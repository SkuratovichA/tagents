//! The engine of the notify daemon: agent events in, notices out, and the prompt-cache deadlines in between (`createEngine` of `packages/notify/src/engine.ts`). It knows no platform: a `Feed`, a `Notifier`, the options, a clock and a screen probe are everything it touches, which is also what makes it testable with five fakes and no sleeping.
//!
//! It is a plain struct with no thread, no channel and no timer. The service's loop calls it: `start` once, `wake` when the watch says the events file changed and when `next_due` has elapsed, `reload` with new options, `stop` once. Each call runs every job it makes before it returns, so the loop serves one message at a time, as node's promise chain runs events and due deadlines one at a time.
//!
//! The order is node's. One FIFO queue of jobs: at each wake the follower's lines are ingested, each a job at the back of the queue and each followed by a sweep of the deadlines that are due, so with two lines and a due key the first line runs, then the due key, then the second line, and a prompt that cancels a key is seen before that key's cache notice runs (`engine.ts:399-408`). A wake that brought no line sweeps once, as node's deadline timer does. A deadline that passes while a post is in flight loses to a prompt line that is in the file when the post ends, where node, whose timer enqueued the due job first, posts: the engine is blocked in the post and cannot order the two after the fact (a known difference, pinned by `a_deadline_that_passes_during_a_post_loses_to_the_prompt_that_is_in_the_file_when_it_ends`).
//!
//! Time comes only from the `Clock` and a deadline is a wall-clock time, so `next_due` is when the loop must call `wake` though nothing was heard, and a loop that sleeps through it is late by the sleep, never wrong. A signal is the `Stop` of the service: it is checked between jobs, never inside one, so a post in flight lands and the jobs behind it are dropped.

use std::any::Any;
use std::collections::{HashMap, HashSet, VecDeque};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use std::time::Duration;

use crate::ending::Stop;
use crate::js;
use crate::json::quote;
use crate::notify::clock::Clock;
use crate::notify::compose::{Extra, NameInputs, agent_name, compose};
use crate::notify::deadlines::Deadlines;
use crate::notify::events::{AgentEvent, AgentHookEvent, Delivery};
use crate::notify::feed::Feed;
use crate::notify::kinds::{NoticeKind, QUESTION_TOOLS, classify, counts_session};
use crate::notify::log::Log;
use crate::notify::notifier::{ClickAction, Notice, Notifier};
use crate::notify::options::{CacheExpiring, Click, Events, Options, Toggles};
use crate::notify::phrases::Phrases;
use crate::notify::screen::{Screen, ScreenAnswer, tmux_screen};
use crate::notify::state::{AgentStateRow, RowState, labels_by_session, read_labels};

#[cfg(test)]
mod tests;

const MINUTE_MS: f64 = 60_000.0;

// A dead follower is followed again after a second, then two, and so on up to five minutes. A follower that has proven itself starts the count over.
const REFOLLOW_MIN_MS: f64 = 1000.0;
const REFOLLOW_MAX_MS: f64 = 5.0 * MINUTE_MS;

// Claude Code follows a question with a permission prompt of its own about six seconds later. A prompt that comes later than this is a real one: a plan that was rejected fires no PostToolUse, and the model may go on to ask for a tool.
const QUESTION_PROMPT_WINDOW_MS: f64 = 20_000.0;

// What a click needs to find the same tmux server, state and config the engine was started with: a click runs under the notification center, not under this process, so it inherits none of it. Nothing else is passed on. The locale is on the list because tmux renders non-ASCII as `_` outside a UTF-8 one, and an agent's name is often not ASCII. The config is three variables because lib/tagents/config.sh looks for it in TA_CONFIG, then XDG_CONFIG_HOME, and the dashboard has the same ones.
const CLICK_ENV: [&str; 10] = [
    "PATH",
    "HOME",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TMUX_TMPDIR",
    "TA_STATE_DIR",
    "TAGENTS_CONFIG_DIR",
    "XDG_CONFIG_HOME",
    "TA_CONFIG",
];

