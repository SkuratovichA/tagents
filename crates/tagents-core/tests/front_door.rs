//! The built `tagents-core` binary, run as a user runs it.
//!
//! Three things are pinned here that the unit tests cannot see: that `sessions` prints the bytes the node CLI's recorded fixtures hold, that `--spec` and the data file agree in both directions, that `--version` is answered by the binary itself, and that every other word reaches the node CLI untouched.
//! The node CLI is never run: a stub stands in for it, in a layout copied from the one a checkout has (`target/debug/tagents-core` three levels below the directory that holds `packages/core/dist/cli/main.js`).
//! `tests/rust-parity.sh` is the suite that runs the real node CLI against this binary.

// Test code: a failed unwrap here is the failure report.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::{
    collections::BTreeSet,
    ffi::OsStr,
    fs,
    io::Write,
    os::unix::{ffi::OsStrExt, process::ExitStatusExt},
    path::{Path, PathBuf},
    process::{Command, Output, Stdio},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use rustix::process::{Pid, Signal, kill_process};
use tagents_spec::{Implementation, Spec};

mod common;
use common::{
    REPO, closed_pipe,
    rig::{Rig, until},
    run, scratch, start, write_executable, writing,
};

const BIN: &str = env!("CARGO_BIN_EXE_tagents-core");
const SPEC_FILE: &str = "spec/cli/tagents-core.json";
/// The call the tests that are about forwarding make: a verb the node CLI keeps and that no flag of a change in flight moves (`plugin list`), so the file does not change when a verb moves to Rust.
const FORWARDED: [&str; 2] = ["plugin", "list"];
const FIXTURES: &str = "packages/core/test/fixtures/sessions";

fn repo(path: &str) -> PathBuf {
    Path::new(REPO).join(path)
}

fn stdout_text(out: &Output) -> String {
    String::from_utf8(out.stdout.clone()).unwrap()
}

// ------------------------------------------------------------------ the fixtures ---

