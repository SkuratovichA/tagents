//! The engine against a fake feed, notifier, clock and screen probe. The clock is the `FakeClock` of the tests and nothing sleeps: a test that waits for real time would be the flaky one. The loop of the service is the test: it moves the clock and calls `wake`, as the service calls it when `next_due` has elapsed or the watch has heard the events file.
//!
//! The 85 cases of `packages/notify/test/engine.test.ts`, numbered in file order, and the test that carries each.
//!
//! - 1 `notices::a_turn_that_ends_posts_one_notice_under_the_keys_id_and_the_sessions_thread`
//! - 2 `notices::the_title_is_the_label_typed_on_ctrl_r_when_there_is_one`
//! - 3 `notices::a_second_notice_for_one_key_reuses_its_id`
//! - 4 `notices::a_disabled_kind_posts_nothing_yet_its_turn_done_still_arms_the_cache_deadline`
//! - 5 `notices::the_kind_that_is_off_by_default_posts_nothing_until_it_is_turned_on`
//! - 6 `notices::skip_visible_with_the_pane_in_some_clients_window_skips_if_frontmost_with_that_clients_pid`
//! - 7 `notices::a_pane_nobody_is_looking_at_is_posted_with_no_skip_and_the_most_active_clients_pid`
//! - 8 `notices::skip_visible_off_posts_a_visible_pane_without_the_skip_still_with_its_client_for_the_click`
//! - 9 `notices::a_pane_tmux_does_not_know_is_posted_with_no_pid_named_by_its_label_or_directory`
//! - 10 `notices::a_probe_that_fails_costs_the_pid_not_the_notice_and_says_why`
//! - 11 `notices::a_prompt_withdraws_only_when_a_notice_is_up_for_that_key`
//! - 12 `notices::a_notice_that_the_backend_dropped_is_not_one_to_withdraw`
//! - 13 `notices::session_end_withdraws_the_notice_and_cancels_the_deadline`
//! - 14 `notices::with_session_end_on_the_end_of_a_session_withdraws_the_old_notice_and_then_posts_its_own`
//! - 15 `notices::the_click_dock_is_the_dashboards_enter_on_that_chat`
//! - 16 `notices::the_click_goto_is_the_agents_own_window`
//! - 17 `notices::the_click_focus_is_the_terminal_only`
//! - 18 `notices::the_click_env_is_path_and_home_plus_the_locale_and_the_variables_that_pick_the_tmux_server_state_and_config_when_they_are_set`
//! - 19 `notices::the_hostname_is_read_for_each_notice_a_title_that_was_the_host_is_a_name_once_the_host_is_renamed`
//! - 20 `notices::a_subagent_stop_posts_nothing_and_arms_nothing_with_every_switch_on`
//! - 21 `notices::a_child_sessions_stop_posts_nothing_with_every_switch_on`
//! - 22 `notices::a_paneless_headless_sessions_stop_posts_nothing_with_every_switch_on`
//! - 23 `notices::a_paneless_row_is_never_armed_at_start_with_every_switch_on`
//! - 24 `notices::a_pane_agents_stop_posts_turn_done_with_every_switch_on`
//! - 25 `notices::a_question_or_a_permission_prompt_raised_inside_a_subagent_is_its_agents_under_the_agents_id`
//! - 26 `notices::a_notifier_that_fails_is_logged_and_the_next_event_still_posts`
//! - 27 `notices::a_notice_is_one_log_line_its_kind_key_title_and_whether_it_was_shown`
//! - 28 `notices::events_are_handled_one_at_a_time_in_the_order_they_arrived`
//! - 29 `notices::start_follows_the_feed_and_handles_what_it_delivers_stop_closes_the_follower_twice_over`
//! - 30 `cache::a_turn_arms_one_deadline_and_a_prompt_cancels_it`
//! - 31 `cache::a_question_arms_one_too_and_a_subagent_finishing_does_not`
//! - 32 `cache::a_deadline_due_with_the_row_done_posts_cache_expiring_with_the_idle_and_the_left_minutes`
//! - 33 `cache::a_deadline_due_with_the_row_blocked_posts_too`
//! - 34 `cache::a_deadline_due_with_the_row_working_new_gone_or_missing_posts_nothing_and_is_dropped`
//! - 35 `cache::a_row_of_another_key_does_not_stand_in_for_this_one`
//! - 36 `cache::the_mac_sleeping_past_the_cache_ttl_leaves_no_notice_about_a_cache_that_is_already_gone`
//! - 37 `cache::the_mac_waking_three_minutes_past_the_due_time_gets_its_notice_on_the_first_wake`
//! - 38 `cache::a_deadline_that_fell_due_while_a_newer_turn_was_queued_ahead_of_it_is_stale_and_posts_nothing`
//! - 39 `cache::the_wait_is_never_longer_than_five_minutes`
//! - 40 `cache::start_arms_every_row_that_is_done_or_blocked_and_still_inside_the_ttl_and_each_posts_once`
//! - 41 `cache::start_leaves_a_row_that_is_already_past_the_ttl_alone_and_arms_nothing`
//! - 42 `cache::a_deadline_armed_from_a_row_is_composed_from_the_row_with_the_label_history_keeps`
//! - 43 `cache::nothing_is_pending_at_start_with_no_rows_and_nothing_fires_after_stop`
//! - 44 `cache::an_event_that_arrives_after_stop_arms_nothing`
//! - 45 `cache::with_cache_expiring_off_no_deadline_is_ever_armed`
//! - 46 `cache::the_options_are_read_again_at_every_event_so_turning_a_kind_off_takes_effect_at_once`
//! - 47 `cache::a_questions_deadline_falls_due_although_the_hook_wrote_the_row_as_working_for_it`
//! - 48 `cache::a_working_row_newer_than_the_question_means_the_turn_runs_again_and_no_cache_notice`
//! - 49 `cache::start_arms_a_row_that_is_working_on_a_question_nobody_answered_and_no_other_working_row`
//! - 50 `questions::a_permission_prompt_after_a_question_posts_nothing_replaces_nothing_and_leaves_the_questions_deadline`
//! - 51 `questions::the_answer_withdraws_the_question_and_a_permission_prompt_after_it_posts`
//! - 52 `questions::a_permission_prompt_with_no_question_pending_posts`
//! - 53 `questions::the_question_ends_with_the_answer_a_prompt_the_turn_the_session_start_or_the_session_end`
//! - 54 `questions::a_subagents_stop_and_another_keys_events_do_not_end_the_question`
//! - 55 `questions::an_elicitation_dialog_holds_nothing_back_it_has_no_answer_event_and_no_prompt_after_it`
//! - 56 `questions::a_permission_prompt_more_than_20_seconds_after_the_question_is_a_real_one_and_posts`
//! - 57 `questions::a_question_the_backend_dropped_or_that_is_switched_off_holds_nothing_back`
//! - 58 `questions::a_turn_done_the_backend_drops_takes_down_the_permission_notice_it_would_have_replaced`
//! - 59 `stopping::a_stop_tripped_in_the_middle_of_a_post_lets_that_post_land_and_drops_the_events_behind_it`
//! - 60 `stopping::a_stop_tripped_in_the_middle_of_a_probe_lets_that_notice_post_and_nothing_after`
//! - 61 `stopping::stop_with_nothing_in_flight_returns_at_once_and_stopping_twice_is_one_stop`
//! - 62 `stopping::a_stop_tripped_during_the_post_of_a_deadline_lets_it_land`
//! - 63 `stopping::start_that_cannot_follow_is_an_err_with_the_reason_and_leaves_no_deadline_armed`
//! - 64 `stopping::stop_closes_the_deadlines_even_when_the_follower_will_not_close`
//! - 65 `following::a_follower_that_dies_is_followed_again_after_a_second_and_its_events_are_heard`
//! - 66 `following::a_refollow_that_fails_waits_twice_as_long_up_to_5_minutes_and_a_follower_that_lived_longer_than_that_wait_starts_over_at_a_second`
//! - 67 `following::a_follower_that_dies_at_once_three_times_is_followed_after_1_2_and_4_seconds`
//! - 68 `following::a_follower_that_keeps_dying_at_once_is_followed_every_5_minutes_at_most`
//! - 69 `following::a_follower_that_heard_an_event_or_lived_longer_than_the_wait_before_it_starts_the_wait_over`
//! - 70 `following::after_a_refollow_the_state_rows_are_armed_again_what_the_events_said_while_it_was_dead_is_in_them`
//! - 71 `following::a_refollow_that_fails_arms_nothing_and_the_one_that_works_afterwards_arms_once`
//! - 72 `following::stop_cancels_a_refollow_that_is_waiting`
//! - 73 `following::a_follower_that_dies_after_stop_is_not_followed_again`
//! - 74 `following::the_refollow_wait_is_beside_the_deadline_and_start_while_dead_does_not_follow_twice`
//! - 75 `cache::no_cache_notice_for_a_pane_tmux_says_is_gone_and_the_reason_is_logged_other_notices_still_post`
//! - 76 `cache::a_tmux_that_did_not_answer_is_not_a_pane_that_is_gone_the_cache_notice_posts`
//! - 77 `order::a_deadline_that_fell_due_while_the_mac_slept_posts_on_the_next_wake_behind_the_lines_of_that_wake`
//! - 78 `order::an_event_of_the_sleeping_chat_itself_a_prompt_cancels_the_deadline_before_the_sweep_can_warn`
//! - 79 not applicable: `handle` is a `cfg(test)` hook of the tests, the service has only `wake`, and a wake always sweeps.
//! - 80 `order::a_failing_backend_is_logged_once_per_distinct_message_and_once_more_when_it_works_again`
//! - 81 `questions::a_new_session_in_the_pane_withdraws_what_the_old_one_asked_and_the_question_with_it`
//! - 82 `questions::a_pane_tmux_says_is_gone_drops_the_question_it_held_back_with_and_leaves_its_notices_up`
//! - 83 `cache::a_refollow_does_not_warn_again_about_a_key_it_already_warned_about`
//! - 84 `cache::a_row_written_after_the_warning_is_a_new_idle_period_and_the_refollow_arms_it`
//! - 85 `cache::a_prompt_or_a_new_turn_lets_a_key_be_warned_about_again`
//!
//! Case 62 (`stop` drains a deadline that fell due) has no async drain to wait for: the engine checks the stop between jobs, so a post in flight lands (`stopping::a_stop_tripped_during_the_post_of_a_deadline_lets_it_land`) and a deadline queued behind a tripped stop is dropped (`stopping::a_stop_tripped_during_a_post_drops_the_due_deadline_queued_behind_it`).

