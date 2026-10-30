//! A call: the program of the verb, run as a child with no stdin, and what it did told back in one JSON document. Nothing here knows a verb; the program, the words and the exit table all come from the tool. It is `packages/mcp/src/run.ts`.
//!
//! Nothing a call starts outlives the call. The child leads a process group of its own, a call ends by exit, timeout, cancellation of its request or closing of the server, and each time the whole group is stopped: SIGTERM, then SIGKILL once the grace is over, and whatever is left in the group after the program itself exited is killed at once.
//!
//! One thread runs the call and waits on a channel with a deadline. Three more feed the channel: one per output pipe, which reads, keeps the first `MAX_STREAM` bytes and discards the rest so the program never blocks on a full pipe, and one that waits for the program to exit without reaping it (the zombie keeps the group's id from being reused while the call signals the group). The stop of the request arrives on the same channel.

use std::collections::HashMap;
use std::ffi::{OsStr, OsString};
use std::io::{self, ErrorKind, Read};
use std::os::fd::{AsFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use rustix::event::{PollFd, PollFlags, Timespec, poll};
use rustix::io::Errno;
use rustix::process::{Pid, Signal, WaitId, WaitIdOptions, kill_process_group, waitid};
use serde::Serialize;
use serde_json::ser::{Formatter, PrettyFormatter};
use serde_json::{Map, Number, Serializer, Value};

use super::rpc::{CallResult, ToolEntry};
use super::server::{Stop, Tools};
use super::tools::{Tool, argv_for};
use crate::js;

/// More than this many bytes of one stream is cut: a transcript or an index can be larger than any client will take.
pub const MAX_STREAM: usize = 256 * 1024;
/// A call that has not ended in five minutes is stopped with its whole process group: a verb that takes longer than that is not one a tool call waits for, and the program's own timeout, where it has one, is shorter.
pub const CALL_TIMEOUT: Duration = Duration::from_secs(5 * 60);
/// What a stopped group is given to leave on SIGTERM before it is killed.
pub const KILL_GRACE: Duration = Duration::from_millis(2000);
/// How long the call waits for the output pipes after the program exited: a process that left the group can hold them open for good. A pipe that still holds bytes, or has lost its last writer, is not held by such a process but waits for its reader thread, and is waited for on past this, up to the grace.
pub const DRAIN: Duration = Duration::from_millis(250);
/// How often a call whose drain is over looks again at the pipes that have bytes or an end to read. The Rust server's own: the node server reads in its event loop's poll phase and has no such wait.
const DRAIN_STEP: Duration = Duration::from_millis(10);

pub struct RunDeps {
    /// The environment the program is looked up and run in: the server's own.
    pub env: HashMap<OsString, OsString>,
    pub timeout: Duration,
    pub kill_grace: Duration,
    pub drain: Duration,
}

impl RunDeps {
    /// The limits of the server, in the environment given.
    pub fn standard(env: HashMap<OsString, OsString>) -> RunDeps {
        RunDeps {
            env,
            timeout: CALL_TIMEOUT,
            kill_grace: KILL_GRACE,
            drain: DRAIN,
        }
    }
}

fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The tools of a contract, run: `tools/list` is their entries and a call is `call_tool`.
pub struct Runner {
    tools: Vec<Tool>,
    deps: RunDeps,
}

impl Runner {
    pub fn new(tools: Vec<Tool>, deps: RunDeps) -> Runner {
        Runner { tools, deps }
    }
}

impl Tools for Runner {
    fn list(&self) -> Vec<ToolEntry> {
        self.tools.iter().map(Tool::entry).collect()
    }

    fn call(&self, name: &str, args: &Map<String, Value>, stop: &Stop) -> Option<CallResult> {
        let tool = self.tools.iter().find(|tool| tool.name == name)?;
        Some(call_tool(tool, args, &self.deps, stop))
    }
}

/// The first name of the exit table that carries the code: the table is in the file's order, and a code two names share is told by the first.
fn outcome_of(exit: &[(String, Number)], code: &Number) -> String {
    let wanted = code.as_f64();
    exit.iter()
        .find(|(_, value)| value.as_f64() == wanted)
        .map_or_else(|| format!("exit {code}"), |(name, _)| name.clone())
}

/// Stdout that is a JSON document is handed over parsed, so the model reads fields and not an escaped string; anything else stays text.
fn parsed_or_text(stdout: &str) -> Value {
    let trimmed = stdout.trim_start_matches(js::is_space);
    if !trimmed.starts_with(['{', '[']) {
        return Value::String(stdout.to_owned());
    }
    serde_json::from_str(stdout).unwrap_or_else(|_| Value::String(stdout.to_owned()))
}

/// The first bytes of a stream up to the cap.
#[derive(Default)]
struct Capture {
    bytes: Vec<u8>,
    cut: bool,
}

impl Capture {
    /// A stream is cut when it is longer than the cap, not when it reaches it.
    fn push(&mut self, chunk: &[u8]) {
        let room = MAX_STREAM - self.bytes.len();
        if chunk.len() <= room {
            self.bytes.extend_from_slice(chunk);
            return;
        }
        self.bytes.extend_from_slice(&chunk[..room]);
        self.cut = true;
    }

    /// The text read so far; once cut, it ends before the character the cap fell in, and a marker says so.
    fn text(&self) -> String {
        if !self.cut {
            return String::from_utf8_lossy(&self.bytes).into_owned();
        }
        let whole = &self.bytes[..complete_end(&self.bytes)];
        format!(
            "{}\n[output cut at {MAX_STREAM} bytes]",
            String::from_utf8_lossy(whole)
        )
    }
}

/// The end of the last whole UTF-8 character of `bytes`: a sequence the cap cut in the middle is left out whole. It looks at the last four bytes only, as `completeEnd` of `run.ts` does, so a stream that is not UTF-8 is cut where node cuts it.
fn complete_end(bytes: &[u8]) -> usize {
    let Some(mut lead) = bytes.len().checked_sub(1) else {
        return 0;
    };
    while lead > 0 && bytes.len() - lead < 4 && bytes[lead] & 0xc0 == 0x80 {
        lead -= 1;
    }
    let length = match bytes[lead] {
        0xf0.. => 4,
        0xe0.. => 3,
        0xc0.. => 2,
        _ => 1,
    };
    if lead + length > bytes.len() {
        lead
    } else {
        bytes.len()
    }
}

#[derive(Serialize)]
struct Body<'a> {
    exit: &'a Number,
    outcome: &'a str,
    stdout: Value,
    stderr: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    truncated: Option<bool>,
}

