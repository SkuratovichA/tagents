//! What a notice is made of and which events make one: the title, the click, the screen, the switches, and the sessions that never post.

use std::fs;

use super::*;

#[test]
fn a_turn_that_ends_posts_one_notice_under_the_keys_id_and_the_sessions_thread() {
    let mut r = rig_with(Setup {
        screens: vec![("%12", hidden())],
        ..Setup::default()
    });
    r.handle(r.now().on(H::Stop).cwd("/work/proj"));
    let posts = r.notifier.posts();
    assert_eq!(posts.len(), 1);
    let n = &posts[0];
    assert_eq!(n.id, "tagents-12");
    assert_eq!(n.thread, "sess-1");
    assert_eq!(n.kind, NoticeKind::TurnDone);
    assert_eq!(n.title, "build agent");
    assert_eq!(n.subtitle, "Answer ready · proj");
    assert_eq!(n.body, "Your move");
    assert_eq!(r.screen.probed(), ["%12"]);
}

#[test]
fn the_title_is_the_label_typed_on_ctrl_r_when_there_is_one() {
    let mut r = rig_with(Setup {
        screens: vec![("%12", hidden())],
        ..Setup::default()
    });
    fs::write(
        format!("{}/labels.tsv", r.dir.dir()),
        "sess-1\ttyped name\n",
    )
    .unwrap();
    r.handle(r.now());
    assert_eq!(r.notifier.posts()[0].title, "typed name");
}

#[test]
fn a_second_notice_for_one_key_reuses_its_id() {
    let mut r = rig();
    r.handle(r.now().on(H::Stop));
    r.handle(
        r.now()
            .on(H::Notification)
            .sub("permission_prompt")
            .text("Allow?"),
    );
    let posts = r.notifier.posts();
    let ids: Vec<&str> = posts.iter().map(|p| p.id.as_str()).collect();
    assert_eq!(ids, ["tagents-12", "tagents-12"]);
    assert_eq!(r.notifier.kinds(), ["turn_done", "permission"]);
}

#[test]
fn a_disabled_kind_posts_nothing_yet_its_turn_done_still_arms_the_cache_deadline() {
    let mut r = rig_with(Setup {
        options: options(|o| o.events.turn_done.enabled = false),
        ..Setup::default()
    });
    r.handle(r.now().on(H::Stop));
    assert!(r.notifier.posts().is_empty());
    assert_eq!(r.armed(), 1);
    r.feed
        .set_rows(vec![row_of("12", RowState::Done, r.clock.now_ms())]);
    r.advance(50.0 * MIN);
    assert_eq!(r.notifier.kinds(), ["cache_expiring"]);
}

#[test]
fn the_kind_that_is_off_by_default_posts_nothing_until_it_is_turned_on() {
    let mut r = rig();
    r.handle(r.now().on(H::SessionEnd).sub("logout"));
    assert!(r.notifier.posts().is_empty());
    let mut on = rig_with(Setup {
        options: options(|o| o.events.session_end.enabled = true),
        ..Setup::default()
    });
    on.handle(on.now().on(H::SessionEnd).sub("logout"));
    let posts = on.notifier.posts();
    assert_eq!(posts.len(), 1);
    assert_eq!(
        (posts[0].kind, posts[0].body.as_str()),
        (NoticeKind::SessionEnd, "logout")
    );
}

#[test]
fn skip_visible_with_the_pane_in_some_clients_window_skips_if_frontmost_with_that_clients_pid() {
    let mut r = rig_with(Setup {
        screens: vec![("%12", visible())],
        ..Setup::default()
    });
    r.handle(r.now());
    let n = &r.notifier.posts()[0];
    assert_eq!(n.skip_if_frontmost, Some(true));
    assert_eq!(n.terminal_pid, Some(4242));
}

#[test]
fn a_pane_nobody_is_looking_at_is_posted_with_no_skip_and_the_most_active_clients_pid() {
    let mut r = rig_with(Setup {
        screens: vec![("%12", hidden())],
        ..Setup::default()
    });
    r.handle(r.now());
    let n = &r.notifier.posts()[0];
    assert_eq!(n.skip_if_frontmost, None);
    assert_eq!(n.terminal_pid, Some(777));
}

