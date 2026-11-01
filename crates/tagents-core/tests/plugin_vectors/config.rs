//! The `config` section of the plugin vectors: each document of the corpus is written to a scratch directory, `plugin::config::add` or `remove` is run on it, and the file must come out as node's `addPluginEntry` or `removePluginEntry` left it. A call node threw on (or one whose file Rust does not read as node does) must be handed over, with the directory as it was.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};

use serde_json::Value;
use tagents_core::plugin::config::{self, Added, Removed};

use super::{common, section};

fn hex_bytes(hex: &str) -> Vec<u8> {
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
        .collect()
}

/// The bytes of the corpus document of that name.
fn document_bytes(documents: &Value, name: &str) -> Vec<u8> {
    let doc = documents
        .as_array()
        .unwrap()
        .iter()
        .find(|d| d["name"] == name)
        .unwrap_or_else(|| panic!("no document {name}"));
    match (doc["hex"].as_str(), doc["text"].as_str()) {
        (Some(hex), _) => hex_bytes(hex),
        (None, Some(text)) => text.as_bytes().to_vec(),
        (None, None) => Vec::new(),
    }
}

/// Every file below `dir`, by path, with its bytes; a directory is `None`.
fn snapshot(dir: &Path) -> BTreeMap<PathBuf, Option<Vec<u8>>> {
    let mut found = BTreeMap::new();
    let mut pending = vec![dir.to_path_buf()];
    while let Some(next) = pending.pop() {
        for entry in fs::read_dir(&next).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                found.insert(path.clone(), None);
                pending.push(path);
            } else {
                let bytes = fs::read(&path).unwrap();
                found.insert(path, Some(bytes));
            }
        }
    }
    found
}

#[test]
fn every_document_gives_the_text_node_gave_or_is_handed_over() {
    let config = section("config");
    let documents = &config["documents"];
    let cases = config["cases"].as_array().unwrap();
    assert!(cases.len() > 400, "the vector file lost its cases");
    for (n, case) in cases.iter().enumerate() {
        let dir = common::scratch(&format!("plugin-vectors-config-{n}"));
        let file = match case["document"].as_str() {
            Some(name) => {
                let file = dir.join("config.toml");
                fs::write(&file, document_bytes(documents, name)).unwrap();
                file
            }
            None => dir.join("sub").join("config.toml"),
        };
        let before = snapshot(&dir);
        let (verb, key) = (
            case["verb"].as_str().unwrap(),
            case["key"].as_str().unwrap(),
        );
        let file_str = file.to_str().unwrap();
        let outcome = match verb {
            "add" => config::add(file_str, key, case["from"].as_str().unwrap()).map(|a| match a {
                Added::Written => "added",
                Added::Exists => "exists",
            }),
            _ => config::remove(file_str, key).map(|r| match r {
                Removed::Written => "removed",
                Removed::Absent => "absent",
            }),
        };
        let what = format!(
            "{n}: {verb} {key:?} on {} (node: {})",
            case["document"], case["outcome"]
        );
        if case["handOver"] == true {
            assert!(outcome.is_err(), "{what}: answered {outcome:?}");
            assert_eq!(snapshot(&dir), before, "{what}: wrote before handing over");
            continue;
        }
        assert_eq!(outcome, Ok(case["outcome"].as_str().unwrap()), "{what}");
        match case["text"].as_str() {
            Some(text) => {
                assert_eq!(fs::read_to_string(&file).unwrap(), text, "{what}");
                let names: Vec<_> = fs::read_dir(file.parent().unwrap())
                    .unwrap()
                    .map(|e| e.unwrap().file_name())
                    .collect();
                assert_eq!(names, ["config.toml"], "{what}: a file was left beside it");
            }
            None => assert_eq!(snapshot(&dir), before, "{what}: wrote when node did not"),
        }
    }
}

#[test]
fn toml_string_and_key_write_what_node_writes() {
    let config = section("config");
    for case in config["strings"].as_array().unwrap() {
        let value = case["value"].as_str().unwrap();
        assert_eq!(
            config::toml_string(value).as_deref(),
            case["string"].as_str(),
            "string of {value:?}"
        );
        assert_eq!(
            config::toml_key(value).as_deref(),
            case["key"].as_str(),
            "key of {value:?}"
        );
    }
}
