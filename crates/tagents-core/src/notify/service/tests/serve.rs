//! The loop and the stop: which message runs what, and the order the service ends in.

use std::{cell::RefCell, thread};

use super::*;
use crate::{
    notify::{events::Delivery, state::AgentStateRow},
    testing::HEARD,
};

const TURN_DONE_OFF: &str = "[events.turn_done]\nenabled = false\n";
const WATCH_FAILED: &str = "stopping (watch failed: EMFILE: too many open files, watch)";

fn ended() -> Message {
    Message::from(Heard::Ended(io::Error::from_raw_os_error(24)))
}

/// Serves a service whose first turn ends at once and whose post is held: `act` runs on another thread once that post has begun, and every post ends after it. Returns the exit code and the kinds that were posted.
fn serve_with_a_post_in_flight(
    rig: &Rig,
    messages: Receiver<Message>,
    act: impl FnOnce() + Send,
) -> (ExitCode, Vec<String>) {
    let (begun, began) = mpsc::channel();
    let (let_go, release) = mpsc::channel();
    let shown = Shown::default();
    let daemon = rig.daemon(
        Gated {
            begun,
            release,
            shown: shown.clone(),
        },
        || {},
    );
    rig.append(&stop_line("12"));
    rig.sender.send(Message::Wake(Key::Events)).unwrap();
    let code = thread::scope(|scope| {
        let hook = scope.spawn(move || {
            began.recv_timeout(HEARD).expect("the post never began");
            act();
            for _ in 0..4 {
                let _ = let_go.send(());
            }
        });
        let code = serve(messages, daemon);
        hook.join().unwrap();
        code
    });
    (code, shown.kinds())
}

/// The feed of a service whose follower will not close: it closes, and says it did not.
struct Stubborn<'a>(FollowerFeed<'a, Recorder>);

impl Feed for Stubborn<'_> {
    fn dir(&self) -> &str {
        self.0.dir()
    }

    fn states(&self) -> Vec<AgentStateRow> {
        self.0.states()
    }

    fn start(&mut self, now_ms: i64) -> Result<Delivery, String> {
        self.0.start(now_ms)
    }

    fn wake(&mut self, now_ms: i64) -> Delivery {
        self.0.wake(now_ms)
    }

    fn due(&self) -> Option<i64> {
        self.0.due()
    }

    fn close(&mut self) -> Option<String> {
        self.0.close();
        Some("the watch would not close".to_owned())
    }
}

#[test]
fn a_stop_ends_with_the_stream_off_the_lock_released_and_exit_0() {
    let (rig, messages) = Rig::new();
    let daemon = rig.daemon(Shown::default(), || {});
    assert!(rig.events_on(), "the stream is on while the service runs");
    rig.sender.send(Message::Stop).unwrap();
    assert_eq!(serve(messages, daemon), ExitCode::SUCCESS);
    assert!(!rig.events_on(), "the stream is off after the stop");
    assert!(!rig.lock_held(), "the lock is released");
    assert_eq!(
        rig.log.lines(),
        Vec::<String>::new(),
        "the line of a signal is the signal thread's"
    );
}

#[test]
fn a_lock_that_is_not_ours_survives_the_stop() {
    let (rig, messages) = Rig::new();
    let daemon = rig.daemon(Shown::default(), || {});
    // Another service took the lock over while this one ran.
    fs::write(rig.lock.file(), "1\n").unwrap();
    rig.sender.send(Message::Stop).unwrap();
    assert_eq!(serve(messages, daemon), ExitCode::SUCCESS);
    assert_eq!(fs::read_to_string(rig.lock.file()).unwrap(), "1\n");
}

#[test]
fn a_line_in_the_events_file_is_a_notice_and_a_stop_removes_the_switch() {
    let (rig, messages) = Rig::new();
    let shown = Shown::default();
    let daemon = rig.daemon(shown.clone(), || {});
    rig.append(&stop_line("12"));
    rig.sender.send(Message::Wake(Key::Events)).unwrap();
    rig.sender.send(Message::Stop).unwrap();
    assert_eq!(serve(messages, daemon), ExitCode::SUCCESS);
    let lines = rig.log.lines();
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert!(
        lines[0].starts_with("notice turn_done 12 \""),
        "{}",
        lines[0]
    );
    assert!(lines[0].ends_with("\" shown"), "{}", lines[0]);
    assert_eq!(shown.kinds(), ["turn_done"]);
    assert!(!rig.events_on());
}

#[test]
fn a_wake_queued_behind_a_tripped_stop_is_dropped() {
    let (rig, messages) = Rig::new();
    let shown = Shown::default();
    let daemon = rig.daemon(shown.clone(), || {});
    rig.append(&stop_line("12"));
    rig.stop.stop();
    rig.sender.send(Message::Wake(Key::Events)).unwrap();
    assert_eq!(serve(messages, daemon), ExitCode::SUCCESS);
    assert_eq!(shown.kinds(), Vec::<String>::new());
    assert!(!rig.lock_held());
}

#[test]
fn an_options_wake_reloads_and_the_next_event_posts_nothing_for_a_kind_that_is_off() {
    let (rig, messages) = Rig::new();
    rig.write_options("");
    let (config, state, sender) = (rig.config(), rig.state(), rig.sender.clone());
    // The first turn is held in its post: while it is, the options change and a second turn ends.
    let (code, posted) = serve_with_a_post_in_flight(&rig, messages, move || {
        fs::write(config.join("plugins/notify.toml"), TURN_DONE_OFF).unwrap();
        sender.send(Message::Wake(Key::Options)).unwrap();
        append_line(&state, &stop_line("13"));
        sender.send(Message::Wake(Key::Events)).unwrap();
        sender.send(Message::Stop).unwrap();
    });
    assert_eq!(code, ExitCode::SUCCESS);
    let lines = rig.log.lines();
    assert_eq!(
        lines
            .iter()
            .filter(|line| *line == "options reloaded")
            .count(),
        1,
        "{lines:?}"
    );
    assert_eq!(
        posted,
        ["turn_done"],
        "the second turn posted nothing: the kind is off"
    );
}

