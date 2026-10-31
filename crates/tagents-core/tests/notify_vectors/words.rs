//! The `words` section of the notify vectors: verdicts, the words of a notice, titles and names, `basename`, phrases in both locales, the locale of an environment value and the tmux answers.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::collections::HashMap;
use std::fs;
use std::process::Command;

use serde_json::Value;
use tagents_core::node;
use tagents_core::notify::compose::{self, Extra, NameInputs};
use tagents_core::notify::events::{AgentEvent, AgentHookEvent};
use tagents_core::notify::kinds::{self, NoticeKind};
use tagents_core::notify::phrases::{self, Locale, Phrases};
use tagents_core::notify::screen::{self, Screen, ScreenAnswer};

use super::{common, section};

fn words(part: &str) -> Value {
    section("words")
        .get(part)
        .cloned()
        .unwrap_or_else(|| panic!("no part {part} in the words section"))
}

fn text(v: &Value, key: &str) -> String {
    v[key]
        .as_str()
        .unwrap_or_else(|| panic!("{key} in {v}"))
        .to_owned()
}

fn flag(v: &Value, key: &str) -> bool {
    v[key].as_bool().unwrap_or_else(|| panic!("{key} in {v}"))
}

/// An `AgentEvent` from the object node wrote.
fn agent_event(v: &Value) -> AgentEvent {
    AgentEvent {
        at: v["at"].as_f64().unwrap(),
        event: AgentHookEvent::parse(v["event"].as_str().unwrap()).unwrap(),
        key: text(v, "key"),
        session_id: text(v, "sessionId"),
        agent_id: text(v, "agentId"),
        pane: text(v, "pane"),
        cwd: text(v, "cwd"),
        transcript: text(v, "transcript"),
        config_dir: text(v, "configDir"),
        tool: text(v, "tool"),
        sub: text(v, "sub"),
        text: text(v, "text"),
        label: text(v, "label"),
    }
}

fn notice_kind(name: &str) -> NoticeKind {
    [
        NoticeKind::Question,
        NoticeKind::Permission,
        NoticeKind::TurnDone,
        NoticeKind::CacheExpiring,
        NoticeKind::SessionEnd,
    ]
    .into_iter()
    .find(|k| k.as_str() == name)
    .unwrap_or_else(|| panic!("kind {name}"))
}

fn locale(name: &str) -> Locale {
    match name {
        "en" => Locale::En,
        "ru" => Locale::Ru,
        other => panic!("locale {other}"),
    }
}

#[test]
fn verdicts_match_node() {
    let cases = words("verdicts");
    let cases = cases.as_array().unwrap();
    assert!(!cases.is_empty());
    for case in cases {
        let e = agent_event(&case["event"]);
        let got = kinds::classify(&e);
        let want = &case["verdict"];
        match (got, want) {
            (None, Value::Null) => {}
            (Some(v), Value::Object(_)) => {
                assert_eq!(
                    v.kind.map(NoticeKind::as_str),
                    want["kind"].as_str(),
                    "{case}"
                );
                assert_eq!(v.plan, flag(want, "plan"), "{case}");
                assert_eq!(v.arms, flag(want, "arms"), "{case}");
                assert_eq!(v.withdraw, flag(want, "withdraw"), "{case}");
                assert_eq!(v.cancel, flag(want, "cancel"), "{case}");
            }
            (got, want) => panic!("{case}: got {got:?}, node gave {want}"),
        }
        assert_eq!(
            kinds::counts_session(&e.key),
            flag(case, "counts"),
            "{case}"
        );
    }
}

#[test]
fn notices_match_node() {
    let cases = words("notices");
    let cases = cases.as_array().unwrap();
    assert!(!cases.is_empty());
    let dir = common::scratch("notices");
    for (at, case) in cases.iter().enumerate() {
        let mut e = agent_event(&case["event"]);
        match &case["transcript"] {
            Value::Null => {}
            spec if spec.get("missing").is_some() => {
                e.transcript = "/nonexistent/t.jsonl".to_owned()
            }
            spec => {
                let file = dir.join(format!("t{at}.jsonl"));
                let record = serde_json::json!({
                    "type": "assistant",
                    "message": { "content": [{ "type": "text", "text": spec["text"] }] }
                });
                fs::write(&file, format!("{record}\n")).unwrap();
                e.transcript = file.to_string_lossy().into_owned();
            }
        }
        let extra = Extra {
            plan: case["extra"]["plan"].as_bool().unwrap_or(false),
            idle_min: case["extra"]["idleMin"].as_f64(),
            left_min: case["extra"]["leftMin"].as_f64(),
        };
        let p = phrases::phrases_for(locale(case["locale"].as_str().unwrap()));
        let got = compose::compose(
            notice_kind(case["kind"].as_str().unwrap()),
            &e,
            case["name"].as_str().unwrap(),
            &extra,
            p,
        );
        let want = &case["composed"];
        assert_eq!(
            got.title,
            want["title"].as_str().unwrap(),
            "title of {case}"
        );
        assert_eq!(
            got.subtitle,
            want["subtitle"].as_str().unwrap(),
            "subtitle of {case}"
        );
        assert_eq!(got.body, want["body"].as_str().unwrap(), "body of {case}");
    }
    fs::remove_dir_all(&dir).unwrap();
}

