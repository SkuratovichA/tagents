//! `JSON.parse`, as far as the transcript reader can tell the difference.
//!
//! `serde_json` is the standard parser and differs from V8 in three ways that change which transcript lines are read:
//! it refuses a lone surrogate escape (`"\ud800"`), where V8 keeps it;
//! it refuses a number that overflows a float (`1e999`), where V8 reads Infinity;
//! and it stops at 128 levels of nesting, where V8 goes on until memory runs out.
//! A line one of those fails on is skipped by Rust and read by node, so the two programs would list different prompts.
//! This parser takes exactly the grammar of ECMA-404 and keeps a number as the float JavaScript would make of it, which is what `isMeta` (truthiness) and the plugin manifest check (`apiVersion` is 1) need.
//! It keeps its own stack of open containers, so nesting costs heap, not call frames.
//!
//! `parse_exact` is the same reader for a program that prints what it read back as `JSON.stringify` does: it keeps a string that holds a lone surrogate half as the UTF-16 it is (`Value::Units`), where `parse` reads U+FFFD, which is what stdout would show.
//! The one thing it does not keep is an object key with a lone half, which it reads as U+FFFD and reports in `Exact::lone_key`.
//!
//! `quote` is the other direction for one string: `JSON.stringify(text)`, which the daemon writes into the helper's input, into its log lines and into the text of a problem. `quote_units` is the same for UTF-16, which can hold a half that only an escape can write, and `quote_prefix16` is `JSON.stringify(text.slice(0, n))`, whose cut can leave one. `stringify` prints a whole value.

use std::collections::HashMap;
use std::collections::hash_map::Entry;

use serde::Serialize;

use crate::js;

/// A parsed value. `parse` reads a lone surrogate escape as U+FFFD, which is how stdout would write it.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    /// The number as JavaScript reads it: an overflow is infinity, and `1.0` and `1e0` are the number 1.
    Number(f64),
    String(String),
    /// A string that holds a surrogate half with no partner, which a `String` cannot. A string that is well-formed is always a `Value::String` (`from_units` and `parse_exact` see to it), so equal strings are equal values.
    Units(Vec<u16>),
    Array(Vec<Value>),
    /// In document order, so a key written twice is found last, as in an object.
    Object(Vec<(String, Value)>),
}

impl Value {
    /// `obj[key]` when `self` is an object. A duplicate key reads as its last occurrence.
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Object(members) => members.iter().rev().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    /// The members of an object in the order JavaScript keeps them (a key written twice once, with its last value), or `None` for a value that is not an object.
    pub fn entries(&self) -> Option<Vec<(&str, &Value)>> {
        match self {
            Value::Object(members) => Some(in_js_order(members)),
            _ => None,
        }
    }

    /// The text of a well-formed string; a string with a lone half has none.
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::String(s) => Some(s),
            _ => None,
        }
    }

    /// The UTF-16 code units of a string, whole or not.
    pub fn units(&self) -> Option<Vec<u16>> {
        match self {
            Value::String(s) => Some(js::units(s)),
            Value::Units(units) => Some(units.clone()),
            _ => None,
        }
    }

    /// The string these code units make: text when they are well-formed, the units themselves when a half has no partner.
    pub fn from_units(units: Vec<u16>) -> Value {
        match String::from_utf16(&units) {
            Ok(text) => Value::String(text),
            Err(_) => Value::Units(units),
        }
    }

    /// JavaScript's `!!value`.
    pub fn truthy(&self) -> bool {
        match self {
            Value::Null => false,
            Value::Bool(b) => *b,
            Value::Number(n) => *n != 0.0,
            Value::String(s) => !s.is_empty(),
            Value::Units(_) | Value::Array(_) | Value::Object(_) => true,
        }
    }
}

/// Dropping a value nested a hundred thousand deep would recurse once per level, so the children are taken apart on a heap stack instead.
impl Drop for Value {
    fn drop(&mut self) {
        let mut pending = Vec::new();
        self.take_children(&mut pending);
        while let Some(mut value) = pending.pop() {
            value.take_children(&mut pending);
        }
    }
}

impl Value {
    fn take_children(&mut self, into: &mut Vec<Value>) {
        match self {
            Value::Array(items) => into.append(items),
            Value::Object(members) => into.extend(members.drain(..).map(|(_, value)| value)),
            _ => {}
        }
    }
}

enum Open {
    Array(Vec<Value>),
    Object(Vec<(String, Value)>, String),
}

/// `JSON.stringify(text)` of a string: a quote, a backslash, `\b \f \n \r \t`, any other control character as lowercase `\u00xx`, and U+2028, U+2029 and everything above ASCII raw, which the tests pin against V8.
pub fn quote(text: &str) -> String {
    serde_json::Value::String(text.to_owned()).to_string()
}

