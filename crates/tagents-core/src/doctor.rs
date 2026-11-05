//! `tagents-core doctor`, which prints what `doctor` of `packages/core/src/cli/main.ts` prints: the node that runs the CLI, the agent state directory with its record count, the config file and whether it exists, and the `claude` found on `PATH`.
//!
//! The verb ignores its arguments, as node's does, and always exits 0: it says what is wrong, it does not fail on it.
//! The node version and path are `process.version` and `process.execPath` of the node that would run the CLI, and `execPath` is what the operating system reports for that node, which can differ from the path that started it. So the node `$TAGENTS_NODE` (else `node` on `PATH`) names is asked once, with `node -p`, and the answer is used only when it is exactly an array of two strings.
//! When that node cannot be started, fails, takes longer than the deadline or answers anything else, line one is `doctorNodeMissing` and the other three lines are printed as usual. Node has no such line, because it cannot run without node, so this one output has no oracle in `tests/rust-plugin-parity.sh`: the unit tests below assert it.

use std::{
    ffi::{OsStr, OsString},
    path::Path,
    process::Command,
    sync::{Arc, OnceLock},
    time::Duration,
};

use crate::{
    child::{self, Policy},
    ending::{self, Stop},
    host::config_file,
    json::{self, Value},
    messages::Locale,
    node,
    notify::state::{read_agent_state, state_dir},
    sessions::{self, Output, exit},
};

/// The verbs this module serves, as the words after the program name. `tagents-core --spec` prints them and a test pins them to `impl: "rust"` in the data file.
pub const VERBS: &[&[&str]] = &[&["doctor"]];

/// What node is asked, once: the two values `doctor` prints about it.
const IDENTITY: &str = "JSON.stringify([process.version, process.execPath])";
/// How long node has to answer; a node that has not answered by then is as good as absent.
const DEADLINE: Duration = Duration::from_secs(10);
/// How long node has to leave after SIGTERM before SIGKILL.
const KILL_GRACE: Duration = Duration::from_millis(500);

/// What a call depends on besides its arguments, which `doctor` does not read.
pub struct Setting {
    pub locale: Locale,
    /// `stateDir()`.
    pub state_dir: String,
    /// `configFile()`.
    pub config_file: String,
    /// `process.env.PATH`; empty when it is unset.
    pub path: String,
    /// The node program that is asked for its version and path.
    pub node: OsString,
    pub deadline: Duration,
}

impl Setting {
    /// The setting of this process.
    pub fn current() -> Setting {
        Setting {
            locale: Locale::current(),
            state_dir: state_dir(),
            config_file: config_file(),
            path: node::env_text("PATH").unwrap_or_default(),
            node: node::interpreter(),
            deadline: DEADLINE,
        }
    }
}

/// `doctor` of this process.
///
/// A signal stops the question to node, which runs in a group of its own that the terminal's Ctrl-C does not reach, and ends the call as it ends node's: with nothing printed and the status a shell reports for a program that signal killed.
pub fn run() -> Output {
    let stop = Stop::default();
    let signalled = Arc::new(OnceLock::new());
    let (trip, said) = (stop.clone(), Arc::clone(&signalled));
    // Before anything starts, so that a signal during the question is heard.
    let listening = ending::on_signals(move |name| {
        let _ = said.set(name);
        trip.stop();
    });
    if let Err(why) = listening {
        return Output::line(
            exit::ERROR,
            &format!("tagents-core: cannot listen for signals: {why}"),
        );
    }
    let output = serve(&Setting::current(), &stop);
    match signalled.get() {
        Some(name) => Output {
            stdout: String::new(),
            stderr: String::new(),
            code: killed_by(name),
        },
        None => output,
    }
}

/// What a shell reports for a program that the signal `name` of `ending::on_signals` killed: 128 and its number.
fn killed_by(name: &str) -> u8 {
    match name {
        "SIGHUP" => 128 + 1,
        "SIGINT" => 128 + 2,
        _ => 128 + 15,
    }
}