/// The result of a call. A cut stdout keeps the text as text; `truncated` is set when either stream was cut.
fn finish(
    code: &Number,
    outcome: &str,
    stdout: &str,
    stderr: &str,
    stdout_cut: bool,
    stderr_cut: bool,
) -> CallResult {
    let body = Body {
        exit: code,
        outcome,
        stdout: if stdout_cut {
            Value::String(stdout.to_owned())
        } else {
            parsed_or_text(stdout)
        },
        stderr,
        truncated: (stdout_cut || stderr_cut).then_some(true),
    };
    CallResult::text(pretty(&body), code.as_f64() != Some(0.0))
}

/// `JSON.stringify(body, null, 2)`. The body is strings, a number and a document that was just parsed: there is nothing in it to fail on.
fn pretty(body: &Body) -> String {
    let mut out = Vec::new();
    let formatter = JsPretty(PrettyFormatter::new());
    match body.serialize(&mut Serializer::with_formatter(&mut out, formatter)) {
        Ok(()) => String::from_utf8_lossy(&out).into_owned(),
        Err(e) => e.to_string(),
    }
}

/// serde_json's pretty layout, which is the two-space one of `JSON.stringify`, with the numbers told as JavaScript tells them. A number reaches a formatter as the text the program wrote (`arbitrary_precision`), and the node server reads it into a double and writes that: `1.0` is `1`, `1E2` is `100`, `-0` is `0`, and what does not fit a double is `null`.
struct JsPretty(PrettyFormatter<'static>);

impl Formatter for JsPretty {
    fn write_number_str<W: ?Sized + io::Write>(
        &mut self,
        writer: &mut W,
        value: &str,
    ) -> io::Result<()> {
        match value.parse::<f64>() {
            Ok(x) if x.is_finite() => writer.write_all(js::number_text(x).as_bytes()),
            _ => writer.write_all(b"null"),
        }
    }

    fn begin_array<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.0.begin_array(writer)
    }

    fn end_array<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.0.end_array(writer)
    }

    fn begin_array_value<W: ?Sized + io::Write>(
        &mut self,
        writer: &mut W,
        first: bool,
    ) -> io::Result<()> {
        self.0.begin_array_value(writer, first)
    }

    fn end_array_value<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.0.end_array_value(writer)
    }

    fn begin_object<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.0.begin_object(writer)
    }

    fn end_object<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.0.end_object(writer)
    }

    fn begin_object_key<W: ?Sized + io::Write>(
        &mut self,
        writer: &mut W,
        first: bool,
    ) -> io::Result<()> {
        self.0.begin_object_key(writer, first)
    }

    fn begin_object_value<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.0.begin_object_value(writer)
    }

    fn end_object_value<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.0.end_object_value(writer)
    }
}

