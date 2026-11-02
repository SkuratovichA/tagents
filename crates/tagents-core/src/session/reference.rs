//! The reference a session verb takes and prints: `SessionRefSchema` and `parseSessionRef` of `packages/core/src/session-ref.ts`, `resolveRef` of `cli/main.ts`, and `list` of `ClaudeHeadlessDriver` that `resolveRef` and `session list` share.
//!
//! A reference node accepts but whose strings cannot be rebuilt byte for byte from what this reader holds is not answered (`Read::HandOver`, design D2): a lone surrogate in a key or in a string the schema keeps, a NUL in one, a `spec.env` entry that `spawn` refuses, an empty `bin` and a relative `bin` with a slash in it. A reference the schema refuses is `Read::Invalid`, which both programs word the same way, so the schema decides before the hand-over does.

use crate::js;
use crate::json::{self, Value};
use crate::notify::state::{RowState, labels_by_session, read_agent_state};

/// `SessionSpec`: the keys of `toSpec` in the order it writes them.
#[derive(Debug, Clone, PartialEq)]
pub struct Spec {
    pub cwd: String,
    pub skip_permissions: bool,
    pub label: Option<String>,
    /// Absent, `null` (the default account) or a directory: `Some(None)` is `null`.
    pub config_dir: Option<Option<String>>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub system_prompt_file: Option<String>,
    pub mcp_config: Option<String>,
    pub disallowed_tools: Option<Vec<String>>,
    /// In JavaScript's key order, a key once, with `__proto__` dropped as the schema drops it.
    pub env: Option<Vec<(String, String)>>,
    pub bin: Option<String>,
    pub log_file: Option<String>,
}

/// `SessionRef`.
#[derive(Debug, Clone, PartialEq)]
pub struct Reference {
    pub id: String,
    pub claude_session_id: Option<String>,
    pub transcript: Option<String>,
    pub spec: Spec,
}

/// What `read` made of a text.
#[derive(Debug, Clone, PartialEq)]
pub enum Read {
    /// `parseSessionRef` gives `null`.
    Invalid,
    /// Node accepts it and this reader cannot reproduce what node does with it.
    HandOver,
    Ref(Box<Reference>),
}

/// What `resolve` made of a reference given on the command line.
#[derive(Debug, Clone, PartialEq)]
pub enum Resolved {
    Ref(Box<Reference>),
    HandOver,
    NoMatch,
}

/// Reads the strings of a document and notes the ones the Rust side cannot rebuild.
struct Reader {
    hand_over: bool,
}

impl Reader {
    /// A string the schema keeps: its text, with a lone half or a NUL noted.
    fn text(&mut self, value: &Value) -> Option<String> {
        let text = match value {
            Value::String(text) => text.clone(),
            Value::Units(units) => {
                self.hand_over = true;
                String::from_utf16_lossy(units)
            }
            _ => return None,
        };
        self.hand_over |= text.contains('\0');
        Some(text)
    }

    /// A string that may be `null`: the outer `None` is a value that is neither.
    fn nullable(&mut self, value: &Value) -> Option<Option<String>> {
        match value {
            Value::Null => Some(None),
            other => self.text(other).map(Some),
        }
    }

    /// A string field that may be absent, but not `null`.
    fn optional(&mut self, spec: &Value, key: &str) -> Option<Option<String>> {
        match spec.get(key) {
            None => Some(None),
            Some(value) => self.text(value).map(Some),
        }
    }

    fn spec(&mut self, spec: &Value) -> Option<Spec> {
        if !matches!(spec, Value::Object(_)) || spec.get("kind")?.as_str() != Some("claude") {
            return None;
        }
        let cwd = self.text(spec.get("cwd")?)?;
        let Value::Bool(skip_permissions) = spec.get("skipPermissions")? else {
            return None;
        };
        let label = self.optional(spec, "label")?;
        let config_dir = match spec.get("configDir") {
            None => None,
            Some(value) => Some(self.nullable(value)?),
        };
        let (model, effort) = (
            self.optional(spec, "model")?,
            self.optional(spec, "effort")?,
        );
        let system_prompt_file = self.optional(spec, "systemPromptFile")?;
        let mcp_config = self.optional(spec, "mcpConfig")?;
        let disallowed_tools = match spec.get("disallowedTools") {
            None => None,
            Some(Value::Array(items)) => Some(
                items
                    .iter()
                    .map(|item| self.text(item))
                    .collect::<Option<Vec<_>>>()?,
            ),
            Some(_) => return None,
        };
        let env = match spec.get("env") {
            None => None,
            Some(env) => Some(self.env(env)?),
        };
        let bin = self.optional(spec, "bin")?;
        if let Some(bin) = &bin {
            self.hand_over |= bin.is_empty() || (!bin.starts_with('/') && bin.contains('/'));
        }
        let log_file = self.optional(spec, "logFile")?;
        Some(Spec {
            cwd,
            skip_permissions: *skip_permissions,
            label,
            config_dir,
            model,
            effort,
            system_prompt_file,
            mcp_config,
            disallowed_tools,
            env,
            bin,
            log_file,
        })
    }