use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::rc::Rc;
use std::sync::Arc;

use super::*;
use crate::notify::clock::FakeClock;
use crate::notify::events::AgentHookEvent as H;
use crate::notify::log::RecordingLog;
use crate::notify::notifier::PostResult;
use crate::notify::phrases::{Locale, phrases_for};
use crate::testing::Scratch;

mod cache;
mod following;
mod notices;
mod order;
mod questions;
mod stopping;

/// A round number of epoch milliseconds, so row seconds convert without a remainder.
const T0: f64 = 1_700_000_000_000.0;
const MIN: f64 = 60_000.0;
const TAGENTS: &str = "/opt/checkout/tagents";
const BASE_ENV: [(&str, &str); 2] = [("PATH", "/usr/bin:/bin"), ("HOME", "/home/u")];

type Hook = Box<dyn FnOnce()>;

/// An event of the pane agent `%12`, a turn that ended, at `T0`.
fn event() -> AgentEvent {
    AgentEvent {
        at: T0,
        event: H::Stop,
        key: "12".to_owned(),
        session_id: "sess-1".to_owned(),
        agent_id: String::new(),
        pane: "%12".to_owned(),
        cwd: "/work/proj".to_owned(),
        transcript: String::new(),
        config_dir: String::new(),
        tool: String::new(),
        sub: String::new(),
        text: String::new(),
        label: String::new(),
    }
}

