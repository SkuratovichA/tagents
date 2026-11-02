//! `session open`, `session list` and `session last`: the three verbs that start no process, as the node CLI's `session()` serves them.
//!
//! Each answers only what it can prove identical to node and returns `None` otherwise, before anything is read or written: an argument outside the grammar of `args`, a reference given as JSON that the Rust reader cannot rebuild (`reference::Read::HandOver`), a working directory that is gone or not UTF-8, random bytes that cannot be read.

use std::{fs, io::Read};

use crate::{
    args::Grammar,
    json::{self, Value},
    messages::{Locale, Texts},
    node,
    notify::state::{RowState, read_agent_state, state_dir},
    session::reference::{self, Resolved},
    sessions::{Output, exit},
    transcripts,
};

/// What a call depends on besides its arguments.
pub struct Setting {
    /// `process.cwd()`.
    pub cwd: String,
    /// `stateDir()`.
    pub state_dir: String,
    pub locale: Locale,
}

impl Setting {
    /// The setting of this process. `None` when the working directory is gone or is not UTF-8: node would fail on the one and read the other with U+FFFD.
    pub fn current() -> Option<Setting> {
        let cwd = std::env::current_dir()
            .ok()?
            .into_os_string()
            .into_string()
            .ok()?;
        Some(Setting {
            cwd,
            state_dir: state_dir(),
            locale: Locale::current(),
        })
    }
}

const OPEN: Grammar = Grammar {
    strings: &[
        "cwd",
        "label",
        "model",
        "effort",
        "resume",
        "system-prompt-file",
        "mcp-config",
        "config-dir",
    ],
    flags: &["no-config-dir", "skip-permissions"],
    multiple: &[],
    positionals: false,
};

const LIST: Grammar = Grammar {
    strings: &["label"],
    flags: &[],
    multiple: &["state"],
    positionals: false,
};

/// The five states `--state` accepts: `subdone` is a row's, not a session's.
const STATES: [(&str, RowState); 5] = [
    ("new", RowState::New),
    ("working", RowState::Working),
    ("blocked", RowState::Blocked),
    ("done", RowState::Done),
    ("gone", RowState::Gone),
];

fn usage(stderr: String) -> Output {
    Output {
        stdout: String::new(),
        stderr: format!("{stderr}\n"),
        code: exit::USAGE,
    }
}

/// `json(value)` of `cli/exit.ts`: two-space layout and a newline.
fn printed(value: &Value) -> Output {
    Output::out(format!("{}\n", json::stringify(value, true)))
}

fn text(s: &str) -> Value {
    Value::String(s.to_owned())
}

/// A version 4 id (RFC 4122) from 16 bytes of the system's random source, as `randomUUID()` makes it.
fn random_id() -> Option<String> {
    let mut bytes = [0u8; 16];
    fs::File::open("/dev/urandom")
        .ok()?
        .read_exact(&mut bytes)
        .ok()?;
    bytes[6] = bytes[6] & 0x0f | 0x40;
    bytes[8] = bytes[8] & 0x3f | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    Some(format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    ))
}

/// `session open …`: the reference of a session that has not started.
pub fn open(args: &[String], setting: &Setting, texts: &Texts) -> Option<Output> {
    let parsed = OPEN.parse(args)?;
    let Some(cwd) = parsed.value("cwd").filter(|cwd| !cwd.is_empty()) else {
        return Some(usage(texts.t("missingOption", &[("option", "--cwd")])));
    };
    let config_dir = parsed.value("config-dir");
    let no_config_dir = parsed.flag("no-config-dir");
    if config_dir.is_some() && no_config_dir {
        return Some(usage(texts.t(
            "unknownOption",
            &[("option", "--config-dir + --no-config-dir")],
        )));
    }
    let id = random_id()?;
    let resume = parsed.value("resume");
    // `ref.transcript` of the driver: the first row of the session that names a transcript.
    let transcript = resume.filter(|id| !id.is_empty()).and_then(|id| {
        read_agent_state(&setting.state_dir)
            .into_iter()
            .find(|row| row.session_id == id && !row.transcript.is_empty())
            .map(|row| row.transcript)
    });
    let mut spec = vec![
        ("kind".to_owned(), text("claude")),
        ("cwd".to_owned(), text(&node::resolve(&setting.cwd, cwd))),
        (
            "skipPermissions".to_owned(),
            Value::Bool(parsed.flag("skip-permissions")),
        ),
    ];
    for (key, option) in [
        ("label", "label"),
        ("model", "model"),
        ("effort", "effort"),
        ("systemPromptFile", "system-prompt-file"),
        ("mcpConfig", "mcp-config"),
    ] {
        if let Some(value) = parsed.value(option) {
            spec.push((key.to_owned(), text(value)));
        }
    }
    if no_config_dir {
        spec.push(("configDir".to_owned(), Value::Null));
    }
    if let Some(dir) = config_dir {
        spec.push(("configDir".to_owned(), text(dir)));
    }
    Some(printed(&Value::Object(vec![
        ("id".to_owned(), text(&id)),
        (
            "claudeSessionId".to_owned(),
            resume.map_or(Value::Null, text),
        ),
        (
            "transcript".to_owned(),
            transcript.as_deref().map_or(Value::Null, text),
        ),
        ("spec".to_owned(), Value::Object(spec)),
    ])))
}

