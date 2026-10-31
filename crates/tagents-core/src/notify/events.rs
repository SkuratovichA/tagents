//! Event lines and the follower of the events file (`parseEventLine`, `followAgentEvents` and the switch of `createAgentFeed` in `packages/core/src/agent-events.ts`).
//!
//! The hook appends one tab separated line per event to `<state dir>/events.tsv` while `<state dir>/events.on` exists. A `Follower` reads that file back from its end, once each line and in file order, and keeps what a read could not finish: the bytes of a line without its newline (bytes, not text, since a read can end in the middle of a character), and the offset it has read to.
//!
//! The follower has no thread, no timer and no poll. The engine calls `wake` when the watch sends `Key::Events` and again when the time `due` names has come, and nothing else wakes it. Time comes in as an argument, so a test drives the grace of a rotated file with a clock of its own. What a call finds comes back as a `Delivery`: events, failed reads and a death are values, and the texts are the ones node's `Error` carries for the same failure.
//!
//! Arm, then read, as the module doc of `watch` asks: `start` arms the directory and the file and reads to the end afterwards, and a file the follower opens afresh (the path was replaced, or the follower rotated it) is armed before it is read. A write that lands between the open and the arming raises no wake, and the read after the arming is what finds it.
//!
//! A `Follower` survives what the hook and the owner do to the file. A size below the offset restarts at 0. A path that is gone or names another inode is read to its end first, then opened again from 0, created when missing. At 1 MiB, once drained, the follower rotates the file itself: `events.tsv` becomes `events.tsv.1`, a fresh `events.tsv` is watched, and the old file stays open for 2 seconds so that a hook that opened the old path just before the rename still lands its line. What arrives through the grace is delivered by the call that finds the grace over, ahead of that call's own events, so it can follow newer events of the fresh file that earlier calls delivered; each event carries its own time.
//!
//! Not detectable without polling: a truncation followed by growth beyond the old offset before the follower wakes. The hook only appends and renames. A symlink as `events.tsv` is read through the link, but the watch does not follow a symlink, so a write to its target raises nothing.
//!
//! `events.on` is created with the first follower of a state directory in the process and removed with the last, the directory being told by its resolved path, so two spellings of one directory share a count.

use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io;
use std::mem;
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, PoisonError};

use rustix::fs::{Mode, OFlags, open};

use crate::js;
use crate::node::{self, io_message};
use crate::watch::{Key, Watch};

#[cfg(test)]
mod tests;

const EVENTS_FILE: &str = "events.tsv";
const EVENTS_SWITCH: &str = "events.on";
/// The size at which the follower rotates the file itself.
const ROTATE_BYTES: u64 = 1_048_576;
/// How long the old file stays open after the follower rotated it.
const ROTATE_GRACE_MS: i64 = 2000;
const CHUNK_BYTES: usize = 64 * 1024;

/// The hook events the stream carries. `PreToolUse` and `PostToolUse` come only for the two tools that put a question to the person, `AskUserQuestion` and `ExitPlanMode`: the `PostToolUse` is the answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AgentHookEvent {
    SessionStart,
    UserPromptSubmit,
    PreToolUse,
    PostToolUse,
    Notification,
    Stop,
    SubagentStop,
    SessionEnd,
}

impl AgentHookEvent {
    /// The hook's name for the event, as the events file spells it.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::SessionStart => "SessionStart",
            Self::UserPromptSubmit => "UserPromptSubmit",
            Self::PreToolUse => "PreToolUse",
            Self::PostToolUse => "PostToolUse",
            Self::Notification => "Notification",
            Self::Stop => "Stop",
            Self::SubagentStop => "SubagentStop",
            Self::SessionEnd => "SessionEnd",
        }
    }

    /// The event a name stands for, or `None` for a name the hook does not write.
    pub fn parse(name: &str) -> Option<Self> {
        Some(match name {
            "SessionStart" => Self::SessionStart,
            "UserPromptSubmit" => Self::UserPromptSubmit,
            "PreToolUse" => Self::PreToolUse,
            "PostToolUse" => Self::PostToolUse,
            "Notification" => Self::Notification,
            "Stop" => Self::Stop,
            "SubagentStop" => Self::SubagentStop,
            "SessionEnd" => Self::SessionEnd,
            _ => return None,
        })
    }
}

