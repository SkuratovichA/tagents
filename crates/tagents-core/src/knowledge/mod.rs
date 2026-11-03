//! The knowledge package in Rust: the index, the search, the usage store and the MCP tools over them.

pub mod args;
pub mod daemon;
pub mod doc;
pub mod front_matter;
pub mod index;
pub mod join;
pub mod mcp;
pub mod paths;
pub mod search;
pub mod serve;
pub mod socket;
pub mod tools;
pub mod usage;

use std::{ffi::OsString, process::ExitCode};

use crate::mcp::server::{Config, Identity, SHUTDOWN_MARGIN};
use crate::{mcp::run::KILL_GRACE, sessions::exit};

/// What the verbs of this module say about how they are used.
pub(crate) const USAGE: &str = "usage: tagents-core knowledge mcp | join | serve [--idle SECONDS] [--foreground] [--socket PATH]\n";

/// How a knowledge server answers and ends, whether it serves a connection of the shared daemon or the stdio of one session.
pub(crate) const SERVER: Config = Config {
    identity: Identity::KNOWLEDGE,
    kill_grace: KILL_GRACE,
    shutdown_margin: SHUTDOWN_MARGIN,
};

/// The verbs of `tagents-core knowledge` that this binary serves: each streams or runs until stopped, so the front door serves them in an arm of its own and hands every other word after `knowledge` to the node CLI.
pub const VERBS: &[&[&str]] = &[
    &["knowledge", "mcp"],
    &["knowledge", "serve"],
    &["knowledge", "join"],
];

/// Runs the verb named by the first of `args` (the words after `knowledge`) and returns its exit code. `mcp` ignores every word after it, as `tagents-knowledge mcp` does; any other word is a usage error.
pub fn status(args: &[OsString]) -> u8 {
    let rest = args.get(1..).unwrap_or_default();
    match args.first().and_then(|word| word.to_str()) {
        Some("mcp") => mcp::run(),
        Some("serve") => serve::run(rest),
        Some("join") => join::run(rest),
        _ => {
            eprint!("{USAGE}");
            exit::USAGE
        }
    }
}

/// `status` as the exit code of the process.
pub fn run(args: &[OsString]) -> ExitCode {
    ExitCode::from(status(args))
}
