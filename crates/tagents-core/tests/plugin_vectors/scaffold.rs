//! The `scaffold` section of the plugin vectors: the five files node's `scaffoldFiles` builds for each `(name, dir, core)` triple, which the Rust renderer of the one template has to write byte for byte.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use tagents_core::plugin::scaffold;

use super::section;

#[test]
fn every_triple_renders_the_bytes_node_writes() {
    let vectors = section("scaffold");
    let cases = vectors["cases"].as_array().unwrap();
    assert!(cases.len() >= 14, "the vector file lost its cases");
    for case in cases {
        let label = case["label"].as_str().unwrap();
        let got = scaffold::files(
            case["name"].as_str().unwrap(),
            case["dir"].as_str().unwrap(),
            case["core"].as_str().unwrap(),
        );
        let want = case["files"].as_array().unwrap();
        assert_eq!(got.len(), want.len(), "{label}: the number of files");
        for (got, want) in got.iter().zip(want) {
            assert_eq!(got.path, want["path"].as_str().unwrap(), "{label}");
            assert_eq!(
                got.body,
                want["body"].as_str().unwrap(),
                "{label}: {}",
                got.path
            );
        }
    }
}
