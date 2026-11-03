//! `TurnOutcome` and `formatAttemptError` of `packages/core/src/turn-outcome.ts`: what one turn ended as, the document `session prompt` prints for it, the line it writes on stderr and its exit code (design D8).

use crate::js;
use crate::json::{self, Value};
use crate::sessions::exit;

const DETAIL_MAX: usize = 300;

/// `clipDetail`: white space collapsed, then cut at 300 UTF-16 units, so a cut inside a pair leaves half of it.
pub fn clip_detail(text: &[u16]) -> Vec<u16> {
    js::slice16(&js::collapse_space16(text), DETAIL_MAX).to_vec()
}

/// What a turn whose result said it succeeded did.
#[derive(Debug, PartialEq)]
pub struct Done {
    pub text: Vec<u16>,
    pub session_id: Option<Value>,
    pub tool_uses: u64,
    pub cost_usd: Option<f64>,
    pub num_turns: Option<f64>,
    pub duration_ms: f64,
}

/// What a turn that did not succeed got done on the wire.
#[derive(Debug, PartialEq)]
pub struct Evidence {
    pub session_id: Option<Value>,
    pub tool_uses: u64,
    pub detail: Vec<u16>,
    pub saw_text: bool,
    pub saw_result: bool,
}

#[derive(Debug, PartialEq)]
pub enum Outcome {
    Ok(Done),
    /// The result arrived and the process left with a code that is not 0: the exit code is about the shutdown, not the work.
    KilledAfterResult(Done, Option<i32>),
    /// The time limit killed it and no successful result arrived.
    Timeout(Evidence, f64),
    /// It left on its own with no successful result. The code is `None` when a signal ended it.
    Exited(Evidence, Option<i32>, Option<&'static str>),
    /// There was never a process.
    SpawnFailed(String),
}

fn string(text: &str) -> Value {
    Value::String(text.to_owned())
}

fn number_or_null(number: Option<f64>) -> Value {
    number.map_or(Value::Null, Value::Number)
}

fn or_null(value: Option<&Value>) -> Value {
    value.cloned().unwrap_or(Value::Null)
}

fn code_value(code: Option<i32>) -> Value {
    number_or_null(code.map(f64::from))
}

#[allow(clippy::cast_precision_loss)]
fn count(number: u64) -> Value {
    Value::Number(number as f64)
}

fn object(members: Vec<(&str, Value)>) -> Value {
    Value::Object(
        members
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value))
            .collect(),
    )
}

fn done_members(kind: &str, done: &Done) -> Vec<(&'static str, Value)> {
    vec![
        ("kind", string(kind)),
        ("text", Value::from_units(done.text.clone())),
        ("sessionId", or_null(done.session_id.as_ref())),
        ("toolUses", count(done.tool_uses)),
        ("costUsd", number_or_null(done.cost_usd)),
        ("numTurns", number_or_null(done.num_turns)),
        ("durationMs", Value::Number(done.duration_ms)),
    ]
}

impl Outcome {
    /// The value `JSON.stringify` prints, the keys in the order node builds them.
    pub fn to_value(&self) -> Value {
        match self {
            Outcome::Ok(done) => object(done_members("ok", done)),
            Outcome::KilledAfterResult(done, code) => {
                let mut members = done_members("killed-after-result", done);
                members.push(("code", code_value(*code)));
                object(members)
            }
            Outcome::Timeout(evidence, limit_ms) => object(vec![
                ("kind", string("timeout")),
                ("sessionId", or_null(evidence.session_id.as_ref())),
                ("toolUses", count(evidence.tool_uses)),
                ("limitMs", Value::Number(*limit_ms)),
                ("detail", Value::from_units(evidence.detail.clone())),
                ("sawText", Value::Bool(evidence.saw_text)),
                ("sawResult", Value::Bool(evidence.saw_result)),
            ]),
            Outcome::Exited(evidence, code, signal) => object(vec![
                ("kind", string("exited")),
                ("sessionId", or_null(evidence.session_id.as_ref())),
                ("toolUses", count(evidence.tool_uses)),
                ("code", code_value(*code)),
                ("signal", signal.map_or(Value::Null, string)),
                ("detail", Value::from_units(evidence.detail.clone())),
                ("sawText", Value::Bool(evidence.saw_text)),
                ("sawResult", Value::Bool(evidence.saw_result)),
            ]),
            Outcome::SpawnFailed(detail) => object(vec![
                ("kind", string("spawn-failed")),
                ("detail", string(detail)),
            ]),
        }
    }

