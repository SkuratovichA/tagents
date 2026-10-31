//! How the engine ends: the service's stop tripped during a post or a probe, `stop` itself, and a start that cannot follow. A job in flight lands and the jobs behind it are dropped. Nothing a hook does inside an engine call asserts: a panic there would be caught as a failed job, so the hooks record and the test reads the record after the call.

use super::*;

#[test]
fn a_stop_tripped_in_the_middle_of_a_post_lets_that_post_land_and_drops_the_events_behind_it() {
    let mut r = rig();
    r.start();
    let stop = r.stop.clone();
    r.notifier.during_post(move || stop.stop());
    r.feed.emit(r.now());
    r.feed.emit(r.permission());
    r.wake();
    assert_eq!(
        r.notifier.kinds(),
        ["turn_done"],
        "the one in flight landed; the one queued behind it did not"
    );
    assert_eq!(r.engine.stop(), Ok(()));
    r.handle(r.now().in_pane("13"));
    assert_eq!(r.notifier.posts().len(), 1, "nothing posts after stop");
}

#[test]
fn a_stop_tripped_in_the_middle_of_a_probe_lets_that_notice_post_and_nothing_after() {
    let mut r = rig();
    r.start();
    let stop = r.stop.clone();
    r.screen.during_probe(move || stop.stop());
    r.feed.emit(r.now());
    r.feed.emit(r.permission());
    r.wake();
    assert_eq!(
        r.screen.probed(),
        ["%12"],
        "the second event was never probed"
    );
    assert_eq!(r.notifier.kinds(), ["turn_done"]);
}

#[test]
fn a_stop_tripped_before_the_wake_runs_no_job_at_all() {
    let mut r = rig();
    r.start();
    r.stop.stop();
    r.feed.emit(r.now());
    r.wake();
    assert!(r.notifier.posts().is_empty());
    assert!(r.screen.probed().is_empty());
}

#[test]
fn a_stop_tripped_during_a_post_drops_the_due_deadline_queued_behind_it() {
    let mut r = rig();
    r.start();
    r.handle(r.now());
    r.feed.set_rows(vec![row()]);
    r.clock.advance(50.0 * MIN);
    let stop = r.stop.clone();
    r.notifier.during_post(move || stop.stop());
    r.feed.emit(r.now().in_pane("13"));
    r.wake();
    assert_eq!(
        r.notifier.kinds(),
        ["turn_done", "turn_done"],
        "the line landed, and the cache notice of key 12 behind it did not"
    );
}

#[test]
fn a_stop_tripped_during_the_post_of_a_deadline_lets_it_land() {
    let mut r = rig();
    r.handle(r.now());
    r.feed.set_rows(vec![row()]);
    let stop = r.stop.clone();
    r.notifier.during_post(move || stop.stop());
    r.advance(50.0 * MIN);
    assert_eq!(r.notifier.kinds(), ["turn_done", "cache_expiring"]);
}

#[test]
fn stop_with_nothing_in_flight_returns_at_once_and_stopping_twice_is_one_stop() {
    let mut r = rig();
    assert_eq!(r.engine.stop(), Ok(()));
    assert_eq!(r.engine.stop(), Ok(()));
    assert_eq!(r.feed.state.borrow().closes, 1);
}

#[test]
fn a_second_stop_returns_what_the_first_returned_and_closes_nothing_again() {
    let mut r = rig();
    r.start();
    r.feed.state.borrow_mut().close_error =
        Some("the events switch cannot be turned off".to_owned());
    let first = r.engine.stop();
    assert_eq!(
        first,
        Err("the events switch cannot be turned off".to_owned())
    );
    assert_eq!(r.engine.stop(), first);
    assert_eq!(r.feed.state.borrow().closes, 1);
}

#[test]
fn a_wake_after_stop_touches_nothing() {
    let mut r = rig();
    r.start();
    assert_eq!(r.engine.stop(), Ok(()));
    let wakes = r.feed.state.borrow().wakes;
    r.feed.emit(r.now());
    r.wake();
    assert_eq!(r.feed.state.borrow().wakes, wakes, "the feed is not asked");
    assert!(r.notifier.posts().is_empty());
}

#[test]
fn a_start_after_stop_follows_nothing() {
    let mut r = rig();
    assert_eq!(r.engine.stop(), Ok(()));
    assert_eq!(r.engine.start(), Ok(()));
    assert_eq!(r.feed.followers(), 0);
}

#[test]
fn start_that_cannot_follow_is_an_err_with_the_reason_and_leaves_no_deadline_armed() {
    let mut r = rig_with(Setup {
        rows: vec![row_of("12", RowState::Done, T0 - 10.0 * MIN)],
        ..Setup::default()
    });
    r.feed.fail_follows(1);
    assert_eq!(
        r.engine.start(),
        Err("the events file cannot be watched".to_owned())
    );
    assert_eq!(r.armed(), 0);
    assert_eq!(r.engine.next_due(), None);
    assert!(r.logged().is_empty());
}

#[test]
fn start_after_a_start_that_failed_follows_and_arms_again() {
    let mut r = rig_with(Setup {
        rows: vec![row_of("12", RowState::Done, T0 - 10.0 * MIN)],
        ..Setup::default()
    });
    r.feed.fail_follows(1);
    assert!(r.engine.start().is_err());
    r.start();
    assert_eq!(r.feed.followers(), 1);
    assert_eq!(r.armed(), 1);
}

#[test]
fn start_that_cannot_read_the_state_rows_is_an_err_with_the_reason_and_the_follower_stays_to_be_closed()
 {
    let mut r = rig();
    r.feed.state.borrow_mut().states_panic = Some("the state directory vanished");
    assert_eq!(
        r.engine.start(),
        Err("the state directory vanished".to_owned())
    );
    assert!(
        r.feed.open(),
        "the service stops the engine, and that closes it"
    );
    assert_eq!(r.engine.stop(), Ok(()));
    assert!(!r.feed.open());
}

#[test]
fn stop_closes_the_deadlines_even_when_the_follower_will_not_close() {
    let mut r = rig_with(Setup {
        rows: vec![row_of("12", RowState::Done, T0 - 10.0 * MIN)],
        ..Setup::default()
    });
    r.feed.state.borrow_mut().close_error =
        Some("the events switch cannot be turned off".to_owned());
    r.start();
    assert_eq!(r.armed(), 1);
    assert_eq!(
        r.engine.stop(),
        Err("the events switch cannot be turned off".to_owned())
    );
    assert_eq!(r.armed(), 0);
    r.advance(120.0 * MIN);
    assert!(r.notifier.posts().is_empty());
}
