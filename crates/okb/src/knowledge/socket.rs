//! Where the shared knowledge server of one environment listens, how a starter learns whether anything answers there, and how it starts one (`packages/knowledge/src/mcp/socket.ts`, and `ensureDaemon` of `daemon.ts`).
//!
//! One server per ENVIRONMENT, not per session: two sessions whose variables make the tools answer differently never share a process, and two that would answer alike do. So the socket is named after a hash of the variables the server reads (`KEY_VARS`) and of the code that serves, and a replaced binary gets a daemon of its own.
//!
//! The key is not node's: its stamp starts `rust:`, so a Rust daemon and a node daemon of one environment are two servers on two sockets and neither looks for the other.

use std::{
    fs,
    io::{self, ErrorKind},
    os::unix::{
        fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt},
        net::UnixStream,
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant, SystemTime},
};

use rustix::{io::Errno, process::geteuid};

use super::{doc::hash_of, paths::Env};
use tagents_core::{js, node};

/// Every variable that changes what a tool answers, in the order the key reads them. `CLAUDE_CONFIG_DIR` is not one: nothing under the server reads it.
pub const KEY_VARS: [&str; 7] = [
    "HOME",
    "TAGENTS_CONFIG_DIR",
    "XDG_CONFIG_HOME",
    "TAGENTS_KNOWLEDGE_DIR",
    "TAGENTS_KNOWLEDGE_DB",
    "TAGENTS_KNOWLEDGE_USAGE_DB",
    "CLAUDE_HOMES",
];

/// The variables okb added to the key. They are in a key line only while set, so an environment without them has the key it always had.
pub const OKB_KEY_VARS: [&str; 2] = ["OKB_CONFIG_DIR", "OKB_DIR"];

/// 108 bytes on Linux, 104 on macOS, and the terminating NUL counts.
const MAX_SOCKET_BYTES: usize = 100;
const KEY_HEX: usize = 12;

/// How long a starter waits for a daemon it started to answer.
const START_WAIT: Duration = Duration::from_millis(8000);
const POLL: Duration = Duration::from_millis(10);
/// A lock older than this was left by a process that died inside the critical section, which takes milliseconds.
const LOCK_STALE: Duration = Duration::from_millis(3000);
const LOCK_WAIT: Duration = Duration::from_millis(5000);

/// What the key variable of this name holds, `None` for one that is not set.
fn var<'a>(env: &'a Env, name: &str) -> Option<&'a str> {
    match name {
        "HOME" => env.home_var.as_deref(),
        "TAGENTS_CONFIG_DIR" => env.tagents_config_dir.as_deref(),
        "XDG_CONFIG_HOME" => env.xdg_config_home.as_deref(),
        "TAGENTS_KNOWLEDGE_DIR" => env.knowledge_dir.as_deref(),
        "TAGENTS_KNOWLEDGE_DB" => env.knowledge_db.as_deref(),
        "TAGENTS_KNOWLEDGE_USAGE_DB" => env.knowledge_usage_db.as_deref(),
        "CLAUDE_HOMES" => env.claude_homes.as_deref(),
        "OKB_CONFIG_DIR" => env.okb_config_dir.as_deref(),
        "OKB_DIR" => env.okb_dir.as_deref(),
        _ => None,
    }
}

/// A path as the daemon will see it: one relative to the session's directory is made absolute, because the daemon outlives the session and starts somewhere else. `~...` stays, since `paths` expands it itself.
fn absolute(path: &str, cwd: &str) -> String {
    if path.starts_with('~') || path.starts_with('/') {
        path.to_owned()
    } else {
        node::resolve(cwd, path)
    }
}

