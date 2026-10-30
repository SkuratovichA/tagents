//! inotify, through rustix and `poll`.

use std::collections::HashMap;
use std::fs;
use std::io;
use std::mem::MaybeUninit;
use std::os::fd::OwnedFd;
use std::path::Path;

use rustix::event::{PollFd, PollFlags, poll};
use rustix::fs::inotify::{self, CreateFlags, ReadFlags, WatchFlags};
use rustix::io::Errno;

use super::{Fired, Key, Kind, drain};

/// What libuv asks inotify for, so a watch sees what node's `fs.watch` sees.
const MASK: WatchFlags = WatchFlags::ATTRIB
    .union(WatchFlags::CREATE)
    .union(WatchFlags::MODIFY)
    .union(WatchFlags::DELETE)
    .union(WatchFlags::DELETE_SELF)
    .union(WatchFlags::MOVE_SELF)
    .union(WatchFlags::MOVED_FROM)
    .union(WatchFlags::MOVED_TO);

/// What it means for the file watch that its inode is gone from the path, or that the kernel dropped the watch.
const FILE_GONE: ReadFlags = ReadFlags::DELETE_SELF
    .union(ReadFlags::MOVE_SELF)
    .union(ReadFlags::IGNORED);

pub(super) struct Backend {
    inotify: OwnedFd,
    wake: OwnedFd,
    /// The watch descriptor of each watch.
    armed: HashMap<(Key, Kind), i32>,
}

impl Backend {
    pub(super) fn new(wake: OwnedFd) -> io::Result<Backend> {
        let inotify = inotify::init(CreateFlags::CLOEXEC | CreateFlags::NONBLOCK)?;
        Ok(Backend {
            inotify,
            wake,
            armed: HashMap::new(),
        })
    }

    pub(super) fn dir(&mut self, path: &Path, key: Key) -> io::Result<()> {
        let armed = inotify::add_watch(&self.inotify, path, MASK | WatchFlags::ONLYDIR);
        self.keep((key, Kind::Dir), armed.ok());
        armed.map(|_| ()).map_err(io::Error::from)
    }

    /// `IN_DONT_FOLLOW` makes a watch on a symlink succeed, on the link and not on its target, so a link is asked about first and gets no watch. Opening the path with `O_NOFOLLOW` would fail with `ELOOP` instead, but inotify takes a path and not a descriptor.
    pub(super) fn file(&mut self, path: &Path, key: Key) -> io::Result<()> {
        let armed = match fs::symlink_metadata(path) {
            Err(err) => Err(err),
            Ok(meta) if meta.file_type().is_symlink() => Ok(None),
            Ok(_) => inotify::add_watch(&self.inotify, path, MASK | WatchFlags::DONT_FOLLOW)
                .map(Some)
                .map_err(io::Error::from),
        };
        self.keep((key, Kind::File), armed.as_ref().ok().copied().flatten());
        armed.map(|_| ())
    }

    /// Puts `wd` in the place of the watch of `slot`. The same inode gives the same descriptor, so a re-arm of an unchanged file removes nothing. A removal fails when the kernel already dropped the watch with its inode, which is what the caller wants.
    fn keep(&mut self, slot: (Key, Kind), wd: Option<i32>) {
        let old = match wd {
            Some(wd) => self.armed.insert(slot, wd),
            None => self.armed.remove(&slot),
        };
        if let Some(old) = old.filter(|old| Some(*old) != wd) {
            let _ = inotify::remove_watch(&self.inotify, old);
        }
    }

    pub(super) fn wait(&mut self) -> io::Result<Fired> {
        let mut fds = [
            PollFd::new(&self.inotify, PollFlags::IN),
            PollFd::new(&self.wake, PollFlags::IN),
        ];
        loop {
            match poll(&mut fds, None) {
                Ok(_) => break,
                Err(Errno::INTR) => {}
                Err(err) => return Err(err.into()),
            }
        }
        let events = !fds[0].revents().is_empty();
        let woken = !fds[1].revents().is_empty();
        let mut fired = Fired::default();
        if events {
            self.read(&mut fired)?;
        }
        if woken {
            drain(&self.wake);
        }
        Ok(fired)
    }

    /// Reads what inotify holds, to the end. A queue that overflowed lost events, so every key is reported and every file watch opened again.
    fn read(&self, fired: &mut Fired) -> io::Result<()> {
        let mut buf = [MaybeUninit::uninit(); 4096];
        let mut reader = inotify::Reader::new(&self.inotify, &mut buf);
        loop {
            let event = match reader.next() {
                Ok(event) => event,
                Err(Errno::AGAIN) => return Ok(()),
                Err(Errno::INTR) => continue,
                Err(err) => return Err(err.into()),
            };
            if event.events().contains(ReadFlags::QUEUE_OVERFLOW) {
                for &(key, _) in self.armed.keys() {
                    fired.add(key, true);
                }
                continue;
            }
            let Some((&(key, kind), _)) = self.armed.iter().find(|(_, wd)| **wd == event.wd())
            else {
                continue;
            };
            fired.add(
                key,
                kind == Kind::Dir || event.events().intersects(FILE_GONE),
            );
        }
    }
}