fn refusal(code: &Number, outcome: &str, message: &str) -> CallResult {
    finish(code, outcome, "", &format!("{message}\n"), false, false)
}

/// Runs the call of `tool` with `args`: refuses what cannot be run, and tells what the program did otherwise. `stop` says that the request was cancelled or the server is closing.
pub fn call_tool(
    tool: &Tool,
    args: &Map<String, Value>,
    deps: &RunDeps,
    stop: &Stop,
) -> CallResult {
    let argv = match argv_for(tool, args) {
        Ok(argv) => argv,
        Err(message) => return refusal(&tool.code("usage", 2), "usage", &message),
    };
    if tool.command.requires_tmux
        && deps
            .env
            .get(OsStr::new("TMUX"))
            .is_none_or(|value| value.is_empty())
    {
        let message = format!(
            "{} needs a tmux server of its own to open a window in, and Claude Code is not running inside tmux (TMUX is not set)",
            tool.name
        );
        return refusal(&tool.code("refused", 3), "refused", &message);
    }
    if stop.is_stopped() {
        return refusal(
            &tool.code("error", 1),
            "cancelled",
            &format!(
                "{} was not started: the request was cancelled",
                tool.program
            ),
        );
    }
    run(tool, &argv, deps, stop)
}

#[derive(Clone, Copy, PartialEq)]
enum Reason {
    Timeout,
    Cancelled,
}

/// One of the two output pipes of the program.
#[derive(Clone, Copy, PartialEq)]
enum Stream {
    Out,
    Err,
}

enum Event {
    /// The program exited; its code, or none when a signal ended it.
    Exited(Option<i32>),
    /// One output pipe is closed, by the program and by everything that held it.
    Eof(Stream),
    Stop,
}

/// What the supervisor saw of the program.
struct Ended {
    reason: Option<Reason>,
    code: Option<i32>,
}

fn signal_group(group: Pid, signal: Signal) {
    // The group is gone already, or never was: either way there is nothing left to signal.
    let _ = kill_process_group(group, signal);
}

/// The text of a spawn failure: the operating system's, except for a program that is not there, which names the program.
fn spawn_failure(program: &str, error: &io::Error) -> String {
    if error.kind() == ErrorKind::NotFound {
        format!("{program} is not on PATH")
    } else {
        error.to_string()
    }
}

fn group_of(child: &Child) -> Option<Pid> {
    Pid::from_raw(i32::try_from(child.id()).ok()?)
}

fn spawn_thread(name: &str, work: impl FnOnce() + Send + 'static) -> Result<(), String> {
    std::thread::Builder::new()
        .name(name.into())
        .spawn(work)
        .map(drop)
        .map_err(|e| format!("could not start a thread for the call: {e}"))
}

