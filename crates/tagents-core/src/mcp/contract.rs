//! The `cli` section of `contract.json`, read the way `packages/mcp/src/contract-file.ts` reads it.
//!
//! The reader is lenient on purpose: a plugin updated ahead of this binary may hold keys and effects it has not heard of, and neither may take every tool away. Unknown keys are ignored and an unknown `effect` is dropped, which leaves the verb unclassified. `tagents-spec` reads `spec/cli/tagents-core.json` strictly, because an unknown key there is a typo; the vocabulary (`Effect`, `OptionKind`) is shared, and a test compares what the two readers make of the `tagents-core` program.
//!
//! Programs, exit tables, commands and options keep the order of the file: `properties` come out in it, and the first name of an exit table that carries a code is the one told.

use serde_json::{Map, Number, Value};
use tagents_spec::{Effect, OptionKind};

/// One program of the contract: `tagents-core`, or `tagents`, with its exit table and its verbs.
#[derive(Clone, Debug, PartialEq)]
pub struct Program {
    pub name: String,
    /// Exit code by name, in the file's order. A value is a number as written; JavaScript reads it as a double.
    pub exit: Vec<(String, Number)>,
    pub commands: Vec<Command>,
}

impl Program {
    pub fn exit_code(&self, name: &str) -> Option<&Number> {
        self.exit
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, code)| code)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Command {
    pub path: Vec<String>,
    pub positionals: Vec<String>,
    /// In the file's order.
    pub options: Vec<(String, OptionShape)>,
    pub required: Vec<String>,
    pub summary: String,
    pub effect: Option<Effect>,
    /// `"requires": "tmux"`: the verb opens a window in a tmux server of its own.
    pub requires_tmux: bool,
    /// `"tool": false`: the verb is not offered as a tool.
    pub not_a_tool: bool,
    /// Booleans a call that leaves them out gets, in the file's order.
    pub tool_defaults: Vec<(String, bool)>,
}

impl Command {
    pub fn option(&self, name: &str) -> Option<&OptionShape> {
        self.options
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, shape)| shape)
    }

    pub fn default_of(&self, name: &str) -> Option<bool> {
        self.tool_defaults
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, value)| *value)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OptionShape {
    pub kind: OptionKind,
    pub multiple: bool,
}

/// The programs of `contract.json`'s `cli` section in the file's order, or why the text is not one.
pub fn parse(text: &str) -> Result<Vec<Program>, String> {
    let json: Value =
        serde_json::from_str(text).map_err(|e| format!("the contract is not JSON: {e}"))?;
    programs(&json).map_err(|reason| format!("the contract has no usable cli section: {reason}"))
}

/// A reason that already names where it was found.
type Read<T> = Result<T, String>;

fn programs(json: &Value) -> Read<Vec<Program>> {
    let top = object(json, "")?;
    let cli = object(member(top, "cli", "")?, "cli")?;
    cli.iter()
        .map(|(name, body)| {
            let at = format!("cli.{name}");
            let body = object(body, &at)?;
            let exit = object(member(body, "exit", &at)?, &format!("{at}.exit"))?
                .iter()
                .map(|(code_name, code)| {
                    number(code, &format!("{at}.exit.{code_name}")).map(|n| (code_name.clone(), n))
                })
                .collect::<Read<_>>()?;
            let commands = array(member(body, "commands", &at)?, &format!("{at}.commands"))?
                .iter()
                .enumerate()
                .map(|(i, command)| self::command(command, &format!("{at}.commands.{i}")))
                .collect::<Read<_>>()?;
            Ok(Program {
                name: name.clone(),
                exit,
                commands,
            })
        })
        .collect()
}

fn command(json: &Value, at: &str) -> Read<Command> {
    let fields = object(json, at)?;
    let child = |key: &str| format!("{at}.{key}");
    let strings = |key: &str| string_list(member(fields, key, at)?, &child(key));
    let options = object(member(fields, "options", at)?, &child("options"))?
        .iter()
        .map(|(name, shape)| {
            option(shape, &format!("{}.{name}", child("options"))).map(|s| (name.clone(), s))
        })
        .collect::<Read<_>>()?;
    let effect = match fields.get("effect") {
        None => None,
        // A name this binary does not know is not an error: the verb stays, unclassified.
        Some(value) => {
            serde_json::from_value::<Effect>(Value::String(string(value, &child("effect"))?)).ok()
        }
    };
    let requires_tmux = match fields.get("requires") {
        None => false,
        Some(Value::String(s)) if s == "tmux" => true,
        Some(_) => return Err(format!("{}: expected \"tmux\"", child("requires"))),
    };
    let not_a_tool = match fields.get("tool") {
        None => false,
        Some(Value::Bool(false)) => true,
        Some(_) => return Err(format!("{}: expected false", child("tool"))),
    };
    let tool_defaults = match fields.get("toolDefaults") {
        None => Vec::new(),
        Some(defaults) => object(defaults, &child("toolDefaults"))?
            .iter()
            .map(|(name, value)| match value {
                Value::Bool(b) => Ok((name.clone(), *b)),
                _ => Err(format!(
                    "{}.{name}: expected true or false",
                    child("toolDefaults")
                )),
            })
            .collect::<Read<_>>()?,
    };
    Ok(Command {
        path: strings("path")?,
        positionals: strings("positionals")?,
        options,
        required: strings("required")?,
        summary: string(member(fields, "summary", at)?, &child("summary"))?,
        effect,
        requires_tmux,
        not_a_tool,
        tool_defaults,
    })
}

