//! Two copies that must not drift, pinned against their originals.
//!
//! The limits of the Rust server are those of the node server (`packages/mcp/src/run.ts`, `main.ts`), which stays in the tree as the oracle `tests/rust-mcp-parity.sh` compares with: the constants are read from those files. And the `tagents-core` program of the bundled `contract.json`, which `tagents-core mcp` serves, is the one `tagents_spec::Spec::bundled()` describes, so the data file the front door reads and the contract the plugin ships say the same about every verb.

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

/// The value of `const NAME = <integer> * <integer> ...;` in TypeScript source: a product of integers, which is all the limits are written as.
fn ts_constant(source: &str, name: &str) -> Result<u64, String> {
    let head = format!("const {name} = ");
    let line = source
        .lines()
        .find_map(|line| line.split_once(head.as_str()).map(|(_, rest)| rest))
        .ok_or_else(|| format!("no `{head}` in the file"))?;
    let expression = line
        .split_once(';')
        .ok_or_else(|| format!("`{head}` is not ended by a semicolon"))?
        .0;
    expression.split('*').try_fold(1u64, |product, factor| {
        let factor: u64 = factor
            .trim()
            .parse()
            .map_err(|_| format!("`{head}{expression}` is not a product of integers"))?;
        Ok(product * factor)
    })
}

fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap()
}

#[test]
fn a_constant_that_is_missing_or_not_a_product_of_integers_is_an_error() {
    assert_eq!(ts_constant("export const A = 2 * 1024;", "A"), Ok(2048));
    assert_eq!(
        ts_constant("const A_MS = 5 * 60 * 1000;\n", "A_MS"),
        Ok(300_000)
    );
    assert!(ts_constant("const A = 1;", "B").is_err());
    assert!(ts_constant("const A = 1 + 2;", "A").is_err());
    assert!(ts_constant("const A = 1", "A").is_err());
}

#[test]
fn the_limits_are_those_of_the_node_server() {
    let run = repo_file("packages/mcp/src/run.ts");
    let main = repo_file("packages/mcp/src/main.ts");
    let read = |source: &str, name: &str| ts_constant(source, name).unwrap();

    assert_eq!(
        MAX_STREAM as u64,
        read(&run, "MAX_STREAM"),
        "run.ts MAX_STREAM"
    );
    assert_eq!(
        millis(KILL_GRACE),
        read(&run, "KILL_GRACE_MS"),
        "run.ts KILL_GRACE_MS"
    );
    assert_eq!(millis(DRAIN), read(&run, "DRAIN_MS"), "run.ts DRAIN_MS");
    assert_eq!(
        millis(CALL_TIMEOUT),
        read(&main, "CALL_TIMEOUT_MS"),
        "main.ts CALL_TIMEOUT_MS"
    );
    assert_eq!(
        millis(KILL_GRACE),
        read(&main, "KILL_GRACE_MS"),
        "main.ts KILL_GRACE_MS"
    );
    assert_eq!(
        millis(SHUTDOWN_MARGIN),
        read(&main, "SHUTDOWN_MARGIN_MS"),
        "main.ts SHUTDOWN_MARGIN_MS"
    );
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
        ["mcp", "notify run"],
        "the verbs that serve are the MCP server and the notify service"
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