/// `JSON.stringify` of a string given as UTF-16 code units: a half with no partner is the lowercase escape `\ud83d`, where text written raw would show U+FFFD, and the rest is what `quote` writes.
pub fn quote_units(units: &[u16]) -> String {
    let mut out = String::from('"');
    let mut run = String::new();
    for piece in char::decode_utf16(units.iter().copied()) {
        match piece {
            Ok(c) => run.push(c),
            Err(lone) => {
                push_quoted(&mut out, &run);
                run.clear();
                out.push_str(&format!("\\u{:04x}", lone.unpaired_surrogate()));
            }
        }
    }
    push_quoted(&mut out, &run);
    out.push('"');
    out
}

/// What stands between the quotes of `quote(text)`.
fn push_quoted(out: &mut String, text: &str) {
    let quoted = quote(text);
    out.push_str(&quoted[1..quoted.len() - 1]);
}

/// `JSON.stringify(text.slice(0, n))`, with `n` in UTF-16 units. A cut between the two halves of a surrogate pair leaves the high half alone, which `quote_units` writes as an escape.
pub fn quote_prefix16(text: &str, n: usize) -> String {
    quote_units(&text.encode_utf16().take(n).collect::<Vec<u16>>())
}

/// `JSON.stringify(value, null, 2)` of anything serde can write. The value goes through its JSON text and this parser, so that `stringify` is the one writer and a number and the order of the keys come out as JavaScript holds them. What is written is strings, numbers, and documents that were just parsed or built: there is nothing in it to fail on.
pub(crate) fn pretty<T: Serialize + ?Sized>(value: &T) -> String {
    match serde_json::to_string(value) {
        Ok(text) => match parse(&text) {
            Some(parsed) => stringify(&parsed, true),
            None => text,
        },
        Err(e) => e.to_string(),
    }
}

/// `JSON.parse(text)`, or `None` where it would throw.
pub fn parse(text: &str) -> Option<Value> {
    Parser::new(text, false).document()
}

/// What `parse_exact` read: the value, and whether an object key in it held a lone surrogate half, which the value reads as U+FFFD.
#[derive(Debug, Clone, PartialEq)]
pub struct Exact {
    pub value: Value,
    pub lone_key: bool,
}

/// `JSON.parse(text)` that keeps a string with a lone surrogate half as `Value::Units`, or `None` where it would throw. It accepts exactly the texts `parse` accepts.
pub fn parse_exact(text: &str) -> Option<Exact> {
    let mut parser = Parser::new(text, true);
    let value = parser.document()?;
    Some(Exact {
        value,
        lone_key: parser.lone_key,
    })
}

/// A container being printed: the members still to come, the character that closes it, and whether one has been written.
struct Level<'a> {
    members: Box<dyn Iterator<Item = (Option<&'a str>, &'a Value)> + 'a>,
    close: char,
    written: bool,
}

/// `JSON.stringify(value)`, or `JSON.stringify(value, null, 2)` with `indent`.
/// A number that is not finite is `null`, the keys of an object come in JavaScript's order, and a container is printed from a heap stack, so a value nested a hundred thousand deep costs heap and not call frames.
pub fn stringify(value: &Value, indent: bool) -> String {
    let mut out = String::new();
    let mut open: Vec<Level> = Vec::new();
    let mut pending = Some(value);
    loop {
        if let Some(value) = pending.take() {
            open.extend(begin(value, &mut out));
        }
        let Some(level) = open.last_mut() else {
            return out;
        };
        let Some((key, member)) = level.members.next() else {
            let (close, written) = (level.close, level.written);
            open.pop();
            if indent && written {
                newline(&mut out, open.len());
            }
            out.push(close);
            continue;
        };
        if level.written {
            out.push(',');
        }
        level.written = true;
        if indent {
            newline(&mut out, open.len());
        }
        if let Some(key) = key {
            out.push_str(&quote(key));
            out.push(':');
            if indent {
                out.push(' ');
            }
        }
        pending = Some(member);
    }
}

fn newline(out: &mut String, depth: usize) {
    out.push('\n');
    out.extend(std::iter::repeat_n(' ', 2 * depth));
}

/// Writes a scalar, or the opening of a container and the level that goes with it.
fn begin<'a>(value: &'a Value, out: &mut String) -> Option<Level<'a>> {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) if n.is_finite() => out.push_str(&js::number_text(*n)),
        Value::Number(_) => out.push_str("null"),
        Value::String(text) => out.push_str(&quote(text)),
        Value::Units(units) => out.push_str(&quote_units(units)),
        Value::Array(items) => {
            out.push('[');
            return Some(Level {
                members: Box::new(items.iter().map(|item| (None, item))),
                close: ']',
                written: false,
            });
        }
        Value::Object(members) => {
            out.push('{');
            return Some(Level {
                members: Box::new(in_js_order(members).into_iter().map(|(k, v)| (Some(k), v))),
                close: '}',
                written: false,
            });
        }
    }
    None
}

