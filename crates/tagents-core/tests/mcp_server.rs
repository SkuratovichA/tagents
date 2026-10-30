//! The server as a client starts it: `tagents-core mcp --contract <file>` on stdio.
//!
//! The ports of `packages/mcp/test/{server,smoke,registration}.test.ts` and of the process-level half of `process.test.ts`, plus what only a process can show: stdout holds JSON-RPC lines and nothing else, the ending by stdin or by signal, the limits through the wire. The programs behind the tools are shell scripts in a directory that is the whole PATH (`common::rig`); only the smoke test runs the real contract, with the node CLI of this checkout behind `tagents-core`.
//!
//! The spawn of the server goes through the fork gate; nothing else here holds it, so a test may wait on its server as long as it needs.

// Test code: a failed unwrap here is the failure report.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::{
    ffi::{OsStr, OsString},
    fs,
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, ExitStatus, Stdio},
    sync::mpsc::{self, Receiver},
    thread,
    time::{Duration, Instant},
};

use rustix::process::{Pid, Signal, kill_process};
use serde_json::{Value, json};
use tagents_core::mcp::run::MAX_STREAM;

mod common;
use common::{
    REPO,
    rig::{Rig, WITH_GRANDCHILD, alive, escapee_program, has_perl, until},
    run, scratch, start, write_executable,
};

const BIN: &str = env!("CARGO_BIN_EXE_tagents-core");

/// A server process and the client side of its pipes.
struct Session {
    child: Child,
    stdin: Option<ChildStdin>,
    lines: Receiver<String>,
    /// Every line the server wrote, in order.
    raw: Vec<String>,
    /// The messages not yet taken by `reply`.
    seen: Vec<Value>,
}

impl Session {
    /// The server on `contract`, with exactly the environment given.
    fn start(contract: &Path, env: &[(&str, &OsStr)]) -> Session {
        let mut child = start(
            Command::new(BIN)
                .args(["mcp", "--contract"])
                .arg(contract)
                .env_clear()
                .envs(env.iter().copied())
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::null()),
        );
        let stdout = child.stdout.take().unwrap();
        let (sender, lines) = mpsc::channel();
        thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if sender.send(line).is_err() {
                    break;
                }
            }
        });
        Session {
            stdin: child.stdin.take(),
            child,
            lines,
            raw: Vec::new(),
            seen: Vec::new(),
        }
    }

    /// The server of a rig: its directory is the PATH.
    fn of(rig: &Rig) -> Session {
        Session::start(&rig.contract(), &[("PATH", &rig.path())])
    }

    fn send(&mut self, message: &Value) {
        let stdin = self.stdin.as_mut().expect("stdin is open");
        writeln!(stdin, "{message}").unwrap();
        stdin.flush().unwrap();
    }

    fn request(&mut self, id: i64, method: &str, params: &Value) {
        self.send(&json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
    }

    fn call(&mut self, id: i64, name: &str, arguments: &Value) {
        self.request(
            id,
            "tools/call",
            &json!({"name": name, "arguments": arguments}),
        );
    }

    /// The handshake of a client, which answers with the server's `serverInfo`.
    fn initialize(&mut self) -> Value {
        self.request(
            1,
            "initialize",
            &json!({"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "0.0.0"}}),
        );
        let answer = self.reply(1);
        self.send(&json!({"jsonrpc": "2.0", "method": "notifications/initialized"}));
        answer
    }

    fn read(&mut self, wait: Duration) -> bool {
        let Ok(line) = self.lines.recv_timeout(wait) else {
            return false;
        };
        let message = serde_json::from_str(&line)
            .unwrap_or_else(|e| panic!("stdout holds a line that is not JSON: {line:?}: {e}"));
        self.raw.push(line);
        self.seen.push(message);
        true
    }

    /// The answer to request `id`, within ten seconds.
    fn reply(&mut self, id: i64) -> Value {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Some(at) = self.seen.iter().position(|m| m["id"] == json!(id)) {
                return self.seen.remove(at);
            }
            let left = deadline.saturating_duration_since(Instant::now());
            assert!(self.read(left), "no answer to {id}; seen {:?}", self.seen);
        }
    }

    /// Whether the server wrote anything for `id` within `wait`.
    fn answers(&mut self, id: i64, wait: Duration) -> bool {
        let deadline = Instant::now() + wait;
        loop {
            if self.seen.iter().any(|m| m["id"] == json!(id)) {
                return true;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() || !self.read(left) {
                return false;
            }
        }
    }

    fn close_stdin(&mut self) {
        self.stdin = None;
    }

    fn signal(&self, signal: Signal) {
        let pid = Pid::from_raw(i32::try_from(self.child.id()).unwrap()).unwrap();
        kill_process(pid, signal).unwrap();
    }

    /// The exit status, if the server left within `wait`.
    fn exit(&mut self, wait: Duration) -> Option<ExitStatus> {
        let deadline = Instant::now() + wait;
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                return Some(status);
            }
            if Instant::now() >= deadline {
                return None;
            }
            thread::sleep(Duration::from_millis(25));
        }
    }

    /// Everything the server wrote up to its end.
    fn drain(&mut self) {
        while self.read(Duration::from_secs(5)) {}
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn result_text(reply: &Value) -> &str {
    reply["result"]["content"][0]["text"].as_str().unwrap()
}

fn call_body(reply: &Value) -> Value {
    serde_json::from_str(result_text(reply)).unwrap()
}

const WAIT: Duration = Duration::from_secs(5);

// server.test.ts

const SHOW_CONTRACT: &str = r#"{"cli":{"tagents-fake":{"exit":{"ok":0,"error":1,"usage":2,"refused":3},"commands":[
{"path":["show"],"positionals":["<id>"],"options":{},"required":[],"summary":"prints one thing","effect":"read"},
{"path":["forget"],"positionals":["<id>"],"options":{},"required":[],"summary":"removes one thing","effect":"destructive"}]}}}"#;

