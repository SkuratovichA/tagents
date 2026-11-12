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
    net::Shutdown,
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, ExitStatus, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
        mpsc::{self, Receiver},
    },
    thread,
    time::{Duration, Instant},
};

use rustix::process::{Pid, Signal, kill_process};
use serde_json::{Map, Value, json};
use tagents_core::ending::Stop;
use tagents_core::mcp::rpc::{CallResult, Out};
use tagents_core::mcp::run::MAX_STREAM;
use tagents_core::mcp::server::{Config, Identity, Sdk, Server, Tools};

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
        // libtest captures `eprintln!` of a passing test; a write to the stderr handle is shown.
        let _ = writeln!(
            std::io::stderr(),
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

// The loop as a library, the way the shared knowledge server uses it: a connection is a socket pair, its `Tools` value is its own, and the end of a connection is a function the loop is given.

/// What a connection's tools answer: `probe` tells the client that shook hands and the arguments it got (`null` when the call had none), `hold` waits for its stop, `nope` is an error result and any other name is nobody's.
#[derive(Default)]
struct Probe {
    client: Mutex<Option<String>>,
    held: Mutex<Option<mpsc::Sender<()>>>,
}

impl Tools for Probe {
    fn list(&self) -> Vec<Value> {
        vec![json!({
            "name": "probe",
            "title": "Probe",
            "description": "Says who shook hands.",
            "inputSchema": {"type": "object"},
            "execution": {"taskSupport": "forbidden"}
        })]
    }

    fn connected(&self, client: &str) {
        *self.client.lock().unwrap() = Some(client.to_owned());
    }

    fn call(
        &self,
        name: &str,
        args: Option<&Map<String, Value>>,
        stop: &Stop,
    ) -> Option<CallResult> {
        match name {
            "probe" => Some(CallResult::text(
                json!({"client": *self.client.lock().unwrap(), "arguments": args}).to_string(),
                false,
            )),
            "hold" => {
                let (tx, rx) = mpsc::channel();
                stop.watch(move || {
                    let _ = tx.send(());
                });
                if let Some(held) = self.held.lock().unwrap().take() {
                    let _ = held.send(());
                }
                let _ = rx.recv();
                Some(CallResult::text("stopped".into(), false))
            }
            "nope" => Some(CallResult::text(
                "MCP error -32602: Tool nope not found".into(),
                true,
            )),
            _ => None,
        }
    }
}

/// One connection to a `Server` of this process: the loop reads one end of a socket pair and writes it, the test is the client on the other end. `closed` counts the times the loop asked for the connection to be closed.
struct Link {
    client: UnixStream,
    lines: BufReader<UnixStream>,
    served: thread::JoinHandle<()>,
    closed: Arc<AtomicUsize>,
}

impl Link {
    fn open(identity: Identity, tools: Arc<dyn Tools>) -> Link {
        let (client, server_end) = UnixStream::pair().unwrap();
        client.set_read_timeout(Some(WAIT)).unwrap();
        let closed = Arc::new(AtomicUsize::new(0));
        let (reader, writer, ender) = (
            server_end.try_clone().unwrap(),
            server_end.try_clone().unwrap(),
            server_end,
        );
        // The server reads in ticks, as the daemon does: a lost wakeup of a reader under load is found at the next tick.
        common::shared::ticking(&reader);
        let counted = Arc::clone(&closed);
        let server = Server::new(
            tools,
            Out::new(writer),
            Config {
                identity,
                kill_grace: Duration::from_millis(50),
                shutdown_margin: Duration::from_millis(50),
            },
            move || {
                counted.fetch_add(1, Ordering::SeqCst);
                let _ = ender.shutdown(Shutdown::Both);
            },
        );
        Link {
            lines: BufReader::new(client.try_clone().unwrap()),
            client,
            served: thread::spawn(move || server.serve(common::shared::Ticks(&reader))),
            closed,
        }
    }

    fn send(&mut self, message: &Value) {
        writeln!(self.client, "{message}").unwrap();
    }

    /// The next line the loop wrote, as the bytes it wrote.
    fn raw(&mut self) -> String {
        let mut line = String::new();
        self.lines.read_line(&mut line).unwrap();
        line
    }

    fn reply(&mut self) -> Value {
        let line = self.raw();
        serde_json::from_str(&line).unwrap_or_else(|e| panic!("not JSON: {line:?}: {e}"))
    }

    fn shake_hands(&mut self, client: &str) -> Value {
        self.send(
            &json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": client, "version": "0.0.0"}}}),
        );
        self.reply()
    }

    /// Whether `serve` has returned within `WAIT`.
    fn ended(self) -> bool {
        let ended = until(|| self.served.is_finished(), WAIT.as_millis() as u64);
        if ended {
            self.served.join().unwrap();
        }
        ended
    }

    /// The client goes away entirely: its descriptors close when `self` ends here, and what is left is what the caller watches, the count of closings and the loop's thread. Only that makes a write into the socket fail: after a `shutdown` of a peer that still holds its descriptor, a write succeeds on Darwin.
    fn hang_up(self) -> (Arc<AtomicUsize>, thread::JoinHandle<()>) {
        (self.closed, self.served)
    }
}

const KNOWLEDGE: Identity = Identity {
    name: "tagents-knowledge",
    version: "9.9.9",
    sdk: Sdk::McpServer,
};

#[test]
fn the_identity_and_the_capabilities_of_the_handshake_are_the_configs() {
    let mut knowledge = Link::open(KNOWLEDGE, Arc::new(Probe::default()));
    let answer = knowledge.shake_hands("a-client");
    assert_eq!(
        answer["result"]["serverInfo"],
        json!({"name": "tagents-knowledge", "version": "9.9.9"})
    );
    assert_eq!(
        answer["result"]["capabilities"],
        json!({"tools": {"listChanged": true}})
    );

    let mut plugin = Link::open(Identity::PLUGIN, Arc::new(Probe::default()));
    let answer = plugin.shake_hands("a-client");
    assert_eq!(
        answer["result"]["serverInfo"],
        json!({"name": "tagents", "version": env!("CARGO_PKG_VERSION")})
    );
    assert_eq!(answer["result"]["capabilities"], json!({"tools": {}}));
}

#[test]
fn the_clients_name_reaches_the_tools_of_its_own_connection_at_initialize() {
    let mut first = Link::open(KNOWLEDGE, Arc::new(Probe::default()));
    let mut second = Link::open(KNOWLEDGE, Arc::new(Probe::default()));
    first.shake_hands("claude-code");
    second.shake_hands("codex");
    for (link, name) in [(&mut first, "claude-code"), (&mut second, "codex")] {
        link.send(&json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "probe"}}));
        let body: Value = serde_json::from_str(
            link.reply()["result"]["content"][0]["text"]
                .as_str()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            body["client"],
            json!(name),
            "each connection has its own tools"
        );
    }
}

