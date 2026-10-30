//! What the integration tests of this crate share: a scratch directory of a test's own, and the gate that keeps a child from being forked while an executable is being written.

// Test code: a failed unwrap here is the failure report.
#![allow(clippy::unwrap_used, clippy::expect_used)]
// Every test crate that includes this module uses some of it.
#![allow(dead_code)]

pub mod rig;

/// The root of the checkout, where the contract, the fixtures and the node packages are.
pub const REPO: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../..");

use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Child, Command, Output},
    sync::{PoisonError, RwLock, RwLockReadGuard, RwLockWriteGuard},
};

/// A scratch directory of this test's own, empty.
pub fn scratch(name: &str) -> PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// A child forked by one test thread holds a copy of every descriptor its parent had open until it execs, so a file stays busy for writing after its writer has closed it, and exec of that file can fail with ETXTBSY ("Text file busy"). Writers of executables take the write side and every spawn the read side, so no fork overlaps a write; spawn through `run` or `start`, and write or copy an executable only under `writing()`.
static FORK_GATE: RwLock<()> = RwLock::new(());

pub fn forking() -> RwLockReadGuard<'static, ()> {
    FORK_GATE.read().unwrap_or_else(PoisonError::into_inner)
}

pub fn writing() -> RwLockWriteGuard<'static, ()> {
    FORK_GATE.write().unwrap_or_else(PoisonError::into_inner)
}

/// `Command::output` under the gate: the guard is held until the child has exited.
#[track_caller]
pub fn run(command: &mut Command) -> Output {
    let _forking = forking();
    command.output().unwrap()
}

/// `Command::spawn` under the gate; the caller feeds or reaps the child after the guard is gone.
#[track_caller]
pub fn start(command: &mut Command) -> Child {
    let _forking = forking();
    command.spawn().unwrap()
}

pub fn write_executable(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let _writing = writing();
    fs::write(path, text).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}
