//! The shared knowledge server as a process that outlives its sessions: the races of starting it, the socket it leaves behind, how it decides to leave, and what one bad connection costs. The ports of the daemon scenarios of `packages/knowledge/test/shared-server.test.ts` and `socket.test.ts`.
//!
//! Most tests run a daemon on a thread of this process, on a socket in a short directory under `/tmp` (an address holds about 100 bytes). The ones that need a process of their own (a signal, a group, the descriptors) start this very test binary at the entries `child_daemon_entry` and `child_starter_entry`, which do nothing unless the parent set their variables.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::{
    fs,
    io::{ErrorKind, Write},
    net::Shutdown,
    os::unix::{fs::PermissionsExt, net::UnixListener, process::CommandExt},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        Arc, Barrier, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    thread,
    time::{Duration, Instant, SystemTime},
};

use rustix::process::{Pid, Signal, getpgid, getpgrp, kill_process, kill_process_group};
use serde_json::{Map, Value, json};
use tagents_core::{
    ending::Stop,
    knowledge::{
        daemon::{Options, Outcome, run_until_signalled},
        paths::Env,
        socket::{Detached, Ended, Launch, Starter, ensure, lock_dir_of, pid_file_of},
        tools::KnowledgeTools,
    },
    mcp::{rpc::CallResult, server::Tools},
    node,
};

use common::{
    forking,
    rig::{alive, until},
    shared::{Client, Daemon, InProcess, ensured_socket, env_in, options, serves},
    short_scratch, start, write_executable, writing,
};

// ---- what the tests are made of ---------------------------------------------------------------

/// What the daemon reports of a fault, instead of writing it on the stderr of the test run.
type Reports = Arc<Mutex<Vec<String>>>;

fn reporting(options: Options) -> (Options, Reports) {
    let reports = Reports::default();
    let sink = Arc::clone(&reports);
    let options = Options {
        report: Arc::new(move |line| sink.lock().unwrap().push(line.to_owned())),
        ..options
    };
    (options, reports)
}

// ---- one daemon, on its socket -----------------------------------------------------------------

/// A socket file nobody listens on. The gate holds off the forks of the other tests: a child forked while the listener is open keeps it open until it execs, so a connection to the file succeeds after the drop here, and the file reads as live.
fn dead_socket(socket: &Path) {
    let _gate = writing();
    drop(UnixListener::bind(socket).unwrap());
}

#[test]
fn a_client_is_served_and_the_daemon_leaves_nothing_behind() {
    let dir = short_scratch("daemon-serve");
    let mut daemon = Daemon::start(options(&dir, Duration::from_secs(60)));
    assert_eq!(
        format!("{}\n", std::process::id()),
        fs::read_to_string(daemon.pid_file()).unwrap()
    );
    // The directory the socket is in is the daemon's to make private.
    assert_eq!(0, fs::metadata(&*dir).unwrap().permissions().mode() & 0o077);

    let mut client = Client::connect(&daemon.socket);
    let hello = client.handshake();
    assert_eq!("tagents-knowledge", hello["result"]["serverInfo"]["name"]);
    let listed = client.ask(2, "tools/list", &json!({}));
    assert_eq!(6, listed["result"]["tools"].as_array().unwrap().len());
    drop(client);

    assert_eq!(Ok(Outcome::Served), daemon.finish());
    assert!(!daemon.socket.exists(), "the socket file is removed");
    assert!(!daemon.pid_file().exists(), "the pid file is removed");
}

#[test]
fn a_bind_where_something_answers_leaves_that_server_alone() {
    let dir = short_scratch("daemon-taken");
    let mut first = Daemon::start(options(&dir, Duration::from_secs(60)));
    let mut second = Daemon::start(options(&dir, Duration::from_secs(60)));
    assert_eq!(Ok(Outcome::Taken), second.outcome());
    // The loser neither removed the socket nor the pid file of the winner.
    serves(&first.socket);
    assert!(first.pid_file().exists());
    assert_eq!(Ok(Outcome::Served), first.finish());
}

