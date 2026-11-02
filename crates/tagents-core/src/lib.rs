//! The `tagents-core` front door and the verbs it serves itself.
//!
//! `js`, `json`, `date` and `node` repeat the few behaviours of JavaScript and of node's `fs` and `path` that change the bytes the node CLI prints; each says which, and `tests/rust-parity.sh` compares the two programs on them.

pub mod args;
pub mod child;
pub mod date;
pub mod doctor;
pub mod ending;
pub mod front_door;
pub mod host;
pub mod js;
pub mod json;
pub mod knowledge;
pub mod mcp;
pub mod messages;
pub mod node;
pub mod notify;
pub mod plugin;
pub mod session;
pub mod sessions;
mod sync;
#[cfg(test)]
mod testing;
pub mod toml_js;
pub mod transcripts;
pub mod watch;
