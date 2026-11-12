//! The shared knowledge server: one process for every session of an environment, listening on a unix socket and serving each connection as `tagents-knowledge mcp` serves its stdio. It is `runDaemon` of `packages/knowledge/src/mcp/daemon.ts`.
//!
//! One accept loop polls the listener and a wake pipe, and a thread of its own serves each connection. Only the loop adds connections, and it is also the one that decides to leave: it drains the backlog and then reads the count. A connection that reached the socket before the drain is counted and served, however long it waited there; one that comes after the drain is closed with no reply when the listener closes. The caller that connected in that gap is `join`, which retries once.
//!
//! The daemon leaves after `idle` with nobody connected, counted from the last disconnect or from the start, and at the end of its `Stop`. It never leaves while a client is connected. It removes its socket and its pid file when it goes, a failure of the loop included.
//!
//! One bad connection costs only itself: a failure while a connection is being set up or served (a refused clone of the stream, a panic of the thread) is reported on stderr as `tagents-knowledge: <what>: <detail>` followed by where the panic was, the connection is closed and counted out, and the daemon goes on. The daemon is shared, and a session whose daemon died has no server of its own to fall back on.

use std::{
    cell::RefCell,
    collections::HashMap,
    fs,
    io::{self, ErrorKind, Read, Write},
    net::Shutdown,
    os::{
        fd::OwnedFd,
        unix::net::{UnixListener, UnixStream},
    },
    panic::{self, AssertUnwindSafe},
    path::{Path, PathBuf},
    sync::{Arc, Condvar, Mutex, Once},
    thread,
    time::{Duration, Instant},
};

use rustix::{
    event::{PollFd, PollFlags, Timespec, poll},
    io::Errno,
};

use super::{
    SERVER,
    paths::Env,
    socket::{self, Probe},
    tools::KnowledgeTools,
};
use tagents_core::{
    ending::{self, Stop},
    mcp::{rpc::Out, server::Server, server::Tools},
    node,
    sync::locked,
    watch,
};

/// How long the daemon stays with nobody connected, when it is not told.
pub const DEFAULT_IDLE_SECONDS: f64 = 600.0;

const BIND_ATTEMPTS: usize = 5;
/// The longest one `poll` is asked to wait, so that a huge idle time is no huge timeout.
const LONGEST_WAIT: Duration = Duration::from_secs(3600);
/// What the loop rests after a failed `accept`, so that a descriptor shortage is not a busy loop.
const ACCEPT_REST: Duration = Duration::from_millis(50);

/// How long a connection waits for its client's next bytes before it looks again.
const TICK: Duration = Duration::from_millis(500);

const SET_UP: &str = "a connection could not be set up";
const SERVED: &str = "a connection could not be served";

/// The tools a connection gets, made from the environment of the daemon: `KnowledgeTools`, unless a test needs ones that fail.
pub type Make = Arc<dyn Fn(&Env) -> Arc<dyn Tools> + Send + Sync>;

/// Where a fault is said, one line at a time without its newline.
pub type Report = Arc<dyn Fn(&str) + Send + Sync>;

#[derive(Clone)]
pub struct Options {
    pub socket: PathBuf,
    /// Quiet time after the last connection closes, or after the start when none ever came, before the daemon leaves.
    pub idle: Duration,
    pub env: Env,
    pub tools: Make,
    pub report: Report,
}

