//! kqueue, through the `kqueue` crate: rustix declares `kevent` unsafe, and the crate's own calls are safe to make.

use std::collections::HashMap;
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, OwnedFd};
use std::path::Path;

use kqueue::{EventData, EventFilter, FilterFlag, Ident, Vnode, Watcher};
use rustix::fs::{Mode, OFlags, open};
use rustix::io::Errno;

use super::{Fired, Key, Kind, Poller, drain};

/// A file: written, grown, its attributes changed, removed, renamed, or revoked.
const FILE_NOTES: FilterFlag = FilterFlag::NOTE_WRITE
    .union(FilterFlag::NOTE_EXTEND)
    .union(FilterFlag::NOTE_ATTRIB)
    .union(FilterFlag::NOTE_DELETE)
    .union(FilterFlag::NOTE_RENAME)
    .union(FilterFlag::NOTE_REVOKE);

/// A directory: an entry added, removed or renamed (`NOTE_WRITE`), or the directory itself removed or renamed. A write to a file inside it is not reported.
const DIR_NOTES: FilterFlag = FilterFlag::NOTE_WRITE
    .union(FilterFlag::NOTE_DELETE)
    .union(FilterFlag::NOTE_RENAME);

pub(super) struct Backend {
    queue: Watcher,
    wake: OwnedFd,
    /// The open descriptor each watch sits on.
    armed: HashMap<(Key, Kind), File>,
}

impl Backend {
    pub(super) fn new(wake: OwnedFd) -> io::Result<Backend> {
        let mut queue = Watcher::new()?;
        queue.add_fd(
            wake.as_raw_fd(),
            EventFilter::EVFILT_READ,
            FilterFlag::empty(),
        )?;
        queue.watch()?;
        Ok(Backend {
            queue,
            wake,
            armed: HashMap::new(),
        })
    }

    /// Puts `file` in the place of the watch of `slot` and registers it. The crate registers every watch it holds each time, which keeps the activation of one that has not been read yet.
    fn keep(&mut self, slot: (Key, Kind), file: Option<File>) -> io::Result<()> {
        let notes = if slot.1 == Kind::Dir {
            DIR_NOTES
        } else {
            FILE_NOTES
        };
        let adding = file.is_some();
        if let Some(file) = &file {
            self.queue
                .add_file(file, EventFilter::EVFILT_VNODE, notes)?;
        }
        let old = match file {
            Some(file) => self.armed.insert(slot, file),
            None => self.armed.remove(&slot),
        };
        if let Some(old) = old {
            // The old entry goes away with its descriptor, so an error here is dropped on purpose: `ENOENT`, the kernel no longer having it, is the expected one.
            let _ = self.queue.remove_file(&old, EventFilter::EVFILT_VNODE);
        }
        let registered = self.queue.watch();
        // `watch` registers every entry of the crate's list, and the crate keeps an entry the kernel refused (`watcher.rs` `watch`, `add_fd`: the list is only trimmed by `remove_fd`). Left there, it fails every later `watch`, and so the arming of every other key.
        if registered.is_err()
            && adding
            && let Some(refused) = self.armed.remove(&slot)
        {
            // `ENOENT` is expected: the kernel never registered the entry it refused.
            let _ = self.queue.remove_file(&refused, EventFilter::EVFILT_VNODE);
        }
        registered
    }

    /// An event of a descriptor that was replaced meanwhile is ignored.
    fn note(&self, ident: &Ident, note: &Vnode, fired: &mut Fired) {
        let Ident::Fd(fd) = ident else { return };
        let Some((&(key, kind), _)) = self.armed.iter().find(|(_, file)| file.as_raw_fd() == *fd)
        else {
            return;
        };
        let gone = matches!(note, Vnode::Delete | Vnode::Rename | Vnode::Revoke);
        fired.add(key, kind == Kind::Dir || gone);
    }
}

impl Poller for Backend {
    fn dir(&mut self, path: &Path, key: Key) -> io::Result<()> {
        let dir = open(
            path,
            OFlags::RDONLY | OFlags::CLOEXEC | OFlags::DIRECTORY,
            Mode::empty(),
        )?;
        self.keep((key, Kind::Dir), Some(File::from(dir)))
    }

    /// `O_NOFOLLOW` fails with `ELOOP` on a symlink, which is no watch and not an error. The crate's `add_filename` would open the path itself, and follow it. `O_NONBLOCK` keeps the open of a FIFO from waiting for a writer, which would hold this thread, and `Watch::drop` behind it, for as long as none comes.
    fn file(&mut self, path: &Path, key: Key) -> io::Result<()> {
        let slot = (key, Kind::File);
        match open(
            path,
            OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW | OFlags::NONBLOCK,
            Mode::empty(),
        ) {
            Ok(file) => self.keep(slot, Some(File::from(file))),
            Err(Errno::LOOP) => self.keep(slot, None),
            Err(err) => {
                self.keep(slot, None)?;
                Err(err.into())
            }
        }
    }

    fn wait(&mut self) -> io::Result<Fired> {
        let mut fired = Fired::default();
        let mut event = self.queue.poll_forever(None);
        while let Some(found) = event {
            match found.data {
                EventData::Error(err) if benign(&err) => {}
                EventData::Error(err) => return Err(err),
                EventData::ReadReady(_) => drain(&self.wake),
                EventData::Vnode(note) => self.note(&found.ident, &note, &mut fired),
                _ => {}
            }
            event = self.queue.poll(None);
        }
        Ok(fired)
    }
}

/// An error event that is no failed wait. The crate builds `InvalidData` for a vnode event with no flag it knows.
fn benign(err: &io::Error) -> bool {
    matches!(
        err.kind(),
        io::ErrorKind::Interrupted | io::ErrorKind::NotFound | io::ErrorKind::InvalidData
    )
}

#[cfg(test)]
mod tests {
    use std::io::{Error, ErrorKind};

    use super::benign;

    #[test]
    fn an_interrupt_a_missing_file_and_an_unknown_note_are_no_failed_wait() {
        for kind in [
            ErrorKind::Interrupted,
            ErrorKind::NotFound,
            ErrorKind::InvalidData,
        ] {
            assert!(benign(&Error::from(kind)), "{kind:?}");
        }
    }

    #[test]
    fn a_bad_descriptor_is_a_failed_wait() {
        assert!(!benign(&Error::from_raw_os_error(
            rustix::io::Errno::BADF.raw_os_error()
        )));
        assert!(!benign(&Error::from(ErrorKind::BrokenPipe)));
    }
}
