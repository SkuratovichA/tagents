//! The order of a wake: the follower's lines are jobs at the back of one FIFO queue, the deadlines swept behind them, and each job runs to its end before the next starts. What a failed job and a failing backend leave in the log.

use super::*;

#[test]
fn a_deadline_that_fell_due_while_the_mac_slept_posts_on_the_next_wake_behind_the_lines_of_that_wake()
 {
    let mut r = rig_with(Setup {
        screens: vec![("%12", hidden())],
        ..Setup::default()
    });
    r.start();
    r.handle(r.now());
    r.feed.set_rows(vec![row()]);
    r.clock.advance(55.0 * MIN);
    assert_eq!(
        r.notifier.kinds(),
        ["turn_done"],
        "a sleeping Mac runs nothing"
    );
    r.feed.emit(r.now().in_pane("13").session("sess-13"));
    r.wake();
    let seen: Vec<(String, &str)> = r
        .notifier
        .posts()
        .into_iter()
        .map(|p| (p.id, p.kind.as_str()))
        .collect();
    assert_eq!(
        seen,
        [
            ("tagents-12".to_owned(), "turn_done"),
            ("tagents-13".to_owned(), "turn_done"),
            ("tagents-12".to_owned(), "cache_expiring")
        ]
    );
    assert!(r.notifier.posts()[2].body.contains("Idle 55 min"));
    assert_eq!(r.armed(), 1, "the other chat's deadline");
}

#[test]
fn an_event_of_the_sleeping_chat_itself_a_prompt_cancels_the_deadline_before_the_sweep_can_warn() {
    let mut r = rig();
    r.start();
    r.handle(r.now());
    r.feed.set_rows(vec![row()]);
    r.clock.advance(55.0 * MIN);
    r.feed.emit(r.now().on(H::UserPromptSubmit));
    r.wake();
    assert_eq!(r.notifier.kinds(), ["turn_done"]);
    assert_eq!(r.notifier.withdrawn(), ["tagents-12"]);
}

#[test]
fn a_wake_runs_all_its_lines_before_the_deadlines_that_fell_due() {
    // Node sweeps after each line and Rust once after all of a wake's lines: with two lines and a due key node runs the first line, the due key and the second line, and Rust the two lines and the due key.
    let mut r = rig();
    r.start();
    r.handle(r.now());
    r.feed.set_rows(vec![row()]);
    r.clock.advance(50.0 * MIN);
    r.feed.emit(r.now().in_pane("13"));
    r.feed.emit(r.now().in_pane("14"));
    r.wake();
    let seen: Vec<(String, &str)> = r
        .notifier
        .posts()
        .into_iter()
        .map(|p| (p.id, p.kind.as_str()))
        .collect();
    assert_eq!(
        seen,
        [
            ("tagents-12".to_owned(), "turn_done"),
            ("tagents-13".to_owned(), "turn_done"),
            ("tagents-14".to_owned(), "turn_done"),
            ("tagents-12".to_owned(), "cache_expiring")
        ]
    );
}

#[test]
fn a_deadline_that_passes_during_a_post_loses_to_the_prompt_that_is_in_the_file_when_it_ends() {
    // Node posts the cache notice here: its timer enqueued the due job while the post was in flight, ahead of the line the prompt's read adds afterwards. The engine is blocked in the post and cannot order the two after the fact: the next wake ingests the prompt and sweeps the deadline behind it, so the prompt cancels the key first.
    let mut r = rig();
    r.start();
    r.feed.set_rows(vec![row()]);
    let (clock, feed) = (r.clock.clone(), r.feed.clone());
    let prompt = r.now().on(H::UserPromptSubmit).at(T0 + 50.0 * MIN);
    r.notifier.during_post(move || {
        clock.advance(50.0 * MIN);
        feed.emit(prompt);
    });
    r.feed.emit(r.now());
    r.wake();
    assert_eq!(r.notifier.kinds(), ["turn_done"]);
    assert_eq!(
        r.armed(),
        1,
        "the deadline passed during the post, and is swept by the next wake"
    );
    r.wake();
    assert_eq!(
        r.notifier.kinds(),
        ["turn_done"],
        "the cache notice is not posted"
    );
    assert_eq!(r.notifier.withdrawn(), ["tagents-12"]);
    assert_eq!(r.armed(), 0);
}

