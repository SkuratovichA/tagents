//! A follower that dies is followed again after a second, then two, up to five minutes, and what the engine arms and logs on the way. The follower learns of its death in a wake, as the real one does, so a test kills it and wakes the engine (`Rig::kill`), and sleeps to the re-follow with `Rig::sleep`, which is what the service's loop does with `next_due`.

use super::*;

const SECOND: Duration = Duration::from_secs(1);

fn secs(n: u64) -> Duration {
    Duration::from_secs(n)
}

#[test]
fn a_follower_that_dies_is_followed_again_after_a_second_and_its_events_are_heard() {
    let mut r = rig();
    r.start();
    r.kill("the watch failed");
    assert_eq!(r.feed.followers(), 1);
    assert_eq!(r.engine.next_due(), Some(SECOND));
    assert_eq!(
        r.logged(),
        ["feed follower died the watch failed following again in 1s"],
        "one line for the death"
    );
    r.advance(999.0);
    assert_eq!(r.feed.followers(), 1, "not yet");
    r.advance(1.0);
    assert_eq!(r.feed.followers(), 2);
    assert_eq!(
        r.engine.next_due(),
        None,
        "the re-follow wait exists only while the follower is dead"
    );
    r.feed.emit(r.now());
    r.wake();
    assert_eq!(r.notifier.kinds(), ["turn_done"]);
}

#[test]
fn a_refollow_that_fails_waits_twice_as_long_up_to_5_minutes_and_a_follower_that_lived_longer_than_that_wait_starts_over_at_a_second()
 {
    let mut r = rig();
    r.start();
    r.feed.fail_follows(12);
    r.kill("the watch failed");
    let waits: Vec<u64> = (0..12).map(|_| r.sleep().as_secs()).collect();
    assert_eq!(waits, [1, 2, 4, 8, 16, 32, 64, 128, 256, 300, 300, 300]);
    assert_eq!(r.feed.followers(), 1, "every try so far failed");
    assert_eq!(r.engine.next_due(), Some(secs(300)));
    r.sleep();
    assert_eq!(r.feed.followers(), 2, "the follow that worked");
    assert_eq!(r.engine.next_due(), None);
    r.clock.advance(300_001.0);
    r.kill("the watch failed again");
    assert_eq!(
        r.engine.next_due(),
        Some(SECOND),
        "it outlived the 300 s that preceded it"
    );
    let failed = r
        .logged()
        .iter()
        .filter(|line| line.starts_with("follow failed"))
        .count();
    assert_eq!(failed, 12, "a failed try is logged too");
}

#[test]
fn a_follower_that_dies_at_once_three_times_is_followed_after_1_2_and_4_seconds() {
    let mut r = rig();
    r.start();
    let mut waits = Vec::new();
    for _ in 0..3 {
        r.kill("the watch failed");
        waits.push(r.sleep());
    }
    assert_eq!(waits, [secs(1), secs(2), secs(4)]);
    assert_eq!(r.feed.followers(), 4);
    assert_eq!(
        r.logged(),
        [
            "feed follower died the watch failed following again in 1s",
            "feed follower died the watch failed following again in 2s",
            "feed follower died the watch failed following again in 4s",
        ]
    );
}

#[test]
fn a_follower_that_keeps_dying_at_once_is_followed_every_5_minutes_at_most() {
    let mut r = rig();
    r.start();
    for _ in 0..12 {
        r.kill("the watch failed");
        r.sleep();
    }
    r.kill("the watch failed");
    assert_eq!(r.engine.next_due(), Some(secs(300)));
}

#[test]
fn a_follower_that_heard_an_event_or_lived_longer_than_the_wait_before_it_starts_the_wait_over() {
    let mut heard = rig();
    heard.start();
    for _ in 0..3 {
        heard.kill("the watch failed");
        heard.sleep();
    }
    heard.feed.emit(heard.now().on(H::PreToolUse).tool("Bash"));
    heard.wake();
    heard.kill("the watch failed");
    assert_eq!(
        heard.engine.next_due(),
        Some(SECOND),
        "it delivered an event"
    );

    let mut lived = rig();
    lived.start();
    for _ in 0..3 {
        lived.kill("the watch failed");
        lived.sleep();
    }
    lived.clock.advance(4_000.0);
    lived.kill("the watch failed");
    assert_eq!(
        lived.engine.next_due(),
        Some(secs(8)),
        "not longer than the 4 s before it"
    );
    lived.sleep();
    lived.clock.advance(8_001.0);
    lived.kill("the watch failed");
    assert_eq!(
        lived.engine.next_due(),
        Some(SECOND),
        "longer than the 8 s before it"
    );
}