/// Reads a pipe to its end. The first `MAX_STREAM` bytes are kept; once the call is over the thread lets go of the pipe at the next byte it reads, so a process that outlived the call gets EPIPE as it would from a pipe that was destroyed.
fn read_stream(mut pipe: impl Read, capture: &Mutex<Capture>, over: &AtomicBool) {
    let mut chunk = vec![0u8; 32 * 1024];
    loop {
        match pipe.read(&mut chunk) {
            Ok(0) => return,
            Ok(n) => {
                if over.load(Ordering::Acquire) {
                    return;
                }
                locked(capture).push(&chunk[..n]);
            }
            Err(e) if e.kind() == ErrorKind::Interrupted => {}
            Err(_) => return,
        }
    }
}

/// Waits for the program to exit without reaping it.
fn wait_for_exit(group: Pid) -> Option<i32> {
    loop {
        match waitid(
            WaitId::Pid(group),
            WaitIdOptions::EXITED | WaitIdOptions::NOWAIT,
        ) {
            Ok(status) => return status.and_then(|status| status.exit_status()),
            Err(Errno::INTR) => {}
            Err(_) => return None,
        }
    }
}

/// A second descriptor of the read end of `pipe`, to ask whether it is readable without reading it. It is the same pipe, so it keeps the pipe open: it must be dropped once the call is over, or a process that outlived the call would never get EPIPE.
fn duplicate(pipe: &impl AsFd) -> Result<OwnedFd, String> {
    pipe.as_fd()
        .try_clone_to_owned()
        .map_err(|e| format!("could not duplicate an output pipe of the call: {e}"))
}

struct Launched {
    events: Receiver<Event>,
    /// The pipes whose reader has not sent its `Eof` yet, each by its duplicate.
    open: Vec<(Stream, OwnedFd)>,
    stdout: Arc<Mutex<Capture>>,
    stderr: Arc<Mutex<Capture>>,
    /// Set when the call is over; the readers let go of their pipes.
    over: Arc<AtomicBool>,
}

/// Starts the threads that watch the program. When one cannot be started the program is stopped and reaped here.
fn launch(child: &mut Child, group: Pid, stop: &Stop) -> Result<Launched, String> {
    let (sender, events) = mpsc::channel();
    let stdout_pipe = child
        .stdout
        .take()
        .ok_or("the program was started without an output pipe")?;
    let stderr_pipe = child
        .stderr
        .take()
        .ok_or("the program was started without an error pipe")?;
    let launched = Launched {
        events,
        open: vec![
            (Stream::Out, duplicate(&stdout_pipe)?),
            (Stream::Err, duplicate(&stderr_pipe)?),
        ],
        stdout: Arc::default(),
        stderr: Arc::default(),
        over: Arc::default(),
    };

    for (name, stream, pipe, capture) in [
        (
            "out",
            Stream::Out,
            Box::new(stdout_pipe) as Box<dyn Read + Send>,
            &launched.stdout,
        ),
        (
            "err",
            Stream::Err,
            Box::new(stderr_pipe) as Box<dyn Read + Send>,
            &launched.stderr,
        ),
    ] {
        let (capture, over, events) = (
            Arc::clone(capture),
            Arc::clone(&launched.over),
            sender.clone(),
        );
        spawn_thread(&format!("tagents-{name}"), move || {
            read_stream(pipe, &capture, &over);
            let _ = events.send(Event::Eof(stream));
        })?;
    }
    let exits = sender.clone();
    spawn_thread("tagents-wait", move || {
        let _ = exits.send(Event::Exited(wait_for_exit(group)));
    })?;
    // A stop that has come already is delivered at once.
    stop.watch(move || {
        let _ = sender.send(Event::Stop);
    });
    Ok(launched)
}

/// Whether a pipe of `open` holds bytes or has lost its last writer, so that its reader has something to take that it has not taken yet. A pipe that is empty and still open is held by a process the call cannot stop, or its reader has taken everything. An error of the poll counts as not readable: the call gives up at the drain.
fn readable(open: &[(Stream, OwnedFd)]) -> bool {
    let mut fds: Vec<PollFd<'_>> = open
        .iter()
        .map(|(_, fd)| PollFd::new(fd, PollFlags::IN))
        .collect();
    poll(&mut fds, Some(&Timespec::default())).is_ok()
        && fds
            .iter()
            .any(|fd| fd.revents().intersects(PollFlags::IN | PollFlags::HUP))
}

