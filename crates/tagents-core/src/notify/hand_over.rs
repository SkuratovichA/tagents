//! A start that fails is handed to the node service: the order of what the Rust daemon does when a step before its `started` line fails.
//!
//! A stop that was requested wins: the process ends as a stop ends it (the follower closed, the lock released, exit 0, no `stopping` line, because that line belongs to a service that logged `started`) and nothing is exec'd. Otherwise the daemon says so, closes what the follower and the watches hold, keeps the lock held and replaces the process with the node service, which runs, or fails by its own lines. The exec keeps the pid, so the lock still names it, and the node service treats a lock held by its own pid as not held: there is no moment in which a manual `run` could take the lock and the node service find it held. The lock is released only on the paths that end the process. The `handing over to the node service:` line is written before the close because it states the intent of a close that can take long, so a stop that lands during the close still exits 0 without the exec, after that line.

use std::{ffi::OsString, process::ExitCode};

use crate::{
    ending::Stop,
    node::{self, ExecFailure},
    notify::{lock::release_lock, log::Log},
};

/// Where the node service sits below the root.
const NODE_NOTIFY: &str = "packages/notify/dist/main.js";

/// The exit of a service that was handed over to and could not be: node's code for a start that failed, which launchd retries.
const FAILED: u8 = 1;

/// The service's lock file. It can be made before the lock is taken: `release` unlinks the file only while it names this process.
pub struct Lock(String);

impl Lock {
    pub fn new(file: String) -> Lock {
        Lock(file)
    }

    pub fn file(&self) -> &str {
        &self.0
    }

    /// `releaseQuietly`: a failure is a line, never an error.
    pub fn release(&self, log: &dyn Log) {
        self.release_with(log, release_lock);
    }

    fn release_with(&self, log: &dyn Log, release: impl FnOnce(&str) -> Result<(), String>) {
        if let Err(why) = release(&self.0) {
            log.line(&["could not release the lock", &self.0, &why]);
        }
    }
}

/// What a failed start does, given `why` it failed. `close` closes the follower and the watches the start opened, and runs on every path; the process is replaced and this does not return, unless the node service could not be started or a stop was requested. A stop that lands during `close` is checked a second time: it exits 0 without the exec, after the `handing over to the node service:` line was written.
pub fn hand_over(
    why: &str,
    stop: &Stop,
    lock: &Lock,
    log: &dyn Log,
    close: impl FnOnce(),
) -> ExitCode {
    hand_over_with(why, stop, lock, log, close, || {
        node::exec(NODE_NOTIFY, &[OsString::from("run")])
    })
}

/// `hand_over` with the exec given, so that a test can look at the world at the moment of the exec.
fn hand_over_with(
    why: &str,
    stop: &Stop,
    lock: &Lock,
    log: &dyn Log,
    close: impl FnOnce(),
    exec: impl FnOnce() -> ExecFailure,
) -> ExitCode {
    if stop.is_stopped() {
        close();
        lock.release(log);
        return ExitCode::SUCCESS;
    }
    log.line(&["handing over to the node service:", why]);
    close();
    // `close` can drain a helper post for a long while, and a stop that lands then is recorded and never read again: node would start with none pending.
    if stop.is_stopped() {
        lock.release(log);
        return ExitCode::SUCCESS;
    }
    let failure = exec();
    lock.release(log);
    log.line(&[
        "could not hand over to the node service:",
        &failure_text(&failure),
    ]);
    ExitCode::from(FAILED)
}

