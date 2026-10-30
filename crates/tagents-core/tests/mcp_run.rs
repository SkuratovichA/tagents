//! A call of the MCP server is a child process: the program looked up on PATH, no stdin, its exit code named by the program's own table, and nothing it started outlives the call.
//!
//! The ports of `packages/mcp/test/run.test.ts` and of the call-level half of `process.test.ts`, run against `call_tool` itself. The programs are shell scripts in a directory that is the whole PATH (`common::rig`). The server as a process is `mcp_server.rs`.
//!
//! A test holds the fork gate for the whole call, so its own thread must not spawn anything (`run`, `start`) while a call is in flight: a writer waiting for the gate would hold it up for good.

// Test code: a failed unwrap here is the failure report.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::{
    ffi::OsString,
    fs,
    sync::mpsc::{self, Receiver},
    thread,
    time::{Duration, Instant},
};

use serde_json::{Value, json};
use tagents_core::mcp::{
    contract,
    rpc::CallResult,
    run::{MAX_STREAM, RunDeps, call_tool},
    server::Stop,
    tools::{Tool, tool_specs},
};

mod common;
use common::{
    forking,
    rig::{FAKE_CONTRACT, Rig, WITH_GRANDCHILD, alive, until},
    scratch,
};

fn tool(name: &str) -> Tool {
    let programs = contract::parse(FAKE_CONTRACT).unwrap();
    tool_specs(&programs)
        .unwrap()
        .into_iter()
        .find(|tool| tool.name == name)
        .unwrap()
}

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

/// The limits of a call with the timeout given and the others of the server.
fn deps(rig: &Rig, timeout: Duration) -> RunDeps {
    RunDeps {
        timeout,
        ..RunDeps::standard(rig.env())
    }
}

fn call(tool: &Tool, args: &Value, deps: &RunDeps, stop: &Stop) -> CallResult {
    let _forking = forking();
    call_tool(tool, args.as_object().unwrap(), deps, stop)
}

/// A call with nothing to stop it but its timeout of five seconds.
fn plain(rig: &Rig, name: &str, args: &Value) -> CallResult {
    call(&tool(name), args, &deps(rig, ms(5000)), &Stop::default())
}

fn body(result: &CallResult) -> Value {
    serde_json::from_str(result.body()).unwrap()
}

/// A call on a thread of its own, for a test that stops it from outside.
fn in_flight(tool: Tool, deps: RunDeps, stop: Stop) -> Receiver<CallResult> {
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let result = call(&tool, &json!({}), &deps, &stop);
        let _ = sender.send(result);
    });
    receiver
}

/// A program that starts a helper in a session of its own, so outside the call's group, then waits for the helper's pid file and runs `after`. `perl` is what the helper runs before it replaces itself with the code of `exec`.
fn escapee_program(perl: &str, after: &str) -> String {
    format!(
        r#"/usr/bin/perl -MPOSIX -e 'POSIX::setsid(); open(F, ">", "$ARGV[0]/escaped.pid"); print F "$$\n"; close F; {perl}' "$D" & n=0; until [ -s "$D/escaped.pid" ] || [ $n -ge 200 ]; do n=$((n+1)); sleep 0.05; done; {after}"#
    )
}

/// Several writers on one pipe, so that the reader thread does not empty it between two polls of the call.
const WRITERS: &str = r#"exec "sh", "-c", "yes & yes & yes & exec yes""#;

fn has_perl() -> bool {
    let found = std::path::Path::new("/usr/bin/perl").exists();
    if !found {
        eprintln!("no perl to start a process in a session of its own: skipped");
    }
    found
}

fn marker() -> String {
    format!("\n[output cut at {MAX_STREAM} bytes]")
}

