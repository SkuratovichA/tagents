//! `tagents-core notify run` as a process: the start, the stop, and the ending of a start that failed.
//!
//! Each test makes a root of its own that holds a copy of the binary. The service runs with `env_clear` and a scratch `HOME`, state directory, config directory and tmux directory, so nothing of the machine's own is read or written, and the log backend, which posts nothing.
//! A signal that has to land during the start is sent while the service waits to read its options, which is a FIFO until the test fills it.

// Test code: a failed unwrap here is the failure report.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::{
    fs,
    io::{self, Write},
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    process::{Child, Command, ExitStatus, Stdio},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use rustix::process::{Pid, Signal, kill_process};

mod common;
use common::{rig::until, run, scratch, start, writing};

const BIN: &str = env!("CARGO_BIN_EXE_tagents-core");
/// Long enough for a start to finish on a loaded machine.
const WAIT_MS: u64 = 20_000;
const LOG_BACKEND: &str = "backend = \"log\"\n";

/// A directory of a test's own that holds a copy of the binary, and the state and config the service runs on.
struct Fake {
    root: PathBuf,
}

impl Fake {
    fn new(name: &str) -> Fake {
        let root = scratch(name).canonicalize().unwrap();
        let bin = root.join("target/debug/tagents-core");
        fs::create_dir_all(bin.parent().unwrap()).unwrap();
        {
            let _writing = writing();
            fs::copy(BIN, &bin).unwrap();
        }
        for dir in ["state", "home", "tmux"] {
            fs::create_dir_all(root.join(dir)).unwrap();
        }
        Fake { root }
    }

    /// A fake with the log backend: the service runs and posts nothing.
    fn logging(name: &str) -> Fake {
        let fake = Fake::new(name);
        fake.options(LOG_BACKEND);
        fake
    }

    fn state(&self) -> PathBuf {
        self.root.join("state")
    }

    fn lock(&self) -> PathBuf {
        self.state().join("notify.lock")
    }

    fn plugins(&self) -> PathBuf {
        self.root.join("config/plugins")
    }

    fn options_file(&self) -> PathBuf {
        self.plugins().join("notify.toml")
    }

    /// `notify.toml` as `text`, put in place whole: a service woken in the middle of a truncating write reads an empty file and reloads.
    fn options(&self, text: &str) {
        fs::create_dir_all(self.plugins()).unwrap();
        let next = self.root.join("options.next");
        fs::write(&next, text).unwrap();
        fs::rename(next, self.options_file()).unwrap();
    }

    /// A state directory whose events file cannot be followed: the follower's start fails, which is a failure of the start.
    fn break_follower(&self) {
        fs::create_dir_all(self.state().join("events.tsv")).unwrap();
    }

    fn command(&self) -> Command {
        let mut command = Command::new(self.root.join("target/debug/tagents-core"));
        command
            .env_clear()
            .env("HOME", self.root.join("home"))
            .env("TA_STATE_DIR", self.state())
            .env("TAGENTS_CONFIG_DIR", self.root.join("config"))
            .env("TMUX_TMPDIR", self.root.join("tmux"))
            .env("PATH", "/usr/bin:/bin")
            .args(["notify", "run"]);
        command
    }

    fn spawn(&self) -> Running {
        let log = self.root.join("log");
        let stderr = fs::File::create(&log).unwrap();
        let child = start(
            self.command()
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(stderr),
        );
        Running { child, log }
    }

    fn append_event(&self, line: &str) {
        fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.state().join("events.tsv"))
            .unwrap()
            .write_all(line.as_bytes())
            .unwrap();
    }

    fn events_on(&self) -> bool {
        self.state().join("events.on").exists()
    }
}

/// A service that was started, with its stderr in a file. A test that fails halfway leaves no service behind.
struct Running {
    child: Child,
    log: PathBuf,
}

impl Running {
    fn pid(&self) -> u32 {
        self.child.id()
    }

    fn log(&self) -> String {
        String::from_utf8_lossy(&fs::read(&self.log).unwrap_or_default()).into_owned()
    }

    /// The lines of the log with the time taken off.
    fn lines(&self) -> Vec<String> {
        self.log()
            .lines()
            .map(|line| {
                line.split_once(' ')
                    .map_or(line, |(_, rest)| rest)
                    .to_owned()
            })
            .collect()
    }

    fn has(&self, text: &str) -> bool {
        self.lines().iter().any(|line| line.contains(text))
    }

    /// True when `text` is in the log within `WAIT_MS`.
    fn says(&self, text: &str) -> bool {
        until(|| self.has(text), WAIT_MS)
    }

    fn signal(&self, signal: Signal) {
        let pid = Pid::from_raw(i32::try_from(self.pid()).unwrap()).unwrap();
        kill_process(pid, signal).unwrap();
    }

