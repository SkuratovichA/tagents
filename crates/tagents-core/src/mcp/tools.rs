//! The tool surface, derived: programs of the contract in, tools out. This file is `packages/mcp/src/tools.ts` and knows no verb of the product.
//!
//! A verb added to a spec is a tool the next time the contract is generated, and the same function answers when the server starts, so the list the contract records and the list a client sees cannot be two lists.

use serde_json::{Map, Number, Value, json};
use tagents_spec::{Effect, OptionKind};

use super::contract::{Command, Program};
use super::rpc::ToolEntry;

/// A verb's positional, read from `<x>`, `[x]`, `<x…>` or `[x…]`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Positional {
    pub name: String,
    pub required: bool,
    /// `<words…>`: any number of strings.
    pub words: bool,
}

/// One tool: what a client is told of it, and what a call needs to run it.
#[derive(Clone, Debug)]
pub struct Tool {
    pub name: String,
    pub description: String,
    /// The properties of the input schema, positionals first and then options, each in order.
    pub properties: Map<String, Value>,
    pub required: Vec<String>,
    pub annotations: Value,
    /// The executable the verb belongs to, looked up on `PATH` when the tool is called.
    pub program: String,
    /// The exit codes of that program by name, to say in words how a call ended.
    pub exit: Vec<(String, Number)>,
    pub command: Command,
    pub positionals: Vec<Positional>,
}

impl Tool {
    pub fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": self.properties,
            "required": self.required,
            "additionalProperties": false,
        })
    }

    pub fn entry(&self) -> ToolEntry {
        ToolEntry {
            name: self.name.clone(),
            description: self.description.clone(),
            input_schema: self.input_schema(),
            annotations: self.annotations.clone(),
        }
    }

    /// The code the program's exit table gives `name`, or `fallback` when the table has no such name.
    pub fn code(&self, name: &str, fallback: i64) -> Number {
        self.exit
            .iter()
            .find(|(n, _)| n == name)
            .map_or_else(|| Number::from(fallback), |(_, code)| code.clone())
    }
}

/// The hints an MCP client asks permission by. A verb without an effect gets `readOnlyHint: false` and nothing else, which the protocol reads as "may be destructive, may reach outside": the cautious answer for a verb nobody classified. A verb that serves is never a tool, so it never gets here.
fn annotations(effect: Option<Effect>) -> Value {
    match effect {
        Some(Effect::Read) => json!({"readOnlyHint": true, "openWorldHint": false}),
        Some(Effect::Write) => {
            json!({"readOnlyHint": false, "destructiveHint": false, "openWorldHint": false})
        }
        Some(Effect::Spawn) => {
            json!({"readOnlyHint": false, "destructiveHint": false, "openWorldHint": true})
        }
        Some(Effect::Destructive) => {
            json!({"readOnlyHint": false, "destructiveHint": true, "openWorldHint": false})
        }
        Some(Effect::Serve) | None => json!({"readOnlyHint": false}),
    }
}

/// Every run of characters other than ASCII letters and digits is one `_`.
fn underscored(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c);
        } else if !out.ends_with('_') {
            out.push('_');
        }
    }
    out
}

/// `<query…>` is required words, `[dir]` an optional value; the name is the text inside, in lower case with every run of other characters an underscore.
pub fn parse_positional(text: &str) -> Result<Positional, String> {
    let required_inner = text.strip_prefix('<').and_then(|t| t.strip_suffix('>'));
    let optional_inner = text.strip_prefix('[').and_then(|t| t.strip_suffix(']'));
    let (inner, required) = match (required_inner, optional_inner) {
        (Some(inner), _) => (inner, true),
        (None, Some(inner)) => (inner, false),
        (None, None) => {
            return Err(format!(
                "cannot read the positional {text}: it is neither <required> nor [optional]"
            ));
        }
    };
    let (inner, words) = inner
        .strip_suffix('…')
        .map_or((inner, false), |rest| (rest, true));
    let name = underscored(&inner.to_lowercase())
        .trim_matches('_')
        .to_owned();
    if name.is_empty() {
        return Err(format!("cannot read the positional {text}: it has no name"));
    }
    Ok(Positional {
        name,
        required,
        words,
    })
}

