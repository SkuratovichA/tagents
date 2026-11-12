//! What the integration tests of this crate share: a scratch directory of a test's own, and the gate that keeps a child from being forked while an executable is being written.

// Test code: a failed unwrap here is the failure report.
#![allow(clippy::unwrap_used, clippy::expect_used)]
// Each test crate that includes this module uses a different part of it, so what one leaves unused is not dead.
#![allow(dead_code, unused_imports)]
pub mod knowledge;
// The process helpers are the file the tests of tagents-core use, so that they exist once.
#[path = "../../../tagents-core/tests/common/rig.rs"]
pub mod rig;
pub mod sessions;
pub mod shared;

/// The root of the checkout, where the contract, the fixtures and the node packages are.
pub const REPO: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../..");

use std::{
    fs,
    ops::Deref,
    path::{Path, PathBuf},
};

// The gate is one file that the unit tests of the library compile too, so that it exists once.
#[path = "../../../tagents-core/src/testing/gate.rs"]
mod gate;
pub use gate::{forking, names_sh, run, start, write_executable, writing};

/// A scratch directory of this test's own, empty.
pub fn scratch(name: &str) -> PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// A scratch directory under `/tmp`, empty, for what is bound to a unix socket: an address holds about 100 bytes, which the paths of `scratch` (in the build directory of a checkout) can exceed. The name carries the process id, so two runs do not meet, and the directory is removed when the value is dropped.
pub struct Short(PathBuf);

impl Deref for Short {
    type Target = Path;

    fn deref(&self) -> &Path {
        &self.0
    }
}

impl Drop for Short {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

pub fn short_scratch(name: &str) -> Short {
    let dir = PathBuf::from(format!("/tmp/tk-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    Short(dir)
}
