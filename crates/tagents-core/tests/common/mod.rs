//! What the integration tests of this crate share: a scratch directory of a test's own, and the gate that keeps a child from being forked while an executable is being written.

// Test code: a failed unwrap here is the failure report.
#![allow(clippy::unwrap_used, clippy::expect_used)]
// Every test crate that includes this module uses some of it.
#![allow(dead_code, unused_imports)]

pub mod rig;

/// The root of the checkout, where the contract, the fixtures and the node packages are.
pub const REPO: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../..");

use std::{
    fs,
    io::{self, PipeWriter},
    path::{Path, PathBuf},
};

// The gate is one file that the unit tests of the library compile too, so that it exists once.
#[path = "../../src/testing/gate.rs"]
mod gate;
pub use gate::{forking, names_sh, run, start, write_executable, writing};

/// A scratch directory of this test's own, empty.
pub fn scratch(name: &str) -> PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// The write end of a pipe whose read end is gone: a child given it as stderr gets EPIPE on every write.
pub fn closed_pipe() -> PipeWriter {
    let (reader, writer) = io::pipe().unwrap();
    drop(reader);
    writer
}