/// The screen probe: what tmux says of a pane, or why it could not be asked. `Ok(None)` is tmux not answering, which is not a pane that is gone (`ScreenAnswer::NoSuchPane`). An `Err` is logged as `screen probe failed` and the notice goes on without the screen.
pub type ScreenProbe<'a> = Box<dyn Fn(&str) -> Result<Option<ScreenAnswer>, String> + 'a>;

/// The probe over a real tmux (`tmuxScreen`). It runs with a stop of its own that nothing trips: a signal during a probe lets the probe end, and the engine drops the jobs behind it.
pub fn tmux_probe(pane: &str) -> Result<Option<ScreenAnswer>, String> {
    Ok(tmux_screen(pane, &Stop::default()))
}

/// What the engine is made of (`EngineDeps`).
pub struct EngineDeps<'a> {
    pub feed: Box<dyn Feed + 'a>,
    pub notifier: Box<dyn Notifier + 'a>,
    /// The options in force; `Engine::reload` replaces them and the next job reads the new ones.
    pub options: Options,
    pub screen: ScreenProbe<'a>,
    pub clock: Box<dyn Clock + 'a>,
    pub log: Arc<dyn Log>,
    /// The absolute path of the `tagents` script a click runs.
    pub tagents: String,
    /// A function: macOS renames the host with the network, so each notice reads it afresh.
    pub hostname: Box<dyn Fn() -> String + 'a>,
    /// Where the click's PATH, HOME, locale, TMUX_TMPDIR, TA_STATE_DIR and the config variables come from.
    pub env: Vec<(String, String)>,
    /// The words of a notice, in the locale of the service.
    pub phrases: &'static Phrases,
    /// Tripped by the signal thread: the engine drops the jobs that wait once it is.
    pub stop: Stop,
}

enum Job {
    Event(Box<AgentEvent>),
    /// A key whose deadline came, with the idle-since it was armed with.
    Due(String, f64),
}

/// A re-follow that waits for its time, after a death or after a follow that failed.
#[derive(Clone, Copy)]
struct Refollow {
    /// The clock reading at which to follow again.
    at: f64,
    /// The wait that ended at `at`, which the follower that comes of it has to outlive to count as having proven itself.
    wait: f64,
}

pub struct Engine<'a> {
    feed: Box<dyn Feed + 'a>,
    notifier: Box<dyn Notifier + 'a>,
    options: Options,
    screen: ScreenProbe<'a>,
    clock: Box<dyn Clock + 'a>,
    log: Arc<dyn Log>,
    tagents: String,
    hostname: Box<dyn Fn() -> String + 'a>,
    env: Vec<(String, String)>,
    phrases: &'static Phrases,
    stop: Stop,
    /// Ids of the notices on screen, as far as the backend told us.
    up: HashSet<String>,
    /// Keys with a question notice on screen that nobody has answered, and when it was asked.
    questions: HashMap<String, f64>,
    /// When a cache warning went out for a key, so that arming from the state rows does not send it twice.
    warned_at: HashMap<String, f64>,
    /// What a failing backend has said since a post last worked, so that each message is logged once.
    post_failures: HashSet<String>,
    /// The event that armed each key's deadline: the notice is composed from it when the deadline falls due.
    armed_by: HashMap<String, AgentEvent>,
    deadlines: Deadlines,
    queue: VecDeque<Job>,
    /// A follower is open.
    following: bool,
    refollow: Option<Refollow>,
    refollow_after: f64,
    followed_at: f64,
    followed_after: f64,
    heard: bool,
    /// Set by `stop`, with what it returned, which a second `stop` returns again.
    stopped: Option<Result<(), String>>,
}

/// `OPEN_QUESTION`: the hook writes the PreToolUse of a question as a `working` row whose detail is the tool's name, and the PostToolUse of the same call as "<tool> ✓". The first is a question nobody has answered yet, which is a wait like any other. It is `^(?:AskUserQuestion|ExitPlanMode)(?: (?!✓$).*)?$` without the `s` flag, where `.` stops at a line terminator.
fn is_open_question(detail: &str) -> bool {
    QUESTION_TOOLS
        .iter()
        .filter_map(|tool| detail.strip_prefix(tool))
        .any(|rest| {
            rest.is_empty()
                || rest.strip_prefix(' ').is_some_and(|text| {
                    text != "✓" && !text.contains(['\n', '\r', '\u{2028}', '\u{2029}'])
                })
        })
}

