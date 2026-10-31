//! A file watch that never polls and never follows a symlink: inotify on Linux, kqueue on macOS, and one thread that blocks until the operating system has something to say. A caller that follows a log and an options file learns of a line appended or of a file replaced from here, and has no timer that looks for either.
//!
//! A `Watch` holds at most one directory watch and one file watch per `Key`. A directory watch fires when an entry of the directory is added, removed or renamed, and on Linux also when a file in it is written (kqueue does not report that, so nothing may depend on it). A file watch is on the inode and fires when the file is written, truncated, removed or renamed; a path that names a symlink gets no file watch at all, so a link's target being edited is never seen and the link being replaced is seen through the directory. The watch takes the path as the caller wrote it: the caller resolves the directory it wants watched by its real path.
//!
//! A file watch goes stale when the path is renamed over: its inode is gone. The thread therefore opens the path again, before it reports the key, whenever the directory of that key reports anything or the file's own watch reports that the inode was removed, renamed or revoked. The path is remembered per key from the first `file` call on, whether or not that call found a file to watch, so a file created later is watched from the next directory event on. A re-arm that finds the file gone leaves the key without a file watch until the next directory event or the next `file` call, and the key is reported all the same. A re-arm that fails for any other reason (the limit of watches or of descriptors) would leave the key deaf with nothing to say so, and ends the thread with `Ended` like a failed wait.
//!
//! The sink hears a `Heard`: `Fired(key)` for every key whose watch fired and, when the thread has to end because a wait failed or a re-arm failed for any reason but a file that is gone, one last `Ended(error)`. The sink of a daemon is a channel other threads send to as well, so a thread that ended without a word would leave a daemon that is running and never hears of a file again. A `Watch` that is dropped, and a sink that has no receiver, end the thread without a value.
//!
//! Arm, then read. An edge-triggered watch reports nothing for a write that landed between the caller's last read and the arming, so `dir` and `file` return only once the watch is armed, and a caller reads to the end right after they return and again on every key it hears.
//!
//! Every descriptor the watch opens is close-on-exec, with two limits. macOS has no `pipe2`, so a child forked by another thread between the `pipe` and the `fcntl` of the wake pipe inherits its two ends until it execs. And the kqueue descriptor is made by the `kqueue` crate, which exposes it only as a raw descriptor that safe code cannot flag; kqueue(2) says a queue is not inherited by a child, and `tests/watch_fds.rs` pins that a child spawned beside a live watch sees none of the watch's descriptors.

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;

use std::collections::HashMap;
use std::io;
use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::thread::{self, JoinHandle};

#[cfg(target_os = "linux")]
use linux::Backend;
#[cfg(target_os = "macos")]
use macos::Backend;
#[cfg(target_os = "macos")]
use rustix::fs::{OFlags, fcntl_setfl};
#[cfg(target_os = "macos")]
use rustix::io::{FdFlags, fcntl_setfd};
#[cfg(target_os = "macos")]
use rustix::pipe::pipe;
#[cfg(target_os = "linux")]
use rustix::pipe::{PipeFlags, pipe_with};

#[cfg(test)]
mod tests;

/// What a watch is for: the thread sends the key of the watch that fired.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Key {
    Events,
    Options,
}

/// What the watch thread sends to its sink.
#[derive(Debug)]
pub enum Heard {
    /// The watch of this key fired.
    Fired(Key),
    /// A wait failed and the thread has ended, so nothing more will come: `dir` and `file` fail from now on. It is the last value the sink gets from this watch.
    Ended(io::Error),
}

/// The two things a key can watch.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum Kind {
    Dir,
    File,
}

/// What one wait learned. `rearm` holds the keys whose file watch the events say is stale; every one of them is also in `keys`.
#[derive(Default)]
struct Fired {
    keys: Vec<Key>,
    rearm: Vec<Key>,
}

impl Fired {
    fn add(&mut self, key: Key, rearm: bool) {
        if !self.keys.contains(&key) {
            self.keys.push(key);
        }
        if rearm && !self.rearm.contains(&key) {
            self.rearm.push(key);
        }
    }
}

/// What the thread asks of the backend of a platform, so that a test can run the loop over a backend of its own.
trait Poller {
    fn dir(&mut self, path: &Path, key: Key) -> io::Result<()>;
    fn file(&mut self, path: &Path, key: Key) -> io::Result<()>;
    /// Blocks until the operating system, or a wake of the pipe, has something to say.
    fn wait(&mut self) -> io::Result<Fired>;
}

struct Command {
    kind: Kind,
    path: PathBuf,
    key: Key,
    reply: mpsc::Sender<io::Result<()>>,
}

pub struct Watch {
    commands: Option<mpsc::Sender<Command>>,
    wake: OwnedFd,
    thread: Option<JoinHandle<()>>,
}

