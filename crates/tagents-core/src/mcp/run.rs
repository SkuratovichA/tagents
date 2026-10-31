//! A call: the program of the verb, run as a child with no stdin, and what it did told back in one JSON document. Nothing here knows a verb; the program, the words and the exit table all come from the tool. It is `packages/mcp/src/run.ts`.
//!
//! Nothing a call starts outlives the call: `child` runs the program as the leader of a process group of its own and, however the call ends (exit, timeout, cancellation of its request, closing of the server), stops the whole group.

use std::collections::HashMap;
use std::ffi::{OsStr, OsString};
use std::io::{self, ErrorKind};
use std::process::Command;
use std::time::Duration;

use serde::Serialize;
use serde_json::ser::{Formatter, PrettyFormatter};
use serde_json::{Map, Number, Serializer, Value};

use super::rpc::{CallResult, ToolEntry};
use super::server::Tools;
use super::tools::{Tool, argv_for};
use crate::child::{self, Policy, Reason};
use crate::ending::Stop;
use crate::js;

/// More than this many bytes of one stream is cut: a transcript or an index can be larger than any client will take.
pub const MAX_STREAM: usize = 256 * 1024;
/// A call that has not ended in five minutes is stopped with its whole process group: a verb that takes longer than that is not one a tool call waits for, and the program's own timeout, where it has one, is shorter.
pub const CALL_TIMEOUT: Duration = Duration::from_secs(5 * 60);
/// What a stopped group is given to leave on SIGTERM before it is killed.
pub const KILL_GRACE: Duration = Duration::from_millis(2000);
/// How long the call waits for the output pipes after the program exited: a process that left the group can hold them open for good. A pipe that still holds bytes, or has lost its last writer, is not held by such a process but waits for its reader thread, and is waited for on past this, up to the grace.
pub const DRAIN: Duration = Duration::from_millis(250);

pub struct RunDeps {
    /// The environment the program is looked up and run in: the server's own.
    pub env: HashMap<OsString, OsString>,
    pub timeout: Duration,
    pub kill_grace: Duration,
    pub drain: Duration,
}

impl RunDeps {
    /// The limits of the server, in the environment given.
    pub fn standard(env: HashMap<OsString, OsString>) -> RunDeps {
        RunDeps {
            env,
            timeout: CALL_TIMEOUT,
            kill_grace: KILL_GRACE,
            drain: DRAIN,
        }
    }
}

/// The tools of a contract, run: `tools/list` is their entries and a call is `call_tool`.
pub struct Runner {
    tools: Vec<Tool>,
    deps: RunDeps,
}

impl Runner {
    pub fn new(tools: Vec<Tool>, deps: RunDeps) -> Runner {
        Runner { tools, deps }
    }
}

impl Tools for Runner {
    fn list(&self) -> Vec<ToolEntry> {
        self.tools.iter().map(Tool::entry).collect()
    }

    fn call(&self, name: &str, args: &Map<String, Value>, stop: &Stop) -> Option<CallResult> {
        let tool = self.tools.iter().find(|tool| tool.name == name)?;
        Some(call_tool(tool, args, &self.deps, stop))
    }
}

/// The first name of the exit table that carries the code: the table is in the file's order, and a code two names share is told by the first.
fn outcome_of(exit: &[(String, Number)], code: &Number) -> String {
    let wanted = code.as_f64();
    exit.iter()
        .find(|(_, value)| value.as_f64() == wanted)
        .map_or_else(|| format!("exit {code}"), |(name, _)| name.clone())
}

/// Stdout that is a JSON document is handed over parsed, so the model reads fields and not an escaped string; anything else stays text.
fn parsed_or_text(stdout: &str) -> Value {
    let trimmed = stdout.trim_start_matches(js::is_space);
    if !trimmed.starts_with(['{', '[']) {
        return Value::String(stdout.to_owned());
    }
    serde_json::from_str(stdout).unwrap_or_else(|_| Value::String(stdout.to_owned()))
}

#[derive(Serialize)]
struct Body<'a> {
    exit: &'a Number,
    outcome: &'a str,
    stdout: Value,
    stderr: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    truncated: Option<bool>,
}

/// The result of a call. A cut stdout keeps the text as text; `truncated` is set when either stream was cut.
fn finish(
    code: &Number,
    outcome: &str,
    stdout: &str,
    stderr: &str,
    stdout_cut: bool,
    stderr_cut: bool,
) -> CallResult {
    let body = Body {
        exit: code,
        outcome,
        stdout: if stdout_cut {
            Value::String(stdout.to_owned())
        } else {
            parsed_or_text(stdout)
        },
        stderr,
        truncated: (stdout_cut || stderr_cut).then_some(true),
    };
    CallResult::text(pretty(&body), code.as_f64() != Some(0.0))
}

