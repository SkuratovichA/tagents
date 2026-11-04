//! `session abort <ref>`: SIGKILL to the process a headless session's state record names, as `session()` of `packages/core/src/cli/main.ts` serves it (design D9).
//!
//! `driver.abort(ref)` of node stops the turn this process is running, and no turn runs in a new process, so it has nothing to copy. The pid is the only handle across processes: a record whose key is a pane's number is somebody's open terminal and is refused, and a record with no pid, or whose pid is not alive, has nothing to stop.

use rustix::process::{Pid, Signal, kill_process};

use crate::{
    json::Value,
    messages::Texts,
    notify::{lock::is_alive, state::read_agent_state},
    session::{
        read::{Setting, printed, usage},
        reference::{self, Resolved},
    },
    sessions::{Output, exit},
};

/// The refusal of a call that stops nothing: `message` is the key of the catalogue text, said about the reference as it was typed.
fn refused(texts: &Texts, message: &str, raw: &str) -> Output {
    Output {
        stdout: String::new(),
        stderr: format!("{}\n", texts.t(message, &[("ref", raw)])),
        code: exit::REFUSED,
    }
}

/// `SIGKILL` to `pid`, which `is_alive` has found to be a process this user can see. `false` when the signal was not delivered.
fn kill(pid: u32) -> bool {
    i32::try_from(pid)
        .ok()
        .and_then(Pid::from_raw)
        .is_some_and(|pid| kill_process(pid, Signal::KILL).is_ok())
}

pub fn abort(args: &[String], setting: &Setting, texts: &Texts) -> Output {
    let Some(raw) = args.first().filter(|raw| !raw.is_empty()) else {
        return usage(texts.t("missingOption", &[("option", "<ref>")]));
    };
    let reference = match reference::resolve(raw, &setting.state_dir) {
        Resolved::NoMatch => {
            return Output::fail(format!("{}\n", texts.t("badRef", &[("ref", raw)])));
        }
        Resolved::Ref(reference) => *reference,
    };
    // The first record, in the order the reader returns them, that the key or the session id names; a `null` session id names none.
    let row = read_agent_state(&setting.state_dir)
        .into_iter()
        .find(|row| {
            row.key == reference.id
                || reference.claude_session_id.as_deref() == Some(&row.session_id)
        });
    // A pane's key is its number and a session without a pane is keyed `s-<sid>`: the pid belongs to the second kind.
    if row.as_ref().is_some_and(|row| !row.key.starts_with("s-")) {
        return refused(texts, "abortPaneAgent", raw);
    }
    let Some(pid) = row
        .and_then(|row| row.pid)
        .filter(|pid| is_alive(u64::from(*pid)))
        .filter(|pid| kill(*pid))
    else {
        return refused(texts, "nothingToAbort", raw);
    };
    printed(&Value::Object(vec![
        ("aborted".to_owned(), Value::Bool(true)),
        ("id".to_owned(), Value::String(reference.id)),
        ("pid".to_owned(), Value::Number(f64::from(pid))),
    ]))
}

#[cfg(test)]
mod tests {
    use std::os::unix::process::ExitStatusExt;
    use std::process::{Child, Command, Stdio};