impl Watch {
    /// Starts the thread. It sends `T::from(Heard::Fired(key))` to `sink` for every key whose watch fired, once per wake for each key that fired (the order between keys is unspecified), and ends when the `Watch` is dropped or when the sink has no receiver. A failed wait, or a failed re-arm of a file watch that is not a missing file, also ends it, after one last `T::from(Heard::Ended(error))`: the next `dir` or `file` then fails, and nothing more comes.
    pub fn start<T: From<Heard> + Send + 'static>(sink: mpsc::Sender<T>) -> io::Result<Watch> {
        let (wake_read, wake) = wake_pipe()?;
        let backend = Backend::new(wake_read)?;
        let (commands, inbox) = mpsc::channel();
        let thread = thread::Builder::new()
            .name("tagents-watch".into())
            .spawn(move || run(backend, &inbox, &sink))?;
        Ok(Watch {
            commands: Some(commands),
            wake,
            thread: Some(thread),
        })
    }

    /// Watches the entries of the directory `path` for `key`, in place of the directory this key watched before. The directory is followed if it is a symlink.
    pub fn dir(&self, path: &Path, key: Key) -> io::Result<()> {
        self.arm(Kind::Dir, path, key)
    }

    /// Watches the file `path` for `key`, in place of the file this key watched before. A path that names a symlink is `Ok(())` and no watch; a path that names nothing is `NotFound`, and is tried again at the next directory event of the key.
    pub fn file(&self, path: &Path, key: Key) -> io::Result<()> {
        self.arm(Kind::File, path, key)
    }

    fn arm(&self, kind: Kind, path: &Path, key: Key) -> io::Result<()> {
        let (reply, answer) = mpsc::channel();
        let command = Command {
            kind,
            path: path.to_path_buf(),
            key,
            reply,
        };
        let ended = || io::Error::other("the watch thread has ended");
        self.commands
            .as_ref()
            .ok_or_else(ended)?
            .send(command)
            .map_err(|_| ended())?;
        self.wake_thread();
        answer.recv().map_err(|_| ended())?
    }

    /// A full pipe means a wake is already waiting, and a closed one means the thread is gone: neither needs more.
    fn wake_thread(&self) {
        let _ = rustix::io::write(&self.wake, &[1]);
    }
}

impl Drop for Watch {
    fn drop(&mut self) {
        drop(self.commands.take());
        self.wake_thread();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn run<T: From<Heard>>(
    mut backend: impl Poller,
    inbox: &mpsc::Receiver<Command>,
    sink: &mpsc::Sender<T>,
) {
    let mut files: HashMap<Key, PathBuf> = HashMap::new();
    loop {
        loop {
            match inbox.try_recv() {
                Ok(command) => {
                    let armed = match command.kind {
                        Kind::Dir => backend.dir(&command.path, command.key),
                        Kind::File => {
                            let armed = backend.file(&command.path, command.key);
                            files.insert(command.key, command.path);
                            armed
                        }
                    };
                    let _ = command.reply.send(armed);
                }
                Err(mpsc::TryRecvError::Empty) => break,
                Err(mpsc::TryRecvError::Disconnected) => return,
            }
        }
        let fired = match backend.wait() {
            Ok(fired) => fired,
            Err(err) => {
                let _ = sink.send(Heard::Ended(err).into());
                return;
            }
        };
        for key in &fired.rearm {
            let Some(path) = files.get(key) else { continue };
            // A file that is gone has no watch to give; any other refusal (a descriptor or watch limit) leaves the key deaf, so it is an ending like a failed wait.
            match backend.file(path, *key) {
                Err(err) if err.kind() != io::ErrorKind::NotFound => {
                    let _ = sink.send(Heard::Ended(err).into());
                    return;
                }
                _ => {}
            }
        }
        for key in fired.keys {
            if sink.send(Heard::Fired(key).into()).is_err() {
                return;
            }
        }
    }
}

/// Empties the wake pipe, which is non-blocking: it ends at the first read that finds nothing.
fn drain(wake: &OwnedFd) {
    let mut buf = [0; 64];
    while matches!(rustix::io::read(wake, &mut buf), Ok(n) if n > 0) {}
}

#[cfg(target_os = "linux")]
fn wake_pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    Ok(pipe_with(PipeFlags::CLOEXEC | PipeFlags::NONBLOCK)?)
}

#[cfg(target_os = "macos")]
fn wake_pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let (read, write) = pipe()?;
    for end in [&read, &write] {
        fcntl_setfd(end, FdFlags::CLOEXEC)?;
        fcntl_setfl(end, OFlags::NONBLOCK)?;
    }
    Ok((read, write))
}
