//! What an agent event means to a person (`packages/notify/src/kinds.ts`).

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
