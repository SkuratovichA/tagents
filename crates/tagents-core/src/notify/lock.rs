//! The one-daemon-per-machine lock of `packages/notify/src/service.ts` (`takeLock`, `holds`, `readLock`, `sweepTempLocks`, `releaseLock`, `psProcessStart`, `systemBootMs`), byte for byte: a node daemon and a Rust daemon on one state directory share this file, and whichever holds it keeps the other off.
//!
//! The file holds `<pid> <start time>\n`, with the start time as `/bin/ps -o lstart=` prints it under `LC_ALL=C TZ=UTC`, and a bare `<pid>\n` of the first format is still read. It is made whole or not at all: the text goes into a temp file beside it and `link` puts it at the lock path, which fails when something is there, so a reader never sees it empty. A holder is told from a stranger by the start time, because pids are reused; a lock with no start time, or a `ps` that cannot answer, falls back on the lock's age against the last boot.
//!
//! A takeover removes the stale file only while it still says what was judged, as node does; between that read and the removal another process could still put its own lock there, and the window is the one node's own protocol has between two node processes, since node's daemon takes no mutex that a second implementation could honour.

use std::fs::{self, OpenOptions};
use std::hash::{BuildHasher, RandomState};
use std::io::{self, Write};
use std::path::Path;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use rustix::process::{Pid, test_kill_process};

use crate::child::{self, Policy};
use crate::ending::Stop;
use crate::js;
use crate::node;
use crate::notify::clock::{Clock, SystemClock};

pub const LOCK_FILE: &str = "notify.lock";

/// Every pass through the lock loop costs one, the takeover pass included.
const LOCK_TRIES: usize = 3;

/// A temp file `create_lock` makes lives for the length of a write and a link; a minute is a crash.
const TEMP_MAX_AGE_MS: f64 = 60_000.0;

/// `Number.isSafeInteger` bound of a pid read from the file.
const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;

/// How long `ps` has: past it the start time is not known, and the lock's age decides.
const PS_TIMEOUT: Duration = Duration::from_millis(2000);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LockResult {
    Taken,
    Held { holder: u64 },
}

/// Who a lock names. `started` is `None` for a lock written before start times were recorded, or when `ps` could not tell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LockHolder {
    pub pid: u64,
    pub started: Option<String>,
}

pub struct LockDeps<'a> {
    pub me: LockHolder,
    /// Epoch ms of the last boot: a lock written before it names a pid that may have been reused. Zero counts every lock as written after boot.
    pub boot_ms: i64,
    /// When a process started, as text, or `None` when that cannot be told. Asked only to take or judge the lock; `ps_process_start` is the real one.
    pub process_start: &'a dyn Fn(u64) -> Option<String>,
}

/// A lock file as read.
#[derive(Debug, Clone, PartialEq)]
pub struct LockContent {
    /// The file's text exactly as read: two reads are the same lock only when this is equal.
    pub raw: String,
    /// The holder's pid; `None` when the file names none (empty, not a pid, zero or not a safe integer).
    pub pid: Option<u64>,
    /// The holder's start time as `ps` printed it; `None` for the first format, a bare pid.
    pub started: Option<String>,
    pub mtime_ms: i64,
}

fn render(holder: &LockHolder) -> String {
    match &holder.started {
        Some(started) => format!("{} {started}\n", holder.pid),
        None => format!("{}\n", holder.pid),
    }
}

/// `^(\d+)(?:[ \t]+(\S[^\n]*))?$` over the trimmed text: the pid and the start time, or `None` when the text is neither format.
fn parse_line(text: &str) -> Option<(&str, Option<&str>)> {
    let text = js::trim(text);
    let digits_end = text
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(text.len());
    if digits_end == 0 {
        return None;
    }
    let (digits, rest) = text.split_at(digits_end);
    if rest.is_empty() {
        return Some((digits, None));
    }
    let started = rest.trim_start_matches([' ', '\t']);
    let spaced = started.len() < rest.len();
    let first = started.chars().next()?;
    if !spaced || js::is_space(first) || started.contains('\n') {
        return None;
    }
    // Changes no input after the trim above; kept because node's `m[2]?.trim()` (`packages/notify/src/service.ts:128`) follows `raw.trim()` (`:123`) the same way.
    Some((digits, Some(js::trim(started))))
}

