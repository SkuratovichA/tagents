//! The macOS notification helper as the daemon drives it, `createHelperNotifier` and `runHelper` of `packages/notify/src/platform/macos/helper.ts`: one verb per process, the notice on its input as JSON, one JSON line back. `helperStatus`, `helperAuthorize` and `helperDelivered` serve CLI verbs that stay node and are not here.
//!
//! `run_helper` is the only place that reads the line and the only place that turns a failure into an `Err`, whose text is the sentence node's `Error` carries, which the engine writes into its log. The exit code is not looked at, as in node: only what the helper printed is.

use std::io;
use std::process::Command;
use std::time::Duration;

use serde_json::{Map, Number, Value};

use crate::child::{self, Policy, Reason};
use crate::ending::Stop;
use crate::js;
use crate::json;
use crate::node;
use crate::notify::notifier::{Notice, Notifier, PostResult};

pub const HELPER_TIMEOUT_MS: u64 = 5000;

/// What `execFile` keeps of each stream before it gives up on the program: its default `maxBuffer`.
const MAX_BUFFER: usize = 1024 * 1024;

/// `path.join(app, 'Contents', 'MacOS', 'tagents-notify')`.
pub fn helper_binary(app: &str) -> String {
    node::join(
        &node::join(&node::join(app, "Contents"), "MacOS"),
        "tagents-notify",
    )
}

/// The helper behind the `macos` backend.
pub struct HelperNotifier {
    app: String,
}

impl HelperNotifier {
    pub fn new(app: &str) -> HelperNotifier {
        HelperNotifier {
            app: app.to_owned(),
        }
    }
}

impl Notifier for HelperNotifier {
    fn name(&self) -> &str {
        "macos"
    }

    fn post(&mut self, notice: &Notice) -> Result<PostResult, String> {
        let line = run_helper(
            &self.app,
            &["post"],
            Some(notice_json(notice)),
            HELPER_TIMEOUT_MS,
        )?;
        Ok(PostResult {
            shown: line.shown.unwrap_or(false),
            why: line.why,
        })
    }

    fn withdraw(&mut self, id: &str) -> Result<(), String> {
        run_helper(&self.app, &["withdraw", id], None, HELPER_TIMEOUT_MS).map(|_| ())
    }
}

/// `JSON.stringify(notice)` of the object `assemble` builds in `engine.ts`: the keys in the order it writes them, `terminalPid` and `skipIfFrontmost` only where node sets them. `serde_json` escapes a string as V8 does (a quote, a backslash, `\b \f \n \r \t`, any other control character as lowercase `\u00xx`, and U+2028, U+2029 and everything above ASCII raw), which the tests pin.
pub fn notice_json(notice: &Notice) -> String {
    let string = |text: &str| Value::String(text.to_owned());
    let mut env = Map::new();
    for (key, value) in &notice.click.env {
        env.insert(key.clone(), string(value));
    }
    let mut click = Map::new();
    click.insert(
        "argv".into(),
        Value::Array(notice.click.argv.iter().map(|a| string(a)).collect()),
    );
    click.insert("env".into(), Value::Object(env));
    let mut object = Map::new();
    object.insert("id".into(), string(&notice.id));
    object.insert("thread".into(), string(&notice.thread));
    object.insert("kind".into(), string(notice.kind.as_str()));
    object.insert("title".into(), string(&notice.title));
    object.insert("subtitle".into(), string(&notice.subtitle));
    object.insert("body".into(), string(&notice.body));
    object.insert("click".into(), Value::Object(click));
    if let Some(pid) = notice.terminal_pid {
        object.insert("terminalPid".into(), Value::Number(Number::from(pid)));
    }
    if let Some(skip) = notice.skip_if_frontmost {
        object.insert("skipIfFrontmost".into(), Value::Bool(skip));
    }
    Value::Object(object).to_string()
}

