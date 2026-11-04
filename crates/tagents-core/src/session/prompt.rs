//! `session prompt`: one turn of `claude`, as `session()` of `packages/core/src/cli/main.ts` and `ClaudeHeadlessDriver.prompt` serve it. The child's environment is built from this process's, with what is not UTF-8 read lossily, and its `PATH` begins with the directory of the node the front door would run (none, on a machine with no node).

use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::{self, Sender};
use std::time::{Duration, Instant};

use crate::child::spawn_thread;
use crate::front_door::{emit_stderr, emit_stdout};
use crate::js;
use crate::messages::Texts;
use crate::node;
use crate::notify::clock::{Clock, SystemClock};
use crate::parse_args::{Grammar, Kind, Parsed};
use crate::session::command::{self, Invocation};
use crate::session::outcome::Outcome;
use crate::session::read::{Setting, usage};
use crate::session::reference::{self, Resolved};
use crate::session::spawn::{self, Start};
use crate::session::turn::supervisor::Watch;
use crate::session::turn::{self, DEFAULT_TIMEOUT_MS, Turn};
use crate::sessions::{Output, exit};

pub(crate) const PROMPT: Grammar = Grammar {
    options: &[
        ("timeout", Kind::Text),
        ("warn-before", Kind::Text),
        ("events", Kind::Flag),
    ],
    positionals: true,
};

/// How long the error line waits for stdout, so that two streams on one pipe keep their order, and a stdout nobody reads cannot hold back the line.
const ORDER_WAIT: Duration = Duration::from_secs(1);

/// What the child's start depends on, besides the reference.
struct Machine {
    parent: BTreeMap<String, String>,
    node_dir: String,
    home: String,
}

impl Machine {
    /// This process's.
    fn current(setting: &Setting) -> Machine {
        let parent = command::parent_environment(std::env::vars_os());
        let interpreter = node::interpreter();
        let path = parent.get("PATH").map_or("", String::as_str);
        let node_dir = command::node_directory(
            &interpreter.to_string_lossy(),
            setting.cwd.as_deref().unwrap_or("/"),
            path,
        );
        Machine {
            parent,
            node_dir,
            home: node::homedir(),
        }
    }
}

/// `num(raw, fallback)` of `main.ts`.
fn limit_ms(raw: Option<&str>) -> f64 {
    raw.map(js::number)
        .filter(|limit| limit.is_finite() && *limit > 0.0)
        .unwrap_or(DEFAULT_TIMEOUT_MS)
}

enum Write {
    Text(String),
    Written(Sender<()>),
}

/// Stdout, written by one thread of its own. Node's writes to a pipe are asynchronous: a reader that stopped reading holds up neither the turn nor the time limit, and everything reaches it when it comes back.
struct Stdout(Sender<Write>);

impl Stdout {
    fn start(mut write: impl FnMut(&str) + Send + 'static) -> Result<Stdout, String> {
        let (writes, queue) = mpsc::channel();
        spawn_thread("stdout", move || {
            for item in queue {
                match item {
                    Write::Text(text) => write(&text),
                    Write::Written(told) => {
                        let _ = told.send(());
                    }
                }
            }
        })?;
        Ok(Stdout(writes))
    }

    fn write(&self, text: String) {
        let _ = self.0.send(Write::Text(text));
    }

    /// Whether everything given so far has been written within `limit`, or, without one, whenever that is.
    fn written(&self, limit: Option<Duration>) -> bool {
        let (told, wait) = mpsc::channel();
        if self.0.send(Write::Written(told)).is_err() {
            return true;
        }
        match limit {
            Some(limit) => wait.recv_timeout(limit).is_ok(),
            None => wait.recv().is_ok(),
        }
    }
}

/// `session prompt <ref-json-or-id> <text>`.
pub fn prompt(args: &[String], setting: &Setting, texts: &Texts) -> Output {
    let parsed = match PROMPT.parse(args) {
        Ok(parsed) => parsed,
        Err(err) => return Output::refused_args(&err),
    };
    let machine = Machine::current(setting);
    // Under a caller that left SIGCHLD ignored Linux reaps the child itself, waiting for it finds nothing, and a good turn reads as a failure, where node sets its dispositions back when it starts. A handler that only sets a flag is the safe form of not ignoring it, and exec sets it back to the default for the child and for node; a failed registration leaves what was inherited.
    let _ = signal_hook::flag::register(
        signal_hook::consts::SIGCHLD,
        Arc::new(AtomicBool::new(false)),
    );
    answer(&parsed, setting, texts, &machine, emit_stdout, emit_stderr)
}