impl Options {
    /// The daemon of `socket` with the knowledge tools and faults on stderr.
    pub fn new(socket: PathBuf, idle: Duration, env: Env) -> Options {
        Options {
            socket,
            idle,
            env,
            tools: Arc::new(|env| Arc::new(KnowledgeTools::new(env.clone(), node::now_ms))),
            report: Arc::new(|line| {
                // A stderr nobody can write to is no reason to fail again.
                let _ = writeln!(io::stderr().lock(), "{line}");
            }),
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The daemon listened, served and left.
    Served,
    /// Something already answered on the socket: another server holds it, and it was left alone.
    Taken,
}

/// The daemon of a process: ended by SIGTERM, SIGINT or SIGHUP, which remove its socket and its pid file like any other ending.
pub fn run_until_signalled(options: Options) -> Result<Outcome, String> {
    let stop = Stop::default();
    let signalled = stop.clone();
    ending::on_signals(move |_| signalled.stop()).map_err(|e| e.to_string())?;
    run(options, &stop)
}

/// Listen on the socket and serve until nothing has been connected for `idle` or `stop` comes. `Taken` at once when another daemon holds the socket.
pub fn run(options: Options, stop: &Stop) -> Result<Outcome, String> {
    install_hook();
    if let Some(dir) = options.socket.parent() {
        socket::ensure_private_dir(dir)?;
    }
    let Some(listener) = bind(&options.socket)? else {
        return Ok(Outcome::Taken);
    };
    let pid_file = PathBuf::from(socket::pid_file_of(&options.socket.to_string_lossy()));
    let started = write_pid(&pid_file).and_then(|()| watch::wake_pipe().map_err(|e| e.to_string()));
    let (woken, wake) = match started {
        Ok(pipe) => pipe,
        Err(reason) => {
            release_socket(listener, &options.socket);
            return Err(reason);
        }
    };
    let shared = Arc::new(Shared::new(wake));
    let waking = Arc::clone(&shared);
    stop.watch(move || watch::wake(&waking.wake));

    let options = Arc::new(options);
    let looped = accept_loop(listener, &woken, &shared, &options, stop);
    // The connections are closed by the decision to leave; they are given the time a server needs to end its calls.
    shared.wait_empty(SERVER.kill_grace + SERVER.shutdown_margin + Duration::from_secs(1));
    // The file is the daemon's only while it holds its own number.
    if fs::read_to_string(&pid_file).is_ok_and(|text| text.trim() == std::process::id().to_string())
    {
        let _ = fs::remove_file(&pid_file);
    }
    looped.map(|()| Outcome::Served)
}

fn write_pid(pid_file: &Path) -> Result<(), String> {
    fs::write(pid_file, format!("{}\n", std::process::id()))
        .map_err(|e| node::io_message(&e, "open", Some(&pid_file.to_string_lossy())))
}

// ---- taking the socket name -----------------------------------------------------------------------

fn listen(socket: &Path) -> Result<Option<UnixListener>, String> {
    match UnixListener::bind(socket) {
        Ok(listener) => Ok(Some(listener)),
        Err(e) if e.kind() == ErrorKind::AddrInUse => Ok(None),
        Err(e) => Err(node::io_message(
            &e,
            "listen",
            Some(&socket.to_string_lossy()),
        )),
    }
}

fn probed(socket: &Path) -> Result<Probe, String> {
    socket::probe(socket)
        .map_err(|e| node::io_message(&e, "connect", Some(&socket.to_string_lossy())))
}

/// Take the socket name, or learn that a live server already has it (`None`).
///
/// A dead file is removed and the new `listen` happens in the same critical section: `bind` and `listen` are two system calls, and a probe that lands between them sees a socket that refuses connections and would unlink the server that is about to listen.
fn bind(socket: &Path) -> Result<Option<UnixListener>, String> {
    let shown = socket.to_string_lossy();
    for _ in 0..BIND_ATTEMPTS {
        if let Some(listener) = listen(socket)? {
            return Ok(Some(listener));
        }
        if probed(socket)? == Probe::Live {
            return Ok(None);
        }
        let Some(_lock) = socket::take_lock(Path::new(&socket::lock_dir_of(&shown)), || false)?
        else {
            continue;
        };
        match probed(socket)? {
            Probe::Live => return Ok(None),
            Probe::Stale => socket::remove_dead(socket)?,
            Probe::Absent => {}
        }
        if let Some(listener) = listen(socket)? {
            return Ok(Some(listener));
        }
    }
    Err(format!("could not take {shown}"))
}

/// Give the socket name up. The file goes first: while the listener is open a probe finds it live, so nobody else can have replaced the file. With the listener closed first, a starter that probes before the file is gone sees a dead socket and binds a new one, and this daemon then unlinks that one.
fn release_socket<L>(listener: L, socket: &Path) {
    let _ = fs::remove_file(socket);
    drop(listener);
}

// ---- the connections ------------------------------------------------------------------------------

/// What the loop and the threads of the connections share.
struct Shared {
    state: Mutex<State>,
    /// Told when a connection is counted out.
    emptied: Condvar,
    /// The write end of the pipe the loop polls: a connection that ends tells the loop, which may have to start the idle clock.
    wake: OwnedFd,
}

struct State {
    next: u64,
    /// The streams of the connections being served, kept to close them when the daemon leaves. How many there are is the count of connections.
    connections: HashMap<u64, UnixStream>,
    /// When the count last became zero, or when the daemon started.
    idle_since: Instant,
}

impl Shared {
    fn new(wake: OwnedFd) -> Shared {
        Shared {
            state: Mutex::new(State {
                next: 0,
                connections: HashMap::new(),
                idle_since: Instant::now(),
            }),
            emptied: Condvar::new(),
            wake,
        }
    }

    /// Counts the connection in under the lock and returns its number.
    fn admit(&self, stream: UnixStream) -> u64 {
        let mut state = locked(&self.state);
        state.next += 1;
        let id = state.next;
        state.connections.insert(id, stream);
        id
    }

    /// Counts the connection out, starts the idle clock when it was the last one, and wakes the loop.
    fn release(&self, id: u64) {
        {
            let mut state = locked(&self.state);
            state.connections.remove(&id);
            state.idle_since = Instant::now();
        }
        self.emptied.notify_all();
        watch::wake(&self.wake);
    }

    fn wait_empty(&self, limit: Duration) {
        let state = locked(&self.state);
        let _ = self
            .emptied
            .wait_timeout_while(state, limit, |state| !state.connections.is_empty());
    }
}

/// Serve the connections, then leave, whichever way the serving ended.
fn accept_loop(
    listener: UnixListener,
    woken: &OwnedFd,
    shared: &Arc<Shared>,
    options: &Arc<Options>,
    stop: &Stop,
) -> Result<(), String> {
    serve_then_leave(listener, shared, &options.socket, |listener| {
        serve_until_left(listener, woken, shared, options, stop)
    })
}

/// Runs `serving`, and on every way out of it gives the socket name up and shuts the connections that remain, so that a failure of the loop leaves no socket file and no client waiting.
fn serve_then_leave<L>(
    listener: L,
    shared: &Shared,
    socket: &Path,
    serving: impl FnOnce(&L) -> Result<(), String>,
) -> Result<(), String> {
    let outcome = serving(&listener);
    release_socket(listener, socket);
    for stream in locked(&shared.state).connections.values() {
        let _ = stream.shutdown(Shutdown::Both);
    }
    outcome
}

/// Serve every connection that comes, until the decision to leave: at the stop, or when the count has been zero for the idle time. Only this thread adds connections, and the decision follows a drain of the backlog, so a session that reached the socket while the daemon could not run is counted before it.
fn serve_until_left(
    listener: &UnixListener,
    woken: &OwnedFd,
    shared: &Arc<Shared>,
    options: &Arc<Options>,
    stop: &Stop,
) -> Result<(), String> {
    listener
        .set_nonblocking(true)
        .map_err(|e| node::io_message(&e, "listen", Some(&options.socket.to_string_lossy())))?;
    loop {
        accept_pending(listener, shared, options);
        let wait = {
            let state = locked(&shared.state);
            let left = state
                .connections
                .is_empty()
                .then(|| options.idle.saturating_sub(state.idle_since.elapsed()));
            if stop.is_stopped() || left.is_some_and(|left| left.is_zero()) {
                return Ok(());
            }
            left
        };
        wait_for(listener, woken, wait)?;
    }
}

fn wait_for(
    listener: &UnixListener,
    woken: &OwnedFd,
    wait: Option<Duration>,
) -> Result<(), String> {
    let wait = wait.map(|wait| {
        let wait = wait.min(LONGEST_WAIT);
        Timespec {
            tv_sec: i64::try_from(wait.as_secs()).unwrap_or(i64::MAX),
            tv_nsec: i64::from(wait.subsec_nanos()),
        }
    });
    let mut fds = [
        PollFd::new(listener, PollFlags::IN),
        PollFd::new(woken, PollFlags::IN),
    ];
    match poll(&mut fds, wait.as_ref()) {
        Ok(_) | Err(Errno::INTR) => {}
        Err(e) => {
            return Err(format!(
                "cannot wait for a connection: {}",
                io::Error::from(e)
            ));
        }
    }
    if !fds[1].revents().is_empty() {
        watch::drain(woken);
    }
    Ok(())
}

/// Takes every connection that is waiting, each to a thread of its own.
fn accept_pending(listener: &UnixListener, shared: &Arc<Shared>, options: &Arc<Options>) {
    loop {
        match listener.accept() {
            Ok((stream, _)) => admit(stream, shared, options),
            Err(e) if e.kind() == ErrorKind::WouldBlock => return,
            Err(e)
                if matches!(
                    e.kind(),
                    ErrorKind::Interrupted | ErrorKind::ConnectionAborted
                ) => {}
            Err(e) => {
                (options.report)(&Fault::io(SET_UP, &e).line());
                thread::sleep(ACCEPT_REST);
                return;
            }
        }
    }
}

fn admit(stream: UnixStream, shared: &Arc<Shared>, options: &Arc<Options>) {
    // The stream of an `accept` on a non-blocking listener is non-blocking on macOS and blocking on Linux.
    let kept = stream
        .set_nonblocking(false)
        .and_then(|()| stream.try_clone());
    let kept = match kept {
        Ok(kept) => kept,
        Err(e) => return (options.report)(&Fault::io(SET_UP, &e).line()),
    };
    let id = shared.admit(kept);
    let (shared_here, options_here) = (Arc::clone(shared), Arc::clone(options));
    let spawned = thread::Builder::new()
        .name("tagents-knowledge-connection".into())
        .spawn(move || connection(id, &stream, &shared_here, &options_here));
    if let Err(e) = spawned {
        (options.report)(&Fault::io(SET_UP, &e).line());
        shared.release(id);
    }
}

/// One connection, from its set-up to its end. Whatever goes wrong is said and ends only this connection, which is closed and counted out either way.
fn connection(id: u64, stream: &UnixStream, shared: &Shared, options: &Options) {
    let _admitted = Admitted { id, stream, shared };
    if let Err(fault) = serve(stream, options) {
        (options.report)(&fault.line());
    }
}

/// Closes a connection and counts it out when its thread ends, by a panic too: a connection that stays counted keeps the daemon from ever leaving.
struct Admitted<'a> {
    id: u64,
    stream: &'a UnixStream,
    shared: &'a Shared,
}

impl Drop for Admitted<'_> {
    fn drop(&mut self) {
        let _ = self.stream.shutdown(Shutdown::Both);
        self.shared.release(self.id);
    }
}