/// Follows the program to its end and, whatever ends it, stops everything it started in its group. A timeout, or a stop of the request, sends SIGTERM to the group and SIGKILL when the grace is over; the exit of the program kills the group at once and gives the pipes the drain to run dry. When the drain is over a pipe that is still `readable` is waited for in steps, up to the drain and the grace after the exit: its reader thread has not run yet, which a process holding an empty pipe never causes. `open` is the pipes whose reader has not finished, each by a duplicate, and it is dropped when the call is.
fn supervise(
    events: &Receiver<Event>,
    group: Pid,
    child: &mut Child,
    deps: &RunDeps,
    mut open: Vec<(Stream, OwnedFd)>,
) -> Ended {
    let mut reason = None;
    // The code of the program, and when the call saw it exit.
    let mut exited: Option<(Option<i32>, Instant)> = None;
    // The next thing that happens if nothing else does: the timeout, then the end of the grace, then (after the exit) the end of the drain.
    let mut deadline = Some(Instant::now() + deps.timeout);
    loop {
        let event = match deadline {
            Some(at) => events.recv_timeout(at.saturating_duration_since(Instant::now())),
            None => events.recv().map_err(|_| RecvTimeoutError::Disconnected),
        };
        match event {
            Ok(Event::Stop) => {
                if exited.is_none() && reason.is_none() {
                    reason = Some(Reason::Cancelled);
                    signal_group(group, Signal::TERM);
                    deadline = Some(Instant::now() + deps.kill_grace);
                }
            }
            Ok(Event::Eof(stream)) => {
                open.retain(|(ended, _)| *ended != stream);
                if open.is_empty() && exited.is_some() {
                    break;
                }
            }
            Ok(Event::Exited(code)) => {
                let at = Instant::now();
                exited = Some((code, at));
                // What the program left running in its group dies with it. The pipes are given a moment to drain, and no longer: a process outside the group can hold them open for good.
                signal_group(group, Signal::KILL);
                // The zombie has done its work: it held the group's id while the group was signalled.
                let _ = child.wait();
                if open.is_empty() {
                    break;
                }
                deadline = Some(at + deps.drain);
            }
            Err(RecvTimeoutError::Timeout) => match (exited, reason) {
                (Some((_, at)), _) => {
                    // The drain, or a step after it, is over. A pipe with bytes or an end to read has a reader the machine has not run yet, and no holder: wait for it, up to the grace.
                    let bound = at + deps.drain + deps.kill_grace;
                    let now = Instant::now();
                    if now >= bound || !readable(&open) {
                        break;
                    }
                    deadline = Some((now + DRAIN_STEP).min(bound));
                }
                (None, None) => {
                    reason = Some(Reason::Timeout);
                    signal_group(group, Signal::TERM);
                    deadline = Some(Instant::now() + deps.kill_grace);
                }
                (None, Some(_)) => {
                    signal_group(group, Signal::KILL);
                    deadline = None;
                }
            },
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
    Ended {
        reason,
        code: exited.and_then(|(code, _)| code),
    }
}

fn run(tool: &Tool, argv: &[String], deps: &RunDeps, stop: &Stop) -> CallResult {
    let error = |message: &str| refusal(&tool.code("error", 1), "error", message);
    let mut command = Command::new(&tool.program);
    command
        .args(argv)
        .env_clear()
        .envs(&deps.env)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(e) => return error(&spawn_failure(&tool.program, &e)),
    };
    let Some(group) = group_of(&child) else {
        let _ = child.kill();
        let _ = child.wait();
        return error(&format!(
            "{} was started with a process id that is not one",
            tool.program
        ));
    };
    let launched = match launch(&mut child, group, stop) {
        Ok(launched) => launched,
        Err(message) => {
            signal_group(group, Signal::KILL);
            let _ = child.wait();
            return error(&message);
        }
    };
    let ended = supervise(&launched.events, group, &mut child, deps, launched.open);
    launched.over.store(true, Ordering::Release);

    let stdout = locked(&launched.stdout);
    let stderr = locked(&launched.stderr);
    let (code, name, note) = match ended.reason {
        Some(Reason::Timeout) => (
            tool.code("timeout", 4),
            "timeout".to_owned(),
            format!(
                "{} did not finish within {} ms and was stopped\n",
                tool.program,
                deps.timeout.as_millis()
            ),
        ),
        Some(Reason::Cancelled) => (
            tool.code("error", 1),
            "cancelled".to_owned(),
            format!(
                "{} was stopped: the request was cancelled or the server closed\n",
                tool.program
            ),
        ),
        None => {
            // A program a signal ended has no code: the table's error.
            let code = ended
                .code
                .map_or_else(|| tool.code("error", 1), Number::from);
            let name = outcome_of(&tool.exit, &code);
            (code, name, String::new())
        }
    };
    finish(
        &code,
        &name,
        &stdout.text(),
        &format!("{}{note}", stderr.text()),
        stdout.cut,
        stderr.cut,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn capture(chunks: &[&[u8]]) -> Capture {
        let mut capture = Capture::default();
        for chunk in chunks {
            capture.push(chunk);
        }
        capture
    }

    fn marker() -> String {
        format!("\n[output cut at {MAX_STREAM} bytes]")
    }

    #[test]
    fn a_stream_that_reaches_the_cap_is_not_cut_and_one_byte_more_is() {
        let exact = capture(&[&vec![b'a'; MAX_STREAM]]);
        assert!(!exact.cut);
        assert_eq!(exact.text().len(), MAX_STREAM);
        let over = capture(&[&vec![b'a'; MAX_STREAM], b"a"]);
        assert!(over.cut);
        assert_eq!(
            over.text(),
            format!("{}{}", "a".repeat(MAX_STREAM), marker())
        );
    }

    #[test]
    fn the_cap_counts_bytes_across_chunks_and_not_the_size_of_one() {
        let chunk = "€".repeat(300).into_bytes();
        let mut capture = Capture::default();
        for _ in 0..400 {
            capture.push(&chunk);
        }
        assert!(capture.cut);
        // 262144 = 3 * 87381 + 1: the euro the cap fell in is dropped whole.
        let text = capture.text();
        let kept = text.strip_suffix(&marker()).unwrap_or("");
        assert_eq!(kept.len(), 3 * 87381);
        assert!(!kept.contains('\u{fffd}'));
    }

    #[test]
    fn a_character_the_cap_cuts_is_dropped_whole_and_one_that_ends_at_the_cap_stays() {
        let mut straddling = vec![b'a'; MAX_STREAM - 1];
        straddling.extend_from_slice("é".as_bytes());
        straddling.extend_from_slice(&[b'b'; 1000]);
        let text = capture(&[&straddling]).text();
        assert_eq!(text, format!("{}{}", "a".repeat(MAX_STREAM - 1), marker()));

        let mut ending = vec![b'a'; MAX_STREAM - 2];
        ending.extend_from_slice("é".as_bytes());
        ending.extend_from_slice(&[b'b'; 1000]);
        let text = capture(&[&ending]).text();
        assert_eq!(text, format!("{}é{}", "a".repeat(MAX_STREAM - 2), marker()));
    }

    #[test]
    fn complete_end_looks_back_at_most_four_bytes_and_by_the_lead_byte() {
        assert_eq!(complete_end(b""), 0);
        assert_eq!(complete_end(b"abc"), 3);
        // A lead byte of a two-byte character with its continuation missing.
        assert_eq!(complete_end(b"ab\xc3"), 2);
        assert_eq!(complete_end(b"ab\xc3\xa9"), 4);
        // A three-byte character cut after two bytes, and after one.
        assert_eq!(complete_end(b"a\xe2\x82"), 1);
        assert_eq!(complete_end(b"a\xe2"), 1);
        // A four-byte character cut after three bytes.
        assert_eq!(complete_end(b"a\xf0\x9f\x98"), 1);
        // Continuation bytes with no lead in reach: kept, as node keeps them.
        assert_eq!(complete_end(b"\x80\x80\x80\x80\x80"), 5);
        assert_eq!(complete_end(b"\x80"), 1);
    }

    #[test]
    fn stdout_that_is_a_document_is_parsed_and_anything_else_stays_text() {
        assert_eq!(
            parsed_or_text("{\"a\":[1,2]}\n"),
            serde_json::json!({"a": [1, 2]})
        );
        assert_eq!(parsed_or_text("  \n[1]"), serde_json::json!([1]));
        assert_eq!(parsed_or_text("42\n"), Value::String("42\n".into()));
        assert_eq!(
            parsed_or_text("{not json"),
            Value::String("{not json".into())
        );
        assert_eq!(parsed_or_text(""), Value::String(String::new()));
        // A no-break space is white space to `trimStart` and not to the JSON grammar.
        assert_eq!(parsed_or_text("\u{a0}{}"), Value::String("\u{a0}{}".into()));
        // Two documents are not one.
        assert_eq!(parsed_or_text("{} {}"), Value::String("{} {}".into()));
    }

    #[test]
    fn the_outcome_is_the_first_name_of_the_table_that_carries_the_code() {
        let table: Vec<(String, Number)> = [("ok", 0), ("error", 1), ("failed", 1), ("refused", 3)]
            .iter()
            .map(|(n, c)| ((*n).to_owned(), Number::from(*c)))
            .collect();
        assert_eq!(outcome_of(&table, &Number::from(1)), "error");
        assert_eq!(outcome_of(&table, &Number::from(3)), "refused");
        assert_eq!(outcome_of(&table, &Number::from(9)), "exit 9");
    }

    #[test]
    fn the_body_is_the_two_space_pretty_form_with_the_keys_in_the_order_of_the_node_server() {
        let result = finish(
            &Number::from(3),
            "refused",
            "",
            "nothing done\n",
            false,
            false,
        );
        assert_eq!(
            result.body(),
            "{\n  \"exit\": 3,\n  \"outcome\": \"refused\",\n  \"stdout\": \"\",\n  \"stderr\": \"nothing done\\n\"\n}"
        );
        assert!(result.is_error());
        let cut = finish(&Number::from(0), "ok", "{\"a\":[]}", "e", true, false);
        assert_eq!(
            cut.body(),
            "{\n  \"exit\": 0,\n  \"outcome\": \"ok\",\n  \"stdout\": \"{\\\"a\\\":[]}\",\n  \"stderr\": \"e\",\n  \"truncated\": true\n}"
        );
        assert!(!cut.is_error());
        let parsed = finish(
            &Number::from(0),
            "ok",
            "{\"a\":[1,{}],\"b\":[]}",
            "",
            false,
            true,
        );
        assert_eq!(
            parsed.body(),
            "{\n  \"exit\": 0,\n  \"outcome\": \"ok\",\n  \"stdout\": {\n    \"a\": [\n      1,\n      {}\n    ],\n    \"b\": []\n  },\n  \"stderr\": \"\",\n  \"truncated\": true\n}"
        );
    }

    #[test]
    fn a_number_in_the_programs_json_is_told_as_javascript_tells_the_double_it_reads_as() {
        let result = finish(
            &Number::from(0),
            "ok",
            r#"{"a":1.0,"b":1E2,"c":[-0,0.10,1e400,123456789012345678901234567890]}"#,
            "",
            false,
            false,
        );
        assert_eq!(
            result.body(),
            "{\n  \"exit\": 0,\n  \"outcome\": \"ok\",\n  \"stdout\": {\n    \"a\": 1,\n    \"b\": 100,\n    \"c\": [\n      0,\n      0.1,\n      null,\n      1.2345678901234568e+29\n    ]\n  },\n  \"stderr\": \"\"\n}"
        );
    }

    #[test]
    fn a_failure_to_spawn_names_the_program_only_when_it_is_missing() {
        assert_eq!(
            spawn_failure("tagents-fake", &io::Error::from(ErrorKind::NotFound)),
            "tagents-fake is not on PATH"
        );
        assert_eq!(
            spawn_failure("tagents-fake", &io::Error::from_raw_os_error(13)),
            io::Error::from_raw_os_error(13).to_string()
        );
    }
}
