//! The framing of the MCP stdio transport and the JSON-RPC messages the server reads and writes.
//!
//! In: one JSON value per line. A line that is not a JSON-RPC request or notification of the SDK's shape is ignored without a word, as the SDK's `ReadBuffer` and `JSONRPCMessageSchema` do (`packages/mcp/node_modules/@modelcontextprotocol/sdk/dist/esm/shared/stdio.js`, `types.js`).
//! Out: one line per message, written by one `write_all` under one lock, so two threads can never interleave their bytes.
//! The keys of a message come in the SDK's order, because the parity suite compares lines byte for byte.

use std::io::{self, Write};
use std::sync::Mutex;

use serde::Serialize;
use serde_json::{Map, Value};

/// `STDIO_DEFAULT_MAX_BUFFER_SIZE` of the SDK: the bytes of one unfinished line the transport keeps before it gives up on the stream.
pub const MAX_BUFFER: usize = 10 * 1024 * 1024;

/// The largest integer a JavaScript number holds exactly, which is the largest id the SDK's `z.number().int()` accepts.
const MAX_SAFE_INTEGER: f64 = 9_007_199_254_740_991.0;

/// The id of a request, as a client sends it. A string `"1"` and a number `1` are two ids.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize)]
#[serde(untagged)]
pub enum Id {
    Num(i64),
    Str(String),
}

impl Id {
    /// The SDK drops a `notifications/cancelled` whose `requestId` is falsy, so a request with id `0` or `""` can never be cancelled.
    pub fn is_falsy(&self) -> bool {
        matches!(self, Id::Num(0)) || matches!(self, Id::Str(s) if s.is_empty())
    }

    pub fn from_json(value: &Value) -> Option<Id> {
        match value {
            Value::String(s) => Some(Id::Str(s.clone())),
            Value::Number(n) => safe_integer(n).map(Id::Num),
            _ => None,
        }
    }
}

/// A number that JavaScript reads as a safe integer: `1`, `1.0` and `1e2` are, `1.5`, `1e999` and `2**53` are not.
fn safe_integer(n: &serde_json::Number) -> Option<i64> {
    let f = n.as_f64()?;
    // `-0` is an integer too, and JSON.stringify writes it as `0`.
    (f.is_finite() && f.fract() == 0.0 && f.abs() <= MAX_SAFE_INTEGER).then_some(f as i64)
}

/// A request the SDK would hand to a handler: the strict envelope of `JSONRPCRequestSchema`.
#[derive(Debug, PartialEq)]
pub struct Request {
    pub id: Id,
    pub method: String,
    pub params: Option<Map<String, Value>>,
}

/// A notification: the same envelope without an id.
#[derive(Debug, PartialEq)]
pub struct Notification {
    pub method: String,
    pub params: Option<Map<String, Value>>,
}

#[derive(Debug, PartialEq)]
pub enum Incoming {
    Request(Request),
    Notification(Notification),
}

/// What one line holds, or `None` when the SDK would not act on it: not JSON, not an object, a key the envelope does not have, a wrong `jsonrpc`, a response, `params` that is not an object, a bad `_meta`.
pub fn parse(line: &str) -> Option<Incoming> {
    let Value::Object(mut object) = serde_json::from_str::<Value>(line).ok()? else {
        return None;
    };
    if object.get("jsonrpc") != Some(&Value::String("2.0".to_owned())) {
        return None;
    }
    let id = object.remove("id");
    let Some(Value::String(method)) = object.remove("method") else {
        return None;
    };
    let params = match object.remove("params") {
        None => None,
        Some(Value::Object(params)) if meta_is_valid(&params) => Some(params),
        Some(_) => return None,
    };
    // `jsonrpc` is the only key left in a message of the strict shape.
    if object.len() != 1 {
        return None;
    }
    Some(match id {
        None => Incoming::Notification(Notification { method, params }),
        Some(id) => Incoming::Request(Request {
            id: Id::from_json(&id)?,
            method,
            params,
        }),
    })
}

