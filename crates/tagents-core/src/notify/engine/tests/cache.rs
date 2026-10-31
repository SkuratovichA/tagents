//! The prompt-cache deadlines: what arms one and what cancels it, what a due one posts and what it leaves alone, how a restart arms the state rows, what the wait is, and the one warning of an idle period.

use std::fs;

use super::*;

const FIFTY_MIN_BODY: &str = "Idle 50 min — send anything within ~10 min to keep the prompt cache";

#[test]
fn a_turn_arms_one_deadline_and_a_prompt_cancels_it() {
    let mut r = rig();
    r.handle(r.now());
    assert_eq!(r.armed(), 1);
    r.handle(r.now().on(H::UserPromptSubmit));
    assert_eq!(r.armed(), 0);
    r.handle(r.permission());
    assert_eq!(r.armed(), 1);
    r.handle(r.now().on(H::SessionStart));
    assert_eq!(r.armed(), 0);
}

#[test]
fn a_question_arms_one_too_and_a_subagent_finishing_does_not() {
    let mut question = rig();
    question.handle(question.ask());
    assert_eq!(question.armed(), 1);
    let mut subagent = rig();
    subagent.handle(
        subagent
            .now()
            .on(H::SubagentStop)
            .agent("a1")
            .sub("Explore"),
    );
    assert_eq!(subagent.armed(), 0);
}

#[test]
fn a_deadline_due_with_the_row_done_posts_cache_expiring_with_the_idle_and_the_left_minutes() {
    let mut r = rig_with(Setup {
        screens: vec![("%12", hidden())],
        ..Setup::default()
    });
    let stop_at = r.clock.now_ms();
    r.handle(r.now().cwd("/work/proj"));
    r.feed.set_rows(vec![row_of("12", RowState::Done, stop_at)]);
    r.advance(49.0 * MIN);
    assert_eq!(r.notifier.kinds(), ["turn_done"], "not yet");
    r.advance(MIN);
    assert_eq!(r.notifier.kinds(), ["turn_done", "cache_expiring"]);
    let n = &r.notifier.posts()[1];
    assert_eq!(n.id, "tagents-12");
    assert_eq!(n.title, "build agent");
    assert_eq!(n.subtitle, "Prompt cache expiring · proj");
    assert_eq!(n.body, FIFTY_MIN_BODY);
    assert_eq!(
        n.click.argv,
        [
            TAGENTS,
            "--act",
            "open",
            "%12",
            "live",
            "sess-1",
            "/work/proj"
        ]
    );
    assert_eq!(r.armed(), 0);
}

#[test]
fn a_deadline_due_with_the_row_blocked_posts_too() {
    let mut r = rig();
    r.handle(r.permission());
    r.feed.set_rows(vec![row_of("12", RowState::Blocked, T0)]);
    r.advance(50.0 * MIN);
    assert_eq!(r.notifier.kinds().last(), Some(&"cache_expiring"));
}

#[test]
fn a_deadline_due_with_the_row_working_new_gone_or_missing_posts_nothing_and_is_dropped() {
    for state in [
        Some(RowState::Working),
        Some(RowState::New),
        Some(RowState::Gone),
        None,
    ] {
        let mut r = rig();
        r.handle(r.now());
        let before = r.notifier.posts().len();
        // A working row is a turn that began after the Stop that armed the deadline.
        r.feed.set_rows(state.map_or_else(Vec::new, |state| {
            let at = if state == RowState::Working {
                T0 + 30_000.0
            } else {
                T0
            };
            vec![row_of("12", state, at)]
        }));
        r.advance(50.0 * MIN);
        assert_eq!(r.notifier.posts().len(), before, "{state:?}");
        assert_eq!(r.armed(), 0, "{state:?}");
    }
}

#[test]
fn a_row_of_another_key_does_not_stand_in_for_this_one() {
    let mut r = rig();
    r.handle(r.now());
    r.feed.set_rows(vec![row_of("99", RowState::Done, T0)]);
    r.advance(50.0 * MIN);
    assert_eq!(r.notifier.kinds(), ["turn_done"]);
}

#[test]
fn the_mac_sleeping_past_the_cache_ttl_leaves_no_notice_about_a_cache_that_is_already_gone() {
    let mut r = rig();
    r.handle(r.now());
    r.feed.set_rows(vec![row()]);
    r.advance(4.0 * MIN);
    r.clock.advance(70.0 * MIN);
    r.wake();
    assert_eq!(r.notifier.kinds(), ["turn_done"]);
    assert_eq!(r.armed(), 0);
}