/// What a test changes of an event, by name.
trait Tweak {
    fn on(self, event: H) -> Self;
    fn at(self, ms: f64) -> Self;
    fn key(self, key: &str) -> Self;
    fn pane(self, pane: &str) -> Self;
    fn session(self, id: &str) -> Self;
    fn agent(self, id: &str) -> Self;
    fn cwd(self, cwd: &str) -> Self;
    fn tool(self, tool: &str) -> Self;
    fn sub(self, sub: &str) -> Self;
    fn text(self, text: &str) -> Self;
    fn label(self, label: &str) -> Self;
    /// The agent of pane `%<n>`: its key is the number.
    fn in_pane(self, n: &str) -> Self;
}

impl Tweak for AgentEvent {
    fn on(self, event: H) -> Self {
        AgentEvent { event, ..self }
    }
    fn at(self, at: f64) -> Self {
        AgentEvent { at, ..self }
    }
    fn key(self, key: &str) -> Self {
        AgentEvent {
            key: key.to_owned(),
            ..self
        }
    }
    fn pane(self, pane: &str) -> Self {
        AgentEvent {
            pane: pane.to_owned(),
            ..self
        }
    }
    fn session(self, id: &str) -> Self {
        AgentEvent {
            session_id: id.to_owned(),
            ..self
        }
    }
    fn agent(self, id: &str) -> Self {
        AgentEvent {
            agent_id: id.to_owned(),
            ..self
        }
    }
    fn cwd(self, cwd: &str) -> Self {
        AgentEvent {
            cwd: cwd.to_owned(),
            ..self
        }
    }
    fn tool(self, tool: &str) -> Self {
        AgentEvent {
            tool: tool.to_owned(),
            ..self
        }
    }
    fn sub(self, sub: &str) -> Self {
        AgentEvent {
            sub: sub.to_owned(),
            ..self
        }
    }
    fn text(self, text: &str) -> Self {
        AgentEvent {
            text: text.to_owned(),
            ..self
        }
    }
    fn label(self, label: &str) -> Self {
        AgentEvent {
            label: label.to_owned(),
            ..self
        }
    }
    fn in_pane(self, n: &str) -> Self {
        self.key(n).pane(&format!("%{n}"))
    }
}

