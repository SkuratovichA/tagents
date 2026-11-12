//! Two copies that must not drift, pinned against their originals.
//!
//! The limits of the Rust server are those of the node server that `tests/rust-mcp-parity.sh` compares with (the oracle tag, `packages/mcp/src/run.ts` and `main.ts` there): they are written out here. And the `tagents-core` program of the bundled `contract.json`, which `tagents-core mcp` serves, is the one `tagents_spec::Spec::bundled()` describes, so the data file the front door reads and the contract the plugin ships say the same about every verb.

// Test code: a failed unwrap here is the failure report.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::{collections::BTreeMap, fs, path::Path, time::Duration};

use serde_json::Value;
use tagents_core::mcp::{
    contract::{self, Program},
    run::{CALL_TIMEOUT, DRAIN, KILL_GRACE, MAX_STREAM},
    server::SHUTDOWN_MARGIN,
};
use tagents_spec::{Effect, OptionKind, Spec};

mod common;
use common::REPO;

fn repo_file(path: &str) -> String {
    let file = Path::new(REPO).join(path);
    fs::read_to_string(&file).unwrap_or_else(|e| panic!("cannot read {}: {e}", file.display()))
}

/// The limits of the node server `tests/rust-mcp-parity.sh` compares with (tag `v0.6.7`, `packages/mcp/src/run.ts` and `main.ts`), written out: the node source is not in the tree any more, and a limit moved here must move with a reason.
#[test]
fn the_limits_are_those_of_the_node_server() {
    assert_eq!(MAX_STREAM, 256 * 1024, "run.ts MAX_STREAM");
    assert_eq!(
        millis(KILL_GRACE),
        2000,
        "KILL_GRACE_MS of run.ts and main.ts"
    );
    assert_eq!(millis(DRAIN), 250, "run.ts DRAIN_MS");
    assert_eq!(
        millis(CALL_TIMEOUT),
        5 * 60 * 1000,
        "main.ts CALL_TIMEOUT_MS"
    );
    assert_eq!(millis(SHUTDOWN_MARGIN), 2000, "main.ts SHUTDOWN_MARGIN_MS");
}

fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap()
}

fn core_program() -> Program {
    contract::parse(&repo_file("contract.json"))
        .unwrap()
        .into_iter()
        .find(|program| program.name == "tagents-core")
        .expect("contract.json has a tagents-core program")
}

#[test]
fn the_core_program_of_the_contract_is_the_one_the_spec_describes() {
    let spec = Spec::bundled().unwrap();
    let program = core_program();
    assert_eq!(program.name, spec.program);

    let exit: BTreeMap<&str, u64> = program
        .exit
        .iter()
        .map(|(name, code)| (name.as_str(), code.as_u64().unwrap()))
        .collect();
    let wanted: BTreeMap<&str, u64> = spec
        .exit
        .iter()
        .map(|(name, code)| (name.as_str(), u64::from(*code)))
        .collect();
    assert_eq!(exit, wanted, "exit table");

    // The same verbs in the same order.
    let paths = |commands: Vec<&Vec<String>>| commands.into_iter().cloned().collect::<Vec<_>>();
    assert_eq!(
        paths(program.commands.iter().map(|c| &c.path).collect()),
        paths(spec.commands.iter().map(|c| &c.path).collect()),
        "verbs"
    );
    for (got, want) in program.commands.iter().zip(&spec.commands) {
        let at = got.path.join(" ");
        assert_eq!(got.positionals, want.positionals, "{at}: positionals");
        assert_eq!(got.required, want.required, "{at}: required");
        let options: BTreeMap<&str, (OptionKind, bool)> = got
            .options
            .iter()
            .map(|(name, shape)| (name.as_str(), (shape.kind, shape.multiple)))
            .collect();
        let wanted: BTreeMap<&str, (OptionKind, bool)> = want
            .options
            .iter()
            .map(|(name, shape)| (name.as_str(), (shape.kind, shape.multiple.unwrap_or(false))))
            .collect();
        assert_eq!(options, wanted, "{at}: options");
        assert_eq!(got.effect, want.effect, "{at}: effect");
        assert_eq!(got.not_a_tool, want.tool.is_some(), "{at}: tool");
        // The spec has no such keys: the contract may not give the core program any.
        assert!(!got.requires_tmux, "{at}: requires");
        assert!(got.tool_defaults.is_empty(), "{at}: toolDefaults");
    }
    let serving: Vec<String> = program
        .commands
        .iter()
        .filter(|c| c.effect == Some(Effect::Serve))
        .map(|c| c.path.join(" "))
        .collect();
    assert_eq!(
        serving,
        [
            "mcp",
            "notify run",
            "knowledge mcp",
            "knowledge serve",
            "knowledge join"
        ],
        "the verbs that serve are the MCP server, the notify service and the three knowledge servers"
    );
}

#[test]
fn the_bundled_contract_is_json_the_server_reads_whole() {
    // Every program of the file, not only the core one, is accepted: the server starts on the real file.
    let text = repo_file("contract.json");
    let programs = contract::parse(&text).unwrap();
    let json: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(programs.len(), json["cli"].as_object().unwrap().len());
    tagents_core::mcp::tools::tool_specs(&programs).unwrap();
}
