//! The built `tagents-core` binary, run as a user runs it.
//!
//! Three things are pinned here that the unit tests cannot see: that `sessions` prints the bytes the node CLI's recorded fixtures hold, that `--spec` and the data file agree in both directions, and that every other word reaches the node CLI untouched.
//! The node CLI is never run: a stub stands in for it, in a layout copied from the one a checkout has (`target/debug/tagents-core` three levels below the directory that holds `packages/core/dist/cli/main.js`).
//! `tests/rust-parity.sh` is the suite that runs the real node CLI against this binary.

// Test code: a failed unwrap here is the failure report.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::{
    collections::BTreeSet,
    ffi::OsStr,
    fs,
    io::Write,
    os::unix::{ffi::OsStrExt, fs::PermissionsExt, process::ExitStatusExt},
    path::{Path, PathBuf},
    process::{Command, Output, Stdio},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use tagents_core::sessions::exit;
use tagents_spec::{Implementation, Spec};

const BIN: &str = env!("CARGO_BIN_EXE_tagents-core");
const REPO: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../..");
const SPEC_FILE: &str = "spec/cli/tagents-core.json";
const FIXTURES: &str = "packages/core/test/fixtures/sessions";

/// A scratch directory of this test's own, empty.
fn scratch(name: &str) -> PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn repo(path: &str) -> PathBuf {
    Path::new(REPO).join(path)
}