#[test]
fn skip_visible_off_posts_a_visible_pane_without_the_skip_still_with_its_client_for_the_click() {
    let mut r = rig_with(Setup {
        screens: vec![("%12", visible())],
        options: options(|o| o.events.turn_done.skip_visible = false),
        ..Setup::default()
    });
    r.handle(r.now());
    let n = &r.notifier.posts()[0];
    assert_eq!(n.skip_if_frontmost, None);
    assert_eq!(n.terminal_pid, Some(4242));
}

#[test]
fn a_pane_tmux_does_not_know_is_posted_with_no_pid_named_by_its_label_or_directory() {
    let mut r = rig();
    r.handle(r.now().label("ticket-agent"));
    let n = &r.notifier.posts()[0];
    assert_eq!((n.terminal_pid, n.skip_if_frontmost), (None, None));
    assert_eq!(n.title, "ticket-agent");
}

#[test]
fn a_probe_that_fails_costs_the_pid_not_the_notice_and_says_why() {
    let mut r = rig();
    r.screen.fail("%12", "tmux went away");
    r.handle(r.now());
    assert_eq!(r.notifier.posts().len(), 1);
    assert_eq!(r.notifier.posts()[0].terminal_pid, None);
    assert_eq!(
        r.logged(),
        [
            "screen probe failed %12 tmux went away",
            "notice turn_done 12 \"proj\" shown"
        ]
    );
}

#[test]
fn a_prompt_withdraws_only_when_a_notice_is_up_for_that_key() {
    let mut r = rig();
    r.handle(r.now().on(H::UserPromptSubmit));
    assert!(r.notifier.withdrawn().is_empty());
    r.handle(r.now().on(H::Stop));
    r.handle(r.now().on(H::UserPromptSubmit).in_pane("13"));
    assert!(
        r.notifier.withdrawn().is_empty(),
        "another key's notice is not this one"
    );
    r.handle(r.now().on(H::UserPromptSubmit));
    assert_eq!(r.notifier.withdrawn(), ["tagents-12"]);
    r.handle(r.now().on(H::UserPromptSubmit));
    assert_eq!(r.notifier.withdrawn(), ["tagents-12"], "once is enough");
}

#[test]
fn a_notice_that_the_backend_dropped_is_not_one_to_withdraw() {
    let mut r = rig();
    r.notifier.answer(false, Some("frontmost"));
    r.handle(r.now().on(H::Stop));
    r.handle(r.now().on(H::UserPromptSubmit));
    assert!(r.notifier.withdrawn().is_empty());
    assert_eq!(
        r.logged(),
        ["notice turn_done 12 \"proj\" dropped: frontmost"]
    );
}

#[test]
fn session_end_withdraws_the_notice_and_cancels_the_deadline() {
    let mut r = rig();
    r.handle(r.now().on(H::Stop));
    assert_eq!(r.armed(), 1);
    r.handle(r.now().on(H::SessionEnd).sub("logout"));
    assert_eq!(r.notifier.withdrawn(), ["tagents-12"]);
    assert_eq!(r.armed(), 0);
}

#[test]
fn with_session_end_on_the_end_of_a_session_withdraws_the_old_notice_and_then_posts_its_own() {
    let mut r = rig_with(Setup {
        options: options(|o| o.events.session_end.enabled = true),
        ..Setup::default()
    });
    r.handle(r.now().on(H::Stop));
    r.handle(r.now().on(H::SessionEnd).sub("logout"));
    assert_eq!(r.notifier.ops(), ["post", "withdraw", "post"]);
}

