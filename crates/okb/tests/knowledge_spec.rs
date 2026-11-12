//! `okb --spec` and `okb --version`: the data file of the verbs is what the program prints, and the verbs in it are the ones the program serves.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::{fs, path::Path, process::Command};

use serde_json::Value;

fn okb(args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_okb"))
        .args(args)
        .env_clear()
        .output()
        .unwrap()
}

#[test]
fn the_spec_flag_prints_the_data_file() {
    let file =
        fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../spec/cli/okb.json"))
            .unwrap();
    let out = okb(&["--spec"]);
    assert_eq!(Some(0), out.status.code());
    assert_eq!(file, String::from_utf8(out.stdout).unwrap());
    assert!(out.stderr.is_empty());
}

#[test]
fn the_version_flag_prints_the_workspace_version() {
    let out = okb(&["--version"]);
    assert_eq!(Some(0), out.status.code());
    assert_eq!(
        format!("okb {}\n", env!("CARGO_PKG_VERSION")),
        String::from_utf8(out.stdout).unwrap()
    );
}

#[test]
fn the_spec_lists_exactly_the_verbs_that_read_the_folder() {
    let spec: Value = serde_json::from_str(okb::knowledge::SPEC).unwrap();
    let verbs: Vec<&str> = spec["commands"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["path"][0].as_str().unwrap())
        .collect();
    assert_eq!(okb::knowledge::cli::VERBS.to_vec(), verbs);
    assert_eq!(0, spec["exit"]["ok"]);
    assert_eq!(2, spec["exit"]["usage"]);
    assert_eq!(4, spec["exit"]["notFound"]);
}