#[test]
fn a_socket_file_nobody_answers_on_is_replaced() {
    let dir = short_scratch("daemon-dead");
    let socket = dir.join("s.sock");
    dead_socket(&socket);
    assert!(socket.exists(), "a dropped listener leaves its file");
    let mut daemon = Daemon::start(options(&dir, Duration::from_secs(60)));
    serves(&socket);
    assert_eq!(Ok(Outcome::Served), daemon.finish());
}

#[test]
fn a_file_that_is_not_a_socket_is_left_alone_and_is_an_error() {
    let dir = short_scratch("daemon-file");
    let socket = dir.join("s.sock");
    fs::write(&socket, "mine").unwrap();
    let mut daemon = Daemon::start(options(&dir, Duration::from_secs(60)));
    assert_eq!(
        Err(format!("{} exists and is not a socket", socket.display())),
        daemon.outcome()
    );
    assert_eq!("mine", fs::read_to_string(&socket).unwrap());
}

#[test]
fn a_dead_socket_is_replaced_under_the_lock_which_is_waited_for() {
    let dir = short_scratch("daemon-lock");
    let socket = dir.join("s.sock");
    dead_socket(&socket);
    let lock = PathBuf::from(lock_dir_of(socket.to_str().unwrap()));
    fs::create_dir(&lock).unwrap();
    let mut daemon = Daemon::spawn(options(&dir, Duration::from_secs(60)));
    thread::sleep(Duration::from_millis(400));
    assert!(
        !daemon.pid_file().exists() && !daemon.left(),
        "the daemon took the socket while somebody held the lock"
    );
    fs::remove_dir(&lock).unwrap();
    assert!(until(|| daemon.pid_file().exists(), 5000));
    serves(&socket);
    assert!(!lock.exists(), "the daemon released the lock");
    assert_eq!(Ok(Outcome::Served), daemon.finish());
}

#[test]
fn a_lock_left_by_a_process_that_died_is_taken_over() {
    let dir = short_scratch("daemon-stale-lock");
    let socket = dir.join("s.sock");
    dead_socket(&socket);
    let lock = PathBuf::from(lock_dir_of(socket.to_str().unwrap()));
    fs::create_dir(&lock).unwrap();
    fs::File::open(&lock)
        .unwrap()
        .set_modified(SystemTime::now() - Duration::from_secs(4))
        .unwrap();
    // A lock that is not taken over ends `bind` with an error after its wait, and then nothing serves.
    let mut daemon = Daemon::start(options(&dir, Duration::from_secs(60)));
    serves(&socket);
    assert!(!lock.exists());
    assert_eq!(Ok(Outcome::Served), daemon.finish());
}

// ---- leaving -----------------------------------------------------------------------------------

#[test]
fn a_daemon_nobody_connects_to_leaves_after_the_idle_time_counted_from_its_start() {
    let dir = short_scratch("daemon-idle-start");
    let idle = Duration::from_millis(400);
    let began = Instant::now();
    let mut daemon = Daemon::start(options(&dir, idle));
    assert_eq!(Ok(Outcome::Served), daemon.outcome());
    assert!(began.elapsed() >= idle, "{:?}", began.elapsed());
    assert!(!daemon.socket.exists());
    assert!(!daemon.pid_file().exists());
}

#[test]
fn a_client_held_open_keeps_the_daemon_and_the_idle_time_counts_from_its_disconnect() {
    let dir = short_scratch("daemon-idle-held");
    let idle = Duration::from_millis(400);
    let mut daemon = Daemon::start(options(&dir, idle));
    let mut client = Client::connect(&daemon.socket);
    client.handshake();
    // More than twice the idle time with a client connected.
    thread::sleep(idle * 2 + Duration::from_millis(200));
    assert!(!daemon.left(), "the daemon left under a connected client");
    let disconnected = Instant::now();
    drop(client);
    assert_eq!(Ok(Outcome::Served), daemon.outcome());
    assert!(
        disconnected.elapsed() >= idle,
        "{:?}",
        disconnected.elapsed()
    );
}

