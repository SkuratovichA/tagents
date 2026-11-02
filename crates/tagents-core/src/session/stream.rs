//! `StreamReader` of `packages/core/src/stream.ts`: what `claude --output-format stream-json` prints, one JSON object per line, read into events and a small final state (design D8).
//!
//! It keeps no stdout: a tool's result can be megabytes, and only the result payload and the assistant's text stay. Lines are cut on the byte `0x0A` before they are decoded, so a character split between two reads is whole and invalid bytes read as U+FFFD.
//!
//! The strings are exact: `claude` is node, so a lone surrogate half can arrive as an escape, and node prints it back as that escape. Text is kept as UTF-16 units, so two halves from two blocks join. The one thing that is not kept is an object key with a lone half (`json::parse_exact`).

use crate::js;
use crate::json::{self, Value};

/// The keys of `PayloadSchema`, in the order the schema writes them.
const PAYLOAD_KEYS: [&str; 6] = [
    "is_error",
    "result",
    "session_id",
    "total_cost_usd",
    "duration_ms",
    "num_turns",
];

/// The reader of one child's stdout. Feed it with `push` and `end`, read the fields once the turn is over.
#[derive(Debug, Default)]
pub struct Reader {
    /// The last result payload, in the key order of the schema's output.
    pub payload: Option<Value>,
    /// The last `session_id` an event carried that was not empty: the id to resume this session with.
    pub session_id: Option<Value>,
    pub tool_uses: u64,
    /// The assistant's text blocks, joined; what its tools returned is never here.
    pub text: Vec<u16>,
    /// Whether a `result` has arrived, which ends the turn.
    pub saw_result: bool,
    /// Whether anyone reads the events: without `--events` no line is built.
    listening: bool,
    /// The bytes of a line that has not ended yet.
    pending: Vec<u8>,
}

/// `z.string().optional()`.
fn string_or_absent(value: Option<&Value>) -> bool {
    matches!(value, None | Some(Value::String(_) | Value::Units(_)))
}

/// `z.number().optional()`, which refuses a number that read as infinity.
fn number_or_absent(value: Option<&Value>) -> bool {
    match value {
        None => true,
        Some(Value::Number(number)) => number.is_finite(),
        Some(_) => false,
    }
}

/// `PayloadSchema.safeParse(json).success`, for an object.
fn fits_payload(json: &Value) -> bool {
    matches!(json.get("is_error"), None | Some(Value::Bool(_)))
        && string_or_absent(json.get("result"))
        && string_or_absent(json.get("session_id"))
        && number_or_absent(json.get("total_cost_usd"))
        && number_or_absent(json.get("duration_ms"))
        && number_or_absent(json.get("num_turns"))
}

/// The output of the schema: the known keys in its order (`type` after them when the schema is `ResultEventSchema`), then the others as they came. A top-level `__proto__` is dropped, whatever it holds. `stringify` prints the keys in JavaScript's order and keeps the last value of a key written twice, so the unknown keys are left as they are. The members move: a nested value can be too deep to clone.
fn payload_of(mut json: Value, with_type: bool) -> Value {
    let Value::Object(members) = &mut json else {
        return json;
    };
    let is_known = |key: &str| PAYLOAD_KEYS.contains(&key) || (with_type && key == "type");
    let (mut known, others): (Vec<_>, Vec<_>) = std::mem::take(members)
        .into_iter()
        .filter(|(key, _)| key != "__proto__")
        .partition(|(key, _)| is_known(key));
    let mut ordered = Vec::with_capacity(known.len() + others.len());
    for key in PAYLOAD_KEYS
        .iter()
        .copied()
        .chain(with_type.then_some("type"))
    {
        if let Some(at) = known.iter().rposition(|(name, _)| name == key) {
            ordered.push(known.swap_remove(at));
        }
    }
    ordered.extend(others);
    Value::Object(ordered)
}

/// The value at `key`, moved out of the object.
fn take(value: &mut Value, key: &str) -> Option<Value> {
    value
        .get_mut(key)
        .map(|found| std::mem::replace(found, Value::Null))
}

fn event(kind: &str, members: Vec<(&str, Value)>) -> String {
    let mut all = vec![("kind".to_owned(), Value::String(kind.to_owned()))];
    all.extend(
        members
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value)),
    );
    json::stringify(&Value::Object(all), false)
}