/// `noticeId`: the id a notice goes up under; a notice with the same id replaces the one on screen, so an agent has one notice at a time, saying the latest thing.
fn notice_id(key: &str) -> String {
    format!("tagents-{key}")
}

/// `clickFor`: what a click on the notice runs, with the variables of `CLICK_ENV` that are set to something. No pane, nothing to dock or go to: the click only raises the terminal.
fn click_for(e: &AgentEvent, mode: Click, tagents: &str, env: &[(String, String)]) -> ClickAction {
    let env = CLICK_ENV
        .iter()
        .filter_map(|name| {
            let (_, value) = env.iter().find(|(key, _)| key == name)?;
            (!value.is_empty()).then(|| ((*name).to_owned(), value.clone()))
        })
        .collect();
    let argv = match mode {
        _ if e.pane.is_empty() => Vec::new(),
        Click::Focus => Vec::new(),
        Click::Goto => vec![tagents.to_owned(), "--goto".to_owned(), e.pane.clone()],
        Click::Dock => [
            tagents,
            "--act",
            "open",
            &e.pane,
            "live",
            &e.session_id,
            &e.cwd,
        ]
        .map(str::to_owned)
        .to_vec(),
    };
    ClickAction { argv, env }
}

/// `eventFromRow`: the state row carries what an event would, enough to compose the notice and to click through to the right pane. Its `at` is epoch seconds, while an event's is milliseconds (the hook writes seconds and the parser multiplies).
fn event_from_row(row: &AgentStateRow, labels: &HashMap<String, String>) -> AgentEvent {
    let is_pane = !row.key.is_empty() && row.key.bytes().all(|b| b.is_ascii_digit());
    AgentEvent {
        at: row.at * 1000.0,
        event: if row.state == RowState::Blocked {
            AgentHookEvent::Notification
        } else {
            AgentHookEvent::Stop
        },
        key: row.key.clone(),
        session_id: row.session_id.clone(),
        agent_id: String::new(),
        pane: if is_pane {
            format!("%{}", row.key)
        } else {
            String::new()
        },
        cwd: row.cwd.clone(),
        transcript: row.transcript.clone(),
        config_dir: row.config_dir.clone().unwrap_or_default(),
        tool: String::new(),
        sub: String::new(),
        text: row.detail.clone(),
        label: labels.get(&row.session_id).cloned().unwrap_or_default(),
    }
}

/// The switches of one kind.
fn toggles_of(events: &Events, kind: NoticeKind) -> Toggles {
    match kind {
        NoticeKind::Question => events.question,
        NoticeKind::Permission => events.permission,
        NoticeKind::TurnDone => events.turn_done,
        NoticeKind::CacheExpiring => events.cache_expiring.toggles,
        NoticeKind::SessionEnd => events.session_end,
    }
}

/// What a panic said, for the line `describe(err)` gives in node.
fn panic_text(payload: &(dyn Any + Send)) -> String {
    payload
        .downcast_ref::<&str>()
        .map(|text| (*text).to_owned())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "panic".to_owned())
}

/// The time to wait for a clock reading, never negative.
fn until(at: f64, now: f64) -> Duration {
    Duration::from_secs_f64((at - now).max(0.0) / 1000.0)
}

impl<'a> Engine<'a> {
    pub fn new(deps: EngineDeps<'a>) -> Self {
        Engine {
            feed: deps.feed,
            notifier: deps.notifier,
            options: deps.options,
            screen: deps.screen,
            clock: deps.clock,
            log: deps.log,
            tagents: deps.tagents,
            hostname: deps.hostname,
            env: deps.env,
            phrases: deps.phrases,
            stop: deps.stop,
            up: HashSet::new(),
            questions: HashMap::new(),
            warned_at: HashMap::new(),
            post_failures: HashSet::new(),
            armed_by: HashMap::new(),
            deadlines: Deadlines::new(),
            queue: VecDeque::new(),
            following: false,
            refollow: None,
            refollow_after: REFOLLOW_MIN_MS,
            followed_at: 0.0,
            followed_after: 0.0,
            heard: false,
            stopped: None,
        }
    }