/// `tagents-core` is `core`, so a tool is `core_session_list`; the script `tagents` keeps its name, so its `--new` is `tagents_new`. The program's own name is joined as it is; only the path words are made into names.
pub fn tool_name(program: &str, path: &[String]) -> String {
    let mut parts = vec![
        program
            .strip_prefix("tagents-")
            .unwrap_or(program)
            .to_owned(),
    ];
    parts.extend(
        path.iter()
            .map(|word| underscored(word.trim_start_matches('-'))),
    );
    parts.join("_")
}

fn sentence(summary: &str) -> String {
    let mut chars = summary.chars();
    // `charAt(0).toUpperCase()` works on one UTF-16 unit: a letter outside the Basic Multilingual Plane keeps its case.
    let capital: String = match chars.next() {
        Some(first) if first.len_utf16() == 1 => first.to_uppercase().chain(chars).collect(),
        Some(first) => std::iter::once(first).chain(chars).collect(),
        None => String::new(),
    };
    if capital.ends_with(['.', '!', '?']) {
        capital
    } else {
        format!("{capital}.")
    }
}

fn property(positional: &Positional) -> Value {
    match (positional.words, positional.required) {
        (true, true) => json!({"type": "array", "items": {"type": "string"}, "minItems": 1}),
        (true, false) => json!({"type": "array", "items": {"type": "string"}}),
        (false, _) => json!({"type": "string"}),
    }
}

fn input_schema(
    name: &str,
    command: &Command,
    positionals: &[Positional],
) -> Result<(Map<String, Value>, Vec<String>), String> {
    let mut properties = Map::new();
    for p in positionals {
        properties.insert(p.name.clone(), property(p));
    }
    for (option, shape) in &command.options {
        if properties.contains_key(option) {
            return Err(format!(
                "{name}: the option --{option} and a positional share the name {option}"
            ));
        }
        let value = match (shape.kind, shape.multiple) {
            (OptionKind::Boolean, _) => match command.default_of(option) {
                Some(fallback) => json!({"type": "boolean", "default": fallback}),
                None => json!({"type": "boolean"}),
            },
            (OptionKind::String, true) => json!({"type": "array", "items": {"type": "string"}}),
            (OptionKind::String, false) => json!({"type": "string"}),
        };
        properties.insert(option.clone(), value);
    }
    let required = positionals
        .iter()
        .filter(|p| p.required)
        .map(|p| p.name.clone())
        .chain(command.required.iter().cloned())
        .collect();
    Ok((properties, required))
}

/// A default can only be given to a boolean option the verb has: a spec that says anything else says something the argv cannot carry.
fn check_defaults(name: &str, command: &Command) -> Result<(), String> {
    for (option, _) in &command.tool_defaults {
        match command.option(option) {
            None => {
                return Err(format!(
                    "{name}: toolDefaults names --{option}, which the verb does not have"
                ));
            }
            Some(shape) if shape.kind != OptionKind::Boolean => {
                return Err(format!(
                    "{name}: toolDefaults gives --{option} a boolean, and the option takes a string"
                ));
            }
            Some(_) => {}
        }
    }
    Ok(())
}

/// Whether a verb is offered as a tool: not one that serves until it is stopped, and not one the spec marks `tool: false`.
pub fn is_tool(command: &Command) -> bool {
    command.effect != Some(Effect::Serve) && !command.not_a_tool
}

/// One tool per verb that `is_tool` says yes to. Sorted by name (as JavaScript sorts strings, by UTF-16 code unit), so the order of the programs cannot move the list.
pub fn tool_specs(programs: &[Program]) -> Result<Vec<Tool>, String> {
    let mut tools: Vec<Tool> = Vec::new();
    for program in programs {
        for command in program.commands.iter().filter(|c| is_tool(c)) {
            let name = tool_name(&program.name, &command.path);
            if tools.iter().any(|t| t.name == name) {
                return Err(format!("two verbs would both be the tool {name}"));
            }
            check_defaults(&name, command)?;
            let positionals = command
                .positionals
                .iter()
                .map(|p| parse_positional(p))
                .collect::<Result<Vec<_>, _>>()?;
            let (properties, required) = input_schema(&name, command, &positionals)?;
            tools.push(Tool {
                description: sentence(&command.summary),
                properties,
                required,
                annotations: annotations(command.effect),
                program: program.name.clone(),
                exit: program.exit.clone(),
                command: command.clone(),
                positionals,
                name,
            });
        }
    }
    tools.sort_by(|a, b| a.name.encode_utf16().cmp(b.name.encode_utf16()));
    Ok(tools)
}

