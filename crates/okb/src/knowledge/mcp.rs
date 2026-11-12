//! `tagents-core knowledge mcp`: the knowledge server of one session, in this process, on its standard streams. It is what `join` falls back to when no shared server can be had.

use std::{
    io::{self, Read},
    sync::Arc,
};

use super::{SERVER, paths::Env, tools::KnowledgeTools};
use tagents_core::{node, sessions::exit};

/// Serves the six tools to the client on `input` and this process's stdout until `input` ends, and returns the exit code.
pub fn serve(input: impl Read) -> u8 {
    let tools = Arc::new(KnowledgeTools::new(Env::from_process(), node::now_ms));
    match tagents_core::mcp::serve_stdio(tools, SERVER, input) {
        Ok(()) => exit::OK,
        Err(reason) => {
            eprintln!("tagents-knowledge: {reason}");
            exit::ERROR
        }
    }
}

/// The verb: serves the session on this process's standard input.
pub fn run() -> u8 {
    serve(io::stdin().lock())
}