/// A row of the pane agent `12`, done at `T0`.
fn row() -> AgentStateRow {
    AgentStateRow {
        key: "12".to_owned(),
        at: T0 / 1000.0,
        state: RowState::Done,
        session_id: "sess-1".to_owned(),
        cwd: "/work/proj".to_owned(),
        transcript: String::new(),
        detail: String::new(),
        config_dir: None,
    }
}

fn row_of(key: &str, state: RowState, at_ms: f64) -> AgentStateRow {
    AgentStateRow {
        key: key.to_owned(),
        at: at_ms / 1000.0,
        state,
        ..row()
    }
}

/// The options with `change` applied to the defaults.
fn options(change: impl FnOnce(&mut Options)) -> Options {
    let mut options = Options::default();
    change(&mut options);
    options
}

/// A file that turns on every switch it has: each `enabled`, `skip_visible` aside (it only ever holds a notice back).
fn every_switch_on() -> Options {
    options(|o| {
        o.events.question.enabled = true;
        o.events.permission.enabled = true;
        o.events.turn_done.enabled = true;
        o.events.cache_expiring.toggles.enabled = true;
        o.events.session_end.enabled = true;
    })
}

fn visible() -> ScreenAnswer {
    ScreenAnswer::Screen(Screen {
        visible: true,
        client_pid: Some(4242),
        pane_title: "✳ build agent".to_owned(),
    })
}

fn hidden() -> ScreenAnswer {
    ScreenAnswer::Screen(Screen {
        visible: false,
        client_pid: Some(777),
        pane_title: "✳ build agent".to_owned(),
    })
}

#[derive(Default)]
struct FeedState {
    rows: Vec<AgentStateRow>,
    /// Follows that worked.
    followers: usize,
    /// How many times each follow was asked, and at which clock reading.
    started_at: Vec<i64>,
    /// How many times a wake reached the feed.
    wakes: usize,
    /// How many times the end of a grace reached the feed.
    graces: usize,
    /// A follower is open: events emitted while none is open are lost, as the file's would be.
    open: bool,
    fail_follows: usize,
    /// What the next follow returns as appended meanwhile.
    on_start: Vec<AgentEvent>,
    /// The next follow finds its follower dead in the first read.
    start_death: Option<String>,
    /// What the next wake returns.
    pending: Vec<AgentEvent>,
    errors: Vec<String>,
    death: Option<String>,
    close_error: Option<String>,
    closes: usize,
    grace: Option<i64>,
    /// Reading the state rows panics with this.
    states_panic: Option<&'static str>,
}

