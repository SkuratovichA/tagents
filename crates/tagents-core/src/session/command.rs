//! `buildArgs` and `childEnv` of `packages/core/src/claude-driver.ts`, and what node takes from its own process to make them: the argv and the environment of the child of `session prompt` (design D4).
//!
//! What `spawn` would refuse is not worded here: a value that cannot be an argument or an environment entry hands the call to node before anything is started (design D2), and so does an environment Rust cannot rebuild entry for entry and a machine with no node to name.

use std::collections::BTreeMap;
use std::ffi::OsString;

use rustix::process::Signal;

use crate::node;
use crate::session::reference::{Reference, Spec};

/// The argv of the child, the prompt last: a text that starts with `-` is never read as an option, and no variadic option touches it.
pub fn args(spec: &Spec, text: &str, resume: Option<&str>) -> Vec<String> {
    let set = |value: &'_ Option<String>| value.clone().filter(|value| !value.is_empty());
    let mut args = vec!["-p".to_owned()];
    let mut add = |words: &[&str]| args.extend(words.iter().map(|word| (*word).to_owned()));
    if let Some(model) = set(&spec.model) {
        add(&["--model", &model]);
    }
    if let Some(effort) = set(&spec.effort) {
        add(&["--effort", &effort]);
    }
    if let Some(tools) = spec
        .disallowed_tools
        .as_ref()
        .filter(|tools| !tools.is_empty())
    {
        add(&["--disallowedTools", &tools.join(",")]);
    }
    if let Some(config) = set(&spec.mcp_config) {
        add(&["--strict-mcp-config", "--mcp-config", &config]);
    }
    add(&["--output-format", "stream-json", "--verbose"]);
    if spec.skip_permissions {
        add(&["--dangerously-skip-permissions"]);
    }
    if let Some(file) = set(&spec.system_prompt_file) {
        add(&["--append-system-prompt-file", &file]);
    }
    if let Some(resume) = resume.filter(|resume| !resume.is_empty()) {
        add(&["--resume", resume]);
    }
    add(&[text]);
    args
}

/// The environment of the child, from the parent's: every `CLAUDE*` name dropped, the account chosen by `spec.configDir` (absent keeps the inherited one, `null` is none), the node directory and `~/.local/bin` in front of the inherited `PATH` with duplicates and empty entries gone, and `spec.env` last, which wins over all of it.
pub fn environment(
    spec: &Spec,
    parent: &BTreeMap<String, String>,
    node_dir: &str,
    home: &str,
) -> BTreeMap<String, String> {
    let mut env = parent.clone();
    let inherited_account = env.get("CLAUDE_CONFIG_DIR").cloned();
    env.retain(|name, _| !name.starts_with("CLAUDE"));
    let account = match &spec.config_dir {
        None => inherited_account,
        Some(choice) => choice.clone(),
    };
    if let Some(account) = account.filter(|account| !account.is_empty()) {
        env.insert("CLAUDE_CONFIG_DIR".to_owned(), account);
    }

    let inherited = env.get("PATH").map_or("", String::as_str);
    let local_bin = node::join(home, ".local/bin");
    let wanted = inherited.split(':').filter(|entry| !entry.is_empty());
    let mut entries: Vec<&str> = Vec::new();
    for entry in [node_dir, local_bin.as_str()].into_iter().chain(wanted) {
        if !entries.contains(&entry) {
            entries.push(entry);
        }
    }
    let path = entries.join(":");
    env.insert("PATH".to_owned(), path);

    if let Some(label) = spec.label.clone().filter(|label| !label.is_empty()) {
        env.insert("TA_LABEL".to_owned(), label);
    }
    if let Some(log) = spec.log_file.clone().filter(|log| !log.is_empty()) {
        env.insert("TA_LOG".to_owned(), log);
    }
    for (name, value) in spec.env.iter().flatten() {
        env.insert(name.clone(), value.clone());
    }
    env
}