/// A program that is not there says where it looked, as `node::program` does; a node that cannot run says what the system said, as node words it.
fn failure_text(failure: &ExecFailure) -> String {
    match failure {
        ExecFailure::Missing(why) => why.clone(),
        ExecFailure::Run { node, err } => {
            node::io_message(err, "exec", Some(&node.to_string_lossy()))
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::fs;
    use std::io;

    use super::*;
    use crate::notify::lock::LOCK_FILE;
    use crate::notify::log::RecordingLog;
    use crate::testing::Scratch;

    /// The lock file of a scratch directory, holding this process's pid as a taken lock does.
    fn taken(scratch: &Scratch) -> Lock {
        let file = format!("{}/{LOCK_FILE}", scratch.dir());
        fs::write(&file, format!("{}\n", std::process::id())).unwrap();
        Lock::new(file)
    }

    fn exits(code: ExitCode, want: u8) {
        assert_eq!(format!("{code:?}"), format!("{:?}", ExitCode::from(want)));
    }

    #[test]
    fn a_stop_that_was_requested_closes_and_releases_and_execs_nothing() {
        let scratch = Scratch::new();
        let lock = taken(&scratch);
        let log = RecordingLog::new();
        let stop = Stop::default();
        stop.stop();
        let steps = RefCell::new(Vec::new());
        let code = hand_over_with(
            "EISDIR: illegal operation on a directory",
            &stop,
            &lock,
            &log,
            || steps.borrow_mut().push("close"),
            || {
                steps.borrow_mut().push("exec");
                ExecFailure::Missing("never".into())
            },
        );
        exits(code, 0);
        assert_eq!(*steps.borrow(), ["close"]);
        assert_eq!(log.lines(), Vec::<String>::new());
        assert!(!fs::exists(lock.file()).unwrap(), "the lock is released");
    }

    #[test]
    fn a_stop_that_lands_during_the_close_execs_nothing_and_exits_0() {
        let scratch = Scratch::new();
        let lock = taken(&scratch);
        let log = RecordingLog::new();
        let stop = Stop::default();
        let steps = RefCell::new(Vec::new());
        let code = hand_over_with(
            "EISDIR: illegal operation on a directory",
            &stop,
            &lock,
            &log,
            || {
                steps.borrow_mut().push("close");
                stop.stop();
            },
            || {
                steps.borrow_mut().push("exec");
                ExecFailure::Missing("never".into())
            },
        );
        exits(code, 0);
        assert_eq!(*steps.borrow(), ["close"]);
        assert_eq!(
            log.lines(),
            ["handing over to the node service: EISDIR: illegal operation on a directory"]
        );
        assert!(!fs::exists(lock.file()).unwrap(), "the lock is released");
    }

    #[test]
    fn a_hand_over_says_why_closes_and_keeps_the_lock_across_the_exec() {
        let scratch = Scratch::new();
        let lock = taken(&scratch);
        let log = RecordingLog::new();
        let steps = RefCell::new(Vec::new());
        let code = hand_over_with(
            "EISDIR: illegal operation on a directory, open 'x'",
            &Stop::default(),
            &lock,
            &log,
            || steps.borrow_mut().push("close".to_owned()),
            || {
                // The world as the node service would find it: closed, and the lock still ours.
                steps.borrow_mut().push(format!(
                    "exec with the lock {}",
                    if fs::exists(lock.file()).unwrap() {
                        "held"
                    } else {
                        "gone"
                    }
                ));
                ExecFailure::Missing("/r/packages/notify/dist/main.js is not a file".into())
            },
        );
        assert_eq!(*steps.borrow(), ["close", "exec with the lock held"]);
        exits(code, 1);
        assert_eq!(
            log.lines(),
            [
                "handing over to the node service: EISDIR: illegal operation on a directory, open 'x'",
                "could not hand over to the node service: /r/packages/notify/dist/main.js is not a file",
            ]
        );
        assert!(
            !fs::exists(lock.file()).unwrap(),
            "an exec that failed releases the lock"
        );
    }

    #[test]
    fn a_node_that_cannot_run_is_worded_as_node_words_a_failed_syscall() {
        let scratch = Scratch::new();
        let lock = taken(&scratch);
        let log = RecordingLog::new();
        hand_over_with(
            "why",
            &Stop::default(),
            &lock,
            &log,
            || {},
            || ExecFailure::Run {
                node: "node".into(),
                err: io::Error::from_raw_os_error(2),
            },
        );
        assert_eq!(
            log.lines().last().unwrap(),
            "could not hand over to the node service: ENOENT: no such file or directory, exec 'node'"
        );
    }

    #[test]
    fn a_lock_that_is_not_ours_is_left_where_it_is() {
        let scratch = Scratch::new();
        let file = format!("{}/{LOCK_FILE}", scratch.dir());
        // pid 1 is never this test.
        fs::write(&file, "1\n").unwrap();
        let lock = Lock::new(file.clone());
        let log = RecordingLog::new();
        lock.release(&log);
        assert!(fs::exists(&file).unwrap());
        assert_eq!(log.lines(), Vec::<String>::new());
    }

    #[test]
    fn a_lock_that_cannot_be_released_is_a_line() {
        let log = RecordingLog::new();
        Lock::new("/s/notify.lock".into()).release_with(&log, |_| {
            Err("EACCES: permission denied, unlink '/s/notify.lock'".into())
        });
        assert_eq!(
            log.lines(),
            [
                "could not release the lock /s/notify.lock EACCES: permission denied, unlink '/s/notify.lock'"
            ]
        );
    }
}