/// A scripted feed over a directory of its own. Clones share one script, so the test and the engine see the same follower.
#[derive(Clone)]
struct FakeFeed {
    dir: String,
    state: Rc<RefCell<FeedState>>,
}

impl FakeFeed {
    fn new(dir: &str) -> FakeFeed {
        FakeFeed {
            dir: dir.to_owned(),
            state: Rc::default(),
        }
    }

    fn set_rows(&self, rows: Vec<AgentStateRow>) {
        self.state.borrow_mut().rows = rows;
    }

    /// The next `n` follows fail.
    fn fail_follows(&self, n: usize) {
        self.state.borrow_mut().fail_follows = n;
    }

    /// The follower hears a line; lost when no follower is open.
    fn emit(&self, e: AgentEvent) {
        let mut state = self.state.borrow_mut();
        if state.open {
            state.pending.push(e);
        }
    }

    /// The follower fails to read once, and goes on.
    fn error(&self, message: &str) {
        self.state.borrow_mut().errors.push(message.to_owned());
    }

    /// The follower dies as the real one does: it has closed itself, and the next wake reports it once.
    fn kill(&self, reason: &str) {
        let mut state = self.state.borrow_mut();
        state.open = false;
        state.death = Some(reason.to_owned());
    }

    fn followers(&self) -> usize {
        self.state.borrow().followers
    }

    fn open(&self) -> bool {
        self.state.borrow().open
    }
}

impl Feed for FakeFeed {
    fn dir(&self) -> &str {
        &self.dir
    }

    fn states(&self) -> Vec<AgentStateRow> {
        let state = self.state.borrow();
        if let Some(text) = state.states_panic {
            panic!("{text}");
        }
        state.rows.clone()
    }

    fn start(&mut self, now_ms: i64) -> Result<Delivery, String> {
        let mut state = self.state.borrow_mut();
        state.started_at.push(now_ms);
        if state.fail_follows > 0 {
            state.fail_follows -= 1;
            return Err("the events file cannot be watched".to_owned());
        }
        state.followers += 1;
        state.death = None;
        let death = state.start_death.take();
        state.open = death.is_none();
        Ok(Delivery {
            events: std::mem::take(&mut state.on_start),
            death,
            ..Delivery::default()
        })
    }

    fn wake(&mut self, _now_ms: i64) -> Delivery {
        let mut state = self.state.borrow_mut();
        state.wakes += 1;
        Delivery {
            events: std::mem::take(&mut state.pending),
            errors: std::mem::take(&mut state.errors),
            death: state.death.take(),
        }
    }

    fn end_grace(&mut self, _now_ms: i64) -> Delivery {
        self.state.borrow_mut().graces += 1;
        Delivery::default()
    }

    fn due(&self) -> Option<i64> {
        self.state.borrow().grace
    }

    fn close(&mut self) -> Option<String> {
        let mut state = self.state.borrow_mut();
        state.open = false;
        state.closes += 1;
        state.pending.clear();
        state.close_error.take()
    }
}

#[derive(Debug, Clone, PartialEq)]
enum Call {
    Post(Notice),
    Withdraw(String),
}

struct NotifierState {
    calls: Vec<Call>,
    /// What the posts answer.
    result: PostResult,
    failing: usize,
    failure: String,
    withdraw_failure: Option<String>,
    /// Run at the start of the next posts, one each: a notifier that takes its time, or that panics.
    during_post: VecDeque<Hook>,
}

/// A notifier that records, and answers as it is told. Clones share one record.
#[derive(Clone)]
struct FakeNotifier(Rc<RefCell<NotifierState>>);

impl FakeNotifier {
    fn new() -> FakeNotifier {
        FakeNotifier(Rc::new(RefCell::new(NotifierState {
            calls: Vec::new(),
            result: PostResult {
                shown: true,
                why: None,
            },
            failing: 0,
            failure: "the notification center is not answering".to_owned(),
            withdraw_failure: None,
            during_post: VecDeque::new(),
        })))
    }

