//! The real `World` of a turn (design D6): one thread per pipe and one that waits for the child, feeding one channel, and a loop that sleeps in `recv_timeout` until the next timer of the machine. No signal handler is installed: a signal that ends the CLI leaves the child running, as it does in node.

use std::io::{ErrorKind, Read};
use std::os::fd::OwnedFd;
use std::process::{Child, ChildStderr, ChildStdout};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender, TryRecvError};
use std::time::Instant;

use rustix::process::{Pid, Signal, kill_process};

use crate::child::{self, DRAIN_STEP, READER_WAIT, Stream};
use crate::notify::clock::{Clock, SystemClock};
use crate::session::turn::{Exit, Msg, Next, World};

/// How much one read of a pipe takes, which is what libuv gives a read.
const READ_SIZE: usize = 64 * 1024;

/// The threads of a turn, started before the child is, because one that cannot be started hands the call to node and nothing may have run by then. Each waits for what it is to watch; dropped instead, they end.
#[derive(Debug)]
pub struct Watch {
    messages: Receiver<Msg>,
    stdout: Sender<ChildStdout>,
    stderr: Sender<ChildStderr>,
    exit: Sender<Pid>,
}

impl Watch {
    pub fn start() -> Result<Watch, String> {
        let (send, messages) = mpsc::channel();
        let (stdout, out_pipe) = mpsc::channel();
        let (stderr, err_pipe) = mpsc::channel();
        let (exit, pid) = mpsc::channel();
        let sender = send.clone();
        child::spawn_thread("turn out", move || {
            read_pipe(&out_pipe, &sender, Msg::Out, Msg::OutEnd);
        })?;
        let sender = send.clone();
        child::spawn_thread("turn err", move || {
            read_pipe(&err_pipe, &sender, Msg::Err, Msg::ErrEnd);
        })?;
        child::spawn_thread("turn exit", move || {
            if let Ok(pid) = pid.recv() {
                child::wait_for_exit(pid);
                let _ = send.send(Msg::Exited);
            }
        })?;
        Ok(Watch {
            messages,
            stdout,
            stderr,
            exit,
        })
    }

    /// The threads go to work on `child`. `on_event` hears every event line, with no newline, as it is read.
    pub fn watch<E: FnMut(&str)>(self, mut child: Child, on_event: E) -> Supervisor<E> {
        let mut open = Vec::with_capacity(2);
        // A pipe with no duplicate is one the end of the drain cannot ask about, and that is all it loses.
        if let Some(pipe) = child.stdout.take() {
            if let Ok(duplicate) = child::duplicate(&pipe) {
                open.push((Stream::Out, duplicate));
            }
            let _ = self.stdout.send(pipe);
        }
        if let Some(pipe) = child.stderr.take() {
            if let Ok(duplicate) = child::duplicate(&pipe) {
                open.push((Stream::Err, duplicate));
            }
            let _ = self.stderr.send(pipe);
        }
        let pid = Pid::from_child(&child);
        let _ = self.exit.send(pid);
        Supervisor {
            child,
            pid: Some(pid),
            messages: self.messages,
            open,
            queued_until: None,
            on_event,
        }
    }
}

/// Reads a pipe to its end, also once the turn is over, so the child and whatever it left behind can go on writing, and tells the machine what it read.
fn read_pipe<P: Read>(
    pipe: &Receiver<P>,
    messages: &Sender<Msg>,
    bytes: fn(Vec<u8>) -> Msg,
    end: Msg,
) {
    let Ok(mut pipe) = pipe.recv() else {
        return;
    };
    let mut buffer = vec![0; READ_SIZE];
    loop {
        match pipe.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => {
                if messages.send(bytes(buffer[..read].to_vec())).is_err() {
                    break;
                }
            }
            Err(error) if error.kind() == ErrorKind::Interrupted => {}
            Err(_) => break,
        }
    }
    let _ = messages.send(end);
}

/// A child and the threads that watch it.
#[derive(Debug)]
pub struct Supervisor<E> {
    child: Child,
    /// Until the child is reaped: no signal goes to a pid after that.
    pid: Option<Pid>,
    messages: Receiver<Msg>,
    /// A duplicate of each pipe whose reader has not reached its end, to ask whether it holds what its reader has not taken yet.
    open: Vec<(Stream, OwnedFd)>,
    /// The end of the wait for a reader once the drain is over.
    queued_until: Option<Instant>,
    on_event: E,
}

impl<E> Supervisor<E> {
    fn noted(&mut self, msg: Msg) -> Msg {
        match msg {
            Msg::OutEnd => self.open.retain(|(stream, _)| *stream != Stream::Out),
            Msg::ErrEnd => self.open.retain(|(stream, _)| *stream != Stream::Err),
            _ => {}
        }
        msg
    }
}

impl<E: FnMut(&str)> World for Supervisor<E> {
    fn now(&self) -> Instant {
        Instant::now()
    }

