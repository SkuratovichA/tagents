//! `tagents-core sessions …`: the text side of the transcript reader.
//!
//! A port of `renderRecent`, `renderSearch` and `renderShow` in `packages/core/src/transcripts.ts` and of `sessions()` in `packages/core/src/cli/main.ts`.
//! The text, including the name `sessions.mjs` the usage lines carry, is what the orchestrator printed and the fixtures pin; the parity suite compares both programs on it.
//! Like the node CLI, a command builds all of its output before writing any, so a failure half way prints nothing on stdout.

use crate::{
    date, js,
    transcripts::{self, Context, Failure, SessionRow},
};

/// The name the rendered text refers callers to. Part of the pinned output.
pub const PROGRAM: &str = "sessions.mjs";
/// How deep `search` looks before giving up.
pub const SEARCH_SCAN: usize = 400;
pub const SEARCH_HITS: usize = 12;
const DEFAULT_RECENT: f64 = 15.0;
const LISTING_PROMPT_UNITS: usize = 150;
const SHOW_UNITS: usize = 1500;

/// The exit codes the front door uses. `OK`, `ERROR` and `USAGE` are the ones `spec/cli/tagents-core.json` names, and a test pins them to it; the last two are the shell's own for a program that could not be started.
pub mod exit {
    pub const OK: u8 = 0;
    pub const ERROR: u8 = 1;
    pub const USAGE: u8 = 2;
    pub const CANNOT_EXECUTE: u8 = 126;
    pub const NOT_FOUND: u8 = 127;
}

/// The verbs this module serves, as the words after the program name. `tagents-core --spec` prints them and a test pins them to `impl: "rust"` in the data file.
pub const VERBS: &[&[&str]] = &[
    &["sessions", "recent"],
    &["sessions", "search"],
    &["sessions", "show"],
];

/// What the command wrote and how it ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Output {
    pub stdout: String,
    pub stderr: String,
    pub code: u8,
}

impl Output {
    fn out(text: String) -> Self {
        Self {
            stdout: text,
            stderr: String::new(),
            code: exit::OK,
        }
    }

    fn fail(stderr: String) -> Self {
        Self {
            stdout: String::new(),
            stderr,
            code: exit::ERROR,
        }
    }
}

/// `sessions(argv)` in `main.ts`, with the `catch` of `main()` around it: a failure prints its message and exits 1.
pub fn run(argv: &[String], cx: &Context) -> Output {
    let (cmd, args) = match argv.split_first() {
        Some((cmd, args)) => (Some(cmd.as_str()), args),
        None => (None, argv),
    };
    let result = match cmd {
        None | Some("recent") => {
            recent(cx, args.first().map_or(f64::NAN, |a| js::number(a))).map(Output::out)
        }
        Some("search") => {
            if args.is_empty() || js::trim(&args.join(" ")).is_empty() {
                return Output::fail(format!("usage: {PROGRAM} search <words…>\n"));
            }
            search(cx, args).map(Output::out)
        }
        Some("show") => {
            let Some(prefix) = args.first().filter(|p| !p.is_empty()) else {
                return Output::fail(format!("usage: {PROGRAM} show <id-prefix>\n"));
            };
            match show(cx, prefix) {
                Ok(Some(text)) => Ok(Output::out(text)),
                Ok(None) => return Output::fail(format!("no session starts with \"{prefix}\"\n")),
                Err(failure) => Err(failure),
            }
        }
        Some(_) => Ok(Output::out(format!(
            "usage: {PROGRAM} [recent [N] | search <words…> | show <id-prefix>]\n"
        ))),
    };
    result.unwrap_or_else(|failure| Output::fail(format!("{failure}\n")))
}

/// `fmtWhen`: `01-02 03:04` in UTC, and ` (today/yday)` for a session written within the last 24 hours (a time in the future counts).
fn when(cx: &Context, mtime_ms: i64) -> String {
    let iso = date::iso(mtime_ms);
    let stamp = iso.get(5..16).unwrap_or_default().replacen('T', " ", 1);
    if cx.now_ms - mtime_ms < 86_400_000 {
        format!("{stamp} (today/yday)")
    } else {
        stamp
    }
}

fn one_line(s: &str, units: usize) -> String {
    js::take16(&js::collapse_space(s), units)
}

fn two_lines(cx: &Context, row: &SessionRow, prompt: &str) -> String {
    format!(
        "{}  {} {} {}\n          {}\n",
        js::take16(&row.id, 8),
        js::pad_end(&when(cx, row.mtime_ms), 18),
        js::pad_end(&row.account, 8),
        row.project,
        one_line(prompt, LISTING_PROMPT_UNITS),
    )
}

/// `recent [N]`: `count` is `Number(arg)`, and zero or NaN means the default.
pub fn recent(cx: &Context, count: f64) -> Result<String, Failure> {
    let count = if count == 0.0 || count.is_nan() {
        DEFAULT_RECENT
    } else {
        count
    };
    let rows = transcripts::collect(cx);
    let mut out = String::new();
    for row in rows.iter().take(js::slice_end(count, rows.len())) {
        let prompt = transcripts::first_prompt(&row.file)?;
        out += &two_lines(
            cx,
            row,
            if prompt.is_empty() {
                "(no opening prompt)"
            } else {
                &prompt
            },
        );
    }
    Ok(format!(
        "{out}\nfull text of one: {PROGRAM} show <id-prefix>\n"
    ))
}

/// `search <words…>`: every word must appear in the project path plus the opening prompt, case-insensitively.
pub fn search(cx: &Context, words: &[String]) -> Result<String, Failure> {
    let q = js::lower(&words.join(" "));
    let needles = js::split_space(&q);
    let mut out = String::new();
    let mut hits = 0;
    for row in transcripts::collect(cx).iter().take(SEARCH_SCAN) {
        let prompt = transcripts::first_prompt(&row.file)?;
        let hay = js::lower(&format!("{} {prompt}", row.project));
        if !needles.iter().all(|w| hay.contains(w)) {
            continue;
        }
        hits += 1;
        out += &two_lines(cx, row, &prompt);
        if hits >= SEARCH_HITS {
            break;
        }
    }
    if hits == 0 {
        return Ok(format!(
            "nothing matches \"{q}\" in the last {SEARCH_SCAN} sessions' opening prompts\n"
        ));
    }
    Ok(out)
}

/// `show <id-prefix>`: `None` when no session starts with the prefix.
pub fn show(cx: &Context, prefix: &str) -> Result<Option<String>, Failure> {
    let Some(row) = transcripts::find_by_prefix(cx, prefix) else {
        return Ok(None);
    };
    let prompt = transcripts::first_prompt(&row.file)?;
    let reply = transcripts::last_assistant_text(&row.file)?;
    Ok(Some(format!(
        "session {}\naccount {} · project {} · last activity {}\n\n── opening prompt ──\n{}\n\n── last assistant reply (tail) ──\n{}\n",
        row.id,
        row.account,
        row.project,
        date::iso(row.mtime_ms),
        one_line(
            if prompt.is_empty() { "(none)" } else { &prompt },
            SHOW_UNITS
        ),
        one_line(
            if reply.is_empty() {
                "(none in tail window)"
            } else {
                &reply
            },
            SHOW_UNITS
        ),
    )))
}