    /// `start()`: follows the feed and arms what the state rows say is waiting, then runs the jobs that makes. An `Err` is the text node's `start` throws (the follow failed, so nothing is armed), and the service then stops the engine and hands over to node. Nothing happens after `stop`, or while a follower is open or a re-follow is waiting.
    pub fn start(&mut self) -> Result<(), String> {
        if self.stopped.is_some() || self.following || self.refollow.is_some() {
            return Ok(());
        }
        // Follow first: if it fails there is nothing armed to leave behind.
        self.follow(0.0)?;
        self.caught(Self::arm_from_states)?;
        self.sweep();
        self.run();
        Ok(())
    }

    /// What the service calls when the watch says the events file changed, and when `next_due` has elapsed: follows again when the time has come, takes in what the follower found, sweeps the deadlines (a wake that brought no line is node's deadline timer) and runs every job that makes. A call with nothing to do is cheap and harmless, so a spurious wake costs nothing.
    pub fn wake(&mut self) {
        if self.stopped.is_some() {
            return;
        }
        if let Some(refollow) = self.refollow
            && self.now() >= refollow.at
        {
            self.refollow = None;
            self.follow_again(refollow.wait);
        }
        let delivery = self.feed.wake(self.now() as i64);
        self.ingest(delivery);
        self.sweep();
        self.run();
    }

    /// How long the loop may block before it must call `wake`: until the earliest of the cache deadlines (never more than `deadlines::MAX_SLEEP_MS`), the end of the grace of a rotated events file and the re-follow of a dead follower. `None` when nothing waits, and after `stop`. A wake that comes sooner does no harm.
    pub fn next_due(&self) -> Option<Duration> {
        if self.stopped.is_some() {
            return None;
        }
        let now = self.now();
        [
            self.deadlines.wait(now),
            self.feed.due().map(|at| until(at as f64, now)),
            self.refollow.map(|refollow| until(refollow.at, now)),
        ]
        .into_iter()
        .flatten()
        .min()
    }

    /// The options file was read again: the next job reads the new options, as node's `options()` is read at each event.
    pub fn reload(&mut self, options: Options) {
        self.options = options;
    }

    /// `stop()`: stops following and arming, and drops the jobs that wait. A post that was in flight has landed by now, since a call of the engine runs its jobs to the end. `Err` is the text node's `stop` rejects with, the follower that would not close, after the same cleanup. A second call does nothing and returns what the first returned.
    pub fn stop(&mut self) -> Result<(), String> {
        if let Some(done) = &self.stopped {
            return done.clone();
        }
        let closed = self.feed.close();
        self.following = false;
        self.refollow = None;
        self.queue.clear();
        self.deadlines = Deadlines::new();
        self.armed_by.clear();
        self.questions.clear();
        self.warned_at.clear();
        let done = closed.map_or(Ok(()), Err);
        self.stopped = Some(done.clone());
        done
    }

    fn now(&self) -> f64 {
        self.clock.now_ms()
    }

    fn say(&self, parts: &[&str]) {
        self.log.line(parts);
    }

    /// Runs `f` and turns a panic into the text of an error: a job that fails is logged and the next one goes on, as `enqueue` of node does.
    fn caught<T>(&mut self, f: impl FnOnce(&mut Self) -> T) -> Result<T, String> {
        catch_unwind(AssertUnwindSafe(|| f(self))).map_err(|payload| panic_text(payload.as_ref()))
    }

    /// Runs the jobs in the queue in order, and drops what is left once the service's stop is tripped, between two jobs and never inside one.
    fn run(&mut self) {
        while let Some(job) = self.queue.pop_front() {
            if self.stopped.is_some() || self.stop.is_stopped() {
                self.queue.clear();
                return;
            }
            if let Err(why) = self.caught(|engine| engine.job(job)) {
                self.say(&["error", &why]);
            }
        }
    }

    fn job(&mut self, job: Job) {
        match job {
            Job::Event(e) => self.step(&e),
            Job::Due(key, idle_since) => self.due(&key, idle_since),
        }
    }