    fn calls(&self) -> Vec<Call> {
        self.0.borrow().calls.clone()
    }

    fn posts(&self) -> Vec<Notice> {
        self.calls()
            .into_iter()
            .filter_map(|call| match call {
                Call::Post(notice) => Some(notice),
                Call::Withdraw(_) => None,
            })
            .collect()
    }

    fn kinds(&self) -> Vec<&'static str> {
        self.posts().iter().map(|n| n.kind.as_str()).collect()
    }

    fn withdrawn(&self) -> Vec<String> {
        self.calls()
            .into_iter()
            .filter_map(|call| match call {
                Call::Withdraw(id) => Some(id),
                Call::Post(_) => None,
            })
            .collect()
    }

    /// ops of every call, as `post` and `withdraw`.
    fn ops(&self) -> Vec<&'static str> {
        self.calls()
            .iter()
            .map(|call| match call {
                Call::Post(_) => "post",
                Call::Withdraw(_) => "withdraw",
            })
            .collect()
    }

    fn answer(&self, shown: bool, why: Option<&str>) {
        self.0.borrow_mut().result = PostResult {
            shown,
            why: why.map(str::to_owned),
        };
    }

    /// The next `n` posts fail with `message`.
    fn fail_posts(&self, n: usize, message: &str) {
        let mut state = self.0.borrow_mut();
        state.failing = n;
        state.failure = message.to_owned();
    }

    fn fail_withdraws(&self, message: &str) {
        self.0.borrow_mut().withdraw_failure = Some(message.to_owned());
    }

    /// Runs `hook` at the start of the next post that has none queued before it.
    fn during_post(&self, hook: impl FnOnce() + 'static) {
        self.0.borrow_mut().during_post.push_back(Box::new(hook));
    }
}

impl Notifier for FakeNotifier {
    fn name(&self) -> &str {
        "recording"
    }

    fn post(&mut self, notice: &Notice) -> Result<PostResult, String> {
        let hook = self.0.borrow_mut().during_post.pop_front();
        if let Some(run) = hook {
            run();
        }
        let mut state = self.0.borrow_mut();
        if state.failing > 0 {
            state.failing -= 1;
            return Err(state.failure.clone());
        }
        state.calls.push(Call::Post(notice.clone()));
        Ok(state.result.clone())
    }

    fn withdraw(&mut self, id: &str) -> Result<(), String> {
        let mut state = self.0.borrow_mut();
        state.calls.push(Call::Withdraw(id.to_owned()));
        state.withdraw_failure.clone().map_or(Ok(()), Err)
    }
}

#[derive(Default)]
struct ScreenState {
    table: HashMap<String, Result<Option<ScreenAnswer>, String>>,
    probed: Vec<String>,
    /// Run at the start of the next probes, one each.
    during: VecDeque<Hook>,
}

/// A probe answering from a table. A pane that is not in it is one tmux did not answer for.
#[derive(Clone, Default)]
struct FakeScreen(Rc<RefCell<ScreenState>>);

impl FakeScreen {
    fn answer(&self, pane: &str, answer: ScreenAnswer) {
        self.0
            .borrow_mut()
            .table
            .insert(pane.to_owned(), Ok(Some(answer)));
    }

    fn fail(&self, pane: &str, why: &str) {
        self.0
            .borrow_mut()
            .table
            .insert(pane.to_owned(), Err(why.to_owned()));
    }

    fn probed(&self) -> Vec<String> {
        self.0.borrow().probed.clone()
    }

    fn during_probe(&self, hook: impl FnOnce() + 'static) {
        self.0.borrow_mut().during.push_back(Box::new(hook));
    }

    fn probe(&self) -> ScreenProbe<'static> {
        let screen = self.clone();
        Box::new(move |pane| {
            let hook = {
                let mut state = screen.0.borrow_mut();
                state.probed.push(pane.to_owned());
                state.during.pop_front()
            };
            if let Some(run) = hook {
                run();
            }
            screen
                .0
                .borrow()
                .table
                .get(pane)
                .cloned()
                .unwrap_or(Ok(None))
        })
    }
}