/// The members of an object in the order JavaScript keeps them: the keys that are array indices first and ascending, then the others as they came; a key written twice keeps the place of its first and the value of its last.
fn in_js_order(members: &[(String, Value)]) -> Vec<(&str, &Value)> {
    let mut slots: Vec<(&str, &Value)> = Vec::with_capacity(members.len());
    let mut at: HashMap<&str, usize> = HashMap::new();
    for (key, value) in members {
        match at.entry(key) {
            Entry::Occupied(slot) => slots[*slot.get()].1 = value,
            Entry::Vacant(slot) => {
                slot.insert(slots.len());
                slots.push((key, value));
            }
        }
    }
    // The sort is stable, and every key that is not an index has the same sort key.
    slots.sort_by_key(|(key, _)| array_index(key).map_or((1, 0), |index| (0, index)));
    slots
}

/// The number a property key stands for when it is an array index: a canonical decimal integer from 0 to 2^32 - 2.
fn array_index(key: &str) -> Option<u32> {
    let canonical =
        (key == "0" || !key.starts_with('0')) && key.bytes().all(|b| b.is_ascii_digit());
    canonical
        .then(|| key.parse().ok())
        .flatten()
        .filter(|&index| index != u32::MAX)
}

/// A string literal while it is read: characters, and code units from the first lone half on.
enum Text {
    Chars(String),
    Units(Vec<u16>),
}

impl Text {
    fn push_str(&mut self, s: &str) {
        match self {
            Text::Chars(chars) => chars.push_str(s),
            Text::Units(units) => units.extend(s.encode_utf16()),
        }
    }

    fn push(&mut self, c: char) {
        self.push_str(c.encode_utf8(&mut [0; 4]));
    }

    /// A surrogate half that has no partner.
    fn push_lone(&mut self, half: u16) {
        if let Text::Chars(chars) = self {
            *self = Text::Units(js::units(chars));
        }
        if let Text::Units(units) = self {
            units.push(half);
        }
    }

    fn into_value(self) -> Value {
        match self {
            Text::Chars(chars) => Value::String(chars),
            Text::Units(units) => Value::Units(units),
        }
    }
}

struct Parser<'a> {
    b: &'a [u8],
    text: &'a str,
    i: usize,
    /// Whether a lone surrogate half is kept (`parse_exact`) or read as U+FFFD (`parse`).
    exact: bool,
    /// Whether the key of an object held a lone half.
    lone_key: bool,
}

impl<'a> Parser<'a> {
    fn new(text: &'a str, exact: bool) -> Self {
        Parser {
            b: text.as_bytes(),
            text,
            i: 0,
            exact,
            lone_key: false,
        }
    }

    fn document(&mut self) -> Option<Value> {
        let mut stack: Vec<Open> = Vec::new();
        loop {
            // A value starts here: either a scalar, which is complete at once, or a container that opens.
            self.skip_space();
            let mut done = match self.peek()? {
                b'[' => {
                    self.i += 1;
                    self.skip_space();
                    if self.peek()? == b']' {
                        self.i += 1;
                        Value::Array(Vec::new())
                    } else {
                        stack.push(Open::Array(Vec::new()));
                        continue;
                    }
                }
                b'{' => {
                    self.i += 1;
                    self.skip_space();
                    if self.peek()? == b'}' {
                        self.i += 1;
                        Value::Object(Vec::new())
                    } else {
                        let key = self.key()?;
                        stack.push(Open::Object(Vec::new(), key));
                        continue;
                    }
                }
                b'"' => self.string()?.into_value(),
                b't' => self.literal("true", Value::Bool(true))?,
                b'f' => self.literal("false", Value::Bool(false))?,
                b'n' => self.literal("null", Value::Null)?,
                b'-' | b'0'..=b'9' => self.number()?,
                _ => return None,
            };
            // The value is complete: hand it to the container it sits in, and close containers while their end follows.
            loop {
                self.skip_space();
                match stack.pop() {
                    None => return (self.i == self.b.len()).then_some(done),
                    Some(Open::Array(mut items)) => {
                        items.push(done);
                        match self.next()? {
                            b',' => {
                                stack.push(Open::Array(items));
                                break;
                            }
                            b']' => done = Value::Array(items),
                            _ => return None,
                        }
                    }
                    Some(Open::Object(mut members, key)) => {
                        members.push((key, done));
                        match self.next()? {
                            b',' => {
                                self.skip_space();
                                let key = self.key()?;
                                stack.push(Open::Object(members, key));
                                break;
                            }
                            b'}' => done = Value::Object(members),
                            _ => return None,
                        }
                    }
                }
            }
        }
    }