impl Reader {
    /// A reader that calls its listener with the line of each event.
    pub fn listening() -> Reader {
        Reader {
            listening: true,
            ..Reader::default()
        }
    }

    /// A chunk of the child's stdout, cut anywhere.
    pub fn push(&mut self, chunk: &[u8], on: &mut dyn FnMut(&str)) {
        for piece in chunk.split_inclusive(|byte| *byte == b'\n') {
            let Some((b'\n', line)) = piece.split_last() else {
                self.pending.extend_from_slice(piece);
                continue;
            };
            if self.pending.is_empty() {
                self.line(line, on);
            } else {
                self.pending.extend_from_slice(line);
                let whole = std::mem::take(&mut self.pending);
                self.line(&whole, on);
            }
        }
    }

    /// The end of the stream: a last line may have no newline.
    pub fn end(&mut self, on: &mut dyn FnMut(&str)) {
        let rest = std::mem::take(&mut self.pending);
        if !rest.is_empty() {
            self.line(&rest, on);
        }
    }

    fn line(&mut self, raw: &[u8], on: &mut dyn FnMut(&str)) {
        let decoded = String::from_utf8_lossy(raw);
        let line = js::trim(&decoded);
        if !line.starts_with('{') {
            return;
        }
        let Some(json::Exact {
            value: mut json, ..
        }) = json::parse_exact(line)
        else {
            return;
        };
        let envelope =
            string_or_absent(json.get("type")) && string_or_absent(json.get("session_id"));
        if envelope && let Some(id) = json.get("session_id").filter(|id| id.truthy()) {
            self.session_id = Some(id.clone());
        }
        let kind = json.get("type").and_then(Value::as_str);
        if kind == Some("result") && fits_payload(&json) {
            self.result(payload_of(json, true), on);
            return;
        }
        if kind == Some("assistant") {
            let content = json
                .get_mut("message")
                .and_then(|message| message.get_mut("content"));
            if let Some(Value::Array(blocks)) = content {
                for block in std::mem::take(blocks) {
                    self.block(block, on);
                }
                return;
            }
        }
        let typed = envelope && json.get("type").is_some_and(Value::truthy);
        if !typed && fits_payload(&json) && json.get("is_error").is_some() {
            self.result(payload_of(json, false), on);
            return;
        }
        if typed
            && self.listening
            && let Some(name) = take(&mut json, "type")
        {
            on(&event("other", vec![("type", name)]));
        }
    }

    fn result(&mut self, payload: Value, on: &mut dyn FnMut(&str)) {
        self.saw_result = true;
        if self.listening {
            let is_error = matches!(payload.get("is_error"), Some(Value::Bool(true)));
            on(&format!(
                "{{\"kind\":\"result\",\"isError\":{is_error},\"payload\":{}}}",
                json::stringify(&payload, false)
            ));
        }
        self.payload = Some(payload);
    }

