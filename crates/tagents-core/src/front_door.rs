//! The `tagents-core` front door.
//!
//! A verb the data file marks `impl: "rust"` is served here; every other word (an unported verb, help, a plugin's verb, a word nobody knows) is handed to the node CLI with the same arguments, environment and stdio, and the exit code is the node CLI's own, because the process is replaced, not waited for.
//! The dispatch is by the first word, so a group of verbs is served wholly by one program: `sessions` and its misspellings behave as they always did, in either implementation.
//! A group answers every call of its verbs, with `Some`. Only `plugin` may decline, with `None`, for what stays with node: `plugin list`, a bare `plugin` and a word of a plugin. An argument that is not UTF-8 is read with U+FFFD for each bad byte, as the node CLI's `process.argv` does.
//! No word, `help`, `--help` and `-h` print the usage line.

use std::{
    ffi::{OsStr, OsString},
    io::Write,
    process::ExitCode,
};

use tagents_spec::Spec;

use crate::{
    doctor, knowledge, mcp,
    messages::Locale,
    node,
    notify::service,
    plugin, session,
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
    /// `None` hands the call to the node CLI. It is returned before anything is written.
    run: fn(&[String], &Context) -> Option<Output>,
}

const GROUPS: &[Group] = &[
    Group {
        word: "sessions",
        verbs: sessions::VERBS,
        run: |argv, cx| Some(sessions::run(argv, cx)),
    },
    Group {
        word: "plugin",
        verbs: plugin::VERBS,
        run: |argv, _| plugin::run(argv),
    },
    Group {
        word: "session",
        verbs: session::VERBS,
        run: |argv, _| Some(session::run(argv)),
    },
    Group {
        word: "doctor",
        verbs: doctor::VERBS,
        run: |_, _| Some(doctor::run()),
    },
];

/// The first word of the verb that serves a protocol on stdin and stdout until the client is gone: it streams, so it cannot be a `Group` (whose `run` answers with the whole of its output at once), and it has its own arm in `run`.
const MCP: &str = "mcp";
/// The verb that runs the notification service in this process until a signal stops it. It has an arm of its own because it runs until stopped, and it matches both words and nothing after them: the rest of `notify` (`install`, `status`, and a `run` with an argument) is the node CLI's.
const NOTIFY_RUN: &[&str] = &["notify", "run"];
/// The first word of the knowledge verbs, which stream or run until stopped, so they have an arm of their own. Only the words `knowledge::VERBS` names are served; every other word after `knowledge` is the node CLI's.
const KNOWLEDGE: &str = "knowledge";
/// The words that ask for the usage line.
const HELP: &[&str] = &["help", "--help", "-h"];
/// The verbs served apart from the groups.
const STREAMING: &[&[&str]] = &[&[MCP], NOTIFY_RUN];

/// The data-file entries of the verbs this binary implements, as JSON: what `--spec` prints.
pub fn served_spec() -> Result<String, String> {
    let mut spec =
        Spec::bundled().map_err(|e| format!("the embedded CLI spec does not load: {e}"))?;
    spec.commands.retain(|c| {
        GROUPS
            .iter()
            .flat_map(|g| g.verbs)
            .chain(STREAMING)
            .chain(knowledge::VERBS)
            .any(|verb| verb.iter().copied().eq(c.path.iter().map(String::as_str)))
    });
    let mut text = serde_json::to_string_pretty(&spec).map_err(|e| e.to_string())?;
    text.push('\n');
    Ok(text)
}

fn context() -> Context {
    Context {
        home: node::homedir(),
        claude_homes: node::env_text("CLAUDE_HOMES"),
        now_ms: node::now_ms(),
    }
}

/// Write all of `text` to `sink` and flush it, ignoring a reader that went away, as the node CLI does.
fn best_effort(sink: &mut dyn Write, text: &str) {
    let _ = sink.write_all(text.as_bytes());
    let _ = sink.flush();
}

/// `text` on stdout, now; a verb that writes while it works calls this itself.
pub(crate) fn emit_stdout(text: &str) {
    best_effort(&mut std::io::stdout().lock(), text);
}

