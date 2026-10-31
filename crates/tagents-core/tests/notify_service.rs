//! `tagents-core notify run` as a process: the start, the stop, and the hand-over of a start that failed to the node service.
//!
//! Each test makes a root of its own, as `front_door.rs` does (`target/debug/tagents-core` three levels below the directory that holds `packages/notify/dist/main.js`), with a stub in place of the node service that writes down its pid, its arguments and the lock it found. The service runs with `env_clear` and a scratch `HOME`, state directory, config directory and tmux directory, so nothing of the machine's own is read or written, and the log backend, which posts nothing.
//! A signal that has to land during the start is sent while the service waits to read its options, which is a FIFO until the test fills it.

// Test code: a failed unwrap here is the failure report.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::{
    fs,
    io::Write,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::PathBuf,
    process::{Child, Command, ExitStatus, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::Duration,
};

use rustix::{
    fs::OFlags,
    process::{Pid, Signal, kill_process},
};

mod common;
use common::{rig::until, run, scratch, start, write_executable, writing};

const BIN: &str = env!("CARGO_BIN_EXE_tagents-core");
/// Long enough for a start to finish on a loaded machine.
const WAIT_MS: u64 = 20_000;
const LOG_BACKEND: &str = "backend = \"log\"\n";

/// A stub of the node service: what it was given and the lock it found, then the exit code the test asked for.
const STUB_NODE: &str = "#!/bin/sh\n{ printf 'pid=%s\\n' \"$$\"; printf 'lock=%s\\n' \"$(cat \"$TA_STATE_DIR/notify.lock\")\"; printf 'arg=%s\\n' \"$@\"; } > \"$HANDED\"\nexit \"${STUB_EXIT:-0}\"\n";

/// A directory of a test's own that holds a copy of the binary where a checkout has it, the stub, and the state and config the service runs on.
struct Fake {
    root: PathBuf,
    node: PathBuf,
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
        fs::create_dir_all(root.join("packages/notify/dist")).unwrap();
        fs::write(root.join("packages/notify/dist/main.js"), "// stub\n").unwrap();
        let node = root.join("node");
        write_executable(&node, STUB_NODE);
        for dir in ["state", "home", "tmux"] {
            fs::create_dir_all(root.join(dir)).unwrap();
        }
        Fake { root, node }
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

    fn handed(&self) -> PathBuf {
        self.root.join("handed")
    }

    fn options(&self, text: &str) {
        fs::create_dir_all(self.plugins()).unwrap();
        fs::write(self.options_file(), text).unwrap();
    }

    /// A state directory whose events file cannot be followed: the follower's start fails, which is the failure a hand-over answers.
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
            .env("TAGENTS_NODE", &self.node)
            .env("HANDED", self.handed())
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

