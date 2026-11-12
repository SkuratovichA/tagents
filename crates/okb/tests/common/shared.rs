//! What a test of the shared knowledge server is made of: an environment that lies in one directory, a daemon on a thread of this process, a client that speaks lines to it, and a starter that runs the daemon in this process.

use std::{
    io::{self, BufRead, BufReader, ErrorKind, Read, Write},
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    thread::{self, JoinHandle},
    time::Duration,
};

use okb::knowledge::{
    daemon::{Options, Outcome, run},
    paths::Env,
    socket::{Ended, Launch, Starter, pid_file_of, socket_path},
};
use serde_json::{Value, json};
use tagents_core::ending::Stop;

use super::rig::until;

/// Makes a read of the stream wait half a second at most, as the daemon does for its connections: with `Ticks` it is the one way a scripted server of a test reads.
pub fn ticking(stream: &UnixStream) {
    stream
        .set_read_timeout(Some(Duration::from_millis(500)))
        .unwrap();
}

/// A stream read in ticks (see `ticking`): a read that timed out is made again, and a lost wakeup of the reader is found at the next one.
pub struct Ticks<'a>(pub &'a UnixStream);

impl Read for Ticks<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        loop {
            match self.0.read(buf) {
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
                read => return read,
            }
        }
    }
}

/// An environment that is all in `dir`, as the daemon of a test needs it.
pub fn env_in(dir: &Path) -> Env {
    let text = dir.to_str().unwrap();
    Env {
        home: text.into(),
        home_var: Some(text.into()),
        cwd: text.into(),
        tagents_config_dir: Some(format!("{text}/config")),
        tmpdir: Some(text.into()),
        ..Env::default()
    }
}

pub fn options(dir: &Path, idle: Duration) -> Options {
    Options::new(dir.join("s.sock"), idle, env_in(dir))
}

/// A daemon on a thread of this process, stopped when the value goes.
pub struct Daemon {
    pub stop: Stop,
    pub handle: Option<JoinHandle<Result<Outcome, String>>>,
    pub socket: PathBuf,
}

impl Daemon {
    /// Run the daemon and wait until it listens, or has left without listening.
    pub fn start(options: Options) -> Daemon {
        let daemon = Daemon::spawn(options);
        let pid_file = PathBuf::from(pid_file_of(daemon.socket.to_str().unwrap()));
        assert!(
            until(|| pid_file.exists() || daemon.left(), 5000),
            "the daemon did not listen"
        );
        daemon
    }

    pub fn spawn(options: Options) -> Daemon {
        let socket = options.socket.clone();
        let stop = Stop::default();
        let handle = thread::spawn({
            let stop = stop.clone();
            move || run(options, &stop)
        });
        Daemon {
            stop,
            handle: Some(handle),
            socket,
        }
    }

    pub fn left(&self) -> bool {
        self.handle.as_ref().is_none_or(JoinHandle::is_finished)
    }

    pub fn pid_file(&self) -> PathBuf {
        PathBuf::from(pid_file_of(self.socket.to_str().unwrap()))
    }

    /// Wait for the daemon to leave on its own.
    pub fn outcome(&mut self) -> Result<Outcome, String> {
        assert!(until(|| self.left(), 10_000), "the daemon did not leave");
        self.handle.take().unwrap().join().unwrap()
    }

    /// Ask it to leave and take what it says.
    pub fn finish(&mut self) -> Result<Outcome, String> {
        self.stop.stop();
        self.outcome()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        self.stop.stop();
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

/// A client of the daemon: lines in, lines out.
pub struct Client {
    pub writer: UnixStream,
    pub lines: BufReader<UnixStream>,
}

impl Client {
    pub fn connect(socket: &Path) -> Client {
        let writer = UnixStream::connect(socket).unwrap();
        writer
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let lines = BufReader::new(writer.try_clone().unwrap());
        Client { writer, lines }
    }

    pub fn send(&mut self, text: &str) {
        writeln!(self.writer, "{text}").unwrap();
    }

    /// The next line, or `None` when the daemon closed the connection.
    pub fn read(&mut self) -> Option<Value> {
        let mut line = String::new();
        match self.lines.read_line(&mut line) {
            Ok(0) => None,
            Ok(_) => Some(serde_json::from_str(&line).unwrap()),
            Err(e) if e.kind() == ErrorKind::ConnectionReset => None,
            Err(e) => panic!("reading from the daemon: {e}"),
        }
    }

    pub fn ask(&mut self, id: u64, method: &str, params: &Value) -> Value {
        self.send(
            &json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}).to_string(),
        );
        loop {
            let reply = self.read().expect("the daemon closed the connection");
            if reply["id"] == id {
                return reply;
            }
        }
    }

    pub fn handshake(&mut self) -> Value {
        let reply = self.ask(
            1,
            "initialize",
            &json!({"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "0.0.0"}}),
        );
        self.send(&json!({"jsonrpc": "2.0", "method": "notifications/initialized"}).to_string());
        reply
    }
}

pub fn serves(socket: &Path) {
    let mut client = Client::connect(socket);
    assert_eq!(
        "tagents-knowledge",
        client.handshake()["result"]["serverInfo"]["name"]
    );
}

/// A starter that runs the daemon on a thread of this process and counts how often it was asked to.
#[derive(Default)]
pub struct InProcess {
    pub starts: AtomicUsize,
    pub stops: Mutex<Vec<Stop>>,
}

impl InProcess {
    pub fn stop_all(&self) {
        for stop in self.stops.lock().unwrap().iter() {
            stop.stop();
        }
    }
}

impl Starter for InProcess {
    fn stamp(&self) -> Result<String, String> {
        Ok("test".to_owned())
    }

    fn start(&self, launch: &Launch<'_>) -> std::io::Result<Ended> {
        self.starts.fetch_add(1, Ordering::SeqCst);
        let options = Options::new(
            launch.socket.to_owned(),
            Duration::from_secs_f64(launch.idle),
            launch.env.clone(),
        );
        let stop = Stop::default();
        self.stops.lock().unwrap().push(stop.clone());
        let handle = thread::spawn(move || run(options, &stop));
        Ok(Box::new(move || handle.is_finished()))
    }
}

/// The socket `ensure` would use for the environment of `dir` under the stamp of `InProcess`.
pub fn ensured_socket(dir: &Path) -> PathBuf {
    PathBuf::from(socket_path(&env_in(dir), rustix_uid(), "test"))
}

pub fn rustix_uid() -> u32 {
    rustix::process::geteuid().as_raw()
}