/// The strings of a JSON array of strings, or nothing when it is anything else.
fn strings(value: &Value) -> Option<Vec<&str>> {
    value.as_array()?.iter().map(Value::as_str).collect()
}

/// Whether a value is a string with a NUL in it, or an array that has such a string among its items. Arrays are looked into one level, as `[value].flat()` does.
fn has_nul(value: &Value) -> bool {
    match value {
        Value::String(s) => s.contains('\0'),
        Value::Array(items) => items
            .iter()
            .any(|v| matches!(v, Value::String(s) if s.contains('\0'))),
        _ => false,
    }
}

/// The command line a call stands for: the verb's words, each option as `--name=value` (so a value that starts with a dash stays a value), then the positionals. The arguments are checked against the schema first, because nothing else does: the CLI would drop or misread what it does not know.
/// A boolean option the spec defaults (`toolDefaults`) is given as its default when the call leaves it out.
/// A positional that starts with a dash is refused: the verb would read it as a flag, and not every verb takes `--` to end the flags.
/// An argument that is absent is an argument whose key is not there; JSON `null` is a value, of the wrong type.
pub fn argv_for(tool: &Tool, args: &Map<String, Value>) -> Result<Vec<String>, String> {
    if let Some(key) = args.keys().find(|key| !tool.properties.contains_key(*key)) {
        return Err(format!("unknown argument \"{key}\""));
    }
    if let Some(key) = tool.required.iter().find(|key| !args.contains_key(*key)) {
        return Err(format!("missing required argument \"{key}\""));
    }
    // A NUL ends a C string: the operating system refuses to start a program with one in its arguments, and no verb can mean it.
    if let Some((key, _)) = args.iter().find(|(_, value)| has_nul(value)) {
        return Err(format!("argument \"{key}\" contains a NUL byte"));
    }

    let command = &tool.command;
    let mut flags: Vec<String> = Vec::new();
    for (option, shape) in &command.options {
        let given = args.get(option);
        match (shape.kind, shape.multiple) {
            (OptionKind::Boolean, _) => {
                let value = match given {
                    Some(value) => value
                        .as_bool()
                        .ok_or_else(|| format!("argument \"{option}\" must be a boolean"))?,
                    None => match command.default_of(option) {
                        Some(fallback) => fallback,
                        None => continue,
                    },
                };
                if value {
                    flags.push(format!("--{option}"));
                }
            }
            (OptionKind::String, true) => {
                let Some(value) = given else { continue };
                let items = strings(value)
                    .ok_or_else(|| format!("argument \"{option}\" must be an array of strings"))?;
                flags.extend(items.into_iter().map(|item| format!("--{option}={item}")));
            }
            (OptionKind::String, false) => {
                let Some(value) = given else { continue };
                let text = value
                    .as_str()
                    .ok_or_else(|| format!("argument \"{option}\" must be a string"))?;
                flags.push(format!("--{option}={text}"));
            }
        }
    }

    let mut values: Vec<String> = Vec::new();
    let mut skipped: Option<&str> = None;
    for p in &tool.positionals {
        let Some(value) = args.get(&p.name) else {
            skipped.get_or_insert(&p.name);
            continue;
        };
        if let Some(before) = skipped {
            return Err(format!(
                "argument \"{}\" needs \"{before}\" before it",
                p.name
            ));
        }
        let given: Vec<&str> = if p.words {
            strings(value)
                .ok_or_else(|| format!("argument \"{}\" must be an array of strings", p.name))?
        } else {
            vec![
                value
                    .as_str()
                    .ok_or_else(|| format!("argument \"{}\" must be a string", p.name))?,
            ]
        };
        if let Some(flag_like) = given.iter().find(|v| v.starts_with('-')) {
            return Err(format!(
                "argument \"{}\" starts with a dash (\"{flag_like}\"), which the verb would read as a flag",
                p.name
            ));
        }
        values.extend(given.into_iter().map(str::to_owned));
    }

    Ok(command
        .path
        .iter()
        .cloned()
        .chain(flags)
        .chain(values)
        .collect())
}

