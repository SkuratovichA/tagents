//! The `feed` section of the notify vectors: event lines, state rows, the state directory's readers and the decoding of bytes, each against what node's functions answered (`tests/rust-notify-vectors/feed.mts`).

// Test code: a failed unwrap here is the failure report.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::{
    fs,
    path::{Path, PathBuf},
};

use serde_json::Value;
use tagents_core::notify::{
    events::{AgentEvent, parse_event_line},
    state::{
        AgentStateRow, RowState, labels_by_session, parse_state_line, read_agent_state, read_labels,
    },
};

use super::section;

fn cases(name: &str) -> Vec<Value> {
    let section = section("feed");
    let list = section[name]
        .as_array()
        .unwrap_or_else(|| panic!("feed.{name} is not a list"))
        .clone();
    assert!(list.len() > 10, "feed.{name} has only {} cases", list.len());
    list
}

fn text<'a>(case: &'a Value, field: &str) -> &'a str {
    case[field]
        .as_str()
        .unwrap_or_else(|| panic!("{field} of {case} is not a string"))
}

fn assert_event(line: &str, want: &Value, got: &AgentEvent) {
    assert_eq!(got.at, want["at"].as_f64().unwrap(), "at of {line:?}");
    assert_eq!(got.event.as_str(), text(want, "event"), "event of {line:?}");
    for (field, value) in [
        ("key", &got.key),
        ("sessionId", &got.session_id),
        ("agentId", &got.agent_id),
        ("pane", &got.pane),
        ("cwd", &got.cwd),
        ("transcript", &got.transcript),
        ("configDir", &got.config_dir),
        ("tool", &got.tool),
        ("sub", &got.sub),
        ("text", &got.text),
        ("label", &got.label),
    ] {
        assert_eq!(value, text(want, field), "{field} of {line:?}");
    }
}

#[test]
fn event_lines_parse_as_node_parses_them() {
    let (mut kept, mut skipped) = (0, 0);
    for case in cases("eventLines") {
        let line = text(&case, "line");
        match (&case["event"], parse_event_line(line)) {
            (Value::Null, None) => skipped += 1,
            (want @ Value::Object(_), Some(got)) => {
                assert_event(line, want, &got);
                kept += 1;
            }
            (want, got) => panic!("{line:?}: node says {want}, Rust says {got:?}"),
        }
    }
    assert!(
        kept > 10 && skipped > 10,
        "the vectors must hold both kinds: {kept} lines kept, {skipped} skipped"
    );
}

fn state_name(state: RowState) -> &'static str {
    match state {
        RowState::New => "new",
        RowState::Working => "working",
        RowState::Blocked => "blocked",
        RowState::Done => "done",
        RowState::Gone => "gone",
        RowState::Subdone => "subdone",
    }
}

fn assert_row(context: &str, want: &Value, got: &AgentStateRow) {
    assert_eq!(got.key, text(want, "key"), "key of {context}");
    assert_eq!(got.at, want["at"].as_f64().unwrap(), "at of {context}");
    assert_eq!(
        state_name(got.state),
        text(want, "state"),
        "state of {context}"
    );
    for (field, value) in [
        ("sessionId", &got.session_id),
        ("cwd", &got.cwd),
        ("transcript", &got.transcript),
        ("detail", &got.detail),
    ] {
        assert_eq!(value, text(want, field), "{field} of {context}");
    }
    assert_eq!(
        got.config_dir.as_deref(),
        want["configDir"].as_str(),
        "configDir of {context}"
    );
}

#[test]
fn state_lines_parse_as_node_parses_them() {
    let (mut kept, mut skipped) = (0, 0);
    for case in cases("stateLines") {
        let (key, line) = (text(&case, "key"), text(&case, "line"));
        match (&case["row"], parse_state_line(key, line)) {
            (Value::Null, None) => skipped += 1,
            (want @ Value::Object(_), Some(got)) => {
                assert_row(&format!("{line:?}"), want, &got);
                kept += 1;
            }
            (want, got) => panic!("{line:?}: node says {want}, Rust says {got:?}"),
        }
    }
    assert!(
        kept > 10 && skipped > 10,
        "the vectors must hold both kinds: {kept} rows kept, {skipped} skipped"
    );
}

/// A directory of this case's own, empty, under the target directory.
fn fresh_dir(name: &str) -> PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn assert_same_map(context: &str, want: &Value, got: &std::collections::HashMap<String, String>) {
    let want = want.as_object().unwrap();
    let mut got: Vec<(&str, &str)> = got.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    got.sort_unstable();
    let mut want: Vec<(&str, &str)> = want
        .iter()
        .map(|(k, v)| (k.as_str(), v.as_str().unwrap()))
        .collect();
    want.sort_unstable();
    assert_eq!(got, want, "{context}");
}

#[test]
fn state_directories_read_as_node_reads_them() {
    for (i, case) in cases("stateDirs").iter().enumerate() {
        let name = text(case, "name");
        let root = fresh_dir(&format!("notify-feed-vectors-{i}"));
        let dir = root.join("agent-state");
        if let Some(files) = case["files"].as_object() {
            fs::create_dir_all(&dir).unwrap();
            for (file, body) in files {
                let path = dir.join(file);
                fs::create_dir_all(path.parent().unwrap()).unwrap();
                fs::write(path, body.as_str().unwrap()).unwrap();
            }
        }
        let dir = dir.to_str().unwrap();
        let want = case["rows"].as_array().unwrap();
        let got = read_agent_state(dir);
        assert_eq!(
            got.iter().map(|r| r.key.as_str()).collect::<Vec<_>>(),
            want.iter().map(|r| text(r, "key")).collect::<Vec<_>>(),
            "the rows of {name}"
        );
        for (want, got) in want.iter().zip(&got) {
            assert_row(&format!("{name}, {}", got.key), want, got);
        }
        assert_same_map(
            &format!("labelsBySession of {name}"),
            &case["labelsBySession"],
            &labels_by_session(dir),
        );
        assert_same_map(
            &format!("labels of {name}"),
            &case["labels"],
            &read_labels(dir),
        );
        fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn bytes_decode_as_node_decodes_them() {
    for case in cases("decode") {
        let hex = text(&case, "hex");
        let bytes: Vec<u8> = (0..hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
            .collect();
        assert_eq!(
            String::from_utf8_lossy(&bytes),
            text(&case, "text"),
            "bytes {hex}"
        );
    }
}
