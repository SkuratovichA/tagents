//! A program run as a child, and what it did told back. The child leads a process group of its own and gets the bytes it is given on stdin, or none. It has a deadline, a cap on what is kept of each output stream and a drain for the pipes once it has exited. `mcp` runs a tool call with it; nothing here knows `mcp`, so whatever else runs a program with a deadline uses it as it is.
//!
//! Nothing a call starts outlives the call. A call ends when the program exits, when its timeout comes or when a stop arrives, and whichever it is the whole group is stopped: a timeout or a stop sends SIGTERM and then SIGKILL once the grace is over (or SIGKILL at once, when there is no grace), and whatever is left in the group after the program itself exited is killed at once.
//!
//! One thread runs the call and waits on a channel with a deadline. More feed the channel: one per output pipe, which reads, keeps the first `cap` bytes and discards the rest so the program never blocks on a full pipe, and one that waits for the program to exit without reaping it (the zombie keeps the group's id from being reused while the call signals the group). The stop of the request arrives on the same channel. A thread of its own writes the input, so that a program that does not read it holds up nothing but that thread.

use std::io::{self, ErrorKind, Read, Write};
use std::os::fd::{AsFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rustix::event::{PollFd, PollFlags, Timespec, poll};
use rustix::io::Errno;
use rustix::process::{Pid, Signal, WaitId, WaitIdOptions, kill_process_group, waitid};

use crate::ending::Stop;
use crate::sync::locked;

/// How often a call whose drain is over looks again at the pipes that have bytes or an end to read. The Rust server's own: the node server reads in its event loop's poll phase and has no such wait.
const DRAIN_STEP: Duration = Duration::from_millis(10);
/// How long a call with no grace waits, past the drain, for a pipe that still has bytes or an end to read.
const READER_WAIT: Duration = Duration::from_millis(2000);

/// What a call is allowed.
pub struct Policy {
    /// Written to the child's stdin, which is closed after it. `None`: stdin is `/dev/null`.
    pub input: Option<Vec<u8>>,
    /// How long the program has before it is stopped.
    pub timeout: Duration,
    /// `Some`: SIGTERM at the timeout or at a stop, and SIGKILL once the grace is over. `None`: SIGKILL at once.
    pub kill_grace: Option<Duration>,
    /// How long the call waits for the output pipes after the program exited: a process that left the group can hold them open for good. A pipe that still holds bytes, or has lost its last writer, is not held by such a process but waits for its reader thread, and is waited for on past this, up to the grace (`READER_WAIT` with no grace). A call that was stopped is given up on at the drain.
    pub drain: Duration,
    /// More than this many bytes of one stream is cut, at a character.
    pub cap: usize,
}

/// What a call saw of the program. A stream that was cut ends in a marker that says so.
#[derive(Debug)]
pub struct Finished {
    /// The exit code of the program, or none when a signal ended it or the call gave up on it.
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub stdout_cut: bool,
    pub stderr_cut: bool,
    /// Why the call stopped the program, if it did.
    pub reason: Option<Reason>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Reason {
    Timeout,
    Cancelled,
}

/// The first bytes of a stream up to the cap.
struct Capture {
    bytes: Vec<u8>,
    cut: bool,
    cap: usize,
}

impl Capture {
    fn new(cap: usize) -> Capture {
        Capture {
            bytes: Vec::new(),
            cut: false,
            cap,
        }
    }

    /// A stream is cut when it is longer than the cap, not when it reaches it.
    fn push(&mut self, chunk: &[u8]) {
        let room = self.cap - self.bytes.len();
        if chunk.len() <= room {
            self.bytes.extend_from_slice(chunk);
            return;
        }
        self.bytes.extend_from_slice(&chunk[..room]);
        self.cut = true;
    }

    /// The text read so far; once cut, it ends before the character the cap fell in, and a marker says so.
    fn text(&self) -> String {
        if !self.cut {
            return String::from_utf8_lossy(&self.bytes).into_owned();
        }
        let whole = &self.bytes[..complete_end(&self.bytes)];
        format!(
            "{}\n[output cut at {} bytes]",
            String::from_utf8_lossy(whole),
            self.cap
        )
    }
}

/// The end of the last whole UTF-8 character of `bytes`: a sequence the cap cut in the middle is left out whole. It looks at the last four bytes only, as `completeEnd` of `run.ts` does, so a stream that is not UTF-8 is cut where node cuts it.
fn complete_end(bytes: &[u8]) -> usize {
    let Some(mut lead) = bytes.len().checked_sub(1) else {
        return 0;
    };
    while lead > 0 && bytes.len() - lead < 4 && bytes[lead] & 0xc0 == 0x80 {
        lead -= 1;
    }
    let length = match bytes[lead] {
        0xf0.. => 4,
        0xe0.. => 3,
        0xc0.. => 2,
        _ => 1,
    };
    if lead + length > bytes.len() {
        lead
    } else {
        bytes.len()
    }
}

/// One of the two output pipes of the program.
#[derive(Clone, Copy, PartialEq)]
enum Stream {
    Out,
    Err,
}

impl Stream {
    /// The name of the stream's reader thread.
    fn name(self) -> &'static str {
        match self {
            Stream::Out => "out",
            Stream::Err => "err",
        }
    }
}

enum Event {
    /// The program exited; its code, or none when a signal ended it.
    Exited(Option<i32>),
    /// One output pipe is closed, by the program and by everything that held it.
    Eof(Stream),
    Stop,
}

/// What the supervisor saw of the program.
struct Ended {
    reason: Option<Reason>,
    code: Option<i32>,
}

fn signal_group(group: Pid, signal: Signal) {
    // The group is gone already, or never was: either way there is nothing left to signal.
    let _ = kill_process_group(group, signal);
}

fn group_of(child: &Child) -> Option<Pid> {
    Pid::from_raw(i32::try_from(child.id()).ok()?)
}

fn spawn_thread(name: &str, work: impl FnOnce() + Send + 'static) -> Result<(), String> {
    std::thread::Builder::new()
        .name(name.into())
        .spawn(work)
        .map(drop)
        .map_err(|e| format!("could not start a thread for the call: {e}"))
}

/// Reads a pipe to its end. The first `cap` bytes are kept; once the call is over the thread lets go of the pipe at the next byte it reads, so a process that outlived the call gets EPIPE as it would from a pipe that was destroyed.
fn read_stream(mut pipe: impl Read, capture: &Mutex<Capture>, over: &AtomicBool) {
    let mut chunk = vec![0u8; 32 * 1024];
    loop {
        match pipe.read(&mut chunk) {
            Ok(0) => return,
            Ok(n) => {
                if over.load(Ordering::Acquire) {
                    return;
                }
                locked(capture).push(&chunk[..n]);
            }
            Err(e) if e.kind() == ErrorKind::Interrupted => {}
            Err(_) => return,
        }
    }
}

/// Gives the program its input and closes its stdin. A program that exits without reading it all makes the write fail with EPIPE, and its exit says the rest; one that never reads it keeps this thread in the write until the call stops it.
fn write_input(mut pipe: ChildStdin, input: &[u8]) {
    let _ = pipe.write_all(input);
}

/// Waits for the program to exit without reaping it.
fn wait_for_exit(group: Pid) -> Option<i32> {
    loop {
        match waitid(
            WaitId::Pid(group),
            WaitIdOptions::EXITED | WaitIdOptions::NOWAIT,
        ) {
            Ok(status) => return status.and_then(|status| status.exit_status()),
            Err(Errno::INTR) => {}
            Err(_) => return None,
        }
    }
}

/// A second descriptor of the read end of `pipe`, to ask whether it is readable without reading it. It is the same pipe, so it keeps the pipe open: it must be dropped once the call is over, or a process that outlived the call would never get EPIPE.
fn duplicate(pipe: &impl AsFd) -> Result<OwnedFd, String> {
    pipe.as_fd()
        .try_clone_to_owned()
        .map_err(|e| format!("could not duplicate an output pipe of the call: {e}"))
}

struct Launched {
    events: Receiver<Event>,
    /// The pipes whose reader has not sent its `Eof` yet, each by its duplicate.
    open: Vec<(Stream, OwnedFd)>,
    stdout: Arc<Mutex<Capture>>,
    stderr: Arc<Mutex<Capture>>,
    /// Set when the call is over; the readers let go of their pipes.
    over: Arc<AtomicBool>,
}

/// Starts the threads that watch the program. When one cannot be started the program is stopped and reaped by the caller.
fn launch(child: &mut Child, group: Pid, policy: &Policy, stop: &Stop) -> Result<Launched, String> {
    let (sender, events) = mpsc::channel();
    let stdout_pipe = child
        .stdout
        .take()
        .ok_or("the program was started without an output pipe")?;
    let stderr_pipe = child
        .stderr
        .take()
        .ok_or("the program was started without an error pipe")?;
    let (stdout, stderr, over) = (
        Arc::new(Mutex::new(Capture::new(policy.cap))),
        Arc::new(Mutex::new(Capture::new(policy.cap))),
        Arc::<AtomicBool>::default(),
    );
    let streams = [
        (
            Stream::Out,
            duplicate(&stdout_pipe)?,
            Box::new(stdout_pipe) as Box<dyn Read + Send>,
            &stdout,
        ),
        (
            Stream::Err,
            duplicate(&stderr_pipe)?,
            Box::new(stderr_pipe) as Box<dyn Read + Send>,
            &stderr,
        ),
    ];
    let mut open = Vec::new();
    for (stream, duplicate, pipe, capture) in streams {
        open.push((stream, duplicate));
        let (capture, over, events) = (Arc::clone(capture), Arc::clone(&over), sender.clone());
        spawn_thread(&format!("tagents-{}", stream.name()), move || {
            read_stream(pipe, &capture, &over);
            let _ = events.send(Event::Eof(stream));
        })?;
    }
    if let Some(input) = &policy.input {
        let pipe = child
            .stdin
            .take()
            .ok_or("the program was started without an input pipe")?;
        let input = input.clone();
        spawn_thread("tagents-in", move || write_input(pipe, &input))?;
    }
    let exits = sender.clone();
    spawn_thread("tagents-wait", move || {
        let _ = exits.send(Event::Exited(wait_for_exit(group)));
    })?;
    // A stop that has come already is delivered at once.
    stop.watch(move || {
        let _ = sender.send(Event::Stop);
    });
    Ok(Launched {
        events,
        open,
        stdout,
        stderr,
        over,
    })
}

/// Whether a pipe of `open` holds bytes or has lost its last writer, so that its reader has something to take that it has not taken yet. A pipe that is empty and still open is held by a process the call cannot stop, or its reader has taken everything. An error of the poll counts as not readable: the call gives up at the drain.
fn readable(open: &[(Stream, OwnedFd)]) -> bool {
    let mut fds: Vec<PollFd<'_>> = open
        .iter()
        .map(|(_, fd)| PollFd::new(fd, PollFlags::IN))
        .collect();
    poll(&mut fds, Some(&Timespec::default())).is_ok()
        && fds
            .iter()
            .any(|fd| fd.revents().intersects(PollFlags::IN | PollFlags::HUP))
}

/// Follows the program to its end and, whatever ends it, stops everything it started in its group. A timeout, or a stop of the request, sends SIGTERM to the group and SIGKILL when the grace is over, or SIGKILL at once when there is no grace; the exit of the program kills the group at once and gives the pipes the drain to run dry. When the drain is over a pipe that is still `readable` is waited for in steps, up to the drain and the grace after the exit: its reader thread has not run yet, which a process holding an empty pipe never causes. `open` is the pipes whose reader has not finished, each by a duplicate, and it is dropped when the call is.
fn supervise(
    events: &Receiver<Event>,
    group: Pid,
    child: &mut Child,
    policy: &Policy,
    mut open: Vec<(Stream, OwnedFd)>,
) -> Ended {
    let mut reason = None;
    // The code of the program, and when the call saw it exit.
    let mut exited: Option<(Option<i32>, Instant)> = None;
    // The next thing that happens if nothing else does: the timeout, then the end of the grace, then (after the exit) the end of the drain.
    let mut deadline = Some(Instant::now() + policy.timeout);
    loop {
        let event = match deadline {
            Some(at) => events.recv_timeout(at.saturating_duration_since(Instant::now())),
            None => events.recv().map_err(|_| RecvTimeoutError::Disconnected),
        };
        match event {
            Ok(Event::Stop) => {
                if exited.is_none() && reason.is_none() {
                    reason = Some(Reason::Cancelled);
                    deadline = stopping(group, policy.kill_grace);
                }
            }
            Ok(Event::Eof(stream)) => {
                open.retain(|(ended, _)| *ended != stream);
                if open.is_empty() && exited.is_some() {
                    break;
                }
            }
            Ok(Event::Exited(code)) => {
                let at = Instant::now();
                exited = Some((code, at));
                // What the program left running in its group dies with it. The pipes are given a moment to drain, and no longer: a process outside the group can hold them open for good.
                signal_group(group, Signal::KILL);
                // The zombie has done its work: it held the group's id while the group was signalled.
                let _ = child.wait();
                if open.is_empty() {
                    break;
                }
                deadline = Some(at + policy.drain);
            }
            Err(RecvTimeoutError::Timeout) => match (exited, reason) {
                (Some((_, at)), _) => {
                    // The drain, or a step after it, is over. A pipe with bytes or an end to read has a reader the machine has not run yet, and no holder: wait for it, up to the grace. A call that was stopped is given up on at the drain: its answer is `cancelled` or its output is partial already, and the ending of `mcp` waits only its grace plus a margin for the calls, which a second grace could overrun.
                    let bound = at + policy.drain + policy.kill_grace.unwrap_or(READER_WAIT);
                    let now = Instant::now();
                    if reason.is_some() || now >= bound || !readable(&open) {
                        break;
                    }
                    deadline = Some((now + DRAIN_STEP).min(bound));
                }
                (None, None) => {
                    reason = Some(Reason::Timeout);
                    deadline = stopping(group, policy.kill_grace);
                }
                (None, Some(_)) => {
                    signal_group(group, Signal::KILL);
                    deadline = None;
                }
            },
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
    Ended {
        reason,
        code: exited.and_then(|(code, _)| code),
    }
}

/// Starts stopping the group, and says when to look again. With a grace it is SIGTERM now and the end of the grace. With none it is SIGKILL now, and nothing to wait for but the exit it causes.
fn stopping(group: Pid, kill_grace: Option<Duration>) -> Option<Instant> {
    match kill_grace {
        Some(grace) => {
            signal_group(group, Signal::TERM);
            Some(Instant::now() + grace)
        }
        None => {
            signal_group(group, Signal::KILL);
            None
        }
    }
}

/// Runs `command` as the leader of a process group of its own, with its stdin, stdout and stderr set here, and tells what it did. `Err` is a program that could not be started: the operating system's error, or one of this module's about the pipes and threads it needs. `stop` says that the request was cancelled or the process is closing.
pub fn run(mut command: Command, policy: &Policy, stop: &Stop) -> io::Result<Finished> {
    command
        .stdin(if policy.input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);
    let program = command.get_program().to_string_lossy().into_owned();
    let mut child = command.spawn()?;
    let Some(group) = group_of(&child) else {
        let _ = child.kill();
        let _ = child.wait();
        return Err(io::Error::other(format!(
            "{program} was started with a process id that is not one"
        )));
    };
    let launched = match launch(&mut child, group, policy, stop) {
        Ok(launched) => launched,
        Err(message) => {
            signal_group(group, Signal::KILL);
            let _ = child.wait();
            return Err(io::Error::other(message));
        }
    };
    let ended = supervise(&launched.events, group, &mut child, policy, launched.open);
    launched.over.store(true, Ordering::Release);

    let stdout = locked(&launched.stdout);
    let stderr = locked(&launched.stderr);
    Ok(Finished {
        code: ended.code,
        stdout: stdout.text(),
        stderr: stderr.text(),
        stdout_cut: stdout.cut,
        stderr_cut: stderr.cut,
        reason: ended.reason,
    })
}

#[cfg(test)]
mod tests {
    use std::thread;

    use super::*;
    use crate::testing::gate::forking;

    /// The cap of `mcp`: the arithmetic of the tests below is its.
    const CAP: usize = 256 * 1024;

    fn capture(chunks: &[&[u8]]) -> Capture {
        let mut capture = Capture::new(CAP);
        for chunk in chunks {
            capture.push(chunk);
        }
        capture
    }

    fn marker() -> String {
        format!("\n[output cut at {CAP} bytes]")
    }

    #[test]
    fn a_stream_that_reaches_the_cap_is_not_cut_and_one_byte_more_is() {
        let exact = capture(&[&vec![b'a'; CAP]]);
        assert!(!exact.cut);
        assert_eq!(exact.text().len(), CAP);
        let over = capture(&[&vec![b'a'; CAP], b"a"]);
        assert!(over.cut);
        assert_eq!(over.text(), format!("{}{}", "a".repeat(CAP), marker()));
    }

    #[test]
    fn the_cap_counts_bytes_across_chunks_and_not_the_size_of_one() {
        let chunk = "€".repeat(300).into_bytes();
        let mut capture = Capture::new(CAP);
        for _ in 0..400 {
            capture.push(&chunk);
        }
        assert!(capture.cut);
        // 262144 = 3 * 87381 + 1: the euro the cap fell in is dropped whole.
        let text = capture.text();
        let kept = text.strip_suffix(&marker()).unwrap_or("");
        assert_eq!(kept.len(), 3 * 87381);
        assert!(!kept.contains('\u{fffd}'));
    }

    #[test]
    fn a_character_the_cap_cuts_is_dropped_whole_and_one_that_ends_at_the_cap_stays() {
        let mut straddling = vec![b'a'; CAP - 1];
        straddling.extend_from_slice("é".as_bytes());
        straddling.extend_from_slice(&[b'b'; 1000]);
        let text = capture(&[&straddling]).text();
        assert_eq!(text, format!("{}{}", "a".repeat(CAP - 1), marker()));

        let mut ending = vec![b'a'; CAP - 2];
        ending.extend_from_slice("é".as_bytes());
        ending.extend_from_slice(&[b'b'; 1000]);
        let text = capture(&[&ending]).text();
        assert_eq!(text, format!("{}é{}", "a".repeat(CAP - 2), marker()));
    }

    #[test]
    fn complete_end_looks_back_at_most_four_bytes_and_by_the_lead_byte() {
        assert_eq!(complete_end(b""), 0);
        assert_eq!(complete_end(b"abc"), 3);
        // A lead byte of a two-byte character with its continuation missing.
        assert_eq!(complete_end(b"ab\xc3"), 2);
        assert_eq!(complete_end(b"ab\xc3\xa9"), 4);
        // A three-byte character cut after two bytes, and after one.
        assert_eq!(complete_end(b"a\xe2\x82"), 1);
        assert_eq!(complete_end(b"a\xe2"), 1);
        // A four-byte character cut after three bytes.
        assert_eq!(complete_end(b"a\xf0\x9f\x98"), 1);
        // Continuation bytes with no lead in reach: kept, as node keeps them.
        assert_eq!(complete_end(b"\x80\x80\x80\x80\x80"), 5);
        assert_eq!(complete_end(b"\x80"), 1);
    }

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    /// A call of `sh -c script` with nothing to stop it but its policy. The scripts use `/bin/sh` and programs that are in `/bin`, and write no file, so a test needs no rig of its own.
    fn sh(script: &str, policy: &Policy, stop: &Stop) -> Finished {
        let _forking = forking();
        let mut command = Command::new("/bin/sh");
        command.arg("-c").arg(script);
        run(command, policy, stop).unwrap()
    }

    fn policy(input: Option<Vec<u8>>, timeout: Duration, kill_grace: Option<Duration>) -> Policy {
        Policy {
            input,
            timeout,
            kill_grace,
            drain: ms(250),
            cap: CAP,
        }
    }

    /// The call in a thread of its own, so that a call that never ends fails the test and does not hang it.
    fn within(limit: Duration, call: impl FnOnce() -> Finished + Send + 'static) -> Finished {
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            let _ = sender.send(call());
        });
        receiver
            .recv_timeout(limit)
            .expect("the call did not end in time")
    }

    #[test]
    fn the_input_is_written_to_stdin_and_stdin_is_closed_after_it() {
        // `cat` ends only at the end of its stdin, so a stdin left open is a timeout.
        let finished = sh(
            "cat",
            &policy(Some(b"hello\nthere".to_vec()), ms(5000), Some(ms(2000))),
            &Stop::default(),
        );
        assert_eq!(finished.reason, None);
        assert_eq!(finished.code, Some(0));
        assert_eq!(finished.stdout, "hello\nthere");
    }

    #[test]
    fn input_larger_than_a_pipe_is_read_whole_by_a_program_that_reads_it() {
        // Four times what a pipe holds, so the write goes on while the program reads and writes back.
        let input: Vec<u8> = (0..1024 * 1024).map(|n| b'a' + (n % 26) as u8).collect();
        let mut everything = policy(Some(input.clone()), ms(10_000), Some(ms(2000)));
        everything.cap = 2 * input.len();
        let finished = sh("cat", &everything, &Stop::default());
        assert_eq!(finished.reason, None);
        assert_eq!(finished.code, Some(0));
        assert!(!finished.stdout_cut);
        assert_eq!(finished.stdout.as_bytes(), input);
    }

    #[test]
    fn without_input_stdin_is_empty_and_not_the_parents() {
        let finished = sh(
            "cat",
            &policy(None, ms(5000), Some(ms(2000))),
            &Stop::default(),
        );
        assert_eq!(finished.reason, None);
        assert_eq!(finished.stdout, "");
    }

    #[test]
    fn a_program_that_never_reads_its_stdin_is_stopped_at_the_deadline() {
        // More than a pipe holds, so the write cannot finish: it must not hold the call up.
        let started = Instant::now();
        let finished = within(ms(10_000), || {
            sh(
                "sleep 30",
                &policy(Some(vec![b'x'; 1024 * 1024]), ms(300), Some(ms(2000))),
                &Stop::default(),
            )
        });
        assert_eq!(finished.reason, Some(Reason::Timeout));
        assert_eq!(finished.code, None);
        assert!(started.elapsed() < ms(8000), "{:?}", started.elapsed());
    }

    #[test]
    fn a_program_that_exits_before_the_write_ends_is_told_by_its_exit() {
        let finished = within(ms(10_000), || {
            sh(
                "exit 7",
                &policy(Some(vec![b'x'; 1024 * 1024]), ms(5000), Some(ms(2000))),
                &Stop::default(),
            )
        });
        assert_eq!(finished.reason, None);
        assert_eq!(finished.code, Some(7));
    }

    #[test]
    fn a_program_that_reads_part_of_its_input_and_leaves_is_told_by_its_exit() {
        let finished = within(ms(10_000), || {
            sh(
                "head -c 10 >/dev/null; echo done; exit 3",
                &policy(Some(vec![b'x'; 1024 * 1024]), ms(5000), Some(ms(2000))),
                &Stop::default(),
            )
        });
        assert_eq!(finished.reason, None);
        assert_eq!(finished.code, Some(3));
        assert_eq!(finished.stdout, "done\n");
    }

    /// A program that ignores SIGTERM and says it has set that up: only SIGKILL stops it.
    const DEAF: &str = "trap '' TERM; echo ready; sleep 30";

    #[test]
    fn with_no_grace_the_deadline_is_a_sigkill_and_not_a_sigterm() {
        // The timeout is how long `sh` has to print `ready`; a program that ignores SIGTERM and is not killed at it would hold the call for its 30 s.
        let started = Instant::now();
        let finished = within(ms(15_000), || {
            sh(DEAF, &policy(None, ms(5000), None), &Stop::default())
        });
        assert_eq!(finished.reason, Some(Reason::Timeout));
        assert_eq!(finished.code, None);
        assert_eq!(finished.stdout, "ready\n");
        assert!(started.elapsed() < ms(9000), "{:?}", started.elapsed());
    }

    #[test]
    fn with_no_grace_a_stop_is_a_sigkill_and_not_a_sigterm() {
        let stop = Stop::default();
        let tripper = stop.clone();
        thread::spawn(move || {
            thread::sleep(ms(1500));
            tripper.stop();
        });
        let finished = within(ms(8000), move || {
            sh(DEAF, &policy(None, ms(20_000), None), &stop)
        });
        assert_eq!(finished.reason, Some(Reason::Cancelled));
        assert_eq!(finished.code, None);
    }

    #[test]
    fn with_a_grace_the_group_is_given_the_grace_to_leave_on_sigterm() {
        // The same program with a grace of 1.2 s lives past the timeout by about that grace: it is not killed at the deadline.
        let started = Instant::now();
        let finished = within(ms(10_000), || {
            sh(
                DEAF,
                &policy(None, ms(1500), Some(ms(1200))),
                &Stop::default(),
            )
        });
        assert_eq!(finished.reason, Some(Reason::Timeout));
        assert!(started.elapsed() >= ms(2700), "{:?}", started.elapsed());
    }

    #[test]
    fn with_no_grace_a_program_that_exits_with_its_output_still_in_the_pipe_loses_none_of_it() {
        // No grace and no drain: the only wait for the readers is `READER_WAIT`. The output is under the cap and over the pipe's buffer, so the program waited for the readers while it wrote. Calls side by side, so that the readers of one compete with the threads of the others, as the same test of `mcp` does: with `READER_WAIT` at zero, thirty-two lanes of twenty-five calls lost output in 20 runs of 20, and sixteen lanes of ten in 2 of 3.
        let everything = Policy {
            drain: ms(0),
            ..policy(None, ms(10_000), None)
        };
        thread::scope(|scope| {
            for lane in 1..=32 {
                let everything = &everything;
                scope.spawn(move || {
                    for call in 1..=25 {
                        let finished = sh(
                            "head -c 200000 /dev/zero | tr '\\0' x",
                            everything,
                            &Stop::default(),
                        );
                        assert_eq!(finished.reason, None, "lane {lane} call {call}");
                        assert_eq!(finished.code, Some(0), "lane {lane} call {call}");
                        assert_eq!(
                            finished.stdout.len(),
                            200_000,
                            "lane {lane} call {call} lost output"
                        );
                    }
                });
            }
        });
    }

    #[test]
    fn the_cap_is_the_one_of_the_policy() {
        let mut small = policy(None, ms(5000), Some(ms(2000)));
        small.cap = 100;
        let finished = sh(
            "head -c 300 /dev/zero | tr '\\0' a",
            &small,
            &Stop::default(),
        );
        assert!(finished.stdout_cut);
        assert!(!finished.stderr_cut);
        assert_eq!(
            finished.stdout,
            format!("{}\n[output cut at 100 bytes]", "a".repeat(100))
        );
    }

    #[test]
    fn a_program_that_is_not_there_is_an_error_of_the_spawn() {
        let _forking = forking();
        let error = run(
            Command::new("/nonexistent/tagents-child-test"),
            &policy(None, ms(5000), None),
            &Stop::default(),
        )
        .unwrap_err();
        assert_eq!(error.kind(), ErrorKind::NotFound);
    }
}
