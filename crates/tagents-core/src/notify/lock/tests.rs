//! Cases of `packages/notify/test/service.test.ts` for the lock (the cases that drive a whole service are scenarios of the differential suite), one Rust test each:
//! - a lock held by another live process: `a_lock_held_by_a_live_process_is_reported_and_not_touched`
//! - a lock in the old format, a bare pid, is still read: `a_bare_pid_lock_is_read_and_a_live_pid_holds_it`
//! - a live pid whose start time is not the recorded one is a reused pid: `a_live_pid_with_another_start_time_is_a_reused_pid_and_the_lock_is_taken_over`
//! - when ps cannot name the holder, the age of the lock decides: `when_ps_cannot_name_the_holder_the_age_of_the_lock_decides`
//! - the lock names our pid and start time, and ps is asked only for the lock: `a_free_lock_is_taken_naming_pid_and_start_without_asking_ps`; "never per event" is not applicable: take_lock is not called per event
//! - a lock with a dead pid is taken over: `a_lock_with_a_dead_pid_is_taken_over`
//! - an old-format lock from before the last boot is stale: `a_bare_pid_lock_from_before_the_boot_is_stale_although_its_pid_is_alive`
//! - an unparseable lock is taken over: `an_unparseable_lock_is_taken_over`
//! - our lock is removed on stop, and stopping twice is one stop: `our_lock_is_removed_on_release_and_releasing_twice_is_one_release`; the one `stopping` line is the service's
//! - a lock someone else took over survives our stop: `a_lock_someone_else_took_over_survives_our_release`
//! - a lock that cannot be removed: `a_lock_that_cannot_be_removed_gives_the_failure_text_and_stays`; the logged line and `done` are the service's
//! - psProcessStart asks ps in a fixed locale and time zone and trims it: `ps_is_asked_for_the_start_time_with_a_fixed_locale_and_zone_and_nothing_else_in_the_environment`
//! - psProcessStart is null when ps finds no such process, prints nothing, or cannot run: `ps_says_nothing_for_a_failure_an_empty_answer_a_timeout_and_no_ps`
//! - psProcessStart on real processes: `ps_on_real_processes_is_stable_and_a_gone_pid_has_none`
//! - taking the lock sweeps the temp files a crash left: `taking_the_lock_sweeps_the_temp_files_of_a_dead_pid_or_older_than_a_minute_and_nothing_else`
//! - two takeovers racing over one stale lock end with exactly one holder: `two_takeovers_racing_over_one_stale_lock_end_with_exactly_one_holder`
//! - a takeover that judged the lock stale does not remove the lock somebody else put there since: `a_takeover_that_judged_the_lock_stale_does_not_remove_a_lock_put_there_since`
//! - the lock is linked into place from a finished file: `the_lock_is_never_visible_empty_and_no_temp_file_is_left`
//! - readLock reads both formats: `read_lock_reads_both_formats`

use std::fs::{self, File};
use std::os::unix::fs::PermissionsExt;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Barrier};
use std::time::{Duration, SystemTime};

use super::*;
use crate::testing::Scratch;
use crate::testing::gate::{forking, write_executable};

/// Pid 1 always exists, and `kill(1, 0)` is refused for it unless we are root: a live process that is not us.
const INIT: u64 = 1;

/// What the lock tests ask of a scratch directory besides its path.
trait LockDir {
    fn file(&self) -> String;
    fn names(&self) -> Vec<String>;
    fn make(&self, name: &str, age_ms: u64) -> String;
}

impl LockDir for Scratch {
    fn file(&self) -> String {
        self.0.join(LOCK_FILE).to_string_lossy().into_owned()
    }

    fn names(&self) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(&self.0)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        names
    }

    fn make(&self, name: &str, age_ms: u64) -> String {
        let path = self.0.join(name);
        fs::write(&path, "x").unwrap();
        if age_ms > 0 {
            set_age(&path, age_ms);
        }
        name.to_owned()
    }
}

fn set_age(path: &std::path::Path, age_ms: u64) {
    let then = SystemTime::now() - Duration::from_millis(age_ms);
    File::options()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(then)
        .unwrap();
}

fn parent() -> u64 {
    u64::from(std::os::unix::process::parent_id())
}

fn me() -> u64 {
    u64::from(std::process::id())
}

/// What a fake process's start time reads: one per pid, so a reused pid is a pid whose start time is another.
fn start_of(pid: u64) -> Option<String> {
    Some(format!("T{pid}"))
}

