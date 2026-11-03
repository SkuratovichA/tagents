//! The machine of one turn of `session prompt`: the three phases and the timers of `ClaudeHeadlessDriver.prompt` (design D6). It reads no clock and starts nothing: the process, the pipes and the time come through `World`, so every timing rule here runs in virtual time in a test.

pub mod supervisor;

use std::os::unix::process::ExitStatusExt;
use std::process::ExitStatus;
use std::time::{Duration, Instant};

use crate::js;
use crate::json::Value;
use crate::session::command::signal_name;
use crate::session::outcome::{Done, Evidence, Outcome, clip_detail};
use crate::session::stream::Reader;

/// `RESULT_EXIT_GRACE_MS`: how long a child may stay after its result.
pub const RESULT_EXIT_GRACE: Duration = Duration::from_secs(60);
/// `PIPE_DRAIN_MS`: how long the pipes may stay open after the exit.
pub const PIPE_DRAIN: Duration = Duration::from_secs(5);
/// `DEFAULT_TIMEOUT_MS`: 50 minutes.
pub const DEFAULT_TIMEOUT_MS: f64 = 3_000_000.0;

/// What comes from the threads that watch the child.
#[derive(Debug)]
pub enum Msg {
    Out(Vec<u8>),
    Err(Vec<u8>),
    OutEnd,
    ErrEnd,
    Exited,
}

/// What waiting gave.
#[derive(Debug)]
pub enum Next {
    Msg(Msg),
    /// The time asked for came and nothing did.
    Timeout,
    /// Nothing can come any more.
    Closed,
}

/// How the child left, as node reports it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Exit {
    pub code: Option<i32>,
    pub signal: Option<&'static str>,
}

impl Exit {
    /// `exit` of a `ChildProcess`: a signal node has no name for reads as the exit code 0, because the empty name is falsy and the code of a process a signal ended is 0.
    pub fn of(status: ExitStatus) -> Exit {
        match (status.code(), status.signal()) {
            (Some(code), _) => Exit {
                code: Some(code),
                signal: None,
            },
            (None, Some(number)) => match signal_name(number) {
                Some(name) => Exit {
                    code: None,
                    signal: Some(name),
                },
                None => Exit {
                    code: Some(0),
                    signal: None,
                },
            },
            (None, None) => Exit::unknown(),
        }
    }

    /// A child that could not be waited for.
    pub fn unknown() -> Exit {
        Exit {
            code: None,
            signal: None,
        }
    }
}

/// The time, the child and the output of a turn.
pub trait World {
    fn now(&self) -> Instant;
    /// `Date.now()`.
    fn wall_ms(&self) -> f64;
    /// The next message, waiting until `until` or, without it, for as long as it takes.
    fn next(&mut self, until: Option<Instant>) -> Next;
    /// A message that is already on its way when the drain is over: what is queued, and what the pipes still report as readable. A bounded number of them: this ends for a pipe that never stops.
    fn queued(&mut self) -> Option<Msg>;
    /// Reaps the child, which has exited. No signal goes to its pid after this.
    fn reap(&mut self) -> Exit;
    /// SIGKILL to the child, and to no other process.
    fn kill(&mut self);
    /// An event line, with no newline, written at once.
    fn event(&mut self, line: &str);
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Phase {
    Running,
    Resulted,
    Exited(Exit),
}

/// A turn in progress.
#[derive(Debug)]
pub struct Turn {
    reader: Reader,
    /// The bytes of stderr, decoded as one text when the turn is over: a read can end inside a character.
    stderr: Vec<u8>,
    events: bool,
    limit_ms: f64,
    started_ms: f64,
    phase: Phase,
    timed_out: bool,
    deadline: Option<Instant>,
    grace: Option<Instant>,
    drain: Option<Instant>,
    drain_over: bool,
    out_open: bool,
    err_open: bool,
}

/// `now + limit`, or no deadline at all for a limit an `Instant` cannot hold: `--timeout 1e300` never fires in node either.
fn deadline_of(now: Instant, limit_ms: f64) -> Option<Instant> {
    let limit = Duration::try_from_secs_f64(limit_ms / 1000.0).ok()?;
    now.checked_add(limit)
}

impl Turn {
    /// A turn whose clock was read at `now` and `wall_ms`, just before the spawn, with the limit `--timeout` gave.
    pub fn new(limit_ms: f64, events: bool, now: Instant, wall_ms: f64) -> Turn {
        Turn {
            reader: if events {
                Reader::listening()
            } else {
                Reader::default()
            },
            stderr: Vec::new(),
            events,
            limit_ms,
            started_ms: wall_ms,
            phase: Phase::Running,
            timed_out: false,
            deadline: deadline_of(now, limit_ms),
            grace: None,
            drain: None,
            drain_over: false,
            out_open: true,
            err_open: true,
        }
    }