    use super::*;
    use crate::messages::Locale;
    use crate::testing::Scratch;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|a| (*a).to_owned()).collect()
    }

    /// A process of the test's own for `abort` to stop: no record in these tests names any other.
    fn sleeper() -> Child {
        Command::new("sleep")
            .arg("600")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap()
    }

    fn record(state: &Scratch, key: &str, at: u32, session: &str, pid: &str) {
        std::fs::write(
            state.path().join(format!("{key}.tsv")),
            format!("{at}\tworking\t{session}\t/w\t\td\t\t{pid}\n"),
        )
        .unwrap();
    }

    fn run(state: &Scratch, words: &[&str]) -> Output {
        let setting = Setting {
            cwd: Some("/base".to_owned()),
            state_dir: state.dir().to_owned(),
            locale: Locale::En,
        };
        abort(&args(words), &setting, &Texts::load(Locale::En).unwrap())
    }

    fn reference(id: &str, session: &str) -> String {
        format!(
            r#"{{"id":"{id}","claudeSessionId":{session},"transcript":null,"spec":{{"kind":"claude","cwd":"/w","skipPermissions":false}}}}"#
        )
    }

    /// The child has been killed by SIGKILL, and nothing else has.
    fn killed(mut child: Child) -> bool {
        child.wait().unwrap().signal() == Some(9)
    }

    /// The child still runs; it is killed so that the test leaves nothing behind.
    fn alive(mut child: Child) -> bool {
        let running = child.try_wait().unwrap().is_none();
        child.kill().unwrap();
        child.wait().unwrap();
        running
    }

    fn refusal(output: &Output, message: &str, who: &str) -> bool {
        let texts = Texts::load(Locale::En).unwrap();
        output.code == exit::REFUSED
            && output.stdout.is_empty()
            && output.stderr == format!("{}\n", texts.t(message, &[("ref", who)]))
    }

    #[test]
    fn a_headless_record_is_killed_and_printed() {
        let state = Scratch::new();
        let child = sleeper();
        record(&state, "s-a", 1, "sid-a", &child.id().to_string());
        let output = run(&state, &["s-a"]);
        assert_eq!(output.code, exit::OK);
        assert_eq!(
            output.stdout,
            format!(
                "{{\n  \"aborted\": true,\n  \"id\": \"s-a\",\n  \"pid\": {}\n}}\n",
                child.id()
            )
        );
        assert!(output.stderr.is_empty());
        assert!(killed(child));
    }

    #[test]
    fn a_reference_names_its_record_by_the_session_id_too() {
        let state = Scratch::new();
        let child = sleeper();
        record(&state, "s-a", 1, "sid-a", &child.id().to_string());
        let output = run(&state, &[&reference("other", r#""sid-a""#)]);
        assert!(output.stdout.contains("\"id\": \"other\""), "{output:?}");
        assert!(killed(child));
        let child = sleeper();
        record(&state, "s-a", 1, "sid-a", &child.id().to_string());
        assert!(run(&state, &["sid-a"]).stdout.contains("\"id\": \"s-a\""));
        assert!(killed(child));
    }

    #[test]
    fn a_pane_s_record_is_refused_and_its_process_left_alone() {
        let state = Scratch::new();
        let child = sleeper();
        record(&state, "1", 1, "sid-a", &child.id().to_string());
        let output = run(&state, &["1"]);
        assert!(refusal(&output, "abortPaneAgent", "1"), "{output:?}");
        assert!(alive(child));
    }

    #[test]
    fn no_pid_and_a_dead_pid_have_nothing_to_stop() {
        let state = Scratch::new();
        record(&state, "s-a", 1, "sid-a", "");
        let output = run(&state, &["s-a"]);
        assert!(refusal(&output, "nothingToAbort", "s-a"), "{output:?}");
        // The largest pid there is, which no system hands to a process.
        record(&state, "s-a", 1, "sid-a", "2147483647");
        let output = run(&state, &["s-a"]);
        assert!(refusal(&output, "nothingToAbort", "s-a"), "{output:?}");
    }

    #[test]
    fn a_pid_beyond_32_bits_is_dead_and_does_not_wrap_onto_a_live_process() {
        let state = Scratch::new();
        let child = sleeper();
        let pid = u64::from(child.id());
        for beyond in [pid + (1 << 31), pid + (1 << 32)] {
            record(&state, "s-a", 1, "sid-a", &beyond.to_string());
            let output = run(&state, &["s-a"]);
            assert!(refusal(&output, "nothingToAbort", "s-a"), "{output:?}");
        }
        assert!(alive(child));
    }

    #[test]
    fn a_process_of_another_user_is_alive() {
        // Signal 0 to the first process is allowed or refused with EPERM, and both mean it is there.
        assert!(is_alive(1));
        assert!(!is_alive(u64::from(u32::MAX)));
        assert!(!is_alive(1 << 32));
    }

    #[test]
    fn a_null_session_matches_nothing_and_an_empty_one_matches_an_empty_column() {
        let state = Scratch::new();
        let child = sleeper();
        record(&state, "s-a", 1, "", &child.id().to_string());
        let output = run(&state, &[&reference("s-x", "null")]);
        assert!(output.code == exit::REFUSED, "{output:?}");
        let output = run(&state, &[&reference("s-x", r#""""#)]);
        assert_eq!(output.code, exit::OK, "{output:?}");
        assert!(killed(child));
    }

    #[test]
    fn the_first_record_in_the_reader_s_order_decides() {
        let state = Scratch::new();
        let child = sleeper();
        let pid = child.id().to_string();
        // Newest first: the pane that holds the session comes before the headless record that holds the key.
        record(&state, "1", 3, "sid-x", &pid);
        record(&state, "s-b", 1, "sid-b", &pid);
        let output = run(&state, &[&reference("s-b", r#""sid-x""#)]);
        assert!(
            refusal(&output, "abortPaneAgent", &reference("s-b", r#""sid-x""#)),
            "{output:?}"
        );
        // And the other way round.
        record(&state, "s-b", 5, "sid-b", &pid);
        let output = run(&state, &[&reference("s-b", r#""sid-x""#)]);
        assert_eq!(output.code, exit::OK, "{output:?}");
        assert!(killed(child));
    }

    #[test]
    fn what_matches_no_record_is_said_before_anything_is_signalled() {
        let state = Scratch::new();
        let child = sleeper();
        record(&state, "s-a", 1, "sid-a", &child.id().to_string());
        let output = run(&state, &["nobody"]);
        assert_eq!(output.code, exit::ERROR);
        assert_eq!(output.stderr, "no session matches nobody\n");
        let who = reference("s-none", r#""sid-none""#);
        let output = run(&state, &[&who]);
        assert!(refusal(&output, "nothingToAbort", &who), "{output:?}");
        assert_eq!(run(&state, &[]).code, exit::USAGE);
        assert_eq!(run(&state, &[""]).code, exit::USAGE);
        let lone = reference(r"\ud83d", "null");
        let unusable = run(&state, &[&lone]);
        assert_eq!(unusable.code, exit::ERROR);
        assert_eq!(unusable.stderr, format!("no session matches {lone}\n"));
        assert!(alive(child));
    }
}