/// One line of `events.tsv`, as node's `AgentEvent` has it.
#[derive(Debug, Clone, PartialEq)]
pub struct AgentEvent {
    /// Epoch milliseconds: `Number(<first field>) * 1000`, so it may have a fraction.
    pub at: f64,
    pub event: AgentHookEvent,
    /// The pane number without its `%`, or `s-<session id>` for a session with no pane.
    pub key: String,
    pub session_id: String,
    /// Empty for the main agent.
    pub agent_id: String,
    /// `%12`, or empty when the session has no pane.
    pub pane: String,
    pub cwd: String,
    pub transcript: String,
    /// `CLAUDE_CONFIG_DIR` of the session, empty for the default account.
    pub config_dir: String,
    pub tool: String,
    pub sub: String,
    pub text: String,
    /// `TA_LABEL`.
    pub label: String,
}

/// `parseEventLine`: one line of `events.tsv`, or `None` for a line with fewer than 13 fields, a time that is not a finite number (an empty or white space one included, which `Number` reads as 0) or an event the hook does not write. One trailing `\r` is dropped, and the fields past the 13th, which a newer hook may write, are ignored.
pub fn parse_event_line(line: &str) -> Option<AgentEvent> {
    let line = line.strip_suffix('\r').unwrap_or(line);
    let fields: Vec<&str> = line.split('\t').collect();
    let [
        raw_at,
        event,
        key,
        session_id,
        agent_id,
        pane,
        cwd,
        transcript,
        config_dir,
        tool,
        sub,
        text,
        label,
        ..,
    ] = fields.as_slice()
    else {
        return None;
    };
    let at = js::number(raw_at);
    if js::trim(raw_at).is_empty() || !at.is_finite() {
        return None;
    }
    let own = |field: &&str| (*field).to_owned();
    Some(AgentEvent {
        at: at * 1000.0,
        event: AgentHookEvent::parse(event)?,
        key: own(key),
        session_id: own(session_id),
        agent_id: own(agent_id),
        pane: own(pane),
        cwd: own(cwd),
        transcript: own(transcript),
        config_dir: own(config_dir),
        tool: own(tool),
        sub: own(sub),
        text: own(text),
        label: own(label),
    })
}

/// What the follower arms: the directory and the file of its events file. `Watch` is the one that matters; a test puts a recorder in its place to count the arming and to make it fail.
pub trait Arming {
    fn dir(&self, path: &Path, key: Key) -> io::Result<()>;
    fn file(&self, path: &Path, key: Key) -> io::Result<()>;
}

impl Arming for Watch {
    fn dir(&self, path: &Path, key: Key) -> io::Result<()> {
        Watch::dir(self, path, key)
    }

    fn file(&self, path: &Path, key: Key) -> io::Result<()> {
        Watch::file(self, path, key)
    }
}

/// What one call of a `Follower` found, for the engine to act on.
#[derive(Debug, Default, PartialEq)]
pub struct Delivery {
    /// The new events in file order. What the old file of a rotation gained during its grace comes with the call that ends the grace, ahead of that call's events of the fresh file.
    pub events: Vec<AgentEvent>,
    /// A read, a rename or a switch that failed and left the follower following: the text of node's `Error` for the same failure, for `feed error <text>`.
    pub errors: Vec<String>,
    /// Set once, by the call that found the follower unable to hear the file any more: it could not open the path again, or arm the watch on it. The follower has closed itself by then, its switch has been counted out, and the engine follows again later.
    pub death: Option<String>,
}

/// An open file and how far into it the follower has read.
struct Cursor {
    file: File,
    ino: u64,
    offset: u64,
    /// The bytes after the last newline. Bytes, not text: a read can end mid-character.
    rest: Vec<u8>,
}

