//! `tagents-core knowledge join`: the byte relay between a session's standard streams and the shared server, and the three things it adds to a copy: the end of the input is passed on and the replies that are still to come are copied, a connection that ends before its first reply is made once more with what was sent, and one that ends after a reply is an error. The relay is run in this process on a pipe for its input, against a server that is scripted connection by connection, or against the real daemon where the daemon is the point. What the verb adds around it (the arguments, the choice of server, the fallback to a server of this process) is `knowledge_serve.rs` and the front door's tests.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::{
    io::{BufRead, BufReader, PipeWriter, Read, Write},
    os::{
        fd::AsFd,
        unix::net::{UnixListener, UnixStream},
    },
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
        mpsc,
    },
    thread::{self, JoinHandle},
    time::Duration,
};

use tagents_core::knowledge::{
    daemon::Outcome,
    join::{REPLAY_CAP, WENT_AWAY, relay},
    socket::ensure,
};

use common::{
    rig::until,
    shared::{Daemon, InProcess, Ticks, env_in, options, serves, ticking},
    short_scratch,
};

const HANDSHAKE: &str = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0.0.0"}}}"#;

/// What the verb's served-here fallback was given, and what it answered.
const HERE: u8 = 7;

/// The output of the relay, which the test reads while the relay runs.
#[derive(Clone, Default)]
struct Sink(Arc<Mutex<Vec<u8>>>);

impl Sink {
    fn text(&self) -> String {
        String::from_utf8(self.0.lock().unwrap().clone()).unwrap()
    }

    fn len(&self) -> usize {
        self.0.lock().unwrap().len()
    }

    fn has(&self, part: &str) -> bool {
        self.text().contains(part)
    }
}

impl Write for Sink {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// An output whose reader has gone away.
struct Gone;

impl Write for Gone {
    fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
        Err(std::io::Error::from(std::io::ErrorKind::BrokenPipe))
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

type Connect = Box<dyn Fn() -> Result<UnixStream, String> + Send>;

/// A connector to `socket` that counts how often it is asked.
fn connector(socket: &Path) -> (Connect, Arc<AtomicUsize>) {
    let calls = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&calls);
    let socket = socket.to_owned();
    let connect: Connect = Box::new(move || {
        counted.fetch_add(1, Ordering::SeqCst);
        UnixStream::connect(&socket).map_err(|e| e.to_string())
    });
    (connect, calls)
}

/// What a run of the relay came to.
struct Ran {
    code: u8,
    errors: String,
    /// What the fallback was given, once for each time it was called.
    here: Vec<Vec<u8>>,
}

/// Run the relay on a thread of its own, on a pipe, writing to `output`, while `drive` plays the session: it gets the writing end of the input and what the relay has written so far, and returns the writing end when the input is to stay open until the relay has ended, or nothing when it has closed it.
fn run_with(
    connect: Connect,
    output: Box<dyn Write + Send>,
    seen: &Sink,
    drive: impl FnOnce(PipeWriter, &Sink) -> Option<PipeWriter> + Send + 'static,
) -> Ran {
    let (reader, writer) = std::io::pipe().unwrap();
    let here = Arc::new(Mutex::new(Vec::new()));
    let relaying = thread::spawn({
        let here = Arc::clone(&here);
        let mut output = output;
        move || {
            let mut errors = Vec::new();
            let code = relay(
                reader.as_fd(),
                &mut *output,
                &mut errors,
                &*connect,
                &mut |replay| {
                    here.lock().unwrap().push(replay);
                    HERE
                },
            );
            (code, String::from_utf8(errors).unwrap())
        }
    });
    let playing = thread::spawn({
        let seen = seen.clone();
        move || drive(writer, &seen)
    });
    assert!(
        until(|| relaying.is_finished(), 15_000),
        "the relay did not end"
    );
    let (code, errors) = relaying.join().unwrap();
    let writer = playing.join().unwrap();
    drop(writer);
    let here = here.lock().unwrap().clone();
    Ran { code, errors, here }
}

fn run(
    connect: Connect,
    drive: impl FnOnce(PipeWriter, &Sink) -> Option<PipeWriter> + Send + 'static,
) -> (Ran, Sink) {
    let sink = Sink::default();
    let ran = run_with(connect, Box::new(sink.clone()), &sink, drive);
    (ran, sink)
}

/// The session: sends `text`, waits until the relay has written `until_seen` (or does not wait when it is empty), and closes its output when `close` says so.
fn session(
    text: &'static str,
    until_seen: &'static str,
    close: bool,
) -> impl FnOnce(PipeWriter, &Sink) -> Option<PipeWriter> + Send + 'static {
    move |mut writer, sink| {
        writer.write_all(text.as_bytes()).unwrap();
        if !until_seen.is_empty() {
            assert!(
                until(|| sink.has(until_seen), 10_000),
                "{until_seen:?} not seen in {:?}",
                sink.text()
            );
        }
        (!close).then_some(writer)
    }
}

