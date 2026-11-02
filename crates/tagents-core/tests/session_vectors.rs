//! Checks the Rust session code case by case against what the node code it ports wrote into `tests/fixtures/session-vectors.json` (`tests/rust-session-vectors.mts`). One test per section of the file.
//!
//! The file holds no lone surrogate: a case that needs one carries the six characters of its escape, and the answers node gave are the texts `JSON.stringify` wrote, so every comparison here is a comparison of texts.

// Test code: a failed unwrap here is the failure report.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use serde_json::Value;
use tagents_core::js;
use tagents_core::json::{self, Value as Js};
use tagents_core::session::command;
use tagents_core::session::reference::{self, Read};
use tagents_core::session::stream;

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
    case[key]
        .as_str()
        .unwrap_or_else(|| panic!("{key} of {case}"))
}

#[test]
fn no_section_is_left_unread() {
    let all = vectors();
    let mut names: Vec<&str> = all
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
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
        match (
            reference::read(document),
            &case["parsed"],
            &case["handOver"],
        ) {
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
    assert!(
        accepted > 15 && refused > 15 && handed > 15,
        "{accepted} {refused} {handed}"
    );
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

/// What the reader made of a case, in the shape of the fixture.
fn reader_answers(chunks: &[&[u8]]) -> (stream::Reader, Vec<String>) {
    let mut reader = stream::Reader::listening();
    let mut events = Vec::new();
    let mut on = |line: &str| events.push(line.to_owned());
    for chunk in chunks {
        reader.push(chunk, &mut on);
    }
    reader.end(&mut on);
    (reader, events)
}

fn assert_reader_equals(case: &Value, reader: &stream::Reader, events: &[String], how: &str) {
    let name = text(case, "name");
    let want: Vec<&str> = case["events"]
        .as_array()
        .unwrap()
        .iter()
        .map(|event| event.as_str().unwrap())
        .collect();
    assert_eq!(events, want, "{name}, {how}: events");
    let payload = reader
        .payload
        .as_ref()
        .map(|payload| json::stringify(payload, false));
    assert_eq!(
        payload.as_deref(),
        case["payload"].as_str(),
        "{name}, {how}: payload"
    );
    let session_id = reader.session_id.as_ref().and_then(Js::as_str);
    assert_eq!(
        session_id,
        case["sessionId"].as_str(),
        "{name}, {how}: session id"
    );
    assert_eq!(
        Some(reader.tool_uses),
        case["toolUses"].as_u64(),
        "{name}, {how}: tool uses"
    );
    assert_eq!(
        json::quote_units(&reader.text),
        text(case, "text"),
        "{name}, {how}: text"
    );
    assert_eq!(
        Some(reader.saw_result),
        case["sawResult"].as_bool(),
        "{name}, {how}: saw result"
    );
}

#[test]
fn the_reader_gives_what_stream_reader_gives() {
    let stream = section("stream");
    let cases = stream["cases"].as_array().unwrap();
    assert!(cases.len() > 60);
    for case in cases {
        let input = text(case, "input");
        // In one read, in the reads node was given, and a byte at a time, which is a cut node's decoder is there to hide.
        let (reader, events) = reader_answers(&[input.as_bytes()]);
        assert_reader_equals(case, &reader, &events, "whole");
        if let Some(size) = case["chunk"].as_u64() {
            let chars: Vec<char> = input.chars().collect();
            let pieces: Vec<String> = chars
                .chunks(usize::try_from(size).unwrap())
                .map(|piece| piece.iter().collect())
                .collect();
            let chunks: Vec<&[u8]> = pieces.iter().map(String::as_bytes).collect();
            let (reader, events) = reader_answers(&chunks);
            assert_reader_equals(case, &reader, &events, "chunked");
        }
        let bytes: Vec<&[u8]> = input.as_bytes().chunks(1).collect();
        let (reader, events) = reader_answers(&bytes);
        assert_reader_equals(case, &reader, &events, "byte by byte");
    }
}

/// The spec of a case, read as `session prompt` reads it: inside a reference.
fn spec_of(value: &Value) -> reference::Spec {
    let text = format!(r#"{{"id":"s","claudeSessionId":null,"transcript":null,"spec":{value}}}"#);
    match reference::read(&text) {
        Read::Ref(reference) => reference.spec,
        other => panic!("{text}: {other:?}"),
    }
}

#[test]
fn the_argv_is_what_build_args_gives() {
    let args = section("args");
    let cases = args["cases"].as_array().unwrap();
    assert!(cases.len() > 200);
    for case in cases {
        let want: Vec<&str> = case["argv"]
            .as_array()
            .unwrap()
            .iter()
            .map(|word| word.as_str().unwrap())
            .collect();
        let got = command::args(
            &spec_of(&case["spec"]),
            text(case, "text"),
            case["resume"].as_str(),
        );
        assert_eq!(got, want, "{} {:?}", text(case, "name"), case["text"]);
    }
}

#[test]
fn the_environment_is_what_child_env_gives() {
    let env = section("env");
    let cases = env["cases"].as_array().unwrap();
    assert!(cases.len() > 80);
    for case in cases {
        let parent = case["parentEnv"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(name, value)| (name.clone(), value.as_str().unwrap().to_owned()))
            .collect();
        let got = command::environment(
            &spec_of(&case["specValue"]),
            &parent,
            "<node-dir>",
            "<home>",
        );
        let want: std::collections::BTreeMap<String, String> = case["env"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(name, value)| (name.clone(), value.as_str().unwrap().to_owned()))
            .collect();
        assert_eq!(got, want, "{} {}", text(case, "parent"), text(case, "spec"));
    }
    assert_eq!(text(&env, "localBin"), "<home>/.local/bin");
}