/// `JSON.stringify(body, null, 2)`. The body is strings, a number and a document that was just parsed: there is nothing in it to fail on.
fn pretty(body: &Body) -> String {
    let mut out = Vec::new();
    let formatter = JsPretty(PrettyFormatter::new());
    match body.serialize(&mut Serializer::with_formatter(&mut out, formatter)) {
        Ok(()) => String::from_utf8_lossy(&out).into_owned(),
        Err(e) => e.to_string(),
    }
}

/// serde_json's pretty layout, which is the two-space one of `JSON.stringify`, with the numbers told as JavaScript tells them. A number reaches a formatter as the text the program wrote (`arbitrary_precision`), and the node server reads it into a double and writes that: `1.0` is `1`, `1E2` is `100`, `-0` is `0`, and what does not fit a double is `null`.
struct JsPretty(PrettyFormatter<'static>);

impl Formatter for JsPretty {
    fn write_number_str<W: ?Sized + io::Write>(
        &mut self,
        writer: &mut W,
        value: &str,
    ) -> io::Result<()> {
        match value.parse::<f64>() {
            Ok(x) if x.is_finite() => writer.write_all(js::number_text(x).as_bytes()),
            _ => writer.write_all(b"null"),
        }
    }

    fn begin_array<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.0.begin_array(writer)
    }

    fn end_array<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.0.end_array(writer)
    }

    fn begin_array_value<W: ?Sized + io::Write>(
        &mut self,
        writer: &mut W,
        first: bool,
    ) -> io::Result<()> {
        self.0.begin_array_value(writer, first)
    }

    fn end_array_value<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.0.end_array_value(writer)
    }

    fn begin_object<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.0.begin_object(writer)
    }

    fn end_object<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.0.end_object(writer)
    }

    fn begin_object_key<W: ?Sized + io::Write>(
        &mut self,
        writer: &mut W,
        first: bool,
    ) -> io::Result<()> {
        self.0.begin_object_key(writer, first)
    }

    fn begin_object_value<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.0.begin_object_value(writer)
    }

    fn end_object_value<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.0.end_object_value(writer)
    }
}

fn refusal(code: &Number, outcome: &str, message: &str) -> CallResult {
    finish(code, outcome, "", &format!("{message}\n"), false, false)
}

/// Runs the call of `tool` with `args`: refuses what cannot be run, and tells what the program did otherwise. `stop` says that the request was cancelled or the server is closing.
pub fn call_tool(
    tool: &Tool,
    args: &Map<String, Value>,
    deps: &RunDeps,
    stop: &Stop,
) -> CallResult {
    let argv = match argv_for(tool, args) {
        Ok(argv) => argv,
        Err(message) => return refusal(&tool.code("usage", 2), "usage", &message),
    };
    if tool.command.requires_tmux
        && deps
            .env
            .get(OsStr::new("TMUX"))
            .is_none_or(|value| value.is_empty())
    {
        let message = format!(
            "{} needs a tmux server of its own to open a window in, and Claude Code is not running inside tmux (TMUX is not set)",
            tool.name
        );
        return refusal(&tool.code("refused", 3), "refused", &message);
    }
    if stop.is_stopped() {
        return refusal(
            &tool.code("error", 1),
            "cancelled",
            &format!(
                "{} was not started: the request was cancelled",
                tool.program
            ),
        );
    }
    run(tool, &argv, deps, stop)
}

/// The text of a spawn failure: the operating system's, except for a program that is not there, which names the program.
fn spawn_failure(program: &str, error: &io::Error) -> String {
    if error.kind() == ErrorKind::NotFound {
        format!("{program} is not on PATH")
    } else {
        error.to_string()
    }
}