/// `untitle_of` of `lib/tagents/names.sh`, run by bash on `title`.
fn shell_untitle(title: &str) -> String {
    let root = concat!(env!("CARGO_MANIFEST_DIR"), "/../..");
    let out = Command::new("bash")
        .args([
            "-c",
            r#". "$1/lib/tagents/names.sh" && untitle_of "$2""#,
            "_",
            root,
            title,
        ])
        .env("STATE_DIR", "/nonexistent")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8(out.stdout).unwrap();
    text.strip_suffix('\n').unwrap_or(&text).to_owned()
}

#[test]
fn untitles_match_node_and_the_shell_function() {
    let cases = words("untitles");
    let cases = cases.as_array().unwrap();
    assert!(!cases.is_empty());
    for case in cases {
        let title = text(case, "title");
        let want = text(case, "out");
        assert_eq!(compose::untitle(&title), want, "{title:?}");
        assert_eq!(
            shell_untitle(&title),
            want,
            "the shell function on {title:?}"
        );
    }
}

#[test]
fn names_match_node() {
    let cases = words("names");
    let cases = cases.as_array().unwrap();
    assert!(!cases.is_empty());
    for case in cases {
        let i = &case["inputs"];
        let labels: HashMap<String, String> = case["labels"]
            .as_array()
            .unwrap()
            .iter()
            .map(|pair| {
                (
                    pair[0].as_str().unwrap().to_owned(),
                    pair[1].as_str().unwrap().to_owned(),
                )
            })
            .collect();
        let (session_id, pane, pane_title, label, cwd, hostname) = (
            text(i, "sessionId"),
            text(i, "pane"),
            text(i, "paneTitle"),
            text(i, "label"),
            text(i, "cwd"),
            text(i, "hostname"),
        );
        let got = compose::agent_name(&NameInputs {
            session_id: &session_id,
            pane: &pane,
            pane_title: &pane_title,
            label: &label,
            cwd: &cwd,
            hostname: &hostname,
            labels: &labels,
        });
        assert_eq!(got, text(case, "name"), "{case}");
    }
}

#[test]
fn basenames_match_node() {
    let cases = words("basenames");
    let cases = cases.as_array().unwrap();
    assert!(!cases.is_empty());
    for case in cases {
        let path = text(case, "path");
        assert_eq!(node::basename(&path), text(case, "out"), "{path:?}");
    }
}

fn texts_of(p: &Phrases) -> Vec<(&'static str, &'static str)> {
    vec![
        ("kindQuestion", p.kind_question),
        ("kindPlan", p.kind_plan),
        ("kindPermission", p.kind_permission),
        ("kindTurnDone", p.kind_turn_done),
        ("kindCacheExpiring", p.kind_cache_expiring),
        ("kindSessionEnd", p.kind_session_end),
        ("questionBody", p.question_body),
        ("turnDoneBody", p.turn_done_body),
        ("permissionBody", p.permission_body),
        ("sessionEndBody", p.session_end_body),
    ]
}

#[test]
fn phrases_match_node() {
    let all = words("phrases");
    for table in all["tables"].as_array().unwrap() {
        let p = phrases::phrases_for(locale(table["locale"].as_str().unwrap()));
        let want = table["texts"].as_object().unwrap();
        let got = texts_of(p);
        assert_eq!(
            got.len(),
            want.len(),
            "the same fields as node's table: {table}"
        );
        for (key, value) in got {
            assert_eq!(
                Some(value),
                want.get(key).and_then(Value::as_str),
                "{key} of {}",
                table["locale"]
            );
        }
        let cache = table["cache"].as_array().unwrap();
        assert!(!cache.is_empty());
        for row in cache {
            let (idle, left) = (row["idle"].as_f64().unwrap(), row["left"].as_f64().unwrap());
            assert_eq!(
                p.cache_body(idle, left),
                text(row, "text"),
                "{row} of {}",
                table["locale"]
            );
        }
    }
}

#[test]
fn locales_of_an_environment_value_match_node() {
    let all = words("phrases");
    let rows = all["locales"].as_array().unwrap();
    assert!(!rows.is_empty());
    for row in rows {
        let got = phrases::phrases_for(Locale::of(row["value"].as_str())).kind_turn_done;
        assert_eq!(
            got,
            text(row, "kindTurnDone"),
            "TAGENTS_LOCALE {}",
            row["value"]
        );
    }
}

#[test]
fn screens_match_node() {
    let cases = words("screens");
    let cases = cases.as_array().unwrap();
    assert!(!cases.is_empty());
    for case in cases {
        let out = text(case, "out");
        let want = &case["screen"];
        let expected = match want {
            Value::Null => None,
            Value::String(s) if s == "no-such-pane" => Some(ScreenAnswer::NoSuchPane),
            Value::Object(_) => Some(ScreenAnswer::Screen(Screen {
                visible: flag(want, "visible"),
                client_pid: want["clientPid"]
                    .as_u64()
                    .map(|pid| u32::try_from(pid).unwrap()),
                pane_title: text(want, "paneTitle"),
            })),
            other => panic!("screen {other}"),
        };
        assert_eq!(screen::parse_screen(&out), expected, "{out:?}");
    }
}
