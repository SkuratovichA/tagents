//! Checks the Rust plugin modules case by case against what the node code they port wrote into `tests/fixtures/plugin-vectors.json` (`tests/rust-plugin-vectors.mts`). One module per section of the file.

#[path = "../common/mod.rs"]
mod common;
mod config;
mod messages;
mod resolve;
mod scaffold;

use serde_json::Value;

/// One section of the vector file, parsed.
pub fn section(name: &str) -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/plugin-vectors.json"
    );
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path}: {e}"));
    let all: Value = serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path}: {e}"));
    all.get(name)
        .cloned()
        .unwrap_or_else(|| panic!("no section {name} in {path}"))
}