/// What a test sets before the engine is built.
struct Setup {
    options: Options,
    screens: Vec<(&'static str, ScreenAnswer)>,
    env: Vec<(&'static str, &'static str)>,
    rows: Vec<AgentStateRow>,
}

impl Default for Setup {
    fn default() -> Self {
        Setup {
            options: Options::default(),
            screens: Vec::new(),
            env: BASE_ENV.to_vec(),
            rows: Vec::new(),
        }
    }
}

struct Rig {
    engine: Engine<'static>,
    feed: FakeFeed,
    notifier: FakeNotifier,
    screen: FakeScreen,
    clock: FakeClock,
    log: RecordingLog,
    stop: Stop,
    /// What the engine reads as the host's name, which a test renames.
    host: Rc<RefCell<String>>,
    /// Where the feed's labels live.
    dir: Scratch,
}

fn rig() -> Rig {
    rig_with(Setup::default())
}

fn rig_with(setup: Setup) -> Rig {
    let dir = Scratch::new();
    let feed = FakeFeed::new(dir.dir());
    feed.set_rows(setup.rows);
    let notifier = FakeNotifier::new();
    let clock = FakeClock::new(T0);
    let screen = FakeScreen::default();
    for (pane, answer) in setup.screens {
        screen.answer(pane, answer);
    }
    let log = RecordingLog::new();
    let stop = Stop::default();
    let host = Rc::new(RefCell::new("mbp.local".to_owned()));
    let engine = Engine::new(EngineDeps {
        feed: Box::new(feed.clone()),
        notifier: Box::new(notifier.clone()),
        options: setup.options,
        screen: screen.probe(),
        clock: Box::new(clock.clone()),
        log: Arc::new(log.clone()),
        tagents: TAGENTS.to_owned(),
        hostname: {
            let host = host.clone();
            Box::new(move || host.borrow().clone())
        },
        env: setup
            .env
            .iter()
            .map(|(name, value)| ((*name).to_owned(), (*value).to_owned()))
            .collect(),
        phrases: phrases_for(Locale::En),
        stop: stop.clone(),
    });
    Rig {
        engine,
        feed,
        notifier,
        screen,
        clock,
        log,
        stop,
        host,
        dir,
    }
}

impl Rig {
    /// A turn that ended, stamped with the clock's now.
    fn now(&self) -> AgentEvent {
        event().at(self.clock.now_ms())
    }

    /// The question tool's PreToolUse, stamped with the clock's now.
    fn ask(&self) -> AgentEvent {
        self.now()
            .on(H::PreToolUse)
            .tool("AskUserQuestion")
            .text("Which one?")
    }

    /// The generic permission prompt, stamped with the clock's now.
    fn permission(&self) -> AgentEvent {
        self.now()
            .on(H::Notification)
            .sub("permission_prompt")
            .text("Claude needs your permission")
    }

    /// An event that reaches the engine without the follower.
    fn handle(&mut self, e: AgentEvent) {
        self.engine.handle(e);
    }

    /// What the loop does when the watch has heard the file or `next_due` has elapsed.
    fn wake(&mut self) {
        self.engine.wake();
    }

    /// The clock moves, and the loop wakes the engine.
    fn advance(&mut self, ms: f64) {
        self.clock.advance(ms);
        self.engine.wake();
    }

    /// The loop with nothing heard: it sleeps as long as `next_due` says and wakes the engine. The wait it slept.
    fn sleep(&mut self) -> Duration {
        let wait = self.engine.next_due().unwrap_or_default();
        self.advance(wait.as_secs_f64() * 1000.0);
        wait
    }

    /// The follower dies, and the wake that finds it out.
    fn kill(&mut self, why: &str) {
        self.feed.kill(why);
        self.wake();
    }

    /// `start`, and the first call of the loop after it, which runs what `start` left: an overdue deadline and the lines of the first read make `next_due` immediate, and the loop calls `tick` at once.
    fn start(&mut self) {
        self.engine.start().unwrap();
        if self.engine.next_due() == Some(Duration::ZERO) {
            self.engine.tick();
        }
    }

    /// Deadlines that are armed.
    fn armed(&self) -> usize {
        self.engine.deadlines.armed()
    }

    fn logged(&self) -> Vec<String> {
        self.log.lines()
    }
}