/// `run` in a given setting, with `stop` to give up on node.
pub fn serve(setting: &Setting, stop: &Stop) -> Output {
    let texts = match sessions::texts(setting.locale) {
        Ok(texts) => texts,
        Err(out) => return out,
    };
    let node = match identity(&setting.node, setting.deadline, stop) {
        Some((version, path)) => texts.t("doctorNode", &[("version", &version), ("path", &path)]),
        None => texts.t("doctorNodeMissing", &[]),
    };
    let count = read_agent_state(&setting.state_dir).len().to_string();
    let state = texts.t(
        "doctorStateDir",
        &[("dir", &setting.state_dir), ("count", &count)],
    );
    let status = texts.t(
        if Path::new(&setting.config_file).exists() {
            "present"
        } else {
            "missing"
        },
        &[],
    );
    let config = texts.t(
        "doctorConfig",
        &[("file", &setting.config_file), ("status", &status)],
    );
    let claude =
        node::find_on_path("claude", &setting.path).unwrap_or_else(|| texts.t("missing", &[]));
    let claude = texts.t("doctorClaude", &[("status", &claude)]);
    Output::out(format!("{node}\n{state}\n{config}\n{claude}\n"))
}

/// The `process.version` and `process.execPath` of `node`, or `None` when it cannot be asked.
fn identity(node: &OsStr, deadline: Duration, stop: &Stop) -> Option<(String, String)> {
    let mut command = Command::new(node);
    command.args(["-p", IDENTITY]);
    let policy = Policy {
        input: None,
        timeout: deadline,
        kill_grace: Some(KILL_GRACE),
        drain: Duration::from_millis(250),
        cap: 64 * 1024,
    };
    let finished = child::run(command, &policy, stop).ok()?;
    if finished.reason.is_some() || finished.code != Some(0) {
        return None;
    }
    let answer = json::parse(&finished.stdout)?;
    match &answer {
        Value::Array(items) => match items.as_slice() {
            [Value::String(version), Value::String(path)] => Some((version.clone(), path.clone())),
            _ => None,
        },
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        path::{Path, PathBuf},
        time::Instant,
    };

    use super::*;
    use crate::testing::{
        Scratch,
        gate::{forking, write_executable},
    };

    const VERSION: &str = "v99.1.2";
    const EXEC_PATH: &str = "/opt/node/bin/node";

    /// A node that answers as the real one does and writes down how it was called.
    const NODE_STUB: &str = "#!/bin/sh\necho \"$#:$1:$2\" >> \"$0.calls\"\nprintf '%s\\n' '[\"v99.1.2\",\"/opt/node/bin/node\"]'\n";

    /// A setting with a node stub, an empty state directory, no config file and an empty `PATH`, in English.
    struct Fixture {
        scratch: Scratch,
        setting: Setting,
    }

    fn fixture() -> Fixture {
        let scratch = Scratch::new();
        let node = scratch.path().join("node");
        write_executable(&node, NODE_STUB);
        let setting = Setting {
            locale: Locale::En,
            state_dir: scratch.sub("state").to_string_lossy().into_owned(),
            config_file: scratch
                .path()
                .join("config/config.toml")
                .to_string_lossy()
                .into_owned(),
            path: scratch.sub("bin").to_string_lossy().into_owned(),
            node: node.into_os_string(),
            deadline: Duration::from_secs(10),
        };
        Fixture { scratch, setting }
    }

    /// What `serve` printed and the exit code; the spawn is under the fork gate because the stub was written under it.
    fn answer(setting: &Setting) -> (Vec<String>, u8) {
        let _forking = forking();
        let out = serve(setting, &Stop::default());
        assert_eq!(out.stderr, "", "doctor writes nothing to stderr");
        assert!(out.stdout.ends_with('\n'));
        (
            out.stdout
                .trim_end()
                .split('\n')
                .map(str::to_owned)
                .collect(),
            out.code,
        )
    }

    fn record(dir: &str, name: &str, body: &str) {
        fs::write(Path::new(dir).join(name), body).unwrap();
    }

    const ROW: &str = "1700000000\tworking\tsid\t/work\t/work/t.jsonl\tReading\n";

    #[test]
    fn the_verb_is_doctor() {
        assert_eq!(VERBS, [&["doctor"][..]]);
    }

    #[test]
    fn four_lines_say_node_state_config_and_claude_and_the_exit_is_0() {
        let f = fixture();
        let (lines, code) = answer(&f.setting);
        assert_eq!(code, 0);
        assert_eq!(
            lines,
            [
                format!("node {VERSION} ({EXEC_PATH})"),
                format!("agent state {} (0 record(s))", f.setting.state_dir),
                format!("config {}: missing", f.setting.config_file),
                "claude: missing".to_owned(),
            ]
        );
    }

    #[test]
    fn russian_prints_the_russian_catalogue() {
        let mut f = fixture();
        f.setting.locale = Locale::Ru;
        let (lines, code) = answer(&f.setting);
        assert_eq!(code, 0);
        assert_eq!(
            lines,
            [
                format!("node {VERSION} ({EXEC_PATH})"),
                format!("состояние агентов {} (0 запис(ь/и))", f.setting.state_dir),
                format!("конфиг {}: нет", f.setting.config_file),
                "claude: нет".to_owned(),
            ]
        );
    }

    #[test]
    fn node_is_asked_once_for_its_version_and_path() {
        let f = fixture();
        answer(&f.setting);
        let calls = fs::read_to_string(f.scratch.path().join("node.calls")).unwrap();
        assert_eq!(
            calls,
            "2:-p:JSON.stringify([process.version, process.execPath])\n"
        );
    }

    #[test]
    fn only_a_valid_record_is_counted() {
        let f = fixture();
        let dir = &f.setting.state_dir;
        record(dir, "1.tsv", ROW);
        // A record that does not parse, a file that is not a record, a record under a name that is not a key, a directory named like a record.
        record(dir, "2.tsv", "garbage\n");
        record(dir, "6.tsv", "1700000000\tgone\tsid\n");
        record(dir, "notes.txt", ROW);
        record(dir, "not a key.tsv", ROW);
        fs::create_dir(Path::new(dir).join("3.tsv")).unwrap();
        let (lines, _) = answer(&f.setting);
        assert_eq!(lines[1], format!("agent state {dir} (1 record(s))"));
        record(dir, "s-abc.tsv", ROW);
        let (lines, _) = answer(&f.setting);
        assert_eq!(lines[1], format!("agent state {dir} (2 record(s))"));
    }

    #[test]
    fn a_state_directory_that_does_not_exist_holds_no_records() {
        let mut f = fixture();
        f.setting.state_dir = f
            .scratch
            .path()
            .join("nowhere")
            .to_string_lossy()
            .into_owned();
        let (lines, code) = answer(&f.setting);
        assert_eq!(code, 0);
        assert_eq!(
            lines[1],
            format!("agent state {} (0 record(s))", f.setting.state_dir)
        );
    }

    #[test]
    fn the_config_file_is_present_when_it_exists() {
        let f = fixture();
        let file = PathBuf::from(&f.setting.config_file);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(&file, "").unwrap();
        let (lines, _) = answer(&f.setting);
        assert_eq!(
            lines[2],
            format!("config {}: present", f.setting.config_file)
        );
    }

    #[test]
    fn a_link_to_nothing_is_a_config_file_that_is_missing() {
        let f = fixture();
        let file = PathBuf::from(&f.setting.config_file);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(f.scratch.path().join("gone"), &file).unwrap();
        let (lines, _) = answer(&f.setting);
        assert_eq!(
            lines[2],
            format!("config {}: missing", f.setting.config_file)
        );
    }

    #[test]
    fn claude_is_the_first_executable_file_on_the_path() {
        let mut f = fixture();
        let first = f.scratch.sub("first");
        let second = f.scratch.sub("second");
        fs::write(first.join("claude"), "").unwrap();
        write_executable(&second.join("claude"), "#!/bin/sh\n");
        f.setting.path = format!("{}:{}", first.display(), second.display());
        let (lines, _) = answer(&f.setting);
        assert_eq!(
            lines[3],
            format!("claude: {}", second.join("claude").display())
        );
    }

    #[test]
    fn no_path_at_all_finds_no_claude() {
        let mut f = fixture();
        write_executable(&f.scratch.sub("bin").join("claude"), "#!/bin/sh\n");
        f.setting.path = String::new();
        let (lines, _) = answer(&f.setting);
        assert_eq!(lines[3], "claude: missing");
    }

    /// Line one when node cannot be asked, and the three others as they are with a node that can.
    fn assert_node_missing(f: &Fixture, line: &str) {
        let (lines, code) = answer(&f.setting);
        assert_eq!(code, 0);
        assert_eq!(lines.len(), 4);
        assert_eq!(lines[0], line);
        assert_eq!(
            lines[1],
            format!("agent state {} (0 record(s))", f.setting.state_dir)
        );
        assert_eq!(
            lines[2],
            format!("config {}: missing", f.setting.config_file)
        );
        assert_eq!(lines[3], "claude: missing");
    }

    #[test]
    fn a_node_that_is_not_there_is_missing_and_the_other_three_lines_stay() {
        let mut f = fixture();
        f.setting.node = f.scratch.path().join("no-such-node").into_os_string();
        assert_node_missing(&f, "node: missing");
        f.setting.locale = Locale::Ru;
        let (lines, code) = answer(&f.setting);
        assert_eq!(code, 0);
        assert_eq!(lines[0], "node: нет");
        assert_eq!(lines.len(), 4);
    }

    #[test]
    fn a_node_that_fails_or_answers_anything_but_two_strings_is_missing() {
        for (what, script) in [
            ("exits 1", "printf '%s\\n' '[\"v1\",\"/n\"]'; exit 1"),
            ("an array of one", "printf '%s\\n' '[\"v1\"]'"),
            (
                "an array of three",
                "printf '%s\\n' '[\"v1\",\"/n\",\"x\"]'",
            ),
            ("a number among them", "printf '%s\\n' '[\"v1\",2]'"),
            ("an object", "printf '%s\\n' '{\"a\":1}'"),
            ("a string", "printf '%s\\n' '\"v1\"'"),
            ("text that is not JSON", "printf '%s\\n' 'v1 /n'"),
            (
                "two arrays",
                "printf '%s\\n%s\\n' '[\"v1\",\"/n\"]' '[\"v1\",\"/n\"]'",
            ),
            ("nothing", "true"),
            ("something on stderr and nothing else", "echo oops >&2"),
        ] {
            let mut f = fixture();
            let node = f.scratch.path().join("odd-node");
            write_executable(&node, &format!("#!/bin/sh\n{script}\n"));
            f.setting.node = node.into_os_string();
            let (lines, code) = answer(&f.setting);
            assert_eq!(code, 0, "{what}");
            assert_eq!(lines.len(), 4, "{what}");
            assert_eq!(lines[0], "node: missing", "{what}");
        }
    }

    #[test]
    fn this_process_gives_node_ten_seconds_to_answer() {
        // The requirement "doctor asks node once and survives its absence" says 10 seconds; the tests below inject a shorter one through the setting.
        assert_eq!(Setting::current().deadline, Duration::from_secs(10));
    }

    #[test]
    fn a_node_that_does_not_answer_in_time_is_stopped_and_missing() {
        let mut f = fixture();
        let node = f.scratch.path().join("slow-node");
        write_executable(&node, "#!/bin/sh\nexec sleep 30\n");
        f.setting.node = node.into_os_string();
        f.setting.deadline = Duration::from_millis(200);
        let started = Instant::now();
        assert_node_missing(&f, "node: missing");
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn a_directory_that_looks_like_a_placeholder_or_a_nested_key_prints_as_typed() {
        let mut f = fixture();
        f.setting.state_dir = f
            .scratch
            .path()
            .join("{{x}}$t(missing)")
            .to_string_lossy()
            .into_owned();
        let (lines, _) = answer(&f.setting);
        assert_eq!(
            lines[1],
            format!("agent state {} (0 record(s))", f.setting.state_dir)
        );
    }
}
