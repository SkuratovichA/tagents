//! The four tools against the node server: every call the vectors hold, answered by the Rust tools over the same documents, with the same text, the same failure flag and the same events in the usage store. The sessions tools are checked against the bytes the node CLI recorded.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::{fs, os::unix::fs::PermissionsExt, path::Path};

use okb::knowledge::{paths::Env, tools::KnowledgeTools};
use rusqlite::{Connection, OpenFlags};
use serde_json::{Map, Value, json};
use tagents_core::{
    ending::Stop,
    mcp::{rpc::CallResult, server::Tools},
};

use common::{
    knowledge::{vectors, write_file, write_files},
    scratch,
};

/// The fixed clock of the vectors: 2026-10-31T12:00:00Z.
const NOW: i64 = 1_793_448_000_000;

fn clock() -> i64 {
    NOW
}

fn call(tools: &KnowledgeTools, tool: &str, args: Option<&Value>) -> CallResult {
    tools
        .call(tool, args.and_then(Value::as_object), &Stop::default())
        .unwrap_or_else(|| panic!("no answer for {tool}"))
}

/// The documents of the vectors need a user the permissions bind.
fn is_root() -> bool {
    rustix::process::geteuid().is_root()
}

/// The events of a usage store in the order they were written, from the `seen`th on.
fn events_since(usage: &Path, seen: &mut usize) -> Vec<Value> {
    if !usage.exists() {
        return Vec::new();
    }
    let db = Connection::open_with_flags(usage, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    let mut statement = db
        .prepare("select ts, doc_id, heading, kind, caller from usage_events order by rowid")
        .unwrap();
    let rows: Vec<Value> = statement
        .query_map([], |row| {
            assert_eq!(
                NOW,
                row.get::<_, i64>(0)?,
                "an event is not at the fixed clock"
            );
            Ok(json!({
                "docId": row.get::<_, String>(1)?,
                "heading": row.get::<_, String>(2)?,
                "kind": row.get::<_, String>(3)?,
                "caller": row.get::<_, Option<String>>(4)?,
            }))
        })
        .unwrap()
        .map(Result::unwrap)
        .collect();
    let fresh = rows[*seen..].to_vec();
    *seen = rows.len();
    fresh
}

/// The environment the corpora and the battery of the vectors ran under: a folder, an index and a store of their own.
fn corpus_env(dir: &Path) -> Env {
    Env {
        home: dir.to_str().unwrap().into(),
        cwd: dir.to_str().unwrap().into(),
        tagents_config_dir: Some(dir.join("config").to_str().unwrap().into()),
        knowledge_dir: Some(dir.join("folder").to_str().unwrap().into()),
        knowledge_db: Some(dir.join("index.sqlite").to_str().unwrap().into()),
        knowledge_usage_db: Some(dir.join("usage.sqlite").to_str().unwrap().into()),
        ..Env::default()
    }
}

#[test]
fn every_call_over_the_corpora_is_answered_as_node_answered_it() {
    let corpora = vectors()["corpus"]["corpora"].as_array().unwrap();
    assert_eq!(3, corpora.len());
    let (mut calls, mut with_events, mut failures) = (0, 0, 0);
    for corpus in corpora {
        let name = corpus["name"].as_str().unwrap();
        let dir = scratch(&format!("knowledge-tools-{name}"));
        write_files(&dir.join("folder"), &corpus["files"]);
        let folder = dir.join("folder").to_str().unwrap().to_string();
        let usage = dir.join("usage.sqlite");
        let (mut tools, mut seen) = (None::<(String, KnowledgeTools)>, 0);
        let mut locked = None;
        for item in corpus["calls"].as_array().unwrap() {
            if let Some(file) = item["chmod"].as_str() {
                if is_root() {
                    break;
                }
                let path = dir.join("folder").join(file);
                fs::set_permissions(&path, fs::Permissions::from_mode(0o000)).unwrap();
                locked = Some(path);
                tools = None;
                continue;
            }
            let client = item["client"].as_str().unwrap();
            if tools.as_ref().is_none_or(|(had, _)| had != client) {
                let fresh = KnowledgeTools::new(corpus_env(&dir), clock);
                fresh.connected(client);
                tools = Some((client.to_string(), fresh));
            }
            let tool = item["tool"].as_str().unwrap();
            let result = call(&tools.as_ref().unwrap().1, tool, Some(&item["args"]));
            let want = match item["whole"].as_str() {
                Some(file) => corpus["files"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|f| f["name"] == file)
                    .unwrap()["text"]
                    .as_str()
                    .unwrap()
                    .to_string(),
                None => item["text"].as_str().unwrap().replace("<dir>", &folder),
            };
            let what = format!("{name}: {tool} {}", item["args"]);
            assert_eq!(
                item["isError"].as_bool().unwrap(),
                result.is_error(),
                "{what}"
            );
            assert_eq!(want, result.body(), "{what}");
            let events = events_since(&usage, &mut seen);
            assert_eq!(item["events"], Value::Array(events), "{what}: events");
            calls += 1;
            with_events += usize::from(!item["events"].as_array().unwrap().is_empty());
            failures += usize::from(result.is_error());
        }
        if let Some(path) = locked {
            fs::set_permissions(path, fs::Permissions::from_mode(0o644)).unwrap();
        }
    }
    // A replay that skipped its calls proves nothing.
    assert!(
        calls >= 600 && with_events >= 400 && failures >= 50,
        "{calls} calls, {with_events} with events, {failures} failures"
    );
}

fn folder_names(dir: &Path) -> Vec<String> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

/// The environment of a scenario: `HOME` and `TAGENTS_CONFIG_DIR` unless it says otherwise, a null value leaving the name out, and `<dir>` for the scratch directory.
fn scenario_env(dir: &Path, vars: &Map<String, Value>) -> Env {
    let text = dir.to_str().unwrap();
    let mut env = Env {
        home: text.into(),
        cwd: format!("{text}/cwd"),
        tagents_config_dir: Some(format!("{text}/config")),
        ..Env::default()
    };
    for (name, value) in vars {
        let value = value.as_str().map(|v| v.replace("<dir>", text));
        match name.as_str() {
            "TAGENTS_CONFIG_DIR" => env.tagents_config_dir = value,
            "XDG_CONFIG_HOME" => env.xdg_config_home = value,
            "TAGENTS_KNOWLEDGE_DIR" => env.knowledge_dir = value,
            "TAGENTS_KNOWLEDGE_DB" => env.knowledge_db = value,
            "TAGENTS_KNOWLEDGE_USAGE_DB" => env.knowledge_usage_db = value,
            other => panic!("a scenario sets {other}, which the environment does not model"),
        }
    }
    env
}

#[test]
fn where_the_folder_the_index_and_the_store_are_is_what_node_works_out() {
    let scenarios = vectors()["tools"]["scenarios"].as_array().unwrap();
    assert!(scenarios.len() >= 30, "{} scenarios", scenarios.len());
    let mut steps = 0;
    for (n, scenario) in scenarios.iter().enumerate() {
        let name = scenario["name"].as_str().unwrap();
        let dir = scratch(&format!("knowledge-tools-scenario-{n}"));
        let text = dir.to_str().unwrap();
        fs::create_dir_all(dir.join("cwd")).unwrap();
        fs::create_dir_all(dir.join("config")).unwrap();
        let folder = scenario["folder"].as_str().map(|f| dir.join(f));
        if let (Some(folder), true) = (&folder, scenario["files"].is_array()) {
            write_files(folder, &scenario["files"]);
        }
        if let Some(config) = scenario["config"].as_str() {
            fs::write(
                dir.join("config/config.toml"),
                config.replace("<dir>", text),
            )
            .unwrap();
        }
        for (file, body) in scenario["extra"].as_object().into_iter().flatten() {
            let path = dir.join(file);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, body.as_str().unwrap()).unwrap();
        }
        let tools = KnowledgeTools::new(
            scenario_env(&dir, scenario["env"].as_object().unwrap()),
            clock,
        );
        tools.connected("knowledge-vectors");
        for step in scenario["steps"].as_array().unwrap() {
            steps += 1;
            if let Some(request) = step["call"].as_object() {
                let tool = request["tool"].as_str().unwrap();
                let result = call(&tools, tool, Some(&request["args"]));
                let what = format!("{name}: {tool} {}", request["args"]);
                assert_eq!(
                    step["isError"].as_bool().unwrap(),
                    result.is_error(),
                    "{what}"
                );
                assert_eq!(
                    step["text"].as_str().unwrap().replace("<dir>", text),
                    result.body(),
                    "{what}"
                );
            } else if let Some(write) = step["write"].as_object() {
                write_file(
                    folder.as_ref().unwrap(),
                    write["name"].as_str().unwrap(),
                    write["text"].as_str().unwrap(),
                    write["mtimeSec"].as_u64().unwrap(),
                );
            } else if let Some(file) = step["remove"].as_str() {
                fs::remove_file(folder.as_ref().unwrap().join(file)).unwrap();
            } else {
                let listed = match step["ls"].as_str().unwrap() {
                    "cwd" => dir.join("cwd"),
                    "config" => dir.join("config"),
                    _ => dir.join("db"),
                };
                assert_eq!(
                    step["entries"],
                    json!(folder_names(&listed)),
                    "{name}: ls {}",
                    step["ls"]
                );
            }
        }
    }
    assert!(steps >= 65, "{steps} steps");
}