/// `{...process.env}` of this process, or `None` when node would not read the same entries: a name or a value that is not UTF-8 (the child's environment is built from it, entry for entry), or a name that starts with `=`, which `process.env` cannot read back. A name written twice is the first one, which is the value `getenv` gives.
pub fn parent_environment(
    vars: impl IntoIterator<Item = (OsString, OsString)>,
) -> Option<BTreeMap<String, String>> {
    let mut env = BTreeMap::new();
    for (name, value) in vars {
        let (name, value) = (name.into_string().ok()?, value.into_string().ok()?);
        if name.starts_with('=') {
            return None;
        }
        env.entry(name).or_insert(value);
    }
    Some(env)
}

/// `path.dirname(process.execPath)` as far as Rust can tell: the directory of the real path of the node the front door would run (`node::interpreter`). `None` when there is no such file: the call goes to the front door, which words that.
pub fn node_directory(interpreter: &str, cwd: &str, path_var: &str) -> Option<String> {
    let file = if interpreter.contains('/') {
        let file = node::resolve(cwd, interpreter);
        node::is_executable_file(&file).then_some(file)?
    } else {
        node::resolve(cwd, &node::find_on_path(interpreter, path_var)?)
    };
    let real = node::realpath(&file).ok()?;
    let (directory, _) = real.rsplit_once('/')?;
    Some(if directory.is_empty() { "/" } else { directory }.to_owned())
}

/// What `session prompt` starts.
#[derive(Debug, Clone, PartialEq)]
pub struct Invocation {
    /// `spec.bin`, else `claude`.
    pub program: String,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    /// `spec.cwd`; empty is the working directory of the CLI.
    pub cwd: String,
}

impl Invocation {
    /// The child of a turn, or `None` for a NUL anywhere in it, which `spawn` refuses. The rest of what it refuses cannot come through here: `reference::read` hands over the name of an environment entry and an empty `bin`, and a state row has neither.
    pub fn of(
        reference: &Reference,
        text: &str,
        parent: &BTreeMap<String, String>,
        node_dir: &str,
        home: &str,
    ) -> Option<Invocation> {
        let spec = &reference.spec;
        let invocation = Invocation {
            program: spec.bin.clone().unwrap_or_else(|| "claude".to_owned()),
            args: args(spec, text, reference.claude_session_id.as_deref()),
            env: environment(spec, parent, node_dir, home),
            cwd: spec.cwd.clone(),
        };
        let clean = |value: &str| !value.contains('\0');
        let fine = clean(&invocation.program)
            && clean(&invocation.cwd)
            && invocation.args.iter().all(|arg| clean(arg))
            && invocation
                .env
                .iter()
                .all(|(name, value)| clean(name) && clean(value));
        fine.then_some(invocation)
    }
}

/// The names `process.signalCode` can hold on this platform: `signo_string` of node, whose first name wins for a number that has two (`SIGABRT` before `SIGIOT`, `SIGIO` before `SIGPOLL`).
const SIGNALS: &[(Signal, &str)] = &[
    (Signal::HUP, "SIGHUP"),
    (Signal::INT, "SIGINT"),
    (Signal::QUIT, "SIGQUIT"),
    (Signal::ILL, "SIGILL"),
    (Signal::TRAP, "SIGTRAP"),
    (Signal::ABORT, "SIGABRT"),
    (Signal::BUS, "SIGBUS"),
    (Signal::FPE, "SIGFPE"),
    (Signal::KILL, "SIGKILL"),
    (Signal::USR1, "SIGUSR1"),
    (Signal::SEGV, "SIGSEGV"),
    (Signal::USR2, "SIGUSR2"),
    (Signal::PIPE, "SIGPIPE"),
    (Signal::ALARM, "SIGALRM"),
    (Signal::TERM, "SIGTERM"),
    (Signal::CHILD, "SIGCHLD"),
    #[cfg(target_os = "linux")]
    (Signal::STKFLT, "SIGSTKFLT"),
    (Signal::CONT, "SIGCONT"),
    (Signal::STOP, "SIGSTOP"),
    (Signal::TSTP, "SIGTSTP"),
    (Signal::TTIN, "SIGTTIN"),
    (Signal::TTOU, "SIGTTOU"),
    (Signal::URG, "SIGURG"),
    (Signal::XCPU, "SIGXCPU"),
    (Signal::XFSZ, "SIGXFSZ"),
    (Signal::VTALARM, "SIGVTALRM"),
    (Signal::PROF, "SIGPROF"),
    (Signal::WINCH, "SIGWINCH"),
    (Signal::IO, "SIGIO"),
    #[cfg(target_os = "linux")]
    (Signal::POWER, "SIGPWR"),
    #[cfg(target_os = "macos")]
    (Signal::INFO, "SIGINFO"),
    (Signal::SYS, "SIGSYS"),
];