#[cfg(test)]
mod tests {
    use crate::mcp::contract::OptionShape;

    use super::*;

    fn string_option(multiple: bool) -> OptionShape {
        OptionShape {
            kind: OptionKind::String,
            multiple,
        }
    }

    fn boolean_option() -> OptionShape {
        OptionShape {
            kind: OptionKind::Boolean,
            multiple: false,
        }
    }

    fn command(
        path: &[&str],
        positionals: &[&str],
        options: Vec<(&str, OptionShape)>,
        required: &[&str],
        summary: &str,
        effect: Option<Effect>,
    ) -> Command {
        Command {
            path: path.iter().map(|s| (*s).to_owned()).collect(),
            positionals: positionals.iter().map(|s| (*s).to_owned()).collect(),
            options: options
                .into_iter()
                .map(|(n, s)| (n.to_owned(), s))
                .collect(),
            required: required.iter().map(|s| (*s).to_owned()).collect(),
            summary: summary.to_owned(),
            effect,
            requires_tmux: false,
            not_a_tool: false,
            tool_defaults: vec![],
        }
    }

    fn program(name: &str, exit: &[(&str, i64)], commands: Vec<Command>) -> Program {
        Program {
            name: name.to_owned(),
            exit: exit
                .iter()
                .map(|(n, c)| ((*n).to_owned(), Number::from(*c)))
                .collect(),
            commands,
        }
    }

    fn demo() -> Program {
        program(
            "tagents-demo",
            &[("ok", 0), ("error", 1), ("usage", 2), ("refused", 3)],
            vec![
                command(
                    &["session", "open"],
                    &[],
                    vec![
                        ("cwd", string_option(false)),
                        ("tag", string_option(true)),
                        ("json", boolean_option()),
                    ],
                    &["cwd"],
                    "starts a demo session",
                    Some(Effect::Spawn),
                ),
                command(
                    &["search"],
                    &["<query…>"],
                    vec![("limit", string_option(false))],
                    &[],
                    "finds things.",
                    Some(Effect::Read),
                ),
                command(
                    &["label"],
                    &["<key>", "[name]"],
                    vec![],
                    &[],
                    "names a thing",
                    Some(Effect::Write),
                ),
                command(
                    &["purge"],
                    &[],
                    vec![],
                    &[],
                    "deletes the demo state",
                    Some(Effect::Destructive),
                ),
                command(
                    &["serve"],
                    &[],
                    vec![],
                    &[],
                    "serves until stopped",
                    Some(Effect::Serve),
                ),
                command(
                    &["mystery"],
                    &[],
                    vec![],
                    &[],
                    "does something unclassified",
                    None,
                ),
            ],
        )
    }

    fn bare() -> Program {
        program(
            "tagents",
            &[("ok", 0), ("error", 1)],
            vec![command(
                &["--new"],
                &["[dir]", "[profile]"],
                vec![],
                &[],
                "opens a window",
                Some(Effect::Spawn),
            )],
        )
    }

    fn windowed_command() -> Command {
        let mut window = command(
            &["--window"],
            &["<DIR>", "<COMMAND>"],
            vec![("detach", boolean_option())],
            &[],
            "opens a window",
            Some(Effect::Spawn),
        );
        window.tool_defaults = vec![("detach".to_owned(), true)];
        window
    }

    fn windowed() -> Program {
        let mut prompt = command(
            &["--prompt"],
            &["<text>"],
            vec![],
            &[],
            "runs an unattended turn",
            Some(Effect::Spawn),
        );
        prompt.not_a_tool = true;
        program(
            "tagents",
            &[("ok", 0), ("error", 1), ("usage", 2)],
            vec![windowed_command(), prompt],
        )
    }

    fn tool_of(programs: &[Program], name: &str) -> Tool {
        tool_specs(programs)
            .unwrap()
            .into_iter()
            .find(|t| t.name == name)
            .unwrap_or_else(|| panic!("no tool {name}"))
    }

    fn args(value: Value) -> Map<String, Value> {
        match value {
            Value::Object(map) => map,
            other => panic!("not an object: {other}"),
        }
    }

    fn argv(tool: &Tool, value: Value) -> Result<Vec<String>, String> {
        argv_for(tool, &args(value))
    }

