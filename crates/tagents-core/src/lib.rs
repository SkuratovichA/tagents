//! The `tagents-core` front door and the verbs it serves itself.
//!
//! `js`, `json`, `date` and `node` repeat the few behaviours of JavaScript and of node's `fs` and `path` that change the bytes the node CLI prints; each says which, and `tests/rust-parity.sh` compares the two programs on them.

pub mod date;
pub mod front_door;
pub mod js;
pub mod json;
pub mod mcp;
pub mod node;
pub mod sessions;
pub mod transcripts;