/// `session list …`: the references of the sessions the hook knows about.
pub fn list(args: &[String], setting: &Setting, texts: &Texts) -> Option<Output> {
    let parsed = LIST.parse(args)?;
    let wanted = parsed.values("state");
    let bad: Vec<&str> = wanted
        .iter()
        .copied()
        .filter(|name| STATES.iter().all(|(known, _)| known != name))
        .collect();
    if !bad.is_empty() {
        let option = format!("--state {}", bad.join(","));
        return Some(usage(texts.t("unknownOption", &[("option", &option)])));
    }
    let states: Vec<RowState> = STATES
        .iter()
        .filter(|(name, _)| wanted.contains(name))
        .map(|(_, state)| *state)
        .collect();
    let refs = reference::listed(&setting.state_dir, parsed.value("label"), &states);
    Some(printed(&Value::Array(
        refs.iter().map(reference::Reference::to_value).collect(),
    )))
}

/// `session last <ref>`: the last thing the session said, and when its transcript last changed.
pub fn last(args: &[String], setting: &Setting, texts: &Texts) -> Option<Output> {
    let Some(raw) = args.first().filter(|raw| !raw.is_empty()) else {
        return Some(usage(texts.t("missingOption", &[("option", "<ref>")])));
    };
    let reference = match reference::resolve(raw, &setting.state_dir) {
        Resolved::HandOver => return None,
        Resolved::NoMatch => {
            return Some(Output::fail(format!(
                "{}\n",
                texts.t("badRef", &[("ref", raw)])
            )));
        }
        Resolved::Ref(reference) => *reference,
    };
    let file = reference.transcript.or_else(|| {
        let id = reference.claude_session_id.filter(|id| !id.is_empty())?;
        read_agent_state(&setting.state_dir)
            .into_iter()
            .find(|row| row.session_id == id && !row.transcript.is_empty())
            .map(|row| row.transcript)
    });
    let Some(file) = file.filter(|file| !file.is_empty()) else {
        return Some(printed(&Value::Null));
    };
    // `lastAssistant`: a file that cannot be stat'd is no answer, one that cannot be read is a failure.
    let Ok(meta) = fs::metadata(&file) else {
        return Some(printed(&Value::Null));
    };
    let at = node::mtime_ms_exact(&meta);
    let reply = match transcripts::last_assistant_reply(&file, |line| {
        json::parse_exact(line).map(|exact| exact.value)
    }) {
        Ok(reply) => reply,
        Err(failure) => return Some(Output::fail(format!("{failure}\n"))),
    };
    if matches!(&reply, Value::String(text) if text.is_empty()) {
        return Some(printed(&Value::Null));
    }
    Some(printed(&Value::Object(vec![
        ("text".to_owned(), reply),
        ("at".to_owned(), Value::Number(at)),
    ])))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Scratch;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|a| (*a).to_owned()).collect()
    }

    fn fixture() -> (Scratch, Setting, Texts) {
        let state = Scratch::new();
        let setting = Setting {
            cwd: "/base/dir".to_owned(),
            state_dir: state.path().to_str().unwrap().to_owned(),
            locale: Locale::En,
        };
        (state, setting, Texts::load(Locale::En).unwrap())
    }

    fn json_of(output: &Output) -> serde_json::Value {
        serde_json::from_str(&output.stdout).unwrap()
    }

    #[test]
    fn open_prints_the_reference_in_the_order_of_main() {
        let (_state, setting, texts) = fixture();
        let out = open(
            &args(&[
                "--cwd",
                "rel",
                "--label",
                "",
                "--model",
                "m",
                "--effort",
                "e",
                "--system-prompt-file",
                "/s",
                "--mcp-config",
                "/m",
                "--config-dir",
                "/acct",
                "--skip-permissions",
                "--resume",
                "sid",
            ]),
            &setting,
            &texts,
        )
        .unwrap();
        assert_eq!(out.code, 0);
        let id = json_of(&out)["id"].as_str().unwrap().to_owned();
        assert_eq!(id.len(), 36);
        assert_eq!(&id[14..15], "4");
        assert!("89ab".contains(&id[19..20]));
        let want = format!(
            "{{\n  \"id\": \"{id}\",\n  \"claudeSessionId\": \"sid\",\n  \"transcript\": null,\n  \"spec\": {{\n    \"kind\": \"claude\",\n    \"cwd\": \"/base/dir/rel\",\n    \"skipPermissions\": true,\n    \"label\": \"\",\n    \"model\": \"m\",\n    \"effort\": \"e\",\n    \"systemPromptFile\": \"/s\",\n    \"mcpConfig\": \"/m\",\n    \"configDir\": \"/acct\"\n  }}\n}}\n"
        );
        assert_eq!(out.stdout, want);
    }

    #[test]
    fn open_checks_cwd_first_and_then_the_two_account_flags() {
        let (_state, setting, texts) = fixture();
        let missing = open(
            &args(&["--no-config-dir", "--config-dir", "/a"]),
            &setting,
            &texts,
        )
        .unwrap();
        assert_eq!(
            (missing.code, missing.stderr.as_str()),
            (2, "missing required option --cwd\n")
        );
        let empty = open(&args(&["--cwd", ""]), &setting, &texts).unwrap();
        assert_eq!(empty.code, 2);
        let both = open(
            &args(&["--cwd", "/w", "--no-config-dir", "--config-dir", "/a"]),
            &setting,
            &texts,
        )
        .unwrap();
        assert_eq!(both.code, 2);
        assert!(
            both.stderr.contains("--config-dir + --no-config-dir"),
            "{}",
            both.stderr
        );
        let null = open(&args(&["--cwd", "/w", "--no-config-dir"]), &setting, &texts).unwrap();
        assert!(null.stdout.contains("\"configDir\": null"));
        for bad in [
            &["--cwd"][..],
            &["--cwd", "/w", "-x"],
            &["--cwd", "/w", "extra"],
            &["--cwd=/w", "--skip-permissions=1"],
        ] {
            assert_eq!(open(&args(bad), &setting, &texts), None, "{bad:?}");
        }
    }

    #[test]
    fn open_resumes_into_the_transcript_a_row_names() {
        let (state, setting, texts) = fixture();
        std::fs::write(
            state.path().join("s-a.tsv"),
            "1700000000\tdone\tsid\t/w\t/t/sid.jsonl\tdetail\n",
        )
        .unwrap();
        let out = open(&args(&["--cwd", "/w", "--resume", "sid"]), &setting, &texts).unwrap();
        assert_eq!(json_of(&out)["transcript"], "/t/sid.jsonl");
        let none = open(&args(&["--cwd", "/w", "--resume", ""]), &setting, &texts).unwrap();
        assert_eq!(json_of(&none)["claudeSessionId"], "");
        assert!(json_of(&none)["transcript"].is_null());
    }

    #[test]
    fn two_new_ids_differ() {
        assert_ne!(random_id().unwrap(), random_id().unwrap());
    }

    fn rows(state: &Scratch) {
        for (key, at, st, sid, config) in [
            ("s-a", 3, "working", "aaa", "\t"),
            ("s-b", 2, "done", "bbb", "\t/acct"),
            ("s-c", 1, "subdone", "ccc", ""),
        ] {
            std::fs::write(
                state.path().join(format!("{key}.tsv")),
                format!("{at}\t{st}\t{sid}\t/w\t/t/{sid}.jsonl\td{config}\n"),
            )
            .unwrap();
        }
    }

    #[test]
    fn list_filters_and_refuses_an_unknown_state() {
        let (state, setting, texts) = fixture();
        rows(&state);
        let all = list(&[], &setting, &texts).unwrap();
        let ids: Vec<String> = json_of(&all)
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["id"].as_str().unwrap().to_owned())
            .collect();
        assert_eq!(ids, ["s-a", "s-b"]);
        let done = list(&args(&["--state", "done"]), &setting, &texts).unwrap();
        assert_eq!(json_of(&done).as_array().unwrap().len(), 1);
        let two = list(
            &args(&["--state", "done", "--state=working"]),
            &setting,
            &texts,
        )
        .unwrap();
        assert_eq!(json_of(&two).as_array().unwrap().len(), 2);
        let bad = list(
            &args(&["--state", "done", "--state", "x", "--state", "subdone"]),
            &setting,
            &texts,
        )
        .unwrap();
        assert_eq!(bad.code, 2);
        assert!(bad.stderr.contains("--state x,subdone"), "{}", bad.stderr);
        assert_eq!(list(&args(&["extra"]), &setting, &texts), None);
        let none = list(&args(&["--label", "nobody"]), &setting, &texts).unwrap();
        assert_eq!(none.stdout, "[]\n");
    }

    fn transcript(state: &Scratch, lines: &[&str]) -> String {
        let path = state.path().join("t.jsonl");
        std::fs::write(&path, lines.join("\n")).unwrap();
        path.to_str().unwrap().to_owned()
    }

    fn reference_to(file: &str, session: &str) -> String {
        format!(
            r#"{{"id":"r","claudeSessionId":{session},"transcript":{file},"spec":{{"kind":"claude","cwd":"/w","skipPermissions":false}}}}"#
        )
    }

    #[test]
    fn last_prints_the_text_and_the_time_or_null() {
        let (state, setting, texts) = fixture();
        let file = transcript(
            &state,
            &[
                r#"{"type":"assistant","message":{"content":[{"type":"text","text":" hi \ud83d "}]}}"#,
            ],
        );
        let quoted = serde_json::to_string(&file).unwrap();
        let out = last(&args(&[&reference_to(&quoted, "null")]), &setting, &texts).unwrap();
        assert_eq!(out.code, 0);
        assert!(
            out.stdout
                .starts_with("{\n  \"text\": \"hi \\ud83d\",\n  \"at\": "),
            "{}",
            out.stdout
        );
        let missing = reference_to("\"/no/such/file\"", "null");
        assert_eq!(
            last(&args(&[&missing]), &setting, &texts).unwrap().stdout,
            "null\n"
        );
        let no_transcript = reference_to("null", "null");
        assert_eq!(
            last(&args(&[&no_transcript]), &setting, &texts)
                .unwrap()
                .stdout,
            "null\n"
        );
        let empty_path = reference_to("\"\"", "\"x\"");
        assert_eq!(
            last(&args(&[&empty_path]), &setting, &texts)
                .unwrap()
                .stdout,
            "null\n"
        );
        let blank = transcript(&state, &["{}"]);
        let blank_ref = reference_to(&serde_json::to_string(&blank).unwrap(), "null");
        assert_eq!(
            last(&args(&[&blank_ref]), &setting, &texts).unwrap().stdout,
            "null\n"
        );
    }

    #[test]
    fn last_finds_the_transcript_of_a_row_and_fails_on_a_directory() {
        let (state, setting, texts) = fixture();
        let file = transcript(
            &state,
            &[r#"{"type":"assistant","message":{"content":[{"type":"text","text":"yes"}]}}"#],
        );
        std::fs::write(
            state.path().join("s-a.tsv"),
            format!("1\tdone\tsid\t/w\t{file}\td\n"),
        )
        .unwrap();
        let by_row = last(&args(&["sid"]), &setting, &texts).unwrap();
        assert!(
            by_row.stdout.contains("\"text\": \"yes\""),
            "{}",
            by_row.stdout
        );
        let by_json = last(&args(&[&reference_to("null", "\"sid\"")]), &setting, &texts).unwrap();
        assert_eq!(by_json.stdout, by_row.stdout);
        // An empty transcript path in the reference is an answer, so the row of the session is not asked.
        let empty = last(&args(&[&reference_to("\"\"", "\"sid\"")]), &setting, &texts).unwrap();
        assert_eq!(empty.stdout, "null\n");
        let dir = serde_json::to_string(state.path().to_str().unwrap()).unwrap();
        let broken = last(&args(&[&reference_to(&dir, "null")]), &setting, &texts).unwrap();
        assert_eq!((broken.code, broken.stdout.as_str()), (1, ""));
        assert!(broken.stderr.contains("EISDIR"), "{}", broken.stderr);
    }

    #[test]
    fn last_refuses_a_missing_or_unknown_reference_and_hands_over_what_it_cannot_read() {
        let (_state, setting, texts) = fixture();
        let missing = last(&[], &setting, &texts).unwrap();
        assert_eq!(
            (missing.code, missing.stderr.as_str()),
            (2, "missing required option <ref>\n")
        );
        let unknown = last(&args(&["nothing"]), &setting, &texts).unwrap();
        assert_eq!(unknown.code, 1);
        assert!(unknown.stderr.contains("nothing"), "{}", unknown.stderr);
        let lone = r#"{"id":"r","claudeSessionId":null,"transcript":null,"spec":{"kind":"claude","cwd":"/w\ud83d","skipPermissions":false}}"#;
        assert_eq!(last(&args(&[lone]), &setting, &texts), None);
    }
}