    fn words(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| (*s).to_owned()).collect()
    }

    /// Ported: "a tool per verb, named program short name and verb words, sorted, with serving verbs left out".
    #[test]
    fn a_tool_per_verb_named_program_short_name_and_verb_words_sorted_with_serving_verbs_left_out()
    {
        let names: Vec<String> = tool_specs(&[demo(), bare()])
            .unwrap()
            .into_iter()
            .map(|t| t.name)
            .collect();
        assert_eq!(
            names,
            [
                "demo_label",
                "demo_mystery",
                "demo_purge",
                "demo_search",
                "demo_session_open",
                "tagents_new"
            ]
        );
        for name in &names {
            assert!(
                !name.is_empty()
                    && name.len() <= 64
                    && name
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-'),
                "{name}"
            );
        }
    }

    /// Ported: "two verbs that would get one name are an error at generation, not a silent overwrite".
    #[test]
    fn two_verbs_that_would_get_one_name_are_an_error() {
        let search = demo().commands[1].clone();
        let mut again = search.clone();
        again.summary = "again".into();
        let twin = program("tagents-demo", &[], vec![search, again]);
        assert!(tool_specs(&[twin]).unwrap_err().contains("demo_search"));
    }

    #[test]
    fn two_programs_may_not_make_one_name_either() {
        let a = program(
            "tagents-demo",
            &[],
            vec![command(&["x"], &[], vec![], &[], "s", None)],
        );
        let b = program(
            "tagents-demo",
            &[],
            vec![command(&["x"], &[], vec![], &[], "t", None)],
        );
        assert_eq!(
            tool_specs(&[a, b]).unwrap_err(),
            "two verbs would both be the tool demo_x"
        );
    }

    /// Ported: "options become properties by type, repeatable ones arrays, and the required list is carried over".
    #[test]
    fn options_become_properties_by_type_repeatable_ones_arrays_and_the_required_list_is_carried_over()
     {
        let tool = tool_of(&[demo()], "demo_session_open");
        assert_eq!(
            serde_json::to_string(&tool.input_schema()).unwrap(),
            r#"{"type":"object","properties":{"cwd":{"type":"string"},"tag":{"type":"array","items":{"type":"string"}},"json":{"type":"boolean"}},"required":["cwd"],"additionalProperties":false}"#,
        );
    }

    /// Ported: "positionals become properties: <x> required, [x] optional, a trailing … an array of words". The keys come in this order too: the suite compares lines byte for byte.
    #[test]
    fn positionals_become_properties_required_optional_or_an_array_of_words() {
        assert_eq!(
            serde_json::to_string(&tool_of(&[demo()], "demo_search").input_schema()).unwrap(),
            r#"{"type":"object","properties":{"query":{"type":"array","items":{"type":"string"},"minItems":1},"limit":{"type":"string"}},"required":["query"],"additionalProperties":false}"#,
        );
        assert_eq!(
            serde_json::to_string(&tool_of(&[demo()], "demo_label").input_schema()).unwrap(),
            r#"{"type":"object","properties":{"key":{"type":"string"},"name":{"type":"string"}},"required":["key"],"additionalProperties":false}"#,
        );
    }

    #[test]
    fn positionals_are_read_the_way_the_node_server_reads_them() {
        let read = |text: &str| parse_positional(text).map(|p| (p.name, p.required, p.words));
        assert_eq!(read("<query…>"), Ok(("query".into(), true, true)));
        assert_eq!(read("[dir]"), Ok(("dir".into(), false, false)));
        assert_eq!(read("<Id-Prefix>"), Ok(("id_prefix".into(), true, false)));
        assert_eq!(
            read("[ref-json-or-id…]"),
            Ok(("ref_json_or_id".into(), false, true))
        );
        assert!(
            read("dir")
                .unwrap_err()
                .contains("neither <required> nor [optional]")
        );
        assert!(read("<dir]").unwrap_err().contains("neither"));
        assert!(read("<").unwrap_err().contains("neither"));
        assert!(read("<>").unwrap_err().contains("no name"));
        assert!(read("[…]").unwrap_err().contains("no name"));
        assert!(read("<-->").unwrap_err().contains("no name"));
    }

    #[test]
    fn names_are_made_of_letters_digits_and_single_underscores() {
        let name = |program: &str, path: &[&str]| tool_name(program, &words(path));
        assert_eq!(
            name("tagents-core", &["session", "list"]),
            "core_session_list"
        );
        assert_eq!(name("tagents", &["--new"]), "tagents_new");
        assert_eq!(name("tagents", &["a-b", "c  d"]), "tagents_a_b_c_d");
        assert_eq!(name("tagents", &["-x-"]), "tagents_x_");
        assert_eq!(name("tagents", &["é"]), "tagents__");
        assert_eq!(name("tagents-", &["x"]), "_x");
    }

    /// Ported: "the description is the summary as a sentence".
    #[test]
    fn the_description_is_the_summary_as_a_sentence() {
        assert_eq!(
            tool_of(&[demo()], "demo_session_open").description,
            "Starts a demo session."
        );
        assert_eq!(
            tool_of(&[demo()], "demo_search").description,
            "Finds things."
        );
        assert_eq!(sentence("really?"), "Really?");
        assert_eq!(sentence("wow!"), "Wow!");
        assert_eq!(sentence(""), ".");
        assert_eq!(sentence("ßeta"), "SSeta.");
        assert_eq!(sentence("\u{10428}x"), "\u{10428}x.");
    }

    /// Ported: "the effect of a verb sets the hints a client asks for permission by; a verb without one is not read-only".
    #[test]
    fn the_effect_of_a_verb_sets_the_hints_and_a_verb_without_one_is_not_read_only() {
        let hints = |name: &str| tool_of(&[demo()], name).annotations.to_string();
        assert_eq!(
            hints("demo_search"),
            r#"{"readOnlyHint":true,"openWorldHint":false}"#
        );
        assert_eq!(
            hints("demo_label"),
            r#"{"readOnlyHint":false,"destructiveHint":false,"openWorldHint":false}"#
        );
        assert_eq!(
            hints("demo_session_open"),
            r#"{"readOnlyHint":false,"destructiveHint":false,"openWorldHint":true}"#
        );
        assert_eq!(
            hints("demo_purge"),
            r#"{"readOnlyHint":false,"destructiveHint":true,"openWorldHint":false}"#
        );
        assert_eq!(hints("demo_mystery"), r#"{"readOnlyHint":false}"#);
    }

    /// Ported: "argv is the verb words, the flags in the order of the schema, then the positionals".
    #[test]
    fn argv_is_the_verb_words_the_flags_in_the_order_of_the_schema_then_the_positionals() {
        let open = tool_of(&[demo()], "demo_session_open");
        assert_eq!(
            argv(
                &open,
                json!({"json": true, "cwd": "/work", "tag": ["a", "b"]})
            ),
            Ok(words(&[
                "session",
                "open",
                "--cwd=/work",
                "--tag=a",
                "--tag=b",
                "--json"
            ]))
        );
        assert_eq!(
            argv(&open, json!({"cwd": "/work", "json": false})),
            Ok(words(&["session", "open", "--cwd=/work"]))
        );
        let label = tool_of(&[demo()], "demo_label");
        assert_eq!(
            argv(&label, json!({"key": "k", "name": "n"})),
            Ok(words(&["label", "k", "n"]))
        );
        assert_eq!(
            argv(&label, json!({"key": "k"})),
            Ok(words(&["label", "k"]))
        );
        let search = tool_of(&[demo()], "demo_search");
        assert_eq!(
            argv(&search, json!({"query": ["two", "words"], "limit": "3"})),
            Ok(words(&["search", "--limit=3", "two", "words"]))
        );
    }

    /// Ported: "arguments the schema does not allow are refused with a message, not dropped", with the messages pinned whole.
    #[test]
    fn arguments_the_schema_does_not_allow_are_refused_with_a_message_not_dropped() {
        let open = tool_of(&[demo()], "demo_session_open");
        let message = |value: Value| argv(&open, value).unwrap_err();
        assert_eq!(message(json!({})), r#"missing required argument "cwd""#);
        assert_eq!(
            message(json!({"cwd": "/w", "extra": 1})),
            r#"unknown argument "extra""#
        );
        assert_eq!(
            message(json!({"cwd": 5})),
            r#"argument "cwd" must be a string"#
        );
        assert_eq!(
            message(json!({"cwd": "/w", "json": "yes"})),
            r#"argument "json" must be a boolean"#
        );
        assert_eq!(
            message(json!({"cwd": "/w", "tag": "a"})),
            r#"argument "tag" must be an array of strings"#
        );
        assert_eq!(
            message(json!({"cwd": "/w", "tag": ["a", 1]})),
            r#"argument "tag" must be an array of strings"#
        );
    }

    #[test]
    fn json_null_is_a_value_of_the_wrong_type_and_not_an_absent_argument() {
        let open = tool_of(&[demo()], "demo_session_open");
        assert_eq!(
            argv(&open, json!({"cwd": null})),
            Err(r#"argument "cwd" must be a string"#.into())
        );
        assert_eq!(
            argv(&open, json!({"cwd": "/w", "json": null})),
            Err(r#"argument "json" must be a boolean"#.into())
        );
        assert_eq!(
            argv(&open, json!({"cwd": "/w", "tag": null})),
            Err(r#"argument "tag" must be an array of strings"#.into())
        );
    }

    /// The checks run in the order unknown, missing, NUL, then the options in the contract's order, then the positionals.
    #[test]
    fn the_checks_run_in_the_node_servers_order() {
        let open = tool_of(&[demo()], "demo_session_open");
        assert_eq!(
            argv(&open, json!({"extra": 1})),
            Err(r#"unknown argument "extra""#.into())
        );
        assert_eq!(
            argv(&open, json!({"json": "\u{0}"})),
            Err(r#"missing required argument "cwd""#.into())
        );
        assert_eq!(
            argv(&open, json!({"cwd": 5, "json": "a\u{0}"})),
            Err(r#"argument "json" contains a NUL byte"#.into())
        );
        assert_eq!(
            argv(&open, json!({"json": 1, "cwd": 5})),
            Err(r#"argument "cwd" must be a string"#.into())
        );
    }

    /// Ported: "an optional positional cannot be given after one that was left out".
    #[test]
    fn an_optional_positional_cannot_be_given_after_one_that_was_left_out() {
        let new = tool_of(&[bare()], "tagents_new");
        assert_eq!(
            argv(&new, json!({"dir": "/w", "profile": "work"})),
            Ok(words(&["--new", "/w", "work"]))
        );
        assert_eq!(argv(&new, json!({})), Ok(words(&["--new"])));
        assert_eq!(
            argv(&new, json!({"profile": "work"})),
            Err(r#"argument "profile" needs "dir" before it"#.into())
        );
    }

    /// Ported: "a value that would be read as a flag is refused, because the verb cannot tell it from one".
    #[test]
    fn a_value_that_would_be_read_as_a_flag_is_refused() {
        let search = tool_of(&[demo()], "demo_search");
        assert_eq!(
            argv(&search, json!({"query": ["-rf"]})),
            Err(r#"argument "query" starts with a dash ("-rf"), which the verb would read as a flag"#.into()),
        );
        assert_eq!(
            argv(&search, json!({"query": ["ok"], "limit": "-1"})),
            Ok(words(&["search", "--limit=-1", "ok"]))
        );
        assert_eq!(
            argv(&search, json!({"query": "ok"})),
            Err(r#"argument "query" must be an array of strings"#.into())
        );
        assert_eq!(
            argv(&tool_of(&[demo()], "demo_label"), json!({"key": 1})),
            Err(r#"argument "key" must be a string"#.into())
        );
    }

    /// An empty array of words passes, as it does in the node server, which does not check `minItems`.
    #[test]
    fn required_words_are_not_checked_for_minitems() {
        assert_eq!(
            argv(&tool_of(&[demo()], "demo_search"), json!({"query": []})),
            Ok(words(&["search"]))
        );
    }

    /// Ported: "a verb the spec marks tool: false is no tool".
    #[test]
    fn a_verb_the_spec_marks_tool_false_is_no_tool() {
        let names: Vec<String> = tool_specs(&[windowed()])
            .unwrap()
            .into_iter()
            .map(|t| t.name)
            .collect();
        assert_eq!(names, ["tagents_window"]);
    }

    /// Ported: "a boolean option the spec defaults is in the schema with its default, and the argv carries it unless the call says false".
    #[test]
    fn a_defaulted_boolean_is_in_the_schema_with_its_default_and_in_the_argv_unless_the_call_says_false()
     {
        let window = tool_of(&[windowed()], "tagents_window");
        assert_eq!(
            window.properties["detach"].to_string(),
            r#"{"type":"boolean","default":true}"#
        );
        assert_eq!(
            argv(&window, json!({"dir": "/w", "command": "make"})),
            Ok(words(&["--window", "--detach", "/w", "make"]))
        );
        assert_eq!(
            argv(
                &window,
                json!({"dir": "/w", "command": "make", "detach": true})
            ),
            Ok(words(&["--window", "--detach", "/w", "make"]))
        );
        assert_eq!(
            argv(
                &window,
                json!({"dir": "/w", "command": "make", "detach": false})
            ),
            Ok(words(&["--window", "/w", "make"]))
        );
    }

    /// Ported: "a default for an option the verb does not have, or for one that is not a boolean, stops the tool list from being made".
    #[test]
    fn a_default_for_an_option_the_verb_lacks_or_one_that_is_not_a_boolean_stops_the_list() {
        let mut missing = windowed_command();
        missing.tool_defaults = vec![("attach".into(), true)];
        let err = tool_specs(&[program("tagents", &[], vec![missing])]).unwrap_err();
        assert_eq!(
            err,
            "tagents_window: toolDefaults names --attach, which the verb does not have"
        );
        let mut text = windowed_command();
        text.options = vec![("detach".into(), string_option(false))];
        let err = tool_specs(&[program("tagents", &[], vec![text])]).unwrap_err();
        assert_eq!(
            err,
            "tagents_window: toolDefaults gives --detach a boolean, and the option takes a string"
        );
    }

    #[test]
    fn an_option_and_a_positional_may_not_share_a_name() {
        let clash = command(
            &["x"],
            &["<dir>"],
            vec![("dir", string_option(false))],
            &[],
            "s",
            None,
        );
        assert_eq!(
            tool_specs(&[program("tagents-demo", &[], vec![clash])]).unwrap_err(),
            "demo_x: the option --dir and a positional share the name dir"
        );
    }

    #[test]
    fn a_positional_that_cannot_be_read_stops_the_list() {
        let bad = command(&["x"], &["dir"], vec![], &[], "s", None);
        assert!(
            tool_specs(&[program("tagents-demo", &[], vec![bad])])
                .unwrap_err()
                .contains("cannot read the positional dir")
        );
    }

    /// Ported: "an argument with a NUL byte is refused by name, whether it is an option, a positional or an item of an array".
    #[test]
    fn an_argument_with_a_nul_byte_is_refused_by_name() {
        let open = tool_of(&[demo()], "demo_session_open");
        let search = tool_of(&[demo()], "demo_search");
        assert_eq!(
            argv(&open, json!({"cwd": "/w\u{0}x"})),
            Err(r#"argument "cwd" contains a NUL byte"#.into())
        );
        assert_eq!(
            argv(&open, json!({"cwd": "/w", "tag": ["fine", "a\u{0}"]})),
            Err(r#"argument "tag" contains a NUL byte"#.into())
        );
        assert_eq!(
            argv(&search, json!({"query": ["one", "t\u{0}wo"]})),
            Err(r#"argument "query" contains a NUL byte"#.into())
        );
        assert_eq!(
            argv(&search, json!({"query": ["no nul"]})),
            Ok(words(&["search", "no nul"]))
        );
    }

    #[test]
    fn tools_are_sorted_by_utf16_code_unit() {
        // U+FF5E (one unit, 0xFF5E) sorts after U+1F600 (two units, 0xD83D…) in JavaScript, and before it by scalar value.
        let a = program(
            "\u{ff5e}",
            &[],
            vec![command(&[], &[], vec![], &[], "s", None)],
        );
        let b = program(
            "\u{1f600}",
            &[],
            vec![command(&[], &[], vec![], &[], "s", None)],
        );
        let names: Vec<String> = tool_specs(&[a, b])
            .unwrap()
            .into_iter()
            .map(|t| t.name)
            .collect();
        assert_eq!(names, ["\u{1f600}", "\u{ff5e}"]);
    }

    #[test]
    fn a_code_is_the_tables_or_the_fallback() {
        let tool = tool_of(&[demo()], "demo_search");
        assert_eq!(tool.code("usage", 9), Number::from(2));
        assert_eq!(tool.code("timeout", 4), Number::from(4));
    }
}
