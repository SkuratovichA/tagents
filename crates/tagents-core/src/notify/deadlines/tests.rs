//! Cases of `packages/notify/test/deadlines.test.ts` (14, in the node file's order). Node arms a timer on a fake clock and `advance` fires it; here the engine's loop is what the tests play: `wait` says how long it may block, the clock moves by that much (or jumps), and `take_due` says what came due.
//! - nothing is pending until something is armed, and again once it is cancelled: `nothing_waits_until_something_is_armed_and_again_once_it_is_cancelled`
//! - one timer serves every key, set for the earliest, and never longer than 5 minutes: `the_wait_is_for_the_earliest_key_and_never_longer_than_five_minutes`
//! - a key fires once, at its time, with the idle-since it was armed with: `a_key_comes_due_once_at_its_time_with_its_idle_since`
//! - several keys due together each fire once: `several_keys_due_together_each_come_due_once_in_the_order_armed`
//! - arming a key again replaces its deadline: `arming_a_key_again_replaces_its_deadline_and_keeps_its_place`
//! - a cancelled key never fires: `a_cancelled_key_never_comes_due`
//! - the wall clock jumping over the deadline fires it on the next wake: `the_wall_clock_jumping_over_the_deadline_makes_it_due_on_the_next_look`
//! - the sleep ends before the deadline, the next wake only shortens the wait: `a_jump_that_stops_short_of_the_deadline_only_shortens_the_wait`
//! - close stops everything: not applicable: the deadlines hold no timer, and the engine ends by dropping them and leaving its loop
//! - closing from inside a callback stops the keys still waiting in the same wake: not applicable: `take_due` has no callback, so there is nothing to close from inside
//! - cancelling a key from inside another key's callback keeps it from firing: not applicable: the due keys leave the list together and the engine's jobs (`onDue` only enqueues in node) run behind it; `a_job_that_cancels_a_due_key_finds_it_already_out` pins what stays
//! - sweep fires what the wall clock says is due, without waiting for the timer a sleep put off: `take_due_at_any_moment_returns_only_what_is_due_by_the_wall_clock`
//! - sweep with nothing due changes nothing, and after close it does nothing: `take_due_with_nothing_due_changes_nothing`
//! - one armed key wakes the process at most 12 times in any hour: `one_armed_key_wakes_at_most_twelve_times_in_any_hour`

use super::*;

const MIN: f64 = 60_000.0;
const T0: f64 = 1_700_000_000_000.0;

fn keys(due: &[Due]) -> Vec<&str> {
    due.iter().map(|d| d.key.as_str()).collect()
}

fn minutes(d: Option<Duration>) -> Option<f64> {
    d.map(|d| d.as_secs_f64() / 60.0)
}

#[test]
fn nothing_waits_until_something_is_armed_and_again_once_it_is_cancelled() {
    let mut d = Deadlines::new();
    assert_eq!(d.wait(T0), None);
    d.arm("12", T0, T0 + 50.0 * MIN);
    assert!(d.wait(T0).is_some());
    assert_eq!(d.armed(), 1);
    d.cancel("12");
    assert_eq!(d.wait(T0), None);
    assert_eq!(d.armed(), 0);
}

#[test]
fn the_wait_is_for_the_earliest_key_and_never_longer_than_five_minutes() {
    let mut d = Deadlines::new();
    d.arm("a", T0, T0 + 50.0 * MIN);
    d.arm("b", T0, T0 + 2.0 * MIN);
    d.arm("c", T0, T0 + 30.0 * MIN);
    assert_eq!(minutes(d.wait(T0)), Some(2.0));
    d.cancel("b");
    assert_eq!(minutes(d.wait(T0)), Some(5.0));
}

#[test]
fn a_key_comes_due_once_at_its_time_with_its_idle_since() {
    let mut d = Deadlines::new();
    d.arm("12", T0 - MIN, T0 + 12.0 * MIN);
    assert!(d.take_due(T0 + 11.0 * MIN).is_empty());
    let due = d.take_due(T0 + 12.0 * MIN);
    assert_eq!(
        due,
        [Due {
            key: "12".into(),
            idle_since: T0 - MIN
        }]
    );
    assert!(d.take_due(T0 + 72.0 * MIN).is_empty());
    assert_eq!((d.armed(), d.wait(T0 + 72.0 * MIN)), (0, None));
}

#[test]
fn several_keys_due_together_each_come_due_once_in_the_order_armed() {
    let mut d = Deadlines::new();
    d.arm("b", T0, T0 + 6.0 * MIN);
    d.arm("a", T0, T0 + 6.0 * MIN);
    assert_eq!(keys(&d.take_due(T0 + 7.0 * MIN)), ["b", "a"]);
    assert_eq!(d.armed(), 0);
}