/// The environment as the daemon will see it (`canonicalEnv`): the variables that hold a path are absolute, a blank one is left as it is, and `CLAUDE_HOMES` is a list that is split, trimmed, emptied of its empty entries, resolved and joined again. `HOME` is not a path of the session's and is not touched.
pub fn canonical(env: &Env) -> Env {
    let path = |value: &Option<String>| {
        value.as_ref().map(|value| {
            if js::trim(value).is_empty() {
                value.clone()
            } else {
                absolute(value, &env.cwd)
            }
        })
    };
    let homes = |value: &Option<String>| {
        value.as_ref().map(|value| {
            if js::trim(value).is_empty() {
                return value.clone();
            }
            let entries: Vec<String> = value
                .split(',')
                .map(js::trim)
                .filter(|entry| !entry.is_empty())
                .map(|entry| absolute(entry, &env.cwd))
                .collect();
            entries.join(",")
        })
    };
    Env {
        tagents_config_dir: path(&env.tagents_config_dir),
        xdg_config_home: path(&env.xdg_config_home),
        knowledge_dir: path(&env.knowledge_dir),
        knowledge_db: path(&env.knowledge_db),
        knowledge_usage_db: path(&env.knowledge_usage_db),
        okb_config_dir: path(&env.okb_config_dir),
        okb_dir: path(&env.okb_dir),
        claude_homes: homes(&env.claude_homes),
        ..env.clone()
    }
}

/// The variables a daemon is started with that the session's own process does not already have: the ones that hold a path, absolute.
pub fn exported(env: &Env) -> Vec<(&'static str, String)> {
    let canonical = canonical(env);
    KEY_VARS[1..]
        .iter()
        .chain(&OKB_KEY_VARS)
        .filter_map(|name| var(&canonical, name).map(|value| (*name, value.to_owned())))
        .collect()
}

/// One `NAME=value` line for each variable of the key, after `canonical`, an unset variable being an empty one.
pub fn key_lines(env: &Env) -> Vec<String> {
    let canonical = canonical(env);
    let set_okb = OKB_KEY_VARS
        .iter()
        .filter(|name| var(&canonical, name).is_some());
    KEY_VARS
        .iter()
        .chain(set_okb)
        .map(|name| format!("{name}={}", var(&canonical, name).unwrap_or("")))
        .collect()
}

/// The stamp of a binary: its path and its modification time in whole milliseconds, which a rebuilt or replaced binary changes.
pub fn code_stamp(exe: &str, mtime_ms: i64) -> String {
    format!("rust:{exe}:{mtime_ms}")
}

/// The stamp of the binary at `exe`.
pub fn program_stamp(exe: &Path) -> Result<String, String> {
    let shown = exe.to_string_lossy();
    let meta = fs::metadata(exe).map_err(|e| node::io_message(&e, "stat", Some(&shown)))?;
    Ok(code_stamp(&shown, node::mtime_ms_floor(&meta)))
}

/// The first 12 hex digits of the SHA-256 over `NAME=value\0` of each variable and then `code=<stamp>`: unset and empty are the same thing, as they are to the code that reads them.
pub fn server_key(env: &Env, stamp: &str) -> String {
    let mut text: String = key_lines(env)
        .iter()
        .map(|line| format!("{line}\0"))
        .collect();
    text.push_str("code=");
    text.push_str(stamp);
    hash_of(&text).chars().take(KEY_HEX).collect()
}

/// The private directory sockets go in: `tagents-<uid>` under `TMPDIR` as it is trimmed, else under the directory `os.tmpdir()` finds, or under `/tmp` when that would not fit in a socket address. Short on purpose.
pub fn socket_dir(env: &Env, uid: u32) -> String {
    let name = format!("tagents-{uid}");
    let base = env
        .tmpdir
        .as_deref()
        .map(js::trim)
        .filter(|trimmed| !trimmed.is_empty())
        .map_or_else(
            || {
                node::tmpdir(
                    env.tmpdir.as_deref(),
                    env.tmp.as_deref(),
                    env.temp.as_deref(),
                )
            },
            str::to_owned,
        );
    let dir = node::join(&base, &name);
    let longest = node::join(&dir, &format!("knowledge-{}.sock", "0".repeat(KEY_HEX)));
    if longest.len() > MAX_SOCKET_BYTES {
        node::join("/tmp", &name)
    } else {
        dir
    }
}

/// Where the server of this environment and this code listens.
pub fn socket_path(env: &Env, uid: u32, stamp: &str) -> String {
    let file = format!("knowledge-{}.sock", server_key(env, stamp));
    node::join(&socket_dir(env, uid), &file)
}

/// The pid file beside a socket: the daemon writes it once it listens and removes it on the way out.
pub fn pid_file_of(socket: &str) -> String {
    format!("{socket}.pid")
}

