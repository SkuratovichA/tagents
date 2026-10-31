//! A question on screen and the generic permission prompt Claude Code raises about six seconds after it, and what a dropped notice leaves behind.

use super::*;

#[test]
fn a_permission_prompt_after_a_question_posts_nothing_replaces_nothing_and_leaves_the_questions_deadline()
 {
    let mut r = rig_with(Setup {
        screens: vec![("%12", hidden())],
        ..Setup::default()
    });
    let asked_at = r.clock.now_ms();
    r.handle(r.ask());
    r.advance(6_000.0);
    r.handle(r.permission());
    assert_eq!(r.notifier.kinds(), ["question"], "the question stays up");
    assert!(r.notifier.withdrawn().is_empty());
    assert_eq!(
        r.logged(),
        [
            "notice question 12 \"build agent\" shown",
            "permission prompt held back by the question on screen 12"
        ]
    );
    r.feed.set_rows(vec![AgentStateRow {
        detail: "AskUserQuestion".to_owned(),
        ..row_of("12", RowState::Working, asked_at)
    }]);
    r.advance(50.0 * MIN - 6_000.0);
    assert_eq!(
        r.notifier.kinds(),
        ["question", "cache_expiring"],
        "due 50 minutes after the question, not after the prompt"
    );
}

#[test]
fn the_answer_withdraws_the_question_and_a_permission_prompt_after_it_posts() {
    let mut r = rig();
    r.handle(r.ask());
    r.handle(r.now().on(H::PostToolUse).tool("AskUserQuestion"));
    assert_eq!(r.notifier.withdrawn(), ["tagents-12"]);
    assert_eq!(r.armed(), 0);
    r.handle(r.permission());
    assert_eq!(r.notifier.kinds(), ["question", "permission"]);
}

#[test]
fn a_permission_prompt_with_no_question_pending_posts() {
    let mut r = rig();
    r.handle(r.permission());
    assert_eq!(r.notifier.kinds(), ["permission"]);
    assert_eq!(r.notifier.posts()[0].id, "tagents-12");
}

#[test]
fn the_question_ends_with_the_answer_a_prompt_the_turn_the_session_start_or_the_session_end() {
    let ends = [
        (
            "PostToolUse AskUserQuestion",
            H::PostToolUse,
            "AskUserQuestion",
        ),
        ("PostToolUse ExitPlanMode", H::PostToolUse, "ExitPlanMode"),
        ("UserPromptSubmit", H::UserPromptSubmit, ""),
        ("Stop", H::Stop, ""),
        ("SessionStart", H::SessionStart, ""),
        ("SessionEnd", H::SessionEnd, ""),
    ];
    for (name, event, tool) in ends {
        let mut r = rig();
        r.handle(r.ask());
        r.handle(r.permission());
        assert_eq!(
            r.notifier.kinds(),
            ["question"],
            "{name}: held back while the question stands"
        );
        r.handle(r.now().on(event).tool(tool));
        r.handle(r.permission());
        assert_eq!(
            r.notifier.kinds().last(),
            Some(&"permission"),
            "{name}: the question is over"
        );
    }
}

#[test]
fn a_subagents_stop_and_another_keys_events_do_not_end_the_question() {
    let mut r = rig();
    r.handle(r.ask());
    r.handle(r.now().agent("a1"));
    r.handle(r.now().on(H::UserPromptSubmit).in_pane("13"));
    r.handle(r.permission());
    assert_eq!(r.notifier.kinds(), ["question"]);
    r.handle(r.permission().in_pane("13"));
    let ids: Vec<String> = r.notifier.posts().into_iter().map(|p| p.id).collect();
    assert_eq!(
        ids,
        ["tagents-12", "tagents-13"],
        "each key has its own question"
    );
}

#[test]
fn an_elicitation_dialog_holds_nothing_back_it_has_no_answer_event_and_no_prompt_after_it() {
    let mut r = rig();
    r.handle(
        r.now()
            .on(H::Notification)
            .sub("elicitation_dialog")
            .text("Pick a branch"),
    );
    r.handle(r.permission());
    assert_eq!(r.notifier.kinds(), ["question", "permission"]);
}

#[test]
fn a_permission_prompt_more_than_20_seconds_after_the_question_is_a_real_one_and_posts() {
    let mut r = rig();
    r.handle(r.ask());
    r.advance(20_000.0);
    r.handle(r.permission());
    assert_eq!(
        r.notifier.kinds(),
        ["question"],
        "20 seconds is still the question's prompt"
    );
    r.advance(10_000.0);
    r.handle(r.permission());
    assert_eq!(
        r.notifier.kinds(),
        ["question", "permission"],
        "30 seconds is not"
    );
}

#[test]
fn a_question_the_backend_dropped_or_that_is_switched_off_holds_nothing_back() {
    let mut dropped = rig();
    dropped.notifier.answer(false, Some("frontmost"));
    dropped.handle(dropped.ask());
    dropped.notifier.answer(true, None);
    dropped.handle(dropped.permission());
    assert_eq!(
        dropped.notifier.kinds(),
        ["question", "permission"],
        "the question was tried, and the prompt is not held back"
    );
    let mut off = rig_with(Setup {
        options: options(|o| o.events.question.enabled = false),
        ..Setup::default()
    });
    off.handle(off.ask());
    off.handle(off.permission());
    assert_eq!(off.notifier.kinds(), ["permission"]);
}

#[test]
fn a_question_the_backend_could_not_post_holds_nothing_back() {
    let mut r = rig();
    r.notifier.fail_posts(1, "the center is away");
    r.handle(r.ask());
    r.handle(r.permission());
    assert_eq!(r.notifier.kinds(), ["permission"]);
}

// A dropped notice and the stale one

#[test]
fn a_turn_done_the_backend_drops_takes_down_the_permission_notice_it_would_have_replaced() {
    let mut r = rig();
    r.handle(r.permission());
    r.notifier.answer(false, Some("frontmost"));
    r.handle(r.now());
    assert_eq!(r.notifier.ops(), ["post", "post", "withdraw"]);
    assert_eq!(r.notifier.withdrawn(), ["tagents-12"]);
    r.notifier.answer(true, None);
    r.handle(r.now().on(H::UserPromptSubmit));
    assert_eq!(
        r.notifier.withdrawn(),
        ["tagents-12"],
        "the key left the set: nothing to withdraw twice"
    );
}

// Cleanup

#[test]
fn a_new_session_in_the_pane_withdraws_what_the_old_one_asked_and_the_question_with_it() {
    let mut r = rig();
    r.handle(r.ask());
    r.handle(r.now().on(H::SessionStart));
    assert_eq!(r.notifier.withdrawn(), ["tagents-12"]);
    assert_eq!(r.armed(), 0);
    r.handle(r.permission());
    assert_eq!(r.notifier.kinds(), ["question", "permission"]);
}

#[test]
fn a_pane_tmux_says_is_gone_drops_the_question_it_held_back_with_and_leaves_its_notices_up() {
    let mut r = rig();
    r.handle(r.ask());
    r.handle(r.permission());
    assert_eq!(
        r.notifier.kinds(),
        ["question"],
        "held back while the pane is there"
    );
    r.screen.answer("%12", ScreenAnswer::NoSuchPane);
    // The next post for the key is what finds the pane gone: a question asked again, which the question it replaces cannot hold back.
    r.handle(r.ask());
    assert!(r.notifier.withdrawn().is_empty());
    r.handle(r.permission());
    assert_eq!(r.notifier.kinds(), ["question", "question", "permission"]);
}
