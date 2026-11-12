//! The knowledge package in Rust: the index, the search, the usage store and the MCP tools over them.

pub mod cli;
pub mod daemon;
pub mod doc;
pub mod front_matter;
pub mod index;
pub mod join;
pub mod lint;
pub mod mcp;
pub mod paths;
pub mod search;
pub mod serve;
pub mod socket;
pub mod toc;
pub mod tools;
pub mod usage;

use std::{ffi::OsString, process::ExitCode};

use tagents_core::mcp::server::{Config, Identity, SHUTDOWN_MARGIN};
use tagents_core::{
    front_door,
    mcp::run::KILL_GRACE,
    messages::{Locale, Texts},
    node,
    sessions::{Output, exit},
};

use paths::Env;

/// The verbs of `okb` as data, in the shape of an entry of the plugin's contract: what `okb --spec` prints. A test pins it to the verbs the program serves.
pub const SPEC: &str = include_str!("../../../../spec/cli/okb.json");

/// What `okb --version` prints: the version of the workspace, which is the version of the release the binary comes from.
const VERSION_LINE: &str = concat!("okb ", env!("CARGO_PKG_VERSION"), "\n");

/// What the verbs that run until stopped say about how they are used.
pub(crate) const USAGE: &str =
    "usage: okb mcp | join | serve [--idle SECONDS] [--foreground] [--socket PATH]\n";

/// How a knowledge server answers and ends, whether it serves a connection of the shared daemon or the stdio of one session.
pub(crate) const SERVER: Config = Config {
    identity: Identity::KNOWLEDGE,
    kill_grace: KILL_GRACE,
    shutdown_margin: SHUTDOWN_MARGIN,
};

/// The catalogue of the sentences `okb` says, in `locale`: the verbs that read the folder, `serve` and the usage text.
pub fn texts(locale: Locale) -> Result<Texts, serde_json::Error> {
    Texts::from_json(locale, include_str!("texts.json"))
}

/// Runs the verb named by the first of `args` and returns its exit code. `mcp` ignores every word after it; `serve` and `join` read theirs; the seven verbs that read the folder are in `cli`; no word is the usage text.
pub fn status(args: &[OsString]) -> u8 {
    if let [only] = args {
        let printed = match only.to_str() {
            Some("--version") => Some(VERSION_LINE),
            Some("--spec") => Some(SPEC),
            _ => None,
        };
        if let Some(text) = printed {
            front_door::print(&Output {
                stdout: text.to_owned(),
                stderr: String::new(),
                code: exit::OK,
            });
            return exit::OK;
        }
    }
    let rest = args.get(1..).unwrap_or_default();
    let spelled = args.first().map(|word| word.to_string_lossy().into_owned());
    let word = spelled.as_deref();
    match word {
        Some("mcp") => return mcp::run(),
        Some("serve") => return serve::run(rest),
        Some("join") => return join::run(rest),
        _ => {}
    }
    let texts = match texts(Locale::current()) {
        Ok(texts) => texts,
        Err(error) => {
            eprintln!("okb: the texts do not load: {error}");
            return exit::ERROR;
        }
    };
    let out = match word {
        Some(verb) if cli::VERBS.contains(&verb) => {
            cli::answer(verb, rest, &texts, Env::from_process(), node::now_ms())
        }
        _ => cli::usage_answer(word, &texts),
    };
    front_door::print(&out);
    out.code
}

/// `status` as the exit code of the process.
pub fn run(args: &[OsString]) -> ExitCode {
    ExitCode::from(status(args))
}