/// The lock a starter takes, and a daemon takes while it replaces a dead socket.
pub fn lock_dir_of(socket: &str) -> String {
    format!("{socket}.lock")
}

/// Make the directory and refuse it unless it is ours alone: the name is predictable, and `/tmp` is shared. A link is not followed, and a mode that lets the group or others in is tightened.
pub fn ensure_private_dir(dir: &Path) -> Result<(), String> {
    let shown = dir.to_string_lossy();
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|e| node::io_message(&e, "mkdir", Some(&shown)))?;
    let meta =
        fs::symlink_metadata(dir).map_err(|e| node::io_message(&e, "lstat", Some(&shown)))?;
    if !meta.is_dir() || meta.uid() != geteuid().as_raw() {
        return Err(format!("{shown} is not a directory of this user"));
    }
    if meta.mode() & 0o077 != 0 {
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
            .map_err(|e| node::io_message(&e, "chmod", Some(&shown)))?;
    }
    Ok(())
}

/// What a connection to a socket path tells: `Live` answers, `Stale` is a file nobody listens on, `Absent` is no file at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Probe {
    Live,
    Stale,
    Absent,
}

/// Connect once and let go. Any other failure than the ones that mean "nobody" is an error. A file that is not a socket is refused by Linux as a socket nobody listens on and by macOS as `ENOTSOCK`, and both are `Stale` here, so that `remove_dead` is the one that tells it from a dead socket.
pub fn probe(socket: &Path) -> io::Result<Probe> {
    match UnixStream::connect(socket) {
        Ok(_) => Ok(Probe::Live),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(Probe::Absent),
        Err(e)
            if e.kind() == ErrorKind::ConnectionRefused
                || Errno::from_io_error(&e) == Some(Errno::NOTSOCK) =>
        {
            Ok(Probe::Stale)
        }
        Err(e) => Err(e),
    }
}

fn answers(socket: &Path) -> bool {
    matches!(probe(socket), Ok(Probe::Live))
}

/// A directory-shaped lock: `mkdir` either creates it or fails, never both. It is released when it is dropped.
pub struct Lock(PathBuf);

impl Drop for Lock {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Take the lock at `dir`, polling every 10 ms for up to 5000 ms. A lock older than 3000 ms is stale and removed. `settled` is asked at each poll, and a true answer ends the wait without the lock (`None`): what the caller wanted was done by whoever held it.
pub fn take_lock(dir: &Path, mut settled: impl FnMut() -> bool) -> Result<Option<Lock>, String> {
    let deadline = Instant::now() + LOCK_WAIT;
    loop {
        match fs::create_dir(dir) {
            Ok(()) => return Ok(Some(Lock(dir.to_owned()))),
            Err(e) if e.kind() == ErrorKind::AlreadyExists => {}
            Err(e) => {
                return Err(node::io_message(&e, "mkdir", Some(&dir.to_string_lossy())));
            }
        }
        let age = fs::metadata(dir)
            .and_then(|meta| meta.modified())
            .ok()
            .and_then(|modified| SystemTime::now().duration_since(modified).ok());
        if age.is_some_and(|age| age > LOCK_STALE) {
            let _ = fs::remove_dir_all(dir);
            continue;
        }
        if settled() {
            return Ok(None);
        }
        if Instant::now() > deadline {
            return Err(format!("could not take {}", dir.display()));
        }
        thread::sleep(POLL);
    }
}

/// What a starter hands the process it starts.
pub struct Launch<'a> {
    pub socket: &'a Path,
    pub idle: f64,
    /// The environment as the daemon is to see it (`canonical`).
    pub env: &'a Env,
}

/// Says whether the process a starter started has ended, so that a starter does not wait the whole time for one that is gone.
pub type Ended = Box<dyn FnMut() -> bool>;