#[test]
fn the_mac_waking_three_minutes_past_the_due_time_gets_its_notice_on_the_first_wake() {
    let mut r = rig();
    r.handle(r.now());
    r.feed.set_rows(vec![row()]);
    r.advance(4.0 * MIN);
    r.clock.advance(49.0 * MIN);
    assert_eq!(r.notifier.posts().len(), 1, "a sleeping Mac runs nothing");
    r.wake();
    let posts = r.notifier.posts();
    let last = posts.last().unwrap();
    assert_eq!(last.kind, NoticeKind::CacheExpiring);
    assert_eq!(
        last.body,
        "Idle 53 min — send anything within ~7 min to keep the prompt cache"
    );
}

#[test]
fn a_deadline_that_fell_due_while_a_newer_turn_was_queued_ahead_of_it_is_stale_and_posts_nothing() {
    let mut r = rig();
    r.start();
    r.feed.set_rows(vec![row()]);
    r.handle(r.now());
    // The second turn's Stop was written before the first deadline's wake could be: its line is in the file when the clock reaches the first deadline.
    r.clock.advance(50.0 * MIN);
    r.feed.emit(event().at(T0 + 49.0 * MIN));
    r.wake();
    assert_eq!(r.notifier.kinds(), ["turn_done", "turn_done"]);
    assert_eq!(
        r.armed(),
        1,
        "the second turn's own deadline is still waiting"
    );
}

#[test]
fn the_wait_is_never_longer_than_five_minutes() {
    let mut r = rig();
    r.handle(r.now());
    assert_eq!(r.engine.next_due(), Some(Duration::from_secs(300)));
}

#[test]
fn the_wait_is_the_time_left_to_the_deadline_when_that_is_sooner_and_none_when_nothing_waits() {
    let mut r = rig();
    assert_eq!(r.engine.next_due(), None);
    r.handle(r.now());
    r.advance(48.0 * MIN);
    assert_eq!(r.engine.next_due(), Some(Duration::from_secs(120)));
    r.clock.advance(5.0 * MIN);
    assert_eq!(
        r.engine.next_due(),
        Some(Duration::ZERO),
        "overdue is no wait, never a negative one"
    );
    r.feed.set_rows(vec![row()]);
    r.wake();
    assert_eq!(r.engine.next_due(), None, "a deadline that fired is gone");
}

#[test]
fn start_arms_every_row_that_is_done_or_blocked_and_still_inside_the_ttl_and_each_posts_once() {
    let mut r = rig_with(Setup {
        rows: vec![
            AgentStateRow {
                session_id: "sess-12".to_owned(),
                cwd: "/work/twelve".to_owned(),
                ..row_of("12", RowState::Done, T0 - 10.0 * MIN)
            },
            AgentStateRow {
                session_id: "sess-13".to_owned(),
                cwd: "/work/thirteen".to_owned(),
                ..row_of("13", RowState::Blocked, T0 - 20.0 * MIN)
            },
            row_of("14", RowState::Working, T0 - 5.0 * MIN),
        ],
        screens: vec![("%12", hidden()), ("%13", hidden())],
        ..Setup::default()
    });
    r.start();
    assert_eq!(r.armed(), 2, "the two that wait; the working one is a turn");
    // The rows are as they were; the clock walks to each deadline.
    r.advance(31.0 * MIN);
    let ids = |r: &Rig| -> Vec<String> { r.notifier.posts().into_iter().map(|p| p.id).collect() };
    assert_eq!(ids(&r), ["tagents-13"]);
    assert_eq!(
        r.notifier.posts()[0].body,
        "Idle 51 min — send anything within ~9 min to keep the prompt cache"
    );
    r.advance(10.0 * MIN);
    assert_eq!(ids(&r), ["tagents-13", "tagents-12"]);
    assert_eq!(
        r.notifier.posts()[1].subtitle,
        "Prompt cache expiring · twelve"
    );
    r.advance(60.0 * MIN);
    assert_eq!(r.notifier.posts().len(), 2, "once each");
    assert_eq!(r.armed(), 0);
}

#[test]
fn start_leaves_a_row_that_is_already_past_the_ttl_alone_and_arms_nothing() {
    let mut r = rig_with(Setup {
        rows: vec![row_of("12", RowState::Done, T0 - 61.0 * MIN)],
        ..Setup::default()
    });
    r.start();
    assert_eq!(r.armed(), 0);
    assert_eq!(r.engine.next_due(), None);
}