#[test]
fn a_zero_exit_with_json_on_stdout_is_an_ok_result_holding_the_parsed_document() {
    let rig = Rig::new("run_ok_json", r#"printf '{"a":[1,2]}\n'"#);
    let result = plain(&rig, "fake_echo", &json!({}));
    assert!(!result.is_error());
    assert_eq!(
        body(&result),
        json!({"exit": 0, "outcome": "ok", "stdout": {"a": [1, 2]}, "stderr": ""})
    );
}

#[test]
fn stdout_that_is_not_json_stays_text_even_when_it_looks_like_a_number() {
    let rig = Rig::new("run_text", r"printf '42\n'");
    assert_eq!(
        body(&plain(&rig, "fake_echo", &json!({})))["stdout"],
        json!("42\n")
    );
}

#[test]
fn the_arguments_reach_the_program_as_the_verb_words_flags_and_positionals() {
    let rig = Rig::new("run_argv", r#"printf '%s|' "$@""#);
    let result = plain(&rig, "fake_echo", &json!({"loud": true, "text": "hi"}));
    assert_eq!(body(&result)["stdout"], json!("echo|--loud|hi|"));
}

#[test]
fn a_non_zero_exit_is_an_error_result_that_names_the_exit_by_the_program_table_and_carries_stderr()
{
    let rig = Rig::new("run_refused", r#"echo "nothing done" >&2; exit 3"#);
    let result = plain(&rig, "fake_echo", &json!({}));
    assert!(result.is_error());
    assert_eq!(
        body(&result),
        json!({"exit": 3, "outcome": "refused", "stdout": "", "stderr": "nothing done\n"})
    );
}

#[test]
fn an_exit_code_the_table_does_not_name_is_reported_as_the_code() {
    let rig = Rig::new("run_exit9", "exit 9");
    assert_eq!(
        body(&plain(&rig, "fake_echo", &json!({})))["outcome"],
        json!("exit 9")
    );
}

#[test]
fn the_program_reads_an_empty_stdin_so_a_verb_that_waits_for_input_ends_instead_of_hanging_the_call()
 {
    let rig = Rig::new("run_stdin", r#"read line; printf 'got:%s' "$line""#);
    assert_eq!(
        body(&plain(&rig, "fake_stdin", &json!({}))),
        json!({"exit": 0, "outcome": "ok", "stdout": "got:", "stderr": ""})
    );
}

#[test]
fn a_program_that_outlives_the_timeout_is_stopped_and_the_call_says_timeout() {
    let rig = Rig::new("run_timeout", "exec sleep 30");
    let result = call(
        &tool("fake_hang"),
        &json!({}),
        &deps(&rig, ms(200)),
        &Stop::default(),
    );
    assert!(result.is_error());
    let body = body(&result);
    assert_eq!(body["outcome"], json!("timeout"));
    assert_eq!(body["exit"], json!(4));
    assert_eq!(
        body["stderr"],
        json!("tagents-fake did not finish within 200 ms and was stopped\n")
    );
}

#[test]
fn a_program_that_is_not_on_path_is_an_error_that_says_which_one() {
    let dir = scratch("run_not_on_path");
    let deps = RunDeps::standard([(OsString::from("PATH"), dir.into_os_string())].into());
    let result = call(&tool("fake_echo"), &json!({}), &deps, &Stop::default());
    assert!(result.is_error());
    let body = body(&result);
    assert_eq!(body["outcome"], json!("error"));
    assert_eq!(body["stderr"], json!("tagents-fake is not on PATH\n"));
}

#[test]
fn arguments_the_schema_rejects_never_start_the_program() {
    let rig = Rig::new("run_schema", r#"touch "$0.ran""#);
    let result = plain(&rig, "fake_echo", &json!({"nope": 1}));
    assert!(result.is_error());
    let body = body(&result);
    assert_eq!(body["outcome"], json!("usage"));
    assert!(body["stderr"].as_str().unwrap().contains("nope"));
    assert!(!rig.dir.join("tagents-fake.ran").exists());
}

#[test]
fn a_verb_that_needs_tmux_is_refused_without_running_when_the_server_has_no_tmux_of_its_own() {
    let rig = Rig::new("run_tmux", r#"touch "$0.ran""#);
    let result = plain(&rig, "fake_window", &json!({}));
    assert!(result.is_error());
    let body = body(&result);
    assert_eq!(body["outcome"], json!("refused"));
    assert_eq!(body["exit"], json!(3));
    assert!(body["stderr"].as_str().unwrap().contains("tmux"));
    assert!(!rig.dir.join("tagents-fake.ran").exists());

    // An empty TMUX is no tmux either.
    let mut env = rig.env();
    env.insert("TMUX".into(), "".into());
    let empty = call(
        &tool("fake_window"),
        &json!({}),
        &RunDeps::standard(env),
        &Stop::default(),
    );
    assert_eq!(body_of_outcome(&empty), "refused");
    assert!(!rig.dir.join("tagents-fake.ran").exists());

    let mut env = rig.env();
    env.insert("TMUX".into(), "/tmp/tmux-1/default,1,0".into());
    let inside = call(
        &tool("fake_window"),
        &json!({}),
        &RunDeps::standard(env),
        &Stop::default(),
    );
    assert!(!inside.is_error());
    assert!(rig.dir.join("tagents-fake.ran").exists());
}

fn body_of_outcome(result: &CallResult) -> String {
    body(result)["outcome"].as_str().unwrap().to_owned()
}

#[test]
fn arguments_travel_as_one_word_each_a_newline_or_an_equals_sign_inside_a_value_does_not_split_or_re_read_it()
 {
    let rig = Rig::new("run_words", r#"printf '%s' "$#"; printf '<%s>' "$@""#);
    let result = plain(
        &rig,
        "fake_echo",
        &json!({"name": "a=b", "text": "line one\nline two=x"}),
    );
    assert_eq!(
        body(&result)["stdout"],
        json!("3<echo><--name=a=b><line one\nline two=x>")
    );
}

#[test]
fn a_program_that_cannot_be_started_is_a_refusal_never_a_panic_a_nul_in_the_environment_a_file_that_is_not_executable()
 {
    let rig = Rig::new("run_cannot_start", "exit 0");
    let mut env = rig.env();
    env.insert("BAD".into(), "a\0b".into());
    let nul = call(
        &tool("fake_echo"),
        &json!({}),
        &RunDeps::standard(env),
        &Stop::default(),
    );
    assert!(nul.is_error());
    assert_eq!(body_of_outcome(&nul), "error");

    let dir = scratch("run_not_executable");
    fs::write(dir.join("tagents-fake"), "#!/bin/sh\nexit 0\n").unwrap();
    let deps = RunDeps::standard([(OsString::from("PATH"), dir.into_os_string())].into());
    let noexec = call(&tool("fake_echo"), &json!({}), &deps, &Stop::default());
    assert!(noexec.is_error());
    assert_eq!(body_of_outcome(&noexec), "error");
}

/// A call of `fake_echo` that has room for a large output.
fn long(rig: &Rig) -> CallResult {
    call(
        &tool("fake_echo"),
        &json!({}),
        &deps(rig, ms(20_000)),
        &Stop::default(),
    )
}

#[test]
fn output_over_the_cap_is_cut_on_a_character_boundary_with_a_marker_and_a_character_that_straddles_the_limit_is_dropped_whole()
 {
    let rig = Rig::new(
        "run_straddle",
        &format!(
            r"head -c {} /dev/zero | tr '\0' a; printf '\303\251'; head -c 1000 /dev/zero | tr '\0' b",
            MAX_STREAM - 1
        ),
    );
    let body = body(&long(&rig));
    assert_eq!(body["truncated"], json!(true));
    let expected = format!("{}{}", "a".repeat(MAX_STREAM - 1), marker());
    assert_eq!(body["stdout"].as_str().unwrap(), expected);
}

#[test]
fn a_character_that_ends_exactly_at_the_limit_stays() {
    let rig = Rig::new(
        "run_exact_char",
        &format!(
            r"head -c {} /dev/zero | tr '\0' a; printf '\303\251'; head -c 1000 /dev/zero | tr '\0' b",
            MAX_STREAM - 2
        ),
    );
    let body = body(&long(&rig));
    assert_eq!(body["truncated"], json!(true));
    let expected = format!("{}\u{e9}{}", "a".repeat(MAX_STREAM - 2), marker());
    assert_eq!(body["stdout"].as_str().unwrap(), expected);
}

#[test]
fn many_small_writes_that_add_up_past_the_cap_are_cut_by_bytes_in_total_and_multi_byte_text_is_counted_in_bytes()
 {
    let euros = "\u{20ac}".repeat(300);
    let rig = Rig::new(
        "run_small_writes",
        &format!("i=0; while [ $i -lt 400 ]; do printf '{euros}'; i=$((i+1)); done"),
    );
    let body = body(&long(&rig));
    assert_eq!(body["truncated"], json!(true));
    let stdout = body["stdout"].as_str().unwrap();
    let kept = stdout.strip_suffix(&marker()).expect("the marker ends it");
    // 262144 is not a multiple of 3: the euro that straddles the limit is dropped whole.
    assert_eq!(kept.len(), MAX_STREAM - MAX_STREAM % 3);
    assert!(!kept.contains('\u{fffd}'));
}

#[test]
fn a_four_byte_character_is_never_split_by_the_cut_and_stderr_is_capped_on_its_own() {
    let rig = Rig::new(
        "run_four_byte",
        &format!(
            "printf a; yes '\u{1f600}' | head -c {size}; yes '\u{1f600}' | head -c {size} >&2",
            size = MAX_STREAM * 2
        ),
    );
    let body = body(&long(&rig));
    for stream in ["stdout", "stderr"] {
        let text = body[stream].as_str().unwrap();
        let kept = text.strip_suffix(&marker()).expect("the marker ends it");
        assert!(kept.len() <= MAX_STREAM, "{stream}");
        assert!(kept.len() > MAX_STREAM - 4, "{stream}");
        assert!(!kept.contains('\u{fffd}'), "{stream}");
    }
}

#[test]
fn a_cut_stderr_marks_the_result_but_does_not_turn_a_small_json_stdout_into_text() {
    let rig = Rig::new(
        "run_cut_stderr",
        &format!(
            r#"printf '{{"a":[1,2]}}\n'; head -c {} /dev/zero | tr '\0' e >&2"#,
            MAX_STREAM + 1000
        ),
    );
    let body = body(&long(&rig));
    assert_eq!(body["truncated"], json!(true));
    assert_eq!(body["stdout"], json!({"a": [1, 2]}));
    assert!(body["stderr"].as_str().unwrap().ends_with(&marker()));
}

#[test]
fn a_failing_program_whose_stderr_is_cut_is_still_an_error_with_its_code_its_stdout_and_the_mark() {
    let rig = Rig::new(
        "run_cut_stderr_failing",
        &format!(
            r#"printf '{{"a":[1,2]}}\n'; head -c {} /dev/zero | tr '\0' e >&2; exit 9"#,
            MAX_STREAM + 1000
        ),
    );
    let result = long(&rig);
    let body = body(&result);
    assert!(result.is_error());
    assert_eq!(body["exit"], json!(9));
    assert_eq!(body["outcome"], json!("exit 9"));
    assert_eq!(body["truncated"], json!(true));
    assert_eq!(body["stdout"], json!({"a": [1, 2]}));
    let stderr = body["stderr"].as_str().unwrap();
    assert_eq!(stderr, format!("{}{}", "e".repeat(MAX_STREAM), marker()));
}

#[test]
fn output_within_the_cap_is_whole_and_not_marked() {
    let rig = Rig::new(
        "run_within_cap",
        &format!(r"head -c {MAX_STREAM} /dev/zero | tr '\0' a"),
    );
    let body = body(&long(&rig));
    assert_eq!(body.get("truncated"), None);
    assert_eq!(body["stdout"].as_str().unwrap().len(), MAX_STREAM);
}

// What follows is process.test.ts: nothing that a call started outlives it.

#[test]
fn a_cancelled_call_stops_the_program_and_what_it_started_and_says_it_was_cancelled() {
    let rig = Rig::new("process_cancel", WITH_GRANDCHILD);
    let stop = Stop::default();
    let deps = RunDeps {
        timeout: Duration::from_secs(60),
        kill_grace: ms(500),
        ..RunDeps::standard(rig.env())
    };
    let result = in_flight(tool("fake_hang"), deps, stop.clone());
    assert!(rig.started(2), "the program and its sleep started");
    stop.stop();
    let result = result
        .recv_timeout(Duration::from_secs(5))
        .expect("the call resolved");
    assert!(result.is_error());
    assert_eq!(body_of_outcome(&result), "cancelled");
    assert_eq!(
        body(&result)["stderr"],
        json!("tagents-fake was stopped: the request was cancelled or the server closed\n")
    );
    assert!(rig.none_alive(), "both processes are gone");
}

#[test]
fn a_call_whose_request_was_cancelled_before_it_started_never_starts_the_program() {
    let rig = Rig::new("process_cancelled_first", r#"touch "$D/ran""#);
    let stop = Stop::default();
    stop.stop();
    let result = call(&tool("fake_hang"), &json!({}), &deps(&rig, ms(5000)), &stop);
    assert_eq!(body_of_outcome(&result), "cancelled");
    assert_eq!(
        body(&result)["stderr"],
        json!("tagents-fake was not started: the request was cancelled\n")
    );
    assert!(!rig.dir.join("ran").exists());
}

#[test]
fn a_program_that_ignores_sigterm_is_killed_once_the_grace_is_over_and_not_before() {
    let rig = Rig::new(
        "process_sigterm_ignored",
        r#"trap '' TERM; echo $$ > "$D/main.pid"; while :; do sleep 1; done"#,
    );
    let stop = Stop::default();
    let deps = RunDeps {
        timeout: Duration::from_secs(60),
        kill_grace: ms(3000),
        ..RunDeps::standard(rig.env())
    };
    let started = Instant::now();
    let result = in_flight(tool("fake_hang"), deps, stop.clone());
    assert!(rig.started(1), "the program started");
    stop.stop();
    let pid = rig.pids()["main"];
    thread::sleep(ms(300));
    assert!(alive(pid), "SIGTERM alone does not stop it");
    let result = result
        .recv_timeout(Duration::from_secs(12))
        .expect("the call resolved");
    assert_eq!(body_of_outcome(&result), "cancelled");
    assert!(
        started.elapsed() >= ms(2900),
        "not before the grace was over"
    );
    assert!(rig.none_alive(), "SIGKILL did");
}

#[test]
fn a_timeout_stops_the_whole_group_too_and_keeps_its_own_outcome() {
    let rig = Rig::new("process_timeout_group", WITH_GRANDCHILD);
    let deps = RunDeps {
        timeout: ms(300),
        kill_grace: ms(500),
        ..RunDeps::standard(rig.env())
    };
    let result = call(&tool("fake_hang"), &json!({}), &deps, &Stop::default());
    let body = body(&result);
    assert_eq!(body["outcome"], json!("timeout"));
    assert_eq!(body["exit"], json!(4));
    assert!(rig.none_alive(), "both processes are gone");
}

#[test]
fn a_program_that_exits_and_leaves_helpers_behind_leaves_nothing_alive() {
    // A helper in a subshell of a helper: neither is a child of the program, and both hold its pipes.
    let rig = Rig::new(
        "process_normal_exit",
        r#"echo $$ > "$D/main.pid"; ( sleep 30 & echo $! > "$D/deep.pid" ); sleep 30 & echo $! > "$D/grand.pid"; echo ok"#,
    );
    let result = plain(&rig, "fake_hang", &json!({}));
    assert_eq!(body(&result)["stdout"], json!("ok\n"));
    assert_eq!(rig.pids().len(), 3);
    assert!(rig.none_alive(), "every helper is gone");
}

#[test]
fn a_program_that_exits_at_once_and_leaves_a_grandchild_holding_its_pipes_does_not_hold_the_call_and_the_grandchild_is_stopped()
 {
    let rig = Rig::new(
        "process_grandchild_pipes",
        r#"sleep 30 & echo $! > "$D/grand.pid"; echo done"#,
    );
    let deps = RunDeps {
        timeout: Duration::from_secs(60),
        drain: ms(300),
        ..RunDeps::standard(rig.env())
    };
    let started = Instant::now();
    let result = call(&tool("fake_hang"), &json!({}), &deps, &Stop::default());
    assert!(
        started.elapsed() < ms(300 + 10_000),
        "long before the holder's 30 s"
    );
    let body = body(&result);
    assert_eq!(body["exit"], json!(0));
    assert_eq!(body["stdout"], json!("done\n"));
    assert!(rig.none_alive(), "the grandchild is gone");
}

#[test]
fn a_program_that_exits_with_its_output_still_in_the_pipe_loses_none_of_it() {
    // A drain of nothing makes the window as wide as it can be: what the pipes hold when the exit is seen is read by threads that may not have run yet. The output is under the cap and over the pipe's buffer, so the program waited for the readers while it wrote.
    let rig = Rig::new(
        "process_output_in_pipe",
        r"head -c 200000 /dev/zero | tr '\0' x",
    );
    let deps = RunDeps {
        drain: ms(0),
        ..deps(&rig, ms(5000))
    };
    // Calls side by side, as a server with several requests in flight runs them, so the readers of one call compete with the threads of the others: twenty calls one after the other on a quiet machine passed against the code that discarded the pipes at the drain, sixteen lanes of ten lost output in every run.
    thread::scope(|scope| {
        for lane in 1..=16 {
            let deps = &deps;
            scope.spawn(move || {
                for n in 1..=10 {
                    let body = body(&call(
                        &tool("fake_echo"),
                        &json!({}),
                        deps,
                        &Stop::default(),
                    ));
                    assert_eq!(
                        body["exit"],
                        json!(0),
                        "lane {lane} call {n}: {}",
                        body["outcome"]
                    );
                    assert_eq!(
                        body["stdout"].as_str().map(str::len),
                        Some(200_000),
                        "lane {lane} call {n} lost output"
                    );
                }
            });
        }
    });
}

#[test]
fn a_holder_of_the_pipes_that_left_the_group_cannot_be_killed_and_still_does_not_hold_the_call_longer_than_the_drain()
 {
    if !std::path::Path::new("/usr/bin/perl").exists() {
        eprintln!("no perl to start a process in a session of its own: skipped");
        return;
    }
    let rig = Rig::new(
        "process_escapee",
        &escapee_program(r#"exec "sleep", "30""#, "echo done"),
    );
    let deps = RunDeps {
        timeout: Duration::from_secs(60),
        drain: ms(100),
        kill_grace: ms(5000),
        ..RunDeps::standard(rig.env())
    };
    let started = Instant::now();
    let result = call(&tool("fake_hang"), &json!({}), &deps, &Stop::default());
    assert!(
        started.elapsed() < ms(3000),
        "the call gave up at the drain, not at the grace of 5 s"
    );
    assert_eq!(body(&result)["stdout"], json!("done\n"));
    // The escapee is out of the group, so the call could not stop it; the rig's drop does.
    assert!(until(|| rig.pids().len() == 1, 1000));
    assert!(
        alive(rig.pids()["escaped"]),
        "the escapee left the group, so the call could not stop it"
    );
}

#[test]
fn a_holder_of_the_stdout_alone_does_not_hold_the_call_longer_than_the_drain() {
    if !has_perl() {
        return;
    }
    // The stderr pipe has no writer left, so it polls as hung up unless its end is named as the one that ended.
    let rig = Rig::new(
        "process_escapee_stdout_only",
        &escapee_program(
            r#"open(STDERR, ">", "/dev/null"); exec "sleep", "30""#,
            "echo done",
        ),
    );
    let deps = RunDeps {
        timeout: Duration::from_secs(60),
        drain: ms(100),
        kill_grace: ms(5000),
        ..RunDeps::standard(rig.env())
    };
    let started = Instant::now();
    let result = call(&tool("fake_hang"), &json!({}), &deps, &Stop::default());
    assert!(
        started.elapsed() < ms(3000),
        "the call gave up at the drain, not at the grace of 5 s"
    );
    assert_eq!(body(&result)["stdout"], json!("done\n"));
}

#[test]
fn a_holder_of_the_stderr_alone_does_not_hold_the_call_longer_than_the_drain() {
    if !has_perl() {
        return;
    }
    let rig = Rig::new(
        "process_escapee_stderr_only",
        &escapee_program(
            r#"open(STDOUT, ">", "/dev/null"); exec "sleep", "30""#,
            "echo done",
        ),
    );
    let deps = RunDeps {
        timeout: Duration::from_secs(60),
        drain: ms(100),
        kill_grace: ms(5000),
        ..RunDeps::standard(rig.env())
    };
    let started = Instant::now();
    let result = call(&tool("fake_hang"), &json!({}), &deps, &Stop::default());
    assert!(
        started.elapsed() < ms(3000),
        "the call gave up at the drain, not at the grace of 5 s"
    );
    assert_eq!(body(&result)["stdout"], json!("done\n"));
}

#[test]
fn a_holder_outside_the_group_that_keeps_writing_holds_the_call_no_longer_than_the_drain_and_the_grace()
 {
    if !std::path::Path::new("/usr/bin/perl").exists() {
        eprintln!("no perl to start a process in a session of its own: skipped");
        return;
    }
    // The escapee writes to the call's stdout for good, so its pipe is never empty for long and the call waits for it, but only up to the drain and the grace.
    let rig = Rig::new(
        "process_escapee_writing",
        &escapee_program(WRITERS, "sleep 0.5; echo done"),
    );
    let deps = RunDeps {
        timeout: Duration::from_secs(60),
        drain: ms(100),
        kill_grace: ms(500),
        ..RunDeps::standard(rig.env())
    };
    let result = in_flight(tool("fake_hang"), deps, Stop::default())
        .recv_timeout(ms(10_000))
        .expect("a holder that keeps writing did not hold the call for good");
    assert_eq!(body(&result)["exit"], json!(0));
    // The call let go of the pipe, so the next write of the holder is a write to a pipe nobody reads.
    let pid = rig.pids()["escaped"];
    assert!(
        until(|| !alive(pid), 5000),
        "the holder died of SIGPIPE once the call was over"
    );
}

#[test]
fn a_call_that_was_stopped_is_given_up_on_at_the_drain_even_when_a_holder_keeps_writing() {
    if !has_perl() {
        return;
    }
    // The program ignores SIGTERM and has a writing helper outside the group: after the kill at the grace the pipe is never empty for long, and a stopped call must not wait for it a second grace.
    let rig = Rig::new(
        "process_stopped_escapee_writing",
        &format!(
            "trap '' TERM; {}",
            escapee_program(WRITERS, "while :; do sleep 1; done")
        ),
    );
    let stop = Stop::default();
    let deps = RunDeps {
        timeout: Duration::from_secs(60),
        drain: ms(100),
        kill_grace: ms(3000),
        ..RunDeps::standard(rig.env())
    };
    let result = in_flight(tool("fake_hang"), deps, stop.clone());
    assert!(rig.started(1), "the helper started");
    let stopped = Instant::now();
    stop.stop();
    let result = result.recv_timeout(ms(12_000)).expect("the call resolved");
    assert_eq!(body_of_outcome(&result), "cancelled");
    assert!(
        stopped.elapsed() < ms(5000),
        "a stopped call was given up on at the drain, not held for a second grace"
    );
}
