//! The language-neutral `tagents-core` CLI spec: the model and the loader.
//!
//! The data is `spec/cli/tagents-core.json` at the repository root, described by `spec/cli/cli-spec.schema.json`.
//! The node CLI and the contract generator read the same file (`packages/core/src/cli/spec.ts`).
//! The model refuses a key the schema does not name, so a newer file fails here at load, not somewhere downstream.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// The spec this crate was built with: the data file, embedded.
pub const BUNDLED: &str = include_str!("../../../spec/cli/tagents-core.json");

/// A CLI's whole surface.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Spec {
    #[serde(rename = "$schema", default, skip_serializing_if = "Option::is_none")]
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
    /// Optional extra string kept for tooling that classifies verbs. Nothing here reads it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effect: Option<String>,
}

/// One option of a verb.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OptionSpec {
    #[serde(rename = "type")]
    pub kind: OptionKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
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

impl Spec {
    /// Parse a spec document.
    pub fn parse(text: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(text)
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

    fn command(effect: Option<&str>) -> Command {
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
            effect: effect.map(str::to_owned),
        }
    }

    #[test]
    fn the_bundled_spec_loads() {
        let spec = Spec::bundled().expect("the data file matches the model");
        assert_eq!(spec.program, "tagents-core");
        assert_eq!(spec.exit["usage"], 2);
        assert_eq!(spec.commands.len(), 13);
        let rust: Vec<String> = spec
            .served_by(Implementation::Rust)
            .map(|c| c.path.join(" "))
            .collect();
        assert_eq!(
            rust,
            ["sessions recent", "sessions search", "sessions show"]
        );
    }

    #[test]
    fn the_data_file_points_at_the_schema_next_to_it() {
        let spec = Spec::bundled().expect("loads");
        let schema = spec.schema.expect("a $schema line");
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../spec/cli");
        assert!(dir.join(schema).is_file());
    }

    #[test]
    fn effect_is_optional_and_a_string() {
        let with = r#"{"path":["a"],"positionals":[],"options":{},"required":[],"summary":"k","impl":"node","effect":"writes"}"#;
        let without = r#"{"path":["a"],"positionals":[],"options":{},"required":[],"summary":"k","impl":"node"}"#;
        let number = r#"{"path":["a"],"positionals":[],"options":{},"required":[],"summary":"k","impl":"node","effect":1}"#;
        let parsed: Command = serde_json::from_str(with).expect("effect accepted");
        assert_eq!(parsed.effect.as_deref(), Some("writes"));
        let parsed: Command = serde_json::from_str(without).expect("effect optional");
        assert_eq!(parsed.effect, None);
        assert!(serde_json::from_str::<Command>(number).is_err());
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

        let full = serde_json::to_value(command(Some("e"))).expect("serializes");
        let bare = serde_json::to_value(command(None)).expect("serializes");
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
    }
}
