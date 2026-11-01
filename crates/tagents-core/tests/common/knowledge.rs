//! The knowledge vectors every knowledge test reads: what the node knowledge package gives for each input, written by `tests/rust-knowledge-vectors.mts`.

use std::{
    fs,
    sync::OnceLock,
    time::{Duration, SystemTime},
};

use rusqlite::Connection;
use serde_json::Value;
use tagents_core::knowledge::index::{open_db, reindex};

use super::scratch;

/// The parsed `knowledge-vectors.json`, read once per test binary.
pub fn vectors() -> &'static Value {
    static VECTORS: OnceLock<Value> = OnceLock::new();
    VECTORS.get_or_init(|| {
        let file = format!(
            "{}/crates/tagents-core/tests/fixtures/knowledge-vectors.json",
            super::REPO
        );
        serde_json::from_str(&std::fs::read_to_string(file).unwrap()).unwrap()
    })
}

/// What a refused document says when its front matter is not YAML, up to the wording of the YAML error.
pub const YAML_ERROR: &str = "frontmatter is not YAML: ";

/// Whether an error message is the one node gave. The wording of a YAML error is a known difference (the `yaml` package and `saphyr` word the same refusal differently); the refusal and the text before the wording are not.
pub fn same_message(got: &str, want: &str) -> bool {
    if want.starts_with(YAML_ERROR) {
        return got.starts_with(YAML_ERROR);
    }
    got == want
}

/// A folder of the vector's files with the times they were written at, and an index over it.
pub fn index_of(name: &str, files: &Value) -> (Connection, String) {
    let dir = scratch(name);
    let folder = dir.join("folder");
    fs::create_dir(&folder).unwrap();
    for file in files.as_array().unwrap() {
        let path = folder.join(file["name"].as_str().unwrap());
        fs::write(&path, file["text"].as_str().unwrap()).unwrap();
        let handle = fs::File::options().write(true).open(&path).unwrap();
        let mtime =
            SystemTime::UNIX_EPOCH + Duration::from_secs(file["mtimeSec"].as_u64().unwrap());
        handle.set_modified(mtime).unwrap();
    }
    let folder = folder.to_str().unwrap().to_string();
    let mut db = open_db(dir.join("index.sqlite").to_str().unwrap()).unwrap();
    reindex(&mut db, &folder, false).unwrap();
    (db, folder)
}
