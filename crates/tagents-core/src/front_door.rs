//! The `tagents-core` front door.
//!
//! A verb the data file marks `impl: "rust"` is served here; every other word (an unported verb, help, `doctor`, a plugin's verb, a word nobody knows) is handed to the node CLI with the same arguments, environment and stdio, and the exit code is the node CLI's own, because the process is replaced, not waited for.
//! The dispatch is by the first word, so a group of verbs is served wholly by one program: `sessions` and its misspellings behave as they always did, in either implementation.

use std::{
    ffi::{OsStr, OsString},
    io::Write,
    process::ExitCode,
    time::{SystemTime, UNIX_EPOCH},
};

use tagents_spec::Spec;

use crate::{
    mcp, node,
    sessions::{self, Output},
    transcripts::Context,
};

/// Where the node CLI sits below the root of a checkout (or of `$TAGENTS_HOME`, which is one).
const NODE_CLI: &str = "packages/core/dist/cli/main.js";
/// The arguments the front door answers itself, each only when it is the only argument.
const SPEC_FLAG: &str = "--spec";
const VERSION_FLAG: &str = "--version";
/// What `--version` prints: the version of the workspace, which is the version of the release this binary comes from (`.github/scripts/core-release.sh version`).
const VERSION_LINE: &str = concat!("tagents-core ", env!("CARGO_PKG_VERSION"), "\n");

/// One first word the front door serves.
struct Group {
    word: &'static str,
    verbs: &'static [&'static [&'static str]],
    run: fn(&[String], &Context) -> Output,
}

const GROUPS: &[Group] = &[Group {
    word: "sessions",
    verbs: sessions::VERBS,
    run: sessions::run,
}];

/// The first word of the verb that serves a protocol on stdin and stdout until the client is gone: it streams, so it cannot be a `Group` (whose `run` answers with the whole of its output at once), and it has its own arm in `run`.
const MCP: &str = "mcp";
/// The verbs served apart from the groups.
const STREAMING: &[&[&str]] = &[&[MCP]];

/// The data-file entries of the verbs this binary implements, as JSON: what `--spec` prints.
pub fn served_spec() -> Result<String, String> {
    let mut spec =
        Spec::bundled().map_err(|e| format!("the embedded CLI spec does not load: {e}"))?;
    spec.commands.retain(|c| {
        GROUPS
            .iter()
            .flat_map(|g| g.verbs)
            .chain(STREAMING)
            .any(|verb| verb.iter().copied().eq(c.path.iter().map(String::as_str)))
    });
    let mut text = serde_json::to_string_pretty(&spec).map_err(|e| e.to_string())?;
    text.push('\n');
    Ok(text)
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

fn context() -> Context {
    Context {
        home: node::homedir(),
        claude_homes: std::env::var_os("CLAUDE_HOMES").map(|v| v.to_string_lossy().into_owned()),
        now_ms: now_ms(),
    }
}

/// Write what was produced and ignore a reader that went away, as the node CLI does.
fn emit(out: &Output) -> ExitCode {
    let mut stdout = std::io::stdout().lock();
    let _ = stdout.write_all(out.stdout.as_bytes());
    let _ = stdout.flush();
    let mut stderr = std::io::stderr().lock();
    let _ = stderr.write_all(out.stderr.as_bytes());
    let _ = stderr.flush();
    ExitCode::from(out.code)
}

/// Replace this process with the node program at `relative` below the root, given `args`. Only returns when that could not be done, after saying why.
fn exec_node(relative: &str, args: &[OsString]) -> ExitCode {
    match node::exec(relative, args) {
        node::ExecFailure::Missing(why) => {
            eprintln!(
                "tagents-core: cannot find {relative}: {why}; this binary has to stay in <root>/target/<profile>/ of a root where it is built"
            );
            ExitCode::from(sessions::exit::USAGE)
        }
        node::ExecFailure::Run { node, err } => {
            eprintln!("tagents-core: cannot run {}: {err}", node.to_string_lossy());
            ExitCode::from(if err.kind() == std::io::ErrorKind::NotFound {
                sessions::exit::NOT_FOUND
            } else {
                sessions::exit::CANNOT_EXECUTE
            })
        }
    }
}

/// The program: `args` are the words after its name.
pub fn run(args: Vec<OsString>) -> ExitCode {
    if args.len() == 1 && args[0] == OsStr::new(VERSION_FLAG) {
        return emit(&Output {
            stdout: VERSION_LINE.to_owned(),
            stderr: String::new(),
            code: sessions::exit::OK,
        });
    }
    if args.len() == 1 && args[0] == OsStr::new(SPEC_FLAG) {
        return match served_spec() {
            Ok(text) => emit(&Output {
                stdout: text,
                stderr: String::new(),
                code: sessions::exit::OK,
            }),
            Err(message) => emit(&Output {
                stdout: String::new(),
                stderr: format!("tagents-core: {message}\n"),
                code: sessions::exit::USAGE,
            }),
        };
    }
    let first = args.first().and_then(|first| first.to_str());
    if first == Some(MCP) {
        return mcp::run(&args[1..]);
    }
    let group = first.and_then(|first| GROUPS.iter().find(|g| g.word == first));
    match group {
        Some(group) => {
            let rest: Vec<String> = args[1..]
                .iter()
                .map(|a| a.to_string_lossy().into_owned())
                .collect();
            emit(&(group.run)(&rest, &context()))
        }
        None => exec_node(NODE_CLI, &args),
    }
}