    /// What a delivery of the follower becomes: each line is a job at the back of the queue with the due deadlines right behind it (the follow callback of `engine.ts:399-408` handles a line and sweeps), and its errors and its death are logged at once, before any job runs, as node's callbacks write them while the jobs wait their turn.
    fn ingest(&mut self, delivery: Delivery) {
        for e in delivery.events {
            self.heard = true;
            self.queue.push_back(Job::Event(Box::new(e)));
            self.sweep();
        }
        for message in &delivery.errors {
            self.say(&["feed error", message]);
        }
        if let Some(message) = delivery.death {
            self.on_dead(&message);
        }
    }

    /// The process is awake, so looking costs no wake: after a Mac sleep the first wake of any kind brings out the warnings that fell due meanwhile. Behind the jobs already queued, so a prompt that cancels a key is seen first.
    fn sweep(&mut self) {
        let now = self.now();
        self.queue.extend(
            self.deadlines
                .take_due(now)
                .into_iter()
                .map(|due| Job::Due(due.key, due.idle_since)),
        );
    }

    /// `follow(precededBy)`: `preceded_by` is the wait before this follow (none for the first), which a follower has to outlive to count as having proven itself.
    fn follow(&mut self, preceded_by: f64) -> Result<(), String> {
        let delivery = self.feed.start(self.now() as i64)?;
        self.following = true;
        // A follower that died in its first read has already been counted out by `ingest`.
        self.ingest(delivery);
        self.followed_at = self.now();
        self.followed_after = preceded_by;
        self.heard = false;
        Ok(())
    }

    /// The re-follow whose time has come: the events that landed while the follower was dead are lost, and the state rows are what is left of them, so they arm what the events would have.
    fn follow_again(&mut self, wait: f64) {
        if let Err(why) = self.follow(wait) {
            let next = self.refollow_soon();
            self.say(&[
                "follow failed",
                &why,
                &format!("trying again in {}s", js::number_text(next / 1000.0)),
            ]);
            return;
        }
        if let Err(why) = self.caught(Self::arm_from_states) {
            self.say(&["arming from the state rows failed", &why]);
        }
    }

    /// The re-follow timer, which exists only while the follower is dead and is then the only thing that can bring the engine back. It returns the wait.
    fn refollow_soon(&mut self) -> f64 {
        let wait = self.refollow_after;
        self.refollow_after = (wait * 2.0).min(REFOLLOW_MAX_MS);
        self.refollow = Some(Refollow {
            at: self.now() + wait,
            wait,
        });
        wait
    }

    fn on_dead(&mut self, message: &str) {
        // The feed counted the follower out before it said so: nothing to close.
        self.following = false;
        // A follow that returns proves nothing: a watch that fails at once would be followed again every second. The wait starts over only for a follower that heard an event, or that lived longer than the wait before it.
        if self.heard || self.now() - self.followed_at > self.followed_after {
            self.refollow_after = REFOLLOW_MIN_MS;
        }
        let wait = self.refollow_soon();
        self.say(&[
            "feed follower died",
            message,
            &format!("following again in {}s", js::number_text(wait / 1000.0)),
        ]);
    }

    /// `armFromStates`: a restart must not forget the sessions that were already idle, so every one whose cache is still alive is armed from the state rows the hooks keep.
    fn arm_from_states(&mut self) {
        let cache = self.options.events.cache_expiring;
        if !cache.toggles.enabled {
            return;
        }
        let now = self.now();
        let labels = labels_by_session(self.feed.dir());
        for row in self.feed.states() {
            let waiting = matches!(row.state, RowState::Done | RowState::Blocked)
                || (row.state == RowState::Working && is_open_question(&row.detail));
            if !waiting || !counts_session(&row.key) {
                continue;
            }
            let idle_since = row.at * 1000.0;
            if now - idle_since >= cache.ttl_ms {
                continue;
            }
            // Warned already for this idle period: a row nobody has written since the warning is the same period (its `at` is not the event's, since the idle ping rewrites it a minute after the Stop, so the two are not compared).
            if self
                .warned_at
                .get(&row.key)
                .is_some_and(|warned| idle_since <= *warned)
            {
                continue;
            }
            self.armed_by
                .insert(row.key.clone(), event_from_row(&row, &labels));
            self.deadlines
                .arm(&row.key, idle_since, idle_since + cache.after_ms);
        }
    }