fn lock_of(pid: u64) -> String {
    format!("{pid} T{pid}\n")
}

fn holder(pid: u64, process_start: &dyn Fn(u64) -> Option<String>) -> LockDeps<'_> {
    LockDeps {
        me: LockHolder {
            pid,
            started: Some(format!("T{pid}")),
        },
        boot_ms: 0,
        process_start,
    }
}

fn stale_lock(dir: &Scratch) -> String {
    let file = dir.file();
    // Our parent is alive, but this lock recorded another start time for its pid: the pid was reused.
    fs::write(&file, format!("{} before the reboot\n", parent())).unwrap();
    file
}

/// A pid that has been reaped: a short-lived child, killed and waited for.
fn gone_pid() -> u64 {
    let _forking = forking();
    let mut child = Command::new("sleep")
        .arg("60")
        .stdout(Stdio::null())
        .spawn()
        .unwrap();
    let pid = u64::from(child.id());
    child.kill().unwrap();
    child.wait().unwrap();
    pid
}

fn read(file: &str) -> String {
    fs::read_to_string(file).unwrap()
}

#[test]
fn a_lock_held_by_a_live_process_is_reported_and_not_touched() {
    let dir = Scratch::new();
    let file = dir.file();
    fs::write(&file, lock_of(parent())).unwrap();
    let result = take_lock(&file, &holder(me(), &start_of)).unwrap();
    assert_eq!(result, LockResult::Held { holder: parent() });
    assert_eq!(read(&file), lock_of(parent()));
}

#[test]
fn a_bare_pid_lock_is_read_and_a_live_pid_holds_it() {
    let dir = Scratch::new();
    let file = dir.file();
    fs::write(&file, format!("{}\n", parent())).unwrap();
    let result = take_lock(&file, &holder(me(), &start_of)).unwrap();
    assert_eq!(result, LockResult::Held { holder: parent() });
    assert_eq!(
        read(&file),
        format!("{}\n", parent()),
        "the lock is not touched"
    );
}

#[test]
fn a_live_pid_with_another_start_time_is_a_reused_pid_and_the_lock_is_taken_over() {
    let dir = Scratch::new();
    let file = stale_lock(&dir);
    assert_eq!(
        take_lock(&file, &holder(me(), &start_of)).unwrap(),
        LockResult::Taken
    );
    assert_eq!(read(&file), lock_of(me()));
}

#[test]
fn when_ps_cannot_name_the_holder_the_age_of_the_lock_decides() {
    let blind = |pid: u64| if pid == parent() { None } else { start_of(pid) };
    let fresh = Scratch::new();
    fs::write(fresh.file(), format!("{} whatever\n", parent())).unwrap();
    assert_eq!(
        take_lock(&fresh.file(), &holder(me(), &blind)).unwrap(),
        LockResult::Held { holder: parent() }
    );

    let old = Scratch::new();
    let file = old.file();
    fs::write(&file, format!("{} whatever\n", parent())).unwrap();
    set_age(std::path::Path::new(&file), 3_600_000);
    let mut deps = holder(me(), &blind);
    deps.boot_ms = date_now() - 1000;
    assert_eq!(take_lock(&file, &deps).unwrap(), LockResult::Taken);
    assert_eq!(read(&file), lock_of(me()));
}

fn date_now() -> i64 {
    SystemClock.now_ms() as i64
}

#[test]
fn a_free_lock_is_taken_naming_pid_and_start_without_asking_ps() {
    let dir = Scratch::new();
    let file = dir.file();
    let asked = AtomicUsize::new(0);
    let counting = |pid: u64| {
        asked.fetch_add(1, Ordering::Relaxed);
        start_of(pid)
    };
    assert_eq!(
        take_lock(&file, &holder(me(), &counting)).unwrap(),
        LockResult::Taken
    );
    assert_eq!(read(&file), lock_of(me()));
    assert_eq!(asked.load(Ordering::Relaxed), 0);
    assert_eq!(dir.names(), [LOCK_FILE]);
}

#[test]
fn a_lock_with_a_dead_pid_is_taken_over() {
    let dir = Scratch::new();
    let file = dir.file();
    fs::write(&file, lock_of(gone_pid())).unwrap();
    assert_eq!(
        take_lock(&file, &holder(me(), &start_of)).unwrap(),
        LockResult::Taken
    );
    assert_eq!(read(&file), lock_of(me()));
}

