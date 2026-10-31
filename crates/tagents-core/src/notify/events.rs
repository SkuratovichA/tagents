//! Event lines and the follower of the events file (`parseEventLine` and `followAgentEvents` of `packages/core/src/agent-events.ts`).

/// The hook events the stream carries. `PreToolUse` and `PostToolUse` come only for the two tools that put a question to the person, `AskUserQuestion` and `ExitPlanMode`: the `PostToolUse` is the answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AgentHookEvent {
    SessionStart,
    UserPromptSubmit,
    PreToolUse,
    PostToolUse,
    Notification,
    Stop,
    SubagentStop,
    SessionEnd,
}

impl AgentHookEvent {
    /// The hook's name for the event, as the events file spells it.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::SessionStart => "SessionStart",
            Self::UserPromptSubmit => "UserPromptSubmit",
            Self::PreToolUse => "PreToolUse",
            Self::PostToolUse => "PostToolUse",
            Self::Notification => "Notification",
            Self::Stop => "Stop",
            Self::SubagentStop => "SubagentStop",
            Self::SessionEnd => "SessionEnd",
        }
    }

    /// The event a name stands for, or `None` for a name the hook does not write.
    pub fn parse(name: &str) -> Option<Self> {
        Some(match name {
            "SessionStart" => Self::SessionStart,
            "UserPromptSubmit" => Self::UserPromptSubmit,
            "PreToolUse" => Self::PreToolUse,
            "PostToolUse" => Self::PostToolUse,
            "Notification" => Self::Notification,
            "Stop" => Self::Stop,
            "SubagentStop" => Self::SubagentStop,
            "SessionEnd" => Self::SessionEnd,
            _ => return None,
        })
    }
}

/// One line of `events.tsv`, as node's `AgentEvent` has it.
#[derive(Debug, Clone, PartialEq)]
pub struct AgentEvent {
    /// Epoch milliseconds: `Number(<first field>) * 1000`, so it may have a fraction.
    pub at: f64,
    pub event: AgentHookEvent,
    /// The pane number without its `%`, or `s-<session id>` for a session with no pane.
    pub key: String,
    pub session_id: String,
    /// Empty for the main agent.
    pub agent_id: String,
    /// `%12`, or empty when the session has no pane.
    pub pane: String,
    pub cwd: String,
    pub transcript: String,
    /// `CLAUDE_CONFIG_DIR` of the session, empty for the default account.
    pub config_dir: String,
    pub tool: String,
    pub sub: String,
    pub text: String,
    /// `TA_LABEL`.
    pub label: String,
}
