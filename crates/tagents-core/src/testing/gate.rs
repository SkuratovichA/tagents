//! The gate that keeps a child from being forked while an executable is being written, and the helpers that go with it. This one file is compiled twice, as `testing::gate` into the unit tests of the library and as `gate` into `tests/common`: each test binary is a process of its own and so needs its own gate, and the code exists once.

// Test code: a failed unwrap here is the failure report.
#![allow(clippy::unwrap_used, clippy::expect_used)]
// Every test binary that includes this file uses some of it.
#![allow(dead_code)]

use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::Path,
    process::{Child, Command, Output},
    sync::{PoisonError, RwLock, RwLockReadGuard, RwLockWriteGuard},
};

/// A child forked by one test thread holds a copy of every descriptor its parent had open until it execs, so a file stays busy for writing after its writer has closed it, and exec of that file can fail with ETXTBSY ("Text file busy"). Writers of executables take the write side and every spawn the read side, so no fork overlaps a write: spawn through `run` or `start`, or under `forking()` when the spawn is inside the code under test, and write or copy an executable only under `writing()` (`write_executable`). A test that holds `forking()` must not call `writing()`: the write side waits for every reader, itself included.
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

/// `text` written to `path` and made executable (755), under the write side of the gate; the directory above it is made.
pub fn write_executable(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let _writing = writing();
    fs::write(path, text).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

/// What bash prints, without its last newline, for `function` of `lib/tagents/names.sh` called with `arg`, the state directory being `state_dir`.
#[track_caller]
pub fn names_sh(function: &str, arg: &str, state_dir: &Path) -> String {
    let root = concat!(env!("CARGO_MANIFEST_DIR"), "/../..");
    let out = run(Command::new("bash")
        .args([
            "-c",
            r#"TAB=$'\t'; . "$1/lib/tagents/names.sh" && "$2" "$3""#,
            "_",
            root,
            function,
            arg,
        ])
        .env("STATE_DIR", state_dir));
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8(out.stdout).unwrap();
    text.strip_suffix('\n').unwrap_or(&text).to_owned()
}