#[test]
fn a_bare_pid_lock_from_before_the_boot_is_stale_although_its_pid_is_alive() {
    let dir = Scratch::new();
    let file = dir.file();
    fs::write(&file, format!("{}\n", parent())).unwrap();
    set_age(std::path::Path::new(&file), 3_600_000);
    let mut deps = holder(me(), &start_of);
    deps.boot_ms = date_now() - 1000;
    assert_eq!(take_lock(&file, &deps).unwrap(), LockResult::Taken);
    assert_eq!(read(&file), lock_of(me()));
}

#[test]
fn an_unparseable_lock_is_taken_over() {
    let dir = Scratch::new();
    let file = dir.file();
    fs::write(&file, "not a pid\n").unwrap();
    assert_eq!(
        take_lock(&file, &holder(me(), &start_of)).unwrap(),
        LockResult::Taken
    );
    assert_eq!(read(&file), lock_of(me()));
}

#[test]
fn our_lock_is_removed_on_release_and_releasing_twice_is_one_release() {
    let dir = Scratch::new();
    let file = dir.file();
    take_lock(&file, &holder(me(), &start_of)).unwrap();
    assert_eq!(read(&file), lock_of(me()));
    release_lock(&file).unwrap();
    assert!(!std::path::Path::new(&file).exists());
    release_lock(&file).unwrap();
}

#[test]
fn a_lock_someone_else_took_over_survives_our_release() {
    let dir = Scratch::new();
    let file = dir.file();
    take_lock(&file, &holder(me(), &start_of)).unwrap();
    fs::write(&file, format!("{}\n", parent())).unwrap();
    release_lock(&file).unwrap();
    assert_eq!(read(&file), format!("{}\n", parent()));
}