#[test]
fn arming_a_key_again_replaces_its_deadline_and_keeps_its_place() {
    let mut d = Deadlines::new();
    d.arm("12", T0, T0 + 10.0 * MIN);
    d.arm("13", T0, T0 + 20.0 * MIN);
    d.arm("12", T0 + 5.0 * MIN, T0 + 20.0 * MIN);
    assert_eq!(d.armed(), 2);
    assert!(d.take_due(T0 + 15.0 * MIN).is_empty());
    let due = d.take_due(T0 + 21.0 * MIN);
    assert_eq!(
        keys(&due),
        ["12", "13"],
        "a Map keeps the first place of a key set again"
    );
    assert_eq!(due[0].idle_since, T0 + 5.0 * MIN);
}

#[test]
fn a_cancelled_key_never_comes_due() {
    let mut d = Deadlines::new();
    d.arm("12", T0, T0 + 10.0 * MIN);
    d.cancel("12");
    assert!(d.take_due(T0 + 60.0 * MIN).is_empty());
}

#[test]
fn the_wall_clock_jumping_over_the_deadline_makes_it_due_on_the_next_look() {
    let mut d = Deadlines::new();
    d.arm("12", T0, T0 + 50.0 * MIN);
    assert!(d.take_due(T0 + 4.0 * MIN).is_empty());
    assert_eq!(minutes(d.wait(T0 + 4.0 * MIN)), Some(5.0));
    let after_sleep = T0 + 4.0 * MIN + 49.0 * MIN;
    assert_eq!(
        minutes(d.wait(after_sleep)),
        Some(0.0),
        "overdue: no wait at all"
    );
    assert_eq!(keys(&d.take_due(after_sleep)), ["12"]);
}

#[test]
fn a_jump_that_stops_short_of_the_deadline_only_shortens_the_wait() {
    let mut d = Deadlines::new();
    d.arm("12", T0, T0 + 50.0 * MIN);
    let woke = T0 + 46.0 * MIN;
    assert!(d.take_due(woke).is_empty());
    assert_eq!(minutes(d.wait(woke)), Some(4.0));
    assert_eq!(d.take_due(woke + 4.0 * MIN).len(), 1);
}

#[test]
fn a_job_that_cancels_a_due_key_finds_it_already_out() {
    let mut d = Deadlines::new();
    d.arm("a", T0, T0 + 6.0 * MIN);
    d.arm("b", T0, T0 + 6.0 * MIN);
    let due = d.take_due(T0 + 7.0 * MIN);
    assert_eq!(due.len(), 2);
    d.cancel("b");
    d.arm("a", T0, T0 + 60.0 * MIN);
    assert_eq!(keys(&d.take_due(T0 + 8.0 * MIN)), Vec::<&str>::new());
    assert_eq!(d.armed(), 1, "only what was armed again waits");
}

#[test]
fn take_due_at_any_moment_returns_only_what_is_due_by_the_wall_clock() {
    let mut d = Deadlines::new();
    d.arm("12", T0, T0 + 50.0 * MIN);
    d.arm("13", T0, T0 + 58.0 * MIN);
    let after_sleep = T0 + 55.0 * MIN;
    assert_eq!(
        d.take_due(after_sleep),
        [Due {
            key: "12".into(),
            idle_since: T0
        }]
    );
    assert_eq!(d.armed(), 1);
    assert_eq!(minutes(d.wait(after_sleep)), Some(3.0));
}

#[test]
fn take_due_with_nothing_due_changes_nothing() {
    let mut d = Deadlines::new();
    assert!(d.take_due(T0).is_empty());
    assert_eq!(d.wait(T0), None);
    d.arm("12", T0, T0 + 50.0 * MIN);
    assert!(d.take_due(T0).is_empty());
    assert_eq!(d.armed(), 1);
    assert_eq!(minutes(d.wait(T0)), Some(5.0));
}

#[test]
fn one_armed_key_wakes_at_most_twelve_times_in_any_hour() {
    let clock = crate::notify::clock::FakeClock::new(T0);
    let mut d = Deadlines::new();
    use crate::notify::clock::Clock;
    let mut wakes: Vec<f64> = Vec::new();
    let mut lives = 0;
    d.arm("12", clock.now_ms(), clock.now_ms() + 50.0 * MIN);
    while let Some(wait) = d.wait(clock.now_ms()) {
        if wakes.len() >= 500 {
            break;
        }
        clock.advance(wait.as_secs_f64() * 1000.0);
        wakes.push(clock.now_ms());
        if !d.take_due(clock.now_ms()).is_empty() {
            lives += 1;
            if lives < 8 {
                d.arm("12", clock.now_ms(), clock.now_ms() + 50.0 * MIN);
            }
        }
    }
    assert_eq!(lives, 8);
    let worst = (0..wakes.len())
        .map(|i| {
            wakes
                .iter()
                .skip(i)
                .filter(|t| **t < wakes[i] + 60.0 * MIN)
                .count()
        })
        .max()
        .unwrap();
    assert!(worst <= 12, "{worst} wakes in one hour");
}

#[test]
fn a_nan_deadline_waits_not_at_all_and_never_panics() {
    let mut d = Deadlines::new();
    d.arm("12", T0, f64::NAN);
    assert_eq!(d.wait(T0), Some(Duration::ZERO));
    assert!(
        d.take_due(T0).is_empty(),
        "a NaN time is never due, as `NaN <= now` is false in JavaScript"
    );
}