#[test]
fn a_list_entry_is_a_raw_value_and_goes_out_with_its_keys_in_the_order_it_has() {
    let mut link = Link::open(KNOWLEDGE, Arc::new(Probe::default()));
    link.shake_hands("a-client");
    link.send(&json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}));
    let line = link.raw();
    assert!(
        line.contains(
            r#""tools":[{"name":"probe","title":"Probe","description":"Says who shook hands.","inputSchema":{"type":"object"},"execution":{"taskSupport":"forbidden"}}]"#
        ),
        "{line}"
    );
}

#[test]
fn a_call_without_an_arguments_object_reaches_the_tool_as_none_and_an_empty_object_as_one() {
    let mut link = Link::open(KNOWLEDGE, Arc::new(Probe::default()));
    link.shake_hands("a-client");
    link.send(
        &json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "probe"}}),
    );
    link.send(&json!({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "probe", "arguments": {}}}));
    let mut arguments = std::collections::HashMap::new();
    for _ in 0..2 {
        let reply = link.reply();
        let body: Value =
            serde_json::from_str(reply["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
        arguments.insert(reply["id"].as_i64().unwrap(), body["arguments"].clone());
    }
    assert_eq!(arguments[&2], Value::Null);
    assert_eq!(arguments[&3], json!({}));
}

#[test]
fn a_result_for_an_unknown_tool_goes_out_as_a_result_and_none_is_still_a_protocol_failure() {
    let mut link = Link::open(KNOWLEDGE, Arc::new(Probe::default()));
    link.shake_hands("a-client");
    link.send(
        &json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "nope"}}),
    );
    let reply = link.reply();
    assert_eq!(reply["result"]["isError"], json!(true));
    assert_eq!(
        reply["result"]["content"][0]["text"],
        json!("MCP error -32602: Tool nope not found")
    );
    assert!(reply.get("error").is_none());

    link.send(
        &json!({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "ghost"}}),
    );
    let reply = link.reply();
    assert_eq!(reply["error"]["code"], json!(-32602));
    assert!(reply.get("result").is_none());
}

#[test]
fn a_connection_whose_client_is_gone_is_closed_by_the_function_it_was_given_and_another_connection_goes_on()
 {
    let probe = Arc::new(Probe::default());
    let (held_tx, held) = mpsc::channel();
    *probe.held.lock().unwrap() = Some(held_tx);
    let mut gone = Link::open(KNOWLEDGE, probe);
    let mut other = Link::open(KNOWLEDGE, Arc::new(Probe::default()));
    gone.shake_hands("a-client");
    other.shake_hands("another-client");

    gone.send(
        &json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "hold"}}),
    );
    held.recv_timeout(WAIT).unwrap();
    // The client goes away entirely: the loop stops the call, which answers into a socket nobody reads, and the connection is closed by the function the loop was given.
    let (closed, served) = gone.hang_up();
    assert!(
        until(|| closed.load(Ordering::SeqCst) == 1, 5000),
        "the connection was closed"
    );
    assert!(
        until(|| served.is_finished(), 5000),
        "the loop of the connection ended"
    );

    other.send(&json!({"jsonrpc": "2.0", "id": 2, "method": "ping"}));
    assert_eq!(other.reply()["result"], json!({}));
    assert_eq!(
        other.closed.load(Ordering::SeqCst),
        0,
        "the other connection was not closed"
    );
}