/// What the lock file says now, in either format; `None` when the file cannot be read. Whether the named process is still the holder is not decided here.
pub fn read_lock(file: &str) -> Option<LockContent> {
    let mtime_ms = node::mtime_ms(&fs::metadata(file).ok()?);
    let raw = String::from_utf8_lossy(&fs::read(file).ok()?).into_owned();
    let parsed = parse_line(&raw);
    let pid = parsed
        .and_then(|(digits, _)| digits.parse::<u64>().ok())
        .filter(|pid| (1..=MAX_SAFE_INTEGER).contains(pid));
    Some(LockContent {
        pid,
        started: parsed.and_then(|(_, started)| started).map(str::to_owned),
        raw,
        mtime_ms,
    })
}

/// `isAlive` of `packages/core/src/pid.ts`: signal 0 reaches the process, or is refused because it belongs to somebody else. A pid that does not fit a `pid_t` names no process here.
fn is_alive(pid: u64) -> bool {
    let Some(pid) = i32::try_from(pid).ok().and_then(Pid::from_raw) else {
        return false;
    };
    match test_kill_process(pid) {
        Ok(()) => true,
        Err(err) => err == rustix::io::Errno::PERM,
    }
}

/// Is the process the lock names still the one that wrote it? A live pid is not enough, since pids are reused.
pub fn holds(seen: &LockContent, deps: &LockDeps) -> bool {
    let Some(pid) = seen.pid else { return false };
    if pid == deps.me.pid || !is_alive(pid) {
        return false;
    }
    if let Some(started) = &seen.started
        && let Some(now) = (deps.process_start)(pid)
    {
        return now == *started;
    }
    seen.mtime_ms >= deps.boot_ms
}

static TEMP_COUNT: AtomicU64 = AtomicU64::new(0);

/// Eight lowercase hex digits, as `randomBytes(4).toString('hex')`. The hasher is seeded by the system for each `RandomState`.
fn temp_suffix() -> String {
    let n = TEMP_COUNT.fetch_add(1, Ordering::Relaxed);
    format!("{:08x}", RandomState::new().hash_one(n) as u32)
}

/// Creates the lock whole or not at all. `Ok(false)` is "something is there", from the temp file's own name as from the link.
fn create_lock(file: &str, me: &LockHolder) -> Result<bool, String> {
    let tmp = format!("{file}.{}.{}.tmp", me.pid, temp_suffix());
    let made = write_new(&tmp, &render(me)).and_then(|()| {
        fs::hard_link(&tmp, file).map_err(|err| (err, "link", format!("{tmp}' -> '{file}")))
    });
    let _ = fs::remove_file(&tmp);
    match made {
        Ok(()) => Ok(true),
        Err((err, ..)) if err.kind() == io::ErrorKind::AlreadyExists => Ok(false),
        Err((err, syscall, path)) => Err(node::io_message(&err, syscall, Some(&path))),
    }
}