    fn peek(&self) -> Option<u8> {
        self.b.get(self.i).copied()
    }

    fn next(&mut self) -> Option<u8> {
        let byte = self.peek()?;
        self.i += 1;
        Some(byte)
    }

    fn skip_space(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.i += 1;
        }
    }

    /// `"name" :`, with the cursor on the opening quote. A key is text: a lone half in it reads as U+FFFD, and `lone_key` says so.
    fn key(&mut self) -> Option<String> {
        if self.peek()? != b'"' {
            return None;
        }
        let key = match self.string()? {
            Text::Chars(text) => text,
            Text::Units(units) => {
                self.lone_key = true;
                js::text16(&units)
            }
        };
        self.skip_space();
        (self.next()? == b':').then_some(key)
    }

    fn literal(&mut self, word: &str, value: Value) -> Option<Value> {
        if self.b[self.i..].starts_with(word.as_bytes()) {
            self.i += word.len();
            Some(value)
        } else {
            None
        }
    }

    fn number(&mut self) -> Option<Value> {
        let start = self.i;
        if self.peek() == Some(b'-') {
            self.i += 1;
        }
        match self.next()? {
            b'0' => {}
            b'1'..=b'9' => self.digits(),
            _ => return None,
        }
        if self.peek() == Some(b'.') {
            self.i += 1;
            if !self.digits_at_least_one() {
                return None;
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.i += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.i += 1;
            }
            if !self.digits_at_least_one() {
                return None;
            }
        }
        // The text is a valid JSON number here, which Rust's parser reads, to Infinity or to zero where it must.
        let value: f64 = self.text[start..self.i].parse().ok()?;
        Some(Value::Number(value))
    }

    fn digits(&mut self) {
        while self.peek().is_some_and(|b| b.is_ascii_digit()) {
            self.i += 1;
        }
    }

    fn digits_at_least_one(&mut self) -> bool {
        let before = self.i;
        self.digits();
        self.i > before
    }

    /// A string literal, with the cursor on the opening quote. It is `Text::Units` only when `exact` and a half has no partner.
    fn string(&mut self) -> Option<Text> {
        self.i += 1;
        let mut out = Text::Chars(String::new());
        loop {
            // Copy the run of plain characters in one go; the quote, the backslash and the control characters end it.
            let run = self.b[self.i..]
                .iter()
                .position(|&b| b == b'"' || b == b'\\' || b < 0x20)?;
            out.push_str(&self.text[self.i..self.i + run]);
            self.i += run;
            match self.next()? {
                b'"' => return Some(out),
                b'\\' => match self.next()? {
                    b'"' => out.push('"'),
                    b'\\' => out.push('\\'),
                    b'/' => out.push('/'),
                    b'b' => out.push('\u{8}'),
                    b'f' => out.push('\u{c}'),
                    b'n' => out.push('\n'),
                    b'r' => out.push('\r'),
                    b't' => out.push('\t'),
                    b'u' => {
                        let at = self.i - 2;
                        let (unit, len) = unicode_escape(self.b, at)?;
                        self.i += len - 2;
                        match unit {
                            Some(c) => out.push(c),
                            None if self.exact => {
                                out.push_lone(u16::try_from(code_unit(self.b, at)?).ok()?);
                            }
                            None => out.push('\u{fffd}'),
                        }
                    }
                    _ => return None,
                },
                _ => return None,
            }
        }
    }
}

/// The backslash-u escape that starts at `at` (the backslash) and the number of bytes it takes: a character, or `None` for a surrogate that stands alone, which `JSON.parse` keeps and `serde_json` refuses. A high surrogate followed by an escaped low one is one character in 12 bytes. `None` when no escape with four hex digits starts there.
pub(crate) fn unicode_escape(bytes: &[u8], at: usize) -> Option<(Option<char>, usize)> {
    let first = code_unit(bytes, at)?;
    if (0xd800..0xdc00).contains(&first)
        && let Some(second) = code_unit(bytes, at + 6).filter(|s| (0xdc00..0xe000).contains(s))
    {
        let pair = 0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00);
        return Some((char::from_u32(pair), 12));
    }
    Some((char::from_u32(first), 6))
}

