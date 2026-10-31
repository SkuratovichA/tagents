//! The language-neutral `tagents-core` CLI spec: the model and the loader.
//!
//! The data is `spec/cli/tagents-core.json` at the repository root, described by `spec/cli/cli-spec.schema.json`.
//! The node CLI and the contract generator read the same file (`packages/core/src/cli/spec.ts`).
//! The model refuses a key the schema does not name and the structural mistakes the schema forbids (an empty program, summary, path or word, a `null` where the schema says string or boolean), and adds the one rule a schema cannot state, that two verbs never share a path, so a newer or wrong file fails here at load, not somewhere downstream.
//! This loader is the stricter one: no input is known that it loads and the node loader refuses. It refuses three inputs the node loader accepts: an `exit` value written `1.0` (the number 1 to JavaScript, a non-integer here because the model holds it as a `u8`), a key written twice in one object (`JSON.parse` keeps the last), and a lone surrogate escape in a string (`JSON.parse` accepts it).

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Deserializer, Serialize, Serializer, de::Error as _};

/// The spec this crate was built with: the data file, embedded.
pub const BUNDLED: &str = include_str!("../../../spec/cli/tagents-core.json");

/// Reads an optional field that may be absent but not `null`: the schema says `string` or `boolean`, and serde would otherwise read `null` as absent. A missing key still gives `None` through `default`.
fn not_null<'de, D, T>(d: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    T::deserialize(d).map(Some)
}

/// A CLI's whole surface.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Spec {
    #[serde(
        rename = "$schema",
        default,
        deserialize_with = "not_null",
        skip_serializing_if = "Option::is_none"
    )]
    pub schema: Option<String>,
    pub program: String,
    /// Exit code names to numbers.
    pub exit: BTreeMap<String, u8>,
    pub commands: Vec<Command>,
}

/// One verb.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Command {
    /// The words after the program name that select the verb.
    pub path: Vec<String>,
    /// Positionals as the usage text prints them.
    pub positionals: Vec<String>,
    /// Option name without the dashes to its kind.
    pub options: BTreeMap<String, OptionSpec>,
    /// Option names the verb refuses to run without.
    pub required: Vec<String>,
    /// i18n key of the one-line summary. The text lives in the language catalogue.
    pub summary: String,
    /// Which program serves the verb.
    #[serde(rename = "impl")]
    pub implementation: Implementation,
    /// What running the verb does, for whoever decides whether to let it run. The contract generator reads it; nothing here acts on it.
    #[serde(
        default,
        deserialize_with = "not_null",
        skip_serializing_if = "Option::is_none"
    )]
    pub effect: Option<Effect>,
    /// `false` keeps the verb out of the plugin's tools. Absent means the verb is a tool. The contract generator reads it; nothing here acts on it.
    #[serde(
        default,
        deserialize_with = "not_null",
        skip_serializing_if = "Option::is_none"
    )]
    pub tool: Option<NotATool>,
}

/// One option of a verb.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OptionSpec {
    #[serde(rename = "type")]
    pub kind: OptionKind,
    #[serde(
        default,
        deserialize_with = "not_null",
        skip_serializing_if = "Option::is_none"
    )]
    pub multiple: Option<bool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OptionKind {
    String,
    Boolean,
}

/// Which program serves a verb: the Rust front door or the node CLI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Implementation {
    Rust,
    Node,
}

/// What running a verb does: `read` changes nothing, `write` changes files, settings or what is on the screen, `spawn` starts a program or a window that does things of its own, `destructive` removes or stops something that cannot be got back, and `serve` runs until it is stopped.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Effect {
    Read,
    Write,
    Spawn,
    Destructive,
    Serve,
}

/// The one value `tool` may have in the data file, written `false`: the verb is not a tool. A verb that is a tool leaves the key out, so `true` has no meaning and is refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NotATool;

impl Serialize for NotATool {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_bool(false)
    }
}

impl<'de> Deserialize<'de> for NotATool {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        if bool::deserialize(deserializer)? {
            return Err(D::Error::custom(
                "`tool` can only be false: a verb that is a tool leaves the key out",
            ));
        }
        Ok(Self)
    }
}

impl Spec {
    /// Parse a spec document, refusing what `spec/cli/cli-spec.schema.json` refuses and a path two verbs share (dispatch is by path, so the second would never run).
    pub fn parse(text: &str) -> Result<Self, serde_json::Error> {
        let spec: Self = serde_json::from_str(text)?;
        spec.check().map_err(serde_json::Error::custom)?;
        Ok(spec)
    }