// ---- a server that is scripted connection by connection -----------------------------------------

type Script = Box<dyn FnOnce(UnixStream) + Send>;

/// A server that takes the connections that come and answers the n-th as the n-th script says, and has nobody listening after the last: a connection after it is refused.
fn scripted(dir: &Path, scripts: Vec<Script>) -> (PathBuf, JoinHandle<()>) {
    let socket = dir.join("fake.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let handle = thread::spawn(move || {
        for script in scripts {
            let (stream, _) = listener.accept().unwrap();
            ticking(&stream);
            script(stream);
        }
    });
    (socket, handle)
}

fn line_from(stream: &UnixStream) -> String {
    let mut line = String::new();
    BufReader::new(Ticks(stream)).read_line(&mut line).unwrap();
    line
}

fn rest_of(stream: &UnixStream) -> Vec<u8> {
    let mut all = Vec::new();
    Ticks(stream).read_to_end(&mut all).unwrap();
    all
}

/// A script that reads a line, tells what it was and goes without a reply.
fn leaves_after_a_line(told: mpsc::Sender<String>) -> Script {
    Box::new(move |stream| {
        told.send(line_from(&stream)).unwrap();
    })
}

/// A script that reads a line, tells what it was, answers `reply`, waits for the end of the input and goes.
fn answers_then_waits(told: mpsc::Sender<String>, reply: &'static str) -> Script {
    Box::new(move |mut stream| {
        told.send(line_from(&stream)).unwrap();
        stream.write_all(reply.as_bytes()).unwrap();
        rest_of(&stream);
    })
}

// ---- the three things the relay adds ------------------------------------------------------------

#[test]
fn input_that_ends_releases_the_daemon_at_once() {
    let dir = short_scratch("join-end");
    let mut daemon = Daemon::start(options(&dir, Duration::from_millis(400)));
    let (connect, calls) = connector(&daemon.socket);
    let text: &'static str =
        format!("{HANDSHAKE}\n{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}}\n")
            .leak();
    let (ran, sink) = run(connect, session(text, "serverInfo", true));
    assert_eq!((0, ""), (ran.code, ran.errors.as_str()));
    assert!(
        sink.has("\"name\":\"tagents-knowledge\""),
        "{}",
        sink.text()
    );
    assert_eq!(1, calls.load(Ordering::SeqCst));
    // The connection is not counted any more, so the idle time runs and the daemon leaves.
    assert_eq!(Ok(Outcome::Served), daemon.outcome());
}

#[test]
fn empty_input_starts_the_daemon_and_leaves_it_running_for_the_session_that_comes() {
    let dir = short_scratch("join-probe");
    let starter = Arc::new(InProcess::default());
    let env = env_in(&dir);
    let socket = Arc::new(Mutex::new(PathBuf::new()));
    let connect: Connect = Box::new({
        let (starter, socket) = (Arc::clone(&starter), Arc::clone(&socket));
        move || {
            let found = ensure(&env, 30.0, &*starter)?;
            *socket.lock().unwrap() = found.clone();
            UnixStream::connect(&found).map_err(|e| e.to_string())
        }
    });
    let (ran, sink) = run(connect, session("", "", true));
    assert_eq!((0, ""), (ran.code, ran.errors.as_str()));
    assert_eq!("", sink.text());
    assert!(ran.here.is_empty());
    assert_eq!(1, starter.starts.load(Ordering::SeqCst));
    serves(&socket.lock().unwrap());
    starter.stop_all();
}