    /// `z.record(z.string(), z.string())`: an object, whose `__proto__` key is dropped whatever it holds.
    fn env(&mut self, env: &Value) -> Option<Vec<(String, String)>> {
        let mut kept = Vec::new();
        for (name, value) in env.entries()? {
            if name == "__proto__" {
                continue;
            }
            let value = self.text(value)?;
            self.hand_over |= name.is_empty() || name.contains('=') || name.contains('\0');
            kept.push((name.to_owned(), value));
        }
        Some(kept)
    }

    fn reference(&mut self, document: &Value) -> Option<Reference> {
        if !matches!(document, Value::Object(_)) {
            return None;
        }
        let id = self.text(document.get("id")?)?;
        let claude_session_id = self.nullable(document.get("claudeSessionId")?)?;
        let transcript = self.nullable(document.get("transcript")?)?;
        let spec = self.spec(document.get("spec")?)?;
        Some(Reference {
            id,
            claude_session_id,
            transcript,
            spec,
        })
    }
}

/// `parseSessionRef(text)`, with the calls this reader leaves to node told apart.
pub fn read(text: &str) -> Read {
    let Some(exact) = json::parse_exact(text) else {
        return Read::Invalid;
    };
    let mut reader = Reader { hand_over: false };
    match reader.reference(&exact.value) {
        None => Read::Invalid,
        Some(_) if exact.lone_key || reader.hand_over => Read::HandOver,
        Some(reference) => Read::Ref(Box::new(reference)),
    }
}

/// `resolveRef(driver, raw)`: the JSON `session open` printed when the trimmed text starts with `{`, else the id the hook knows by its key or its session id, else the first reference whose session id starts with the text.
pub fn resolve(raw: &str, state_dir: &str) -> Resolved {
    if js::trim(raw).starts_with('{') {
        return match read(raw) {
            Read::Ref(reference) => Resolved::Ref(reference),
            Read::HandOver => Resolved::HandOver,
            Read::Invalid => Resolved::NoMatch,
        };
    }
    let known = listed(state_dir, None, &[]);
    let by_id = known
        .iter()
        .position(|r| r.id == raw || r.claude_session_id.as_deref() == Some(raw));
    let by_prefix = || {
        known.iter().position(|r| {
            r.claude_session_id
                .as_deref()
                .is_some_and(|id| id.starts_with(raw))
        })
    };
    match by_id.or_else(by_prefix) {
        Some(at) => Resolved::Ref(Box::new(known[at].clone())),
        None => Resolved::NoMatch,
    }
}

/// `driver.list({label, state})`: the references of the state rows that are not `subdone`, those whose label is `label` when it is given and whose state is one of `states` when there are any, in the order the reader returns them.
pub fn listed(state_dir: &str, label: Option<&str>, states: &[RowState]) -> Vec<Reference> {
    let labels = labels_by_session(state_dir);
    read_agent_state(state_dir)
        .into_iter()
        .filter(|row| row.state != RowState::Subdone)
        .filter(|row| states.is_empty() || states.contains(&row.state))
        .filter_map(|row| {
            let name = labels.get(&row.session_id).cloned().unwrap_or_default();
            if label.is_some_and(|wanted| wanted != name) {
                return None;
            }
            Some(Reference::of_row(row, name))
        })
        .collect()
}

impl Reference {
    /// The reference a state row stands for: its key, its session and transcript when they are not empty, and a spec that says only what the row says (design D9).
    pub fn of_row(row: crate::notify::state::AgentStateRow, label: String) -> Reference {
        Reference {
            id: row.key,
            claude_session_id: Some(row.session_id).filter(|id| !id.is_empty()),
            transcript: Some(row.transcript).filter(|path| !path.is_empty()),
            spec: Spec {
                cwd: row.cwd,
                skip_permissions: false,
                label: Some(label).filter(|label| !label.is_empty()),
                // No seventh column says nothing about the account: inherit.
                config_dir: row
                    .config_dir
                    .map(|dir| Some(dir).filter(|dir| !dir.is_empty())),
                model: None,
                effort: None,
                system_prompt_file: None,
                mcp_config: None,
                disallowed_tools: None,
                env: None,
                bin: None,
                log_file: None,
            },
        }
    }

