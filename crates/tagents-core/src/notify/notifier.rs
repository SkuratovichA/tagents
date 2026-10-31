//! The boundary between the engine and whatever puts a banner on a screen, as `packages/notify/src/notifier.ts` draws it: the engine depends on `Notifier` and on nothing platform-specific.

use crate::notify::kinds::NoticeKind;

/// What a click on a banner runs: the absolute program first, or nothing for the terminal only.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ClickAction {
    pub argv: Vec<String>,
    /// In the order written, as the keys of node's object, since the helper's input is compared byte for byte.
    pub env: Vec<(String, String)>,
}

/// One banner. The daemon posts only what an agent's event asks for; node's `message` kind belongs to `tagents notify send`, which stays node.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Notice {
    pub id: String,
    pub thread: String,
    pub kind: NoticeKind,
    pub title: String,
    pub subtitle: String,
    pub body: String,
    pub click: ClickAction,
    /// `None` where node leaves the key out.
    pub terminal_pid: Option<u32>,
    /// `None` where node leaves the key out.
    pub skip_if_frontmost: Option<bool>,
}

/// What a post did: shown, or not shown and why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PostResult {
    pub shown: bool,
    pub why: Option<String>,
}

/// A backend. An `Err` carries the text node's `describe(err)` gives for the error the backend threw, which the engine writes into its log line.
pub trait Notifier {
    fn name(&self) -> &str;
    fn post(&mut self, notice: &Notice) -> Result<PostResult, String>;
    fn withdraw(&mut self, id: &str) -> Result<(), String>;
}