#[test]
fn the_replies_that_come_after_the_input_ended_are_copied_until_the_server_closes() {
    let dir = short_scratch("join-late");
    let (socket, server) = scripted(
        &dir,
        vec![Box::new(|mut stream| {
            let got = rest_of(&stream);
            assert_eq!(b"hello\n".as_slice(), got.as_slice());
            stream.write_all(b"late reply\n").unwrap();
        })],
    );
    let (connect, calls) = connector(&socket);
    let (ran, sink) = run(connect, session("hello\n", "", true));
    assert_eq!((0, ""), (ran.code, ran.errors.as_str()));
    assert_eq!("late reply\n", sink.text());
    assert_eq!(1, calls.load(Ordering::SeqCst));
    server.join().unwrap();
}

#[test]
fn a_server_that_leaves_between_the_connect_and_the_first_reply_is_connected_to_again_and_sent_what_was_sent()
 {
    let dir = short_scratch("join-retry");
    let (first, first_saw) = mpsc::channel();
    let (second, second_saw) = mpsc::channel();
    let (socket, server) = scripted(
        &dir,
        vec![
            leaves_after_a_line(first),
            answers_then_waits(second, "answer\n"),
        ],
    );
    let (connect, calls) = connector(&socket);
    let (ran, sink) = run(connect, session("first\n", "answer\n", true));
    assert_eq!((0, ""), (ran.code, ran.errors.as_str()));
    assert_eq!("answer\n", sink.text());
    assert_eq!(2, calls.load(Ordering::SeqCst));
    assert_eq!("first\n", first_saw.recv().unwrap());
    assert_eq!("first\n", second_saw.recv().unwrap());
    assert!(ran.here.is_empty());
    server.join().unwrap();
}

#[test]
fn what_is_sent_after_the_retry_follows_the_replay_on_the_new_connection() {
    let dir = short_scratch("join-retry-more");
    let (first, first_saw) = mpsc::channel();
    let (socket, server) = scripted(
        &dir,
        vec![
            leaves_after_a_line(first),
            Box::new(|mut stream| {
                let got = rest_of(&stream);
                assert_eq!(b"one\ntwo\n".as_slice(), got.as_slice());
                stream.write_all(b"both\n").unwrap();
            }),
        ],
    );
    let (connect, _) = connector(&socket);
    let (ran, sink) = run(connect, |mut writer, _| {
        writer.write_all(b"one\n").unwrap();
        // The first server is gone by now and the second one has the replay: the second line follows it.
        thread::sleep(Duration::from_millis(300));
        writer.write_all(b"two\n").unwrap();
        drop(writer);
        None
    });
    assert_eq!((0, ""), (ran.code, ran.errors.as_str()));
    assert_eq!("both\n", sink.text());
    assert_eq!("one\n", first_saw.recv().unwrap());
    server.join().unwrap();
}

#[test]
fn a_server_that_goes_after_its_first_reply_ends_join_with_exit_1_and_the_line() {
    let dir = short_scratch("join-dies");
    let (socket, server) = scripted(
        &dir,
        vec![Box::new(|mut stream| {
            line_from(&stream);
            stream.write_all(b"r1\n").unwrap();
        })],
    );
    let (connect, calls) = connector(&socket);
    let (ran, sink) = run(connect, session("q\n", "r1\n", false));
    assert_eq!(1, ran.code);
    assert_eq!(format!("{WENT_AWAY}\n"), ran.errors);
    assert_eq!("tagents-knowledge: the shared server went away", WENT_AWAY);
    assert_eq!("r1\n", sink.text());
    assert_eq!(1, calls.load(Ordering::SeqCst));
    assert!(ran.here.is_empty());
    server.join().unwrap();
}

#[test]
fn a_server_that_goes_twice_before_a_reply_is_tried_once_more_and_then_it_is_an_error() {
    let dir = short_scratch("join-twice");
    let (first, first_saw) = mpsc::channel();
    let (second, second_saw) = mpsc::channel();
    let (socket, server) = scripted(
        &dir,
        vec![leaves_after_a_line(first), leaves_after_a_line(second)],
    );
    let (connect, calls) = connector(&socket);
    let (ran, sink) = run(connect, session("q\n", "", false));
    assert_eq!(1, ran.code);
    assert_eq!(format!("{WENT_AWAY}\n"), ran.errors);
    assert_eq!("", sink.text());
    assert_eq!(2, calls.load(Ordering::SeqCst));
    assert_eq!("q\n", first_saw.recv().unwrap());
    assert_eq!("q\n", second_saw.recv().unwrap());
    assert!(ran.here.is_empty());
    server.join().unwrap();
}