fn show_session(name: &str) -> (Rig, Session) {
    let rig = Rig::new(name, r#"printf '{"args":"%s"}' "$*""#);
    let contract = rig.dir.join("show.json");
    fs::write(&contract, SHOW_CONTRACT).unwrap();
    let mut session = Session::start(&contract, &[("PATH", &rig.path())]);
    session.initialize();
    (rig, session)
}

#[test]
fn a_client_lists_one_tool_per_verb_with_the_hints_of_its_effect() {
    let (_rig, mut session) = show_session("server_list");
    session.request(2, "tools/list", &json!({}));
    let listed = session.reply(2);
    let tools = listed["result"]["tools"].as_array().unwrap();
    let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["fake_forget", "fake_show"]);
    let show = &tools[1];
    assert_eq!(
        show["annotations"],
        json!({"readOnlyHint": true, "openWorldHint": false})
    );
    assert_eq!(show["description"], json!("Prints one thing."));
    assert_eq!(show["inputSchema"]["required"], json!(["id"]));
}

#[test]
fn a_call_runs_the_verb_and_answers_with_its_result() {
    let (_rig, mut session) = show_session("server_call");
    session.call(2, "fake_show", &json!({"id": "abc"}));
    let reply = session.reply(2);
    assert_ne!(reply["result"]["isError"], json!(true));
    assert_eq!(call_body(&reply)["stdout"], json!({"args": "show abc"}));
}

#[test]
fn a_call_for_a_tool_that_does_not_exist_is_a_protocol_error_not_a_result() {
    let (_rig, mut session) = show_session("server_unknown_tool");
    session.call(2, "fake_nothing", &json!({}));
    let reply = session.reply(2);
    assert_eq!(reply.get("result"), None);
    assert_eq!(reply["error"]["code"], json!(-32602));
    assert!(
        reply["error"]["message"]
            .as_str()
            .unwrap()
            .contains("fake_nothing")
    );
}

// smoke.test.ts

/// The directory of the `node` on PATH, if there is one and the workspace has its node dependencies installed: the CLI this test calls runs from its TypeScript sources and imports them.
fn node_dir() -> Option<PathBuf> {
    if !Path::new(REPO).join("node_modules").is_dir() {
        return None;
    }
    std::env::split_paths(&std::env::var_os("PATH")?).find(|dir| dir.join("node").is_file())
}