#[test]
fn after_a_refollow_the_state_rows_are_armed_again_what_the_events_said_while_it_was_dead_is_in_them()
 {
    let mut r = rig();
    r.start();
    r.kill("the watch failed");
    r.feed.set_rows(vec![
        row_of("12", RowState::Done, T0 - 5.0 * MIN),
        AgentStateRow {
            detail: "AskUserQuestion".to_owned(),
            session_id: "sess-13".to_owned(),
            ..row_of("13", RowState::Working, T0 - 2.0 * MIN)
        },
    ]);
    assert_eq!(r.armed(), 0, "nothing is armed while the follower is dead");
    r.advance(1000.0);
    assert_eq!(r.feed.followers(), 2);
    assert_eq!(r.armed(), 2);
    r.advance(49.0 * MIN);
    let seen: Vec<(String, &str)> = r
        .notifier
        .posts()
        .into_iter()
        .map(|p| (p.id, p.kind.as_str()))
        .collect();
    assert_eq!(
        seen,
        [
            ("tagents-12".to_owned(), "cache_expiring"),
            ("tagents-13".to_owned(), "cache_expiring")
        ]
    );
}

#[test]
fn a_refollow_that_fails_arms_nothing_and_the_one_that_works_afterwards_arms_once() {
    let mut r = rig();
    r.start();
    r.feed.fail_follows(1);
    r.kill("the watch failed");
    r.feed
        .set_rows(vec![row_of("12", RowState::Done, T0 - 5.0 * MIN)]);
    r.advance(1000.0);
    assert_eq!(r.armed(), 0);
    assert_eq!(
        r.engine.next_due(),
        Some(secs(2)),
        "only the next re-follow"
    );
    assert_eq!(
        r.logged().last().map(String::as_str),
        Some("follow failed the events file cannot be watched trying again in 2s")
    );
    r.advance(2000.0);
    assert_eq!(r.feed.followers(), 2);
    assert_eq!(r.armed(), 1);
    r.advance(46.0 * MIN);
    assert_eq!(r.notifier.kinds(), ["cache_expiring"]);
}

#[test]
fn a_refollow_whose_rows_cannot_be_read_says_so_and_goes_on_following() {
    let mut r = rig();
    r.start();
    r.kill("the watch failed");
    r.feed.state.borrow_mut().states_panic = Some("the state directory vanished");
    r.advance(1000.0);
    assert_eq!(
        r.logged().last().map(String::as_str),
        Some("arming from the state rows failed the state directory vanished")
    );
    assert_eq!(r.feed.followers(), 2);
    assert!(r.feed.open());
    r.feed.state.borrow_mut().states_panic = None;
    r.feed.emit(r.now());
    r.wake();
    assert_eq!(r.notifier.kinds(), ["turn_done"]);
}

#[test]
fn stop_cancels_a_refollow_that_is_waiting() {
    let mut r = rig();
    r.start();
    r.kill("the watch failed");
    assert_eq!(r.engine.next_due(), Some(SECOND));
    assert_eq!(r.engine.stop(), Ok(()));
    assert_eq!(r.engine.next_due(), None);
    r.advance(10.0 * MIN);
    assert_eq!(r.feed.followers(), 1);
}

#[test]
fn a_follower_that_dies_after_stop_is_not_followed_again() {
    let mut r = rig();
    r.start();
    assert_eq!(r.engine.stop(), Ok(()));
    r.feed.kill("the watch failed");
    r.wake();
    assert_eq!(r.engine.next_due(), None);
    assert!(r.logged().is_empty());
    assert_eq!(r.feed.followers(), 1);
}