#[test]
fn the_click_dock_is_the_dashboards_enter_on_that_chat() {
    let mut r = rig_with(Setup {
        screens: vec![("%12", hidden())],
        ..Setup::default()
    });
    r.handle(r.now().cwd("/work/proj").session("sess-1"));
    assert_eq!(
        r.notifier.posts()[0].click.argv,
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
}

#[test]
fn the_click_goto_is_the_agents_own_window() {
    let mut r = rig_with(Setup {
        options: options(|o| o.click = Click::Goto),
        ..Setup::default()
    });
    r.handle(r.now());
    assert_eq!(r.notifier.posts()[0].click.argv, [TAGENTS, "--goto", "%12"]);
}

#[test]
fn the_click_focus_is_the_terminal_only() {
    let mut r = rig_with(Setup {
        options: options(|o| o.click = Click::Focus),
        ..Setup::default()
    });
    r.handle(r.now());
    assert!(r.notifier.posts()[0].click.argv.is_empty());
}

#[test]
fn a_paneless_event_clicks_to_the_terminal_only_whatever_the_mode() {
    for mode in [Click::Dock, Click::Goto, Click::Focus] {
        let mut r = rig_with(Setup {
            options: options(|o| o.click = mode),
            ..Setup::default()
        });
        r.handle(r.now().pane(""));
        assert!(r.notifier.posts()[0].click.argv.is_empty(), "{mode:?}");
    }
}

fn click_env(setup_env: Vec<(&'static str, &'static str)>) -> Vec<(String, String)> {
    let mut r = rig_with(Setup {
        env: setup_env,
        ..Setup::default()
    });
    r.handle(r.now());
    r.notifier.posts()[0].click.env.clone()
}

fn pairs(env: &[(&str, &str)]) -> Vec<(String, String)> {
    env.iter()
        .map(|(name, value)| ((*name).to_owned(), (*value).to_owned()))
        .collect()
}

#[test]
fn the_click_env_is_path_and_home_plus_the_locale_and_the_variables_that_pick_the_tmux_server_state_and_config_when_they_are_set()
 {
    let mut bare = BASE_ENV.to_vec();
    bare.extend([("SHELL", "/bin/zsh"), ("SECRET", "no")]);
    assert_eq!(click_env(bare), pairs(&BASE_ENV));

    let full = [
        ("SECRET", "no"),
        ("TA_CONFIG", "/tmp/cfg/config.toml"),
        ("XDG_CONFIG_HOME", "/tmp/xdg"),
        ("TAGENTS_CONFIG_DIR", "/tmp/cfg"),
        ("TA_STATE_DIR", "/tmp/st"),
        ("TMUX_TMPDIR", "/tmp/tm"),
        ("LC_CTYPE", "UTF-8"),
        ("LC_ALL", "en_US.UTF-8"),
        ("LANG", "ru_RU.UTF-8"),
        ("HOME", "/home/u"),
        ("PATH", "/usr/bin:/bin"),
    ];
    assert_eq!(
        click_env(full.to_vec()),
        pairs(&[
            ("PATH", "/usr/bin:/bin"),
            ("HOME", "/home/u"),
            ("LANG", "ru_RU.UTF-8"),
            ("LC_ALL", "en_US.UTF-8"),
            ("LC_CTYPE", "UTF-8"),
            ("TMUX_TMPDIR", "/tmp/tm"),
            ("TA_STATE_DIR", "/tmp/st"),
            ("TAGENTS_CONFIG_DIR", "/tmp/cfg"),
            ("XDG_CONFIG_HOME", "/tmp/xdg"),
            ("TA_CONFIG", "/tmp/cfg/config.toml"),
        ]),
        "the order is the one of the list, whatever the order of the environment"
    );

    let mut empty = BASE_ENV.to_vec();
    empty.push(("LANG", ""));
    assert_eq!(
        click_env(empty),
        pairs(&BASE_ENV),
        "an empty variable stays absent"
    );
}

#[test]
fn the_hostname_is_read_for_each_notice_a_title_that_was_the_host_is_a_name_once_the_host_is_renamed()
 {
    let mut r = rig();
    r.screen.answer(
        "%12",
        ScreenAnswer::Screen(Screen {
            visible: false,
            client_pid: None,
            pane_title: "untitled.local".to_owned(),
        }),
    );
    *r.host.borrow_mut() = "untitled.local".to_owned();
    r.handle(r.now());
    *r.host.borrow_mut() = "renamed.local".to_owned();
    r.handle(r.now());
    let posts = r.notifier.posts();
    assert_eq!(
        posts[0].title, "proj",
        "the pane title is the host: the directory names the agent"
    );
    assert_eq!(
        posts[1].title, "untitled.local",
        "the host changed: the title is a name now"
    );
}

// Notices come only from agents: never from a subagent, a child session or a pane-less session, whatever the options say.

#[test]
fn a_subagent_stop_posts_nothing_and_arms_nothing_with_every_switch_on() {
    let mut r = rig_with(Setup {
        options: every_switch_on(),
        ..Setup::default()
    });
    r.handle(r.now().on(H::SubagentStop).agent("a1").sub("Explore"));
    r.handle(r.now().on(H::SubagentStop).agent("").sub(""));
    assert!(r.notifier.posts().is_empty());
    assert_eq!(r.armed(), 0);
}

#[test]
fn a_child_sessions_stop_posts_nothing_with_every_switch_on() {
    // As the hook writes a child: keyed by its own session, with no pane, even though the agent that started it sits in pane %12.
    let mut r = rig_with(Setup {
        options: every_switch_on(),
        ..Setup::default()
    });
    let kid = || r.now().key("s-kid").session("kid").pane("");
    let events = [
        kid().cwd("/work/elsewhere"),
        kid()
            .on(H::Notification)
            .sub("permission_prompt")
            .text("Claude needs your permission to use Bash"),
        kid().on(H::SessionEnd).sub("other"),
    ];
    for e in events {
        r.handle(e);
    }
    assert!(r.notifier.posts().is_empty());
    assert_eq!(r.armed(), 0);
}

#[test]
fn a_paneless_headless_sessions_stop_posts_nothing_with_every_switch_on() {
    // A daemon's `claude -p` turn, named through TA_LABEL: it reports elsewhere.
    let mut r = rig_with(Setup {
        options: every_switch_on(),
        ..Setup::default()
    });
    r.handle(
        r.now()
            .key("s-daemon")
            .session("daemon")
            .pane("")
            .label("ticket-agent"),
    );
    assert!(r.notifier.posts().is_empty());
    assert_eq!(r.armed(), 0);
}

#[test]
fn a_paneless_row_is_never_armed_at_start_with_every_switch_on() {
    let mut r = rig_with(Setup {
        options: every_switch_on(),
        rows: vec![AgentStateRow {
            session_id: "daemon".to_owned(),
            ..row_of("s-daemon", RowState::Done, T0 - 55.0 * MIN)
        }],
        ..Setup::default()
    });
    r.start();
    assert_eq!(r.armed(), 0);
    assert_eq!(r.engine.stop(), Ok(()));
}

#[test]
fn a_pane_agents_stop_posts_turn_done_with_every_switch_on() {
    let mut r = rig_with(Setup {
        options: every_switch_on(),
        ..Setup::default()
    });
    r.handle(r.now());
    let posts = r.notifier.posts();
    assert_eq!(posts.len(), 1);
    assert_eq!(
        (posts[0].kind, posts[0].id.as_str()),
        (NoticeKind::TurnDone, "tagents-12")
    );
}

#[test]
fn a_question_or_a_permission_prompt_raised_inside_a_subagent_is_its_agents_under_the_agents_id() {
    // A subagent's tool events carry its agent_id, and they block the agent that started it: the notice is that agent's, not suppressed.
    let mut r = rig();
    r.handle(
        r.now()
            .on(H::Notification)
            .agent("a1")
            .sub("permission_prompt")
            .text("Claude needs your permission to use Bash"),
    );
    r.handle(
        r.now()
            .in_pane("13")
            .session("sess-2")
            .on(H::PreToolUse)
            .agent("a2")
            .tool("AskUserQuestion")
            .text("Which one?"),
    );
    let posts = r.notifier.posts();
    let seen: Vec<(&str, &str)> = posts
        .iter()
        .map(|p| (p.kind.as_str(), p.id.as_str()))
        .collect();
    assert_eq!(
        seen,
        [("permission", "tagents-12"), ("question", "tagents-13")]
    );
}

#[test]
fn a_notifier_that_fails_is_logged_and_the_next_event_still_posts() {
    let mut r = rig();
    r.notifier
        .fail_posts(1, "the notification center is not answering");
    r.handle(r.now().on(H::Stop));
    assert!(r.notifier.posts().is_empty());
    assert_eq!(
        r.logged(),
        ["post failed turn_done 12 the notification center is not answering"]
    );
    r.handle(
        r.now()
            .on(H::Notification)
            .sub("permission_prompt")
            .text("Allow?"),
    );
    assert_eq!(r.notifier.posts().len(), 1);
}

#[test]
fn a_notice_is_one_log_line_its_kind_key_title_and_whether_it_was_shown() {
    let mut r = rig_with(Setup {
        screens: vec![("%12", hidden())],
        ..Setup::default()
    });
    r.handle(r.now());
    assert_eq!(r.logged(), ["notice turn_done 12 \"build agent\" shown"]);
    r.handle(r.now().on(H::UserPromptSubmit));
    assert_eq!(
        r.logged(),
        [
            "notice turn_done 12 \"build agent\" shown",
            "withdraw tagents-12"
        ]
    );
}

#[test]
fn the_title_in_the_notice_line_is_json_so_a_quote_or_a_newline_stays_on_one_line() {
    let mut r = rig();
    r.handle(r.now().label("say \"hi\"\nthere"));
    assert_eq!(
        r.logged(),
        ["notice turn_done 12 \"say \\\"hi\\\"\\nthere\" shown"]
    );
}

#[test]
fn a_notice_the_backend_dropped_without_a_reason_is_a_line_that_ends_dropped() {
    let mut r = rig();
    r.notifier.answer(false, None);
    r.handle(r.now());
    assert_eq!(r.logged(), ["notice turn_done 12 \"proj\" dropped"]);
    let mut empty = rig();
    empty.notifier.answer(false, Some(""));
    empty.handle(empty.now());
    assert_eq!(
        empty.logged(),
        ["notice turn_done 12 \"proj\" dropped"],
        "an empty reason is no reason"
    );
}

#[test]
fn a_notice_that_was_dropped_takes_down_the_one_on_screen_with_its_id() {
    let mut r = rig();
    r.handle(
        r.now()
            .on(H::Notification)
            .sub("permission_prompt")
            .text("Allow?"),
    );
    r.notifier.answer(false, Some("the pane is in front"));
    r.handle(r.now().on(H::Stop));
    assert_eq!(r.notifier.ops(), ["post", "post", "withdraw"]);
    assert_eq!(
        r.logged(),
        [
            "notice permission 12 \"proj\" shown",
            "notice turn_done 12 \"proj\" dropped: the pane is in front",
            "withdraw tagents-12"
        ]
    );
}

#[test]
fn a_withdrawal_the_backend_refuses_is_logged_with_its_id_and_the_reason() {
    let mut r = rig();
    r.handle(r.now());
    r.notifier.fail_withdraws("the center would not let go");
    r.handle(r.now().on(H::UserPromptSubmit));
    assert_eq!(
        r.logged(),
        [
            "notice turn_done 12 \"proj\" shown",
            "withdraw failed tagents-12 the center would not let go"
        ]
    );
}

#[test]
fn events_are_handled_one_at_a_time_in_the_order_they_arrived() {
    let mut r = rig();
    r.start();
    // What the notifier has been asked when the post of the turn is in flight: the prompt behind it has not run.
    let seen = Rc::new(RefCell::new(None));
    let notifier = r.notifier.clone();
    let record = seen.clone();
    r.notifier
        .during_post(move || *record.borrow_mut() = Some(notifier.calls().len()));
    r.feed.emit(r.now().on(H::Stop));
    r.feed.emit(r.now().on(H::UserPromptSubmit));
    r.wake();
    assert_eq!(*seen.borrow(), Some(0), "the prompt waits behind the post");
    assert_eq!(r.notifier.ops(), ["post", "withdraw"]);
}

#[test]
fn start_follows_the_feed_and_handles_what_it_delivers_stop_closes_the_follower_twice_over() {
    let mut r = rig();
    r.start();
    assert_eq!(r.feed.followers(), 1);
    r.feed.emit(r.now().on(H::Stop));
    r.wake();
    assert_eq!(r.notifier.posts().len(), 1);
    assert_eq!(r.engine.stop(), Ok(()));
    assert!(!r.feed.open());
    assert_eq!(r.armed(), 0);
    assert_eq!(r.engine.stop(), Ok(()));
    assert_eq!(
        r.feed.state.borrow().closes,
        1,
        "the second stop closes nothing again"
    );
}