#[test]
fn tools_list_is_the_list_the_contract_records_and_a_read_only_tool_answers_against_scratch_state()
{
    let root = Path::new(REPO).canonicalize().unwrap();
    let contract = root.join("contract.json");
    let scratch = scratch("smoke");
    let bin = scratch.join("bin");
    let node = node_dir();
    if let Some(node) = &node {
        write_executable(
            &bin.join("tagents-core"),
            &format!(
                "#!/bin/sh\nexec {}/node {}/packages/core/src/cli/main.ts \"$@\"\n",
                node.display(),
                root.display()
            ),
        );
    }
    let mut path = bin.clone().into_os_string();
    path.push(":");
    path.push(node.as_deref().unwrap_or(Path::new("")));
    path.push(":/usr/bin:/bin");
    let config = scratch.join("config");
    let state = scratch.join("state");
    let mut session = Session::start(
        &contract,
        &[
            ("PATH", &path),
            ("HOME", scratch.as_os_str()),
            ("TAGENTS_CONFIG_DIR", config.as_os_str()),
            ("TA_STATE_DIR", state.as_os_str()),
        ],
    );
    session.initialize();
    session.request(2, "tools/list", &json!({}));
    let listed = session.reply(2);

    let recorded: Value = serde_json::from_str(&fs::read_to_string(&contract).unwrap()).unwrap();
    let wanted = &recorded["mcp"]["tagents"]["tools"];
    let fields = |tools: &Value| -> Vec<String> {
        tools
            .as_array()
            .unwrap()
            .iter()
            .map(|t| {
                json!({"name": t["name"], "description": t["description"], "inputSchema": t["inputSchema"], "annotations": t["annotations"]}).to_string()
            })
            .collect()
    };
    // Compared as text: the order of the properties is part of what a client sees.
    assert_eq!(fields(&listed["result"]["tools"]), fields(wanted));

    if node.is_none() {
        eprintln!(
            "no node on PATH, or no node_modules (run pnpm install): the call half of the smoke test is skipped"
        );
        return;
    }
    session.call(3, "core_plugin_list", &json!({"json": true}));
    let reply = session.reply(3);
    assert_ne!(reply["result"]["isError"], json!(true), "{reply}");
    let body = call_body(&reply);
    assert_eq!(body["exit"], json!(0));
    assert_eq!(body["outcome"], json!("ok"));
}

// registration.test.ts

fn registered_entry() -> (Value, Value) {
    let manifest: Value = serde_json::from_str(
        &fs::read_to_string(Path::new(REPO).join(".claude-plugin/plugin.json")).unwrap(),
    )
    .unwrap();
    let server = &manifest["mcpServers"]["tagents"];
    assert!(server.is_object(), "plugin.json has no mcpServers.tagents");
    (server["command"].clone(), server["args"].clone())
}

#[test]
fn plugin_json_registers_the_server_as_tagents_mcp_reading_the_contract_json_that_ships_with_the_plugin()
 {
    let (command, args) = registered_entry();
    assert_eq!(command, json!("tagents-mcp"));
    assert_eq!(
        args,
        json!(["--contract", "${CLAUDE_PLUGIN_ROOT}/contract.json"])
    );
}

#[test]
fn the_command_the_manifest_names_is_the_bin_this_package_declares() {
    let package: Value = serde_json::from_str(
        &fs::read_to_string(Path::new(REPO).join("packages/mcp/package.json")).unwrap(),
    )
    .unwrap();
    let bins: Vec<&String> = package["bin"].as_object().unwrap().keys().collect();
    assert_eq!(vec![registered_entry().0.as_str().unwrap()], bins);
}

// process.test.ts, the half that needs the server as a process

/// The server with a call in flight once the program and its helper have written their pids.
fn call_in_flight(name: &str) -> (Rig, Session) {
    let rig = Rig::new(name, WITH_GRANDCHILD);
    let mut session = Session::of(&rig);
    session.initialize();
    session.call(2, "fake_hang", &json!({}));
    assert!(rig.started(2), "the program and its sleep started");
    (rig, session)
}

#[test]
fn over_mcp_a_request_the_client_cancels_stops_the_program_it_started_and_gets_no_answer() {
    let (rig, mut session) = call_in_flight("server_cancel");
    session.send(
        &json!({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 2, "reason": "test"}}),
    );
    assert!(rig.none_alive(), "both processes are gone");
    assert!(
        !session.answers(2, Duration::from_millis(500)),
        "a cancelled request is not answered"
    );
    session.request(3, "ping", &json!({}));
    assert_eq!(session.reply(3)["result"], json!({}));
}

#[test]
fn with_a_call_in_flight_and_stdin_closed_the_program_it_started_is_gone_within_seconds_and_so_is_the_server()
 {
    let (rig, mut session) = call_in_flight("server_stdin_closed");
    session.close_stdin();
    assert!(rig.none_alive(), "both processes are gone");
    let status = session.exit(WAIT).expect("the server exited");
    assert_eq!(status.code(), Some(0));
    // The call still answers, as cancelled, before the server leaves.
    session.drain();
    let reply = session.reply(2);
    assert_eq!(call_body(&reply)["outcome"], json!("cancelled"));
}

fn signal_stops_the_call_in_flight(name: &str, signal: Signal) {
    let (rig, mut session) = call_in_flight(name);
    session.signal(signal);
    assert!(rig.none_alive(), "both processes are gone");
    let status = session.exit(WAIT).expect("the server exited");
    assert_eq!(status.code(), Some(0));
    // The call still answers, as cancelled, before the server leaves.
    session.drain();
    let reply = session.reply(2);
    assert_eq!(call_body(&reply)["outcome"], json!("cancelled"));
}