/// `text` on stderr, now.
pub(crate) fn emit_stderr(text: &str) {
    best_effort(&mut std::io::stderr().lock(), text);
}

/// Write what was produced: stdout, then stderr.
pub(crate) fn print(out: &Output) {
    emit_stdout(&out.stdout);
    emit_stderr(&out.stderr);
}

/// Write what was produced, and the exit code that goes with it.
fn emit(out: &Output) -> ExitCode {
    print(out);
    ExitCode::from(out.code)
}

/// Replace this process with the node program at `relative` below the root, given `args`. Only returns when that could not be done, after saying why; a stderr that went away does not change the exit code.
fn exec_node(relative: &str, args: &[OsString]) -> ExitCode {
    match node::exec(relative, args) {
        node::ExecFailure::Missing(why) => emit(&Output {
            stdout: String::new(),
            stderr: format!(
                "tagents-core: cannot find {relative}: {why}; this binary has to stay in <root>/target/<profile>/ of a root where it is built\n"
            ),
            code: sessions::exit::USAGE,
        }),
        node::ExecFailure::Run { node, err } => emit(&Output {
            stdout: String::new(),
            stderr: format!(
                "tagents-core: cannot run {}: {err}\n",
                node.to_string_lossy()
            ),
            code: if err.kind() == std::io::ErrorKind::NotFound {
                sessions::exit::NOT_FOUND
            } else {
                sessions::exit::CANNOT_EXECUTE
            },
        }),
    }
}

/// The usage line, with the exit code of asking for it (`help`) and of forgetting to (no word).
fn usage(forgotten: bool) -> Output {
    let texts = match sessions::texts(Locale::current()) {
        Ok(texts) => texts,
        Err(out) => return out,
    };
    Output {
        stdout: format!("{}\n", texts.t("usage", &[])),
        stderr: String::new(),
        code: if forgotten {
            sessions::exit::USAGE
        } else {
            sessions::exit::OK
        },
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
    if args.iter().eq(NOTIFY_RUN) {
        return service::run();
    }
    if first == Some(KNOWLEDGE)
        && args
            .get(1)
            .is_some_and(|verb| knowledge::VERBS.iter().any(|v| verb.to_str() == Some(v[1])))
    {
        return knowledge::run(&args[1..]);
    }
    if args.is_empty() || first.is_some_and(|word| HELP.contains(&word)) {
        return emit(&usage(args.is_empty()));
    }
    let served = first
        .and_then(|first| GROUPS.iter().find(|g| g.word == first))
        .and_then(|group| {
            let rest: Vec<String> = args[1..]
                .iter()
                .map(|a| a.to_string_lossy().into_owned())
                .collect();
            (group.run)(&rest, &context())
        });
    match served {
        Some(out) => emit(&out),
        None => exec_node(NODE_CLI, &args),
    }
}

#[cfg(test)]
mod tests {
    use std::io::{self, Write};

    use super::best_effort;

    /// A reader that went away: every write and every flush fails, as a closed pipe's do.
    struct Gone;

    impl Write for Gone {
        fn write(&mut self, _: &[u8]) -> io::Result<usize> {
            Err(io::ErrorKind::BrokenPipe.into())
        }

        fn flush(&mut self) -> io::Result<()> {
            Err(io::ErrorKind::BrokenPipe.into())
        }
    }

    /// A sink that keeps what it was given and whether it was flushed.
    #[derive(Default)]
    struct Sink {
        bytes: Vec<u8>,
        flushed: bool,
    }

    impl Write for Sink {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.bytes.extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            self.flushed = true;
            Ok(())
        }
    }

    #[test]
    fn a_reader_that_went_away_is_ignored() {
        // `emit_stdout` and `emit_stderr` are this over the two streams, so neither can fail or panic when its reader is gone.
        best_effort(&mut Gone, "text");
    }

    #[test]
    fn the_text_is_written_whole_and_flushed() {
        let mut sink = Sink::default();
        best_effort(&mut sink, "ünï\nline");
        assert_eq!(sink.bytes, "ünï\nline".as_bytes());
        assert!(sink.flushed);
    }
}