    /// One block of an assistant message: a tool call, a text that is not empty, or nothing.
    fn block(&mut self, mut block: Value, on: &mut dyn FnMut(&str)) {
        match block.get("type").and_then(Value::as_str) {
            Some("tool_use") => {
                let input_fits = matches!(block.get("input"), None | Some(Value::Object(_)));
                if !input_fits
                    || !matches!(block.get("name"), Some(Value::String(_) | Value::Units(_)))
                {
                    return;
                }
                self.tool_uses += 1;
                if !self.listening {
                    return;
                }
                let name = take(&mut block, "name").unwrap_or(Value::Null);
                let mut input = take(&mut block, "input").unwrap_or(Value::Object(Vec::new()));
                // `z.record` drops the key, whatever it holds.
                if let Value::Object(members) = &mut input {
                    members.retain(|(key, _)| key != "__proto__");
                }
                on(&event("tool_use", vec![("name", name), ("input", input)]));
            }
            Some("text") => {
                let Some(units) = block.get("text").and_then(Value::units) else {
                    return;
                };
                if units.is_empty() {
                    return;
                }
                self.text.extend_from_slice(&units);
                if self.listening {
                    on(&event("text", vec![("text", Value::from_units(units))]));
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Feeds the chunks and ends the stream; the lines the reader wrote come back.
    fn read(chunks: &[&[u8]]) -> (Reader, Vec<String>) {
        let mut reader = Reader::listening();
        let mut lines = Vec::new();
        let mut on = |line: &str| lines.push(line.to_owned());
        for chunk in chunks {
            reader.push(chunk, &mut on);
        }
        reader.end(&mut on);
        (reader, lines)
    }

    fn read_text(text: &str) -> (Reader, Vec<String>) {
        read(&[text.as_bytes()])
    }

    fn assistant_text(text: &str) -> String {
        format!(
            r#"{{"type":"assistant","message":{{"content":[{{"type":"text","text":{text}}}]}}}}"#
        )
    }

    fn payload_text(reader: &Reader) -> String {
        json::stringify(reader.payload.as_ref().unwrap(), false)
    }

    #[test]
    fn a_character_split_between_two_reads_is_whole() {
        let line = format!("{}\n", assistant_text("\"é\""));
        let bytes = line.as_bytes();
        let cut = line.find('é').unwrap() + 1;
        let (reader, lines) = read(&[&bytes[..cut], &bytes[cut..]]);
        assert_eq!(String::from_utf16(&reader.text).unwrap(), "é");
        assert_eq!(lines, [r#"{"kind":"text","text":"é"}"#]);
    }

    #[test]
    fn the_cut_is_the_byte_0a_and_a_line_is_decoded_whole() {
        // Bytes that are not UTF-8 read as U+FFFD, each maximal part once, wherever the reads fell.
        let start = br#"{"type":"assistant","message":{"content":[{"type":"text","text":"a"#;
        let end = br#"b"}]}}"#;
        let mut line = start.to_vec();
        line.extend_from_slice(b"\xe2\x82");
        line.extend_from_slice(end);
        line.push(b'\n');
        let whole = read(&[&line]);
        assert_eq!(String::from_utf16(&whole.0.text).unwrap(), "a\u{fffd}b");
        let by_byte: Vec<&[u8]> = line.chunks(1).collect();
        assert_eq!(read(&by_byte).0.text, whole.0.text);
        // A line separator inside a string does not end the line, and a carriage return is trimmed.
        let (reader, _) = read_text(&format!("{}\r\n", assistant_text("\"a\u{2028}b\"")));
        assert_eq!(String::from_utf16(&reader.text).unwrap(), "a\u{2028}b");
    }

    #[test]
    fn a_line_is_trimmed_as_ecmascript_trims() {
        let result = r#"{"type":"result","is_error":false}"#;
        for space in ["\u{feff}", "\u{a0}\u{2003}", " \t", "\u{3000}"] {
            let (reader, _) = read_text(&format!("{space}{result}{space}\n"));
            assert!(reader.saw_result, "{space:?}");
        }
        // U+0085 is white space in Rust and not in ECMAScript.
        assert!(!read_text(&format!("\u{85}{result}\n")).0.saw_result);
    }

    #[test]
    fn lines_that_are_not_json_objects_are_noise() {
        let (reader, lines) =
            read_text("banner\n[1]\n\"s\"\nnull\n{broken\n{\"type\":\"system\"} x\n\n");
        assert!(lines.is_empty(), "{lines:?}");
        assert!(reader.payload.is_none() && reader.session_id.is_none());
    }

    #[test]
    fn a_last_line_with_no_newline_is_read_at_the_end() {
        let mut reader = Reader::listening();
        let mut lines = Vec::new();
        reader.push(br#"{"type":"result","is_error":false}"#, &mut |l: &str| {
            lines.push(l.to_owned())
        });
        assert!(!reader.saw_result);
        reader.end(&mut |l: &str| lines.push(l.to_owned()));
        assert!(reader.saw_result);
        assert_eq!(lines.len(), 1);
    }

    #[test]
    fn the_envelope_remembers_a_session_id_that_is_not_empty() {
        let id = |text: &str| {
            read_text(text)
                .0
                .session_id
                .and_then(|v| v.as_str().map(str::to_owned))
        };
        assert_eq!(id("{\"session_id\":\"only\"}\n").as_deref(), Some("only"));
        assert_eq!(id("{\"type\":\"s\",\"session_id\":\"\"}\n"), None);
        assert_eq!(
            id("{\"type\":\"s\",\"session_id\":\"a\"}\n{\"type\":\"s\",\"session_id\":\"\"}\n")
                .as_deref(),
            Some("a")
        );
        // An envelope with a `type` that is no string fails as a whole.
        assert_eq!(id("{\"type\":5,\"session_id\":\"n\"}\n"), None);
    }

    #[test]
    fn the_tree_is_result_then_assistant_then_plain_then_other() {
        let (reader, lines) = read_text(concat!(
            "{\"type\":\"system\",\"session_id\":\"s\"}\n",
            "{\"type\":\"assistant\",\"message\":{\"content\":[",
            "{\"type\":\"text\",\"text\":\"one\"},5,null,{\"type\":\"thinking\"},",
            "{\"type\":\"tool_use\",\"name\":\"A\"},{\"type\":\"tool_use\",\"input\":{}},",
            "{\"type\":\"tool_use\",\"name\":\"B\",\"input\":[1]},{\"type\":\"text\",\"text\":\"\"},",
            "{\"type\":\"tool_use\",\"name\":\"C\",\"input\":{\"x\":1}}]}}\n",
            "{\"type\":\"assistant\"}\n",
            "{\"type\":\"result\",\"is_error\":false,\"result\":\"r\"}\n",
        ));
        assert_eq!(
            lines,
            [
                r#"{"kind":"other","type":"system"}"#,
                r#"{"kind":"text","text":"one"}"#,
                r#"{"kind":"tool_use","name":"A","input":{}}"#,
                r#"{"kind":"tool_use","name":"C","input":{"x":1}}"#,
                r#"{"kind":"other","type":"assistant"}"#,
                r#"{"kind":"result","isError":false,"payload":{"is_error":false,"result":"r","type":"result"}}"#,
            ]
        );
        assert_eq!(reader.tool_uses, 2);
    }

    #[test]
    fn a_result_that_fails_the_schema_is_an_other_event_and_does_not_end_the_turn() {
        for fields in [
            "\"is_error\":null",
            "\"is_error\":\"no\"",
            "\"result\":5",
            "\"total_cost_usd\":1e999",
            "\"duration_ms\":null",
            "\"num_turns\":\"1\"",
        ] {
            let (reader, lines) = read_text(&format!("{{\"type\":\"result\",{fields}}}\n"));
            assert!(!reader.saw_result, "{fields}");
            assert_eq!(lines, [r#"{"kind":"other","type":"result"}"#], "{fields}");
        }
        // A `session_id` that is no string fails the envelope too, which is what the `other` event reads its type from.
        let (reader, lines) = read_text("{\"type\":\"result\",\"session_id\":5}\n");
        assert!(!reader.saw_result && lines.is_empty(), "{lines:?}");
    }

    #[test]
    fn the_payload_has_the_keys_of_the_schema_first_then_the_others() {
        let (reader, _) = read_text(concat!(
            "{\"zeta\":1,\"num_turns\":1,\"type\":\"result\",\"session_id\":\"s\",\"duration_ms\":2,\"alpha\":{\"__proto__\":{\"a\":1}},",
            "\"result\":\"r\",\"is_error\":true,\"total_cost_usd\":3,\"__proto__\":{\"x\":1},\"7\":\"seven\",\"2\":\"two\"}\n"
        ));
        assert_eq!(
            payload_text(&reader),
            concat!(
                "{\"2\":\"two\",\"7\":\"seven\",\"is_error\":true,\"result\":\"r\",\"session_id\":\"s\",\"total_cost_usd\":3,\"duration_ms\":2,\"num_turns\":1,",
                "\"type\":\"result\",\"zeta\":1,\"alpha\":{\"__proto__\":{\"a\":1}}}"
            )
        );
    }

    #[test]
    fn a_plain_payload_has_no_type_and_has_an_is_error_key() {
        let (reader, lines) = read_text("{\"is_error\":true,\"result\":\"plain\"}\n");
        assert!(reader.saw_result);
        assert_eq!(
            lines,
            [r#"{"kind":"result","isError":true,"payload":{"is_error":true,"result":"plain"}}"#]
        );
        // An empty type is no type, and it stays among the other keys.
        let (reader, _) = read_text("{\"type\":\"\",\"is_error\":false,\"result\":\"r\"}\n");
        assert_eq!(
            payload_text(&reader),
            r#"{"is_error":false,"result":"r","type":""}"#
        );
        // A type that fails the envelope is no type either.
        assert_eq!(
            payload_text(&read_text("{\"type\":5,\"is_error\":false}\n").0),
            r#"{"is_error":false,"type":5}"#
        );
        for other in [
            "{\"type\":\"summary\",\"is_error\":false}\n",
            "{\"is_error\":null}\n",
            "{\"result\":\"r\"}\n",
        ] {
            assert!(!read_text(other).0.saw_result, "{other}");
        }
    }

    #[test]
    fn the_last_result_is_the_payload() {
        let (reader, lines) = read_text(concat!(
            "{\"type\":\"result\",\"is_error\":false,\"result\":\"first\"}\n",
            "{\"type\":\"result\",\"is_error\":true,\"result\":\"second\"}\n",
        ));
        assert_eq!(lines.len(), 2);
        assert_eq!(
            payload_text(&reader),
            r#"{"is_error":true,"result":"second","type":"result"}"#
        );
    }

    #[test]
    fn two_halves_join_and_a_lone_half_prints_as_its_escape() {
        let (reader, lines) = read_text(&format!(
            "{}\n{}\n",
            assistant_text(r#""a\ud83d""#),
            assistant_text(r#""\ude00b""#)
        ));
        assert_eq!(String::from_utf16(&reader.text).unwrap(), "a\u{1f600}b");
        assert_eq!(
            lines,
            [
                r#"{"kind":"text","text":"a\ud83d"}"#,
                r#"{"kind":"text","text":"\ude00b"}"#
            ]
        );
        let (reader, _) = read_text(&format!("{}\n", assistant_text(r#""\ud83d""#)));
        assert_eq!(json::quote_units(&reader.text), r#""\ud83d""#);
        let (_, lines) = read_text(
            "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"\\ud83d\",\"input\":{\"k\":[\"\\ude00\"]}}]}}\n",
        );
        assert_eq!(
            lines,
            [r#"{"kind":"tool_use","name":"\ud83d","input":{"k":["\ude00"]}}"#]
        );
    }

    #[test]
    fn nobody_listening_means_no_line_and_the_same_state() {
        let mut reader = Reader::default();
        let mut lines = 0;
        reader.push(
            b"{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"t\"},{\"type\":\"tool_use\",\"name\":\"A\"}]}}\n{\"type\":\"result\",\"is_error\":false}\n{\"type\":\"system\"}\n",
            &mut |_: &str| lines += 1,
        );
        assert_eq!(lines, 0);
        assert!(reader.saw_result);
        assert_eq!((reader.tool_uses, reader.text.len()), (1, 1));
    }

    #[test]
    fn a_value_nested_very_deep_is_moved_and_never_cloned() {
        // A test thread has 2 MiB of stack, which a clone or a recursive print of this value overflows.
        let deep = 300_000;
        let input = format!("{}1{}", "{\"a\":".repeat(deep), "}".repeat(deep));
        let tool = format!(
            "{{\"type\":\"assistant\",\"message\":{{\"content\":[{{\"type\":\"tool_use\",\"name\":\"T\",\"input\":{input}}}]}}}}\n"
        );
        let (reader, lines) = read_text(&tool);
        assert_eq!(reader.tool_uses, 1);
        assert_eq!(
            lines[0].len(),
            input.len() + r#"{"kind":"tool_use","name":"T","input":}"#.len()
        );
        let result = format!(
            "{{\"type\":\"result\",\"is_error\":false,\"deep\":{input},\"__proto__\":{input}}}\n"
        );
        let (reader, lines) = read_text(&result);
        assert!(reader.saw_result);
        assert!(lines[0].starts_with(r#"{"kind":"result","isError":false,"payload":{"is_error":false,"type":"result","deep":{"a""#));
    }

    #[test]
    fn a_stream_that_never_ends_a_line_keeps_only_that_line() {
        let mut reader = Reader::listening();
        let mut lines = 0;
        for _ in 0..3 {
            reader.push(b"xxxx", &mut |_: &str| lines += 1);
        }
        assert_eq!(reader.pending.len(), 12);
        reader.push(b"\nrest", &mut |_: &str| lines += 1);
        assert_eq!(reader.pending, b"rest");
        assert_eq!(lines, 0);
    }
}
