//! What was I working on, across every Claude project on this machine?
//!
//! A port of `packages/core/src/transcripts.ts`, which stays the reference: `tests/rust-parity.sh` runs both programs on the same files and compares every byte.
//! It reads the session transcripts every Claude account keeps on disk (`~/.claude/projects/<slug>/<id>.jsonl`, plus `~/.claude-<name>/projects/`) and never reads one whole:
//! the opening human prompt lives in the first 64 KiB and the latest assistant text in the last 48 KiB, and widening a window turns a listing of 400 sessions into hundreds of megabytes of reads.
//! Where node's behaviour is an accident of its runtime (UTF-16 lengths, the order `readdir` returns, `Date` rounding), the port repeats it, because the text is a contract that an agent reads out of a shell.

use std::{
    fs, io,
    os::unix::{ffi::OsStrExt, fs::FileExt},
    path::Path,
};

use crate::{js, json, node};

pub const HEAD_WINDOW_BYTES: u64 = 65536;
pub const TAIL_WINDOW_BYTES: u64 = 49152;
/// Empty shells and aborted starts: not worth listing.
pub const MIN_TRANSCRIPT_BYTES: u64 = 2000;

/// The failure node would have thrown, as the message it would have printed.
pub type Failure = String;

/// What the listing depends on besides the files: the same three things the node CLI reads from its environment.
#[derive(Debug, Clone)]
pub struct Context {
    /// `os.homedir()`.
    pub home: String,
    /// `$CLAUDE_HOMES`: a comma-separated list that replaces the discovery.
    pub claude_homes: Option<String>,
    /// `Date.now()`.
    pub now_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Account {
    pub name: String,
    /// The `projects/` directory, not the config directory itself.
    pub dir: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionRow {
    pub id: String,
    pub account: String,
    pub project: String,
    pub file: String,
    pub mtime_ms: i64,
}

/// `fs.readdirSync`: libuv returns the names sorted by byte, and nothing else about the order is promised or stable.
/// A name that is not UTF-8 is left out: node would hand back a name with U+FFFD in it, and the next `stat` on that name fails.
fn read_dir_sorted(dir: &str) -> io::Result<Vec<fs::DirEntry>> {
    let mut entries = fs::read_dir(dir)?.collect::<io::Result<Vec<_>>>()?;
    entries.sort_by(|a, b| a.file_name().as_bytes().cmp(b.file_name().as_bytes()));
    Ok(entries)
}

fn utf8_name(entry: &fs::DirEntry) -> Option<String> {
    entry.file_name().to_str().map(str::to_owned)
}

/// `/^\.claude(-[\w.-]+)?$/`
fn is_claude_dir_name(name: &str) -> bool {
    name == ".claude"
        || name.strip_prefix(".claude-").is_some_and(|rest| {
            !rest.is_empty()
                && rest
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
        })
}

/// Every Claude config dir on this machine: `~/.claude` and any `~/.claude-<name>`.
/// `CLAUDE_HOMES=dir1,dir2` replaces the discovery, so a value of `,` means no accounts, not the default ones; only the empty string falls back to discovery.
pub fn discover_accounts(cx: &Context) -> Vec<Account> {
    let dirs: Vec<String> = match cx.claude_homes.as_deref() {
        Some(homes) if !homes.is_empty() => homes
            .split(',')
            .map(js::trim)
            .filter(|d| !d.is_empty())
            .map(str::to_owned)
            .collect(),
        _ => read_dir_sorted(&cx.home)
            .map(|entries| {
                entries
                    .iter()
                    .filter_map(utf8_name)
                    .filter(|name| is_claude_dir_name(name))
                    .map(|name| node::join(&cx.home, &name))
                    .collect()
            })
            .unwrap_or_default(),
    };
    dirs.iter()
        .map(|dir| {
            let base = node::basename(dir);
            let name = if base == ".claude" {
                "personal"
            } else {
                base.strip_prefix(".claude-").unwrap_or(base)
            };
            Account {
                name: name.to_owned(),
                dir: node::join(dir, "projects"),
            }
        })
        .filter(|account| Path::new(&account.dir).exists())
        .collect()
}

/// One window of a file, decoded as node decodes it (invalid bytes become U+FFFD) before anything is cut off.
fn window(file: &str, tail: bool, len: u64) -> Result<String, Failure> {
    let size = fs::metadata(file)
        .map_err(|e| node::io_message(&e, "stat", Some(file)))?
        .len();
    let start = if tail { size.saturating_sub(len) } else { 0 };
    let handle = fs::File::open(file).map_err(|e| node::io_message(&e, "open", Some(file)))?;
    let mut buf = vec![0; usize::try_from(len.min(size)).unwrap_or(0)];
    let mut filled = 0;
    while filled < buf.len() {
        match handle.read_at(&mut buf[filled..], start + filled as u64) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(node::io_message(&e, "read", None)),
        }
    }
    let text = String::from_utf8_lossy(&buf[..filled]);
    // A tail window starts mid-line: drop the fragment. A window with no newline in it is kept whole.
    Ok(match (start > 0, text.find('\n')) {
        (true, Some(newline)) => text[newline + 1..].to_owned(),
        _ => text.into_owned(),
    })
}

/// The first real human prompt: what the session was opened to do. Empty when there is none in the head window.
pub fn first_prompt(file: &str) -> Result<String, Failure> {
    for line in window(file, false, HEAD_WINDOW_BYTES)?.split('\n') {
        if !line.contains("\"user\"") {
            continue;
        }
        let Some(record) = json::parse(line) else {
            continue;
        };
        if record.get("type").and_then(json::Value::as_str) != Some("user")
            || record.get("isMeta").is_some_and(json::Value::truthy)
        {
            continue;
        }
        let Some(content) = record
            .get("message")
            .and_then(|m| m.get("content"))
            .and_then(json::Value::as_str)
        else {
            continue;
        };
        let trimmed = js::trim(content);
        if !trimmed.is_empty() && !content.starts_with('<') {
            return Ok(trimmed.to_owned());
        }
    }
    Ok(String::new())
}

/// The last assistant text block inside the tail window. Empty when there is none. A lone surrogate half reads as U+FFFD, which is what stdout shows of it.
pub fn last_assistant_text(file: &str) -> Result<String, Failure> {
    // `json::parse` never makes a lone half, so the reply is always whole text.
    let reply = last_assistant_reply(file, json::parse)?;
    Ok(reply.as_str().unwrap_or_default().to_owned())
}

/// The last assistant text block inside the tail window, as the string `lastAssistantText` returns: a `Value::String`, empty when there is none, or a `Value::Units` when `parse` keeps a lone surrogate half (`json::parse_exact`).
pub fn last_assistant_reply(
    file: &str,
    parse: impl Fn(&str) -> Option<json::Value>,
) -> Result<json::Value, Failure> {
    let mut reply = json::Value::String(String::new());
    for line in window(file, true, TAIL_WINDOW_BYTES)?.split('\n') {
        if !line.contains("\"assistant\"") {
            continue;
        }
        let Some(record) = parse(line) else {
            continue;
        };
        if record.get("type").and_then(json::Value::as_str) != Some("assistant") {
            continue;
        }
        let Some(json::Value::Array(blocks)) = record.get("message").and_then(|m| m.get("content"))
        else {
            continue;
        };
        for block in blocks {
            if block.get("type").and_then(json::Value::as_str) != Some("text") {
                continue;
            }
            let trimmed = match block.get("text") {
                Some(json::Value::String(text)) => Some(js::trim(text))
                    .filter(|text| !text.is_empty())
                    .map(|text| json::Value::String(text.to_owned())),
                Some(json::Value::Units(units)) => {
                    Some(json::Value::from_units(js::trim16(units).to_vec()))
                }
                _ => None,
            };
            if let Some(text) = trimmed {
                reply = text;
            }
        }
    }
    Ok(reply)
}

/// Claude names a project dir after the absolute cwd with `/` replaced by `-`: `<home encoded>-git-work-x` is `~/git/work/x`.
/// Lossy, since a `-` inside a segment also becomes `/`, which is fine for a listing and is what the fixtures pin.
pub fn decode_project_slug(slug: &str, home: &str) -> String {
    let encoded = home.replace('/', "-");
    match slug.strip_prefix(&encoded) {
        Some(rest) => format!("~{}", rest.replace('-', "/")),
        None => slug.replace('-', "/"),
    }
}

/// Every transcript worth listing, newest first, ties in the order the directories are walked.
pub fn collect(cx: &Context) -> Vec<SessionRow> {
    let mut rows = Vec::new();
    for account in discover_accounts(cx) {
        let Ok(projects) = read_dir_sorted(&account.dir) else {
            continue;
        };
        for project in projects.iter().filter_map(utf8_name) {
            let dir = node::join(&account.dir, &project);
            let Ok(entries) = read_dir_sorted(&dir) else {
                continue;
            };
            for entry in &entries {
                let Some(name) = utf8_name(entry) else {
                    continue;
                };
                let Some(id) = name.strip_suffix(".jsonl") else {
                    continue;
                };
                if !entry.file_type().is_ok_and(|t| t.is_file()) {
                    continue;
                }
                let file = node::join(&dir, &name);
                let Ok(meta) = fs::metadata(&file) else {
                    continue;
                };
                if meta.len() < MIN_TRANSCRIPT_BYTES {
                    continue;
                }
                rows.push(SessionRow {
                    id: id.to_owned(),
                    account: account.name.clone(),
                    project: decode_project_slug(&project, &cx.home),
                    file,
                    mtime_ms: node::mtime_ms(&meta),
                });
            }
        }
    }
    rows.sort_by_key(|row| std::cmp::Reverse(row.mtime_ms));
    rows
}

/// Find one session by id prefix, newest first.
pub fn find_by_prefix(cx: &Context, prefix: &str) -> Option<SessionRow> {
    collect(cx)
        .into_iter()
        .find(|row| row.id.starts_with(prefix))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Scratch;

    fn transcript(scratch: &Scratch, lines: &[&str]) -> String {
        let file = scratch.path().join("t.jsonl");
        fs::write(&file, lines.join("\n") + "\n").unwrap();
        file.to_str().unwrap().to_owned()
    }

    fn reply(text: &str) -> String {
        format!(
            r#"{{"type":"assistant","message":{{"content":[{{"type":"text","text":"{text}"}}]}}}}"#
        )
    }

    fn exact(line: &str) -> Option<json::Value> {
        json::parse_exact(line).map(|exact| exact.value)
    }

    #[test]
    fn the_reading_decides_what_a_lone_surrogate_in_the_reply_is() {
        let scratch = Scratch::new();
        let file = transcript(&scratch, &[&reply("  a\\ud83d  ")]);
        assert_eq!(
            last_assistant_reply(&file, json::parse),
            Ok(json::Value::String("a\u{fffd}".into()))
        );
        assert_eq!(
            last_assistant_reply(&file, exact),
            Ok(json::Value::Units(vec![0x61, 0xd83d]))
        );
        assert_eq!(last_assistant_text(&file), Ok("a\u{fffd}".to_owned()));
    }

    #[test]
    fn the_last_non_blank_text_is_the_reply_whatever_the_reading() {
        let scratch = Scratch::new();
        let file = transcript(
            &scratch,
            &[
                &reply("first"),
                r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"x"},{"type":"text","text":"  the \ud83d\ude00 pair  "},{"type":"text","text":"   "}]}}"#,
                r#"{"type":"user","message":{"content":"hello"}}"#,
                "not json \"assistant\"",
            ],
        );
        for read in [json::parse as fn(&str) -> Option<json::Value>, exact] {
            assert_eq!(
                last_assistant_reply(&file, read),
                Ok(json::Value::String("the 😀 pair".into()))
            );
        }
    }

    #[test]
    fn no_text_is_the_empty_string_and_an_unreadable_file_is_the_failure_node_would_print() {
        let scratch = Scratch::new();
        let file = transcript(
            &scratch,
            &[r#"{"type":"user","message":{"content":"hello"}}"#],
        );
        for read in [json::parse as fn(&str) -> Option<json::Value>, exact] {
            assert_eq!(
                last_assistant_reply(&file, read),
                Ok(json::Value::String(String::new()))
            );
        }
        assert_eq!(last_assistant_text(&file), Ok(String::new()));
        let missing = scratch.path().join("missing.jsonl");
        let failure = last_assistant_reply(missing.to_str().unwrap(), exact).unwrap_err();
        assert!(
            failure.starts_with("ENOENT: no such file or directory, stat"),
            "{failure}"
        );
    }

    #[test]
    fn a_line_cut_through_an_emoji_is_skipped_and_the_lines_around_it_are_kept() {
        // Claude Code before 2.1.309 cut long tool output previews between the bytes of an emoji; those transcripts stay broken on disk.
        let scratch = Scratch::new();
        let file = scratch.path().join("cut.jsonl");
        let mut bytes = Vec::new();
        bytes.extend_from_slice(br#"{"type":"user","message":{"content":"first prompt"}}"#);
        bytes.push(b'\n');
        bytes.extend_from_slice(
            br#"{"type":"assistant","message":{"content":[{"type":"text","text":"cut "#,
        );
        bytes.extend_from_slice(&"\u{1F600}".as_bytes()[..2]);
        bytes.push(b'\n');
        bytes.extend_from_slice(reply("last answer").as_bytes());
        bytes.push(b'\n');
        fs::write(&file, bytes).unwrap();
        let file = file.to_str().unwrap();
        assert_eq!(first_prompt(file), Ok("first prompt".to_owned()));
        assert_eq!(last_assistant_text(file), Ok("last answer".to_owned()));
    }
}