fn write_executable(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
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
    Command::new(BIN)
        .env_clear()
        .env("HOME", home)
        .env("CLAUDE_HOMES", home.join(".claude"))
        .env("TZ", "UTC")
        .args(args)
        .output()
        .unwrap()
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
    let out = Command::new(BIN)
        .env_clear()
        .arg("--spec")
        .output()
        .unwrap();
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

#[test]
fn a_group_is_served_by_one_program_wholly() {
    // Dispatch is by the first word, so `sessions bogus` is Rust's to answer. That is only true to the data file while every `sessions …` verb is marked rust.
    let out = Command::new(BIN)
        .env_clear()
        .arg("--spec")
        .output()
        .unwrap();
    let served = Spec::parse(&stdout_text(&out)).unwrap();
    let words: BTreeSet<&str> = served.commands.iter().map(|c| c.path[0].as_str()).collect();
    assert!(!words.is_empty());
    for command in &data_file().commands {
        if words.contains(command.path[0].as_str()) {
            assert_eq!(
                command.implementation,
                Implementation::Rust,
                "{:?}",
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
        fs::copy(BIN, &bin).unwrap();
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

    fn cli(&self) -> String {
        self.root
            .join("packages/core/dist/cli/main.js")
            .display()
            .to_string()
    }
}

fn run_with_stdin(mut command: Command, stdin: &str) -> Output {
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
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
    let out = checkout.command().args(["--spec", "x"]).output().unwrap();
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
fn every_other_word_reaches_the_node_cli_with_argv_environment_and_stdin() {
    let checkout = Checkout::new("forward-argv");
    let mut command = checkout.command();
    command
        .env("SENTINEL", "kept")
        .env("STUB_EXIT", "3")
        .args(["session", "list", "--label", "two words", "", "--", "ünï"])
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
            "arg=session".into(),
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
    let out = checkout
        .command()
        .arg("doctor")
        .arg(OsStr::from_bytes(b"\xff\xfe"))
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(0));
    let recorded = fs::read(&checkout.argv).unwrap();
    assert!(
        recorded.ends_with(b"arg=doctor\narg=\xff\xfe\n"),
        "{:?}",
        String::from_utf8_lossy(&recorded)
    );

    // The verb position too: a first word that is not UTF-8 is not one the front door serves, so it is forwarded, and it must arrive as the same bytes. Its bytes differ from the second word's so a mixed-up pair would show.
    let out = checkout
        .command()
        .arg(OsStr::from_bytes(b"\xfe\xff"))
        .arg(OsStr::from_bytes(b"\xff\xfe"))
        .output()
        .unwrap();
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
    // Every verb the data file gives to Rust, run without its arguments: each answers on its own, and the stub node never runs.
    for command in data_file().served_by(Implementation::Rust) {
        let out = checkout
            .command()
            .env("HOME", &home)
            .env("CLAUDE_HOMES", home.join(".claude"))
            .args(&command.path)
            .output()
            .unwrap();
        assert!(out.status.code().is_some(), "{:?}", command.path);
        assert!(
            !checkout.argv.exists(),
            "{:?} reached the node CLI",
            command.path
        );
    }
}

#[test]
fn the_exit_is_the_node_clis_even_when_it_is_a_signal() {
    let checkout = Checkout::new("forward-signal");
    let out = checkout
        .command()
        .env("KILL_SELF", "1")
        .arg("doctor")
        .output()
        .unwrap();
    // exec replaces the process, so nothing of the front door is left to turn a signal into a number.
    assert_eq!(out.status.signal(), Some(15));
    assert_eq!(out.status.code(), None);
}

#[test]
fn a_missing_node_cli_is_exit_2_and_names_where_it_looked() {
    let checkout = Checkout::new("forward-no-cli");
    fs::remove_file(checkout.root.join("packages/core/dist/cli/main.js")).unwrap();
    let out = checkout.command().arg("doctor").output().unwrap();
    assert_eq!(out.status.code(), Some(exit::USAGE.into()));
    assert_eq!(out.stdout, b"");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains(&checkout.cli()), "{stderr}");
    assert!(stderr.contains("<root>/target/<profile>/"), "{stderr}");
    assert!(!checkout.argv.exists());
}

#[test]
fn a_node_that_cannot_run_is_exit_127_or_126() {
    let checkout = Checkout::new("forward-no-node");
    let missing = checkout
        .command()
        .env("TAGENTS_NODE", checkout.root.join("no-such-node"))
        .arg("doctor")
        .output()
        .unwrap();
    // The shell's codes for "not found" and "found but cannot run", written out so that changing a constant in the code does not move the test with it.
    assert_eq!(missing.status.code(), Some(127));
    assert!(
        String::from_utf8_lossy(&missing.stderr).contains("no-such-node"),
        "{:?}",
        missing.stderr
    );

    fs::write(checkout.root.join("not-executable"), "#!/bin/sh\n").unwrap();
    let denied = checkout
        .command()
        .env("TAGENTS_NODE", checkout.root.join("not-executable"))
        .arg("doctor")
        .output()
        .unwrap();
    assert_eq!(denied.status.code(), Some(126));
}

#[test]
fn node_is_looked_up_on_path_when_no_node_is_pinned() {
    let checkout = Checkout::new("forward-path-node");
    let mut command = checkout.command();
    command
        .env_remove("TAGENTS_NODE")
        .env("PATH", &checkout.root)
        .arg("doctor");
    let out = command.output().unwrap();
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(checkout.recorded().last().unwrap(), "arg=doctor");
}

#[test]
fn the_binary_finds_its_node_cli_through_a_symlink() {
    let checkout = Checkout::new("forward-symlink");
    let link = checkout.root.join("link");
    std::os::unix::fs::symlink(checkout.root.join("target/debug/tagents-core"), &link).unwrap();
    let out = Command::new(&link)
        .env_clear()
        .env("TAGENTS_NODE", checkout.root.join("node"))
        .env("ARGV_FILE", &checkout.argv)
        .arg("doctor")
        .output()
        .unwrap();
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
    let mut child = Command::new(BIN)
        .env_clear()
        .env("HOME", &home)
        .env("CLAUDE_HOMES", home.join(".claude"))
        .args(["sessions", "recent", "1000"])
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
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
    let out = checkout.command().arg("doctor").output().unwrap();
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(fs::read(&checkout.argv).unwrap(), b"");
}