/// `transcript()` in `packages/core/test/helpers.ts`: one meta turn, the prompt, padding past the 2000-byte floor, a superseded reply and the reply.
fn transcript(prompt: &str, reply: &str) -> String {
    let json = |s: &str| serde_json::to_string(s).unwrap();
    let pad = "x".repeat(2400);
    [
        r#"{"type":"user","isMeta":true,"message":{"content":"<command-name>/init</command-name>"}}"#.to_owned(),
        format!(r#"{{"type":"user","message":{{"content":{}}}}}"#, json(prompt)),
        format!(r#"{{"type":"system","subtype":"pad","note":"{pad}"}}"#),
        r#"{"type":"assistant","message":{"content":[{"type":"text","text":"first pass, superseded"}]}}"#.to_owned(),
        format!(r#"{{"type":"assistant","message":{{"content":[{{"type":"text","text":{}}}]}}}}"#, json(reply)),
        String::new(),
    ]
    .join("\n")
}

/// `seedSessions()` in `helpers.ts`: the two sessions every fixture was recorded from.
fn seed_sessions(claude_home: &Path) {
    for (slug, id, prompt, reply, at) in [
        (
            "-Users-demo-git-demo",
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "Fix the deploy script for the staging cluster",
            "Deploy script fixed and staging is green.",
            1_767_323_045, // 2026-01-02T03:04:05Z
        ),
        (
            "-Users-demo-git-other-repo",
            "ffffffff-1111-2222-3333-444444444444",
            "Собери сводку по топикам за неделю",
            "Сводка готова, отправил в «dev».",
            1_770_091_506, // 2026-02-03T04:05:06Z
        ),
    ] {
        let dir = claude_home.join("projects").join(slug);
        fs::create_dir_all(&dir).unwrap();
        let file = fs::File::create(dir.join(format!("{id}.jsonl"))).unwrap();
        (&file)
            .write_all(transcript(prompt, reply).as_bytes())
            .unwrap();
        file.set_modified(UNIX_EPOCH + Duration::from_secs(at))
            .unwrap();
    }
}

/// The binary with an environment of exactly the variables the node CLI's tests pin, and nothing of the caller's.
fn sessions(home: &Path, args: &[&str]) -> Output {
    run(Command::new(BIN)
        .env_clear()
        .env("HOME", home)
        .env("CLAUDE_HOMES", home.join(".claude"))
        .env("TZ", "UTC")
        .args(args))
}

#[test]
fn sessions_print_the_bytes_the_node_cli_recorded() {
    let home = scratch("fixtures-home");
    seed_sessions(&home.join(".claude"));
    for (fixture, args) in [
        ("recent", vec!["sessions", "recent"]),
        ("recent-1", vec!["sessions", "recent", "1"]),
        ("search-deploy", vec!["sessions", "search", "deploy"]),
        ("search-miss", vec!["sessions", "search", "zzzznothing"]),
        ("show", vec!["sessions", "show", "aaaaaaaa"]),
    ] {
        let want = fs::read_to_string(repo(&format!("{FIXTURES}/{fixture}.txt"))).unwrap();
        let out = sessions(&home, &args);
        assert_eq!(stdout_text(&out), want, "{args:?} against {fixture}.txt");
        assert_eq!(out.stderr, b"", "{args:?}");
        assert_eq!(out.status.code(), Some(0), "{args:?}");
    }
}

#[test]
fn sessions_refusals_keep_the_node_cli_text_and_codes() {
    let home = scratch("refusals-home");
    seed_sessions(&home.join(".claude"));
    for (args, stdout, stderr, code) in [
        (
            vec!["sessions", "search"],
            "",
            "usage: sessions.mjs search <words…>\n",
            1,
        ),
        (
            vec!["sessions", "search", " "],
            "",
            "usage: sessions.mjs search <words…>\n",
            1,
        ),
        (
            vec!["sessions", "show"],
            "",
            "usage: sessions.mjs show <id-prefix>\n",
            1,
        ),
        (
            vec!["sessions", "show", ""],
            "",
            "usage: sessions.mjs show <id-prefix>\n",
            1,
        ),
        (
            vec!["sessions", "show", "nope"],
            "",
            "no session starts with \"nope\"\n",
            1,
        ),
        (
            vec!["sessions", "bogus"],
            "usage: sessions.mjs [recent [N] | search <words…> | show <id-prefix>]\n",
            "",
            0,
        ),
    ] {
        let out = sessions(&home, &args);
        assert_eq!(stdout_text(&out), stdout, "{args:?}");
        assert_eq!(String::from_utf8(out.stderr).unwrap(), stderr, "{args:?}");
        assert_eq!(out.status.code(), Some(code), "{args:?}");
    }
}

// ------------------------------------------------------------------------- --spec ---

fn data_file() -> Spec {
    Spec::parse(&fs::read_to_string(repo(SPEC_FILE)).unwrap()).unwrap()
}

fn paths<'a>(commands: impl Iterator<Item = &'a tagents_spec::Command>) -> BTreeSet<Vec<String>> {
    commands.map(|c| c.path.clone()).collect()
}

#[test]
fn spec_flag_prints_the_data_file_entries_of_the_verbs_it_serves() {
    let out = run(Command::new(BIN).env_clear().arg("--spec"));
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(out.stderr, b"");
    let served = Spec::parse(&stdout_text(&out)).unwrap();
    let file = data_file();

    // Every verb the data file gives to Rust is served, and every verb served is marked: the two sets are the same.
    assert_eq!(
        paths(served.commands.iter()),
        paths(file.served_by(Implementation::Rust)),
        "--spec against `impl: rust` in {SPEC_FILE}"
    );
    // ...with the data file's own entries, not a copy that could drift.
    for command in &served.commands {
        let entry = file
            .commands
            .iter()
            .find(|c| c.path == command.path)
            .unwrap();
        assert_eq!(command, entry, "{:?}", command.path);
    }
    assert_eq!((served.program, served.exit), (file.program, file.exit));
}

// ---------------------------------------------------------------------- --version ---

#[test]
fn version_flag_prints_the_crate_version_and_nothing_else() {
    // No node and no node CLI in reach: a forwarded `--version` would fail here (exit 2 or 127), so a pass means the front door answered itself.
    let out = run(Command::new(BIN).env_clear().arg("--version"));
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(out.stderr, b"");
    assert_eq!(
        stdout_text(&out),
        format!("tagents-core {}\n", env!("CARGO_PKG_VERSION"))
    );
}

#[test]
fn a_group_shared_with_node_declines_by_the_second_word() {
    // Dispatch is by the first word, so `sessions bogus` is Rust's to answer, and that is only true to the data file while every `sessions …` verb is marked rust. A word with verbs of both programs is a group that declines: the node verbs under it have a second word to decline by.
    let out = run(Command::new(BIN).env_clear().arg("--spec"));
    let served = Spec::parse(&stdout_text(&out)).unwrap();
    let words: BTreeSet<&str> = served.commands.iter().map(|c| c.path[0].as_str()).collect();
    assert!(!words.is_empty());
    for command in &data_file().commands {
        if words.contains(command.path[0].as_str())
            && command.implementation == Implementation::Node
        {
            assert!(
                command.path.len() >= 2,
                "{:?} is served by node under a word the binary answers wholly",
                command.path
            );
        }
    }
}

#[test]
fn exit_codes_in_the_code_are_the_ones_the_data_file_names() {
    let exit = data_file().exit;
    assert_eq!(exit["ok"], tagents_core::sessions::exit::OK);
    assert_eq!(exit["error"], tagents_core::sessions::exit::ERROR);
    assert_eq!(exit["usage"], tagents_core::sessions::exit::USAGE);
    assert_eq!(exit["refused"], tagents_core::sessions::exit::REFUSED);
    assert_eq!(exit["timeout"], tagents_core::sessions::exit::TIMEOUT);
}

// ------------------------------------------------------------------- the fall back ---

/// A checkout in miniature: the binary where `cargo build` puts it, a stub standing in for `main.js`, and a stub node.
struct Checkout {
    root: PathBuf,
    argv: PathBuf,
}

impl Checkout {
    fn new(name: &str) -> Self {
        let root = scratch(name).canonicalize().unwrap();
        let bin = root.join("target/debug/tagents-core");
        fs::create_dir_all(bin.parent().unwrap()).unwrap();
        {
            let _writing = writing();
            fs::copy(BIN, &bin).unwrap();
        }
        fs::create_dir_all(root.join("packages/core/dist/cli")).unwrap();
        fs::write(root.join("packages/core/dist/cli/main.js"), "// stub\n").unwrap();
        let argv = root.join("argv");
        write_executable(
            &root.join("node"),
            "#!/bin/sh\n{ printf 'cwd=%s\\n' \"$PWD\"; printf 'env=%s\\n' \"$SENTINEL\"; printf 'in=%s\\n' \"$(cat)\"; printf 'arg=%s\\n' \"$@\"; } > \"$ARGV_FILE\"\n[ -z \"$KILL_SELF\" ] || kill -TERM $$\nexit \"${STUB_EXIT:-0}\"\n",
        );
        Self { root, argv }
    }

    fn command(&self) -> Command {
        let mut command = Command::new(self.root.join("target/debug/tagents-core"));
        command
            .env_clear()
            .env("TAGENTS_NODE", self.root.join("node"))
            .env("ARGV_FILE", &self.argv);
        command
    }

    fn recorded(&self) -> Vec<String> {
        fs::read_to_string(&self.argv)
            .unwrap()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// Was the node CLI's script among the arguments the stub node was last given?
    fn reached_cli(&self) -> bool {
        let cli = format!("arg={}", self.cli());
        fs::read_to_string(&self.argv).is_ok_and(|text| text.lines().any(|line| line == cli))
    }

    fn cli(&self) -> String {
        self.root
            .join("packages/core/dist/cli/main.js")
            .display()
            .to_string()
    }
}

/// `command` with its stdout written to a pipe whose reader has gone and its stderr captured.
fn run_with_stdout(command: &mut Command, stdout: std::io::PipeWriter) -> Output {
    start(command.stdout(stdout).stderr(Stdio::piped()))
        .wait_with_output()
        .unwrap()
}

fn run_with_stdin(mut command: Command, stdin: &str) -> Output {
    let mut child = start(
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()),
    );
    child
        .stdin
        .take()
        .unwrap()
        .write_all(stdin.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

#[test]
fn spec_with_more_words_is_not_the_flag() {
    // Only an argv of exactly `--spec` is the front door's own; anything else is some verb's, and the node CLI refuses it in its own words.
    let checkout = Checkout::new("forward-spec-with-words");
    let out = run(checkout.command().args(["--spec", "x"]));
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(
        checkout.recorded()[3..],
        [
            format!("arg={}", checkout.cli()),
            "arg=--spec".into(),
            "arg=x".into()
        ]
    );
}

#[test]
fn version_with_more_words_is_not_the_flag() {
    // Same rule as `--spec`: only an argv of exactly `--version` is the front door's own.
    let checkout = Checkout::new("forward-version-with-words");
    let out = run(checkout.command().args(["--version", "x"]));
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(
        checkout.recorded()[3..],
        [
            format!("arg={}", checkout.cli()),
            "arg=--version".into(),
            "arg=x".into()
        ]
    );
}

#[test]
fn every_other_word_reaches_the_node_cli_with_argv_environment_and_stdin() {
    let checkout = Checkout::new("forward-argv");
    let mut command = checkout.command();
    command
        .env("SENTINEL", "kept")
        .env("STUB_EXIT", "3")
        .args(["plugin", "list", "--label", "two words", "", "--", "ünï"])
        .current_dir(&checkout.root);
    let out = run_with_stdin(command, "from stdin");
    assert_eq!(
        out.status.code(),
        Some(3),
        "the node CLI's exit code, untouched"
    );
    assert_eq!(
        checkout.recorded(),
        [
            format!("cwd={}", checkout.root.display()),
            "env=kept".into(),
            "in=from stdin".into(),
            format!("arg={}", checkout.cli()),
            "arg=plugin".into(),
            "arg=list".into(),
            "arg=--label".into(),
            "arg=two words".into(),
            "arg=".into(),
            "arg=--".into(),
            "arg=ünï".into(),
        ]
    );
}

#[test]
fn an_argument_that_is_not_utf8_is_forwarded_byte_for_byte() {
    // A lossy conversion would turn these two bytes into U+FFFD, and node would decode both to the same text; only the raw bytes the node stub writes down tell them apart.
    let checkout = Checkout::new("forward-bytes");
    let out = run(checkout
        .command()
        .args(FORWARDED)
        .arg(OsStr::from_bytes(b"\xff\xfe")));
    assert_eq!(out.status.code(), Some(0));
    let recorded = fs::read(&checkout.argv).unwrap();
    assert!(
        recorded.ends_with(b"arg=plugin\narg=list\narg=\xff\xfe\n"),
        "{:?}",
        String::from_utf8_lossy(&recorded)
    );

    // The verb position too: a first word that is not UTF-8 is not one the front door serves, so it is forwarded, and it must arrive as the same bytes. Its bytes differ from the second word's so a mixed-up pair would show.
    let out = run(checkout
        .command()
        .arg(OsStr::from_bytes(b"\xfe\xff"))
        .arg(OsStr::from_bytes(b"\xff\xfe")));
    assert_eq!(out.status.code(), Some(0));
    let recorded = fs::read(&checkout.argv).unwrap();
    assert!(
        recorded.ends_with(b"arg=\xfe\xff\narg=\xff\xfe\n"),
        "{:?}",
        String::from_utf8_lossy(&recorded)
    );
}

#[test]
fn a_verb_the_front_door_serves_is_not_forwarded() {
    let checkout = Checkout::new("served-not-forwarded");
    let home = checkout.root.join("home");
    fs::create_dir_all(&home).unwrap();
    // `notify run` serves until a signal, unless there is nothing to post: the options of this checkout say so.
    let config = checkout.root.join("config");
    fs::create_dir_all(config.join("plugins")).unwrap();
    fs::write(config.join("plugins/notify.toml"), "backend = \"none\"\n").unwrap();
    // Every verb the data file gives to Rust, run without its arguments: each answers on its own, and the node CLI never runs. `doctor` does start node, once, to ask it what it is, which is not the CLI: `reached_cli` looks for the CLI's script among the arguments the stub node was given.
    for command in data_file().served_by(Implementation::Rust) {
        let _ = fs::remove_file(&checkout.argv);
        let out = run(checkout
            .command()
            .env("HOME", &home)
            .env("CLAUDE_HOMES", home.join(".claude"))
            .env("TAGENTS_CONFIG_DIR", &config)
            .env("TA_STATE_DIR", checkout.root.join("state"))
            .args(&command.path));
        assert!(out.status.code().is_some(), "{:?}", command.path);
        assert!(
            !checkout.reached_cli(),
            "{:?} reached the node CLI",
            command.path
        );
    }
}

#[test]
fn doctor_is_answered_by_the_binary_which_asks_node_once_and_ignores_its_arguments() {
    // The stub node answers `-p` with nothing, so line one is the one the binary words itself; the other three come from the environment given here.
    let checkout = Checkout::new("doctor-served");
    let config = checkout.root.join("config");
    let state = checkout.root.join("state");
    fs::create_dir_all(&state).unwrap();
    fs::write(
        state.join("1.tsv"),
        "1700000000\tworking\tsid\t/work\t/work/t.jsonl\tReading\n",
    )
    .unwrap();
    for args in [
        vec![OsStr::new("doctor")],
        vec![OsStr::new("doctor"), OsStr::new("--x"), OsStr::new("y")],
        vec![OsStr::new("doctor"), OsStr::from_bytes(b"\xff\xfe")],
    ] {
        let _ = fs::remove_file(&checkout.argv);
        let out = run(checkout
            .command()
            .env("TAGENTS_CONFIG_DIR", &config)
            .env("TA_STATE_DIR", &state)
            .env("PATH", "")
            .env("SENTINEL", "kept")
            .args(&args));
        assert_eq!(out.status.code(), Some(0), "{args:?}");
        assert_eq!(
            stdout_text(&out),
            format!(
                "node: missing\nagent state {} (1 record(s))\nconfig {}: missing\nclaude: missing\n",
                state.display(),
                config.join("config.toml").display()
            ),
            "{args:?}"
        );
        assert_eq!(out.stderr, b"", "{args:?}");
        assert!(!checkout.reached_cli(), "{args:?}");
        // Node was run once, with the one question and nothing of the call's own arguments.
        assert_eq!(
            checkout.recorded()[3..],
            [
                "arg=-p",
                "arg=JSON.stringify([process.version, process.execPath])"
            ],
            "{args:?}"
        );
    }
}

/// A signal that comes while `doctor` waits for node ends it with the status a shell reports for a program that signal killed (128 and the number), prints nothing, and stops node first: node runs in a group of its own, which the terminal's Ctrl-C does not reach, so a doctor that only died would leave it running.
fn a_signal_during_the_wait_for_node_stops_node_and_ends_doctor(
    name: &str,
    signal: Signal,
    code: i32,
) {
    let rig = Rig::new(name, r#"echo $$ > "$D/node.pid"; exec sleep 30"#);
    let mut command = Command::new(BIN);
    command
        .env_clear()
        .env("TAGENTS_NODE", rig.dir.join("tagents-fake"))
        .env("TAGENTS_CONFIG_DIR", rig.dir.join("config"))
        .env("TA_STATE_DIR", rig.dir.join("state"))
        .env("PATH", rig.path())
        .arg("doctor")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut doctor = start(&mut command);
    // The pid is written once node runs, which is after doctor has been told to hear signals.
    assert!(rig.started(1), "node was not asked");
    kill_process(
        Pid::from_raw(i32::try_from(doctor.id()).unwrap()).unwrap(),
        signal,
    )
    .unwrap();
    // Well inside the 10 seconds node is given to answer, so that the signal is what ended the wait and not the deadline.
    let mut status = None;
    assert!(
        until(
            || {
                status = doctor.try_wait().unwrap();
                status.is_some()
            },
            5_000
        ),
        "doctor did not end at the signal"
    );
    assert_eq!(status.unwrap().code(), Some(code));
    assert!(rig.none_alive(), "node outlived doctor");
    let out = doctor.wait_with_output().unwrap();
    assert_eq!((out.stdout, out.stderr), (Vec::new(), Vec::new()));
}

#[test]
fn sigterm_during_the_wait_for_node_stops_node_and_ends_doctor() {
    a_signal_during_the_wait_for_node_stops_node_and_ends_doctor(
        "doctor_sigterm",
        Signal::TERM,
        143,
    );
}

#[test]
fn sigint_during_the_wait_for_node_stops_node_and_ends_doctor() {
    a_signal_during_the_wait_for_node_stops_node_and_ends_doctor("doctor_sigint", Signal::INT, 130);
}

#[test]
fn sighup_during_the_wait_for_node_stops_node_and_ends_doctor() {
    a_signal_during_the_wait_for_node_stops_node_and_ends_doctor("doctor_sighup", Signal::HUP, 129);
}

#[test]
fn the_plugin_calls_node_keeps_reach_it_with_their_arguments() {
    // `plugin add` and `plugin remove` are served here and `plugin list` is not: the group has to hand the rest of its first word to node, a bare `plugin` and an unknown verb included, each with every argument as it was typed.
    let checkout = Checkout::new("plugin-declines");
    for args in [
        &["plugin"][..],
        &["plugin", "list"],
        &["plugin", "list", "--json"],
        &["plugin", "list", "extra"],
        &["plugin", "bogus"],
        &["plugin", "bogus", "--name", "x"],
    ] {
        let _ = fs::remove_file(&checkout.argv);
        let out = run(checkout.command().args(args).current_dir(&checkout.root));
        assert_eq!(out.status.code(), Some(0), "{args:?}");
        let recorded = checkout.recorded();
        let expected: Vec<String> = args.iter().map(|a| format!("arg={a}")).collect();
        assert_eq!(
            recorded[3..],
            [vec![format!("arg={}", checkout.cli())], expected].concat()[..],
            "{args:?}"
        );
    }
}

#[test]
fn a_plugin_argument_that_is_not_utf8_is_forwarded_whole_not_decoded_lossily() {
    // `plugin add` and `plugin remove` are served here, and a name or path that is not UTF-8 is node's to read: a lossy decoding would write a different key or `from` than node does. The group is registered with `lossy_args: false`, so the call must arrive at node unchanged, and before anything is written.
    let checkout = Checkout::new("plugin-bytes");
    for verb in ["add", "remove"] {
        let _ = fs::remove_file(&checkout.argv);
        let out = run(checkout
            .command()
            .env("TAGENTS_CONFIG_DIR", checkout.root.join("config"))
            .current_dir(&checkout.root)
            .arg("plugin")
            .arg(verb)
            .arg(OsStr::from_bytes(b"\xff\xfe")));
        assert_eq!(out.status.code(), Some(0), "{verb}");
        let recorded = fs::read(&checkout.argv).unwrap();
        let expected = format!("arg=plugin\narg={verb}\narg=");
        assert!(
            recorded.ends_with(&[expected.as_bytes(), b"\xff\xfe\n"].concat()),
            "{verb}: {:?}",
            String::from_utf8_lossy(&recorded)
        );
        assert!(
            !checkout.root.join("config").exists(),
            "{verb} wrote before it handed over"
        );
    }
}

#[test]
fn the_session_calls_node_keeps_reach_it_with_their_arguments() {
    // `session` is a group that serves some of its verbs and hands the rest to node: a bare `session`, an unknown verb, a verb node keeps (`prompt`, `abort`) and a served verb whose arguments the grammar does not read (`open --bogus`), each with every argument as it was typed and nothing written before.
    let checkout = Checkout::new("session-declines");
    for args in [
        &["session"][..],
        &["session", "bogus"],
        &["session", "bogus", "--cwd", "x"],
        &["session", "open", "--bogus"],
        &["session", "prompt"],
        &["session", "prompt", "s-1", "two words", "--timeout", "5"],
        &["session", "abort"],
        &["session", "abort", "s-1"],
    ] {
        let _ = fs::remove_file(&checkout.argv);
        let out = run(checkout
            .command()
            .env("TA_STATE_DIR", checkout.root.join("state"))
            .env("TAGENTS_CONFIG_DIR", checkout.root.join("config"))
            .args(args)
            .current_dir(&checkout.root));
        assert_eq!(out.status.code(), Some(0), "{args:?}");
        let recorded = checkout.recorded();
        let expected: Vec<String> = args.iter().map(|a| format!("arg={a}")).collect();
        assert_eq!(
            recorded[3..],
            [vec![format!("arg={}", checkout.cli())], expected].concat()[..],
            "{args:?}"
        );
        assert!(
            !checkout.root.join("state").exists(),
            "{args:?} wrote before it handed over"
        );
    }
}

#[test]
fn a_session_argument_that_is_not_utf8_is_forwarded_whole_not_decoded_lossily() {
    // A cwd or a reference that is not UTF-8 is node's to read: a lossy decoding would look at another directory or session than the one that was typed. The group is registered with `lossy_args: false`, so the call must arrive at node unchanged.
    let checkout = Checkout::new("session-bytes");
    for words in [&["open", "--cwd"][..], &["last"], &["list", "--label"]] {
        let _ = fs::remove_file(&checkout.argv);
        let out = run(checkout
            .command()
            .env("TA_STATE_DIR", checkout.root.join("state"))
            .current_dir(&checkout.root)
            .arg("session")
            .args(words)
            .arg(OsStr::from_bytes(b"\xff\xfe")));
        assert_eq!(out.status.code(), Some(0), "{words:?}");
        let recorded = fs::read(&checkout.argv).unwrap();
        let typed: String = words.iter().map(|w| format!("arg={w}\n")).collect();
        let expected = [
            format!("arg=session\n{typed}arg=").as_bytes(),
            b"\xff\xfe\n",
        ]
        .concat();
        assert!(
            recorded.ends_with(&expected),
            "{words:?}: {:?}",
            String::from_utf8_lossy(&recorded)
        );
        assert!(
            !checkout.root.join("state").exists(),
            "{words:?} wrote before it handed over"
        );
    }
}

#[test]
fn the_exit_is_the_node_clis_even_when_it_is_a_signal() {
    let checkout = Checkout::new("forward-signal");
    let out = run(checkout.command().env("KILL_SELF", "1").args(FORWARDED));
    // exec replaces the process, so nothing of the front door is left to turn a signal into a number.
    assert_eq!(out.status.signal(), Some(15));
    assert_eq!(out.status.code(), None);
}

#[test]
fn a_missing_node_cli_is_exit_2_and_names_where_it_looked() {
    let checkout = Checkout::new("forward-no-cli");
    fs::remove_file(checkout.root.join("packages/core/dist/cli/main.js")).unwrap();
    let out = run(checkout.command().args(FORWARDED));
    // 2 is the usage exit of the CLI spec, written out so that changing the constant in the code does not move the test with it.
    assert_eq!(out.status.code(), Some(2));
    assert_eq!(out.stdout, b"");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains(&checkout.cli()), "{stderr}");
    assert!(
        stderr.contains("cannot find packages/core/dist/cli/main.js:"),
        "{stderr}"
    );
    assert!(stderr.contains("<root>/target/<profile>/"), "{stderr}");
    assert!(!checkout.argv.exists());
}

#[test]
fn a_node_that_cannot_run_is_exit_127_or_126() {
    let checkout = Checkout::new("forward-no-node");
    let missing = run(checkout
        .command()
        .env("TAGENTS_NODE", checkout.root.join("no-such-node"))
        .args(FORWARDED));
    // The shell's codes for "not found" and "found but cannot run", written out so that changing a constant in the code does not move the test with it.
    assert_eq!(missing.status.code(), Some(127));
    assert!(
        String::from_utf8_lossy(&missing.stderr).contains("no-such-node"),
        "{:?}",
        missing.stderr
    );

    fs::write(checkout.root.join("not-executable"), "#!/bin/sh\n").unwrap();
    let denied = run(checkout
        .command()
        .env("TAGENTS_NODE", checkout.root.join("not-executable"))
        .args(FORWARDED));
    assert_eq!(denied.status.code(), Some(126));
}

#[test]
fn a_session_call_for_node_with_no_node_gets_the_front_doors_error() {
    let checkout = Checkout::new("session-no-node");
    for args in [
        &["session"][..],
        &["session", "bogus"],
        &["session", "open", "--bogus"],
    ] {
        let pinned = run(checkout
            .command()
            .env("TAGENTS_NODE", checkout.root.join("no-such-node"))
            .args(args));
        assert_eq!(pinned.status.code(), Some(127), "{args:?}");
        assert_eq!(pinned.stdout, b"", "{args:?}");
        let said = String::from_utf8_lossy(&pinned.stderr);
        assert!(
            said.starts_with("tagents-core: cannot run ") && said.contains("no-such-node"),
            "{args:?}: {said}"
        );

        let on_path = run(checkout
            .command()
            .env_remove("TAGENTS_NODE")
            .env("PATH", checkout.root.join("no-such-directory"))
            .args(args));
        assert_eq!(on_path.status.code(), Some(127), "{args:?}");
        assert_eq!(on_path.stdout, b"", "{args:?}");
        let said = String::from_utf8_lossy(&on_path.stderr);
        assert!(
            said.starts_with("tagents-core: cannot run node: "),
            "{args:?}: {said}"
        );
    }
}

#[test]
fn the_read_verbs_of_session_start_nothing_so_they_answer_with_no_node() {
    let checkout = Checkout::new("session-read-no-node");
    let listed = run(checkout
        .command()
        .env("TAGENTS_NODE", checkout.root.join("no-such-node"))
        .env("HOME", checkout.root.join("home"))
        .env("TA_STATE_DIR", checkout.root.join("state"))
        .args(["session", "list"]));
    assert_eq!(listed.status.code(), Some(0), "{listed:?}");
    assert_eq!(listed.stdout, b"[]\n");
    assert_eq!(listed.stderr, b"");
}

#[test]
fn a_failed_exec_with_stderr_a_closed_pipe_exits_with_the_front_doors_code_not_a_panic() {
    // The line cannot be written; the exit is the same as when it can: 2 when the node CLI is missing, 127 when node cannot run.
    let checkout = Checkout::new("forward-failed-exec-closed-stderr");
    let main = checkout.root.join("packages/core/dist/cli/main.js");
    fs::remove_file(&main).unwrap();
    let missing = start(
        checkout
            .command()
            .args(FORWARDED)
            .stdout(Stdio::null())
            .stderr(closed_pipe()),
    )
    .wait()
    .unwrap();
    assert_eq!(missing.code(), Some(2), "{missing:?}");
    fs::write(&main, "// stub\n").unwrap();
    let cannot_run = start(
        checkout
            .command()
            .env("TAGENTS_NODE", checkout.root.join("no-such-node"))
            .args(FORWARDED)
            .stdout(Stdio::null())
            .stderr(closed_pipe()),
    )
    .wait()
    .unwrap();
    assert_eq!(cannot_run.code(), Some(127), "{cannot_run:?}");
}

#[test]
fn a_reader_that_went_away_changes_neither_the_exit_code_nor_the_other_stream() {
    // Both streams of a served call are best-effort writes: stdout closed under `--version` still ends 0 with nothing on stderr, and stderr closed under a refusal (`sessions search` with no words, exit 1, its usage on stderr) still ends 1.
    let checkout = Checkout::new("served-closed-pipes");
    let version = run_with_stdout(checkout.command().arg("--version"), closed_pipe());
    assert_eq!(version.status.code(), Some(0), "{version:?}");
    assert_eq!(version.stderr, b"");
    let refused = start(
        checkout
            .command()
            .args(["sessions", "search"])
            .stdout(Stdio::piped())
            .stderr(closed_pipe()),
    )
    .wait_with_output()
    .unwrap();
    assert_eq!(refused.status.code(), Some(1), "{refused:?}");
    assert_eq!(refused.stdout, b"");
}

#[test]
fn node_is_looked_up_on_path_when_no_node_is_pinned() {
    let checkout = Checkout::new("forward-path-node");
    let mut command = checkout.command();
    command
        .env_remove("TAGENTS_NODE")
        .env("PATH", &checkout.root)
        .args(FORWARDED);
    let out = run(&mut command);
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(checkout.recorded().last().unwrap(), "arg=list");
}

#[test]
fn the_binary_finds_its_node_cli_through_a_symlink() {
    let checkout = Checkout::new("forward-symlink");
    let link = checkout.root.join("link");
    std::os::unix::fs::symlink(checkout.root.join("target/debug/tagents-core"), &link).unwrap();
    let out = run(Command::new(&link)
        .env_clear()
        .env("TAGENTS_NODE", checkout.root.join("node"))
        .env("ARGV_FILE", &checkout.argv)
        .args(FORWARDED));
    assert_eq!(out.status.code(), Some(0));
    assert!(
        checkout
            .recorded()
            .contains(&format!("arg={}", checkout.cli()))
    );
}

#[test]
fn a_closed_stdout_is_not_an_error() {
    // The node CLI ignores a write that fails because the reader went away; so does this.
    // The listing is far larger than a pipe holds, so the write cannot finish while the read end is open: it either blocks until the reader is gone or fails at once, and in both cases it meets a closed pipe.
    let home = scratch("closed-stdout");
    let projects = home.join(".claude/projects/-Users-demo-git-demo");
    fs::create_dir_all(&projects).unwrap();
    for n in 0..1000 {
        let prompt = format!("session {n} {}", "p".repeat(120));
        fs::write(
            projects.join(format!("{n:08x}-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl")),
            transcript(&prompt, "done"),
        )
        .unwrap();
    }
    let mut child = start(
        Command::new(BIN)
            .env_clear()
            .env("HOME", &home)
            .env("CLAUDE_HOMES", home.join(".claude"))
            .args(["sessions", "recent", "1000"])
            .stdout(Stdio::piped()),
    );
    drop(child.stdout.take());
    let status = child.wait().unwrap();
    assert_eq!(status.code(), Some(0), "{status:?}");
}

#[test]
fn the_clock_is_the_systems() {
    // A session written a minute ago is marked as written today; one from January is not.
    let home = scratch("clock");
    seed_sessions(&home.join(".claude"));
    let recent_file = home
        .join(".claude/projects/-Users-demo-git-demo/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl");
    let file = fs::OpenOptions::new()
        .write(true)
        .open(recent_file)
        .unwrap();
    file.set_modified(SystemTime::now() - Duration::from_secs(60))
        .unwrap();
    let out = stdout_text(&sessions(&home, &["sessions", "recent"]));
    assert!(out.contains("(today/yday)"), "{out}");
    assert_eq!(out.matches("(today/yday)").count(), 1, "{out}");
}

#[test]
fn the_node_cli_starts_with_sigpipe_at_its_default() {
    // Rust's runtime ignores SIGPIPE, and a program started from it that kept that would print "Broken pipe" where the same program started from a shell dies quietly.
    // `yes` is the probe: with SIGPIPE ignored it reports the failed write on stderr, with the default it is simply gone.
    let checkout = Checkout::new("forward-sigpipe");
    write_executable(
        &checkout.root.join("node"),
        "#!/bin/sh\nyes 2> \"$ARGV_FILE\" | head -c 1 > /dev/null\n",
    );
    let out = run(checkout.command().args(FORWARDED));
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(fs::read(&checkout.argv).unwrap(), b"");
}