/// A line of `bytes` bytes, the newline included.
fn line_of(bytes: usize) -> String {
    format!("{}\n", "a".repeat(bytes - 1))
}

#[test]
fn what_was_sent_is_replayed_up_to_exactly_the_cap() {
    assert_eq!(64 * 1024, REPLAY_CAP);
    let dir = short_scratch("join-cap");
    let text: &'static str = line_of(REPLAY_CAP).leak();
    let (first, first_saw) = mpsc::channel();
    let (second, second_saw) = mpsc::channel();
    let (socket, server) = scripted(
        &dir,
        vec![
            leaves_after_a_line(first),
            answers_then_waits(second, "ok\n"),
        ],
    );
    let (connect, calls) = connector(&socket);
    let (ran, sink) = run(connect, session(text, "ok\n", true));
    assert_eq!((0, ""), (ran.code, ran.errors.as_str()));
    assert_eq!("ok\n", sink.text());
    assert_eq!(2, calls.load(Ordering::SeqCst));
    assert_eq!(text, first_saw.recv().unwrap());
    assert_eq!(text, second_saw.recv().unwrap());
    server.join().unwrap();
}

#[test]
fn what_was_sent_past_the_cap_is_not_replayed_and_a_server_that_goes_is_an_error() {
    let dir = short_scratch("join-over");
    let text: &'static str = line_of(REPLAY_CAP + 1).leak();
    let (first, first_saw) = mpsc::channel();
    let (socket, server) = scripted(&dir, vec![leaves_after_a_line(first)]);
    let (connect, calls) = connector(&socket);
    let (ran, sink) = run(connect, session(text, "", false));
    assert_eq!(1, ran.code);
    assert_eq!(format!("{WENT_AWAY}\n"), ran.errors);
    assert_eq!("", sink.text());
    assert_eq!(1, calls.load(Ordering::SeqCst));
    assert_eq!(text, first_saw.recv().unwrap());
    assert!(ran.here.is_empty());
    server.join().unwrap();
}

#[test]
fn what_was_sent_before_a_reply_is_forgotten_at_the_first_reply_byte() {
    // After a reply the replay buffer is dropped, so a later cap overflow is no reason to fail: the server stays and a large request goes through.
    let dir = short_scratch("join-forget");
    let text: &'static str = line_of(REPLAY_CAP * 3).leak();
    let (socket, server) = scripted(
        &dir,
        vec![Box::new(|mut stream| {
            stream.write_all(b"hello\n").unwrap();
            let got = rest_of(&stream);
            assert_eq!(REPLAY_CAP * 3, got.len());
        })],
    );
    let (connect, calls) = connector(&socket);
    let (ran, sink) = run(connect, move |mut writer, sink| {
        assert!(until(|| sink.has("hello\n"), 10_000));
        writer.write_all(text.as_bytes()).unwrap();
        drop(writer);
        None
    });
    assert_eq!((0, ""), (ran.code, ran.errors.as_str()));
    assert_eq!("hello\n", sink.text());
    assert_eq!(1, calls.load(Ordering::SeqCst));
    server.join().unwrap();
}

// ---- no reply is wanted, no server can be had, the reader is gone --------------------------------

#[test]
fn input_that_ended_without_a_word_is_no_reason_to_connect_again() {
    let dir = short_scratch("join-quiet");
    let (socket, server) = scripted(
        &dir,
        vec![Box::new(|stream| {
            // The server closes when the session's input has ended, as a daemon does that is leaving: if it closed before the relay had seen the end, the relay could not tell a session with nothing to say from one not yet begun.
            rest_of(&stream);
        })],
    );
    let (connect, calls) = connector(&socket);
    let (ran, sink) = run(connect, session("", "", true));
    assert_eq!((0, ""), (ran.code, ran.errors.as_str()));
    assert_eq!("", sink.text());
    assert_eq!(1, calls.load(Ordering::SeqCst));
    server.join().unwrap();
}

