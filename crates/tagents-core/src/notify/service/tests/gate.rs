//! The start gate, one test per interleaving of a signal and the end of start, and what the signal thread does with it.

use super::*;

#[test]
fn a_signal_before_settled_is_only_remembered_and_settled_returns_its_name() {
    let gate = StartGate::default();
    assert!(
        !gate.signalled("SIGTERM"),
        "start has not settled: the caller does not write"
    );
    assert_eq!(gate.settled(), Some("SIGTERM"));
}

#[test]
fn a_signal_after_settled_is_written_by_the_signal_thread() {
    let gate = StartGate::default();
    assert_eq!(gate.settled(), None);
    assert!(
        gate.signalled("SIGTERM"),
        "start has settled: the caller writes"
    );
}

#[test]
fn two_signals_before_settled_count_only_the_first() {
    let gate = StartGate::default();
    assert!(!gate.signalled("SIGINT"));
    assert!(!gate.signalled("SIGTERM"));
    assert_eq!(gate.settled(), Some("SIGINT"));
}

#[test]
fn no_signal_settles_with_none_and_a_second_settle_has_nothing_to_say() {
    let gate = StartGate::default();
    assert_eq!(gate.settled(), None);
    assert_eq!(gate.settled(), None);
}

/// A log that writes down, with each line, whether the stop was tripped already.
struct Probe {
    stop: Stop,
    seen: Mutex<Vec<(String, bool)>>,
}

impl Log for Probe {
    fn line(&self, parts: &[&str]) {
        locked(&self.seen).push((parts.join(" "), self.stop.is_stopped()));
    }
}

#[test]
fn stopping_is_written_before_the_stop_is_tripped_so_it_precedes_the_notice_of_a_post_in_flight() {
    let stop = Stop::default();
    let probe = Arc::new(Probe {
        stop: stop.clone(),
        seen: Mutex::new(Vec::new()),
    });
    let (sender, _messages) = mpsc::channel();
    let signalling = Signalling {
        gate: Arc::new(StartGate::default()),
        said: Said::default(),
        stop: stop.clone(),
        messages: sender,
        log: probe.clone(),
    };
    signalling.gate.settled();
    signalling.signal("SIGTERM");
    assert_eq!(
        *locked(&probe.seen),
        [("stopping (SIGTERM)".to_owned(), false)],
        "the line is written while the stop is not tripped yet"
    );
    assert!(stop.is_stopped());
}

#[test]
fn each_signal_is_named_in_its_line_and_sends_the_stop() {
    for name in ["SIGTERM", "SIGINT", "SIGHUP"] {
        let (rig, messages) = Rig::new();
        rig.gate.settled();
        rig.signalling().signal(name);
        assert_eq!(rig.log.lines(), [format!("stopping ({name})")]);
        assert!(rig.stop.is_stopped());
        assert!(matches!(messages.try_recv(), Ok(Message::Stop)));
    }
}

#[test]
fn a_signal_during_start_writes_nothing_trips_the_stop_and_leaves_its_name_for_the_main_thread() {
    let (rig, messages) = Rig::new();
    rig.signalling().signal("SIGINT");
    assert_eq!(rig.log.lines(), Vec::<String>::new());
    assert!(
        rig.stop.is_stopped(),
        "a start that fails after it sees the stop and does not hand over"
    );
    assert!(matches!(messages.try_recv(), Ok(Message::Stop)));
    assert_eq!(rig.gate.settled(), Some("SIGINT"));
}

#[test]
fn the_stopping_line_is_written_once_by_the_signal_or_by_the_watch_that_ended() {
    let (rig, _messages) = Rig::new();
    rig.gate.settled();
    let signalling = rig.signalling();
    signalling.signal("SIGTERM");
    signalling.signal("SIGINT");
    assert_eq!(
        rig.log.lines(),
        ["stopping (SIGTERM)"],
        "a second signal is no second line"
    );

    let (rig, _messages) = Rig::new();
    rig.gate.settled();
    assert!(
        rig.said.first(),
        "the main thread wrote the line of a watch that ended"
    );
    rig.signalling().signal("SIGTERM");
    assert_eq!(
        rig.log.lines(),
        Vec::<String>::new(),
        "and a signal after it adds none"
    );
    assert!(rig.stop.is_stopped());
}

#[test]
fn a_signal_during_start_and_a_second_one_after_it_give_one_stopping_line() {
    let (rig, _messages) = Rig::new();
    let signalling = rig.signalling();
    signalling.signal("SIGTERM");
    signalling.settle();
    assert_eq!(rig.log.lines(), ["stopping (SIGTERM)"]);
    signalling.signal("SIGINT");
    assert_eq!(
        rig.log.lines(),
        ["stopping (SIGTERM)"],
        "the second signal adds no second line"
    );
}

#[test]
fn a_signal_whose_loop_is_gone_still_trips_the_stop() {
    let (rig, messages) = Rig::new();
    drop(messages);
    rig.gate.settled();
    rig.signalling().signal("SIGTERM");
    assert!(rig.stop.is_stopped());
    assert_eq!(rig.log.lines(), ["stopping (SIGTERM)"]);
}

#[test]
fn a_wake_is_a_wake_and_an_ended_watch_is_an_ended_message() {
    assert!(matches!(
        Message::from(Heard::Fired(Key::Events)),
        Message::Wake(Key::Events)
    ));
    assert!(matches!(
        Message::from(Heard::Fired(Key::Options)),
        Message::Wake(Key::Options)
    ));
    let ended = Message::from(Heard::Ended(io::Error::from_raw_os_error(24)));
    assert!(matches!(ended, Message::Ended(err) if err.raw_os_error() == Some(24)));
}
