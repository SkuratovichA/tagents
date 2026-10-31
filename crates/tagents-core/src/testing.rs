//! What the unit tests of several modules share: a scratch directory removed when the test ends, the `Arming` that arms nothing and writes down what it was asked, and the two waits of a test that listens to the watch. A key that has to come is waited for `HEARD`; a key that must not come is waited for `QUIET` and found missing, so a test of silence can pass by being early but never fails by being late.

use std::cell::{Cell, RefCell};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::Receiver;
use std::time::Duration;

use crate::notify::events::Arming;
use crate::watch::{Heard, Key};

pub(crate) const HEARD: Duration = Duration::from_secs(10);
pub(crate) const QUIET: Duration = Duration::from_millis(400);

/// A directory of a test's own, removed when the test ends. The process's temp directory is shared, so the name carries the process and a count.
pub(crate) struct Scratch(pub(crate) PathBuf);

impl Scratch {
    pub(crate) fn new() -> Scratch {
        static COUNT: AtomicUsize = AtomicUsize::new(0);
        let dir = std::env::temp_dir().join(format!(
            "tagents-test-{}-{}",
            std::process::id(),
            COUNT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&dir).unwrap();
        Scratch(dir)
    }

    pub(crate) fn path(&self) -> &Path {
        &self.0
    }

    /// The path as the string the readers take.
    pub(crate) fn dir(&self) -> &str {
        self.0.to_str().unwrap()
    }

    /// A directory of this name inside, created.
    pub(crate) fn sub(&self, name: &str) -> PathBuf {
        let dir = self.0.join(name);
        fs::create_dir_all(&dir).unwrap();
        dir
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// The next key the watch heard, within `HEARD`.
pub(crate) fn heard(keys: &Receiver<Heard>) -> Key {
    match keys.recv_timeout(HEARD).expect("the watch heard nothing") {
        Heard::Fired(key) => key,
        Heard::Ended(err) => panic!("the watch ended: {err}"),
    }
}

/// Takes every key that one action made, however many batches the system sent it in.
pub(crate) fn settle(keys: &Receiver<Heard>) {
    while keys.recv_timeout(QUIET).is_ok() {}
}

/// An `Arming` that arms nothing, writes down what it was asked, and does what it is told: fail the `file` calls from the Nth, fail `dir`, or run something in the middle of the next `file` (what a hook writes between the open of a file and the arming of it).
#[derive(Default)]
pub(crate) struct Recorder {
    pub(crate) calls: RefCell<Vec<String>>,
    pub(crate) file_fails_from: Cell<Option<usize>>,
    pub(crate) dir_fails: Cell<bool>,
    pub(crate) during_file: RefCell<Option<Box<dyn FnOnce()>>>,
}

impl Arming for Recorder {
    fn dir(&self, path: &Path, key: Key) -> io::Result<()> {
        self.calls
            .borrow_mut()
            .push(format!("dir {} {key:?}", path.display()));
        if self.dir_fails.get() {
            return Err(io::Error::from_raw_os_error(24));
        }
        Ok(())
    }

    fn file(&self, path: &Path, key: Key) -> io::Result<()> {
        self.calls
            .borrow_mut()
            .push(format!("file {} {key:?}", path.display()));
        if let Some(run) = self.during_file.borrow_mut().take() {
            run();
        }
        let nth = self
            .calls
            .borrow()
            .iter()
            .filter(|call| call.starts_with("file"))
            .count();
        if self.file_fails_from.get().is_some_and(|from| nth >= from) {
            return Err(io::Error::from_raw_os_error(24));
        }
        Ok(())
    }
}