#[test]
fn a_server_that_leaves_before_the_session_has_sent_a_byte_is_replaced_for_it() {
    let dir = short_scratch("join-early");
    let (second, second_saw) = mpsc::channel();
    let (socket, server) = scripted(
        &dir,
        vec![Box::new(drop), answers_then_waits(second, "answer\n")],
    );
    let (connect, calls) = connector(&socket);
    let (ran, sink) = run(connect, |mut writer, sink| {
        // The first server is gone before the first byte is sent, and the session has not ended.
        thread::sleep(Duration::from_millis(300));
        writer.write_all(b"late\n").unwrap();
        assert!(until(|| sink.has("answer\n"), 10_000));
        drop(writer);
        None
    });
    assert_eq!((0, ""), (ran.code, ran.errors.as_str()));
    assert_eq!("answer\n", sink.text());
    assert_eq!(2, calls.load(Ordering::SeqCst));
    assert_eq!("late\n", second_saw.recv().unwrap());
    server.join().unwrap();
}

#[test]
fn input_that_ended_after_a_request_nobody_answered_is_sent_once_more_and_is_no_failure() {
    let dir = short_scratch("join-ended-retry");
    let (socket, server) = scripted(
        &dir,
        vec![
            Box::new(|stream| {
                rest_of(&stream);
            }),
            Box::new(|mut stream| {
                assert_eq!(b"q\n".as_slice(), rest_of(&stream).as_slice());
                stream.write_all(b"a\n").unwrap();
            }),
        ],
    );
    let (connect, calls) = connector(&socket);
    let (ran, sink) = run(connect, session("q\n", "", true));
    assert_eq!((0, ""), (ran.code, ran.errors.as_str()));
    assert_eq!("a\n", sink.text());
    assert_eq!(2, calls.load(Ordering::SeqCst));
    server.join().unwrap();
}

#[test]
fn when_no_server_can_be_had_the_session_is_served_here_with_nothing_read_yet() {
    let connect: Connect = Box::new(|| Err("no server".to_owned()));
    let (ran, sink) = run(connect, session("", "", true));
    assert_eq!((HERE, ""), (ran.code, ran.errors.as_str()));
    assert_eq!(vec![Vec::<u8>::new()], ran.here);
    assert_eq!("", sink.text());
}

#[test]
fn when_the_second_connection_cannot_be_had_the_session_is_served_here_with_what_was_read() {
    let dir = short_scratch("join-second");
    let (first, first_saw) = mpsc::channel();
    let (socket, server) = scripted(&dir, vec![leaves_after_a_line(first)]);
    let (first_connect, calls) = connector(&socket);
    let connect: Connect = Box::new(move || {
        if calls.load(Ordering::SeqCst) == 0 {
            first_connect()
        } else {
            Err("gone".to_owned())
        }
    });
    let (ran, sink) = run(connect, session("first\n", "", false));
    assert_eq!((HERE, ""), (ran.code, ran.errors.as_str()));
    assert_eq!(vec![b"first\n".to_vec()], ran.here);
    assert_eq!("", sink.text());
    assert_eq!("first\n", first_saw.recv().unwrap());
    server.join().unwrap();
}

#[test]
fn a_reader_that_went_away_releases_the_server_and_ends_join_with_exit_0() {
    let dir = short_scratch("join-reader-gone");
    let (released, release_seen) = mpsc::channel();
    let (socket, server) = scripted(
        &dir,
        vec![Box::new(move |mut stream| {
            line_from(&stream);
            stream.write_all(b"r\n").unwrap();
            // The relay shuts the connection down, which this read sees as its end.
            rest_of(&stream);
            released.send(()).unwrap();
        })],
    );
    let (connect, _) = connector(&socket);
    let sink = Sink::default();
    let ran = run_with(connect, Box::new(Gone), &sink, session("q\n", "", false));
    assert_eq!((0, ""), (ran.code, ran.errors.as_str()));
    release_seen
        .recv_timeout(Duration::from_secs(10))
        .expect("the server was not released");
    server.join().unwrap();
}

#[test]
fn a_large_reply_arrives_whole() {
    let dir = short_scratch("join-large");
    let size = 300_000;
    let (socket, server) = scripted(
        &dir,
        vec![Box::new(move |mut stream| {
            line_from(&stream);
            stream.write_all(&vec![b'x'; size]).unwrap();
            rest_of(&stream);
        })],
    );
    let (connect, _) = connector(&socket);
    let (ran, sink) = run(connect, move |mut writer, sink| {
        writer.write_all(b"q\n").unwrap();
        assert!(until(|| sink.len() == size, 10_000), "{}", sink.len());
        drop(writer);
        None
    });
    assert_eq!((0, ""), (ran.code, ran.errors.as_str()));
    assert_eq!(size, sink.len());
    server.join().unwrap();
}