#[test]
fn start_arms_nothing_with_cache_expiring_switched_off() {
    let mut r = rig_with(Setup {
        options: options(|o| o.events.cache_expiring.toggles.enabled = false),
        rows: vec![row_of("12", RowState::Done, T0 - 10.0 * MIN)],
        ..Setup::default()
    });
    r.start();
    assert_eq!(r.armed(), 0);
}

#[test]
fn a_deadline_armed_from_a_row_is_composed_from_the_row_with_the_label_history_keeps() {
    let mut r = rig_with(Setup {
        rows: vec![row_of("12", RowState::Done, T0 - 55.0 * MIN)],
        ..Setup::default()
    });
    // history.tsv: at, kind, session id, pane, label, cwd
    fs::write(
        format!("{}/history.tsv", r.dir.dir()),
        format!(
            "{}\tturn\tsess-1\t%12\tticket-agent\t/work/proj\n",
            T0 / 1000.0 - 3300.0
        ),
    )
    .unwrap();
    // The row is 55 minutes old, so its deadline fell due before the engine started: start posts it.
    r.start();
    let posts = r.notifier.posts();
    assert_eq!(posts.len(), 1);
    let n = &posts[0];
    assert_eq!(n.thread, "sess-1");
    assert_eq!(n.title, "ticket-agent");
    assert_eq!(
        n.body,
        "Idle 55 min — send anything within ~5 min to keep the prompt cache"
    );
    assert_eq!(
        n.click.argv,
        [
            TAGENTS,
            "--act",
            "open",
            "%12",
            "live",
            "sess-1",
            "/work/proj"
        ]
    );
    assert_eq!(r.screen.probed(), ["%12"]);
}

#[test]
fn a_row_that_is_blocked_is_composed_as_a_notification_and_a_done_one_as_a_stop() {
    let blocked = AgentStateRow {
        detail: "needs a yes".to_owned(),
        ..row_of("12", RowState::Blocked, T0 - 5.0 * MIN)
    };
    let notification = event_from_row(&blocked, &HashMap::new());
    assert_eq!(notification.event, H::Notification);
    assert_eq!(notification.text, "needs a yes");
    assert_eq!(
        notification.at,
        T0 - 5.0 * MIN,
        "seconds of the row, milliseconds of the event"
    );
    assert_eq!(notification.pane, "%12");
    let done = event_from_row(&row_of("12", RowState::Done, T0), &HashMap::new());
    assert_eq!(done.event, H::Stop);
    let named = event_from_row(
        &row_of("proj-agent", RowState::Done, T0),
        &HashMap::from([("sess-1".to_owned(), "typed".to_owned())]),
    );
    assert_eq!(named.pane, "", "a key that is no pane number has no pane");
    assert_eq!(named.label, "typed");
}

#[test]
fn nothing_is_pending_at_start_with_no_rows_and_nothing_fires_after_stop() {
    let mut r = rig();
    r.start();
    assert_eq!(r.armed(), 0);
    assert_eq!(r.engine.next_due(), None);
    r.handle(r.now());
    assert_eq!(r.armed(), 1);
    r.feed.set_rows(vec![row()]);
    assert_eq!(r.engine.stop(), Ok(()));
    assert_eq!(r.armed(), 0);
    assert_eq!(r.engine.next_due(), None);
    r.advance(120.0 * MIN);
    assert_eq!(r.notifier.kinds(), ["turn_done"]);
}

#[test]
fn an_event_that_arrives_after_stop_arms_nothing() {
    let mut r = rig();
    assert_eq!(r.engine.stop(), Ok(()));
    r.handle(r.now());
    assert_eq!(r.armed(), 0);
    assert!(r.notifier.posts().is_empty());
}

#[test]
fn with_cache_expiring_off_no_deadline_is_ever_armed() {
    let mut r = rig_with(Setup {
        options: options(|o| o.events.cache_expiring.toggles.enabled = false),
        ..Setup::default()
    });
    r.handle(r.now());
    assert_eq!(r.armed(), 0);
    assert_eq!(r.notifier.posts().len(), 1);
}

#[test]
fn a_deadline_that_falls_due_after_cache_expiring_was_switched_off_posts_nothing() {
    let mut r = rig();
    r.handle(r.now());
    r.feed.set_rows(vec![row()]);
    r.engine
        .reload(options(|o| o.events.cache_expiring.toggles.enabled = false));
    r.advance(50.0 * MIN);
    assert_eq!(r.notifier.kinds(), ["turn_done"]);
    assert_eq!(r.armed(), 0);
}