    fn arm(&mut self, e: &AgentEvent, cache: &CacheExpiring) {
        // No notice would come of it, so no timer either: "no timer at all while nothing is armed".
        if self.stopped.is_some() || !cache.toggles.enabled {
            return;
        }
        self.armed_by.insert(e.key.clone(), e.clone());
        self.warned_at.remove(&e.key);
        self.deadlines.arm(&e.key, e.at, e.at + cache.after_ms);
    }

    /// `step`: what one event does.
    fn step(&mut self, e: &AgentEvent) {
        if self.stopped.is_some() {
            return;
        }
        let events = self.options.events;
        let Some(verdict) = classify(e) else {
            return;
        };
        // That prompt's generic text would replace the question's, and the question is the wait: the deadline it armed stays armed.
        if verdict.kind == Some(NoticeKind::Permission)
            && self
                .questions
                .get(&e.key)
                .is_some_and(|asked_at| e.at - asked_at <= QUESTION_PROMPT_WINDOW_MS)
        {
            self.say(&[
                "permission prompt held back by the question on screen",
                &e.key,
            ]);
            return;
        }
        // The answer, a prompt, the end of the turn or of the session: nothing is asked any more.
        if verdict.cancel || verdict.kind == Some(NoticeKind::TurnDone) {
            self.questions.remove(&e.key);
        }
        if verdict.cancel {
            self.deadlines.cancel(&e.key);
            self.armed_by.remove(&e.key);
            self.warned_at.remove(&e.key);
        }
        if verdict.withdraw {
            self.take_down(&notice_id(&e.key));
        }
        // A kind that is switched off posts nothing, but the person is still waiting on the session and the prompt cache's clock still runs.
        if verdict.arms {
            self.arm(e, &events.cache_expiring);
        }
        let Some(kind) = verdict.kind else {
            return;
        };
        let toggles = toggles_of(&events, kind);
        if !toggles.enabled {
            return;
        }
        let extra = Extra {
            plan: verdict.plan,
            ..Extra::default()
        };
        self.post(kind, e, &extra, toggles.skip_visible);
    }

    /// `due`: a cache deadline came.
    fn due(&mut self, key: &str, idle_since: f64) {
        // This job waited its turn in the queue. If a prompt cancelled the key, or a newer turn re-armed it with an idle-since of its own, the newer deadline has its own wake and this one is stale.
        let Some(e) = self.armed_by.get(key).cloned() else {
            return;
        };
        if self.stopped.is_some() || e.at != idle_since {
            return;
        }
        self.armed_by.remove(key);
        let cache = self.options.events.cache_expiring;
        if !cache.toggles.enabled || !counts_session(key) {
            return;
        }
        let row = self.feed.states().into_iter().find(|row| row.key == key);
        // The session is over, or a turn is running (its Stop re-arms). The hook writes `working` for the question that armed this very deadline, so a working row counts as a turn only when it is newer than that event.
        let Some(row) = row else {
            return;
        };
        if matches!(row.state, RowState::New | RowState::Gone) {
            return;
        }
        if row.state == RowState::Working && row.at * 1000.0 > idle_since {
            return;
        }
        let now = self.now();
        // The cache is gone already, perhaps because the Mac slept through its TTL.
        if now - idle_since >= cache.ttl_ms {
            return;
        }
        let extra = Extra {
            plan: false,
            idle_min: Some(js::round((now - idle_since) / MINUTE_MS)),
            left_min: Some(js::round((idle_since + cache.ttl_ms - now) / MINUTE_MS)),
        };
        if self.post(
            NoticeKind::CacheExpiring,
            &e,
            &extra,
            cache.toggles.skip_visible,
        ) {
            self.warned_at.insert(key.to_owned(), now);
        }
    }

    /// `probe`: `None` for a pane that is not asked about, and for one that could not be asked. Losing the click's terminal is cheaper than losing the notice.
    fn probe(&self, pane: &str) -> Option<ScreenAnswer> {
        if pane.is_empty() {
            return None;
        }
        match (self.screen)(pane) {
            Ok(answer) => answer,
            Err(why) => {
                self.say(&["screen probe failed", pane, &why]);
                None
            }
        }
    }

