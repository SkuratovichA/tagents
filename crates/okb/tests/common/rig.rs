//! A fake program for the tests of the MCP server: a shell script in a directory that is the whole PATH, so nothing of the machine can answer. A script finds its own directory in `$D` and writes the pids it wants checked there, one file each (`main.pid`, `grand.pid`): `Rig::pids` reads them back, and a rig that is dropped kills whatever is still alive, so a test that fails halfway leaves no `sleep` behind.

// Test code: a failed unwrap here is the failure report.
#![allow(clippy::unwrap_used, clippy::expect_used)]
#![allow(dead_code)]

use std::{
    collections::{BTreeMap, HashMap},
    ffi::OsString,
    fs,
    io::Write,
    path::PathBuf,
    thread,
    time::{Duration, Instant},
};

use rustix::process::{Pid, Signal, kill_process, kill_process_group, test_kill_process};

use super::{scratch, write_executable};

/// The contract the tests of `packages/mcp` use (`test/rig.ts`): one program and four verbs, one of which needs tmux.
pub const FAKE_CONTRACT: &str = r#"{"cli":{"tagents-fake":{"exit":{"ok":0,"error":1,"usage":2,"refused":3,"timeout":4},"commands":[
{"path":["echo"],"positionals":["[text]"],"options":{"loud":{"type":"boolean"},"name":{"type":"string"}},"required":[],"summary":"prints","effect":"read"},
{"path":["stdin"],"positionals":[],"options":{},"required":[],"summary":"reads stdin","effect":"read"},
{"path":["hang"],"positionals":[],"options":{},"required":[],"summary":"never ends","effect":"read"},
{"path":["window"],"positionals":[],"options":{},"required":[],"summary":"opens a window","effect":"spawn","requires":"tmux"}]}}}"#;

/// A program that starts a `sleep 30` of its own and waits for it: two processes, both of which have to go.
pub const WITH_GRANDCHILD: &str =
    r#"echo $$ > "$D/main.pid"; sleep 30 & echo $! > "$D/grand.pid"; wait"#;

pub struct Rig {
    pub dir: PathBuf,
}

impl Rig {
    /// A rig of its own named `name`, whose program `tagents-fake` runs `script`.
    pub fn new(name: &str, script: &str) -> Rig {
        let dir = scratch(name).canonicalize().unwrap();
        write_executable(
            &dir.join("tagents-fake"),
            &format!("#!/bin/sh\nD=$(dirname \"$0\")\n{script}\n"),
        );
        Rig { dir }
    }

    /// The environment of a call: the rig's directory and the system's, nothing else.
    pub fn env(&self) -> HashMap<OsString, OsString> {
        HashMap::from([(OsString::from("PATH"), self.path())])
    }

    pub fn path(&self) -> OsString {
        let mut path = self.dir.clone().into_os_string();
        path.push(":/usr/bin:/bin");
        path
    }

    /// The contract of `FAKE_CONTRACT`, written beside the program.
    pub fn contract(&self) -> PathBuf {
        let file = self.dir.join("contract.json");
        fs::write(&file, FAKE_CONTRACT).unwrap();
        file
    }

    /// The pids the script wrote into `$D/*.pid`, by file name without the extension.
    pub fn pids(&self) -> BTreeMap<String, i32> {
        let mut pids = BTreeMap::new();
        for entry in fs::read_dir(&self.dir).unwrap().flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let Some(stem) = name.strip_suffix(".pid") else {
                continue;
            };
            // A file the script is still writing holds no number yet.
            if let Some(pid) = fs::read_to_string(entry.path())
                .ok()
                .and_then(|text| text.trim().parse().ok())
            {
                pids.insert(stem.to_owned(), pid);
            }
        }
        pids
    }

    /// Whether `count` processes of the script have started. A liveness wait, not a timing check: a process start waits when a test that writes an executable is queued for the write side of `FORK_GATE` behind the calls in flight, so on a loaded machine the ceiling is wide and the wait ends as soon as they are up.
    pub fn started(&self, count: usize) -> bool {
        until(|| self.pids().len() == count, 30_000)
    }

    /// Whether every process the script recorded is gone, within a bounded wait.
    pub fn none_alive(&self) -> bool {
        until(|| self.pids().values().all(|pid| !alive(*pid)), 5000)
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        for pid in self.pids().into_values().filter(|pid| alive(*pid)) {
            if let Some(pid) = Pid::from_raw(pid) {
                let _ = kill_process_group(pid, Signal::KILL);
                let _ = kill_process(pid, Signal::KILL);
            }
        }
    }
}

/// A program that starts a helper in a session of its own, so outside the call's group, then waits for the helper's pid file and runs `after`. `perl` is what the helper runs before it replaces itself with the code of `exec`.
pub fn escapee_program(perl: &str, after: &str) -> String {
    format!(
        r#"/usr/bin/perl -MPOSIX -e 'POSIX::setsid(); open(F, ">", "$ARGV[0]/escaped.pid"); print F "$$\n"; close F; {perl}' "$D" & n=0; until [ -s "$D/escaped.pid" ] || [ $n -ge 200 ]; do n=$((n+1)); sleep 0.05; done; {after}"#
    )
}

/// Whether `/usr/bin/perl` exists, for the tests that start a process in a session of its own; says so when it does not, so the skip is visible.
pub fn has_perl() -> bool {
    let found = std::path::Path::new("/usr/bin/perl").exists();
    if !found {
        // libtest captures `eprintln!` of a passing test; a write to the stderr handle is shown.
        let _ = writeln!(
            std::io::stderr(),
            "no perl to start a process in a session of its own: skipped"
        );
    }
    found
}

/// `kill -0`: the process exists. It spawns nothing, so a test may ask while a call of its own holds the fork gate.
pub fn alive(pid: i32) -> bool {
    Pid::from_raw(pid).is_some_and(|pid| test_kill_process(pid).is_ok())
}

/// A bounded poll: true as soon as the condition holds, false when `ms` have passed.
pub fn until(mut condition: impl FnMut() -> bool, ms: u64) -> bool {
    let deadline = Instant::now() + Duration::from_millis(ms);
    while Instant::now() < deadline {
        if condition() {
            return true;
        }
        thread::sleep(Duration::from_millis(25));
    }
    condition()
}