#[test]
fn every_call_of_the_battery_the_loop_hands_to_a_tool_is_answered_as_node_answered_it() {
    let dir = scratch("knowledge-tools-sdk");
    fs::create_dir_all(dir.join("folder")).unwrap();
    let tools = KnowledgeTools::new(corpus_env(&dir), clock);
    tools.connected("knowledge-vectors");
    let (mut replayed, mut told_no, mut unknown) = (0, 0, 0);
    for entry in vectors()["process"]["sdk"].as_array().unwrap() {
        let Some(params) = entry["params"].as_object() else {
            continue;
        };
        let Some(name) = params.get("name").and_then(Value::as_str) else {
            continue;
        };
        // An arguments value that is not an object is refused by the loop, before a tool is asked.
        let args = match params.get("arguments") {
            None => None,
            Some(args) if args.is_object() => Some(args),
            Some(_) => continue,
        };
        let result = call(&tools, name, args);
        let want = &entry["response"]["result"];
        let got = serde_json::to_value(&result).unwrap();
        assert_eq!(want, &got, "{}", entry["name"]);
        replayed += 1;
        told_no += usize::from(result.is_error());
        unknown += usize::from(result.body().ends_with(" not found"));
    }
    assert!(
        replayed >= 90 && told_no >= 80 && unknown >= 5,
        "{replayed} calls, {told_no} failures, {unknown} unknown tools"
    );
}

#[test]
fn a_list_of_the_tools_is_what_the_server_announces() {
    let tools = KnowledgeTools::new(Env::default(), clock);
    let listed = tools.list();
    assert_eq!(
        vec![
            "knowledge_search",
            "knowledge_get",
            "knowledge_list",
            "knowledge_usage",
        ],
        listed
            .iter()
            .map(|t| t["name"].as_str().unwrap())
            .collect::<Vec<_>>()
    );
}