/// The old file of a rotation, held open until `due` (epoch milliseconds) for the line a hook may still land in it.
struct Grace {
    cursor: Cursor,
    due: i64,
}

struct Inner {
    dir: String,
    file: String,
    cur: Cursor,
    grace: Option<Grace>,
    rotate_bytes: u64,
    /// The key this follower is counted under in `COUNTED`.
    counted: PathBuf,
}

/// Follows `events.tsv` of one state directory: `followAgentEvents` with the switch of `createAgentFeed.follow`. It holds no thread and no timer; see the module doc for how it is driven.
pub struct Follower(Option<Inner>);

impl Follower {
    /// Starts at the current end of the file, so there is no backlog, creating the directory and the file when they are missing, arms the watch, turns the hook's switch on when this is the first follower of the directory, and reads what was appended meanwhile. `Err` is what node's `followAgentEvents` or `follow` throws: the directory or the file could not be made or opened, the watch could not be armed, or the switch could not be created.
    pub fn start(
        arming: &impl Arming,
        dir: &str,
        now_ms: i64,
    ) -> Result<(Follower, Delivery), String> {
        start_with(arming, dir, now_ms, ROTATE_BYTES)
    }

    /// Reads what the file has gained since the last call. The engine calls it when the watch sends `Key::Events`, and when `due` has come; a call that finds nothing to do is cheap and harmless, so a spurious wake costs nothing. After `close` or a death it finds nothing.
    pub fn wake(&mut self, arming: &impl Arming, now_ms: i64) -> Delivery {
        let mut out = Delivery::default();
        let Some(inner) = self.0.as_mut() else {
            return out;
        };
        if let Err(death) = inner.wake(arming, now_ms, &mut out) {
            out.errors.extend(self.shutdown());
            out.death = Some(death);
        }
        out
    }

    /// When the engine must call `wake` though the watch says nothing: the end of the grace of a rotated file. `None` when no grace is pending.
    pub fn due(&self) -> Option<i64> {
        self.0.as_ref()?.grace.as_ref().map(|grace| grace.due)
    }

    /// Releases the files and counts the follower out; the switch goes off with the last follower of its directory, and a switch that cannot be removed is the text returned. Idempotent: the second call, and a call after a death, return `None`.
    pub fn close(&mut self) -> Option<String> {
        self.shutdown()
    }

    fn shutdown(&mut self) -> Option<String> {
        let inner = self.0.take()?;
        switch_out(&inner.counted, &inner.dir)
    }
}

impl Drop for Follower {
    /// A follower dropped without `close` must not leave the directory's count one too high, or the switch would stay on for good.
    fn drop(&mut self) {
        let _ = self.shutdown();
    }
}

fn start_with(
    arming: &impl Arming,
    dir: &str,
    now_ms: i64,
    rotate_bytes: u64,
) -> Result<(Follower, Delivery), String> {
    let file = node::join(dir, EVENTS_FILE);
    let cur = open_cursor(dir, &file, true)?;
    arming
        .dir(Path::new(dir), Key::Events)
        .map_err(|e| io_message(&e, "watch", Some(dir)))?;
    arm_file(arming, &file)?;
    // After the follower has a file to read, as in `createAgentFeed.follow`: a line the hook writes once the switch is on is not missed.
    let counted = switch_in(dir)?;
    let mut follower = Follower(Some(Inner {
        dir: dir.to_owned(),
        file,
        cur,
        grace: None,
        rotate_bytes,
        counted,
    }));
    // The read after the arming: what was appended between the open and the arming raised no wake.
    let first = follower.wake(arming, now_ms);
    Ok((follower, first))
}

impl Inner {
    /// What a wake of the watch and the end of a grace do in node, in one call: the grace first, when it is over, so a rotation that is due can follow at once, then the file.
    fn wake(
        &mut self,
        arming: &impl Arming,
        now_ms: i64,
        out: &mut Delivery,
    ) -> Result<(), String> {
        if self.grace.as_ref().is_some_and(|grace| now_ms >= grace.due) {
            self.finish_grace(out);
        }
        self.drain(arming, now_ms, out)
    }