/// What `runHelper` reads out of the line: the fields a caller of the daemon uses. The rest of the schema is checked and dropped.
#[derive(Debug, PartialEq)]
struct HelperLine {
    shown: Option<bool>,
    why: Option<String>,
}

/// The `Line` schema of `helper.ts`: a loose object with a boolean `ok` and optional `error`, `why`, `status`, `alertStyle` and `bundleId` strings, `shown` boolean and `ids` array of strings. `Ok(Err(text))` is a line that says `ok: false`.
fn read_line(stdout: &str) -> Option<Result<HelperLine, String>> {
    let value = json::parse(js::trim(stdout))?;
    if !matches!(value, json::Value::Object(_)) {
        return None;
    }
    let optional = |key: &str, is: &dyn Fn(&json::Value) -> bool| value.get(key).is_none_or(is);
    let is_string = |v: &json::Value| matches!(v, json::Value::String(_));
    let valid = optional("error", &is_string)
        && optional("why", &is_string)
        && optional("status", &is_string)
        && optional("alertStyle", &is_string)
        && optional("bundleId", &is_string)
        && optional("shown", &|v| matches!(v, json::Value::Bool(_)))
        && optional(
            "ids",
            &|v| matches!(v, json::Value::Array(items) if items.iter().all(is_string)),
        );
    let Some(json::Value::Bool(ok)) = value.get("ok") else {
        return None;
    };
    if !valid {
        return None;
    }
    if !ok {
        let text = value.get("error").and_then(json::Value::as_str);
        return Some(Err(text
            .unwrap_or("the notification helper failed")
            .to_owned()));
    }
    Some(Ok(HelperLine {
        shown: match value.get("shown") {
            Some(json::Value::Bool(shown)) => Some(*shown),
            _ => None,
        },
        why: value
            .get("why")
            .and_then(json::Value::as_str)
            .map(str::to_owned),
    }))
}

/// The name node gives a failed `spawn`, `spawn <file> <CODE>`; an error `node::ERRNOS` does not name prints what Rust says.
fn spawn_message(err: &io::Error, file: &str) -> String {
    match node::errno(err) {
        Some(errno) => format!("spawn {file} {}", errno.code),
        None => err.to_string(),
    }
}

fn run_helper(
    app: &str,
    args: &[&str],
    input: Option<String>,
    timeout_ms: u64,
) -> Result<HelperLine, String> {
    run_binary(
        Command::new(helper_binary(app)),
        app,
        args,
        input,
        timeout_ms,
    )
}

/// `run_helper` with the command to run, so that a test can stand a stub in for the helper.
fn run_binary(
    mut command: Command,
    app: &str,
    args: &[&str],
    input: Option<String>,
    timeout_ms: u64,
) -> Result<HelperLine, String> {
    let bin = helper_binary(app);
    command.args(args);
    let policy = Policy {
        input: input.map(String::into_bytes),
        timeout: Duration::from_millis(timeout_ms),
        // SIGKILL at the deadline: a helper that is stuck is not going to handle a polite signal either.
        kill_grace: None,
        drain: Duration::from_millis(250),
        cap: MAX_BUFFER,
    };
    let finished = child::run(command, &policy, &Stop::default()).map_err(|err| {
        format!(
            "cannot start the notification helper at {app} ({}); run `tagents notify install`",
            spawn_message(&err, &bin)
        )
    })?;
    if finished.reason == Some(Reason::Timeout) {
        return Err(format!(
            "the notification helper timed out after {} s",
            js::number_text(timeout_ms as f64 / 1000.0)
        ));
    }
    match read_line(&finished.stdout) {
        Some(Ok(line)) => Ok(line),
        Some(Err(text)) => Err(text),
        None => Err(format!(
            "unreadable output from the notification helper: stdout {}, stderr {}",
            json::quote_prefix16(&finished.stdout, 200),
            json::quote_prefix16(&finished.stderr, 200)
        )),
    }
}

#[cfg(test)]
mod tests;