    fn next_timer(&self) -> Option<Instant> {
        [self.deadline, self.grace, self.drain]
            .into_iter()
            .flatten()
            .min()
    }

    /// `onResult`. It says nothing about which result: the phase only moves once, and the deadline only goes.
    fn after_a_result(&mut self, now: Instant) {
        match self.phase {
            Phase::Running => {
                self.phase = Phase::Resulted;
                self.deadline = None;
                self.grace = now.checked_add(RESULT_EXIT_GRACE);
            }
            Phase::Exited(_) => self.deadline = None,
            Phase::Resulted => {}
        }
    }

    fn take(&mut self, msg: Msg, world: &mut impl World) {
        match msg {
            Msg::Out(bytes) => {
                self.reader
                    .push(&bytes, &mut |line: &str| world.event(line));
                if self.reader.saw_result {
                    self.after_a_result(world.now());
                }
            }
            Msg::Err(bytes) => self.stderr.extend_from_slice(&bytes),
            Msg::OutEnd => self.out_open = false,
            Msg::ErrEnd => self.err_open = false,
            Msg::Exited => {
                let exit = world.reap();
                self.phase = Phase::Exited(exit);
                self.grace = None;
                self.drain = world.now().checked_add(PIPE_DRAIN);
            }
        }
    }

    /// What is due, in the order it was due. It runs on every pass of the loop, because a child that never stops writing leaves no quiet moment for a timer to run in.
    fn timers(&mut self, world: &mut impl World) {
        let now = world.now();
        while let Some(at) = self.next_timer().filter(|at| *at <= now) {
            if self.deadline == Some(at) {
                self.deadline = None;
                self.timed_out = true;
                // The deadline stays armed through the drain of a child with no result. Its pid is gone by then: node's `kill` finds no handle.
                if !matches!(self.phase, Phase::Exited(_)) {
                    world.kill();
                }
            } else if self.grace == Some(at) {
                self.grace = None;
                world.kill();
            } else {
                self.drain = None;
                self.drain_over = true;
            }
        }
    }

    /// `close`: the child has exited and both of its pipes have ended.
    fn closed(&self) -> bool {
        matches!(self.phase, Phase::Exited(_)) && !self.out_open && !self.err_open
    }