#[test]
fn sigterm_stops_the_program_of_a_call_in_flight_and_the_server_exits() {
    signal_stops_the_call_in_flight("server_sigterm", Signal::TERM);
}

#[test]
fn sigint_stops_the_program_of_a_call_in_flight_and_the_server_exits() {
    signal_stops_the_call_in_flight("server_sigint", Signal::INT);
}

#[test]
fn sighup_stops_the_program_of_a_call_in_flight_and_the_server_exits() {
    signal_stops_the_call_in_flight("server_sighup", Signal::HUP);
}

#[test]
fn a_second_signal_during_the_ending_does_not_cut_it_short() {
    let rig = Rig::new(
        "server_second_sigterm",
        r#"trap '' TERM; echo $$ > "$D/main.pid"; while :; do sleep 1; done"#,
    );
    let mut session = Session::of(&rig);
    session.initialize();
    session.call(2, "fake_hang", &json!({}));
    assert!(rig.started(1), "the program started");
    let started = Instant::now();
    // The first signal starts the ending, which the program that ignores SIGTERM keeps busy for the whole grace.
    session.signal(Signal::TERM);
    thread::sleep(Duration::from_millis(300));
    session.signal(Signal::TERM);
    let status = session
        .exit(Duration::from_secs(10))
        .expect("the server ended");
    assert_eq!(
        status.code(),
        Some(0),
        "by its own exit after the ending, not by the second signal"
    );
    assert!(
        started.elapsed() >= Duration::from_millis(1900),
        "only after the grace of 2 s: the second signal did not cut the ending short"
    );
    assert!(
        until(|| rig.none_alive(), 2000),
        "the program that ignores SIGTERM got its SIGKILL"
    );
}

// What only a process can show.