fn option(json: &Value, at: &str) -> Read<OptionShape> {
    let fields = object(json, at)?;
    let kind = member(fields, "type", at)?;
    let kind = serde_json::from_value::<OptionKind>(kind.clone())
        .map_err(|_| format!("{at}.type: expected \"string\" or \"boolean\""))?;
    let multiple = match fields.get("multiple") {
        None => false,
        Some(Value::Bool(b)) => *b,
        Some(_) => return Err(format!("{at}.multiple: expected true or false")),
    };
    Ok(OptionShape { kind, multiple })
}

fn member<'a>(fields: &'a Map<String, Value>, key: &str, at: &str) -> Read<&'a Value> {
    fields
        .get(key)
        .ok_or_else(|| format!("{}: required", path(at, key)))
}

fn path(at: &str, key: &str) -> String {
    if at.is_empty() {
        key.to_owned()
    } else {
        format!("{at}.{key}")
    }
}

fn object<'a>(json: &'a Value, at: &str) -> Read<&'a Map<String, Value>> {
    json.as_object().ok_or_else(|| {
        format!(
            "{}: expected an object",
            if at.is_empty() { "(top level)" } else { at }
        )
    })
}

fn array<'a>(json: &'a Value, at: &str) -> Read<&'a Vec<Value>> {
    json.as_array()
        .ok_or_else(|| format!("{at}: expected an array"))
}

fn string(json: &Value, at: &str) -> Read<String> {
    json.as_str()
        .map(str::to_owned)
        .ok_or_else(|| format!("{at}: expected a string"))
}

fn string_list(json: &Value, at: &str) -> Read<Vec<String>> {
    array(json, at)?
        .iter()
        .enumerate()
        .map(|(i, item)| string(item, &format!("{at}.{i}")))
        .collect()
}