#[test]
fn the_refollow_wait_is_beside_the_deadline_and_start_while_dead_does_not_follow_twice() {
    let mut r = rig_with(Setup {
        rows: vec![row_of("12", RowState::Done, T0 - 10.0 * MIN)],
        ..Setup::default()
    });
    r.start();
    assert_eq!(r.engine.next_due(), Some(secs(300)), "the deadline's wait");
    r.kill("the watch failed");
    assert_eq!(r.armed(), 1);
    assert_eq!(
        r.engine.next_due(),
        Some(SECOND),
        "the re-follow's, which is sooner"
    );
    r.start();
    assert_eq!(r.feed.followers(), 1);
    r.advance(1000.0);
    assert_eq!(r.feed.followers(), 2);
}

#[test]
fn start_while_following_follows_nothing_again() {
    let mut r = rig();
    r.start();
    r.start();
    assert_eq!(r.feed.followers(), 1);
}

// What a wake takes in

#[test]
fn the_errors_of_a_wake_are_lines_and_the_follower_goes_on() {
    let mut r = rig();
    r.start();
    r.feed.error("read events.tsv: input/output error");
    r.wake();
    assert_eq!(
        r.logged(),
        ["feed error read events.tsv: input/output error"]
    );
    assert_eq!(
        r.engine.next_due(),
        None,
        "still followed, nothing to follow again"
    );
    r.feed.emit(r.now());
    r.wake();
    assert_eq!(r.notifier.kinds(), ["turn_done"]);
}

#[test]
fn the_errors_and_the_death_of_a_wake_are_logged_before_any_of_its_jobs_run() {
    let mut r = rig();
    r.start();
    r.feed.emit(r.now());
    r.feed.error("rename events.tsv: permission denied");
    r.feed.kill("the watch failed");
    r.wake();
    assert_eq!(
        r.logged(),
        [
            "feed error rename events.tsv: permission denied",
            "feed follower died the watch failed following again in 1s",
            "notice turn_done 12 \"proj\" shown"
        ]
    );
}

#[test]
fn what_the_first_read_of_a_follow_found_appended_meanwhile_is_handled_by_start() {
    let mut r = rig();
    r.feed.state.borrow_mut().on_start = vec![r.now(), r.now().on(H::UserPromptSubmit)];
    r.start();
    assert_eq!(r.notifier.ops(), ["post", "withdraw"]);
}

#[test]
fn a_follower_that_died_in_its_first_read_is_followed_again_and_start_still_arms_the_rows() {
    let mut r = rig_with(Setup {
        rows: vec![row_of("12", RowState::Done, T0 - 10.0 * MIN)],
        ..Setup::default()
    });
    r.feed.state.borrow_mut().start_death = Some("the first read failed".to_owned());
    r.start();
    assert_eq!(
        r.logged(),
        ["feed follower died the first read failed following again in 1s"]
    );
    assert_eq!(r.engine.next_due(), Some(SECOND));
    assert_eq!(r.armed(), 1);
    r.start();
    assert_eq!(
        r.feed.followers(),
        1,
        "a start while the re-follow waits does nothing"
    );
    r.advance(1000.0);
    assert_eq!(r.feed.followers(), 2);
}

#[test]
fn every_wake_reaches_the_feed_so_the_grace_of_a_rotated_file_can_end() {
    let mut r = rig();
    r.start();
    r.wake();
    r.wake();
    assert_eq!(r.feed.state.borrow().wakes, 2);
}

#[test]
fn the_wait_ends_with_the_grace_of_a_rotated_file_when_that_comes_first() {
    let mut r = rig();
    r.start();
    r.feed.state.borrow_mut().grace = Some(T0 as i64 + 7_000);
    assert_eq!(r.engine.next_due(), Some(secs(7)));
    r.handle(r.now());
    assert_eq!(
        r.engine.next_due(),
        Some(secs(7)),
        "a deadline 50 minutes away is capped at 5 minutes and the grace is sooner"
    );
    r.clock.advance(8_000.0);
    assert_eq!(
        r.engine.next_due(),
        Some(Duration::ZERO),
        "the grace is over"
    );
    r.feed.state.borrow_mut().grace = None;
    assert_eq!(
        r.engine.next_due(),
        Some(secs(300)),
        "without the grace the deadline's wait is capped at 5 minutes"
    );
}