/// The name node gives a signal number. A number it has no name for is `None`, which node reports as the exit code 0 and no signal.
pub fn signal_name(number: i32) -> Option<&'static str> {
    SIGNALS
        .iter()
        .find(|(signal, _)| signal.as_raw() == number)
        .map(|(_, name)| *name)
}

#[cfg(test)]
mod tests {
    use std::os::unix::ffi::OsStringExt;

    use super::*;
    use crate::session::reference;

    fn spec(extra: &str) -> Spec {
        let comma = if extra.is_empty() { "" } else { "," };
        let text = format!(
            r#"{{"id":"s","claudeSessionId":null,"transcript":null,"spec":{{"kind":"claude","cwd":"/w","skipPermissions":false{comma}{extra}}}}}"#
        );
        match reference::read(&text) {
            reference::Read::Ref(reference) => reference.spec,
            other => panic!("{text}: {other:?}"),
        }
    }

    fn parent(entries: &[(&str, &str)]) -> BTreeMap<String, String> {
        entries
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect()
    }

    #[test]
    fn the_argv_is_in_the_order_of_build_args_with_the_prompt_last() {
        assert_eq!(
            args(&spec(""), "-x go", None),
            ["-p", "--output-format", "stream-json", "--verbose", "-x go"]
        );
        let all = spec(
            r#""model":"m","effort":"e","disallowedTools":["A","B"],"mcpConfig":"/m","systemPromptFile":"/p","skipPermissions":true"#,
        );
        assert_eq!(
            args(&all, "go", Some("id")),
            [
                "-p",
                "--model",
                "m",
                "--effort",
                "e",
                "--disallowedTools",
                "A,B",
                "--strict-mcp-config",
                "--mcp-config",
                "/m",
                "--output-format",
                "stream-json",
                "--verbose",
                "--dangerously-skip-permissions",
                "--append-system-prompt-file",
                "/p",
                "--resume",
                "id",
                "go"
            ]
        );
        // Empty is left out, as a falsy value is.
        let empty = spec(
            r#""model":"","effort":"","disallowedTools":[],"mcpConfig":"","systemPromptFile":"""#,
        );
        assert_eq!(args(&empty, "go", Some("")), args(&spec(""), "go", None));
    }