#[test]
fn a_client_that_closes_only_its_writing_side_is_released_at_once() {
    let dir = short_scratch("daemon-half-closed");
    // An idle time far above the bound: the half close ends the connection, and no clock of the daemon does.
    let bound = Duration::from_secs(30);
    let mut daemon = Daemon::start(options(&dir, Duration::from_secs(120)));
    let mut client = Client::connect(&daemon.socket);
    client.handshake();
    client.writer.set_read_timeout(Some(bound)).unwrap();
    client.writer.shutdown(Shutdown::Write).unwrap();
    let began = Instant::now();
    // What is in flight may still be answered; the connection ends, and quickly.
    while client.read().is_some() {}
    assert!(began.elapsed() < bound, "{:?}", began.elapsed());
    assert_eq!(Ok(Outcome::Served), daemon.finish());
}

#[test]
fn a_client_that_closes_only_its_writing_side_is_counted_out() {
    let dir = short_scratch("daemon-half-counted");
    let mut daemon = Daemon::start(options(&dir, Duration::from_secs(2)));
    let mut client = Client::connect(&daemon.socket);
    client.handshake();
    client.writer.shutdown(Shutdown::Write).unwrap();
    while client.read().is_some() {}
    // With nobody left the daemon leaves although the client still holds its end.
    assert_eq!(Ok(Outcome::Served), daemon.outcome());
    drop(client);
}

// ---- one bad connection ------------------------------------------------------------------------

#[test]
fn a_client_quiet_for_longer_than_the_tick_stays_connected_and_is_answered() {
    let dir = short_scratch("daemon-quiet");
    let daemon = Daemon::start(options(&dir, Duration::from_secs(60)));
    let mut client = Client::connect(&daemon.socket);
    client.handshake();
    thread::sleep(Duration::from_millis(1300));
    let listed = client.ask(2, "tools/list", &json!({}));
    assert_eq!(6, listed["result"]["tools"].as_array().unwrap().len());
}

