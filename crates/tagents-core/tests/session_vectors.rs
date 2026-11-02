//! Checks the Rust session code case by case against what the node code it ports wrote into `tests/fixtures/session-vectors.json` (`tests/rust-session-vectors.mts`). One test per section of the file.
//!
//! The file holds no lone surrogate: a case that needs one carries the six characters of its escape, and the answers node gave are the texts `JSON.stringify` wrote, so every comparison here is a comparison of texts.

// Test code: a failed unwrap here is the failure report.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use serde_json::Value;
use tagents_core::js;
use tagents_core::json::{self, Value as Js};
use tagents_core::session::reference::{self, Read};

/// The sections the turn of `session prompt` reads (`args`, `env`, `stream` and the error line of `outcome`), which the tests of `session::{command,stream,outcome}` take up with that verb.
const READ_BY_THE_TURN: [&str; 4] = ["args", "env", "stream", "outcome"];
const READ_HERE: [&str; 3] = ["print", "decode", "reference"];

fn vectors() -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/session-vectors.json"
    );
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path}: {e}"))
}

fn section(name: &str) -> Value {
    vectors()
        .get(name)
        .cloned()
        .unwrap_or_else(|| panic!("no section {name}"))
}

fn text<'a>(case: &'a Value, key: &str) -> &'a str {
    case[key].as_str().unwrap_or_else(|| panic!("{key} of {case}"))
}

#[test]
fn no_section_is_left_unread() {
    let all = vectors();
    let mut names: Vec<&str> = all.as_object().unwrap().keys().map(String::as_str).collect();
    names.sort_unstable();
    let mut expected: Vec<&str> = READ_HERE.iter().chain(&READ_BY_THE_TURN).copied().collect();
    expected.sort_unstable();
    assert_eq!(names, expected);
}

#[test]
fn what_json_stringify_writes_is_what_stringify_writes() {
    let print = section("print");
    let cases = print["cases"].as_array().unwrap();
    assert!(cases.len() > 60);
    for case in cases {
        let document = text(case, "document");
        let parsed = json::parse_exact(document);
        // The two readers accept the same texts: only a lone surrogate differs, and it is a string, not a syntax.
        assert_eq!(
            json::parse(document).is_some(),
            parsed.is_some(),
            "{document:?}"
        );
        match (&case["compact"], &case["pretty"], parsed) {
            (Value::Null, Value::Null, None) => {}
            (compact, pretty, Some(exact)) => {
                assert_eq!(
                    json::stringify(&exact.value, false),
                    compact.as_str().unwrap(),
                    "compact {document:?}"
                );
                assert_eq!(
                    format!("{}\n", json::stringify(&exact.value, true)),
                    pretty.as_str().unwrap(),
                    "pretty {document:?}"
                );
            }
            (compact, _, got) => panic!("{document:?}: node gave {compact}, Rust read {got:?}"),
        }
    }
}

#[test]
fn bytes_that_are_not_utf8_decode_as_node_decodes_them() {
    let decode = section("decode");
    for case in decode["cases"].as_array().unwrap() {
        let hex = text(case, "hex");
        let bytes: Vec<u8> = (0..hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
            .collect();
        assert_eq!(
            json::quote(&String::from_utf8_lossy(&bytes)),
            text(case, "json"),
            "{}",
            text(case, "name")
        );
    }
}

#[test]
fn a_reference_reads_as_node_reads_it_or_is_handed_over() {
    let reference = section("reference");
    let cases = reference["cases"].as_array().unwrap();
    let (mut accepted, mut refused, mut handed) = (0, 0, 0);
    for case in cases {
        let document = text(case, "text");
        match (reference::read(document), &case["parsed"], &case["handOver"]) {
            (Read::Invalid, Value::Null, Value::Bool(false)) => refused += 1,
            (Read::HandOver, Value::String(_), Value::Bool(true)) => handed += 1,
            (Read::Ref(got), Value::String(want), Value::Bool(false)) => {
                assert_eq!(json::stringify(&got.to_value(), false), *want, "{document}");
                accepted += 1;
            }
            (got, want, hand) => {
                panic!("{document}: Rust read {got:?}, node gave {want} (hand over {hand})")
            }
        }
    }
    // The corpus holds each answer, so a reader that gave one answer to everything fails.
    assert!(accepted > 15 && refused > 15 && handed > 15, "{accepted} {refused} {handed}");
}

#[test]
fn a_detail_is_clipped_as_clip_detail_clips_it() {
    let outcome = section("outcome");
    for case in outcome["clip"].as_array().unwrap() {
        let input = json::parse_exact(text(case, "text")).unwrap().value;
        let units = input.units().unwrap();
        let clipped = js::slice16(&js::collapse_space16(&units), 300).to_vec();
        assert_eq!(
            json::stringify(&Js::from_units(clipped), false),
            text(case, "clipped"),
            "{}",
            text(case, "text")
        );
    }
}