fn answer(
    parsed: &Parsed,
    setting: &Setting,
    texts: &Texts,
    machine: &Machine,
    stdout: impl FnMut(&str) + Send + 'static,
    stderr: impl FnOnce(&str),
) -> Output {
    let words = parsed.words();
    let raw_ref = words.first().copied().filter(|raw| !raw.is_empty());
    let (Some(raw_ref), Some(text)) = (raw_ref, words.get(1).copied()) else {
        return usage(texts.t("missingOption", &[("option", "<ref> <text>")]));
    };
    if js::trim(text).is_empty() {
        return usage(texts.t("noPrompt", &[]));
    }
    let reference = match reference::resolve(raw_ref, &setting.state_dir) {
        Resolved::Ref(reference) => reference,
        Resolved::NoMatch => {
            return Output::line(exit::ERROR, &texts.t("badRef", &[("ref", raw_ref)]));
        }
    };
    let invocation = Invocation::of(
        &reference,
        text,
        &machine.parent,
        &machine.node_dir,
        &machine.home,
    );
    let events = parsed.flag("events");
    let limit = limit_ms(parsed.value("timeout"));
    // What may fail without a word comes before the child, so that nothing has run when it does.
    let out = match Stdout::start(stdout) {
        Ok(out) => out,
        Err(why) => {
            return Output::line(
                exit::ERROR,
                &format!("tagents-core: cannot start a thread: {why}"),
            );
        }
    };
    let watch = match Watch::start() {
        Ok(watch) => watch,
        Err(why) => {
            return Output::line(
                exit::ERROR,
                &format!("tagents-core: cannot watch the child: {why}"),
            );
        }
    };
    // Read before the spawn, as node reads `startedAt`: what the start of the child costs counts towards the limit and `durationMs`.
    let (started, started_ms) = (Instant::now(), SystemClock.now_ms());
    match spawn::start(&invocation) {
        Start::Started(child) => {
            #[cfg(target_os = "macos")]
            let awake = crate::session::awake::hold(child.id());
            let mut world = watch.watch(child, |line: &str| out.write(format!("{line}\n")));
            let mut turn = Turn::new(limit, events, started, started_ms);
            let outcome = turn::run(&mut turn, &mut world);
            #[cfg(target_os = "macos")]
            if let Some(awake) = awake {
                crate::session::awake::release(awake);
            }
            out.write(outcome.document(events));
            if let Some(line) = outcome.error_line() {
                out.written(Some(ORDER_WAIT));
                stderr(&format!("{line}\n"));
            }
            turn::linger(&mut turn, &mut world);
            out.written(None);
            Output {
                stdout: String::new(),
                stderr: String::new(),
                code: outcome.exit_code(),
            }
        }
        Start::Failed(detail) => {
            let outcome = Outcome::SpawnFailed(detail);
            Output {
                stdout: outcome.document(events),
                stderr: outcome
                    .error_line()
                    .map_or_else(String::new, |line| format!("{line}\n")),
                code: outcome.exit_code(),
            }
        }
        Start::Thrown(message) => Output::line(exit::ERROR, &message),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;
    use crate::messages::Locale;
    use crate::testing::{Scratch, gate};

    fn setting(state_dir: &str) -> Setting {
        Setting {
            cwd: Some("/base".to_owned()),
            state_dir: state_dir.to_owned(),
            locale: Locale::En,
        }
    }

    fn machine(path: &str) -> Machine {
        Machine {
            parent: BTreeMap::from([("PATH".to_owned(), path.to_owned())]),
            node_dir: "/node".to_owned(),
            home: "/home".to_owned(),
        }
    }

    fn words(args: &[&str]) -> Vec<String> {
        args.iter().map(|a| (*a).to_owned()).collect()
    }

    /// The answer of a call, with what was written while it ran: stdout, then stderr.
    fn call(args: &[&str], path: &str) -> (Output, String, String) {
        let args = words(args);
        let parsed = PROMPT.parse(&args).unwrap();
        let (out, err) = (
            Arc::new(Mutex::new(String::new())),
            Arc::new(Mutex::new(String::new())),
        );
        let (out_end, err_end) = (Arc::clone(&out), Arc::clone(&err));
        let output = answer(
            &parsed,
            &setting("/no/such/state"),
            &Texts::load(Locale::En).unwrap(),
            &machine(path),
            move |text: &str| out_end.lock().unwrap().push_str(text),
            |text: &str| err_end.lock().unwrap().push_str(text),
        );
        let (out, err) = (out.lock().unwrap().clone(), err.lock().unwrap().clone());
        (output, out, err)
    }

    fn reference(cwd: &str) -> String {
        format!(
            r#"{{"id":"r1","claudeSessionId":null,"transcript":null,"spec":{{"kind":"claude","cwd":"{cwd}","skipPermissions":false}}}}"#
        )
    }

    #[test]
    fn the_grammar_words_what_node_words() {
        for args in [
            &["--bogus", "r", "t"][..],
            &["r", "t", "--timeout"],
            &["r", "t", "--timeout", "-5"],
            &["r", "t", "--events=x"],
            &["r", "-x"],
        ] {
            assert!(PROMPT.parse(&words(args)).is_err(), "{args:?}");
        }
    }

    #[test]
    fn the_checks_come_in_the_order_of_main() {
        let missing = "missing required option <ref> <text>\n";
        for args in [&[][..], &["r"], &["", "t"]] {
            let (output, _, _) = call(args, "/usr/bin");
            assert_eq!(
                (output.stderr.as_str(), output.code),
                (missing, exit::USAGE)
            );
        }
        for text in ["", " \n\t "] {
            let (output, _, _) = call(&["nobody", text], "/usr/bin");
            assert_eq!(output.stderr, "nothing to say: the prompt text is empty\n");
            assert_eq!(output.code, exit::USAGE);
        }
        let (output, _, _) = call(&["nobody", "t"], "/usr/bin");
        assert_eq!(output.stderr, "no session matches nobody\n");
        assert_eq!(output.code, exit::ERROR);
    }

    #[test]
    fn a_child_that_cannot_be_started_is_the_outcome_or_the_message() {
        let scratch = Scratch::new();
        let cwd = scratch.path().to_str().unwrap();
        let (output, out, err) = call(&[&reference(cwd), "t", "--events"], "/no/such");
        assert_eq!(
            output.stdout,
            "{\"kind\":\"spawn-failed\",\"detail\":\"spawn claude ENOENT\"}\n"
        );
        assert_eq!(output.stderr, "exit=null spawn: spawn claude ENOENT\n");
        assert_eq!(output.code, exit::ERROR);
        assert_eq!((out.as_str(), err.as_str()), ("", ""));

        let file = scratch.path().join("a-file");
        std::fs::write(&file, "x").unwrap();
        let (output, _, _) = call(&[&reference(file.to_str().unwrap()), "t"], "/usr/bin:/bin");
        assert_eq!(output.stdout, "");
        assert_eq!(output.stderr, "spawn ENOTDIR\n");
        assert_eq!(output.code, exit::ERROR);
    }

    #[test]
    fn a_failure_without_a_name_in_the_table_is_worded_by_its_code() {
        let scratch = Scratch::new();
        let looping = scratch.path().join("loop");
        std::fs::create_dir_all(&looping).unwrap();
        std::os::unix::fs::symlink("claude", looping.join("claude")).unwrap();
        let (output, out, err) = call(
            &[&reference(scratch.path().to_str().unwrap()), "t"],
            looping.to_str().unwrap(),
        );
        assert_eq!(output.stderr, "spawn ELOOP\n");
        assert_eq!(output.code, exit::ERROR);
        assert_eq!((out.as_str(), err.as_str()), ("", ""));
    }

    #[test]
    fn a_turn_writes_its_events_then_its_outcome_and_gives_its_exit_code() {
        let scratch = Scratch::new();
        gate::write_executable(
            &scratch.path().join("bin/claude"),
            "#!/bin/sh\nprintf '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}\\n'\necho boom >&2\nexit 3\n",
        );
        let cwd = scratch.path().to_str().unwrap();
        let path = scratch.path().join("bin");
        let (output, out, err) = call(&[&reference(cwd), "t", "--events"], path.to_str().unwrap());
        assert_eq!(output.stdout, "");
        assert_eq!(output.stderr, "");
        assert_eq!(output.code, exit::ERROR);
        let lines: Vec<_> = out.lines().collect();
        assert_eq!(lines[0], r#"{"kind":"text","text":"hi"}"#);
        assert!(lines[1].starts_with(r#"{"kind":"exited""#), "{out}");
        assert_eq!(lines.len(), 2);
        assert_eq!(err, "exit=3 boom \n");
    }

    #[test]
    fn the_limit_is_read_as_a_number_and_falls_back_as_num_does() {
        assert_eq!(limit_ms(None), DEFAULT_TIMEOUT_MS);
        for raw in ["abc", "0", "-5", "", "Infinity", "1e400", "1_000"] {
            assert_eq!(limit_ms(Some(raw)), DEFAULT_TIMEOUT_MS, "{raw}");
        }
        for (raw, want) in [
            ("1e3", 1000.0),
            (".5", 0.5),
            ("0x10", 16.0),
            (" 7 ", 7.0),
            ("+2", 2.0),
        ] {
            assert_eq!(limit_ms(Some(raw)), want, "{raw}");
        }
    }

    /// Another test writing an executable takes the write side of the fork gate, and a turn that held the read side over its wait would keep that test out for as long as the child lives.
    #[test]
    fn a_turn_holds_no_gate_while_it_waits_for_its_child() {
        let scratch = Scratch::new();
        gate::write_executable(
            &scratch.path().join("bin/claude"),
            "#!/bin/sh\n: > started\ni=0\nuntil [ -e go ]; do\n  i=$((i + 1))\n  [ \"$i\" -lt 1200 ] || exit 3\n  sleep 0.05\ndone\nprintf '{\"type\":\"result\",\"is_error\":false,\"result\":\"r\",\"session_id\":\"s\"}\\n'\n",
        );
        let cwd = scratch.path().to_str().unwrap().to_owned();
        let path = format!("{}:/usr/bin:/bin", scratch.path().join("bin").display());
        let turn = std::thread::spawn(move || call(&[&reference(&cwd), "t"], &path).0.code);
        let given_up = Instant::now() + Duration::from_secs(30);
        while !scratch.path().join("started").exists() {
            assert!(Instant::now() < given_up, "the child did not start");
            std::thread::sleep(Duration::from_millis(10));
        }
        drop(gate::writing());
        std::fs::write(scratch.path().join("go"), "").unwrap();
        assert_eq!(turn.join().unwrap(), exit::OK);
    }

    /// What the start of the child costs counts, as it does in node: here the fork gate makes that start slow. A machine that stalls can reach the spawn after the gate was given back, which says nothing, so there is more than one try; a clock read after the spawn gets there on none of them.
    #[test]
    fn the_clock_of_a_turn_is_read_before_the_spawn() {
        const HELD: Duration = Duration::from_millis(400);
        let scratch = Scratch::new();
        gate::write_executable(
            &scratch.path().join("bin/claude"),
            "#!/bin/sh\nprintf '{\"type\":\"result\",\"is_error\":false,\"result\":\"r\",\"session_id\":\"s\"}\\n'\n",
        );
        let cwd = scratch.path().to_str().unwrap().to_owned();
        let path = scratch.path().join("bin").to_str().unwrap().to_owned();
        let mut seen = Vec::new();
        for _ in 0..5 {
            let (cwd, path) = (cwd.clone(), path.clone());
            let writer = gate::writing();
            let turn = std::thread::spawn(move || call(&[&reference(&cwd), "t"], &path).1);
            std::thread::sleep(HELD);
            drop(writer);
            let document: serde_json::Value = serde_json::from_str(&turn.join().unwrap()).unwrap();
            let duration = document["durationMs"].as_f64().unwrap();
            if duration >= HELD.as_secs_f64() * 500.0 {
                return;
            }
            seen.push(duration);
        }
        panic!("the start of the child did not count: durationMs {seen:?}");
    }

    /// The writer sits in a write that does not come back: the caller is held up by nothing, and the wait with a limit says so.
    #[test]
    fn a_stdout_nobody_reads_holds_up_neither_the_writes_nor_the_error_line() {
        let (open, blocked) = mpsc::channel::<()>();
        let (seen, written) = mpsc::channel();
        let out = Stdout::start(move |text: &str| {
            let _ = blocked.recv();
            let _ = seen.send(text.to_owned());
        })
        .unwrap();
        let asked = Instant::now();
        out.write("one\n".to_owned());
        out.write("two\n".to_owned());
        assert!(!out.written(Some(Duration::from_millis(50))));
        assert!(asked.elapsed() < Duration::from_secs(30));
        open.send(()).unwrap();
        open.send(()).unwrap();
        assert!(out.written(None));
        assert_eq!(written.try_iter().collect::<Vec<_>>(), ["one\n", "two\n"]);
    }
}