/// `params._meta` as `RequestMetaSchema` has it: an object whose `progressToken`, when present, is a string or a safe integer, and whose related-task entry, when present, is an object with a string `taskId`. Other keys pass.
fn meta_is_valid(params: &Map<String, Value>) -> bool {
    let Some(meta) = params.get("_meta") else {
        return true;
    };
    let Value::Object(meta) = meta else {
        return false;
    };
    let token_ok = match meta.get("progressToken") {
        None | Some(Value::String(_)) => true,
        Some(Value::Number(n)) => safe_integer(n).is_some(),
        Some(_) => false,
    };
    let task_ok = match meta.get("io.modelcontextprotocol/related-task") {
        None => true,
        Some(Value::Object(task)) => matches!(task.get("taskId"), Some(Value::String(_))),
        Some(_) => false,
    };
    token_ok && task_ok
}

/// The stream overflowed `MAX_BUFFER` before a newline came.
#[derive(Debug, Eq, PartialEq)]
pub struct Overflow;

/// Cuts a byte stream into lines. A last line the stream ends in the middle of is never returned: the SDK processes a line when its newline arrives and no sooner.
#[derive(Default)]
pub struct Framer {
    buf: Vec<u8>,
    start: usize,
}

impl Framer {
    /// The SDK checks the size of what it holds plus the chunk, and so does this: a line is never longer than `MAX_BUFFER` bytes with the chunk that ends it.
    pub fn push(&mut self, chunk: &[u8]) -> Result<(), Overflow> {
        self.buf.drain(..self.start);
        self.start = 0;
        if self.buf.len() + chunk.len() > MAX_BUFFER {
            self.buf.clear();
            return Err(Overflow);
        }
        self.buf.extend_from_slice(chunk);
        Ok(())
    }

    /// The next whole line, decoded as UTF-8 with U+FFFD for what is not, without its newline and without one `\r` before it.
    pub fn next_line(&mut self) -> Option<String> {
        let rest = &self.buf[self.start..];
        let end = rest.iter().position(|&b| b == b'\n')?;
        let line = &rest[..end];
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        let text = String::from_utf8_lossy(line).into_owned();
        self.start += end + 1;
        Some(text)
    }
}

/// `{"result":…,"jsonrpc":"2.0","id":…}`: the SDK writes the result first.
#[derive(Serialize)]
struct Success<'a, T: Serialize> {
    result: T,
    jsonrpc: &'static str,
    id: &'a Id,
}

#[derive(Serialize)]
struct Failure<'a> {
    jsonrpc: &'static str,
    id: &'a Id,
    error: ErrorBody<'a>,
}

#[derive(Serialize)]
struct ErrorBody<'a> {
    code: i32,
    message: &'a str,
}

/// A tool as `tools/list` tells it: the keys come in the SDK's order.
#[derive(Serialize)]
pub struct ToolEntry {
    pub name: String,
    pub description: String,
    #[serde(rename = "inputSchema")]
    pub input_schema: Value,
    pub annotations: Value,
}

/// What a tool call answers: one text block, and whether the call failed.
#[derive(Serialize)]
pub struct CallResult {
    content: [TextBlock; 1],
    #[serde(rename = "isError")]
    is_error: bool,
}

#[derive(Serialize)]
struct TextBlock {
    r#type: &'static str,
    text: String,
}

impl CallResult {
    pub fn text(text: String, is_error: bool) -> CallResult {
        CallResult {
            content: [TextBlock {
                r#type: "text",
                text,
            }],
            is_error,
        }
    }

    pub fn body(&self) -> &str {
        &self.content[0].text
    }

    pub fn is_error(&self) -> bool {
        self.is_error
    }
}

pub const METHOD_NOT_FOUND: i32 = -32601;
pub const INVALID_PARAMS: i32 = -32602;
pub const INTERNAL_ERROR: i32 = -32603;

/// The only way out of the process on stdout: every message is serialised first, then written whole under the lock.
pub struct Out {
    sink: Mutex<Box<dyn Write + Send>>,
}

impl Out {
    pub fn new(sink: impl Write + Send + 'static) -> Out {
        Out {
            sink: Mutex::new(Box::new(sink)),
        }
    }