/// Runs the program of `tool` as a child and tells what it did.
fn run(tool: &Tool, argv: &[String], deps: &RunDeps, stop: &Stop) -> CallResult {
    let error = |message: &str| refusal(&tool.code("error", 1), "error", message);
    let mut command = Command::new(&tool.program);
    command.args(argv).env_clear().envs(&deps.env);
    let policy = Policy {
        input: None,
        timeout: deps.timeout,
        kill_grace: Some(deps.kill_grace),
        drain: deps.drain,
        cap: MAX_STREAM,
    };
    let finished = match child::run(command, &policy, stop) {
        Ok(finished) => finished,
        Err(e) => return error(&spawn_failure(&tool.program, &e)),
    };
    let (code, name, note) = match finished.reason {
        Some(Reason::Timeout) => (
            tool.code("timeout", 4),
            "timeout".to_owned(),
            format!(
                "{} did not finish within {} ms and was stopped\n",
                tool.program,
                deps.timeout.as_millis()
            ),
        ),
        Some(Reason::Cancelled) => (
            tool.code("error", 1),
            "cancelled".to_owned(),
            format!(
                "{} was stopped: the request was cancelled or the server closed\n",
                tool.program
            ),
        ),
        None => {
            // A program a signal ended has no code: the table's error.
            let code = finished
                .code
                .map_or_else(|| tool.code("error", 1), Number::from);
            let name = outcome_of(&tool.exit, &code);
            (code, name, String::new())
        }
    };
    finish(
        &code,
        &name,
        &finished.stdout,
        &format!("{}{note}", finished.stderr),
        finished.stdout_cut,
        finished.stderr_cut,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stdout_that_is_a_document_is_parsed_and_anything_else_stays_text() {
        assert_eq!(
            parsed_or_text("{\"a\":[1,2]}\n"),
            serde_json::json!({"a": [1, 2]})
        );
        assert_eq!(parsed_or_text("  \n[1]"), serde_json::json!([1]));
        assert_eq!(parsed_or_text("42\n"), Value::String("42\n".into()));
        assert_eq!(
            parsed_or_text("{not json"),
            Value::String("{not json".into())
        );
        assert_eq!(parsed_or_text(""), Value::String(String::new()));
        // A no-break space is white space to `trimStart` and not to the JSON grammar.
        assert_eq!(parsed_or_text("\u{a0}{}"), Value::String("\u{a0}{}".into()));
        // Two documents are not one.
        assert_eq!(parsed_or_text("{} {}"), Value::String("{} {}".into()));
    }

    #[test]
    fn the_outcome_is_the_first_name_of_the_table_that_carries_the_code() {
        let table: Vec<(String, Number)> = [("ok", 0), ("error", 1), ("failed", 1), ("refused", 3)]
            .iter()
            .map(|(n, c)| ((*n).to_owned(), Number::from(*c)))
            .collect();
        assert_eq!(outcome_of(&table, &Number::from(1)), "error");
        assert_eq!(outcome_of(&table, &Number::from(3)), "refused");
        assert_eq!(outcome_of(&table, &Number::from(9)), "exit 9");
    }

    #[test]
    fn the_body_is_the_two_space_pretty_form_with_the_keys_in_the_order_of_the_node_server() {
        let result = finish(
            &Number::from(3),
            "refused",
            "",
            "nothing done\n",
            false,
            false,
        );
        assert_eq!(
            result.body(),
            "{\n  \"exit\": 3,\n  \"outcome\": \"refused\",\n  \"stdout\": \"\",\n  \"stderr\": \"nothing done\\n\"\n}"
        );
        assert!(result.is_error());
        let cut = finish(&Number::from(0), "ok", "{\"a\":[]}", "e", true, false);
        assert_eq!(
            cut.body(),
            "{\n  \"exit\": 0,\n  \"outcome\": \"ok\",\n  \"stdout\": \"{\\\"a\\\":[]}\",\n  \"stderr\": \"e\",\n  \"truncated\": true\n}"
        );
        assert!(!cut.is_error());
        let parsed = finish(
            &Number::from(0),
            "ok",
            "{\"a\":[1,{}],\"b\":[]}",
            "",
            false,
            true,
        );
        assert_eq!(
            parsed.body(),
            "{\n  \"exit\": 0,\n  \"outcome\": \"ok\",\n  \"stdout\": {\n    \"a\": [\n      1,\n      {}\n    ],\n    \"b\": []\n  },\n  \"stderr\": \"\",\n  \"truncated\": true\n}"
        );
    }

    #[test]
    fn a_number_in_the_programs_json_is_told_as_javascript_tells_the_double_it_reads_as() {
        let result = finish(
            &Number::from(0),
            "ok",
            r#"{"a":1.0,"b":1E2,"c":[-0,0.10,1e400,123456789012345678901234567890]}"#,
            "",
            false,
            false,
        );
        assert_eq!(
            result.body(),
            "{\n  \"exit\": 0,\n  \"outcome\": \"ok\",\n  \"stdout\": {\n    \"a\": 1,\n    \"b\": 100,\n    \"c\": [\n      0,\n      0.1,\n      null,\n      1.2345678901234568e+29\n    ]\n  },\n  \"stderr\": \"\"\n}"
        );
    }

    #[test]
    fn a_failure_to_spawn_names_the_program_only_when_it_is_missing() {
        assert_eq!(
            spawn_failure("tagents-fake", &io::Error::from(ErrorKind::NotFound)),
            "tagents-fake is not on PATH"
        );
        assert_eq!(
            spawn_failure("tagents-fake", &io::Error::from_raw_os_error(13)),
            io::Error::from_raw_os_error(13).to_string()
        );
    }
}