type Failed = (io::Error, &'static str, String);

fn write_new(tmp: &str, text: &str) -> Result<(), Failed> {
    let mut out = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(tmp)
        .map_err(|err| (err, "open", tmp.to_owned()))?;
    out.write_all(text.as_bytes())
        .map_err(|err| (err, "write", tmp.to_owned()))
}

/// Removes the temp files whose process is gone, or that are older than a minute (a reused pid), with one look at the directory. A process that dies between writing its temp file and linking it leaves the file for good.
fn sweep_temp_locks(file: &str) {
    let path = Path::new(file);
    let base = node::basename(file);
    let dir = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let Ok(names) = fs::read_dir(dir) else { return };
    let now = SystemClock.now_ms();
    for name in names.filter_map(|entry| entry.ok()?.file_name().into_string().ok()) {
        let start = base.len() + 1;
        if !name.starts_with(base)
            || name.as_bytes().get(base.len()) != Some(&b'.')
            || !name.ends_with(".tmp")
        {
            continue;
        }
        let Some(middle) = name.get(start..name.len().saturating_sub(4)) else {
            continue;
        };
        let Some((digits, hex)) = middle.split_once('.') else {
            continue;
        };
        let named = !digits.is_empty()
            && digits.bytes().all(|b| b.is_ascii_digit())
            && hex.len() == 8
            && hex.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
        if !named {
            continue;
        }
        let tmp = dir.join(&name);
        let gone = !digits.parse::<u64>().is_ok_and(is_alive);
        let old = || {
            fs::metadata(&tmp)
                .is_ok_and(|meta| now - node::mtime_ms(&meta) as f64 > TEMP_MAX_AGE_MS)
        };
        if gone || old() {
            let _ = fs::remove_file(&tmp);
        }
    }
}

/// `fs.rmSync(file, { force: true })`: a file that is not there is removed.
fn remove(file: &str) -> Result<(), String> {
    match fs::remove_file(file) {
        Err(err) if err.kind() != io::ErrorKind::NotFound => {
            Err(node::io_message(&err, "unlink", Some(file)))
        }
        _ => Ok(()),
    }
}

/// Takes the lock, or says who holds it. `Err` is the text of the failure as node words it, which the service hands over with.
pub fn take_lock(file: &str, deps: &LockDeps) -> Result<LockResult, String> {
    sweep_temp_locks(file);
    for _ in 0..LOCK_TRIES {
        if create_lock(file, &deps.me)? {
            return Ok(LockResult::Taken);
        }
        // It vanished between the link and the read: that is a free lock, not an old one.
        let Some(seen) = read_lock(file) else {
            continue;
        };
        if let Some(holder) = seen.pid
            && holds(&seen, deps)
        {
            return Ok(LockResult::Held { holder });
        }
        // Dead, unreadable, our own leftover, a reused pid, or from before the last boot. Judging may have taken a `ps` call, and meanwhile another process may have put its own lock there: the file is removed only while it still says what was judged.
        if read_lock(file).is_some_and(|now| now.raw == seen.raw) {
            remove(file)?;
        }
    }
    Err(format!(
        "cannot take {file}: another process keeps recreating it"
    ))
}

/// Unlinks the lock only while it still names this process: after a takeover it is somebody else's. `Err` is the text the service logs after `could not release the lock <file>`.
pub fn release_lock(file: &str) -> Result<(), String> {
    if read_lock(file).and_then(|seen| seen.pid) == Some(u64::from(std::process::id())) {
        remove(file)?;
    }
    Ok(())
}

/// `ps -o lstart= -p <pid>` with a locale, UTC and no other environment, for one pid: the text is compared between processes started from different places and at different times, so the two must read alike. `None` when `ps` cannot say.
pub fn ps_process_start(pid: u64) -> Option<String> {
    start_via(Command::new("/bin/ps"), pid)
}

/// `ps_process_start` with the command to run, so a test can stand a stub in for `ps`.
fn start_via(mut command: Command, pid: u64) -> Option<String> {
    command
        .args(["-o", "lstart=", "-p", &pid.to_string()])
        .env_clear()
        .env("LC_ALL", "C")
        .env("TZ", "UTC");
    let policy = Policy {
        input: None,
        timeout: PS_TIMEOUT,
        kill_grace: None,
        drain: Duration::from_millis(250),
        cap: 64 * 1024,
    };
    let finished = child::run(command, &policy, &Stop::default()).ok()?;
    let text = js::trim(&finished.stdout);
    (finished.reason.is_none() && finished.code == Some(0) && !text.is_empty())
        .then(|| text.to_owned())
}

/// Epoch ms of the last boot as of `now_ms`, read once at start: `/proc/uptime` on Linux, `kern.boottime` on macOS, zero when neither can tell.
pub fn boot_ms(now_ms: i64) -> i64 {
    if cfg!(target_os = "macos") {
        macos_boot_ms().unwrap_or(0)
    } else {
        fs::read_to_string("/proc/uptime")
            .ok()
            .and_then(|text| boot_from_uptime(&text, now_ms))
            .unwrap_or(0)
    }
}

fn macos_boot_ms() -> Option<i64> {
    let mut command = Command::new("/usr/sbin/sysctl");
    command.args(["-n", "kern.boottime"]);
    let policy = Policy {
        input: None,
        timeout: PS_TIMEOUT,
        kill_grace: None,
        drain: Duration::from_millis(250),
        cap: 4096,
    };
    let finished = child::run(command, &policy, &Stop::default()).ok()?;
    if finished.reason.is_some() || finished.code != Some(0) {
        return None;
    }
    boot_from_boottime(&finished.stdout)
}

/// `{ sec = 1791766984, usec = 222183 }` of `sysctl -n kern.boottime`.
fn boot_from_boottime(text: &str) -> Option<i64> {
    let number = |label: &str| -> Option<i64> {
        let after = text.split_once(label)?.1.trim_start().strip_prefix('=')?;
        let digits: String = after
            .trim_start()
            .chars()
            .take_while(char::is_ascii_digit)
            .collect();
        digits.parse().ok()
    };
    Some(number("sec")? * 1000 + number("usec")? / 1000)
}

/// The first number of `/proc/uptime`, in seconds, taken from `now_ms`; fractions of a second are kept to the millisecond.
fn boot_from_uptime(text: &str, now_ms: i64) -> Option<i64> {
    let seconds: f64 = text.split_whitespace().next()?.parse().ok()?;
    seconds
        .is_finite()
        .then(|| now_ms - (seconds * 1000.0) as i64)
}

#[cfg(test)]
mod tests;