    /// `finishOld`: read what the old file gained during the grace, then close it.
    fn finish_grace(&mut self, out: &mut Delivery) {
        let Some(mut grace) = self.grace.take() else {
            return;
        };
        if let Err(message) = pump(&mut grace.cursor, &mut out.events) {
            out.errors.push(message);
        }
    }

    /// `drain`: read the file to its end; then, if the path no longer names it, open the path afresh and read that; then rotate if it has reached the size and no grace is pending. `Err` is a death. A read that fails is reported and ends this call only.
    fn drain(
        &mut self,
        arming: &impl Arming,
        now_ms: i64,
        out: &mut Delivery,
    ) -> Result<(), String> {
        loop {
            if let Err(message) = pump(&mut self.cur, &mut out.events) {
                out.errors.push(message);
                return Ok(());
            }
            if !names_file(&self.file, self.cur.ino) {
                self.cur = open_cursor(&self.dir, &self.file, false)?;
                arm_file(arming, &self.file)?;
                continue;
            }
            if self.cur.offset < self.rotate_bytes
                || self.grace.is_some()
                || !self.rotate(arming, now_ms, out)?
            {
                return Ok(());
            }
        }
    }

    /// `rotate`: `events.tsv` becomes `events.tsv.1`, the fresh `events.tsv` is followed from 0, and the old file stays open for the grace. `Ok(false)` when the rename failed, which is reported, and the follower goes on with the file as it is.
    fn rotate(
        &mut self,
        arming: &impl Arming,
        now_ms: i64,
        out: &mut Delivery,
    ) -> Result<bool, String> {
        let renamed = format!("{}.1", self.file);
        if let Err(e) = fs::rename(&self.file, &renamed) {
            // `io_message` quotes one path, and node names both ends of a rename.
            let both = format!("{}' -> '{renamed}", self.file);
            out.errors.push(io_message(&e, "rename", Some(&both)));
            return Ok(false);
        }
        let fresh = open_cursor(&self.dir, &self.file, false)?;
        let old = mem::replace(&mut self.cur, fresh);
        self.grace = Some(Grace {
            cursor: old,
            due: now_ms + ROTATE_GRACE_MS,
        });
        arm_file(arming, &self.file)?;
        Ok(true)
    }
}

fn arm_file(arming: &impl Arming, file: &str) -> Result<(), String> {
    arming
        .file(Path::new(file), Key::Events)
        .map_err(|e| io_message(&e, "watch", Some(file)))
}

/// Whether the path still names the file with this inode: a missing path, or another file, is a replaced one.
fn names_file(file: &str, ino: u64) -> bool {
    fs::metadata(file).is_ok_and(|meta| meta.ino() == ino)
}

/// `openCursor`: the directory and the file are created when missing, the file is opened read only, and `from_end` starts at its size rather than at 0.
fn open_cursor(dir: &str, file: &str, from_end: bool) -> Result<Cursor, String> {
    fs::create_dir_all(dir).map_err(|e| io_message(&e, "mkdir", Some(dir)))?;
    let fd = open(
        file,
        OFlags::RDONLY | OFlags::CREATE | OFlags::CLOEXEC,
        Mode::RUSR | Mode::WUSR,
    )
    .map_err(|e| io_message(&io::Error::from(e), "open", Some(file)))?;
    let file = File::from(fd);
    let meta = file.metadata().map_err(|e| io_message(&e, "fstat", None))?;
    Ok(Cursor {
        ino: meta.ino(),
        offset: if from_end { meta.len() } else { 0 },
        rest: Vec::new(),
        file,
    })
}

