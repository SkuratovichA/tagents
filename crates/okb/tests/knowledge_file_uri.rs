//! A name that starts with `file:` opens as a URI in the node program (`node:sqlite` opens every database with the URI flag) and in this one (the bundled SQLite is built with `SQLITE_USE_URI`), so `file:rel.db` is the file `rel.db`. Neither program is handed such a name by a verb: `resolveDb` in `packages/knowledge/src/paths.ts` makes the path absolute with `path.resolve`, so `TAGENTS_KNOWLEDGE_DB=file:rel.db` creates a file named `file:rel.db` in the working directory, and the Rust verbs resolve the path the same way (task 9.4). This test is a binary of its own because it changes the working directory of the process.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::{env, fs, path::Path};

use okb::knowledge::index::open_db;
use serde_json::{Value, json};

use common::{knowledge::vectors, scratch};

/// Everything under `dir`, folders with a trailing slash, in name order.
fn listing(dir: &Path, prefix: &str) -> Vec<String> {
    let mut entries: Vec<_> = fs::read_dir(dir).unwrap().map(Result::unwrap).collect();
    entries.sort_by_key(fs::DirEntry::file_name);
    let mut found = Vec::new();
    for entry in entries {
        let name = format!("{prefix}{}", entry.file_name().to_string_lossy());
        if entry.file_type().unwrap().is_dir() {
            found.push(format!("{name}/"));
            found.extend(listing(&entry.path(), &format!("{name}/")));
        } else {
            found.push(name);
        }
    }
    found
}

#[test]
fn a_file_uri_names_the_file_it_points_at_as_it_does_in_node() {
    for (i, want) in vectors()["engine"]["fileUris"]
        .as_array()
        .unwrap()
        .iter()
        .enumerate()
    {
        let name = want["name"].as_str().unwrap();
        let dir = scratch(&format!("knowledge-file-uri-{i}"));
        env::set_current_dir(&dir).unwrap();
        let outcome = match open_db(name) {
            Ok(_) => "opened".to_string(),
            Err(message) => message,
        };
        let got: Value = json!({"name": name, "outcome": outcome, "left": listing(&dir, "")});
        assert_eq!(want, &got, "{name}");
    }
}