    fn check(&self) -> Result<(), String> {
        if self.program.is_empty() {
            return Err("the program name is empty".into());
        }
        let mut seen = BTreeSet::new();
        for command in &self.commands {
            let at = command.path.join(" ");
            if command.path.is_empty() || command.path.iter().any(String::is_empty) {
                return Err(format!(
                    "a verb has an empty path or an empty word in it ({at:?})"
                ));
            }
            if command.summary.is_empty() {
                return Err(format!("{at}: an empty summary"));
            }
            if command.positionals.iter().any(String::is_empty) {
                return Err(format!("{at}: an empty entry in positionals"));
            }
            if command.required.iter().any(String::is_empty) {
                return Err(format!("{at}: an empty entry in required"));
            }
            if !seen.insert(&command.path) {
                return Err(format!("the path {at:?} appears twice"));
            }
        }
        Ok(())
    }

    /// The spec this crate was built with.
    pub fn bundled() -> Result<Self, serde_json::Error> {
        Self::parse(BUNDLED)
    }

    /// The verbs `who` serves, in file order.
    pub fn served_by(&self, who: Implementation) -> impl Iterator<Item = &Command> {
        self.commands
            .iter()
            .filter(move |c| c.implementation == who)
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use serde_json::Value;

    use super::*;

    const SCHEMA: &str = include_str!("../../../spec/cli/cli-spec.schema.json");

    fn object(value: &Value) -> &serde_json::Map<String, Value> {
        value.as_object().expect("a JSON object")
    }

    fn names(map: &serde_json::Map<String, Value>) -> BTreeSet<String> {
        map.keys().cloned().collect()
    }

    fn required(schema: &Value) -> BTreeSet<String> {
        schema["required"]
            .as_array()
            .expect("a required list")
            .iter()
            .map(|v| v.as_str().expect("a name").to_owned())
            .collect()
    }

    fn command(effect: Option<Effect>, tool: Option<NotATool>) -> Command {
        Command {
            path: vec!["x".into()],
            positionals: vec![],
            options: BTreeMap::from([(
                "o".into(),
                OptionSpec {
                    kind: OptionKind::String,
                    multiple: Some(true),
                },
            )]),
            required: vec![],
            summary: "summaryX".into(),
            implementation: Implementation::Rust,
            effect,
            tool,
        }
    }

    /// A spec document with the given verbs, each a JSON object body after `"options":{},"summary":"k","impl":"node"`.
    fn spec_with(commands: &[&str]) -> String {
        format!(
            r#"{{"program":"p","exit":{{}},"commands":[{}]}}"#,
            commands.join(",")
        )
    }

    fn verb(path: &str, positionals: &str, required: &str) -> String {
        format!(
            r#"{{"path":{path},"positionals":{positionals},"options":{{}},"required":{required},"summary":"k","impl":"node"}}"#
        )
    }

    fn refused(path: &str, positionals: &str, required: &str) -> String {
        Spec::parse(&spec_with(&[&verb(path, positionals, required)]))
            .expect_err("the spec is refused")
            .to_string()
    }

    #[test]
    fn a_verb_without_words_is_refused() {
        assert!(refused("[]", "[]", "[]").contains("path"));
    }

    #[test]
    fn an_empty_word_in_a_path_is_refused() {
        assert!(refused(r#"["a",""]"#, "[]", "[]").contains("path"));
    }

    #[test]
    fn an_empty_positional_is_refused() {
        assert!(refused(r#"["a"]"#, r#"[""]"#, "[]").contains("positionals"));
    }

    #[test]
    fn an_empty_required_option_is_refused() {
        assert!(refused(r#"["a"]"#, "[]", r#"[""]"#).contains("required"));
    }

    #[test]
    fn an_empty_summary_is_refused() {
        let text = spec_with(&[
            &verb(r#"["a"]"#, "[]", "[]").replace(r#""summary":"k""#, r#""summary":"""#)
        ]);
        let err = Spec::parse(&text).expect_err("an empty summary");
        assert!(err.to_string().contains("summary"), "{err}");
    }

    #[test]
    fn an_empty_program_is_refused() {
        let text = spec_with(&[&verb(r#"["a"]"#, "[]", "[]")])
            .replace(r#""program":"p""#, r#""program":"""#);
        let err = Spec::parse(&text).expect_err("an empty program");
        assert!(err.to_string().contains("program"), "{err}");
    }

    #[test]
    fn two_verbs_with_one_path_are_refused() {
        let one = verb(r#"["a","b"]"#, "[]", "[]");
        let err = Spec::parse(&spec_with(&[&one, &one])).expect_err("a duplicate path");
        assert!(err.to_string().contains("twice"), "{err}");
    }

    #[test]
    fn a_valid_verb_passes_the_same_checks() {
        Spec::parse(&spec_with(&[&verb(r#"["a"]"#, r#"["<x>"]"#, r#"["o"]"#)])).expect("accepted");
    }

    #[test]
    fn the_bundled_spec_loads() {
        let spec = Spec::bundled().expect("the data file matches the model");
        assert_eq!(spec.program, "tagents-core");
        assert_eq!(spec.exit["usage"], 2);
        assert_eq!(spec.commands.len(), 14);
        let rust: Vec<String> = spec
            .served_by(Implementation::Rust)
            .map(|c| c.path.join(" "))
            .collect();
        assert_eq!(
            rust,
            ["sessions recent", "sessions search", "sessions show", "mcp"]
        );
    }

    #[test]
    fn the_data_file_points_at_the_schema_next_to_it() {
        let spec = Spec::bundled().expect("loads");
        let schema = spec.schema.expect("a $schema line");
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../spec/cli");
        assert!(dir.join(schema).is_file());
    }

    /// A verb of the data file with `extra` after `"impl":"node"`, e.g. `,"effect":"read"`.
    fn verb_with(extra: &str) -> String {
        format!(
            r#"{{"path":["a"],"positionals":[],"options":{{}},"required":[],"summary":"k","impl":"node"{extra}}}"#
        )
    }

    #[test]
    fn effect_is_optional_and_one_of_five_words() {
        for (word, effect) in [
            ("read", Effect::Read),
            ("write", Effect::Write),
            ("spawn", Effect::Spawn),
            ("destructive", Effect::Destructive),
            ("serve", Effect::Serve),
        ] {
            let parsed: Command =
                serde_json::from_str(&verb_with(&format!(r#","effect":"{word}""#)))
                    .expect("effect accepted");
            assert_eq!(parsed.effect, Some(effect), "{word}");
        }
        let parsed: Command = serde_json::from_str(&verb_with("")).expect("effect optional");
        assert_eq!(parsed.effect, None);
    }

    #[test]
    fn an_effect_nobody_declared_is_refused_like_the_schema_does() {
        for bad in [
            r#""writes""#,
            r#""Read""#,
            r#""""#,
            "1",
            "true",
            "[]",
            "null",
        ] {
            let text = verb_with(&format!(r#","effect":{bad}"#));
            assert!(
                serde_json::from_str::<Command>(&text).is_err(),
                "effect {bad} accepted"
            );
        }
    }

    #[test]
    fn tool_is_optional_and_only_false() {
        let parsed: Command =
            serde_json::from_str(&verb_with(r#","tool":false"#)).expect("tool false accepted");
        assert_eq!(parsed.tool, Some(NotATool));
        let parsed: Command = serde_json::from_str(&verb_with("")).expect("tool optional");
        assert_eq!(parsed.tool, None);
    }

    #[test]
    fn a_tool_that_is_not_false_is_refused_like_the_schema_does() {
        for bad in ["true", r#""false""#, "0", "[]", "null"] {
            let text = verb_with(&format!(r#","tool":{bad}"#));
            assert!(
                serde_json::from_str::<Command>(&text).is_err(),
                "tool {bad} accepted"
            );
        }
    }

    #[test]
    fn effect_and_tool_are_printed_as_the_data_file_writes_them() {
        let text = serde_json::to_string(&command(Some(Effect::Destructive), Some(NotATool)))
            .expect("serializes");
        assert!(
            text.contains(r#""effect":"destructive","tool":false"#),
            "{text}"
        );
        let text = serde_json::to_string(&command(None, None)).expect("serializes");
        assert!(!text.contains("effect") && !text.contains("tool"), "{text}");
    }

    #[test]
    fn a_null_multiple_is_refused_like_the_schema_does() {
        assert!(
            serde_json::from_str::<OptionSpec>(r#"{"type":"string","multiple":null}"#).is_err()
        );
        let ok: OptionSpec =
            serde_json::from_str(r#"{"type":"string"}"#).expect("multiple optional");
        assert_eq!(ok.multiple, None);
    }

    #[test]
    fn a_null_schema_line_is_refused_like_the_schema_does() {
        let text = spec_with(&[]).replacen('{', r#"{"$schema":null,"#, 1);
        assert!(Spec::parse(&text).is_err());
    }

    #[test]
    fn a_key_written_twice_is_refused_though_json_parse_keeps_the_last() {
        let text = spec_with(&[]).replacen('{', r#"{"program":"first","#, 1);
        let err = Spec::parse(&text).expect_err("a duplicate key").to_string();
        assert!(err.contains("duplicate"), "{err}");
    }

    #[test]
    fn a_lone_surrogate_escape_is_refused_though_json_parse_accepts_it() {
        let text = spec_with(&[]).replace(r#""program":"p""#, r#""program":"\ud800""#);
        let err = Spec::parse(&text)
            .expect_err("a lone surrogate")
            .to_string();
        assert!(err.contains("hex escape"), "{err}");
    }

    #[test]
    fn a_key_the_schema_does_not_name_is_refused() {
        let extra = r#"{"path":["a"],"positionals":[],"options":{},"required":[],"summary":"k","impl":"node","surprise":1}"#;
        assert!(serde_json::from_str::<Command>(extra).is_err());
        let both = r#"{"path":["a"],"positionals":[],"options":{},"required":[],"summary":"k","impl":"python"}"#;
        assert!(serde_json::from_str::<Command>(both).is_err());
    }

    /// The schema is the contract the other programs read; the model must name the same keys.
    #[test]
    fn the_schema_and_the_model_name_the_same_keys() {
        let schema: Value = serde_json::from_str(SCHEMA).expect("the schema is JSON");
        let defs = &schema["$defs"];

        let top = serde_json::to_value(Spec {
            schema: Some(String::new()),
            program: String::new(),
            exit: BTreeMap::new(),
            commands: vec![],
        })
        .expect("serializes");
        assert_eq!(names(object(&schema["properties"])), names(object(&top)));
        assert_eq!(
            required(&schema),
            BTreeSet::from(["program".into(), "exit".into(), "commands".into()])
        );

        let full =
            serde_json::to_value(command(Some(Effect::Read), Some(NotATool))).expect("serializes");
        let bare = serde_json::to_value(command(None, None)).expect("serializes");
        let cmd = &defs["command"];
        assert_eq!(names(object(&cmd["properties"])), names(object(&full)));
        assert_eq!(required(cmd), names(object(&bare)));

        let full = serde_json::to_value(OptionSpec {
            kind: OptionKind::String,
            multiple: Some(true),
        })
        .expect("serializes");
        let bare = serde_json::to_value(OptionSpec {
            kind: OptionKind::Boolean,
            multiple: None,
        })
        .expect("serializes");
        let option = &defs["option"];
        assert_eq!(names(object(&option["properties"])), names(object(&full)));
        assert_eq!(required(option), names(object(&bare)));
    }

    #[test]
    fn the_schema_enums_are_the_model_enums() {
        let schema: Value = serde_json::from_str(SCHEMA).expect("the schema is JSON");
        let spelled = |v: &dyn Fn() -> Vec<Value>| -> BTreeSet<String> {
            v().iter()
                .map(|s| s.as_str().expect("text").to_owned())
                .collect()
        };
        let impls =
            serde_json::to_value([Implementation::Rust, Implementation::Node]).expect("serializes");
        let kinds =
            serde_json::to_value([OptionKind::String, OptionKind::Boolean]).expect("serializes");
        let list = |v: &Value| v.as_array().expect("a list").clone();
        assert_eq!(
            spelled(&|| list(&schema["$defs"]["command"]["properties"]["impl"]["enum"])),
            spelled(&|| list(&impls))
        );
        assert_eq!(
            spelled(&|| list(&schema["$defs"]["option"]["properties"]["type"]["enum"])),
            spelled(&|| list(&kinds))
        );
        // `word` has no wildcard arm, so a new variant does not compile until it is spelled here and then listed below.
        fn word(effect: Effect) -> &'static str {
            match effect {
                Effect::Read => "read",
                Effect::Write => "write",
                Effect::Spawn => "spawn",
                Effect::Destructive => "destructive",
                Effect::Serve => "serve",
            }
        }
        let effects = [
            Effect::Read,
            Effect::Write,
            Effect::Spawn,
            Effect::Destructive,
            Effect::Serve,
        ];
        let spelled_by_serde = serde_json::to_value(effects).expect("serializes");
        assert_eq!(
            spelled(&|| list(&schema["$defs"]["command"]["properties"]["effect"]["enum"])),
            spelled(&|| list(&spelled_by_serde))
        );
        assert_eq!(
            spelled(&|| list(&spelled_by_serde)),
            effects.iter().map(|e| word(*e).to_owned()).collect()
        );
    }

    #[test]
    fn the_schema_allows_tool_false_and_nothing_else() {
        let schema: Value = serde_json::from_str(SCHEMA).expect("the schema is JSON");
        assert_eq!(
            schema["$defs"]["command"]["properties"]["tool"]["const"],
            Value::Bool(false)
        );
    }
}