    fn wall_ms(&self) -> f64 {
        SystemClock.now_ms()
    }

    fn next(&mut self, until: Option<Instant>) -> Next {
        let message = match until {
            Some(at) => self
                .messages
                .recv_timeout(at.saturating_duration_since(Instant::now())),
            None => self
                .messages
                .recv()
                .map_err(|_| RecvTimeoutError::Disconnected),
        };
        match message {
            Ok(msg) => Next::Msg(self.noted(msg)),
            Err(RecvTimeoutError::Timeout) => Next::Timeout,
            Err(RecvTimeoutError::Disconnected) => Next::Closed,
        }
    }

    fn queued(&mut self) -> Option<Msg> {
        let until = *self
            .queued_until
            .get_or_insert_with(|| Instant::now() + READER_WAIT);
        loop {
            if Instant::now() >= until {
                return None;
            }
            match self.messages.try_recv() {
                Ok(msg) => return Some(self.noted(msg)),
                Err(TryRecvError::Disconnected) => return None,
                Err(TryRecvError::Empty) => {}
            }
            // A pipe that is empty and still open is held by something that outlives the child, and a reader is not behind on it.
            if !child::readable(&self.open) {
                return None;
            }
            match self.messages.recv_timeout(DRAIN_STEP) {
                Ok(msg) => return Some(self.noted(msg)),
                Err(RecvTimeoutError::Disconnected) => return None,
                Err(RecvTimeoutError::Timeout) => {}
            }
        }
    }

    fn reap(&mut self) -> Exit {
        self.pid = None;
        self.child.wait().map_or_else(|_| Exit::unknown(), Exit::of)
    }

    fn kill(&mut self) {
        if let Some(pid) = self.pid {
            let _ = kill_process(pid, Signal::KILL);
        }
    }