/// `pump`: read `[offset, size)` of one file and push its complete lines as events. A size below the offset is a truncation: start again at 0. On `Err` the events pushed before it stay pushed.
fn pump(c: &mut Cursor, events: &mut Vec<AgentEvent>) -> Result<(), String> {
    let size = c
        .file
        .metadata()
        .map_err(|e| io_message(&e, "fstat", None))?
        .len();
    if size < c.offset {
        c.offset = 0;
        c.rest.clear();
    }
    while c.offset < size {
        let want =
            usize::try_from(size - c.offset).map_or(CHUNK_BYTES, |left| left.min(CHUNK_BYTES));
        let mut buf = vec![0; want];
        let n = loop {
            match c.file.read_at(&mut buf, c.offset) {
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                read => break read.map_err(|e| io_message(&e, "read", None))?,
            }
        };
        if n == 0 {
            break;
        }
        c.offset += n as u64;
        c.rest.extend_from_slice(&buf[..n]);
        let Some(last) = c.rest.iter().rposition(|&b| b == b'\n') else {
            continue;
        };
        // `Buffer.toString('utf8')`: a byte sequence that is not UTF-8 becomes U+FFFD.
        let text = String::from_utf8_lossy(&c.rest[..last]);
        events.extend(text.split('\n').filter_map(parse_event_line));
        c.rest.drain(..=last);
    }
    Ok(())
}

/// Followers open per state directory across the process (`followersByDir`), keyed by the directory itself, whatever it is called: two spellings of one directory must share a count, or the first to close would remove the switch under the other. The lock is held through the file work, so a switch going off and one coming on cannot cross.
static COUNTED: Mutex<BTreeMap<PathBuf, usize>> = Mutex::new(BTreeMap::new());

fn counted() -> MutexGuard<'static, BTreeMap<PathBuf, usize>> {
    COUNTED.lock().unwrap_or_else(PoisonError::into_inner)
}

/// `dirKey`: absolute, with symlinks resolved once the directory exists.
fn dir_key(dir: &str) -> PathBuf {
    fs::canonicalize(dir)
        .unwrap_or_else(|_| std::path::absolute(dir).unwrap_or_else(|_| PathBuf::from(dir)))
}

/// Counts a follower of `dir` in; the first of its directory turns the switch on, and a switch that cannot be created leaves no count behind.
fn switch_in(dir: &str) -> Result<PathBuf, String> {
    let key = dir_key(dir);
    let mut held = counted();
    match held.get_mut(&key) {
        Some(count) => *count += 1,
        None => {
            set_events_on(true, dir)?;
            held.insert(key.clone(), 1);
        }
    }
    Ok(key)
}

/// Counts a follower out; the last of its directory turns the switch off. The text is a switch that could not be removed.
fn switch_out(key: &Path, dir: &str) -> Option<String> {
    let mut held = counted();
    let left = held.get(key).copied().unwrap_or(1) - 1;
    if left > 0 {
        held.insert(key.to_path_buf(), left);
        return None;
    }
    held.remove(key);
    set_events_on(false, dir).err()
}

/// `setEventsOn`: on creates the switch and an empty `events.tsv` when there is none, so a follower started a moment later has a file to watch; off removes the switch and nothing else, since the log stays for whoever reads it next.
fn set_events_on(on: bool, dir: &str) -> Result<(), String> {
    if on {
        fs::create_dir_all(dir).map_err(|e| io_message(&e, "mkdir", Some(dir)))?;
        touch(&node::join(dir, EVENTS_SWITCH))?;
        return touch(&node::join(dir, EVENTS_FILE));
    }
    let switch = node::join(dir, EVENTS_SWITCH);
    match fs::remove_file(&switch) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => {
            // `rmSync` of a directory without `recursive` is node's own error, and the same on both systems, where `unlink` is EISDIR on Linux and EPERM on macOS.
            if fs::symlink_metadata(&switch).is_ok_and(|meta| meta.is_dir()) {
                return Err(format!(
                    "Path is a directory: rm returned EISDIR (is a directory) {switch}"
                ));
            }
            Err(io_message(&e, "unlink", Some(&switch)))
        }
        _ => Ok(()),
    }
}

/// Create the file if it is missing, never touch one that exists.
fn touch(file: &str) -> Result<(), String> {
    OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .open(file)
        .map(drop)
        .map_err(|e| io_message(&e, "open", Some(file)))
}