#[test]
fn a_client_that_closes_only_its_write_side_still_gets_the_answer_in_flight_and_then_the_connection_ends()
 {
    let probe = Arc::new(Probe::default());
    let (held_tx, held) = mpsc::channel();
    *probe.held.lock().unwrap() = Some(held_tx);
    let mut link = Link::open(KNOWLEDGE, probe);
    link.shake_hands("a-client");
    link.send(
        &json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "hold"}}),
    );
    held.recv_timeout(WAIT).unwrap();
    link.client.shutdown(Shutdown::Write).unwrap();
    let reply = link.reply();
    assert_eq!(reply["result"]["content"][0]["text"], json!("stopped"));
    let closed = Arc::clone(&link.closed);
    assert!(link.ended(), "the loop ended after the answer");
    assert_eq!(
        closed.load(Ordering::SeqCst),
        0,
        "an end of input is not a write failure"
    );
}

/// What the SDK's `McpServer` answers when the params of a request do not fit its schema: `-32603` and the zod issues as JSON text, all of them, in the order of the schema's keys.
fn zod_issues(issues: &[(&[&str], &str, &str)]) -> String {
    let list: Vec<Value> = issues
        .iter()
        .map(|(path, expected, received)| {
            json!({
                "expected": expected,
                "code": "invalid_type",
                "path": path,
                "message": format!("Invalid input: expected {expected}, received {received}"),
            })
        })
        .collect();
    serde_json::to_string_pretty(&list).unwrap()
}

#[test]
fn a_request_whose_params_do_not_fit_is_refused_with_the_zod_issues_when_the_server_is_an_mcp_server()
 {
    let mut link = Link::open(KNOWLEDGE, Arc::new(Probe::default()));
    let cases: Vec<(&str, Option<Value>, String)> = vec![
        (
            "initialize",
            None,
            zod_issues(&[(&["params"], "object", "undefined")]),
        ),
        (
            "initialize",
            Some(json!({})),
            zod_issues(&[
                (&["params", "protocolVersion"], "string", "undefined"),
                (&["params", "capabilities"], "object", "undefined"),
                (&["params", "clientInfo"], "object", "undefined"),
            ]),
        ),
        (
            "initialize",
            Some(json!({"protocolVersion": "x", "capabilities": [], "clientInfo": 5})),
            zod_issues(&[
                (&["params", "capabilities"], "object", "array"),
                (&["params", "clientInfo"], "object", "number"),
            ]),
        ),
        (
            "initialize",
            Some(json!({"protocolVersion": "x", "capabilities": null, "clientInfo": {}})),
            zod_issues(&[
                (&["params", "capabilities"], "object", "null"),
                (&["params", "clientInfo", "name"], "string", "undefined"),
                (&["params", "clientInfo", "version"], "string", "undefined"),
            ]),
        ),
        (
            "initialize",
            Some(
                json!({"protocolVersion": "x", "capabilities": {}, "clientInfo": {"name": 5, "version": null}}),
            ),
            zod_issues(&[
                (&["params", "clientInfo", "name"], "string", "number"),
                (&["params", "clientInfo", "version"], "string", "null"),
            ]),
        ),
        (
            "tools/list",
            Some(json!({"cursor": null})),
            zod_issues(&[(&["params", "cursor"], "string", "null")]),
        ),
        (
            "tools/call",
            None,
            zod_issues(&[(&["params"], "object", "undefined")]),
        ),
        (
            "tools/call",
            Some(json!({"arguments": 5})),
            zod_issues(&[
                (&["params", "name"], "string", "undefined"),
                (&["params", "arguments"], "record", "number"),
            ]),
        ),
        (
            "tools/call",
            Some(json!({"name": "probe", "arguments": []})),
            zod_issues(&[(&["params", "arguments"], "record", "array")]),
        ),
    ];
    for (i, (method, params, text)) in cases.iter().enumerate() {
        let mut request = json!({"jsonrpc": "2.0", "id": i + 1, "method": method});
        if let Some(params) = params {
            request["params"] = params.clone();
        }
        link.send(&request);
        let reply = link.reply();
        assert_eq!(reply["error"]["code"], json!(-32603), "{method} {params:?}");
        assert_eq!(
            reply["error"]["message"],
            json!(text),
            "{method} {params:?}"
        );
    }
}

#[test]
fn a_request_whose_params_do_not_fit_is_refused_in_a_sentence_when_the_server_is_the_plugins() {
    let mut link = Link::open(Identity::PLUGIN, Arc::new(Probe::default()));
    link.send(&json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}));
    let reply = link.reply();
    assert_eq!(reply["error"]["code"], json!(-32602));
    assert_eq!(
        reply["error"]["message"],
        json!("Invalid params: protocolVersion must be a string")
    );
}
