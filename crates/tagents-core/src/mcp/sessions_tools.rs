//! `sessions_recent` and `sessions_search`: the two tools of the tagents server that are not a verb of any CLI spec. They answer with the text `tagents-core sessions` prints, from the transcripts of every Claude account on the machine.
//!
//! They were tools of the knowledge server until the knowledge base became okb, which keeps no sessions; their names, schemas and answers are the ones they had there. The list is `sessions_tools.json` and the checks of a call's arguments are made against its schemas (`args`).

use std::sync::OnceLock;

use serde_json::{Map, Value};

use super::args;
use super::rpc::CallResult;
use crate::{js, node, sessions, transcripts::Context};

/// How many sessions `sessions_recent` lists when it is not told.
const DEFAULT_SESSIONS: f64 = 15.0;

/// The entries of `tools/list` of these two tools.
pub fn listing() -> &'static [Value] {
    static LIST: OnceLock<Vec<Value>> = OnceLock::new();
    LIST.get_or_init(|| {
        serde_json::from_str(include_str!("sessions_tools.json")).unwrap_or_default()
    })
}

/// The two tools, over the context a call reads the transcripts by: the home, the accounts and the clock, taken when the call is made.
pub struct SessionTools {
    context: Box<dyn Fn() -> Context + Send + Sync>,
}

impl SessionTools {
    /// The tools of this process: its home, its `CLAUDE_HOMES` and its clock.
    pub fn new() -> SessionTools {
        SessionTools::with_context(|| Context {
            home: node::homedir(),
            claude_homes: node::env_text("CLAUDE_HOMES"),
            now_ms: node::now_ms(),
        })
    }

    pub fn with_context(context: impl Fn() -> Context + Send + Sync + 'static) -> SessionTools {
        SessionTools {
            context: Box::new(context),
        }
    }

    /// Whether `name` is one of the two.
    pub fn has(name: &str) -> bool {
        listing().iter().any(|entry| entry["name"] == name)
    }

    /// The answer to a call of one of the two, a refusal of its arguments in the words the SDK writes them, or `None` for a name that is not theirs.
    pub fn call(&self, name: &str, args: Option<&Map<String, Value>>) -> Option<CallResult> {
        let entry = listing().iter().find(|entry| entry["name"] == name)?;
        if let Some(refusal) = args::refusal(name, &entry["inputSchema"], args) {
            return Some(CallResult::fail(refusal));
        }
        let empty = Map::new();
        let args = args.unwrap_or(&empty);
        let context = (self.context)();
        let answer = if name == "sessions_recent" {
            sessions::recent(
                &context,
                args::number(args, "limit").unwrap_or(DEFAULT_SESSIONS),
            )
        } else {
            let words: Vec<String> = js::split_space(args::text(args, "words"))
                .into_iter()
                .filter(|word| !word.is_empty())
                .map(str::to_owned)
                .collect();
            sessions::search(&context, &words)
        };
        Some(match answer {
            Ok(text) => CallResult::ok(text),
            Err(text) => CallResult::fail(text),
        })
    }
}

impl Default for SessionTools {
    fn default() -> SessionTools {
        SessionTools::new()
    }
}