/// What starts a daemon: the real one runs the binary detached, and a test runs a server of its own in this process.
pub trait Starter {
    /// What names the code that serves: the key carries it.
    fn stamp(&self) -> Result<String, String>;
    fn start(&self, launch: &Launch<'_>) -> io::Result<Ended>;
}

/// The daemon as a process of its own: `okb serve --foreground --socket P --idle S` in a process group of its own, in `/`, with no stdio, under the environment of `canonical`. A new session would need `setsid` called inside the daemon, which leaves a window in which a signal to the starter's group reaches it, and `pre_exec` is unsafe; the group is enough for what matters, that a `^C` or a kill of the group of the session's proxy never reaches the daemon.
pub struct Detached {
    program: PathBuf,
}

impl Detached {
    pub fn at(program: impl Into<PathBuf>) -> Detached {
        Detached {
            program: program.into(),
        }
    }

    /// The binary that is running.
    pub fn current() -> Result<Detached, String> {
        std::env::current_exe()
            .map(Detached::at)
            .map_err(|e| format!("cannot find the running binary: {e}"))
    }
}

impl Starter for Detached {
    fn stamp(&self) -> Result<String, String> {
        program_stamp(&self.program)
    }

    fn start(&self, launch: &Launch<'_>) -> io::Result<Ended> {
        let mut command = Command::new(&self.program);
        command
            .args(["serve", "--foreground", "--socket"])
            .arg(launch.socket)
            .arg("--idle")
            .arg(js::number_text(launch.idle))
            // A daemon must not hold the directory of a session open: a worktree about to be removed.
            .current_dir("/")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0);
        for (name, value) in exported(launch.env) {
            command.env(name, value);
        }
        let mut child = command.spawn()?;
        // Let go of it: dropping a `Child` neither waits for it nor kills it.
        Ok(Box::new(move || !matches!(child.try_wait(), Ok(None))))
    }
}

/// Where the daemon of this environment listens under the code `starter` runs, whether or not one does.
pub fn default_socket(env: &Env, starter: &dyn Starter) -> Result<PathBuf, String> {
    let stamp = starter.stamp()?;
    Ok(PathBuf::from(socket_path(env, geteuid().as_raw(), &stamp)))
}

/// The socket of a daemon that answers for this environment, starting one if none does. Two starters end with one daemon: the one that takes the lock starts it, and the other waits for the lock and then finds it answering.
pub fn ensure(env: &Env, idle: f64, starter: &dyn Starter) -> Result<PathBuf, String> {
    let socket = default_socket(env, starter)?;
    let shown = socket.to_string_lossy().into_owned();
    if let Some(dir) = socket.parent() {
        ensure_private_dir(dir)?;
    }
    let probed =
        |socket: &Path| probe(socket).map_err(|e| node::io_message(&e, "connect", Some(&shown)));
    if probed(&socket)? == Probe::Live {
        return Ok(socket);
    }
    let Some(_lock) = take_lock(Path::new(&lock_dir_of(&shown)), || answers(&socket))? else {
        return Ok(socket);
    };
    match probed(&socket)? {
        Probe::Live => return Ok(socket),
        Probe::Stale => remove_dead(&socket)?,
        Probe::Absent => {}
    }
    let daemon_env = canonical(env);
    let mut ended = starter
        .start(&Launch {
            socket: &socket,
            idle,
            env: &daemon_env,
        })
        .map_err(|e| format!("cannot start the knowledge server: {e}"))?;
    let deadline = Instant::now() + START_WAIT;
    loop {
        if answers(&socket) {
            return Ok(socket);
        }
        // A daemon that lost the race to another one exits 0 having found it live: the probe sees that one.
        if ended() {
            if answers(&socket) {
                return Ok(socket);
            }
            return Err("the knowledge server exited before it was listening".to_owned());
        }
        if Instant::now() > deadline {
            return Err(format!(
                "the knowledge server did not listen on {shown} within {} ms",
                START_WAIT.as_millis()
            ));
        }
        thread::sleep(POLL);
    }
}

/// Remove the file of a socket nobody listens on, and nothing else.
pub fn remove_dead(socket: &Path) -> Result<(), String> {
    let shown = socket.to_string_lossy();
    let meta =
        fs::symlink_metadata(socket).map_err(|e| node::io_message(&e, "lstat", Some(&shown)))?;
    if !meta.file_type().is_socket() {
        return Err(format!("{shown} exists and is not a socket"));
    }
    fs::remove_file(socket).map_err(|e| node::io_message(&e, "unlink", Some(&shown)))
}