#[test]
fn a_wake_with_nothing_to_do_does_nothing() {
    let mut r = rig();
    r.start();
    r.wake();
    r.wake();
    assert!(r.notifier.calls().is_empty());
    assert!(r.logged().is_empty());
}

// A backend that keeps failing

#[test]
fn a_failing_backend_is_logged_once_per_distinct_message_and_once_more_when_it_works_again() {
    let mut r = rig();
    let posting = |r: &Rig| -> Vec<String> {
        r.logged()
            .into_iter()
            .filter(|line| line.starts_with("post"))
            .collect()
    };
    r.notifier.fail_posts(3, "helper exited 1");
    for _ in 0..3 {
        r.handle(r.now());
    }
    assert_eq!(posting(&r), ["post failed turn_done 12 helper exited 1"]);
    r.notifier.fail_posts(2, "the helper is missing");
    r.handle(r.now());
    r.handle(r.now());
    assert_eq!(
        posting(&r),
        [
            "post failed turn_done 12 helper exited 1",
            "post failed turn_done 12 the helper is missing"
        ],
        "a message not seen yet is logged"
    );
    r.notifier.fail_posts(1, "helper exited 1");
    r.handle(r.now());
    assert_eq!(
        posting(&r).len(),
        2,
        "seen since the last success: not again"
    );
    r.handle(r.now());
    assert_eq!(
        posting(&r).last().map(String::as_str),
        Some("posting works again")
    );
    r.handle(r.now());
    assert_eq!(posting(&r).len(), 3, "said once");
    r.notifier.fail_posts(1, "helper exited 1");
    r.handle(r.now());
    assert_eq!(
        posting(&r),
        [
            "post failed turn_done 12 helper exited 1",
            "post failed turn_done 12 the helper is missing",
            "posting works again",
            "post failed turn_done 12 helper exited 1"
        ],
        "after a success the message counts as new again"
    );
}

#[test]
fn a_post_that_fails_is_not_up_so_the_next_prompt_has_nothing_to_withdraw() {
    let mut r = rig();
    r.notifier.fail_posts(1, "helper exited 1");
    r.handle(r.now());
    r.handle(r.now().on(H::UserPromptSubmit));
    assert!(r.notifier.withdrawn().is_empty());
}

// A job that fails

#[test]
fn a_job_that_panics_is_logged_as_an_error_with_its_text_and_the_next_job_runs() {
    let mut r = rig();
    r.start();
    r.notifier.during_post(|| panic!("the helper blew up"));
    r.feed.emit(r.now());
    r.feed.emit(r.now().in_pane("13"));
    r.wake();
    assert_eq!(
        r.logged(),
        [
            "error the helper blew up",
            "notice turn_done 13 \"proj\" shown"
        ]
    );
}

#[test]
fn a_panic_with_a_formatted_text_is_logged_with_that_text_and_the_engine_goes_on() {
    let mut r = rig();
    r.handle(r.now());
    r.feed.set_rows(vec![row()]);
    r.feed.state.borrow_mut().states_panic = Some("the rows cannot be read");
    r.advance(50.0 * MIN);
    assert_eq!(
        r.logged().last().map(String::as_str),
        Some("error the rows cannot be read")
    );
    r.feed.state.borrow_mut().states_panic = None;
    r.handle(r.now().in_pane("13"));
    assert_eq!(r.notifier.kinds(), ["turn_done", "turn_done"]);
}

#[test]
fn a_panic_whose_payload_is_no_text_is_logged_as_panic() {
    let mut r = rig();
    r.notifier.during_post(|| std::panic::panic_any(7_u8));
    r.handle(r.now());
    assert_eq!(r.logged(), ["error panic"]);
}