/// An MCP server of its own for the stream: it reads until the client ends its writing side or the stream is closed, and answers on the same stream.
fn serve(stream: &UnixStream, options: &Options) -> Result<(), Fault> {
    let clone = |stream: &UnixStream| stream.try_clone().map_err(|e| Fault::io(SET_UP, &e));
    let (reader, writer, closer) = (clone(stream)?, clone(stream)?, clone(stream)?);
    // Darwin refuses the option (EINVAL) on a stream whose client has already closed its writing side: the end is then there to be read, and the read needs no tick to find it.
    let _ = reader.set_read_timeout(Some(TICK));
    let server = caught(SET_UP, || {
        let tools = (options.tools)(&options.env);
        // What leaves the process in the stdio server closes the connection here: an answer that cannot be sent is a client that went away.
        Server::new(tools, Out::new(writer), SERVER, move || {
            let _ = closer.shutdown(Shutdown::Both);
        })
    })?;
    let served = caught(SERVED, || server.serve(Ticking(reader)));
    if served.is_err() {
        server.end();
    }
    served
}

/// A stream read in ticks: a read that timed out is made again, so a quiet client stays connected. A wakeup of the reader can be lost when the client closes its writing side, and a read that looks again finds the end that was missed.
struct Ticking(UnixStream);