#[test]
fn stopping_precedes_the_notice_of_a_post_in_flight() {
    let (rig, messages) = Rig::new();
    rig.gate.settled();
    let signalling = rig.signalling();
    let (code, posted) = serve_with_a_post_in_flight(&rig, messages, move || {
        signalling.signal("SIGTERM");
    });
    assert_eq!(code, ExitCode::SUCCESS);
    assert_eq!(posted, ["turn_done"], "the post in flight lands");
    let lines = rig.log.lines();
    assert_eq!(lines.len(), 2, "{lines:?}");
    assert_eq!(
        lines[0], "stopping (SIGTERM)",
        "the line is written while the post is out"
    );
    assert!(lines[1].starts_with("notice turn_done 12 "), "{}", lines[1]);
    assert!(!rig.events_on());
    assert!(!rig.lock_held());
}

#[test]
fn a_watch_that_ends_behind_a_post_in_flight_is_served_after_the_queued_wake_and_stops_with_its_reason()
 {
    let (rig, messages) = Rig::new();
    let (state, sender) = (rig.state(), rig.sender.clone());
    // A second turn ends and the watch dies, both while the first post is out.
    let (code, posted) = serve_with_a_post_in_flight(&rig, messages, move || {
        append_line(&state, &stop_line("13"));
        sender.send(Message::Wake(Key::Events)).unwrap();
        sender.send(ended()).unwrap();
    });
    assert_eq!(code, ExitCode::from(1));
    assert_eq!(posted, ["turn_done", "turn_done"]);
    let lines = rig.log.lines();
    assert_eq!(lines.len(), 3, "{lines:?}");
    assert!(lines[0].starts_with("notice turn_done 12 "), "{}", lines[0]);
    assert!(lines[1].starts_with("notice turn_done 13 "), "{}", lines[1]);
    assert_eq!(
        lines[2], WATCH_FAILED,
        "the queued wake is served first and the reason is the last line"
    );
    assert!(
        !rig.log.has("handing over"),
        "a failure after started is never handed over: the events queued in the engine would be lost"
    );
    assert!(!rig.events_on(), "the stream is off");
    assert!(!rig.lock_held(), "the lock is released");
    assert!(rig.stop.is_stopped());
}

#[test]
fn a_watch_that_ends_with_nothing_in_flight_stops_with_its_reason_and_exits_1() {
    let (rig, messages) = Rig::new();
    let daemon = rig.daemon(Shown::default(), || {});
    rig.sender.send(ended()).unwrap();
    assert_eq!(serve(messages, daemon), ExitCode::from(1));
    assert_eq!(rig.log.lines(), [WATCH_FAILED]);
    assert!(!rig.events_on());
    assert!(!rig.lock_held());
}

#[test]
fn a_watch_that_ended_after_a_signal_said_stopping_adds_no_second_line() {
    let (rig, _messages) = Rig::new();
    let daemon = rig.daemon(Shown::default(), || {});
    assert!(rig.said.first(), "the signal thread wrote its line");
    assert_eq!(
        end(
            daemon,
            Ending::WatchFailed(io::Error::from_raw_os_error(24))
        ),
        ExitCode::from(1)
    );
    assert_eq!(rig.log.lines(), Vec::<String>::new());
    assert!(rig.stop.is_stopped());
}

#[test]
fn the_watch_closes_first_and_the_lock_goes_last() {
    let (rig, messages) = Rig::new();
    let seen = RefCell::new(None);
    let daemon = rig.daemon(Shown::default(), || {
        *seen.borrow_mut() = Some((rig.events_on(), rig.lock_held()));
    });
    rig.sender.send(Message::Stop).unwrap();
    serve(messages, daemon);
    assert_eq!(
        *seen.borrow(),
        Some((true, true)),
        "when the watch closes the engine has not stopped and the lock is held"
    );
    assert!(!rig.events_on());
    assert!(!rig.lock_held());
}

#[test]
fn a_feed_that_will_not_close_is_a_line_and_the_lock_is_still_released() {
    let (rig, messages) = Rig::new();
    let feed = Box::new(Stubborn(FollowerFeed::new(&rig.arming, &rig.state())));
    let daemon = rig.daemon_over(feed, Shown::default(), || {});
    rig.sender.send(Message::Stop).unwrap();
    assert_eq!(serve(messages, daemon), ExitCode::SUCCESS);
    assert_eq!(rig.log.lines(), ["drain failed the watch would not close"]);
    assert!(!rig.lock_held());
}

#[test]
fn a_closed_watch_slot_arms_nothing_and_closes_twice_without_harm() {
    let (sender, _messages) = mpsc::channel::<Message>();
    let slot = WatchSlot(RefCell::new(Some(Watch::start::<Message>(sender).unwrap())));
    let scratch = Scratch::new();
    assert!(slot.dir(scratch.path(), Key::Options).is_ok());
    slot.close();
    slot.close();
    let err = slot.dir(scratch.path(), Key::Options).unwrap_err();
    assert_eq!(err.to_string(), "the watch is closed");
    assert!(slot.file(&scratch.path().join("x"), Key::Events).is_err());
}