#[test]
fn a_lock_that_cannot_be_removed_gives_the_failure_text_and_stays() {
    if rustix::process::geteuid().is_root() {
        eprintln!("skipped: root removes a file from a directory it cannot write");
        return;
    }
    let dir = Scratch::new();
    let file = dir.file();
    take_lock(&file, &holder(me(), &start_of)).unwrap();
    fs::set_permissions(&dir.0, fs::Permissions::from_mode(0o555)).unwrap();
    let failed = release_lock(&file);
    fs::set_permissions(&dir.0, fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(
        failed,
        Err(format!("EACCES: permission denied, unlink '{file}'"))
    );
    assert_eq!(read(&file), lock_of(me()));
}

/// A stand-in for `ps`: records its arguments and its environment, then prints what the test says.
fn stub(dir: &Scratch, script: &str) -> Command {
    let path = dir.0.join("ps-stub");
    write_executable(&path, &format!("#!/bin/sh\n{script}\n"));
    Command::new(path)
}

/// `start_via` with the spawn under the fork gate; the command is made before the call, so a stub is written outside the gate.
fn gated(command: Command, pid: u64) -> Option<String> {
    let _forking = forking();
    start_via(command, pid)
}

/// `ps_process_start` under the fork gate.
fn ps_started(pid: u64) -> Option<String> {
    let _forking = forking();
    ps_process_start(pid)
}

#[test]
fn ps_is_asked_for_the_start_time_with_a_fixed_locale_and_zone_and_nothing_else_in_the_environment()
{
    let dir = Scratch::new();
    let record = dir.0.join("record");
    let script = format!(
        "echo \"$@\" > '{0}'; /usr/bin/env | LC_ALL=C sort >> '{0}'; echo 'Sat Oct 17 10:23:45 2026'",
        record.display()
    );
    let got = gated(stub(&dir, &script), 123);
    assert_eq!(got.as_deref(), Some("Sat Oct 17 10:23:45 2026"));
    let text = fs::read_to_string(&record).unwrap();
    let mut lines = text.lines();
    assert_eq!(lines.next(), Some("-o lstart= -p 123"));
    let env: Vec<&str> = lines
        .filter(|l| {
            !["PWD=", "SHLVL=", "_=", "OLDPWD="]
                .iter()
                .any(|p| l.starts_with(p))
        })
        .collect();
    assert_eq!(env, ["LC_ALL=C", "TZ=UTC"]);
}

#[test]
fn ps_says_nothing_for_a_failure_an_empty_answer_a_timeout_and_no_ps() {
    let dir = Scratch::new();
    assert_eq!(gated(stub(&dir, "exit 1"), 1), None, "no such pid");
    assert_eq!(gated(stub(&dir, "echo '  '"), 1), None, "empty output");
    assert_eq!(
        gated(stub(&dir, "echo 'Sat Oct 17 10:23:45 2026'; exit 3"), 1),
        None,
        "failing exit"
    );
    assert_eq!(
        gated(Command::new(dir.0.join("no-such-ps")), 1),
        None,
        "no ps"
    );
    let slow = std::time::Instant::now();
    assert_eq!(
        gated(stub(&dir, "echo 'Sat Oct 17 10:23:45 2026'; sleep 30"), 1),
        None,
        "killed at the deadline"
    );
    assert!(slow.elapsed() < Duration::from_secs(10));
}

#[test]
fn ps_on_real_processes_is_stable_and_a_gone_pid_has_none() {
    let mine = ps_started(me());
    assert!(mine.as_deref().is_some_and(|t| !t.is_empty()), "{mine:?}");
    assert_eq!(ps_started(me()), mine);
    assert_eq!(ps_started(gone_pid()), None);
}

#[test]
fn taking_the_lock_sweeps_the_temp_files_of_a_dead_pid_or_older_than_a_minute_and_nothing_else() {
    let dir = Scratch::new();
    let gone = gone_pid();
    dir.make(&format!("{LOCK_FILE}.{gone}.0a1b2c3d.tmp"), 0);
    dir.make(&format!("{LOCK_FILE}.{}.0a1b2c3e.tmp", me()), 120_000);
    let fresh = dir.make(&format!("{LOCK_FILE}.{}.0a1b2c3f.tmp", me()), 0);
    let events = dir.make("events.tsv", 0);
    let lookalike = dir.make(&format!("{LOCK_FILE}.{gone}.tmp"), 0);
    let short = dir.make(&format!("{LOCK_FILE}.tmp"), 0);
    let upper = dir.make(&format!("{LOCK_FILE}.{gone}.0A1B2C4D.tmp"), 0);
    assert_eq!(
        take_lock(&dir.file(), &holder(me(), &start_of)).unwrap(),
        LockResult::Taken
    );
    let mut expected = vec![LOCK_FILE.to_owned(), fresh, events, lookalike, short, upper];
    expected.sort();
    assert_eq!(dir.names(), expected);
}

#[test]
fn two_takeovers_racing_over_one_stale_lock_end_with_exactly_one_holder() {
    let dir = Scratch::new();
    let file = stale_lock(&dir);
    // Both read the stale lock and both wait on ps, as node's two takeovers do; then the first goes on to take the lock, and the second, held back until it is done, must find the new lock.
    let both_judged = Arc::new(Barrier::new(2));
    let first_done = Arc::new(AtomicBool::new(false));
    let racer = |pid: u64, wait_for_first: bool| {
        let (file, both_judged, first_done) =
            (file.clone(), both_judged.clone(), first_done.clone());
        std::thread::spawn(move || {
            let judge = |asked: u64| {
                if asked == parent() {
                    both_judged.wait();
                    while wait_for_first && !first_done.load(Ordering::SeqCst) {
                        std::thread::sleep(Duration::from_millis(5));
                    }
                }
                start_of(asked)
            };
            let result = take_lock(&file, &holder(pid, &judge)).unwrap();
            if !wait_for_first {
                first_done.store(true, Ordering::SeqCst);
            }
            result
        })
    };
    let (a, b) = (racer(INIT, false), racer(me(), true));
    let (ra, rb) = (a.join().unwrap(), b.join().unwrap());
    assert_eq!(ra, LockResult::Taken);
    assert_eq!(rb, LockResult::Held { holder: INIT });
    assert_eq!(read(&file), lock_of(INIT), "the file names the winner");
    assert_eq!(dir.names(), [LOCK_FILE], "no temp file is left behind");
}

#[test]
fn a_takeover_that_judged_the_lock_stale_does_not_remove_a_lock_put_there_since() {
    let dir = Scratch::new();
    let file = stale_lock(&dir);
    let (entered_tx, entered_rx) = mpsc::channel::<()>();
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let late = {
        let file = file.clone();
        std::thread::spawn(move || {
            let slow = |asked: u64| {
                if asked == parent() {
                    entered_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                }
                start_of(asked)
            };
            take_lock(&file, &holder(me(), &slow)).unwrap()
        })
    };
    // While the late one is still asking ps about the old holder, another takeover completes.
    entered_rx.recv().unwrap();
    assert_eq!(
        take_lock(&file, &holder(INIT, &start_of)).unwrap(),
        LockResult::Taken
    );
    release_tx.send(()).unwrap();
    assert_eq!(late.join().unwrap(), LockResult::Held { holder: INIT });
    assert_eq!(read(&file), lock_of(INIT), "the new holder keeps its lock");
}

#[test]
fn the_lock_is_never_visible_empty_and_no_temp_file_is_left() {
    let dir = Scratch::new();
    let file = dir.file();
    let stop = Arc::new(AtomicBool::new(false));
    let watcher = {
        let (file, stop) = (file.clone(), stop.clone());
        std::thread::spawn(move || {
            let (mut seen, mut partial) = (0, 0);
            while !stop.load(Ordering::SeqCst) {
                if let Ok(text) = fs::read_to_string(&file) {
                    seen += 1;
                    if text != lock_of(me()) {
                        partial += 1;
                    }
                }
            }
            (seen, partial)
        })
    };
    for _ in 0..3000 {
        assert_eq!(
            take_lock(&file, &holder(me(), &start_of)).unwrap(),
            LockResult::Taken
        );
        fs::remove_file(&file).unwrap();
    }
    stop.store(true, Ordering::SeqCst);
    let (seen, partial) = watcher.join().unwrap();
    assert_eq!(partial, 0, "{partial} partial reads of {seen}");
    assert_eq!(dir.names(), Vec::<String>::new());
}

#[test]
fn read_lock_reads_both_formats() {
    let dir = Scratch::new();
    let file = dir.file();
    assert_eq!(read_lock(&file), None, "no file");
    let pair = |text: &str| {
        fs::write(&file, text).unwrap();
        let got = read_lock(&file).unwrap();
        (got.pid, got.started)
    };
    assert_eq!(pair("4242\n"), (Some(4242), None));
    assert_eq!(
        pair("4242 Sat Oct  3 10:23:45 2026\n"),
        (Some(4242), Some("Sat Oct  3 10:23:45 2026".to_owned()))
    );
    assert_eq!(pair("4242\tT 1 \n"), (Some(4242), Some("T 1".to_owned())));
    assert_eq!(
        pair("\u{feff} 7 x \n"),
        (Some(7), Some("x".to_owned())),
        "a JavaScript trim removes U+FEFF"
    );
    // node's `readLock` on each text, run once: a U+FEFF at both ends of the text and of the start time is trimmed away, and one right after the space is not a start time.
    assert_eq!(
        pair("\u{feff}7 Sat Oct  3 10:23:45 2026\u{feff}\n"),
        (Some(7), Some("Sat Oct  3 10:23:45 2026".to_owned()))
    );
    assert_eq!(pair("\u{feff}7\u{feff}\n"), (Some(7), None));
    assert_eq!(pair("7 x\u{feff}\n"), (Some(7), Some("x".to_owned())));
    assert_eq!(pair("7 \u{feff}x\u{feff}\n"), (None, None));
    for junk in [
        "",
        "not a pid\n",
        "42abc\n",
        "0\n",
        "-5\n",
        "9007199254740992\n",
        "12 \u{a0}x\n",
        "12 a\nb\n",
        "99999999999999999999\n",
    ] {
        assert_eq!(pair(junk).0, None, "{junk:?}");
    }
    assert_eq!(pair("9007199254740991\n").0, Some(9_007_199_254_740_991));
}

#[test]
fn the_boot_time_comes_from_the_uptime_or_from_kern_boottime() {
    assert_eq!(
        boot_from_uptime("350735.47 234388.90\n", 1_000_000_000),
        Some(1_000_000_000 - 350_735_470)
    );
    assert_eq!(boot_from_uptime("", 5), None);
    assert_eq!(boot_from_uptime("x 1", 5), None);
    assert_eq!(
        boot_from_boottime("{ sec = 1791766984, usec = 222183 } Mon Oct 12 03:03:04 2026\n"),
        Some(1_791_766_984_222)
    );
    assert_eq!(boot_from_boottime("garbage"), None);
    let _forking = forking();
    assert!(boot_ms(date_now()) <= date_now());
}

/// Node: `('﻿Sat Oct 17 10:23:45 2026﻿\n').trim()` is the date and `('﻿\n').trim() === ''`.
#[test]
fn a_u_feff_at_both_ends_of_the_ps_answer_is_trimmed_and_one_alone_is_an_empty_answer() {
    let dir = Scratch::new();
    let bom = '\u{feff}';
    let wrapped = format!("echo '{bom}Sat Oct 17 10:23:45 2026{bom}'");
    assert_eq!(
        gated(stub(&dir, &wrapped), 1).as_deref(),
        Some("Sat Oct 17 10:23:45 2026")
    );
    assert_eq!(gated(stub(&dir, &format!("echo '{bom}'")), 1), None);
}