impl Read for Ticking {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        loop {
            match self.0.read(buf) {
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
                read => return read,
            }
        }
    }
}

// ---- faults ---------------------------------------------------------------------------------------

/// What went wrong with a connection, in the words of the line it is reported as.
struct Fault {
    what: &'static str,
    detail: String,
}

impl Fault {
    fn io(what: &'static str, e: &io::Error) -> Fault {
        Fault {
            what,
            detail: e.to_string(),
        }
    }

    /// `tagents-knowledge: <what>: <detail>`, where a panic's detail is its message and then the place it happened.
    fn line(&self) -> String {
        format!("tagents-knowledge: {}: {}", self.what, self.detail)
    }
}

/// Where a thread's panic happened, kept for the thread that asked for it by `caught`.
enum Capture {
    Off,
    Armed,
    Caught(String),
}

thread_local! {
    static CAPTURE: RefCell<Capture> = const { RefCell::new(Capture::Off) };
}

/// A panic hook that keeps the place of a panic on a thread that is inside `caught`, so that it is reported once, in the fault line, and not also printed by the default hook; a panic anywhere else goes to the hook that was there. It is installed once, and stays.
fn install_hook() {
    static INSTALLED: Once = Once::new();
    INSTALLED.call_once(|| {
        let previous = panic::take_hook();
        panic::set_hook(Box::new(move |info| {
            let kept = CAPTURE
                .try_with(|capture| {
                    let mut capture = capture.borrow_mut();
                    if matches!(*capture, Capture::Off) {
                        return false;
                    }
                    *capture = Capture::Caught(info.location().map_or_else(String::new, |at| {
                        format!("    at {}:{}:{}", at.file(), at.line(), at.column())
                    }));
                    true
                })
                .unwrap_or(false);
            if !kept {
                previous(info);
            }
        }));
    });
}

