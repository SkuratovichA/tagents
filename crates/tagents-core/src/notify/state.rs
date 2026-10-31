//! What the hook publishes next to the events file and the notify daemon reads back (`agent-state.ts` of `packages/core`): one row per pane or session in `<state dir>/<key>.tsv`, the history of starts in `history.tsv`, and the names the owner typed in `labels.tsv`. A reader here never fails: a missing directory or file is no rows and no labels, and a line that does not parse is skipped.
//!
//! The rows carry only the columns the daemon reads. The columns past the sixth are the account (kept apart from its absence: a row with six fields says nothing about the account, which is not an empty one), and the pid, log file, label and parent of a headless session, which only the node driver and the dashboard read, so they are not parsed here.

use std::collections::HashMap;
use std::fs;

use crate::{js, node};

#[cfg(test)]
mod tests;

/// What a row says its session is doing. `Subdone` is a subagent that finished; the rest is node's `SessionState`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowState {
    New,
    Working,
    Blocked,
    Done,
    Gone,
    Subdone,
}

impl RowState {
    fn parse(name: &str) -> Option<Self> {
        Some(match name {
            "new" => Self::New,
            "working" => Self::Working,
            "blocked" => Self::Blocked,
            "done" => Self::Done,
            "gone" => Self::Gone,
            "subdone" => Self::Subdone,
            _ => return None,
        })
    }
}

/// One `<key>.tsv` of the state directory, as node's `AgentStateRow` has it for the columns the daemon reads.
#[derive(Debug, Clone, PartialEq)]
pub struct AgentStateRow {
    /// The file's name without `.tsv`: a pane number, or `s-<session id>`.
    pub key: String,
    /// Epoch SECONDS, where `AgentEvent::at` is milliseconds.
    pub at: f64,
    pub state: RowState,
    pub session_id: String,
    pub cwd: String,
    pub transcript: String,
    /// What the session is doing, already clipped by the hook.
    pub detail: String,
    /// `CLAUDE_CONFIG_DIR` of the session: empty for the default account, `None` for a row written before the column existed.
    pub config_dir: Option<String>,
}

/// `stateDir()`: `$TA_STATE_DIR` when it is set to something that is not white space, else `~/.claude/agent-state`.
pub fn state_dir() -> String {
    let from_env = std::env::var_os("TA_STATE_DIR").map(|v| v.to_string_lossy().into_owned());
    state_dir_in(from_env.as_deref(), &node::homedir())
}

fn state_dir_in(from_env: Option<&str>, home: &str) -> String {
    match from_env {
        Some(dir) if !js::trim(dir).is_empty() => dir.to_owned(),
        _ => node::join(home, ".claude/agent-state"),
    }
}

/// `/^(?:\d+|s-[\w.-]+)$/`: the digits of a pane id, or `s-` and the characters of a session id.
fn is_key(key: &str) -> bool {
    match key.strip_prefix("s-") {
        Some(sid) => {
            !sid.is_empty()
                && sid
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
        }
        None => !key.is_empty() && key.bytes().all(|b| b.is_ascii_digit()),
    }
}

/// `parseStateLine`: `None` for a line with fewer than six fields, a time that is not a finite number or a state the hook does not write.
pub fn parse_state_line(key: &str, line: &str) -> Option<AgentStateRow> {
    let line = line.strip_suffix('\n').unwrap_or(line);
    let fields: Vec<&str> = line.split('\t').collect();
    let [at, state, session_id, cwd, transcript, detail, rest @ ..] = fields.as_slice() else {
        return None;
    };
    let at = js::number(at);
    let state = RowState::parse(state)?;
    if !at.is_finite() {
        return None;
    }
    Some(AgentStateRow {
        key: key.to_owned(),
        at,
        state,
        session_id: (*session_id).to_owned(),
        cwd: (*cwd).to_owned(),
        transcript: (*transcript).to_owned(),
        detail: (*detail).to_owned(),
        config_dir: rest.first().map(|dir| (*dir).to_owned()),
    })
}

/// A file read as `readFileSync(path, 'utf8')` does: whole, and a byte sequence that is not UTF-8 becomes U+FFFD.
fn read_text(path: &str) -> Option<String> {
    fs::read(path)
        .ok()
        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
}

/// `readAgentState`: every current record, newest first. A missing directory is no agents. Rows with the same time keep the order of their names, which is the order node's `readdirSync` lists them in (libuv sorts by name).
pub fn read_agent_state(dir: &str) -> Vec<AgentStateRow> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    // A name that is not UTF-8 cannot be a key, so it is dropped here.
    let mut names: Vec<String> = entries
        .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
        .collect();
    names.sort();
    let mut rows: Vec<AgentStateRow> = names
        .iter()
        .filter_map(|name| {
            let key = name.strip_suffix(".tsv").filter(|key| is_key(key))?;
            let text = read_text(&node::join(dir, name))?;
            parse_state_line(key, text.split('\n').next().unwrap_or(""))
        })
        .collect();
    rows.sort_by(|a, b| b.at.partial_cmp(&a.at).unwrap_or(std::cmp::Ordering::Equal));
    rows
}

/// `labelsBySession`: session id to the label it was started with, from `history.tsv`; the latest line wins. A history line is `at, kind, session id, pane, label, cwd` and more; one with fewer than six fields, a time that is not finite or a kind other than `start`, `turn` and `end` is skipped.
pub fn labels_by_session(dir: &str) -> HashMap<String, String> {
    let mut labels = HashMap::new();
    let Some(text) = read_text(&node::join(dir, "history.tsv")) else {
        return labels;
    };
    for line in text.split('\n').filter(|line| !line.is_empty()) {
        let fields: Vec<&str> = line.split('\t').collect();
        let [at, kind, session_id, _pane, label, _cwd, ..] = fields.as_slice() else {
            continue;
        };
        if !js::number(at).is_finite() || !matches!(*kind, "start" | "turn" | "end") {
            continue;
        }
        if !session_id.is_empty() && !label.is_empty() {
            labels.insert((*session_id).to_owned(), (*label).to_owned());
        }
    }
    labels
}

/// `readLabels`: the names typed on ctrl-r, `labels.tsv`, key to name, where the key is a session id or a pane id (`%12`). The shell owns the file and reads one key as `label_of` of `lib/tagents/names.sh` does: the second field of the first line with that key, even when it is empty, so an empty name is the answer for its key and a later line cannot replace it; whoever reads the map treats an empty name as no label.
pub fn read_labels(dir: &str) -> HashMap<String, String> {
    let mut labels = HashMap::new();
    let Some(text) = read_text(&node::join(dir, "labels.tsv")) else {
        return labels;
    };
    for line in text.split('\n') {
        let mut fields = line.split('\t');
        let key = fields.next().unwrap_or("");
        let name = fields.next().unwrap_or("");
        if !key.is_empty() {
            labels
                .entry(key.to_owned())
                .or_insert_with(|| name.to_owned());
        }
    }
    labels
}