    /// `finish`, in its order of decisions.
    fn finish(&mut self, world: &mut impl World) -> Outcome {
        // The last line may have no newline, and it may be the result itself: the fields are read after it.
        self.reader.end(&mut |line: &str| world.event(line));
        if self.reader.saw_result {
            self.after_a_result(world.now());
        }
        let exit = match self.phase {
            Phase::Exited(exit) => exit,
            Phase::Running | Phase::Resulted => Exit::unknown(),
        };
        let duration_ms = world.wall_ms() - self.started_ms;
        let payload = self.reader.payload.as_ref();
        let session_id = payload
            .and_then(|p| p.get("session_id"))
            .or(self.reader.session_id.as_ref())
            .cloned();
        let number = |key: &str| match payload.and_then(|p| p.get(key)) {
            Some(Value::Number(number)) => Some(*number),
            _ => None,
        };
        let (cost_usd, num_turns) = (number("total_cost_usd"), number("num_turns"));
        let succeeded = matches!(
            payload.and_then(|p| p.get("is_error")),
            Some(Value::Bool(false))
        );
        if succeeded {
            let done = Done {
                text: std::mem::take(&mut self.reader.text),
                session_id,
                tool_uses: self.reader.tool_uses,
                cost_usd,
                num_turns,
                duration_ms,
            };
            return match exit.code {
                Some(0) => Outcome::Ok(done),
                code => Outcome::KilledAfterResult(done, code),
            };
        }
        // The payload's `result` when it has one, even empty.
        let detail = match payload.and_then(|p| p.get("result")).and_then(Value::units) {
            Some(result) => clip_detail(&result),
            None => clip_detail(&js::units(&String::from_utf8_lossy(&self.stderr))),
        };
        let evidence = Evidence {
            session_id,
            tool_uses: self.reader.tool_uses,
            detail,
            saw_text: !self.reader.text.is_empty(),
            saw_result: self.reader.saw_result,
        };
        if self.timed_out {
            Outcome::Timeout(evidence, self.limit_ms)
        } else {
            Outcome::Exited(evidence, exit.code, exit.signal)
        }
    }
}

/// The turn, from the spawn to its outcome.
pub fn run(turn: &mut Turn, world: &mut impl World) -> Outcome {
    loop {
        match world.next(turn.next_timer()) {
            Next::Msg(msg) => turn.take(msg, world),
            Next::Timeout => {}
            Next::Closed => break,
        }
        turn.timers(world);
        if turn.drain_over {
            while let Some(msg) = world.queued() {
                turn.take(msg, world);
            }
            break;
        }
        if turn.closed() {
            break;
        }
    }
    turn.finish(world)
}

/// After the outcome the process stays until both pipes of the child have ended, because node never lets go of them: exiting would change what a grandchild sees on its next write. Node's listeners stay too, so a line that arrives now still is an event. Its reader was flushed when the turn finished and never is again, so a line with no newline here is lost as it is in node.
pub fn linger(turn: &mut Turn, world: &mut impl World) {
    while turn.out_open || turn.err_open {
        match world.next(None) {
            Next::Msg(Msg::Out(bytes)) => {
                if turn.events {
                    turn.reader
                        .push(&bytes, &mut |line: &str| world.event(line));
                }
            }
            Next::Msg(Msg::OutEnd) => turn.out_open = false,
            Next::Msg(Msg::ErrEnd) => turn.err_open = false,
            Next::Msg(Msg::Err(_) | Msg::Exited) => {}
            Next::Timeout | Next::Closed => return,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;

    use super::*;

    const RESULT: &[u8] = b"{\"type\":\"result\",\"is_error\":false,\"result\":\"r\",\"session_id\":\"s\",\"total_cost_usd\":0.5,\"num_turns\":2}\n";
    const FAILED: &[u8] = b"{\"type\":\"result\",\"is_error\":true,\"result\":\"it failed\"}\n";

    /// A turn in virtual time: what arrives when, and how the child left.
    struct Script {
        start: Instant,
        now: Instant,
        arrivals: VecDeque<(Duration, Msg)>,
        /// What only `queued` hands out.
        late: VecDeque<Msg>,
        exit: Exit,
        reaped: bool,
        kills: Vec<Duration>,
        events: Vec<(Duration, String)>,
    }

    fn at(ms: u64) -> Duration {
        Duration::from_millis(ms)
    }

    fn code(code: i32) -> Exit {
        Exit {
            code: Some(code),
            signal: None,
        }
    }

    fn killed() -> Exit {
        Exit {
            code: None,
            signal: Some("SIGKILL"),
        }
    }

    impl Script {
        fn new(exit: Exit, arrivals: Vec<(Duration, Msg)>) -> Script {
            let start = Instant::now();
            Script {
                start,
                now: start,
                arrivals: arrivals.into(),
                late: VecDeque::new(),
                exit,
                reaped: false,
                kills: Vec::new(),
                events: Vec::new(),
            }
        }

        fn elapsed(&self) -> Duration {
            self.now - self.start
        }

        /// Runs the turn to its outcome, with `--events` when asked.
        fn run(&mut self, limit_ms: f64, events: bool) -> (Turn, Outcome) {
            let mut turn = Turn::new(limit_ms, events, self.start, 1000.0);
            let outcome = run(&mut turn, self);
            (turn, outcome)
        }
    }

    impl World for Script {
        fn now(&self) -> Instant {
            self.now
        }

        fn wall_ms(&self) -> f64 {
            1000.0 + self.elapsed().as_secs_f64() * 1000.0
        }

        fn next(&mut self, until: Option<Instant>) -> Next {
            let due = self.arrivals.front().map(|(when, _)| self.start + *when);
            match (due, until) {
                (Some(due), Some(until)) if due > until => {
                    self.now = self.now.max(until);
                    Next::Timeout
                }
                (Some(due), _) => {
                    self.now = self.now.max(due);
                    match self.arrivals.pop_front() {
                        Some((_, msg)) => Next::Msg(msg),
                        None => Next::Closed,
                    }
                }
                (None, Some(until)) => {
                    self.now = self.now.max(until);
                    Next::Timeout
                }
                (None, None) => Next::Closed,
            }
        }

        fn queued(&mut self) -> Option<Msg> {
            self.late.pop_front()
        }

        fn reap(&mut self) -> Exit {
            self.reaped = true;
            self.exit
        }

        fn kill(&mut self) {
            assert!(
                !self.reaped,
                "a signal to the pid of a child that was reaped"
            );
            self.kills.push(self.elapsed());
        }

        fn event(&mut self, line: &str) {
            let when = self.elapsed();
            self.events.push((when, line.to_owned()));
        }
    }

    fn out(bytes: &[u8]) -> Msg {
        Msg::Out(bytes.to_vec())
    }

    fn compact(outcome: &Outcome) -> String {
        outcome.document(true)
    }

    fn kind(outcome: &Outcome) -> &'static str {
        match outcome {
            Outcome::Ok(_) => "ok",
            Outcome::KilledAfterResult(..) => "killed-after-result",
            Outcome::Timeout(..) => "timeout",
            Outcome::Exited(..) => "exited",
            Outcome::SpawnFailed(_) => "spawn-failed",
        }
    }

    #[test]
    fn a_result_and_a_clean_exit_with_both_pipes_ended_is_ok_at_once() {
        let mut script = Script::new(
            code(0),
            vec![
                (at(10), out(RESULT)),
                (at(20), Msg::OutEnd),
                (at(20), Msg::ErrEnd),
                (at(30), Msg::Exited),
            ],
        );
        let (_, outcome) = script.run(1000.0, false);
        assert_eq!(
            compact(&outcome),
            "{\"kind\":\"ok\",\"text\":\"\",\"sessionId\":\"s\",\"toolUses\":0,\"costUsd\":0.5,\"numTurns\":2,\"durationMs\":30}\n"
        );
        assert_eq!(script.elapsed(), at(30));
        assert!(script.kills.is_empty());
    }

    #[test]
    fn the_deadline_kills_once_at_the_limit_and_the_turn_is_a_timeout() {
        let mut script = Script::new(
            killed(),
            vec![
                (at(5), out(b"{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"t\"},{\"type\":\"tool_use\",\"name\":\"A\"}]}}\n")),
                (at(100), Msg::Err(b"slow".to_vec())),
                (at(401), Msg::Exited),
                (at(402), Msg::OutEnd),
                (at(402), Msg::ErrEnd),
            ],
        );
        let (_, outcome) = script.run(400.0, false);
        assert_eq!(script.kills, [at(400)]);
        assert_eq!(
            compact(&outcome),
            "{\"kind\":\"timeout\",\"sessionId\":null,\"toolUses\":1,\"limitMs\":400,\"detail\":\"slow\",\"sawText\":true,\"sawResult\":false}\n"
        );
        assert_eq!(outcome.exit_code(), 4);
    }

    #[test]
    fn a_child_that_never_stops_writing_does_not_starve_the_deadline() {
        let mut arrivals: Vec<(Duration, Msg)> =
            (0..2000).map(|ms| (at(ms), out(b"noise\n"))).collect();
        arrivals.push((at(2000), Msg::Exited));
        arrivals.push((at(2000), Msg::OutEnd));
        arrivals.push((at(2000), Msg::ErrEnd));
        let mut script = Script::new(killed(), arrivals);
        let (_, outcome) = script.run(500.0, false);
        assert_eq!(script.kills, [at(500)]);
        assert_eq!(kind(&outcome), "timeout");
    }

    #[test]
    fn a_child_that_stays_60_seconds_after_its_result_is_killed_and_the_turn_succeeded() {
        let mut script = Script::new(
            killed(),
            vec![
                (at(10), out(RESULT)),
                (at(60_011), Msg::Exited),
                (at(60_011), Msg::OutEnd),
                (at(60_011), Msg::ErrEnd),
            ],
        );
        let (_, outcome) = script.run(1000.0, false);
        // The result took the deadline away: nothing fired at one second.
        assert_eq!(script.kills, [at(60_010)]);
        assert_eq!(kind(&outcome), "killed-after-result");
        assert!(
            compact(&outcome).ends_with("\"durationMs\":60011,\"code\":null}\n"),
            "{}",
            compact(&outcome)
        );
        assert_eq!(outcome.exit_code(), 0);
    }

    #[test]
    fn a_result_and_a_code_that_is_not_0_is_killed_after_result_with_the_code() {
        let mut script = Script::new(
            code(3),
            vec![
                (at(1), out(RESULT)),
                (at(2), Msg::Exited),
                (at(2), Msg::OutEnd),
                (at(2), Msg::ErrEnd),
            ],
        );
        let (_, outcome) = script.run(1000.0, false);
        assert_eq!(kind(&outcome), "killed-after-result");
        assert!(compact(&outcome).ends_with("\"code\":3}\n"));
    }

    #[test]
    fn a_result_that_arrives_after_the_deadline_killed_still_wins() {
        let mut script = Script::new(
            killed(),
            vec![
                (at(600), out(RESULT)),
                (at(601), Msg::Exited),
                (at(601), Msg::OutEnd),
                (at(601), Msg::ErrEnd),
            ],
        );
        let (_, outcome) = script.run(500.0, false);
        assert_eq!(script.kills, [at(500)]);
        assert_eq!(kind(&outcome), "killed-after-result");
    }

    #[test]
    fn a_payload_with_is_error_true_is_not_a_success_and_its_result_is_the_detail() {
        let mut script = Script::new(
            code(1),
            vec![
                (at(1), out(FAILED)),
                (at(1), Msg::Err(b"ignored".to_vec())),
                (at(2), Msg::Exited),
                (at(2), Msg::OutEnd),
                (at(2), Msg::ErrEnd),
            ],
        );
        let (_, outcome) = script.run(1000.0, false);
        assert_eq!(
            compact(&outcome),
            "{\"kind\":\"exited\",\"sessionId\":null,\"toolUses\":0,\"code\":1,\"signal\":null,\"detail\":\"it failed\",\"sawText\":false,\"sawResult\":true}\n"
        );
    }

    #[test]
    fn a_payload_without_is_error_is_not_a_success() {
        let mut script = Script::new(
            code(0),
            vec![
                (at(1), out(b"{\"type\":\"result\",\"result\":\"\"}\n")),
                (at(1), Msg::Err(b"unused".to_vec())),
                (at(2), Msg::Exited),
                (at(2), Msg::OutEnd),
                (at(2), Msg::ErrEnd),
            ],
        );
        let (_, outcome) = script.run(1000.0, false);
        // An empty `result` is still the detail.
        assert_eq!(
            compact(&outcome),
            "{\"kind\":\"exited\",\"sessionId\":null,\"toolUses\":0,\"code\":0,\"signal\":null,\"detail\":\"\",\"sawText\":false,\"sawResult\":true}\n"
        );
    }

    #[test]
    fn a_child_that_exits_with_no_result_reports_its_code_or_its_signal_and_its_stderr() {
        let run_one = |exit: Exit| {
            let mut script = Script::new(
                exit,
                vec![
                    (at(1), Msg::Err(b"bo".to_vec())),
                    (at(2), Msg::Err(b"om\n\n x".to_vec())),
                    (at(3), Msg::Exited),
                    (at(3), Msg::OutEnd),
                    (at(3), Msg::ErrEnd),
                ],
            );
            script.run(1000.0, false).1
        };
        let by_code = run_one(code(1));
        assert_eq!(by_code.error_line().as_deref(), Some("exit=1 boom x"));
        let by_signal = run_one(Exit {
            code: None,
            signal: Some("SIGTERM"),
        });
        assert!(compact(&by_signal).contains("\"code\":null,\"signal\":\"SIGTERM\""));
        assert_eq!(
            by_signal.error_line().as_deref(),
            Some("exit=SIGTERM boom x")
        );
    }

    #[test]
    fn a_character_split_between_two_reads_of_stderr_is_whole() {
        let bytes = "é".as_bytes();
        let mut script = Script::new(
            code(1),
            vec![
                (at(1), Msg::Err(bytes[..1].to_vec())),
                (at(2), Msg::Err(bytes[1..].to_vec())),
                (at(3), Msg::Exited),
                (at(3), Msg::OutEnd),
                (at(3), Msg::ErrEnd),
            ],
        );
        let (_, outcome) = script.run(1000.0, false);
        assert_eq!(outcome.error_line().as_deref(), Some("exit=1 é"));
    }

    #[test]
    fn the_status_of_a_process_reads_as_node_reads_it() {
        assert_eq!(Exit::of(ExitStatus::from_raw(3 << 8)), code(3));
        assert_eq!(
            Exit::of(ExitStatus::from_raw(rustix::process::Signal::KILL.as_raw())),
            killed()
        );
        // With the core-dump bit.
        assert_eq!(
            Exit::of(ExitStatus::from_raw(
                rustix::process::Signal::ABORT.as_raw() | 0x80
            )),
            Exit {
                code: None,
                signal: Some("SIGABRT")
            }
        );
        // A number with no name is the code 0 and no signal.
        assert_eq!(Exit::of(ExitStatus::from_raw(0x7e)), code(0));
    }

    #[test]
    fn the_drain_ends_the_turn_5_seconds_after_the_exit_when_a_pipe_stays_open() {
        let mut script = Script::new(
            code(0),
            vec![
                (at(10), out(RESULT)),
                (at(20), Msg::Exited),
                (at(20), Msg::ErrEnd),
            ],
        );
        let (turn, outcome) = script.run(100_000.0, false);
        assert_eq!(script.elapsed(), at(5020));
        assert_eq!(kind(&outcome), "ok");
        assert!(turn.out_open && !turn.err_open);
    }

    #[test]
    fn a_line_that_is_queued_when_the_drain_ends_is_read_before_the_decision() {
        let mut script = Script::new(code(0), vec![(at(20), Msg::Exited)]);
        script.late.push_back(out(RESULT));
        let (_, outcome) = script.run(100_000.0, false);
        assert_eq!(kind(&outcome), "ok");
        assert_eq!(script.elapsed(), at(5020));
    }

    #[test]
    fn a_line_with_no_newline_is_read_when_the_turn_finishes_and_may_be_the_result() {
        let line = RESULT.strip_suffix(b"\n").unwrap();
        let mut script = Script::new(
            code(0),
            vec![
                (at(1), out(line)),
                (at(2), Msg::OutEnd),
                (at(2), Msg::ErrEnd),
                (at(3), Msg::Exited),
            ],
        );
        let (_, outcome) = script.run(100_000.0, true);
        assert_eq!(kind(&outcome), "ok");
        assert_eq!(script.events.len(), 1);
    }

    #[test]
    fn pipes_that_end_before_the_exit_wait_for_the_exit_and_an_exit_with_no_pipes_needs_no_drain() {
        let mut script = Script::new(
            code(0),
            vec![
                (at(1), Msg::OutEnd),
                (at(2), Msg::ErrEnd),
                (at(500), Msg::Exited),
            ],
        );
        let (_, outcome) = script.run(100_000.0, false);
        assert_eq!(kind(&outcome), "exited");
        assert_eq!(script.elapsed(), at(500));
    }

    #[test]
    fn the_deadline_stays_armed_through_the_drain_and_sends_no_signal_after_the_reap() {
        // The child leaves with code 1 and a grandchild holds the pipe: node's tick still fires, its `kill` finds no handle, and the turn reads as a timeout.
        let mut script = Script::new(code(1), vec![(at(10), Msg::Exited)]);
        let (_, outcome) = script.run(300.0, false);
        assert!(script.kills.is_empty());
        assert_eq!(kind(&outcome), "timeout");
        assert_eq!(script.elapsed(), at(5010));
        // A limit past the drain never comes.
        let mut script = Script::new(code(1), vec![(at(10), Msg::Exited)]);
        let (_, outcome) = script.run(6000.0, false);
        assert_eq!(kind(&outcome), "exited");
    }

    #[test]
    fn a_result_during_the_drain_takes_the_deadline_away() {
        let mut script = Script::new(code(0), vec![(at(10), Msg::Exited), (at(20), out(RESULT))]);
        let (_, outcome) = script.run(300.0, false);
        assert_eq!(kind(&outcome), "ok");
    }

    #[test]
    fn a_fractional_and_an_exponent_limit_are_the_numbers_they_read_as() {
        let mut half = Script::new(
            killed(),
            vec![
                (at(5), Msg::Exited),
                (at(5), Msg::OutEnd),
                (at(5), Msg::ErrEnd),
            ],
        );
        let (_, outcome) = half.run(js::number("0.5"), false);
        assert_eq!(half.kills, [Duration::from_micros(500)]);
        assert!(compact(&outcome).contains("\"limitMs\":0.5,"));
        let mut thousand = Script::new(
            killed(),
            vec![
                (at(1001), Msg::Exited),
                (at(1001), Msg::OutEnd),
                (at(1001), Msg::ErrEnd),
            ],
        );
        let (_, outcome) = thousand.run(js::number("1e3"), false);
        assert_eq!(thousand.kills, [at(1000)]);
        assert!(compact(&outcome).contains("\"limitMs\":1000,"));
    }

    #[test]
    fn a_limit_an_instant_cannot_hold_is_no_deadline() {
        let now = Instant::now();
        assert!(deadline_of(now, 1e300).is_none());
        assert!(deadline_of(now, f64::MAX).is_none());
        assert!(deadline_of(now, 1000.0).is_some());
        let mut script = Script::new(
            code(0),
            vec![
                (at(10), Msg::Exited),
                (at(10), Msg::OutEnd),
                (at(10), Msg::ErrEnd),
            ],
        );
        let (_, outcome) = script.run(1e300, false);
        assert!(script.kills.is_empty());
        assert!(compact(&outcome).contains("\"code\":0"));
    }

    #[test]
    fn the_events_are_written_when_their_line_is_read() {
        let mut script = Script::new(
            code(0),
            vec![
                (at(1), out(b"{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"A\"}]}}\n")),
                (at(1000), out(RESULT)),
                (at(1001), Msg::Exited),
                (at(1001), Msg::OutEnd),
                (at(1001), Msg::ErrEnd),
            ],
        );
        script.run(100_000.0, true);
        let times: Vec<Duration> = script.events.iter().map(|(when, _)| *when).collect();
        assert_eq!(times, [at(1), at(1000)]);
    }

    #[test]
    fn after_the_outcome_the_call_stays_until_the_pipes_end_and_a_line_is_still_an_event() {
        let mut script = Script::new(
            code(0),
            vec![
                (at(1), out(RESULT)),
                (at(2), Msg::Exited),
                (at(2), Msg::ErrEnd),
                (at(6000), out(b"{\"type\":\"late\"}\n{\"type\":\"cut\"}")),
                (at(14_000), Msg::OutEnd),
            ],
        );
        let (mut turn, outcome) = script.run(100_000.0, true);
        assert_eq!(kind(&outcome), "ok");
        assert_eq!(script.elapsed(), at(5002));
        linger(&mut turn, &mut script);
        assert_eq!(script.elapsed(), at(14_000));
        let lines: Vec<&str> = script
            .events
            .iter()
            .map(|(_, line)| line.as_str())
            .collect();
        // The reader is flushed once: the line with no newline after the turn is never read.
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[1], "{\"kind\":\"other\",\"type\":\"late\"}");
    }

    #[test]
    fn with_nobody_listening_the_call_still_stays_and_writes_nothing() {
        let mut script = Script::new(
            code(0),
            vec![
                (at(2), Msg::Exited),
                (at(2), Msg::ErrEnd),
                (at(6000), out(b"{\"type\":\"late\"}\n")),
                (at(7000), Msg::OutEnd),
            ],
        );
        let (mut turn, _) = script.run(100_000.0, false);
        linger(&mut turn, &mut script);
        assert_eq!(script.elapsed(), at(7000));
        assert!(script.events.is_empty());
    }

    #[test]
    fn a_channel_that_closes_ends_the_turn_with_what_it_has() {
        let mut closed = Script::new(code(0), vec![]);
        let (_, outcome) = closed.run(1e300, false);
        assert_eq!(kind(&outcome), "exited");
        assert_eq!(outcome.error_line().as_deref(), Some("exit=null "));
    }
}
