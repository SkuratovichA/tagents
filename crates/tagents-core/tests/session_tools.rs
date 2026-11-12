//! `sessions_recent` and `sessions_search` of the tagents server: the text the sessions CLI printed, the refusals the node server wrote for their arguments, and the list the server announces.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::{fs, path::Path};

use serde_json::{Value, json};
use tagents_core::{
    mcp::{
        args::refusal,
        rpc::CallResult,
        sessions_tools::{SessionTools, listing},
    },
    transcripts::Context,
};

use common::{REPO, scratch, sessions::seed_sessions};

/// The fixed clock of the sessions fixtures.
const NOW: i64 = 1_793_448_000_000;

const REFUSAL: &str = "MCP error -32602: Input validation error: Invalid arguments for tool ";

fn tools_at(home: &Path) -> SessionTools {
    let home = home.to_str().unwrap().to_owned();
    let claude = format!("{home}/.claude");
    SessionTools::with_context(move || Context {
        home: home.clone(),
        claude_homes: Some(claude.clone()),
        now_ms: NOW,
    })
}

fn call(tools: &SessionTools, tool: &str, args: Option<&Value>) -> CallResult {
    tools
        .call(tool, args.and_then(Value::as_object))
        .unwrap_or_else(|| panic!("no answer for {tool}"))
}

fn recorded(fixture: &str) -> String {
    fs::read_to_string(Path::new(REPO).join(format!(
        "packages/core/test/fixtures/sessions/{fixture}.txt"
    )))
    .unwrap()
}

#[test]
fn the_session_tools_print_what_the_sessions_cli_printed() {
    let home = scratch("session-tools");
    seed_sessions(&home.join(".claude"));
    let tools = tools_at(&home);
    for (tool, args, fixture) in [
        ("sessions_recent", json!({}), "recent"),
        ("sessions_recent", json!({"limit": 1}), "recent-1"),
        (
            "sessions_search",
            json!({"words": "deploy"}),
            "search-deploy",
        ),
        (
            "sessions_search",
            json!({"words": " deploy\t"}),
            "search-deploy",
        ),
        (
            "sessions_search",
            json!({"words": "zzzznothing"}),
            "search-miss",
        ),
    ] {
        let result = call(&tools, tool, Some(&args));
        assert_eq!(recorded(fixture), result.body(), "{tool} {args}");
        assert!(!result.is_error(), "{tool} {args}");
        // A result that is not a failure leaves out the flag, as the node server does.
        assert_eq!(
            None,
            serde_json::to_value(&result).unwrap().get("isError"),
            "{tool} {args}"
        );
    }
    // Words that are only white space are no words, and then every session matches.
    let all = call(&tools, "sessions_search", Some(&json!({"words": " "})));
    assert!(
        all.body().contains("aaaaaaaa") && all.body().contains("ffffffff"),
        "{}",
        all.body()
    );
}

#[test]
fn a_name_that_is_not_theirs_gets_no_answer() {
    let tools = tools_at(Path::new("/nonexistent"));
    assert!(tools.call("knowledge_search", None).is_none());
    assert!(SessionTools::has("sessions_recent") && !SessionTools::has("knowledge_search"));
}

#[test]
fn the_list_is_what_the_server_announced() {
    assert_eq!(
        vec!["sessions_recent", "sessions_search"],
        listing()
            .iter()
            .map(|t| t["name"].as_str().unwrap())
            .collect::<Vec<_>>()
    );
}

#[test]
fn every_refusal_and_every_pass_of_the_node_server_is_the_same() {
    let vectors: Value = serde_json::from_str(
        &fs::read_to_string(
            Path::new(REPO).join("crates/tagents-core/tests/fixtures/sessions-tools-vectors.json"),
        )
        .unwrap(),
    )
    .unwrap();
    let (mut replayed, mut refusals) = (0, 0);
    for entry in vectors.as_array().unwrap() {
        let params = entry["params"].as_object().unwrap();
        let tool = params["name"].as_str().unwrap();
        let schema = listing()
            .iter()
            .find(|listed| listed["name"] == tool)
            .map(|listed| &listed["inputSchema"])
            .unwrap();
        // An arguments value that is not an object is refused by the loop before a tool is asked.
        let args = match params.get("arguments") {
            None => None,
            Some(Value::Object(args)) => Some(args),
            Some(_) => continue,
        };
        let text = entry["response"]["result"]["content"][0]["text"]
            .as_str()
            .unwrap();
        let want = text.starts_with(REFUSAL).then_some(text);
        assert_eq!(
            want,
            refusal(tool, schema, args).as_deref(),
            "{}",
            entry["name"]
        );
        replayed += 1;
        refusals += usize::from(want.is_some());
    }
    assert!(
        replayed >= 10 && refusals >= 10,
        "replayed {replayed}, refused {refusals}"
    );
}

/// What the SDK says of a number JavaScript reads as infinite, which JSON text spells `1e999`.
#[test]
fn an_infinite_limit_is_named_as_such() {
    let args: Value = serde_json::from_str(r#"{"limit":1e999}"#).unwrap();
    let schema = &listing()[0]["inputSchema"];
    assert_eq!(
        Some(format!(
            "{REFUSAL}sessions_recent: Invalid input: expected number, received Infinity at limit"
        )),
        refusal("sessions_recent", schema, args.as_object())
    );
}
