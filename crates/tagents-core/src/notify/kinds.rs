//! What an agent event means to a person: which kind of notice it asks for, and what else it does to the session's notice and cache deadline (`packages/notify/src/kinds.ts`).

use super::events::{AgentEvent, AgentHookEvent};
use crate::js;

/// The notice an event asks for, before the options decide whether it is wanted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum NoticeKind {
    Question,
    Permission,
    TurnDone,
    CacheExpiring,
    SessionEnd,
}

impl NoticeKind {
    /// node's string for the kind, as the log, the options and the helper's input spell it.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Question => "question",
            Self::Permission => "permission",
            Self::TurnDone => "turn_done",
            Self::CacheExpiring => "cache_expiring",
            Self::SessionEnd => "session_end",
        }
    }
}

/// What one event means.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Verdict {
    /// The notice this event asks for, before the options decide whether it is wanted.
    pub kind: Option<NoticeKind>,
    /// A question that is a plan waiting for approval, which has a subtitle of its own.
    pub plan: bool,
    /// The session is waiting on the person now: the prompt cache's clock started.
    pub arms: bool,
    /// The notice this session has up is stale.
    pub withdraw: bool,
    /// The session is working again or gone: no cache deadline applies.
    pub cancel: bool,
}

impl Verdict {
    const NOTHING: Verdict = Verdict {
        kind: None,
        plan: false,
        arms: false,
        withdraw: false,
        cancel: false,
    };

    /// No notice, and the session's notice and deadline are over.
    const GONE: Verdict = Verdict {
        withdraw: true,
        cancel: true,
        ..Verdict::NOTHING
    };

    fn asks(kind: NoticeKind) -> Verdict {
        Verdict {
            kind: Some(kind),
            ..Verdict::NOTHING
        }
    }

    /// A notice that also starts the prompt cache's clock.
    fn arming(kind: NoticeKind) -> Verdict {
        Verdict {
            arms: true,
            ..Verdict::asks(kind)
        }
    }
}

/// The tools whose `PreToolUse` is a question put to the person, and whose `PostToolUse` is the answer.
pub const QUESTION_TOOLS: [&str; 2] = ["AskUserQuestion", "ExitPlanMode"];

fn is_question_tool(tool: &str) -> bool {
    QUESTION_TOOLS.contains(&tool)
}

/// Notices come only from agents: a session that sits in a tmux pane of its own, whose key is that pane's number. A key of `s-<id>` is a session with no pane of its own (a child `claude -p` an agent started, or a headless session), and none of those is ever counted, whatever the options say. An Agent-tool subagent is no session at all: its events carry its agent id under the agent's own key.
pub fn counts_session(key: &str) -> bool {
    !key.starts_with("s-")
}

/// Claude Code says "waiting for your input" about 60 seconds after a Stop, and Stop already told the person. `/waiting for your input/i` folds ASCII case only: a non-ASCII character never matches an ASCII one without the `u` flag.
fn is_waiting(text: &str) -> bool {
    text.to_ascii_lowercase().contains("waiting for your input")
}

fn from_notification(e: &AgentEvent) -> Option<Verdict> {
    match e.sub.as_str() {
        "elicitation_dialog" => return Some(Verdict::arming(NoticeKind::Question)),
        "permission_prompt" => return Some(Verdict::arming(NoticeKind::Permission)),
        "idle_prompt" | "auth_success" => return None,
        _ => {}
    }
    if is_waiting(&e.text) {
        return None;
    }
    // A subtype this code has not met, with words to show: Claude Code adds notification types over time, and a prompt for the person is the likelier reading than silence.
    if js::trim(&e.text).is_empty() {
        None
    } else {
        Some(Verdict::arming(NoticeKind::Permission))
    }
}

/// The verdict on one event, or `None` when it is nothing to notify and nothing to track.
pub fn classify(e: &AgentEvent) -> Option<Verdict> {
    if !counts_session(&e.key) {
        return None;
    }
    match e.event {
        AgentHookEvent::PreToolUse => is_question_tool(&e.tool).then(|| Verdict {
            plan: e.tool == "ExitPlanMode",
            ..Verdict::arming(NoticeKind::Question)
        }),
        // The person answered the question or the plan: the session works again.
        AgentHookEvent::PostToolUse => is_question_tool(&e.tool).then_some(Verdict::GONE),
        AgentHookEvent::Notification => from_notification(e),
        // A Stop with an agent id is a subagent's own turn ending, and the agent that started it is still working.
        AgentHookEvent::Stop => e
            .agent_id
            .is_empty()
            .then(|| Verdict::arming(NoticeKind::TurnDone)),
        // A subagent finishing is a step in its agent's turn: the agent's own Stop says when the turn is over.
        AgentHookEvent::SubagentStop => None,
        AgentHookEvent::SessionEnd => Some(Verdict {
            withdraw: true,
            cancel: true,
            ..Verdict::asks(NoticeKind::SessionEnd)
        }),
        // A new prompt, or a new session in the pane, makes whatever the old one asked moot.
        AgentHookEvent::UserPromptSubmit | AgentHookEvent::SessionStart => Some(Verdict::GONE),
    }
}

#[cfg(test)]
mod tests;
