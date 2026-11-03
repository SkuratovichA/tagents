//! The check of a call's arguments against what the node server says: every refusal the MCP SDK's zod 4 wrote for the arguments of the six tools, in its words and in its order.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use serde_json::{Map, Value};
use tagents_core::knowledge::{args::refusal, tools::listing};

use common::knowledge::vectors;

/// The words every refusal starts with, before the tool's name.
const REFUSAL: &str = "MCP error -32602: Input validation error: Invalid arguments for tool ";

fn schema_of(tool: &str) -> &'static Value {
    listing()
        .iter()
        .find(|entry| entry["name"] == tool)
        .map(|entry| &entry["inputSchema"])
        .unwrap_or_else(|| panic!("no tool {tool}"))
}

fn refused(tool: &str, arguments: &str) -> Option<String> {
    let args: Value = serde_json::from_str(arguments).unwrap();
    refusal(tool, schema_of(tool), Some(args.as_object().unwrap()))
}

#[test]
fn every_refusal_and_every_pass_of_the_node_server_is_the_same() {
    let sdk = vectors()["process"]["sdk"].as_array().unwrap();
    let (mut replayed, mut refusals) = (0, 0);
    for entry in sdk {
        let Some(params) = entry["params"].as_object() else {
            continue;
        };
        let Some(tool) = params.get("name").and_then(Value::as_str) else {
            continue;
        };
        if !listing().iter().any(|listed| listed["name"] == tool) {
            continue;
        }
        // An arguments value that is not an object is refused by the loop before a tool is asked.
        let args = match params.get("arguments") {
            None => None,
            Some(Value::Object(args)) => Some(args),
            Some(_) => continue,
        };
        let text = entry["response"]["result"]["content"][0]["text"]
            .as_str()
            .unwrap();
        let want = text.starts_with(REFUSAL).then_some(text);
        let got = refusal(tool, schema_of(tool), args);
        assert_eq!(want, got.as_deref(), "{}", entry["name"]);
        replayed += 1;
        refusals += usize::from(want.is_some());
    }
    // A replay that skipped its entries proves nothing.
    assert!(
        replayed >= 100 && refusals >= 90,
        "replayed {replayed} calls, {refusals} of them refused"
    );
}

#[test]
fn a_call_without_an_arguments_object_is_refused_without_a_place() {
    for entry in listing() {
        let tool = entry["name"].as_str().unwrap();
        assert_eq!(
            Some(format!(
                "{REFUSAL}{tool}: Invalid input: expected object, received undefined"
            )),
            refusal(tool, &entry["inputSchema"], None),
            "{tool}"
        );
    }
}

#[test]
fn a_key_the_schema_does_not_name_is_accepted() {
    assert_eq!(
        None,
        refused("knowledge_search", r#"{"query":"x","extra":{"a":[1]}}"#)
    );
}

/// What the SDK says of a number JavaScript reads as infinite, which JSON text spells `1e999`: zod 4 names the value and not its type. Probed with `z.number().int().positive().max(50).safeParse(Infinity)` on zod 4.6.2, which the vectors cannot carry because their text writes it as null.
#[test]
fn an_infinite_number_is_named_as_such() {
    let line = |tool: &str, key: &str, number: &str, word: &str| {
        let arguments = if tool == "knowledge_search" {
            format!(r#"{{"query":"x","{key}":{number}}}"#)
        } else {
            format!(r#"{{"{key}":{number}}}"#)
        };
        assert_eq!(
            Some(format!(
                "{REFUSAL}{tool}: Invalid input: expected number, received {word} at {key}"
            )),
            refused(tool, &arguments),
            "{tool} {key} {number}"
        );
    };
    line("knowledge_search", "limit", "1e999", "Infinity");
    line("knowledge_search", "limit", "-1e999", "-Infinity");
    line("knowledge_usage", "top", "1e999", "Infinity");
    line("knowledge_usage", "min_days", "-1e999", "-Infinity");
    line("sessions_recent", "limit", "1e999", "Infinity");
}

/// The minimum of a string reads `length` of whatever it is given, as `length >= 1` does in JavaScript: an object with a `length` that converts to a number of 1 or more passes it, and a list counts its items. The cases are the ones the vectors hold, pinned here as the rule they follow.
#[test]
fn the_minimum_of_a_string_is_the_comparison_javascript_makes() {
    let small = |length: &str| {
        refused(
            "knowledge_get",
            &format!(r#"{{"id":{{"length":{length}}}}}"#),
        )
        .unwrap()
        .contains("Too small: expected unknown to be >=1 at id")
    };
    for passes in [
        "3",
        "1",
        "1.5",
        r#""2""#,
        r#"" 2 ""#,
        r#""0x10""#,
        r#""1e0""#,
        "true",
        "[3]",
    ] {
        assert!(!small(passes), "length {passes}");
    }
    // A list is converted through its text, so `[1,2]` is "1,2", which is no number.
    for fails in [
        "0", "-1", "null", "false", "[]", "[1,2]", "{}", r#""""#, r#""abc""#, r#""٣""#,
    ] {
        assert!(small(fails), "length {fails}");
    }
}

/// The checker handles the keywords the list has and no others: a keyword added to the list that nothing checks would let a bad call through, so this fails first.
#[test]
fn the_checks_cover_every_keyword_of_the_list() {
    assert_eq!(6, listing().len());
    for entry in listing() {
        let tool = entry["name"].as_str().unwrap();
        let schema = entry["inputSchema"].as_object().unwrap();
        for key in schema.keys() {
            assert!(
                ["$schema", "type", "properties", "required"].contains(&key.as_str()),
                "{tool}: the schema has {key}"
            );
        }
        assert_eq!("object", schema["type"], "{tool}");
        for (name, property) in schema["properties"].as_object().unwrap() {
            let kind = property["type"].as_str().unwrap();
            for key in property.as_object().unwrap().keys() {
                let known = match key.as_str() {
                    "type" | "description" => true,
                    "minLength" => kind == "string",
                    "exclusiveMinimum" | "maximum" => kind == "integer",
                    _ => false,
                };
                assert!(known, "{tool}.{name}: {kind} has {key}");
            }
            assert!(
                ["string", "integer", "boolean"].contains(&kind),
                "{tool}.{name}: {kind}"
            );
        }
    }
}

#[test]
fn what_a_refusal_lists_is_in_the_order_of_the_properties() {
    let args: Map<String, Value> =
        serde_json::from_str(r#"{"limit":0,"kind":1,"query":"","tag":2}"#).unwrap();
    let got = refusal(
        "knowledge_search",
        schema_of("knowledge_search"),
        Some(&args),
    )
    .unwrap();
    let lines: Vec<&str> = got.split('\n').collect();
    assert_eq!(
        vec![
            "MCP error -32602: Input validation error: Invalid arguments for tool knowledge_search: Too small: expected string to have >=1 characters at query",
            "Invalid input: expected string, received number at tag",
            "Invalid input: expected string, received number at kind",
            "Too small: expected number to be >0 at limit",
        ],
        lines
    );
}