fn code_unit(bytes: &[u8], at: usize) -> Option<u32> {
    let [b'\\', b'u', digits @ ..] = bytes.get(at..at + 6)? else {
        return None;
    };
    if !digits.iter().all(u8::is_ascii_hexdigit) {
        return None;
    }
    u32::from_str_radix(std::str::from_utf8(digits).ok()?, 16).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok(text: &str) -> Value {
        parse(text).unwrap_or_else(|| panic!("{text:?} should parse"))
    }

    /// `Object.entries(JSON.parse('{"b":1,"2":2,"a":3,"1":4,"b":5}'))` is `[["1",4],["2",2],["b",5],["a",3]]`: indices first and ascending, a repeated key at its first place with its last value.
    #[test]
    fn entries_come_in_the_order_javascript_keeps() {
        let value = ok(r#"{"b":1,"2":2,"a":3,"1":4,"b":5}"#);
        let got: Vec<(&str, f64)> = value
            .entries()
            .unwrap()
            .into_iter()
            .map(|(key, member)| match member {
                Value::Number(n) => (key, *n),
                other => panic!("{other:?}"),
            })
            .collect();
        assert_eq!(got, [("1", 4.0), ("2", 2.0), ("b", 5.0), ("a", 3.0)]);
        assert!(ok("[1]").entries().is_none());
        assert!(ok("null").entries().is_none());
    }

    /// The expected text is what `node -e 'JSON.stringify(...)'` printed for the same string (31.10.2026): a quote, a backslash, `\n`, `\t`, `\b`, `\f`, `\r`, U+001f and U+0000 as lowercase `\u00xx`, DEL, U+2028, U+2029 and a non-ASCII letter raw.
    #[test]
    fn quote_escapes_as_json_stringify_does() {
        let text = "a\"\\\n\t\u{1f}\u{2028}\u{2029}\u{e9}\u{8}\u{c}\r\u{7f}\u{0}";
        assert_eq!(
            quote(text),
            "\"a\\\"\\\\\\n\\t\\u001f\u{2028}\u{2029}\u{e9}\\b\\f\\r\u{7f}\\u0000\""
        );
    }

    /// The expected text is what `node -e 'JSON.stringify("a😀b".slice(0, 2))'` printed (31.10.2026): the high half of the pair as `\ud83d`.
    #[test]
    fn quote_prefix16_writes_the_high_half_of_a_cut_pair_as_an_escape() {
        assert_eq!(quote_prefix16("a😀b", 2), "\"a\\ud83d\"");
        assert_eq!(quote_prefix16("a😀b", 3), "\"a😀\"");
        assert_eq!(quote_prefix16("a\n😀", 2), "\"a\\n\"");
        assert_eq!(quote_prefix16("abc", 10), "\"abc\"");
        assert_eq!(quote_prefix16("😀", 0), "\"\"");
    }

    #[test]
    fn scalars_and_containers() {
        assert_eq!(ok(" null "), Value::Null);
        assert_eq!(ok("true"), Value::Bool(true));
        assert_eq!(ok("\"a\\n\\u00e9\\/\""), Value::String("a\né/".into()));
        assert!(ok("[1, [2], {}]").truthy());
        let doc = ok(r#"{"a":1,"b":{"c":"d"},"a":2}"#);
        assert_eq!(
            doc.get("b")
                .and_then(|b| b.get("c"))
                .and_then(Value::as_str),
            Some("d")
        );
        assert_eq!(doc.get("a"), Some(&Value::Number(2.0)));
    }

    #[test]
    fn a_number_is_the_float_javascript_makes_of_its_text() {
        for (text, want) in [
            ("1", 1.0),
            ("1.0", 1.0),
            ("1e0", 1.0),
            ("10e-1", 1.0),
            ("0.5e1", 5.0),
            ("-2", -2.0),
            ("1e999", f64::INFINITY),
            ("-1e999", f64::NEG_INFINITY),
            ("1e-999", 0.0),
        ] {
            assert_eq!(ok(text), Value::Number(want), "{text}");
        }
        let Value::Number(zero) = ok("-0") else {
            panic!("-0 is a number");
        };
        assert!(zero == 0.0 && zero.is_sign_negative());
    }

    #[test]
    fn javascript_truthiness() {
        for (text, want) in [
            ("0", false),
            ("-0", false),
            ("0.0e5", false),
            ("1e-999", false),
            ("1e999", true),
            ("2", true),
            ("\"\"", false),
            ("\"0\"", true),
            ("null", false),
            ("false", false),
            ("[]", true),
            ("{}", true),
        ] {
            assert_eq!(ok(text).truthy(), want, "{text}");
        }
    }

    #[test]
    fn lone_surrogates_read_as_the_replacement_character() {
        assert_eq!(ok(r#""\ud800""#), Value::String("\u{fffd}".into()));
        assert_eq!(ok(r#""\udc00x""#), Value::String("\u{fffd}x".into()));
        assert_eq!(ok(r#""\ud83d\ude00""#), Value::String("😀".into()));
        assert_eq!(
            ok(r#""\ud83d\ud83d\ude00""#),
            Value::String("\u{fffd}😀".into())
        );
        assert_eq!(ok(r#""\ud83d\u0041""#), Value::String("\u{fffd}A".into()));
        assert_eq!(
            ok(r#""\ude00\ud83d""#),
            Value::String("\u{fffd}\u{fffd}".into())
        );
    }

    #[test]
    fn the_shared_reader_of_backslash_u_escapes() {
        type Read = Option<(Option<char>, usize)>;
        let cases: &[(&[u8], usize, Read)] = &[
            (b"\\ud83d\\ude00", 0, Some((Some('\u{1f600}'), 12))),
            (b"\\ud800x", 0, Some((None, 6))),
            (b"\\udc00", 0, Some((None, 6))),
            (b"\\ud83d\\u0041", 0, Some((None, 6))),
            (b"\\ud83d\\ude", 0, Some((None, 6))),
            (b"\\u00E9", 0, Some((Some('\u{e9}'), 6))),
            (b"x\\u0041", 1, Some((Some('A'), 6))),
            (b"\\u00zz", 0, None),
            (b"\\u004", 0, None),
            (b"\\n\\u0041", 0, None),
            (b"\\\\u0041", 0, None),
        ];
        for (bytes, at, want) in cases {
            assert_eq!(unicode_escape(bytes, *at), *want, "{bytes:?} at {at}");
        }
    }

    #[test]
    fn what_json_parse_refuses() {
        for text in [
            "",
            " ",
            "{",
            "[1,]",
            "{\"a\":1,}",
            "{'a':1}",
            "[01]",
            "[1.]",
            "[.5]",
            "[+1]",
            "[1e]",
            "[--1]",
            "nul",
            "tru e",
            "\"a",
            "\"\\x\"",
            "\"\\u12\"",
            "\"\\u12g4\"",
            "\"a\tb\"",
            "\"a\nb\"",
            "[1] 2",
            "{\"a\" 1}",
            "{1:2}",
            "[1 2]",
            "\u{feff}1",
            "\u{a0}1",
            "NaN",
            "Infinity",
            "[,1]",
        ] {
            assert_eq!(parse(text), None, "{text:?}");
        }
    }

    #[test]
    fn nesting_costs_heap_not_stack() {
        let depth = 200_000;
        let text = format!("{}{}", "[".repeat(depth), "]".repeat(depth));
        let parsed = std::thread::Builder::new()
            .stack_size(512 * 1024)
            .spawn(move || parse(&text).is_some())
            .expect("a thread")
            .join()
            .expect("neither parsing nor dropping overflowed the stack");
        assert!(parsed);
    }

    #[test]
    fn printing_a_deep_value_costs_heap_not_stack() {
        let depth = 200_000;
        let text = format!("{}1{}", "[{\"a\":".repeat(depth), "}]".repeat(depth));
        let same = std::thread::Builder::new()
            .stack_size(512 * 1024)
            .spawn(move || {
                let value = parse_exact(&text).expect("the document").value;
                stringify(&value, false) == text
            })
            .expect("a thread")
            .join()
            .expect("neither printing nor dropping overflowed the stack");
        assert!(same);
    }

    fn exact(text: &str) -> Value {
        parse_exact(text)
            .unwrap_or_else(|| panic!("{text:?} should parse"))
            .value
    }

    #[test]
    fn parse_exact_keeps_a_lone_surrogate_where_parse_reads_u_fffd() {
        assert_eq!(
            parse("\"a\\ud83d\""),
            Some(Value::String("a\u{fffd}".into()))
        );
        assert_eq!(exact("\"a\\ud83d\""), Value::Units(vec![0x61, 0xd83d]));
        assert_eq!(exact("\"\\ude00x\""), Value::Units(vec![0xde00, 0x78]));
        // A pair is its character; a lone half in front of a pair is still a lone half; a low half and then a high one are not a pair.
        assert_eq!(exact("\"\\ud83d\\ude00\""), Value::String("😀".into()));
        assert_eq!(
            exact("\"\\ud83d\\ud83d\\ude00\""),
            Value::Units(vec![0xd83d, 0xd83d, 0xde00])
        );
        assert_eq!(
            exact("\"\\ude00\\ud83d\""),
            Value::Units(vec![0xde00, 0xd83d])
        );
        // The characters before the first lone half are kept as the units they are.
        assert_eq!(
            exact("\"é😀\\ud83d x\""),
            Value::Units(vec![0xe9, 0xd83d, 0xde00, 0xd83d, 0x20, 0x78])
        );
    }

    #[test]
    fn parse_exact_reads_everything_else_as_parse_does() {
        for text in [
            "null",
            "[1,\"a\",null,{\"k\":\"v\\u00e9\\ud83d\\ude00\"},[]]",
            "{\"a\":1,\"b\":{\"c\":\"d\"},\"a\":2}",
            " 1e999 ",
            "\"\\u0000\\n\\/\"",
        ] {
            assert_eq!(Some(exact(text)), parse(text), "{text:?}");
        }
        for text in [
            "",
            "[1,]",
            "\"\\ud83",
            "\"\\ud83d",
            "{\"a\":\"\\ud83d}",
            "[1] 2",
            "NaN",
        ] {
            assert!(parse_exact(text).is_none(), "{text:?}");
            assert!(parse(text).is_none(), "{text:?}");
        }
    }

    #[test]
    fn a_key_with_a_lone_surrogate_is_read_as_u_fffd_and_reported() {
        let lone = parse_exact("{\"\\ud83d\":1,\"b\":2}").unwrap();
        assert!(lone.lone_key);
        assert_eq!(Some(lone.value), parse("{\"\\ud83d\":1,\"b\":2}"));
        let nested = parse_exact("[{\"a\":{\"x\\ude00\":[]}}]").unwrap();
        assert!(nested.lone_key);
        // A lone half in a value is kept, and a key with a pair is not lone.
        let value = parse_exact("{\"\\ud83d\\ude00\":\"\\ud83d\"}").unwrap();
        assert!(!value.lone_key);
        assert_eq!(value.value.get("😀"), Some(&Value::Units(vec![0xd83d])));
        assert!(!parse_exact("[\"\\ud83d\", {\"k\": 1}]").unwrap().lone_key);
    }

    #[test]
    fn units_make_a_string_only_when_they_are_well_formed() {
        assert_eq!(
            Value::from_units(vec![0x61, 0xd83d, 0xde00]),
            Value::String("a😀".into())
        );
        assert_eq!(Value::from_units(vec![]), Value::String(String::new()));
        assert_eq!(
            Value::from_units(vec![0xde00, 0xd83d]),
            Value::Units(vec![0xde00, 0xd83d])
        );
        assert_eq!(
            Value::from_units(vec![0x61, 0xd83d]),
            Value::Units(vec![0x61, 0xd83d])
        );
        assert_eq!(
            Value::String("a😀".into()).units(),
            Some(vec![0x61, 0xd83d, 0xde00])
        );
        assert_eq!(Value::Units(vec![0xd83d]).units(), Some(vec![0xd83d]));
        assert_eq!(Value::Number(1.0).units(), None);
        assert_eq!(Value::Units(vec![0xd83d]).as_str(), None);
        assert!(Value::Units(vec![0xd83d]).truthy());
    }

    #[test]
    fn quote_units_writes_a_lone_half_as_a_lowercase_escape() {
        assert_eq!(quote_units(&[0x61, 0xd83d, 0x22]), "\"a\\ud83d\\\"\"");
        assert_eq!(quote_units(&[0xde00]), "\"\\ude00\"");
        assert_eq!(quote_units(&[0xd83d, 0xde00, 0x0a]), "\"😀\\n\"");
        assert_eq!(quote_units(&[0xde00, 0xd83d, 0xde00]), "\"\\ude00😀\"");
        assert_eq!(quote_units(&[]), "\"\"");
    }

    #[test]
    fn stringify_prints_what_json_stringify_prints() {
        for (document, compact) in [
            ("null", "null"),
            ("true", "true"),
            ("1e21", "1e+21"),
            ("-0", "0"),
            ("1e999", "null"),
            ("-1e999", "null"),
            ("12345678901234567890", "12345678901234567000"),
            ("0.1", "0.1"),
            ("1e-7", "1e-7"),
            ("\"a\\u0000\\u2028é\"", "\"a\\u0000\u{2028}é\""),
            ("\"\\ud83d\"", "\"\\ud83d\""),
            ("[]", "[]"),
            ("{}", "{}"),
            ("[1,[2,[]],{}]", "[1,[2,[]],{}]"),
            // An integer key goes first and in order, the others as they came, and a key written twice keeps its first place and its last value.
            (
                "{\"b\":1,\"2\":2,\"a\":3,\"1\":4}",
                "{\"1\":4,\"2\":2,\"b\":1,\"a\":3}",
            ),
            ("{\"a\":1,\"b\":2,\"a\":3}", "{\"a\":3,\"b\":2}"),
            ("{\"10\":1,\"9\":2,\"1\":3}", "{\"1\":3,\"9\":2,\"10\":1}"),
            (
                "{\"4294967295\":1,\"4294967294\":2,\"01\":3,\"-1\":4,\"0\":5,\"1.5\":6}",
                "{\"0\":5,\"4294967294\":2,\"4294967295\":1,\"01\":3,\"-1\":4,\"1.5\":6}",
            ),
            ("{\"__proto__\":1}", "{\"__proto__\":1}"),
        ] {
            assert_eq!(stringify(&exact(document), false), compact, "{document}");
        }
    }

    #[test]
    fn stringify_indents_by_two_spaces_and_keeps_empty_containers_on_one_line() {
        let value = exact(r#"{"a":[1,{"b":[]}],"c":{},"d":"x"}"#);
        assert_eq!(
            stringify(&value, true),
            "{\n  \"a\": [\n    1,\n    {\n      \"b\": []\n    }\n  ],\n  \"c\": {},\n  \"d\": \"x\"\n}"
        );
        assert_eq!(stringify(&exact("[]"), true), "[]");
        assert_eq!(stringify(&exact("{}"), true), "{}");
        assert_eq!(stringify(&exact("7"), true), "7");
        assert_eq!(
            stringify(&exact("[\"\\ude00\"]"), true),
            "[\n  \"\\ude00\"\n]"
        );
    }

    /// The expected text is what node v22.23.1 printed for `JSON.stringify(JSON.parse(text), null, 2)` (02.11.2026). `pretty` takes any `Serialize` and `stringify` takes what this parser read: they are two ways to write the same text.
    #[test]
    fn pretty_and_stringify_write_what_json_stringify_writes() {
        const TABLE: &[(&str, &str)] = &[
            ("1.0", "1"),
            ("1E2", "100"),
            ("-0", "0"),
            ("0.1", "0.1"),
            ("-1.5e-7", "-1.5e-7"),
            ("1e21", "1e+21"),
            ("1e-7", "1e-7"),
            ("123456789012345678901234567890", "1.2345678901234568e+29"),
            ("9007199254740993", "9007199254740992"),
            ("1.7976931348623157e308", "1.7976931348623157e+308"),
            ("1e999", "null"),
            ("-1e999", "null"),
            (
                "[1.0,[1E2,[-0,{\"a\":0.1}]]]",
                "[\n  1,\n  [\n    100,\n    [\n      0,\n      {\n        \"a\": 0.1\n      }\n    ]\n  ]\n]",
            ),
            (
                "{\"a\":{\"b\":[true,null,[]],\"c\":{}},\"d\":\"e\"}",
                "{\n  \"a\": {\n    \"b\": [\n      true,\n      null,\n      []\n    ],\n    \"c\": {}\n  },\n  \"d\": \"e\"\n}",
            ),
            ("[]", "[]"),
            ("{}", "{}"),
            ("[[]]", "[\n  []\n]"),
            ("[{}]", "[\n  {}\n]"),
            ("{\"a\":[],\"b\":{}}", "{\n  \"a\": [],\n  \"b\": {}\n}"),
            (
                "\"\\\"\\\\\\/\\b\\f\\n\\r\\t\\u0001\\u001f\\u007f\\u2028\\u2029\"",
                "\"\\\"\\\\/\\b\\f\\n\\r\\t\\u0001\\u001f\u{7f}\u{2028}\u{2029}\"",
            ),
            (
                "\"café Привет 日本語 😀 \\ud83d\\ude00 \\u00e9\"",
                "\"café Привет 日本語 😀 😀 é\"",
            ),
            ("{\"k\\n\\\"é😀\":\"v\"}", "{\n  \"k\\n\\\"é😀\": \"v\"\n}"),
            (
                "{\"b\":1,\"2\":2,\"10\":3,\"1\":4,\"01\":5,\"a\":6}",
                "{\n  \"1\": 4,\n  \"2\": 2,\n  \"10\": 3,\n  \"b\": 1,\n  \"01\": 5,\n  \"a\": 6\n}",
            ),
            ("{\"a\":1,\"b\":2,\"a\":3}", "{\n  \"a\": 3,\n  \"b\": 2\n}"),
            (
                "{\"4294967294\":1,\"4294967295\":2,\"3\":3}",
                "{\n  \"3\": 3,\n  \"4294967294\": 1,\n  \"4294967295\": 2\n}",
            ),
        ];
        let mut wrong = Vec::new();
        for (text, want) in TABLE {
            let written = stringify(&ok(text), true);
            let parsed: serde_json::Value = serde_json::from_str(text).unwrap();
            let serialized = pretty(&parsed);
            if written != *want || serialized != *want {
                wrong.push((*text, *want, written, serialized));
            }
        }
        assert!(
            wrong.is_empty(),
            "text, node, stringify, pretty: {wrong:#?}"
        );
    }

    /// What reaches `pretty` as a number of Rust is written as the double JavaScript would hold.
    #[test]
    fn pretty_writes_a_number_of_rust_as_javascript_would() {
        assert_eq!(pretty(&1.0_f64), "1");
        assert_eq!(pretty(&-0.0_f64), "0");
        assert_eq!(pretty(&1e21_f64), "1e+21");
        assert_eq!(pretty(&f64::INFINITY), "null");
        assert_eq!(pretty(&7_u8), "7");
        assert_eq!(pretty(&u64::MAX), "18446744073709552000");
        assert_eq!(pretty(&[1.5_f64]), "[\n  1.5\n]");
    }
}