    #[test]
    fn every_claude_name_goes_and_the_account_is_the_choice_of_the_spec() {
        let from = parent(&[
            ("CLAUDE_CONFIG_DIR", "/a"),
            ("CLAUDE_X", "1"),
            ("CLAUDECODE", "1"),
            ("Claude_low", "2"),
            ("NOTCLAUDE", "3"),
        ]);
        let env = environment(&spec(""), &from, "/n", "/h");
        assert_eq!(env.get("CLAUDE_CONFIG_DIR").map(String::as_str), Some("/a"));
        assert!(!env.contains_key("CLAUDE_X") && !env.contains_key("CLAUDECODE"));
        assert!(env.contains_key("Claude_low") && env.contains_key("NOTCLAUDE"));
        let none = environment(&spec(r#""configDir":null"#), &from, "/n", "/h");
        assert!(!none.contains_key("CLAUDE_CONFIG_DIR"));
        let chosen = environment(&spec(r#""configDir":"/c""#), &from, "/n", "/h");
        assert_eq!(
            chosen.get("CLAUDE_CONFIG_DIR").map(String::as_str),
            Some("/c")
        );
        let empty = environment(&spec(r#""configDir":"""#), &from, "/n", "/h");
        assert!(!empty.contains_key("CLAUDE_CONFIG_DIR"));
        let inherited_empty =
            environment(&spec(""), &parent(&[("CLAUDE_CONFIG_DIR", "")]), "/n", "/h");
        assert!(!inherited_empty.contains_key("CLAUDE_CONFIG_DIR"));
    }

    #[test]
    fn the_path_is_the_node_directory_then_local_bin_then_the_inherited_entries_once() {
        let path = |value: &str, node_dir: &str| {
            environment(&spec(""), &parent(&[("PATH", value)]), node_dir, "/h")["PATH"].clone()
        };
        assert_eq!(path("/a:/b:/a", "/n"), "/n:/h/.local/bin:/a:/b");
        assert_eq!(path("/a::/b:", "/n"), "/n:/h/.local/bin:/a:/b");
        assert_eq!(path("/a:/n:/h/.local/bin", "/n"), "/n:/h/.local/bin:/a");
        assert_eq!(path("", "/n"), "/n:/h/.local/bin");
        // A node that lives in the local bin is one entry, where the duplicate is dropped.
        assert_eq!(path("/a", "/h/.local/bin"), "/h/.local/bin:/a");
        assert_eq!(
            environment(&spec(""), &parent(&[]), "/n", "/h")["PATH"],
            "/n:/h/.local/bin"
        );
    }

    #[test]
    fn the_label_and_the_log_are_set_when_not_empty_and_the_spec_env_wins() {
        let from = parent(&[("TA_LABEL", "old"), ("TA_LOG", "/old")]);
        let kept = environment(&spec(r#""label":"","logFile":"""#), &from, "/n", "/h");
        assert_eq!(
            (kept["TA_LABEL"].as_str(), kept["TA_LOG"].as_str()),
            ("old", "/old")
        );
        let set = environment(&spec(r#""label":"l","logFile":"/l""#), &from, "/n", "/h");
        assert_eq!(
            (set["TA_LABEL"].as_str(), set["TA_LOG"].as_str()),
            ("l", "/l")
        );
        let wins = environment(
            &spec(
                r#""label":"l","configDir":"/c","env":{"TA_LABEL":"mine","PATH":"/mine","CLAUDE_X":"9","CLAUDE_CONFIG_DIR":"/env","E":""}"#,
            ),
            &from,
            "/n",
            "/h",
        );
        assert_eq!(wins["TA_LABEL"], "mine");
        assert_eq!(wins["PATH"], "/mine");
        assert_eq!(wins["CLAUDE_X"], "9");
        assert_eq!(wins["CLAUDE_CONFIG_DIR"], "/env");
        assert_eq!(wins["E"], "");
    }

    #[test]
    fn an_environment_rust_cannot_rebuild_is_handed_over() {
        let vars = |entries: Vec<(Vec<u8>, Vec<u8>)>| {
            parent_environment(
                entries
                    .into_iter()
                    .map(|(k, v)| (OsString::from_vec(k), OsString::from_vec(v))),
            )
        };
        assert!(vars(vec![(b"A".to_vec(), b"1".to_vec())]).is_some());
        assert!(vars(vec![(b"A".to_vec(), b"\xff".to_vec())]).is_none());
        assert!(vars(vec![(b"\xff".to_vec(), b"1".to_vec())]).is_none());
        assert!(vars(vec![(b"=A".to_vec(), b"1".to_vec())]).is_none());
        // `getenv` finds the first of a name written twice.
        let twice = vars(vec![
            (b"A".to_vec(), b"1".to_vec()),
            (b"A".to_vec(), b"2".to_vec()),
        ])
        .unwrap();
        assert_eq!(twice["A"], "1");
    }

    #[test]
    fn the_node_directory_is_that_of_the_real_path() {
        let scratch = crate::testing::Scratch::new();
        let real = scratch.sub("real");
        let links = scratch.sub("links");
        std::fs::create_dir_all(&real).unwrap();
        std::fs::create_dir_all(&links).unwrap();
        let node_file = real.join("node");
        crate::testing::gate::write_executable(&node_file, "#!/bin/sh\n");
        std::os::unix::fs::symlink(&node_file, links.join("node")).unwrap();
        std::fs::write(real.join("plain"), "not executable").unwrap();
        let root = node::realpath(scratch.dir()).unwrap();
        let want = format!("{root}/real");
        let links_dir = links.to_str().unwrap();
        // Named by a path, a symbolic link followed; found on PATH; relative to the working directory.
        assert_eq!(
            node_directory(&format!("{links_dir}/node"), "/", "").as_deref(),
            Some(want.as_str())
        );
        assert_eq!(
            node_directory("node", "/", links_dir).as_deref(),
            Some(want.as_str())
        );
        assert_eq!(
            node_directory("links/node", &root, "").as_deref(),
            Some(want.as_str())
        );
        // Nothing to name.
        assert_eq!(node_directory("node", "/", ""), None);
        assert_eq!(node_directory("node", "/", "/no/such/dir"), None);
        assert_eq!(node_directory("/no/such/node", "/", ""), None);
        assert_eq!(node_directory(&format!("{root}/real/plain"), "/", ""), None);
        assert_eq!(node_directory(&format!("{root}/real"), "/", ""), None);
    }

    fn reference_of(spec_value: Spec, resume: Option<&str>) -> Reference {
        Reference {
            id: "s".to_owned(),
            claude_session_id: resume.map(str::to_owned),
            transcript: None,
            spec: spec_value,
        }
    }

    #[test]
    fn the_invocation_is_the_program_the_args_the_env_and_the_directory() {
        let mut with_bin = spec(r#""bin":"/b""#);
        with_bin.cwd = String::new();
        let invocation = Invocation::of(
            &reference_of(with_bin, Some("id")),
            "go",
            &parent(&[]),
            "/n",
            "/h",
        )
        .unwrap();
        assert_eq!(invocation.program, "/b");
        assert_eq!(invocation.cwd, "");
        assert_eq!(invocation.args.last().map(String::as_str), Some("go"));
        assert!(invocation.args.contains(&"--resume".to_owned()));
        assert_eq!(
            Invocation::of(
                &reference_of(spec(""), None),
                "go",
                &parent(&[]),
                "/n",
                "/h"
            )
            .unwrap()
            .program,
            "claude"
        );
    }

    #[test]
    fn a_nul_from_a_state_row_hands_the_call_over() {
        let call =
            |reference: Reference| Invocation::of(&reference, "go", &parent(&[]), "/n", "/h");
        assert!(call(reference_of(spec(""), None)).is_some());
        // A state row is not checked where it is read, and each of its fields that reaches the child comes through here.
        assert!(call(reference_of(spec(""), Some("a\0b"))).is_none());
        let mut bad = spec("");
        bad.cwd = "/a\0b".to_owned();
        assert!(call(reference_of(bad, None)).is_none());
        let mut bad = spec("");
        bad.label = Some("a\0b".to_owned());
        assert!(call(reference_of(bad, None)).is_none());
        let mut bad = spec("");
        bad.config_dir = Some(Some("a\0b".to_owned()));
        assert!(call(reference_of(bad, None)).is_none());
    }

    /// What `reference::read` hands over before an invocation is made: the classes of design D2 that have their own words in node.
    #[test]
    fn a_reference_with_a_value_spawn_refuses_is_handed_over_when_it_is_read() {
        let of = |extra: &str| {
            let text = format!(
                r#"{{"id":"s","claudeSessionId":null,"transcript":null,"spec":{{"kind":"claude","cwd":"/w","skipPermissions":false,{extra}}}}}"#
            );
            reference::read(&text)
        };
        assert!(matches!(of(r#""bin":"/b""#), reference::Read::Ref(_)));
        assert!(matches!(of(r#""bin":"b""#), reference::Read::Ref(_)));
        for extra in [
            r#""env":{"A=B":"v"}"#,
            r#""env":{"":"v"}"#,
            r#""env":{"A\u0000B":"v"}"#,
            r#""env":{"A":"v\u0000"}"#,
            r#""bin":"""#,
            r#""bin":"./b""#,
            r#""bin":"a\u0000b""#,
            r#""model":"a\u0000b""#,
            r#""disallowedTools":["a\u0000b"]"#,
        ] {
            assert_eq!(of(extra), reference::Read::HandOver, "{extra}");
        }
    }

    /// The numbers of the table against the C library of the target.
    #[test]
    fn the_numbers_of_the_signal_table_are_those_of_libc() {
        let libc_numbers = [
            ("SIGHUP", libc::SIGHUP),
            ("SIGINT", libc::SIGINT),
            ("SIGQUIT", libc::SIGQUIT),
            ("SIGILL", libc::SIGILL),
            ("SIGTRAP", libc::SIGTRAP),
            ("SIGABRT", libc::SIGABRT),
            ("SIGBUS", libc::SIGBUS),
            ("SIGFPE", libc::SIGFPE),
            ("SIGKILL", libc::SIGKILL),
            ("SIGUSR1", libc::SIGUSR1),
            ("SIGSEGV", libc::SIGSEGV),
            ("SIGUSR2", libc::SIGUSR2),
            ("SIGPIPE", libc::SIGPIPE),
            ("SIGALRM", libc::SIGALRM),
            ("SIGTERM", libc::SIGTERM),
            ("SIGCHLD", libc::SIGCHLD),
            #[cfg(target_os = "linux")]
            ("SIGSTKFLT", libc::SIGSTKFLT),
            ("SIGCONT", libc::SIGCONT),
            ("SIGSTOP", libc::SIGSTOP),
            ("SIGTSTP", libc::SIGTSTP),
            ("SIGTTIN", libc::SIGTTIN),
            ("SIGTTOU", libc::SIGTTOU),
            ("SIGURG", libc::SIGURG),
            ("SIGXCPU", libc::SIGXCPU),
            ("SIGXFSZ", libc::SIGXFSZ),
            ("SIGVTALRM", libc::SIGVTALRM),
            ("SIGPROF", libc::SIGPROF),
            ("SIGWINCH", libc::SIGWINCH),
            ("SIGIO", libc::SIGIO),
            #[cfg(target_os = "linux")]
            ("SIGPWR", libc::SIGPWR),
            #[cfg(target_os = "macos")]
            ("SIGINFO", libc::SIGINFO),
            ("SIGSYS", libc::SIGSYS),
        ];
        assert_eq!(libc_numbers.len(), SIGNALS.len());
        for (name, number) in libc_numbers {
            assert_eq!(signal_name(number), Some(name), "{number}");
        }
        // A number with no name in node's table.
        #[cfg(target_os = "macos")]
        assert_eq!(signal_name(libc::SIGEMT), None);
        // The lowest real-time signal the C library leaves to a program.
        #[cfg(target_os = "linux")]
        assert_eq!(signal_name(34), None);
        assert_eq!(signal_name(0), None);
        assert_eq!(signal_name(1000), None);
    }
}