/// A number JavaScript can hold: `1e999` reads as Infinity there, which `z.number()` refuses.
fn number(json: &Value, at: &str) -> Read<Number> {
    match json {
        Value::Number(n) if n.as_f64().is_some_and(f64::is_finite) => Ok(n.clone()),
        _ => Err(format!("{at}: expected a number")),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn demo() -> Program {
        Program {
            name: "tagents-demo".into(),
            exit: vec![
                ("ok".into(), 0.into()),
                ("error".into(), 1.into()),
                ("refused".into(), 3.into()),
            ],
            commands: vec![
                Command {
                    path: vec!["open".into()],
                    positionals: vec!["<dir>".into()],
                    options: vec![
                        (
                            "tag".into(),
                            OptionShape {
                                kind: OptionKind::String,
                                multiple: true,
                            },
                        ),
                        (
                            "json".into(),
                            OptionShape {
                                kind: OptionKind::Boolean,
                                multiple: false,
                            },
                        ),
                    ],
                    required: vec![],
                    summary: "opens".into(),
                    effect: Some(Effect::Spawn),
                    requires_tmux: true,
                    not_a_tool: false,
                    tool_defaults: vec![],
                },
                Command {
                    path: vec!["plain".into()],
                    positionals: vec![],
                    options: vec![],
                    required: vec![],
                    summary: "has no effect and no requirement".into(),
                    effect: None,
                    requires_tmux: false,
                    not_a_tool: false,
                    tool_defaults: vec![],
                },
                Command {
                    path: vec!["quiet".into()],
                    positionals: vec![],
                    options: vec![(
                        "detach".into(),
                        OptionShape {
                            kind: OptionKind::Boolean,
                            multiple: false,
                        },
                    )],
                    required: vec![],
                    summary: "is no tool and defaults a flag".into(),
                    effect: Some(Effect::Read),
                    requires_tmux: false,
                    not_a_tool: true,
                    tool_defaults: vec![("detach".into(), true)],
                },
            ],
        }
    }

    /// Ported from `contract-file.test.ts`: "contract.json is read back into the CLI contracts it was written from".
    #[test]
    fn contract_json_is_read_back_into_the_programs_it_was_written_from() {
        let text = json!({
            "contractVersion": 1,
            "cli": { "tagents-demo": {
                "exit": { "ok": 0, "error": 1, "refused": 3 },
                "commands": [
                    { "path": ["open"], "positionals": ["<dir>"], "options": { "tag": { "type": "string", "multiple": true }, "json": { "type": "boolean" } }, "required": [], "summary": "opens", "effect": "spawn", "requires": "tmux" },
                    { "path": ["plain"], "positionals": [], "options": {}, "required": [], "summary": "has no effect and no requirement" },
                    { "path": ["quiet"], "positionals": [], "options": { "detach": { "type": "boolean" } }, "required": [], "summary": "is no tool and defaults a flag", "effect": "read", "tool": false, "toolDefaults": { "detach": true } },
                ],
            } },
            "mcp": {},
            "api": {},
        })
        .to_string();
        assert_eq!(parse(&text), Ok(vec![demo()]));
    }

    #[test]
    fn a_file_that_is_not_json_or_has_no_cli_section_is_an_error_that_says_so() {
        assert!(parse("{").unwrap_err().contains("JSON"));
        assert!(
            parse(r#"{"contractVersion":1}"#)
                .unwrap_err()
                .contains("cli")
        );
        assert!(
            parse("[]")
                .unwrap_err()
                .contains("(top level): expected an object")
        );
    }

    /// Ported: a contract from a newer generator, with an effect this server does not know and a key it has not heard of, still yields the verb, unclassified.
    #[test]
    fn a_newer_generators_effect_and_keys_leave_an_unclassified_verb() {
        let newer = r#"{"contractVersion":2,"cli":{"tagents-demo":{"exit":{"ok":0},"commands":[
            {"path":["x"],"positionals":[],"options":{},"required":[],"summary":"s","effect":"teleport","futureKey":{"any":"shape"}}]}}}"#;
        let programs = parse(newer).unwrap();
        let command = &programs[0].commands[0];
        assert_eq!(command.effect, None);
        assert_eq!(
            (command.path.clone(), command.summary.as_str()),
            (vec!["x".to_owned()], "s")
        );
    }

    #[test]
    fn programs_exit_tables_and_options_keep_the_files_order() {
        let text = r#"{"cli":{"z":{"exit":{"b":2,"a":2},"commands":[{"path":["x"],"positionals":[],"options":{"zz":{"type":"string"},"aa":{"type":"boolean"}},"required":[],"summary":"s"}]},"a":{"exit":{},"commands":[]}}}"#;
        let programs = parse(text).unwrap();
        assert_eq!(
            programs.iter().map(|p| p.name.as_str()).collect::<Vec<_>>(),
            ["z", "a"]
        );
        assert_eq!(
            programs[0]
                .exit
                .iter()
                .map(|(n, _)| n.as_str())
                .collect::<Vec<_>>(),
            ["b", "a"]
        );
        assert_eq!(
            programs[0].commands[0]
                .options
                .iter()
                .map(|(n, _)| n.as_str())
                .collect::<Vec<_>>(),
            ["zz", "aa"]
        );
    }

    #[test]
    fn a_shape_the_generator_does_not_write_stops_the_server_with_the_reason() {
        let command = |extra: &str| {
            format!(
                r#"{{"cli":{{"p":{{"exit":{{}},"commands":[{{"path":[],"positionals":[],"options":{{}},"required":[],"summary":"s"{extra}}}]}}}}}}"#
            )
        };
        for (extra, reason) in [
            (
                r#","requires":"screen""#,
                "cli.p.commands.0.requires: expected \"tmux\"",
            ),
            (r#","tool":true"#, "cli.p.commands.0.tool: expected false"),
            (
                r#","effect":5"#,
                "cli.p.commands.0.effect: expected a string",
            ),
            (
                r#","toolDefaults":{"a":"yes"}"#,
                "cli.p.commands.0.toolDefaults.a: expected true or false",
            ),
            (
                r#","summary":3"#,
                "cli.p.commands.0.summary: expected a string",
            ),
        ] {
            assert!(
                parse(&command(extra)).unwrap_err().ends_with(reason),
                "{extra}"
            );
        }
        for (text, reason) in [
            (
                r#"{"cli":{"p":{"exit":{"ok":"0"},"commands":[]}}}"#,
                "cli.p.exit.ok: expected a number",
            ),
            (
                r#"{"cli":{"p":{"exit":{},"commands":[{"path":["x"],"positionals":[],"options":{"o":{"type":"number"}},"required":[],"summary":"s"}]}}}"#,
                "cli.p.commands.0.options.o.type: expected \"string\" or \"boolean\"",
            ),
            (
                r#"{"cli":{"p":{"exit":{},"commands":[{"path":["x"],"positionals":[],"options":{"o":{"type":"string","multiple":1}},"required":[],"summary":"s"}]}}}"#,
                "cli.p.commands.0.options.o.multiple: expected true or false",
            ),
            (r#"{"cli":{"p":{"commands":[]}}}"#, "cli.p.exit: required"),
            (
                r#"{"cli":{"p":{"exit":{},"commands":[{"positionals":[],"options":{},"required":[],"summary":"s"}]}}}"#,
                "cli.p.commands.0.path: required",
            ),
        ] {
            assert!(parse(text).unwrap_err().ends_with(reason), "{text}");
        }
    }

    #[test]
    fn a_number_javascript_reads_as_infinity_is_not_an_exit_code() {
        assert!(parse(r#"{"cli":{"p":{"exit":{"ok":1e999},"commands":[]}}}"#).is_err());
    }
}