    /// The exit status, waited for.
    fn exit(&mut self) -> ExitStatus {
        let mut status = None;
        until(
            || {
                status = self.child.try_wait().unwrap();
                status.is_some()
            },
            WAIT_MS,
        );
        status.unwrap_or_else(|| panic!("the service did not exit:\n{}", self.log()))
    }
}

impl Drop for Running {
    fn drop(&mut self) {
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

/// A service that is waiting to read its options: `notify.toml` is a FIFO with no writer, and the service has taken its lock and registered for signals. The returned function gives the service `text` to read, after the signal thread has had time to see a signal that was sent. The file that the service reads once more after it armed its watch is the same text as a regular file, put in the place of the FIFO before the first read ends, so that no read waits for a writer that is not there and none is given the text twice.
fn waiting_for_options(fake: &Fake) -> (Running, impl FnOnce(&'static str)) {
    fs::create_dir_all(fake.plugins()).unwrap();
    let made = run(Command::new("mkfifo").arg(fake.options_file()));
    assert!(made.status.success());
    let running = fake.spawn();
    assert!(
        until(|| fake.lock().exists(), WAIT_MS),
        "the service took no lock:\n{}",
        running.log()
    );
    let fifo = fake.options_file();
    let next = fake.root.join("options.next");
    let supply = move |text: &'static str| {
        // The start has no line to wait for: this is the time a signal takes to reach the signal thread.
        thread::sleep(Duration::from_millis(1500));
        fs::write(&next, text).unwrap();
        // Not joined: a service that never reads leaves this thread waiting in the open, and the test has already failed.
        thread::spawn(move || {
            let mut write_end = fs::OpenOptions::new().write(true).open(&fifo).unwrap();
            write_end.write_all(text.as_bytes()).unwrap();
            fs::rename(&next, &fifo).unwrap();
        });
    };
    (running, supply)
}

#[test]
fn a_stop_during_a_failing_start_ends_the_process_as_a_stop_ends_it() {
    let fake = Fake::new("service-stop-failing-start");
    fake.break_follower();
    let (mut running, fill) = waiting_for_options(&fake);
    running.signal(Signal::TERM);
    fill(LOG_BACKEND);
    let status = running.exit();
    assert_eq!(status.code(), Some(0), "{}", running.log());
    assert!(!running.has("could not start"), "{}", running.log());
    assert!(!fake.lock().exists(), "the lock is released");
}

#[test]
fn a_signal_during_a_start_that_fails_logs_no_stopping() {
    let fake = Fake::new("service-signal-failing-start");
    fake.break_follower();
    let (mut running, fill) = waiting_for_options(&fake);
    running.signal(Signal::TERM);
    fill(LOG_BACKEND);
    running.exit();
    assert!(!running.has("stopping"), "{}", running.log());
    assert!(!running.has("started"), "{}", running.log());
}

#[test]
fn a_signal_during_a_start_that_succeeds_logs_started_and_then_stopping() {
    let fake = Fake::new("service-signal-during-start");
    let (mut running, fill) = waiting_for_options(&fake);
    running.signal(Signal::TERM);
    fill(LOG_BACKEND);
    let status = running.exit();
    assert_eq!(status.code(), Some(0), "{}", running.log());
    let lines = running.lines();
    let at = |text: &str| lines.iter().position(|line| line.starts_with(text));
    assert!(
        at("started pid ") < at("stopping (SIGTERM)") && at("started pid ").is_some(),
        "started comes first and stopping after it:\n{}",
        running.log()
    );
    assert_eq!(lines.last().map(String::as_str), Some("stopping (SIGTERM)"));
    assert!(!fake.lock().exists());
    assert!(!fake.events_on());
}

#[test]
fn a_failed_follower_start_writes_the_line_exits_1_and_releases_the_lock() {
    let fake = Fake::logging("service-follower-fails");
    fake.break_follower();
    let mut running = fake.spawn();
    let status = running.exit();
    assert_eq!(status.code(), Some(1), "{}", running.log());
    assert!(
        running
            .lines()
            .iter()
            .any(|line| line.starts_with("could not start: ") && line.contains("events.tsv")),
        "{}",
        running.log()
    );
    assert!(!running.has("started"));
    assert!(!fake.lock().exists(), "the lock is released");
}

#[test]
fn a_failed_start_with_stderr_a_closed_pipe_exits_1_and_is_not_killed_by_sigpipe() {
    let fake = Fake::logging("service-start-fails-closed-stderr");
    fake.break_follower();
    let mut child = start(
        fake.command()
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(common::closed_pipe()),
    );
    let mut status = None;
    until(
        || {
            status = child.try_wait().unwrap();
            status.is_some()
        },
        WAIT_MS,
    );
    let status = status.unwrap_or_else(|| {
        let _ = child.kill();
        panic!("the service did not exit")
    });
    assert_eq!(status.code(), Some(1), "{status:?}");
}

/// Whether this process may read a directory it has no read permission on: root may.
fn is_root() -> bool {
    rustix::process::geteuid().is_root()
}

/// Gives a directory its permission back so that the scratch directory can be removed.
struct Restore(PathBuf);

impl Drop for Restore {
    fn drop(&mut self) {
        let _ = fs::set_permissions(&self.0, fs::Permissions::from_mode(0o755));
    }
}

#[test]
fn a_failed_options_watch_is_not_a_failed_start() {
    if is_root() {
        // libtest captures `eprintln!` of a passing test; a write to the stderr handle is shown.
        let _ = writeln!(
            io::stderr(),
            "skipped: root can read a directory that has no read permission, so the options watch does not fail"
        );
        return;
    }
    let fake = Fake::logging("service-options-watch-fails");
    // The directory can be entered and its file read, and cannot be watched: it cannot be opened for reading.
    let _restore = Restore(fake.plugins());
    fs::set_permissions(fake.plugins(), fs::Permissions::from_mode(0o311)).unwrap();
    let mut running = fake.spawn();
    assert!(running.says("started pid "), "{}", running.log());
    assert!(running.has("options watch failed "), "{}", running.log());
    assert!(!running.has("could not start"), "{}", running.log());
    running.signal(Signal::TERM);
    assert_eq!(running.exit().code(), Some(0));
}

#[test]
fn a_running_service_posts_a_notice_and_stops_on_sigterm() {
    let fake = Fake::logging("service-runs");
    let mut running = fake.spawn();
    assert!(running.says("started pid "), "{}", running.log());
    let started = running
        .lines()
        .into_iter()
        .find(|line| line.starts_with("started"))
        .unwrap();
    assert_eq!(
        started,
        format!(
            "started pid {} backend log options {} (found)",
            running.pid(),
            fake.root.join("config/plugins/notify.toml").display()
        )
    );
    assert!(fake.events_on(), "the stream is on while the service runs");
    // at event key sessionId agent pane cwd transcript config tool sub text label
    fake.append_event("1760000000\tStop\t12\tsess-1\t\t%12\t/tmp/x\t\t\t\t\t\t\n");
    assert!(running.says("notice turn_done 12 "), "{}", running.log());
    running.signal(Signal::TERM);
    assert_eq!(running.exit().code(), Some(0));
    assert_eq!(
        running.lines().last().map(String::as_str),
        Some("stopping (SIGTERM)")
    );
    assert!(!fake.lock().exists(), "the lock is released");
    assert!(!fake.events_on(), "the stream is off");
}

/// The parity scenarios `rows: ...` and `locale: ...`: node's timer for a deadline that is overdue at start runs after the synchronous start, so `started` is the first line and the notice is the second.
#[test]
fn a_notice_that_is_due_at_start_is_logged_after_started() {
    let fake = Fake::logging("service-due-at-start");
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    // at state sessionId cwd transcript detail
    fs::write(
        fake.state().join("12.tsv"),
        format!("{}\tdone\tsess-1\t/tmp/x\t\t\n", now - 55 * 60),
    )
    .unwrap();
    let mut running = fake.spawn();
    assert!(
        running.says("notice cache_expiring 12 "),
        "{}",
        running.log()
    );
    let lines = running.lines();
    let at = |text: &str| {
        lines
            .iter()
            .position(|line| line.starts_with(text))
            .unwrap()
    };
    assert!(
        at("started pid ") < at("notice cache_expiring 12 "),
        "started comes before the notice that was due at start:\n{}",
        running.log()
    );
    running.signal(Signal::TERM);
    assert_eq!(running.exit().code(), Some(0));
}

#[test]
fn stopping_names_sigint_and_sighup() {
    for (signal, name) in [(Signal::INT, "SIGINT"), (Signal::HUP, "SIGHUP")] {
        let fake = Fake::logging(&format!("service-stops-on-{name}"));
        let mut running = fake.spawn();
        assert!(running.says("started pid "), "{}", running.log());
        running.signal(signal);
        assert_eq!(running.exit().code(), Some(0), "{name}");
        assert_eq!(running.lines().last(), Some(&format!("stopping ({name})")));
        assert!(!fake.lock().exists());
    }
}

#[test]
fn an_unrelated_file_in_the_options_directory_logs_nothing_and_keeps_the_options() {
    let fake = Fake::new("service-unrelated-file");
    fake.options("backend = \"log\"\nclick = \"goto\"\n");
    let mut running = fake.spawn();
    assert!(running.says("started pid "), "{}", running.log());
    let before = running.lines();
    fs::write(fake.plugins().join("unrelated.toml"), "").unwrap();
    fake.options("backend = \"log\"\nclick = \"goto\"\n");
    // The wakes come on one channel in the order they happened: a marker event the service must answer, written after the two that must not be, shows by its own notice that the first two were read.
    fake.append_event("1760000000\tStop\t12\tsess-marker\t\t%12\t/tmp/x\t\t\t\t\t\t\n");
    assert!(running.says("notice turn_done 12 "), "{}", running.log());
    let after = running.lines();
    let since: Vec<&str> = after[before.len()..]
        .iter()
        .map(String::as_str)
        .take_while(|line| !line.starts_with("notice turn_done 12 "))
        .collect();
    // The marker's own `post` line comes before its notice; it is the only line expected between `before` and the notice.
    assert!(
        matches!(since.as_slice(), [post] if post.starts_with("post tagents-12 turn_done ")),
        "an unrelated file and the same bytes written again say nothing, whatever the line: {since:?} in {}",
        running.log()
    );
    fake.options("backend = \"log\"\nclick = \"focus\"\n");
    assert!(running.says("options reloaded"), "{}", running.log());
    assert_eq!(
        running
            .lines()
            .iter()
            .filter(|line| *line == "options reloaded")
            .count(),
        1,
        "the change is one reload"
    );
    running.signal(Signal::TERM);
    assert_eq!(running.exit().code(), Some(0));
}

#[test]
fn backend_none_leaves_at_once_and_releases_the_lock() {
    let fake = Fake::new("service-backend-none");
    fake.options("backend = \"none\"\n");
    let mut running = fake.spawn();
    assert_eq!(running.exit().code(), Some(0), "{}", running.log());
    assert_eq!(
        running.lines(),
        ["backend none: nothing to post; exiting"],
        "no `started` and no `stopping`"
    );
    assert!(!fake.lock().exists());
    assert!(!fake.events_on());
}

#[test]
fn a_lock_held_by_a_live_process_is_logged_and_left() {
    let fake = Fake::logging("service-lock-held");
    // This test is alive and is not the service: a lock naming it is held by another process.
    let held = format!("{}\n", std::process::id());
    fs::write(fake.lock(), &held).unwrap();
    let mut running = fake.spawn();
    assert_eq!(running.exit().code(), Some(0), "{}", running.log());
    assert_eq!(
        running.lines(),
        [format!(
            "another notify service holds {} (pid {}); exiting",
            fake.lock().display(),
            std::process::id()
        )]
    );
    assert_eq!(
        fs::read_to_string(fake.lock()).unwrap(),
        held,
        "the lock is untouched"
    );
}

#[cfg(target_os = "macos")]
#[test]
fn a_service_with_no_config_dir_says_reload_is_off_before_started() {
    let fake = Fake::new("service-no-config-dir");
    let mut running = fake.spawn();
    assert!(running.says("started pid "), "{}", running.log());
    let lines = running.lines();
    let at = |text: &str| {
        lines
            .iter()
            .position(|line| line.starts_with(text))
            .unwrap()
    };
    assert!(
        at("options reload is off:") < at("started pid "),
        "started is said last:\n{}",
        running.log()
    );
    assert!(lines[at("started pid ")].ends_with("(not found)"));
    running.signal(Signal::TERM);
    assert_eq!(running.exit().code(), Some(0));
}

// The defaults pick the macOS backend, which the other systems do not have: there the service leaves at once.
#[cfg(target_os = "macos")]
#[test]
fn an_invalid_options_file_keeps_the_service_running_on_the_defaults_until_sigterm() {
    let fake = Fake::new("service-invalid-options");
    fake.options("events = 7\n");
    let mut running = fake.spawn();
    assert!(running.says("started pid "), "{}", running.log());
    let lines = running.lines();
    let at = |text: &str| {
        lines
            .iter()
            .position(|line| line.starts_with(text))
            .unwrap()
    };
    assert!(
        at("options: ") < at("started pid "),
        "the problem is logged before started:\n{}",
        running.log()
    );
    assert!(lines[at("started pid ")].ends_with("(invalid)"));
    assert!(
        running.child.try_wait().unwrap().is_none(),
        "the service did not leave"
    );
    assert!(fake.lock().exists());
    running.signal(Signal::TERM);
    assert_eq!(running.exit().code(), Some(0), "{}", running.log());
    assert!(!fake.lock().exists());
}

#[cfg(target_os = "linux")]
#[test]
fn on_linux_the_auto_backend_leaves_with_its_reason() {
    let fake = Fake::new("service-linux-auto");
    let mut running = fake.spawn();
    assert_eq!(running.exit().code(), Some(0), "{}", running.log());
    assert_eq!(
        running.lines(),
        ["no notification backend for linux yet; exiting"]
    );
    assert!(!fake.lock().exists());
}