    pub fn success<T: Serialize>(&self, id: &Id, result: T) -> io::Result<()> {
        self.line(&Success {
            result,
            jsonrpc: "2.0",
            id,
        })
    }

    pub fn failure(&self, id: &Id, code: i32, message: &str) -> io::Result<()> {
        self.line(&Failure {
            jsonrpc: "2.0",
            id,
            error: ErrorBody { code, message },
        })
    }

    fn line<T: Serialize>(&self, message: &T) -> io::Result<()> {
        let mut bytes = serde_json::to_vec(message).map_err(io::Error::from)?;
        bytes.push(b'\n');
        // A thread that panicked while writing left a message half written: nothing more is said after it.
        let mut sink = self.sink.lock().map_err(|_| {
            io::Error::other("the output was left half written by a thread that panicked")
        })?;
        sink.write_all(&bytes)?;
        sink.flush()
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::*;

    fn request(line: &str) -> Request {
        match parse(line) {
            Some(Incoming::Request(r)) => r,
            other => panic!("not a request: {other:?}"),
        }
    }

    #[test]
    fn a_request_and_a_notification_are_told_apart_by_the_id() {
        let r = request(r#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#);
        assert_eq!(
            (r.id, r.method.as_str(), r.params),
            (Id::Num(7), "ping", None)
        );
        assert_eq!(
            parse(r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#),
            Some(Incoming::Notification(Notification {
                method: "notifications/initialized".into(),
                params: None
            })),
        );
    }

    #[test]
    fn an_id_is_a_string_or_a_safe_integer() {
        let id = |raw: &str| {
            parse(&format!(
                r#"{{"jsonrpc":"2.0","id":{raw},"method":"ping"}}"#
            ))
            .and_then(|m| match m {
                Incoming::Request(r) => Some(r.id),
                Incoming::Notification(_) => None,
            })
        };
        assert_eq!(id(r#""a""#), Some(Id::Str("a".into())));
        assert_eq!(id("1.0"), Some(Id::Num(1)));
        assert_eq!(id("1e2"), Some(Id::Num(100)));
        assert_eq!(id("-0"), Some(Id::Num(0)));
        assert_eq!(id("9007199254740991"), Some(Id::Num(9_007_199_254_740_991)));
        for refused in [
            "1.5",
            "9007199254740992",
            "1e999",
            "null",
            "true",
            "[]",
            "{}",
        ] {
            assert_eq!(id(refused), None, "{refused}");
        }
    }

    #[test]
    fn a_line_the_sdk_would_not_act_on_is_ignored() {
        for line in [
            "",
            "not json",
            "[]",
            "42",
            r#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#,
            r#"{"id":1,"method":"ping"}"#,
            r#"{"jsonrpc":"2.0","id":1}"#,
            r#"{"jsonrpc":"2.0","id":1,"method":7}"#,
            r#"{"jsonrpc":"2.0","id":1,"method":"ping","extra":true}"#,
            r#"{"jsonrpc":"2.0","method":"x","extra":true}"#,
            r#"{"jsonrpc":"2.0","id":1,"method":"ping","params":null}"#,
            r#"{"jsonrpc":"2.0","id":1,"method":"ping","params":[]}"#,
            r#"{"jsonrpc":"2.0","id":1,"result":{}}"#,
            r#"{"jsonrpc":"2.0","id":1,"error":{"code":1,"message":"m"}}"#,
        ] {
            assert_eq!(parse(line), None, "{line}");
        }
    }

    #[test]
    fn meta_is_checked_the_way_the_sdk_checks_it() {
        let with = |meta: &str| {
            parse(&format!(
                r#"{{"jsonrpc":"2.0","id":1,"method":"ping","params":{{"_meta":{meta}}}}}"#
            ))
            .is_some()
        };
        assert!(with("{}"));
        assert!(with(r#"{"progressToken":"t","other":1}"#));
        assert!(with(r#"{"progressToken":3}"#));
        assert!(with(
            r#"{"io.modelcontextprotocol/related-task":{"taskId":"x","more":1}}"#
        ));
        for refused in [
            "null",
            "1",
            r#"{"progressToken":1.5}"#,
            r#"{"progressToken":null}"#,
            r#"{"io.modelcontextprotocol/related-task":{}}"#,
            r#"{"io.modelcontextprotocol/related-task":null}"#,
        ] {
            assert!(!with(refused), "{refused}");
        }
    }

    #[test]
    fn only_zero_and_the_empty_string_are_falsy_ids() {
        assert!(Id::Num(0).is_falsy() && Id::Str(String::new()).is_falsy());
        assert!(!Id::Num(1).is_falsy() && !Id::Str("0".into()).is_falsy());
    }

    #[test]
    fn lines_come_out_whole_and_a_last_line_without_a_newline_never_does() {
        let mut framer = Framer::default();
        framer.push(b"one\r\ntw").unwrap();
        assert_eq!(framer.next_line().as_deref(), Some("one"));
        assert_eq!(framer.next_line(), None);
        framer.push(b"o\n\nlast").unwrap();
        assert_eq!(framer.next_line().as_deref(), Some("two"));
        assert_eq!(framer.next_line().as_deref(), Some(""));
        assert_eq!(framer.next_line(), None);
    }

    #[test]
    fn invalid_utf8_becomes_replacement_characters() {
        let mut framer = Framer::default();
        framer.push(b"a\xffb\n").unwrap();
        assert_eq!(framer.next_line().as_deref(), Some("a\u{fffd}b"));
    }

    #[test]
    fn an_unfinished_line_longer_than_the_buffer_overflows_it() {
        let mut framer = Framer::default();
        framer.push(&vec![b'x'; MAX_BUFFER]).unwrap();
        assert_eq!(framer.push(b"x"), Err(Overflow));
        // Finished lines do not count against the buffer.
        let mut framer = Framer::default();
        for _ in 0..3 {
            framer.push(&vec![b'x'; MAX_BUFFER - 1]).unwrap();
            framer.push(b"\n").unwrap();
            assert_eq!(framer.next_line().map(|l| l.len()), Some(MAX_BUFFER - 1));
        }
    }

    /// A sink the test can read, and one that fails.
    #[derive(Clone, Default)]
    struct Shared(Arc<Mutex<Vec<u8>>>);

    impl Write for Shared {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    struct Broken;

    impl Write for Broken {
        fn write(&mut self, _: &[u8]) -> io::Result<usize> {
            Err(io::ErrorKind::BrokenPipe.into())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn messages_are_written_one_per_line_with_the_keys_in_the_sdks_order() {
        let sink = Shared::default();
        let out = Out::new(sink.clone());
        out.success(&Id::Num(1), serde_json::json!({})).unwrap();
        out.failure(&Id::Str("a".into()), METHOD_NOT_FOUND, "Method not found")
            .unwrap();
        let written = String::from_utf8(sink.0.lock().unwrap().clone()).unwrap();
        assert_eq!(
            written,
            "{\"result\":{},\"jsonrpc\":\"2.0\",\"id\":1}\n{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}\n",
        );
    }

    #[test]
    fn a_failed_write_is_an_error_for_the_caller() {
        let err = Out::new(Broken)
            .success(&Id::Num(1), serde_json::json!({}))
            .unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::BrokenPipe);
    }

    #[test]
    fn threads_never_interleave_their_lines() {
        let sink = Shared::default();
        let out = Arc::new(Out::new(sink.clone()));
        let threads: Vec<_> = (0..8)
            .map(|n| {
                let out = Arc::clone(&out);
                std::thread::spawn(move || {
                    for i in 0..50 {
                        out.success(
                            &Id::Num(n * 100 + i),
                            serde_json::json!({"text": "x".repeat(2000)}),
                        )
                        .unwrap();
                    }
                })
            })
            .collect();
        for t in threads {
            t.join().unwrap();
        }
        let written = String::from_utf8(sink.0.lock().unwrap().clone()).unwrap();
        assert_eq!(written.lines().count(), 400);
        assert!(
            written
                .lines()
                .all(|l| serde_json::from_str::<Value>(l).is_ok())
        );
    }
}