    fn event(&mut self, line: &str) {
        (self.on_event)(line);
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::BTreeMap;
    use std::fs;
    use std::path::Path;
    use std::rc::Rc;
    use std::time::Duration;

    use rustix::process::test_kill_process;

    use super::*;
    use crate::session::command::Invocation;
    use crate::session::outcome::Outcome;
    use crate::session::spawn::{self, Start};
    use crate::session::turn::{self, Turn};
    use crate::testing::{Scratch, gate};

    const RESULT: &str =
        r#"printf '{"type":"result","is_error":false,"result":"r","session_id":"s"}\n'"#;

    /// A real child running `script` in a directory of its own, and what watches it.
    fn begin<E: FnMut(&str)>(script: &str, on_event: E) -> (Supervisor<E>, Scratch) {
        let scratch = Scratch::new();
        let stub = scratch.path().join("bin/claude");
        gate::write_executable(&stub, &format!("#!/bin/sh\n{script}\n"));
        let invocation = Invocation {
            program: stub.to_str().unwrap().to_owned(),
            args: Vec::new(),
            env: BTreeMap::from([("PATH".to_owned(), "/usr/bin:/bin".to_owned())]),
            cwd: scratch.path().to_str().unwrap().to_owned(),
        };
        let watch = Watch::start().unwrap();
        let start = spawn::start(&invocation);
        let Start::Started(child) = start else {
            panic!("not started: {start:?}")
        };
        (watch.watch(child, on_event), scratch)
    }

    /// The outcome of a whole turn of `script`.
    fn turn_of(script: &str, limit_ms: f64) -> Outcome {
        let (mut world, _scratch) = begin(script, |_: &str| {});
        let mut turn = Turn::new(limit_ms, false, world.now(), world.wall_ms());
        let outcome = turn::run(&mut turn, &mut world);
        turn::linger(&mut turn, &mut world);
        outcome
    }

    /// The content of a file its writer has ended with a newline. The wait is the failure of the test, never its pace.
    fn written(path: &Path) -> String {
        let given_up = Instant::now() + Duration::from_secs(30);
        loop {
            let text = fs::read_to_string(path).unwrap_or_default();
            if text.ends_with('\n') {
                return text;
            }
            assert!(Instant::now() < given_up, "{} stayed empty", path.display());
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    fn pid_in(path: &Path) -> Pid {
        Pid::from_raw(written(path).trim().parse().unwrap()).unwrap()
    }

    #[test]
    fn a_line_written_just_before_the_exit_is_not_lost() {
        let lines = Rc::new(RefCell::new(Vec::new()));
        let heard = Rc::clone(&lines);
        let (mut world, _scratch) = begin(RESULT, move |line: &str| {
            heard.borrow_mut().push(line.to_owned());
        });
        let mut turn = Turn::new(60_000.0, true, world.now(), world.wall_ms());
        let outcome = turn::run(&mut turn, &mut world);
        assert!(matches!(outcome, Outcome::Ok(_)), "{outcome:?}");
        let lines = lines.borrow();
        assert_eq!(lines.len(), 1, "{lines:?}");
        assert!(lines[0].starts_with(r#"{"kind":"result""#), "{lines:?}");
    }

    #[test]
    fn a_child_with_no_result_ends_with_its_code_and_its_stderr() {
        let outcome = turn_of("echo boom >&2; exit 3", 60_000.0);
        let Outcome::Exited(evidence, code, signal) = outcome else {
            panic!("{outcome:?}")
        };
        assert_eq!((code, signal), (Some(3), None));
        assert_eq!(
            String::from_utf16_lossy(&evidence.detail).trim_end(),
            "boom"
        );
    }

    #[test]
    fn a_limit_too_large_for_a_clock_is_no_limit() {
        for limit_ms in [1e300, f64::MAX] {
            let outcome = turn_of(RESULT, limit_ms);
            assert!(matches!(outcome, Outcome::Ok(_)), "{outcome:?}");
        }
    }

    #[test]
    fn the_limit_ends_the_turn() {
        let outcome = turn_of("exec sleep 30", 300.0);
        assert!(matches!(outcome, Outcome::Timeout(..)), "{outcome:?}");
    }

    /// The kill is SIGKILL to the child alone: what the child left behind, holding none of its pipes, lives on.
    #[test]
    fn the_kill_reaches_the_lone_pid() {
        let script = "sleep 30 > /dev/null 2>&1 < /dev/null &\necho $! > left-behind\necho ready\nexec sleep 30";
        let (mut world, scratch) = begin(script, |_: &str| {});
        while !matches!(world.next(None), Next::Msg(Msg::Out(_))) {}
        world.kill();
        while !matches!(world.next(None), Next::Msg(Msg::Exited)) {}
        assert_eq!(world.reap().signal, Some("SIGKILL"));
        let left_behind = pid_in(&scratch.path().join("left-behind"));
        assert!(test_kill_process(left_behind).is_ok());
        kill_process(left_behind, Signal::KILL).unwrap();
    }

    /// A reader keeps reading after the outcome, so what the child left behind can go on writing, and with `--events` a whole line of it is one more event. The call goes on until the pipes end.
    #[test]
    fn the_readers_go_on_after_the_outcome_until_both_pipes_end() {
        let script = format!(
            "{{ until [ -e go ]; do sleep 0.05; done; printf '{{\"type\":\"late\"}}\\n{{\"type\":\"cut\"}}'; }} &\n{RESULT}\nexit 0"
        );
        let lines = Rc::new(RefCell::new(Vec::new()));
        let heard = Rc::clone(&lines);
        let (mut world, scratch) = begin(&script, move |line: &str| {
            heard.borrow_mut().push(line.to_owned());
        });
        let mut turn = Turn::new(60_000.0, true, world.now(), world.wall_ms());
        let outcome = turn::run(&mut turn, &mut world);
        assert!(matches!(outcome, Outcome::Ok(_)), "{outcome:?}");
        assert_eq!(lines.borrow().len(), 1, "{lines:?}");
        fs::write(scratch.path().join("go"), "").unwrap();
        turn::linger(&mut turn, &mut world);
        let lines = lines.borrow();
        assert_eq!(lines.len(), 2, "{lines:?}");
        assert_eq!(lines[1], r#"{"kind":"other","type":"late"}"#);
    }

    #[test]
    fn threads_with_nothing_to_watch_end_with_the_watch() {
        drop(Watch::start().unwrap());
    }

    /// Whatever the readers had not taken at the exit still comes, through `queued`, up to the end of the pipe.
    #[test]
    fn the_drain_takes_all_that_the_readers_had_not_taken() {
        const SIZE: usize = 1024 * 1024;
        let (mut world, _scratch) = begin(&format!("head -c {SIZE} /dev/zero"), |_: &str| {});
        let (mut read, mut ended) = (0, false);
        let mut note = |msg: &Msg| match msg {
            Msg::Out(bytes) => read += bytes.len(),
            Msg::OutEnd => ended = true,
            _ => {}
        };
        loop {
            let Next::Msg(msg) = world.next(None) else {
                panic!("the channel closed before the exit")
            };
            note(&msg);
            if matches!(msg, Msg::Exited) {
                break;
            }
        }
        world.reap();
        while let Some(msg) = world.queued() {
            note(&msg);
        }
        assert!(ended);
        assert_eq!(read, SIZE);
    }

    /// An exit whose pipes stay open and empty: they are held by what outlives the child, and the drain has nothing to wait for.
    #[test]
    fn a_pipe_that_stays_empty_and_open_gives_nothing_more_at_the_end_of_the_drain() {
        let (mut world, scratch) = begin("sleep 30 &\necho $! > left-behind\nexit 0", |_: &str| {});
        while !matches!(world.next(None), Next::Msg(Msg::Exited)) {}
        world.reap();
        let asked = Instant::now();
        assert!(world.queued().is_none());
        assert!(asked.elapsed() < READER_WAIT, "{:?}", asked.elapsed());
        kill_process(pid_in(&scratch.path().join("left-behind")), Signal::KILL).unwrap();
    }
}
