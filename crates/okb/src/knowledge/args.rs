//! The check of a call's arguments, in the words the MCP SDK's zod 4 writes them.
//!
//! The schema is the `inputSchema` of one tool in `tools.json`, so the list a client reads and the checks a call meets come from one file. The keywords it uses are the ones zod's JSON Schema output has for a string with a minimum length, an integer that is positive or bounded, and a boolean: `type`, `minLength`, `exclusiveMinimum` and `maximum`. A keyword this file does not handle makes `tests/knowledge_args.rs` fail, since the check would let a bad call through.
//!
//! Which lines come, and in which order, is zod's: the properties in the order the schema has them, and for each the issues of its checks in the order zod runs them. Unknown keys are accepted.

use serde_json::{Map, Value};

use tagents_core::{js, mcp::server::received};

/// The largest integer JavaScript holds exactly, which zod's `int()` takes as the end of its range.
const MAX_SAFE: f64 = 9_007_199_254_740_991.0;

/// The text a failed call answers, one line per issue, or none when the arguments pass.
pub fn refusal(tool: &str, schema: &Value, args: Option<&Map<String, Value>>) -> Option<String> {
    let lines = issues(schema, args);
    (!lines.is_empty()).then(|| {
        format!(
            "MCP error -32602: Input validation error: Invalid arguments for tool {tool}: {}",
            lines.join("\n")
        )
    })
}

/// The issues of the arguments, each as the SDK words it: the message and the property it is about. A call with no arguments object has one issue, about the object itself.
pub fn issues(schema: &Value, args: Option<&Map<String, Value>>) -> Vec<String> {
    let Some(args) = args else {
        return vec!["Invalid input: expected object, received undefined".to_owned()];
    };
    let required: Vec<&str> = schema["required"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    let mut lines = Vec::new();
    for (key, property) in schema["properties"].as_object().into_iter().flatten() {
        let value = args.get(key);
        if value.is_none() && !required.contains(&key.as_str()) {
            continue;
        }
        lines.extend(
            property_issues(property, value)
                .into_iter()
                .map(|message| format!("{message} at {key}")),
        );
    }
    lines
}

fn property_issues(property: &Value, value: Option<&Value>) -> Vec<String> {
    match property["type"].as_str() {
        Some("string") => string_issues(property, value),
        Some("integer") => integer_issues(property, value),
        Some("boolean") => boolean_issues(value),
        _ => Vec::new(),
    }
}

fn wrong_type(expected: &str, value: Option<&Value>) -> String {
    format!(
        "Invalid input: expected {expected}, received {}",
        received(value)
    )
}

fn boolean_issues(value: Option<&Value>) -> Vec<String> {
    match value {
        Some(Value::Bool(_)) => Vec::new(),
        other => vec![wrong_type("boolean", other)],
    }
}

/// A string, and then its minimum length. The minimum is checked for any value that has a `length`, a string that is not one included: zod's check reads `length >= minimum` of whatever it is given, so a list and an object with a `length` get both lines.
fn string_issues(property: &Value, value: Option<&Value>) -> Vec<String> {
    let mut lines = Vec::new();
    if !matches!(value, Some(Value::String(_))) {
        lines.push(wrong_type("string", value));
    }
    if let (Some(minimum), Some(value)) = (property["minLength"].as_f64(), value) {
        let shown = js::number_text(minimum);
        let short = |length: f64| length.is_nan() || length < minimum;
        match value {
            Value::String(text) if short(js::len16(text) as f64) => lines.push(format!(
                "Too small: expected string to have >={shown} characters"
            )),
            Value::Array(items) if short(items.len() as f64) => {
                lines.push(format!("Too small: expected array to have >={shown} items"))
            }
            Value::Object(object)
                if object
                    .get("length")
                    .is_some_and(|length| short(to_number(length))) =>
            {
                lines.push(format!("Too small: expected unknown to be >={shown}"));
            }
            _ => {}
        }
    }
    lines
}

/// `z.number().int()` with the bounds the schema gives. Zod stops at a value that is not finite and at one with a fraction, and goes on past one outside the safe range to the bounds of the schema.
fn integer_issues(property: &Value, value: Option<&Value>) -> Vec<String> {
    let Some(Value::Number(number)) = value else {
        return vec![wrong_type("number", value)];
    };
    // The text of the number is read, not the number: with the text kept, a literal beyond the range of a double is still one, and is infinite as JavaScript reads it.
    let x = js::number(&number.to_string());
    if x.is_infinite() {
        let word = if x > 0.0 { "Infinity" } else { "-Infinity" };
        return vec![format!("Invalid input: expected number, received {word}")];
    }
    if x.fract() != 0.0 {
        return vec!["Invalid input: expected int, received number".to_owned()];
    }
    let mut lines = Vec::new();
    if x > MAX_SAFE {
        lines.push("Too big: expected int to be <=9007199254740991".to_owned());
    } else if x < -MAX_SAFE {
        lines.push("Too small: expected int to be >=-9007199254740991".to_owned());
    }
    if let Some(floor) = property["exclusiveMinimum"].as_f64()
        && (x.is_nan() || x <= floor)
    {
        lines.push(format!(
            "Too small: expected number to be >{}",
            js::number_text(floor)
        ));
    }
    // A maximum at the end of the safe range is the integer's own, which was reported above.
    if let Some(ceiling) = property["maximum"].as_f64()
        && ceiling < MAX_SAFE
        && x > ceiling
    {
        lines.push(format!(
            "Too big: expected number to be <={}",
            js::number_text(ceiling)
        ));
    }
    lines
}

/// `Number(value)` of a value JSON can hold, as the `>=` of the check converts it: a list through its text, an object through "[object Object]".
fn to_number(value: &Value) -> f64 {
    match value {
        Value::Null => 0.0,
        Value::Bool(flag) => f64::from(u8::from(*flag)),
        Value::Number(number) => js::number(&number.to_string()),
        Value::String(text) => js::number(text),
        Value::Array(_) | Value::Object(_) => js::number(&to_text(value)),
    }
}

/// `String(value)`: a list joins its items with commas and an empty text for `null`, an object is `[object Object]`.
fn to_text(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::Bool(flag) => flag.to_string(),
        Value::Number(number) => js::number_text(js::number(&number.to_string())),
        Value::String(text) => text.clone(),
        Value::Array(items) => items.iter().map(to_text).collect::<Vec<_>>().join(","),
        Value::Object(_) => "[object Object]".to_owned(),
    }
}