    /// What the stub wrote down, or `None` when it never ran.
    fn handed_over(&self) -> Option<Vec<String>> {
        let text = fs::read_to_string(self.handed()).ok()?;
        Some(text.lines().map(str::to_owned).collect())
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

/// The writer end of the FIFO that stands for `notify.toml`: every read of the file is given `text`, until this is dropped. A write end is opened without blocking, so a service that does not read again leaves no thread stuck in an `open`.
struct Supplier {
    done: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}

impl Drop for Supplier {
    fn drop(&mut self) {
        self.done.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            thread.join().unwrap();
        }
    }
}

/// A service that is waiting to read its options: `notify.toml` is a FIFO with no writer, and the service has taken its lock and registered for signals. The returned function gives each read of the file `text` after the signal thread has had time to see a signal that was sent.
fn waiting_for_options(fake: &Fake) -> (Running, impl FnOnce(&'static str) -> Supplier) {
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
    let supply = move |text: &'static str| {
        // The start has no line to wait for: this is the time a signal takes to reach the signal thread.
        thread::sleep(Duration::from_millis(1500));
        let done = Arc::new(AtomicBool::new(false));
        let stopped = Arc::clone(&done);
        let thread = thread::spawn(move || {
            let nonblocking = i32::try_from(OFlags::NONBLOCK.bits()).unwrap();
            while !stopped.load(Ordering::SeqCst) {
                match fs::OpenOptions::new()
                    .write(true)
                    .custom_flags(nonblocking)
                    .open(&fifo)
                {
                    // A reader that has gone by the time of the write is the service done reading: the next open finds out. The pause keeps one read from being given the text twice.
                    Ok(mut file) => {
                        drop(file.write_all(text.as_bytes()));
                        thread::sleep(Duration::from_millis(100));
                    }
                    Err(_) => thread::sleep(Duration::from_millis(10)),
                }
            }
        });
        Supplier {
            done,
            thread: Some(thread),
        }
    };
    (running, supply)
}

fn stub_pid(handed: &[String]) -> &str {
    handed[0].strip_prefix("pid=").unwrap()
}

#[test]
fn a_stop_during_a_failing_start_ends_the_process_and_does_not_exec() {
    let fake = Fake::new("service-stop-failing-start");
    fake.break_follower();
    let (mut running, fill) = waiting_for_options(&fake);
    running.signal(Signal::TERM);
    let _supplier = fill(LOG_BACKEND);
    let status = running.exit();
    assert_eq!(status.code(), Some(0), "{}", running.log());
    assert_eq!(fake.handed_over(), None, "the node service was not exec'd");
    assert!(!running.has("handing over"), "{}", running.log());
    assert!(!fake.lock().exists(), "the lock is released");
}

#[test]
fn a_signal_during_a_start_that_fails_logs_no_stopping() {
    let fake = Fake::new("service-signal-failing-start");
    fake.break_follower();
    let (mut running, fill) = waiting_for_options(&fake);
    running.signal(Signal::TERM);
    let _supplier = fill(LOG_BACKEND);
    running.exit();
    assert!(!running.has("stopping"), "{}", running.log());
    assert!(!running.has("started"), "{}", running.log());
}

#[test]
fn a_signal_during_a_start_that_succeeds_logs_started_and_then_stopping() {
    let fake = Fake::new("service-signal-during-start");
    let (mut running, fill) = waiting_for_options(&fake);
    running.signal(Signal::TERM);
    let _supplier = fill(LOG_BACKEND);
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
fn a_failed_follower_start_hands_over() {
    let fake = Fake::logging("service-follower-fails");
    fake.break_follower();
    let mut running = fake.spawn();
    // The stub is the node service: it ran in this process (the pid is kept) with the arguments node's `run` takes.
    let status = running.exit();
    assert_eq!(
        status.code(),
        Some(0),
        "the exit is the node service's: {}",
        running.log()
    );
    let handed = fake.handed_over().expect("the stub did not run");
    assert_eq!(stub_pid(&handed), running.pid().to_string());
    assert_eq!(
        handed[2..],
        [
            format!("arg={}/packages/notify/dist/main.js", fake.root.display()),
            "arg=run".to_owned()
        ]
    );
    let lines = running.lines();
    assert!(
        lines.iter().any(
            |line| line.starts_with("handing over to the node service: ")
                && line.contains("events.tsv")
        ),
        "{}",
        running.log()
    );
    assert!(!running.has("started"));
}

#[test]
fn the_lock_still_names_the_pid_after_the_exec() {
    let fake = Fake::logging("service-lock-after-exec");
    fake.break_follower();
    let mut running = fake.spawn();
    running.exit();
    let handed = fake.handed_over().expect("the stub did not run");
    let lock = handed[1].strip_prefix("lock=").unwrap();
    assert_eq!(
        lock.split_whitespace().next(),
        Some(stub_pid(&handed)),
        "the stub found the lock naming its own pid, which is the service's: {lock:?}"
    );
}

#[test]
fn an_exec_that_fails_writes_the_line_and_exits_1_with_the_lock_released() {
    let mut fake = Fake::logging("service-exec-fails");
    fake.break_follower();
    fake.node = fake.root.join("no-such-node");
    let mut running = fake.spawn();
    assert_eq!(running.exit().code(), Some(1), "{}", running.log());
    let lines = running.lines();
    let last = format!(
        "could not hand over to the node service: ENOENT: no such file or directory, exec '{}'",
        fake.node.display()
    );
    assert_eq!(lines.last(), Some(&last), "{}", running.log());
    assert!(running.has("handing over to the node service: "));
    assert!(!fake.lock().exists(), "the lock is released");
    assert_eq!(fake.handed_over(), None);
}

#[test]
fn a_missing_main_js_writes_the_same_line_exits_1_releases_the_lock_and_prints_no_cannot_find_line()
{
    let fake = Fake::logging("service-no-main-js");
    fake.break_follower();
    let main = fake.root.join("packages/notify/dist/main.js");
    fs::remove_file(&main).unwrap();
    let mut running = fake.spawn();
    assert_eq!(running.exit().code(), Some(1), "{}", running.log());
    assert_eq!(
        running.lines().last(),
        Some(&format!(
            "could not hand over to the node service: {} is not a file",
            main.display()
        ))
    );
    assert!(
        !running.log().contains("tagents-core: cannot find"),
        "{}",
        running.log()
    );
    assert!(!fake.lock().exists());
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
fn a_failed_options_watch_does_not_hand_over() {
    if is_root() {
        return;
    }
    let fake = Fake::logging("service-options-watch-fails");
    // The directory can be entered and its file read, and cannot be watched: it cannot be opened for reading.
    let _restore = Restore(fake.plugins());
    fs::set_permissions(fake.plugins(), fs::Permissions::from_mode(0o311)).unwrap();
    let mut running = fake.spawn();
    assert!(running.says("started pid "), "{}", running.log());
    assert!(running.has("options watch failed "), "{}", running.log());
    assert!(!running.has("handing over"), "{}", running.log());
    running.signal(Signal::TERM);
    assert_eq!(running.exit().code(), Some(0));
    assert_eq!(fake.handed_over(), None, "the node service was not exec'd");
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
    fake.options("click = \"goto\"\n");
    let mut running = fake.spawn();
    assert!(running.says("started pid "), "{}", running.log());
    let before = running.lines();
    fs::write(fake.plugins().join("unrelated.toml"), "").unwrap();
    fake.options("click = \"goto\"\n");
    // The file is read at each wake: quiet is the absence of a line for as long as a wake takes to come.
    thread::sleep(Duration::from_millis(1500));
    assert_eq!(
        running.lines(),
        before,
        "an unrelated file and the same bytes written again say nothing"
    );
    // And the watch is alive: a change is a reload.
    fake.options("click = \"focus\"\n");
    assert!(running.says("options reloaded"), "{}", running.log());
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