#[test]
fn the_options_are_read_again_at_every_event_so_turning_a_kind_off_takes_effect_at_once() {
    let mut r = rig();
    r.handle(r.now());
    r.engine
        .reload(options(|o| o.events.turn_done.enabled = false));
    r.handle(r.now());
    assert_eq!(r.notifier.posts().len(), 1);
    r.engine.reload(Options::default());
    r.handle(r.now());
    assert_eq!(
        r.notifier.posts().len(),
        2,
        "and turning it on again does too"
    );
}

#[test]
fn a_cache_deadline_uses_the_after_and_ttl_of_the_options() {
    let mut r = rig_with(Setup {
        options: options(|o| {
            o.events.cache_expiring.after_ms = 10.0 * MIN;
            o.events.cache_expiring.ttl_ms = 20.0 * MIN;
        }),
        ..Setup::default()
    });
    r.handle(r.now());
    r.feed.set_rows(vec![row()]);
    r.advance(10.0 * MIN);
    let posts = r.notifier.posts();
    assert_eq!(posts.len(), 2);
    assert_eq!(
        posts[1].body,
        "Idle 10 min — send anything within ~10 min to keep the prompt cache"
    );
}

// A question's deadline

#[test]
fn a_questions_deadline_falls_due_although_the_hook_wrote_the_row_as_working_for_it() {
    for tool in ["AskUserQuestion", "ExitPlanMode"] {
        let mut r = rig_with(Setup {
            screens: vec![("%12", hidden())],
            ..Setup::default()
        });
        let asked_at = r.clock.now_ms();
        r.handle(r.now().on(H::PreToolUse).tool(tool));
        r.feed.set_rows(vec![AgentStateRow {
            detail: tool.to_owned(),
            ..row_of("12", RowState::Working, asked_at)
        }]);
        r.advance(50.0 * MIN);
        assert_eq!(r.notifier.kinds(), ["question", "cache_expiring"], "{tool}");
        assert_eq!(r.notifier.posts()[1].body, FIFTY_MIN_BODY, "{tool}");
    }
}

#[test]
fn a_working_row_newer_than_the_question_means_the_turn_runs_again_and_no_cache_notice() {
    let mut r = rig();
    r.handle(r.ask());
    r.feed.set_rows(vec![AgentStateRow {
        detail: "Bash ls".to_owned(),
        ..row_of("12", RowState::Working, T0 + 10_000.0)
    }]);
    r.advance(50.0 * MIN);
    assert_eq!(r.notifier.kinds(), ["question"]);
    assert_eq!(r.armed(), 0);
}

#[test]
fn start_arms_a_row_that_is_working_on_a_question_nobody_answered_and_no_other_working_row() {
    let asked = |key: &str, detail: &str| AgentStateRow {
        detail: detail.to_owned(),
        session_id: format!("sess-{key}"),
        ..row_of(key, RowState::Working, T0 - 10.0 * MIN)
    };
    let mut r = rig_with(Setup {
        rows: vec![
            asked("12", "AskUserQuestion"),
            asked("13", "ExitPlanMode"),
            asked("14", "Bash ls"),
            asked("15", "AskUserQuestion ✓"),
            asked("16", "ExitPlanMode ✓"),
        ],
        screens: vec![("%12", hidden()), ("%13", hidden())],
        ..Setup::default()
    });
    r.start();
    assert_eq!(r.armed(), 2);
    r.advance(40.0 * MIN);
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
    r.advance(20.0 * MIN);
    assert_eq!(
        r.notifier.posts().len(),
        2,
        "the answered ones and the running tool never armed"
    );
}

#[test]
fn an_open_question_is_the_tool_alone_or_with_text_that_is_not_the_answers_tick_on_one_line() {
    assert!(is_open_question("AskUserQuestion"));
    assert!(is_open_question("ExitPlanMode"));
    assert!(is_open_question("AskUserQuestion Which one?"));
    assert!(!is_open_question("AskUserQuestion ✓"));
    assert!(!is_open_question("ExitPlanMode ✓"));
    assert!(!is_open_question("AskUserQuestionX"));
    assert!(!is_open_question("Bash AskUserQuestion"));
    assert!(!is_open_question("AskUserQuestion line one\nline two"));
    assert!(!is_open_question("ExitPlanMode a\u{2028}b"));
    assert!(is_open_question("AskUserQuestion ✓ and more"));
    assert!(!is_open_question(""));
}

