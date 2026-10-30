//! `JSON.parse`, as far as the transcript reader can tell the difference.
//!
//! `serde_json` is the standard parser and differs from V8 in three ways that change which transcript lines are read:
//! it refuses a lone surrogate escape (`"\ud800"`), where V8 keeps it;
//! it refuses a number that overflows a float (`1e999`), where V8 reads Infinity;
//! and it stops at 128 levels of nesting, where V8 goes on until memory runs out.
//! A line one of those fails on is skipped by Rust and read by node, so the two programs would list different prompts.
//! This parser takes exactly the grammar of ECMA-404 and keeps no number but its truthiness, which is all `isMeta` needs.
//! It keeps its own stack of open containers, so nesting costs heap, not call frames.

/// A parsed value. A lone surrogate escape reads as U+FFFD, which is how stdout would write it.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    /// Whether the number is anything but zero: all that JavaScript truthiness asks of one.
    Number(bool),
    String(String),
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

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::String(s) => Some(s),
            _ => None,
        }
    }

    /// JavaScript's `!!value`.
    pub fn truthy(&self) -> bool {
        match self {
            Value::Null => false,
            Value::Bool(b) | Value::Number(b) => *b,
            Value::String(s) => !s.is_empty(),
            Value::Array(_) | Value::Object(_) => true,
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

/// `JSON.parse(text)`, or `None` where it would throw.
pub fn parse(text: &str) -> Option<Value> {
    Parser {
        b: text.as_bytes(),
        text,
        i: 0,
    }
    .document()
}

struct Parser<'a> {
    b: &'a [u8],
    text: &'a str,
    i: usize,
}

impl Parser<'_> {
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
                b'"' => Value::String(self.string()?),
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

    /// `"name" :`, with the cursor on the opening quote.
    fn key(&mut self) -> Option<String> {
        if self.peek()? != b'"' {
            return None;
        }
        let key = self.string()?;
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
        Some(Value::Number(value != 0.0))
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

    /// A string literal, with the cursor on the opening quote.
    fn string(&mut self) -> Option<String> {
        self.i += 1;
        let mut out = String::new();
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
                        let (unit, len) = unicode_escape(self.b, self.i - 2)?;
                        self.i += len - 2;
                        out.push(unit.unwrap_or('\u{fffd}'));
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
        assert_eq!(doc.get("a"), Some(&Value::Number(true)));
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
}