/// Runs `step`, and turns a panic of it into the fault `what`.
fn caught<T>(what: &'static str, step: impl FnOnce() -> T) -> Result<T, Fault> {
    CAPTURE.with(|capture| *capture.borrow_mut() = Capture::Armed);
    let result = panic::catch_unwind(AssertUnwindSafe(step));
    let place = CAPTURE.with(|capture| match capture.replace(Capture::Off) {
        Capture::Caught(place) => Some(place),
        Capture::Off | Capture::Armed => None,
    });
    result.map_err(|payload| {
        let message = payload
            .downcast_ref::<&str>()
            .map(|text| (*text).to_owned())
            .or_else(|| payload.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "Box<dyn Any>".to_owned());
        Fault {
            what,
            detail: match place {
                Some(place) if !place.is_empty() => format!("{message}\n{place}"),
                _ => message,
            },
        }
    })
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, Ordering};

    use super::*;
    use crate::testing::Scratch;

    /// Stands for the listener and says whether the socket file was still there when it closed.
    struct Witness {
        socket: PathBuf,
        file_at_close: Arc<AtomicBool>,
    }

    impl Drop for Witness {
        fn drop(&mut self) {
            self.file_at_close
                .store(self.socket.exists(), Ordering::SeqCst);
        }
    }

    #[test]
    fn the_socket_file_goes_before_the_listener_closes() {
        let dir = Scratch::new();
        let socket = dir.path().join("s.sock");
        fs::write(&socket, "").unwrap();
        let file_at_close = Arc::new(AtomicBool::new(true));
        let listener = Witness {
            socket: socket.clone(),
            file_at_close: Arc::clone(&file_at_close),
        };
        release_socket(listener, &socket);
        assert!(!socket.exists());
        assert!(
            !file_at_close.load(Ordering::SeqCst),
            "the listener closed with the file still there, so a probe could see a dead socket"
        );
    }

    #[test]
    fn the_daemon_leaves_on_every_way_out_of_the_serving() {
        for ended in [Ok(()), Err("the wait failed".to_owned())] {
            let dir = Scratch::new();
            let socket = dir.path().join("s.sock");
            fs::write(&socket, "").unwrap();
            let (_woken, wake) = watch::wake_pipe().unwrap();
            let shared = Shared::new(wake);
            let (mut client, served) = UnixStream::pair().unwrap();
            client
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            shared.admit(served);

            let outcome = serve_then_leave((), &shared, &socket, |()| ended.clone());

            assert_eq!(ended, outcome);
            assert!(!socket.exists(), "{ended:?}: the socket file stayed");
            assert_eq!(
                0,
                client.read(&mut [0; 1]).unwrap(),
                "{ended:?}: a connection stayed open"
            );
        }
    }
}
