//! What a notice says: whose it is, what happened, and the one line that tells you whether to go and look (`packages/notify/src/compose.ts`).

use std::collections::HashMap;

use super::events::AgentEvent;
use super::kinds::NoticeKind;
use super::phrases::Phrases;
use crate::{js, node, transcripts};

const BODY_CLIP: usize = 200;

/// The pane title without the status glyph Claude Code puts in front of it: the Rust copy of `untitle_of` (`lib/tagents/names.sh:82`), whose rule is the awk `AWK_UNTITLE` (`lib/tagents/names.sh:64`). The first word, with the spaces after it, is dropped only when it is exactly one code point and that is an ASCII character other than a letter or digit, one in U+2000-U+2BFF, or one in U+1F000-U+1FFFF. Every other title is left alone, so `Search index rebuild` keeps all three words and `я иду` keeps its one-letter word.
pub fn untitle(title: &str) -> &str {
    let Some(space) = title.find(' ').filter(|&at| at >= 1) else {
        return title;
    };
    let mut chars = title[..space].chars();
    let (Some(first), None) = (chars.next(), chars.next()) else {
        return title;
    };
    let cp = u32::from(first);
    let glyph = if cp < 0x80 {
        !first.is_ascii_alphanumeric()
    } else {
        (0x2000..=0x2bff).contains(&cp) || (0x1f000..=0x1ffff).contains(&cp)
    };
    if glyph {
        title[space..].trim_start_matches(' ')
    } else {
        title
    }
}

/// What `agent_name` looks a name up by.
pub struct NameInputs<'a> {
    pub session_id: &'a str,
    pub pane: &'a str,
    pub pane_title: &'a str,
    pub label: &'a str,
    pub cwd: &'a str,
    pub hostname: &'a str,
    pub labels: &'a HashMap<String, String>,
}

/// The name the dashboard shows for this agent, in the dashboard's order (`nameof`, `lib/tagents/list.sh:351`): the name typed on ctrl-r for the session, else for the pane, else the pane title without its glyph; a headless session has no title, so its `TA_LABEL`; and the directory's name when that is still empty or is only the machine's hostname, which is what a terminal that was never given a title shows.
pub fn agent_name(o: &NameInputs) -> String {
    let by_session = (!o.session_id.is_empty())
        .then(|| o.labels.get(o.session_id))
        .flatten();
    let by_pane = (!o.pane.is_empty()).then(|| o.labels.get(o.pane)).flatten();
    let mut name = by_session
        .or(by_pane)
        .map_or_else(|| untitle(o.pane_title), String::as_str);
    if name.is_empty() {
        name = o.label;
    }
    // The dashboard compares with `hostname -s`.
    let short_host = o.hostname.split('.').next().unwrap_or("");
    if name.is_empty() || name == o.hostname || name == short_host {
        name = node::basename(o.cwd);
    }
    name.to_owned()
}

/// `text` as it is when it has at most `max` code points, else its first `max - 1` and an ellipsis.
fn clip(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_owned();
    }
    let kept: String = text.chars().take(max - 1).collect();
    format!("{kept}…")
}

/// The last answer of a transcript, or nothing when there is none or the file cannot be read: a transcript that was deleted or moved while a notice was being composed is an ordinary event, and the notice is worth posting without its first line.
fn last_answer(file: &str) -> String {
    transcripts::last_assistant_text(file).unwrap_or_default()
}

fn first_line(text: &str) -> &str {
    text.split('\n')
        .map(js::trim)
        .find(|line| !line.is_empty())
        .unwrap_or("")
}

fn subtitle_for(kind: NoticeKind, plan: bool, p: &Phrases) -> &'static str {
    match kind {
        NoticeKind::Question if plan => p.kind_plan,
        NoticeKind::Question => p.kind_question,
        NoticeKind::Permission => p.kind_permission,
        NoticeKind::TurnDone => p.kind_turn_done,
        NoticeKind::CacheExpiring => p.kind_cache_expiring,
        NoticeKind::SessionEnd => p.kind_session_end,
    }
}

/// What a notice needs beyond its event.
#[derive(Debug, Clone, Copy, Default)]
pub struct Extra {
    /// A question that is a plan waiting for approval.
    pub plan: bool,
    /// Whole minutes the session has been idle, for a cache notice; missing is 0.
    pub idle_min: Option<f64>,
    /// Whole minutes the prompt cache has left, for a cache notice; missing is 0.
    pub left_min: Option<f64>,
}

fn body_for(kind: NoticeKind, e: &AgentEvent, extra: &Extra, p: &Phrases) -> String {
    let text_or = |fallback: &str| {
        if e.text.is_empty() {
            fallback.to_owned()
        } else {
            e.text.clone()
        }
    };
    match kind {
        NoticeKind::Question => text_or(p.question_body),
        NoticeKind::Permission => text_or(p.permission_body),
        // The event's own text comes first: Claude Code runs the Stop hook before it writes the final assistant record, so the transcript's last answer at that moment can be an older one.
        NoticeKind::TurnDone => {
            if !e.text.is_empty() {
                return clip(&e.text, BODY_CLIP);
            }
            let answer = if e.transcript.is_empty() {
                String::new()
            } else {
                last_answer(&e.transcript)
            };
            let line = first_line(&answer);
            if line.is_empty() {
                p.turn_done_body.to_owned()
            } else {
                clip(line, BODY_CLIP)
            }
        }
        NoticeKind::CacheExpiring => {
            p.cache_body(extra.idle_min.unwrap_or(0.0), extra.left_min.unwrap_or(0.0))
        }
        NoticeKind::SessionEnd => {
            if e.sub.is_empty() {
                p.session_end_body.to_owned()
            } else {
                e.sub.clone()
            }
        }
    }
}

/// The title, subtitle and body of one notice.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Composed {
    pub title: String,
    pub subtitle: String,
    pub body: String,
}

/// Title, subtitle and body of one notice. `name` is already resolved (see `agent_name`); the subtitle names the project too unless the name already is it.
pub fn compose(
    kind: NoticeKind,
    e: &AgentEvent,
    name: &str,
    extra: &Extra,
    p: &Phrases,
) -> Composed {
    let project = if e.cwd.is_empty() {
        ""
    } else {
        node::basename(&e.cwd)
    };
    let phrase = subtitle_for(kind, extra.plan, p);
    Composed {
        title: name.to_owned(),
        subtitle: if !project.is_empty() && project != name {
            format!("{phrase} · {project}")
        } else {
            phrase.to_owned()
        },
        body: body_for(kind, e, extra, p),
    }
}

#[cfg(test)]
mod tests;