// One warning for one idle period

#[test]
fn a_refollow_does_not_warn_again_about_a_key_it_already_warned_about() {
    let mut r = rig_with(Setup {
        rows: vec![row_of("12", RowState::Done, T0)],
        ..Setup::default()
    });
    r.start();
    r.advance(50.0 * MIN);
    assert_eq!(r.notifier.kinds(), ["cache_expiring"]);
    r.kill("the watch failed");
    r.advance(1000.0);
    assert_eq!(r.feed.followers(), 2);
    assert_eq!(
        r.armed(),
        0,
        "the row is the same idle period: nothing armed"
    );
    r.advance(5.0 * MIN);
    assert_eq!(r.notifier.kinds(), ["cache_expiring"]);
}

#[test]
fn a_row_written_after_the_warning_is_a_new_idle_period_and_the_refollow_arms_it() {
    let mut r = rig_with(Setup {
        rows: vec![row_of("12", RowState::Done, T0)],
        ..Setup::default()
    });
    r.start();
    r.advance(50.0 * MIN);
    r.kill("the watch failed");
    r.feed
        .set_rows(vec![row_of("12", RowState::Done, T0 + 52.0 * MIN)]);
    r.advance(1000.0);
    assert_eq!(r.armed(), 1);
}

#[test]
fn a_prompt_or_a_new_turn_lets_a_key_be_warned_about_again() {
    let mut r = rig();
    r.feed.set_rows(vec![row()]);
    r.handle(r.now());
    r.advance(50.0 * MIN);
    assert_eq!(r.notifier.kinds(), ["turn_done", "cache_expiring"]);
    r.handle(r.now().on(H::UserPromptSubmit));
    let second = r.clock.now_ms();
    r.feed.set_rows(vec![row_of("12", RowState::Done, second)]);
    r.handle(r.now());
    r.advance(50.0 * MIN);
    assert_eq!(
        r.notifier.kinds(),
        ["turn_done", "cache_expiring", "turn_done", "cache_expiring"]
    );
}

#[test]
fn a_warning_that_failed_to_post_is_not_a_warning_and_the_refollow_arms_the_row_again() {
    let mut r = rig_with(Setup {
        rows: vec![row_of("12", RowState::Done, T0)],
        ..Setup::default()
    });
    r.notifier.fail_posts(1, "the center is away");
    r.start();
    r.advance(50.0 * MIN);
    assert!(r.notifier.posts().is_empty());
    r.kill("the watch failed");
    r.advance(1000.0);
    assert_eq!(
        r.notifier.kinds(),
        ["cache_expiring"],
        "nobody was told, so the row is armed once more and its deadline, long past, fires at once"
    );
    assert_eq!(r.armed(), 0);
}

// A pane that is gone

#[test]
fn no_cache_notice_for_a_pane_tmux_says_is_gone_and_the_reason_is_logged_other_notices_still_post()
{
    let mut r = rig_with(Setup {
        screens: vec![("%12", ScreenAnswer::NoSuchPane)],
        ..Setup::default()
    });
    r.handle(r.now());
    r.feed.set_rows(vec![row()]);
    r.advance(50.0 * MIN);
    assert_eq!(r.notifier.kinds(), ["turn_done"]);
    assert_eq!(r.notifier.posts()[0].terminal_pid, None);
    assert_eq!(
        r.logged(),
        [
            "notice turn_done 12 \"proj\" shown",
            "notice cache_expiring 12 skipped: tmux has no pane %12"
        ]
    );
}

#[test]
fn a_tmux_that_did_not_answer_is_not_a_pane_that_is_gone_the_cache_notice_posts() {
    let mut r = rig();
    r.handle(r.now());
    r.feed.set_rows(vec![row()]);
    r.advance(50.0 * MIN);
    assert_eq!(r.notifier.kinds(), ["turn_done", "cache_expiring"]);
}

#[test]
fn two_deadlines_that_fell_due_together_post_in_the_order_they_were_armed() {
    let mut r = rig();
    r.handle(r.now().in_pane("13"));
    r.handle(r.now());
    r.feed.set_rows(vec![
        row_of("12", RowState::Done, T0),
        row_of("13", RowState::Done, T0),
    ]);
    r.advance(50.0 * MIN);
    let ids: Vec<String> = r.notifier.posts().into_iter().map(|p| p.id).collect();
    assert_eq!(
        ids,
        ["tagents-13", "tagents-12", "tagents-13", "tagents-12"]
    );
}
