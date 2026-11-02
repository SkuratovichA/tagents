//! Keeping the machine awake through a turn, as `holdAwake` of `keep-awake.ts` does (design D11). `caffeinate` exists on macOS only, and a failure of any step is silent: the CLI keeps no log.

use std::ffi::OsStr;
use std::process::{Child, Command, Stdio};

use rustix::process::{Pid, Signal, kill_process};

use crate::child::spawn_thread;

/// `keepAwakeWanted`: any value but `0`.
fn wanted(value: Option<&OsStr>) -> bool {
    value != Some(OsStr::new("0"))
}

/// `caffeinate` for the child `pid`, found on the CLI's own `PATH`, with all three streams ignored.
fn command(pid: u32) -> Command {
    let mut command = Command::new("caffeinate");
    command
        .args(["-i", "-w", &pid.to_string()])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    command
}

/// What holds the machine awake for the child `pid`, when that is wanted and it could be started.
pub fn hold(pid: u32) -> Option<Child> {
    if !wanted(std::env::var_os("TA_KEEP_AWAKE").as_deref()) {
        return None;
    }
    command(pid).spawn().ok()
}

/// A SIGTERM, which is what `child.kill()` of node sends, and a thread that reaps it so the process does not stay behind for as long as the call lingers.
pub fn release(mut holder: Child) {
    let _ = kill_process(Pid::from_child(&holder), Signal::TERM);
    let _ = spawn_thread("awake", move || {
        let _ = holder.wait();
    });
}

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::process::Child;
    use std::time::{Duration, Instant};
    use std::{fs, thread};

    use super::*;
    use crate::testing::{Scratch, gate};

    /// Says how it was started and what its streams are, and that it was told to go.
    const STUB: &str = "#!/bin/sh\nwaiting=\ntrap '[ -n \"$waiting\" ] && kill \"$waiting\" 2> /dev/null; echo released >> \"$0.record\"; exit 0' TERM\necho \"$*\" >> \"$0.record\"\nfor fd in 0 1 2; do [ /dev/fd/$fd -ef /dev/null ] && echo \"$fd is the null device\" >> \"$0.record\"; done\necho ready >> \"$0.record\"\nsleep 30 &\nwaiting=$!\nwait \"$waiting\"\n";

    fn on_path(dir: &Path, pid: u32) -> Child {
        let mut command = command(pid);
        command.env("PATH", format!("{}:/usr/bin:/bin", dir.display()));
        gate::start(&mut command)
    }

    /// The record, once it holds `line`. The wait is the failure of the test, never its pace.
    fn record_with(path: &Path, line: &str) -> String {
        let given_up = Instant::now() + Duration::from_secs(20);
        loop {
            let record = fs::read_to_string(path).unwrap_or_default();
            if record.lines().any(|held| held == line) {
                return record;
            }
            assert!(Instant::now() < given_up, "no {line} in {record}");
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn only_the_value_0_turns_it_off() {
        assert!(!wanted(Some(OsStr::new("0"))));
        assert!(wanted(None));
        assert!(wanted(Some(OsStr::new(""))));
        assert!(wanted(Some(OsStr::new("1"))));
        assert!(wanted(Some(OsStr::new("00"))));
    }

    #[test]
    fn it_runs_with_the_three_streams_ignored_until_it_gets_its_sigterm() {
        let scratch = Scratch::new();
        let stub = scratch.path().join("caffeinate");
        gate::write_executable(&stub, STUB);
        let record = scratch.path().join("caffeinate.record");
        let holder = on_path(scratch.path(), 4321);
        let started = record_with(&record, "ready");
        assert_eq!(
            started.lines().collect::<Vec<_>>(),
            [
                "-i -w 4321",
                "0 is the null device",
                "1 is the null device",
                "2 is the null device",
                "ready"
            ]
        );
        release(holder);
        record_with(&record, "released");
    }

    #[test]
    fn a_holder_that_cannot_be_started_is_nothing() {
        let scratch = Scratch::new();
        let mut command = command(1);
        command.env("PATH", scratch.path());
        let _forking = gate::forking();
        assert!(command.spawn().is_err());
    }
}