#[test]
fn stdout_carries_json_rpc_lines_and_nothing_else() {
    // A program that is loud on both streams, and requests that are wrong in every way a line can be.
    let rig = Rig::new(
        "server_stdout",
        r#"echo "plain text on stdout"; echo "and on stderr" >&2; echo '{"not":"jsonrpc"}'"#,
    );
    let mut session = Session::of(&rig);
    session.initialize();
    session.request(2, "tools/list", &json!({}));
    session.call(3, "fake_echo", &json!({"text": "x"}));
    session.call(4, "fake_echo", &json!({"nope": 1}));
    session.request(5, "no/such/method", &json!({}));
    session.send(
        &json!({"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"arguments": {}}}),
    );
    session
        .stdin
        .as_mut()
        .unwrap()
        .write_all(b"this is not json\n\n[1,2]\n")
        .unwrap();
    session.request(7, "ping", &json!({}));
    let replies: Vec<Value> = (2..=7).map(|id| session.reply(id)).collect();
    session.close_stdin();
    assert!(session.exit(WAIT).is_some());
    session.drain();
    // The program's own output is inside the answer to its call, as a string, and nowhere else; the lines that are not requests got no line of their own.
    assert_eq!(session.raw.len(), 7, "{:?}", session.raw);
    for line in &session.raw {
        let message: Value = serde_json::from_str(line).unwrap();
        assert_eq!(message["jsonrpc"], json!("2.0"), "{line}");
    }
    let loud = call_body(&replies[1]);
    assert!(
        loud["stdout"]
            .as_str()
            .unwrap()
            .starts_with("plain text on stdout\n")
    );
}

#[test]
fn a_failure_to_start_is_a_message_on_stderr_and_a_code_and_never_a_byte_on_stdout() {
    let dir = scratch("server_start_failure");
    let broken = dir.join("broken.json");
    fs::write(&broken, "{").unwrap();
    let missing = dir.join("missing.json");
    let cases: Vec<(Vec<OsString>, i32, String)> = vec![
        (
            vec!["mcp".into()],
            2,
            "usage: tagents-core mcp --contract <contract.json>\n".into(),
        ),
        (
            vec!["mcp".into(), "--contract".into(), missing.clone().into()],
            1,
            format!(
                "tagents-core mcp: cannot read the contract {}: No such file or directory (os error 2)\n",
                missing.display()
            ),
        ),
        (
            vec!["mcp".into(), "--contract".into(), broken.into()],
            1,
            "tagents-core mcp: the contract is not JSON: EOF while parsing an object at line 1 column 1\n".into(),
        ),
    ];
    for (args, code, stderr) in cases {
        let out = run(Command::new(BIN)
            .env_clear()
            .args(&args)
            .stdin(Stdio::null()));
        assert_eq!(out.status.code(), Some(code), "{args:?}");
        assert_eq!(out.stdout, b"", "{args:?}");
        assert_eq!(String::from_utf8_lossy(&out.stderr), stderr, "{args:?}");
    }
}

#[test]
fn output_over_the_cap_comes_back_as_one_line_with_the_marker() {
    let rig = Rig::new(
        "server_cap",
        &format!(r"head -c {} /dev/zero | tr '\0' a", MAX_STREAM + 10),
    );
    let mut session = Session::of(&rig);
    session.initialize();
    session.call(2, "fake_echo", &json!({}));
    let body = call_body(&session.reply(2));
    assert_eq!(body["truncated"], json!(true));
    let stdout = body["stdout"].as_str().unwrap();
    assert_eq!(
        stdout,
        format!(
            "{}\n[output cut at {MAX_STREAM} bytes]",
            "a".repeat(MAX_STREAM)
        )
    );
}

#[test]
fn a_verb_that_needs_tmux_is_refused_unless_the_server_runs_inside_one() {
    let rig = Rig::new("server_tmux", r#"touch "$0.ran""#);
    let mut outside = Session::of(&rig);
    outside.initialize();
    outside.call(2, "fake_window", &json!({}));
    let refused = outside.reply(2);
    assert_eq!(refused["result"]["isError"], json!(true));
    assert_eq!(call_body(&refused)["outcome"], json!("refused"));
    assert!(!rig.dir.join("tagents-fake.ran").exists());

    let mut inside = Session::start(
        &rig.contract(),
        &[
            ("PATH", &rig.path()),
            ("TMUX", OsStr::new("/tmp/tmux-1/default,1,0")),
        ],
    );
    inside.initialize();
    inside.call(2, "fake_window", &json!({}));
    assert_ne!(inside.reply(2)["result"]["isError"], json!(true));
    assert!(until(|| rig.dir.join("tagents-fake.ran").exists(), 2000));
}

#[test]
fn a_program_missing_from_path_is_an_error_result_that_says_which_one() {
    let rig = Rig::new("server_missing_program", "exit 0");
    let empty = scratch("server_missing_program_path");
    let mut session = Session::start(&rig.contract(), &[("PATH", empty.as_os_str())]);
    session.initialize();
    session.call(2, "fake_echo", &json!({}));
    let reply = session.reply(2);
    assert_eq!(reply["result"]["isError"], json!(true));
    let body = call_body(&reply);
    assert_eq!(body["outcome"], json!("error"));
    assert_eq!(body["stderr"], json!("tagents-fake is not on PATH\n"));
}

#[test]
fn a_holder_of_the_pipes_that_left_the_group_does_not_hold_the_call_longer_than_the_drain() {
    if !has_perl() {
        return;
    }
    let rig = Rig::new(
        "server_escapee",
        &escapee_program(r#"exec "sleep", "30""#, "echo done"),
    );
    let mut session = Session::of(&rig);
    session.initialize();
    let started = Instant::now();
    session.call(2, "fake_echo", &json!({}));
    let reply = session.reply(2);
    assert!(
        started.elapsed() < Duration::from_millis(250 + 10_000),
        "long before the holder's 30 s"
    );
    assert_eq!(call_body(&reply)["stdout"], json!("done\n"));
    // The escapee is out of the group, so the call could not stop it; the rig's drop does.
    assert!(until(|| rig.pids().len() == 1, 1000));
    assert!(
        alive(rig.pids()["escaped"]),
        "the escapee left the group, so the call could not stop it"
    );
    // The server still answers, and its own end is not held by the escapee either.
    session.request(3, "ping", &json!({}));
    session.reply(3);
    session.close_stdin();
    assert!(session.exit(WAIT).is_some(), "the server exited");
}

#[test]
fn calls_run_side_by_side_and_answer_in_the_order_they_finish() {
    let rig = Rig::new(
        "server_concurrent",
        r#"if [ "$2" = slow ]; then sleep 1; fi; printf '%s' "$2""#,
    );
    let mut session = Session::of(&rig);
    session.initialize();
    session.call(2, "fake_echo", &json!({"text": "slow"}));
    session.call(3, "fake_echo", &json!({"text": "fast"}));
    // The fast one is first on the wire although it was asked second.
    session.read(WAIT);
    assert_eq!(session.seen[0]["id"], json!(3));
    assert_eq!(call_body(&session.reply(3))["stdout"], json!("fast"));
    assert_eq!(call_body(&session.reply(2))["stdout"], json!("slow"));
}