    /// `assemble`: the one place a `Notice` is made from an event.
    fn assemble(
        &self,
        kind: NoticeKind,
        e: &AgentEvent,
        extra: &Extra,
        skip_visible: bool,
        screen: Option<&Screen>,
    ) -> Notice {
        let hostname = (self.hostname)();
        let labels = read_labels(self.feed.dir());
        let name = agent_name(&NameInputs {
            session_id: &e.session_id,
            pane: &e.pane,
            pane_title: screen.map_or("", |screen| &screen.pane_title),
            label: &e.label,
            cwd: &e.cwd,
            hostname: &hostname,
            labels: &labels,
        });
        let composed = compose(kind, e, &name, extra, self.phrases);
        Notice {
            id: notice_id(&e.key),
            thread: e.session_id.clone(),
            kind,
            title: composed.title,
            subtitle: composed.subtitle,
            body: composed.body,
            click: click_for(e, self.options.click, &self.tagents, &self.env),
            terminal_pid: screen.and_then(|screen| screen.client_pid),
            skip_if_frontmost: (skip_visible && screen.is_some_and(|screen| screen.visible))
                .then_some(true),
        }
    }

    /// `post`: whether a notice was attempted that the backend answered for. `false` for a notice skipped for a pane that is gone and for a backend that failed.
    fn post(
        &mut self,
        kind: NoticeKind,
        e: &AgentEvent,
        extra: &Extra,
        skip_visible: bool,
    ) -> bool {
        let seen = self.probe(&e.pane);
        let pane_gone = seen == Some(ScreenAnswer::NoSuchPane);
        // The pane is gone and nobody told us (it was closed without a SessionEnd): nothing is asked there any more. Its notices stay, since a click resumes the chat by its session id, but a warning about its cache is not sent.
        if pane_gone {
            self.questions.remove(&e.key);
            if kind == NoticeKind::CacheExpiring {
                self.say(&[
                    "notice",
                    kind.as_str(),
                    &e.key,
                    &format!("skipped: tmux has no pane {}", e.pane),
                ]);
                return false;
            }
        }
        let screen = match &seen {
            Some(ScreenAnswer::Screen(screen)) => Some(screen),
            _ => None,
        };
        let notice = self.assemble(kind, e, extra, skip_visible, screen);
        let result = match self.notifier.post(&notice) {
            Ok(result) => result,
            Err(why) => {
                if self.post_failures.insert(why.clone()) {
                    self.say(&["post failed", kind.as_str(), &e.key, &why]);
                }
                return false;
            }
        };
        if !self.post_failures.is_empty() {
            self.post_failures.clear();
            self.say(&["posting works again"]);
        }
        if result.shown {
            self.up.insert(notice.id.clone());
            // Only the question tools get a PostToolUse and a prompt that follows: an MCP elicitation has neither, so it holds nothing back.
            if kind == NoticeKind::Question && e.event == AgentHookEvent::PreToolUse && !pane_gone {
                self.questions.insert(e.key.clone(), e.at);
            }
        }
        let outcome = match result.why.as_deref().filter(|why| !why.is_empty()) {
            _ if result.shown => "shown".to_owned(),
            Some(why) => format!("dropped: {why}"),
            None => "dropped".to_owned(),
        };
        self.say(&[
            "notice",
            kind.as_str(),
            &e.key,
            &quote(&notice.title),
            &outcome,
        ]);
        // A notice that was dropped (the pane is in front, say) leaves the old one with this id on screen, saying something that is no longer so.
        if !result.shown {
            self.take_down(&notice.id);
        }
        true
    }

    /// `takeDown`: withdraws a notice that is up, once.
    fn take_down(&mut self, id: &str) {
        if !self.up.remove(id) {
            return;
        }
        match self.notifier.withdraw(id) {
            Ok(()) => self.say(&["withdraw", id]),
            Err(why) => self.say(&["withdraw failed", id, &why]),
        }
    }

    /// `handle`: an event that reaches the engine without the follower, which does not sweep the deadlines.
    #[cfg(test)]
    fn handle(&mut self, e: AgentEvent) {
        self.queue.push_back(Job::Event(Box::new(e)));
        self.run();
    }
}