    /// The value `JSON.stringify` prints for the reference node built, in the key order of `toRef` and `toSpec`.
    pub fn to_value(&self) -> Value {
        let text = |s: &str| Value::String(s.to_owned());
        let or_null = |s: &Option<String>| s.as_deref().map_or(Value::Null, text);
        let spec = &self.spec;
        let mut members = vec![
            ("kind".to_owned(), text("claude")),
            ("cwd".to_owned(), text(&spec.cwd)),
            (
                "skipPermissions".to_owned(),
                Value::Bool(spec.skip_permissions),
            ),
        ];
        let mut add = |key: &str, value: Option<Value>| {
            if let Some(value) = value {
                members.push((key.to_owned(), value));
            }
        };
        add("label", spec.label.as_deref().map(text));
        add("configDir", spec.config_dir.as_ref().map(or_null));
        add("model", spec.model.as_deref().map(text));
        add("effort", spec.effort.as_deref().map(text));
        add(
            "systemPromptFile",
            spec.system_prompt_file.as_deref().map(text),
        );
        add("mcpConfig", spec.mcp_config.as_deref().map(text));
        add(
            "disallowedTools",
            spec.disallowed_tools
                .as_ref()
                .map(|tools| Value::Array(tools.iter().map(|tool| text(tool)).collect())),
        );
        add(
            "env",
            spec.env
                .as_ref()
                .map(|env| Value::Object(env.iter().map(|(k, v)| (k.clone(), text(v))).collect())),
        );
        add("bin", spec.bin.as_deref().map(text));
        add("logFile", spec.log_file.as_deref().map(text));
        Value::Object(vec![
            ("id".to_owned(), text(&self.id)),
            (
                "claudeSessionId".to_owned(),
                or_null(&self.claude_session_id),
            ),
            ("transcript".to_owned(), or_null(&self.transcript)),
            ("spec".to_owned(), Value::Object(members)),
        ])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Scratch;
    use std::fs;

    const SPEC: &str = r#"{"kind":"claude","cwd":"/w","skipPermissions":false}"#;

    fn doc(spec: &str) -> String {
        format!(r#"{{"id":"r1","claudeSessionId":null,"transcript":null,"spec":{spec}}}"#)
    }

    fn printed(text: &str) -> String {
        match read(text) {
            Read::Ref(r) => json::stringify(&r.to_value(), false),
            other => panic!("{text}: {other:?}"),
        }
    }

    #[test]
    fn a_reference_prints_in_the_order_of_to_ref() {
        let text = doc(
            r#"{"bin":"/b","env":{"B":"1","2":"x","1":"y"},"model":"m","skipPermissions":true,"cwd":"/w","kind":"claude","configDir":null,"label":"l"}"#,
        );
        assert_eq!(
            printed(&text),
            r#"{"id":"r1","claudeSessionId":null,"transcript":null,"spec":{"kind":"claude","cwd":"/w","skipPermissions":true,"label":"l","configDir":null,"model":"m","env":{"1":"y","2":"x","B":"1"},"bin":"/b"}}"#
        );
    }

    #[test]
    fn the_schema_decides_before_the_hand_over() {
        let lone = r#"\ud83d"#;
        let bad = doc(&format!(
            r#"{{"kind":"claude","cwd":"/w","skipPermissions":0,"label":"{lone}"}}"#
        ));
        assert_eq!(read(&bad), Read::Invalid);
        assert_eq!(read(""), Read::Invalid);
        assert_eq!(read("[]"), Read::Invalid);
    }

    #[test]
    fn what_cannot_be_rebuilt_is_handed_over() {
        let lone = r#"\ud83d"#;
        for spec in [
            format!(r#"{{"kind":"claude","cwd":"/w{lone}","skipPermissions":false}}"#),
            r#"{"kind":"claude","cwd":"/w\u0000","skipPermissions":false}"#.to_owned(),
            format!(r#"{{"kind":"claude","cwd":"/w","skipPermissions":false,"{lone}":1}}"#),
            r#"{"kind":"claude","cwd":"/w","skipPermissions":false,"env":{"":"1"}}"#.to_owned(),
            r#"{"kind":"claude","cwd":"/w","skipPermissions":false,"env":{"A=B":"1"}}"#.to_owned(),
            r#"{"kind":"claude","cwd":"/w","skipPermissions":false,"bin":""}"#.to_owned(),
            r#"{"kind":"claude","cwd":"/w","skipPermissions":false,"bin":"a/b"}"#.to_owned(),
        ] {
            assert_eq!(read(&doc(&spec)), Read::HandOver, "{spec}");
        }
        for spec in [
            r#"{"kind":"claude","cwd":"/w","skipPermissions":false,"bin":"claude"}"#,
            r#"{"kind":"claude","cwd":"/w","skipPermissions":false,"bin":"/a/b"}"#,
            r#"{"kind":"claude","cwd":"/w","skipPermissions":false,"extra":"\ud83d"}"#,
        ] {
            // A field the schema drops is not read again; only a key with a lone half is.
            let kind = read(&doc(spec));
            assert!(matches!(kind, Read::Ref(_)), "{spec}: {kind:?}");
        }
    }

    #[test]
    fn the_proto_key_of_env_is_dropped_and_a_repeated_key_is_one() {
        let spec = r#"{"kind":"claude","cwd":"/w","skipPermissions":false,"env":{"__proto__":5,"A":"x","A":"y"}}"#;
        assert!(printed(&doc(spec)).contains(r#""env":{"A":"y"}"#));
        let spec = r#"{"kind":"claude","cwd":"/w","skipPermissions":false,"env":{"A":5,"A":"y"}}"#;
        assert!(matches!(read(&doc(spec)), Read::Ref(_)));
        let spec = r#"{"kind":"claude","cwd":"/w","skipPermissions":false,"env":{"A":"y","A":5}}"#;
        assert_eq!(read(&doc(spec)), Read::Invalid);
    }

    #[test]
    fn config_dir_is_absent_null_or_a_string() {
        for (field, printed_as) in [
            ("", ""),
            (r#","configDir":null"#, r#","configDir":null"#),
            (r#","configDir":"""#, r#","configDir":"""#),
        ] {
            let spec = format!(r#"{{"kind":"claude","cwd":"/w","skipPermissions":false{field}}}"#);
            let want = format!(r#""skipPermissions":false{printed_as}}}"#);
            assert!(printed(&doc(&spec)).contains(&want), "{field}");
        }
    }

    fn state_dir() -> Scratch {
        let dir = Scratch::new();
        let mut at = 1_700_000_000;
        let mut row = |key: &str, state: &str, sid: &str, config: Option<&str>| {
            at -= 1;
            let mut line = format!("{at}\t{state}\t{sid}\t/w/{key}\t/t/{sid}.jsonl\tdetail");
            if let Some(config) = config {
                line.push_str(&format!("\t{config}"));
            }
            fs::write(dir.path().join(format!("{key}.tsv")), format!("{line}\n")).unwrap();
        };
        row("s-a", "working", "abc123", None);
        row("s-b", "done", "abd456", Some(""));
        row("s-c", "subdone", "zzz", Some("/acct"));
        row("7", "blocked", "", Some("/acct"));
        fs::write(
            dir.path().join("history.tsv"),
            "1\tstart\tabc123\t%1\tmine\t/w\n",
        )
        .unwrap();
        dir
    }

    fn keys(refs: &[Reference]) -> Vec<&str> {
        refs.iter().map(|r| r.id.as_str()).collect()
    }

    #[test]
    fn listing_leaves_out_subdone_and_filters_by_label_and_state() {
        let dir = state_dir();
        let path = dir.path().to_str().unwrap();
        let all = listed(path, None, &[]);
        assert_eq!(keys(&all), ["s-a", "s-b", "7"]);
        assert_eq!(keys(&listed(path, Some("mine"), &[])), ["s-a"]);
        assert_eq!(keys(&listed(path, Some(""), &[])).len(), 2);
        assert_eq!(keys(&listed(path, None, &[RowState::Done])), ["s-b"]);
        assert!(listed(path, None, &[RowState::Subdone]).is_empty());
        let acct = all.iter().find(|r| r.id == "7").unwrap();
        assert_eq!(acct.claude_session_id, None);
        assert_eq!(acct.spec.config_dir, Some(Some("/acct".to_owned())));
        let done = all.iter().find(|r| r.id == "s-b").unwrap();
        assert_eq!(done.spec.config_dir, Some(None));
        let old = all.iter().find(|r| r.id == "s-a").unwrap();
        assert_eq!(old.spec.config_dir, None);
        assert_eq!(old.spec.label.as_deref(), Some("mine"));
    }

    #[test]
    fn a_text_resolves_by_id_then_session_then_prefix() {
        let dir = state_dir();
        let path = dir.path().to_str().unwrap();
        let id = |raw: &str| match resolve(raw, path) {
            Resolved::Ref(r) => r.id,
            other => format!("{other:?}"),
        };
        assert_eq!(id("s-b"), "s-b");
        assert_eq!(id("abd456"), "s-b");
        assert_eq!(id("abc"), "s-a");
        // Two prefixes match: the first row wins, not the unique one.
        assert_eq!(id("ab"), "s-a");
        assert_eq!(id("zzz"), "NoMatch");
        assert_eq!(id("nothing"), "NoMatch");
        assert_eq!(id("  {\"x\":1}"), "NoMatch");
        assert_eq!(id(&doc(SPEC)), "r1");
        assert_eq!(
            resolve(
                &doc(r#"{"kind":"claude","cwd":"/w","skipPermissions":false,"bin":""}"#),
                path
            ),
            Resolved::HandOver
        );
    }
}