#[test]
fn rubbish_and_a_cut_off_line_cost_only_their_connection() {
    let dir = short_scratch("daemon-rubbish");
    let (options, reports) = reporting(options(&dir, Duration::from_millis(600)));
    let mut daemon = Daemon::start(options);

    let mut garbled = Client::connect(&daemon.socket);
    garbled.send("this is not json");
    garbled.send("{\"jsonrpc\":");
    assert_eq!(
        "tagents-knowledge",
        garbled.handshake()["result"]["serverInfo"]["name"]
    );

    let mut cut = Client::connect(&daemon.socket);
    cut.writer
        .write_all(br#"{"jsonrpc":"2.0","id":1,"meth"#)
        .unwrap();
    drop(cut);

    serves(&daemon.socket);
    drop(garbled);
    assert!(
        reports.lock().unwrap().is_empty(),
        "{:?}",
        reports.lock().unwrap()
    );
    assert_eq!(Ok(Outcome::Served), daemon.outcome());
}

/// The first request of a session, which is where `Panicking` panics.
const INITIALIZE: &str = r#"{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "0.0.0"}}}"#;

/// Tools whose handshake panics, which is a failure of the thread of the connection while it serves.
struct Panicking;

impl Tools for Panicking {
    fn list(&self) -> Vec<Value> {
        Vec::new()
    }

    fn connected(&self, _client: &str) {
        panic!("boom while serving");
    }

    fn call(&self, _: &str, _: Option<&Map<String, Value>>, _: &Stop) -> Option<CallResult> {
        None
    }
}

/// The first connection meets a failure, the later ones meet the real tools.
fn failing_once(
    options: Options,
    fail: impl Fn() -> Arc<dyn Tools> + Send + Sync + 'static,
) -> Options {
    let calls = AtomicUsize::new(0);
    Options {
        tools: Arc::new(move |env: &Env| {
            if calls.fetch_add(1, Ordering::SeqCst) == 0 {
                fail()
            } else {
                Arc::new(KnowledgeTools::new(env.clone(), node::now_ms))
            }
        }),
        ..options
    }
}

#[test]
fn a_panic_while_a_connection_is_set_up_is_reported_and_survived() {
    let dir = short_scratch("daemon-panic-setup");
    let (options, reports) = reporting(failing_once(
        options(&dir, Duration::from_millis(600)),
        || panic!("boom while setting up"),
    ));
    let mut daemon = Daemon::start(options);

    let mut victim = Client::connect(&daemon.socket);
    assert!(
        victim.read().is_none(),
        "the connection that failed is closed"
    );
    serves(&daemon.socket);

    let reported = reports.lock().unwrap().clone();
    assert_eq!(1, reported.len(), "{reported:?}");
    // The line of the daemon's faults, then the panic's message and where it was.
    assert!(
        reported[0].starts_with(
            "tagents-knowledge: a connection could not be set up: boom while setting up"
        ),
        "{}",
        reported[0]
    );
    assert!(
        reported[0].contains("knowledge_daemon.rs:"),
        "{}",
        reported[0]
    );
    drop(victim);
    // The failed connection was counted out, or the daemon would never leave.
    assert_eq!(Ok(Outcome::Served), daemon.outcome());
}

#[test]
fn a_panic_while_a_connection_is_served_is_reported_and_survived() {
    let dir = short_scratch("daemon-panic-serve");
    let (options, reports) = reporting(failing_once(
        options(&dir, Duration::from_millis(600)),
        || Arc::new(Panicking),
    ));
    let mut daemon = Daemon::start(options);

    let mut victim = Client::connect(&daemon.socket);
    victim.send(INITIALIZE);
    assert!(
        victim.read().is_none(),
        "the connection that failed is closed"
    );
    serves(&daemon.socket);

    let reported = reports.lock().unwrap().clone();
    assert_eq!(1, reported.len(), "{reported:?}");
    assert!(
        reported[0]
            .starts_with("tagents-knowledge: a connection could not be served: boom while serving"),
        "{}",
        reported[0]
    );
    assert!(
        reported[0].contains("knowledge_daemon.rs:"),
        "{}",
        reported[0]
    );
    drop(victim);
    assert_eq!(Ok(Outcome::Served), daemon.outcome());
}

#[test]
fn a_panic_outside_the_caught_steps_still_closes_the_connection_and_counts_it_out() {
    let dir = short_scratch("daemon-panic-report");
    let options = Options {
        report: Arc::new(|_| panic!("boom while reporting")),
        ..failing_once(options(&dir, Duration::from_millis(600)), || {
            Arc::new(Panicking)
        })
    };
    let mut daemon = Daemon::start(options);

    let mut victim = Client::connect(&daemon.socket);
    victim.send(INITIALIZE);
    assert!(
        victim.read().is_none(),
        "the connection that failed is closed"
    );
    // The panic of `report` is outside what `caught` wraps: the connection was counted out all the same, or the daemon would never leave.
    assert_eq!(Ok(Outcome::Served), daemon.outcome());
}

// ---- ensure: finding the daemon or starting one ---------------------------------------------------

#[test]
fn two_starters_end_with_one_daemon() {
    let dir = short_scratch("ensure-race");
    let starter = Arc::new(InProcess::default());
    let barrier = Arc::new(Barrier::new(4));
    let sockets: Vec<PathBuf> = (0..4)
        .map(|_| {
            let (starter, barrier, env) =
                (Arc::clone(&starter), Arc::clone(&barrier), env_in(&dir));
            thread::spawn(move || {
                barrier.wait();
                ensure(&env, 60.0, &*starter).unwrap()
            })
        })
        .collect::<Vec<_>>()
        .into_iter()
        .map(|handle| handle.join().unwrap())
        .collect();
    assert_eq!(
        1,
        starter.starts.load(Ordering::SeqCst),
        "one daemon was started"
    );
    assert!(
        sockets.iter().all(|socket| *socket == sockets[0]),
        "{sockets:?}"
    );
    assert_eq!(ensured_socket(&dir), sockets[0]);
    serves(&sockets[0]);
    assert!(
        !PathBuf::from(lock_dir_of(sockets[0].to_str().unwrap())).exists(),
        "the lock is released"
    );
    starter.stop_all();
}

#[test]
fn a_daemon_that_answers_is_found_and_not_started_again() {
    let dir = short_scratch("ensure-found");
    let starter = InProcess::default();
    let first = ensure(&env_in(&dir), 60.0, &starter).unwrap();
    let second = ensure(&env_in(&dir), 60.0, &starter).unwrap();
    assert_eq!(first, second);
    assert_eq!(1, starter.starts.load(Ordering::SeqCst));
    starter.stop_all();
}

#[test]
fn a_dead_socket_is_replaced_by_the_starter_under_the_lock() {
    let dir = short_scratch("ensure-dead");
    let socket = ensured_socket(&dir);
    fs::create_dir_all(socket.parent().unwrap()).unwrap();
    dead_socket(&socket);
    let starter = InProcess::default();
    assert_eq!(socket, ensure(&env_in(&dir), 60.0, &starter).unwrap());
    assert_eq!(1, starter.starts.load(Ordering::SeqCst));
    serves(&socket);
    starter.stop_all();
}

#[test]
fn a_starter_that_finds_the_lock_held_takes_the_daemon_the_holder_started() {
    let dir = short_scratch("ensure-lock");
    let socket = ensured_socket(&dir);
    fs::create_dir_all(socket.parent().unwrap()).unwrap();
    let lock = PathBuf::from(lock_dir_of(socket.to_str().unwrap()));
    fs::create_dir(&lock).unwrap();

    let starter = Arc::new(InProcess::default());
    let waiting = thread::spawn({
        let (starter, env) = (Arc::clone(&starter), env_in(&dir));
        move || ensure(&env, 60.0, &*starter)
    });
    thread::sleep(Duration::from_millis(300));
    assert!(
        !waiting.is_finished(),
        "the starter went on past a held lock"
    );
    // The holder's daemon comes up: the waiting starter answers with it and never starts one of its own.
    let mut winner = Daemon::start(Options::new(
        socket.clone(),
        Duration::from_secs(60),
        env_in(&dir),
    ));
    assert_eq!(socket, waiting.join().unwrap().unwrap());
    assert_eq!(0, starter.starts.load(Ordering::SeqCst));
    fs::remove_dir(&lock).unwrap();
    assert_eq!(Ok(Outcome::Served), winner.finish());
}

#[test]
fn a_daemon_that_exits_before_it_listens_is_an_error_at_once() {
    struct Gone;
    impl Starter for Gone {
        fn stamp(&self) -> Result<String, String> {
            Ok("test".to_owned())
        }
        fn start(&self, _: &Launch<'_>) -> std::io::Result<Ended> {
            Ok(Box::new(|| true))
        }
    }
    let dir = short_scratch("ensure-gone");
    // A starter that waits the whole time for a daemon ends in another message, so this one says that it did not wait.
    assert_eq!(
        Err("the knowledge server exited before it was listening".to_owned()),
        ensure(&env_in(&dir), 60.0, &Gone)
    );
    let socket = ensured_socket(&dir);
    assert!(
        !PathBuf::from(lock_dir_of(socket.to_str().unwrap())).exists(),
        "the lock is released after a failure"
    );
}

#[test]
fn a_file_that_is_not_a_socket_is_not_removed_by_a_starter() {
    let dir = short_scratch("ensure-file");
    let socket = ensured_socket(&dir);
    fs::create_dir_all(socket.parent().unwrap()).unwrap();
    fs::write(&socket, "mine").unwrap();
    let starter = InProcess::default();
    assert_eq!(
        Err(format!("{} exists and is not a socket", socket.display())),
        ensure(&env_in(&dir), 60.0, &starter)
    );
    assert_eq!(0, starter.starts.load(Ordering::SeqCst));
    assert_eq!("mine", fs::read_to_string(&socket).unwrap());
}

// ---- the daemon as a process -------------------------------------------------------------------

const DAEMON_SOCKET: &str = "KNOWLEDGE_DAEMON_ENTRY_SOCKET";

/// The program the signal tests start: a daemon in a process of its own, ended by the signals of the process. It does nothing in an ordinary run.
#[test]
fn child_daemon_entry() {
    let Some(socket) = std::env::var_os(DAEMON_SOCKET) else {
        return;
    };
    let options = Options::new(socket.into(), Duration::from_secs(600), Env::from_process());
    std::process::exit(i32::from(run_until_signalled(options).is_err()));
}

fn this_binary_at(entry: &str) -> Command {
    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .args(["--exact", entry, "--test-threads=1", "--nocapture"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    command
}

fn pid_of(child: &Child) -> Pid {
    Pid::from_raw(i32::try_from(child.id()).unwrap()).unwrap()
}

/// A daemon as a process of this binary, in `dir`, and the pid it wrote.
fn start_child_daemon(dir: &Path) -> (Child, PathBuf, PathBuf) {
    let socket = dir.join("s.sock");
    let mut command = this_binary_at("child_daemon_entry");
    let child = start(
        command
            .env(DAEMON_SOCKET, &socket)
            .env("HOME", dir)
            .env("TAGENTS_CONFIG_DIR", dir.join("config")),
    );
    let pid_file = PathBuf::from(pid_file_of(socket.to_str().unwrap()));
    assert!(
        until(|| pid_file.exists(), 10_000),
        "the daemon process did not listen"
    );
    (child, socket, pid_file)
}

#[test]
fn a_signal_ends_the_daemon_and_it_takes_its_socket_and_pid_file_with_it() {
    for (name, signal) in [
        ("sigterm", Signal::TERM),
        ("sigint", Signal::INT),
        ("sighup", Signal::HUP),
    ] {
        let dir = short_scratch(&format!("daemon-{name}"));
        let (mut child, socket, pid_file) = start_child_daemon(&dir);
        assert_eq!(
            format!("{}\n", child.id()),
            fs::read_to_string(&pid_file).unwrap(),
            "{name}: the pid file names the daemon"
        );
        serves(&socket);
        let mut held = Client::connect(&socket);
        held.handshake();

        kill_process(pid_of(&child), signal).unwrap();
        let status =
            wait_for(&mut child, 10_000).unwrap_or_else(|| panic!("{name}: it did not leave"));
        assert!(status.success(), "{name}: {status:?}");
        assert!(!socket.exists(), "{name}: the socket is removed");
        assert!(!pid_file.exists(), "{name}: the pid file is removed");
        // A client that was connected sees the daemon go.
        assert!(held.read().is_none(), "{name}");
    }
}

fn wait_for(child: &mut Child, ms: u64) -> Option<std::process::ExitStatus> {
    let mut status = None;
    until(
        || {
            status = child.try_wait().unwrap();
            status.is_some()
        },
        ms,
    );
    status
}

// ---- detached ----------------------------------------------------------------------------------

/// What a stub daemon records about the process it was started as, and then it waits to be killed.
const STUB: &str = r#"#!/bin/sh
rec="$(dirname "$0")/record"
echo "$@" > "$rec/args"
here="$(pwd)"
echo "$here" > "$rec/cwd"
ps -o pgid= -p $$ | tr -d ' ' > "$rec/pgid"
stdio=""
for fd in stdin stdout stderr; do
  if [ "/dev/$fd" -ef /dev/null ]; then stdio="$stdio null"; else stdio="$stdio other"; fi
done
echo $stdio > "$rec/stdio"
echo "$TAGENTS_KNOWLEDGE_DIR" > "$rec/knowledge_dir"
echo $$ > "$rec/pid"
exec sleep 60
"#;

fn recorded(dir: &Path, name: &str) -> String {
    fs::read_to_string(dir.join(name))
        .unwrap()
        .trim()
        .to_owned()
}

/// A stub in `dir/stub`, and where it records.
fn stub_in(dir: &Path) -> (PathBuf, PathBuf) {
    let record = dir.join("record");
    fs::create_dir(&record).unwrap();
    let stub = dir.join("stub");
    write_executable(&stub, STUB);
    (stub, record)
}

/// Kill what the stub left, by the pid it recorded.
fn kill_recorded(record: &Path) {
    if let Ok(text) = fs::read_to_string(record.join("pid"))
        && let Some(pid) = text.trim().parse().ok().and_then(Pid::from_raw)
    {
        let _ = kill_process(pid, Signal::KILL);
    }
}

#[test]
fn detached_the_daemon_is_started_as_serve_in_a_group_of_its_own_in_the_root_with_no_stdio() {
    let dir = short_scratch("detached");
    let (stub, record) = stub_in(&dir);
    let socket = dir.join("s.sock");
    let env = Env {
        cwd: "/work/dir".into(),
        knowledge_dir: Some("rel/docs".into()),
        ..Env::default()
    };
    let _forking = forking();
    let mut ended = Detached::at(&stub)
        .start(&Launch {
            socket: &socket,
            idle: 30.0,
            env: &env,
        })
        .unwrap();
    drop(_forking);

    assert!(
        until(|| record.join("pid").exists(), 10_000),
        "the stub did not run"
    );
    let pid = recorded(&record, "pid");
    assert_eq!(
        format!(
            "knowledge serve --foreground --socket {} --idle 30",
            socket.display()
        ),
        recorded(&record, "args")
    );
    assert_eq!("/", recorded(&record, "cwd"));
    // A group of its own, which is the process's own number, and not the group of this test.
    assert_eq!(pid, recorded(&record, "pgid"));
    assert_ne!(
        getpgrp().as_raw_nonzero().get().to_string(),
        recorded(&record, "pgid")
    );
    assert_eq!("null null null", recorded(&record, "stdio"));
    // The paths of the session reach it absolute.
    assert_eq!("/work/dir/rel/docs", recorded(&record, "knowledge_dir"));
    assert!(!ended(), "the stub is running");
    kill_recorded(&record);
    assert!(until(ended, 5000), "the end of the process is seen");
}

const STARTER_STUB: &str = "KNOWLEDGE_STARTER_ENTRY_STUB";
const STARTER_DIR: &str = "KNOWLEDGE_STARTER_ENTRY_DIR";

/// The program the group test starts: a starter that starts a detached daemon and then stays alive. It does nothing in an ordinary run.
#[test]
fn child_starter_entry() {
    let (Some(stub), Some(dir)) = (
        std::env::var_os(STARTER_STUB),
        std::env::var_os(STARTER_DIR),
    ) else {
        return;
    };
    let socket = PathBuf::from(dir).join("s.sock");
    let _ = Detached::at(PathBuf::from(&stub))
        .start(&Launch {
            socket: &socket,
            idle: 30.0,
            env: &Env::default(),
        })
        .unwrap();
    thread::sleep(Duration::from_secs(120));
}

#[test]
fn detached_a_kill_of_the_starters_group_leaves_the_daemon_running() {
    let dir = short_scratch("detached-group");
    let (stub, record) = stub_in(&dir);
    let mut command = this_binary_at("child_starter_entry");
    // The starter is the leader of a group of its own, so that a kill of the group is one this test can make.
    command
        .env(STARTER_STUB, &stub)
        .env(STARTER_DIR, &*dir)
        .process_group(0);
    let mut starter = start(&mut command);
    assert!(
        until(|| record.join("pid").exists(), 10_000),
        "the stub did not run"
    );
    let daemon = recorded(&record, "pid");
    let daemon_group = getpgid(Pid::from_raw(daemon.parse().unwrap())).unwrap();
    assert_ne!(
        pid_of(&starter),
        daemon_group,
        "the daemon is in the starter's group"
    );

    kill_process_group(pid_of(&starter), Signal::KILL).unwrap();
    assert!(
        wait_for(&mut starter, 5000).is_some(),
        "the starter did not end"
    );
    thread::sleep(Duration::from_millis(300));
    assert!(
        alive(daemon.parse().unwrap()),
        "the daemon went with the group of its starter"
    );
    kill_recorded(&record);
}

#[test]
fn a_binary_that_cannot_be_run_is_a_failure_to_start() {
    let dir = short_scratch("detached-missing");
    let socket = dir.join("s.sock");
    let _forking = forking();
    let result = Detached::at(dir.join("nothing")).start(&Launch {
        socket: &socket,
        idle: 30.0,
        env: &Env::default(),
    });
    assert_eq!(ErrorKind::NotFound, result.err().map(|e| e.kind()).unwrap());
}