    /// The document: one compact line after `--events`, else the two-space layout.
    pub fn document(&self, events: bool) -> String {
        format!("{}\n", json::stringify(&self.to_value(), !events))
    }

    /// `formatAttemptError`: the line for stderr, with no newline, or nothing for a turn that succeeded. A lone half in the detail is U+FFFD here, which is what writing a string to a stream makes of it.
    pub fn error_line(&self) -> Option<String> {
        match self {
            Outcome::Ok(_) | Outcome::KilledAfterResult(..) => None,
            Outcome::SpawnFailed(detail) => Some(format!("exit=null spawn: {detail}")),
            Outcome::Timeout(evidence, limit_ms) => Some(format!(
                "exit=SIGKILL (timeout {}ms, {} tool call(s)) {}",
                js::number_text(*limit_ms),
                evidence.tool_uses,
                js::text16(&evidence.detail)
            )),
            Outcome::Exited(evidence, code, signal) => {
                let how = match (code, signal) {
                    (Some(code), _) => code.to_string(),
                    (None, Some(signal)) => (*signal).to_owned(),
                    (None, None) => "null".to_owned(),
                };
                Some(format!("exit={how} {}", js::text16(&evidence.detail)))
            }
        }
    }

    /// `exitFor`.
    pub fn exit_code(&self) -> u8 {
        match self {
            Outcome::Ok(_) | Outcome::KilledAfterResult(..) => exit::OK,
            Outcome::Timeout(..) => exit::TIMEOUT,
            Outcome::Exited(..) | Outcome::SpawnFailed(_) => exit::ERROR,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn done() -> Done {
        Done {
            text: js::units("t"),
            session_id: Some(string("s")),
            tool_uses: 2,
            cost_usd: Some(0.5),
            num_turns: None,
            duration_ms: 7.0,
        }
    }

    fn evidence() -> Evidence {
        Evidence {
            session_id: None,
            tool_uses: 1,
            detail: js::units("why"),
            saw_text: true,
            saw_result: false,
        }
    }

    fn compact(outcome: &Outcome) -> String {
        outcome.document(true)
    }

    #[test]
    fn the_keys_of_each_kind_are_in_the_order_node_builds_them() {
        assert_eq!(
            compact(&Outcome::Ok(done())),
            "{\"kind\":\"ok\",\"text\":\"t\",\"sessionId\":\"s\",\"toolUses\":2,\"costUsd\":0.5,\"numTurns\":null,\"durationMs\":7}\n"
        );
        assert_eq!(
            compact(&Outcome::KilledAfterResult(done(), None)),
            "{\"kind\":\"killed-after-result\",\"text\":\"t\",\"sessionId\":\"s\",\"toolUses\":2,\"costUsd\":0.5,\"numTurns\":null,\"durationMs\":7,\"code\":null}\n"
        );
        assert_eq!(
            compact(&Outcome::Timeout(evidence(), 400.0)),
            "{\"kind\":\"timeout\",\"sessionId\":null,\"toolUses\":1,\"limitMs\":400,\"detail\":\"why\",\"sawText\":true,\"sawResult\":false}\n"
        );
        assert_eq!(
            compact(&Outcome::Exited(evidence(), Some(3), None)),
            "{\"kind\":\"exited\",\"sessionId\":null,\"toolUses\":1,\"code\":3,\"signal\":null,\"detail\":\"why\",\"sawText\":true,\"sawResult\":false}\n"
        );
        assert_eq!(
            compact(&Outcome::SpawnFailed("spawn claude ENOENT".to_owned())),
            "{\"kind\":\"spawn-failed\",\"detail\":\"spawn claude ENOENT\"}\n"
        );
    }

    #[test]
    fn the_document_is_two_spaces_without_events_and_ends_with_a_newline() {
        let document = Outcome::SpawnFailed("d".to_owned()).document(false);
        assert_eq!(
            document,
            "{\n  \"kind\": \"spawn-failed\",\n  \"detail\": \"d\"\n}\n"
        );
    }

    #[test]
    fn numbers_print_as_json_stringify_prints_them() {
        let mut big = done();
        big.cost_usd = Some(1e21);
        big.num_turns = Some(-0.0);
        let text = compact(&Outcome::Ok(big));
        assert!(text.contains("\"costUsd\":1e+21,\"numTurns\":0,"), "{text}");
        assert!(compact(&Outcome::Timeout(evidence(), 0.5)).contains("\"limitMs\":0.5,"));
        assert!(compact(&Outcome::Timeout(evidence(), 1e3)).contains("\"limitMs\":1000,"));
    }

    #[test]
    fn a_detail_is_clipped_and_a_cut_inside_a_pair_prints_as_an_escape() {
        let long = format!("{}\u{1f600}", "x".repeat(299));
        let clipped = clip_detail(&js::units(&long));
        assert_eq!(clipped.len(), 300);
        let mut failed = evidence();
        failed.detail = clipped;
        assert!(
            compact(&Outcome::Exited(failed, Some(1), None))
                .contains(&format!("\"detail\":\"{}\\ud83d\"", "x".repeat(299)))
        );
        assert_eq!(clip_detail(&js::units("  a \n\n b  ")), js::units(" a b "));
    }

    #[test]
    fn the_error_line_is_format_attempt_error_and_a_lone_half_is_replaced_on_it() {
        assert_eq!(Outcome::Ok(done()).error_line(), None);
        assert_eq!(
            Outcome::KilledAfterResult(done(), Some(1)).error_line(),
            None
        );
        assert_eq!(
            Outcome::SpawnFailed("spawn b ENOENT".to_owned())
                .error_line()
                .as_deref(),
            Some("exit=null spawn: spawn b ENOENT")
        );
        assert_eq!(
            Outcome::Timeout(evidence(), 0.5).error_line().as_deref(),
            Some("exit=SIGKILL (timeout 0.5ms, 1 tool call(s)) why")
        );
        assert_eq!(
            Outcome::Exited(evidence(), Some(0), None)
                .error_line()
                .as_deref(),
            Some("exit=0 why")
        );
        assert_eq!(
            Outcome::Exited(evidence(), None, Some("SIGTERM"))
                .error_line()
                .as_deref(),
            Some("exit=SIGTERM why")
        );
        assert_eq!(
            Outcome::Exited(evidence(), None, None)
                .error_line()
                .as_deref(),
            Some("exit=null why")
        );
        let mut half = evidence();
        half.detail = vec![0xd83d];
        assert_eq!(
            Outcome::Exited(half, Some(1), None).error_line().as_deref(),
            Some("exit=1 \u{fffd}")
        );
    }

    #[test]
    fn the_exit_code_is_exit_for() {
        assert_eq!(Outcome::Ok(done()).exit_code(), 0);
        assert_eq!(Outcome::KilledAfterResult(done(), None).exit_code(), 0);
        assert_eq!(Outcome::Timeout(evidence(), 1.0).exit_code(), 4);
        assert_eq!(Outcome::Exited(evidence(), Some(0), None).exit_code(), 1);
        assert_eq!(Outcome::SpawnFailed(String::new()).exit_code(), 1);
    }
}
