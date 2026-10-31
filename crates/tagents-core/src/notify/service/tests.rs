//! The service of the notify daemon against a scratch state directory, a `Recorder` that arms nothing in place of the watch, a log that keeps its lines and a notifier that a test holds in the middle of a post. The loop of the service is the test: it sends the `Message`s the watch and the signal thread would send, and `serve` reads them in channel order. The processes that run `tagents-core notify run` are `tests/notify_service.rs`.
//!
//! Cases of `packages/notify/test/service.test.ts` that drive the service, one Rust test each (the lock cases are the tests of `lock.rs`, see its header):
//! - our lock is removed on stop, and stopping twice is one stop: `serve::a_stop_ends_with_the_stream_off_the_lock_released_and_exit_0`; stopping twice is `gate::the_stopping_line_is_written_once_by_the_signal_or_by_the_watch_that_ended`
//! - a lock someone else took over survives our stop: `serve::a_lock_that_is_not_ours_survives_the_stop`
//! - an invalid options file: each problem once, the defaults post a finished turn: `settings::each_problem_is_logged_once_however_often_the_file_is_read_and_a_valid_change_is_a_reload`, `settings::a_bad_file_runs_on_the_defaults_and_says_each_problem_at_the_start`
//! - a reload takes effect on the next event: `serve::an_options_wake_reloads_and_the_next_event_posts_nothing_for_a_kind_that_is_off`
//! - a reload to the value already running is ignored, a changed backend waits for a restart: `settings::a_reload_to_the_value_in_force_is_ignored_and_a_changed_backend_waits_for_a_restart`, `options_watch::the_same_value_in_other_words_and_an_unrelated_file_are_no_reload`
//! - the options directory may appear after the service started: `options_watch::a_directory_that_appears_later_is_adopted_and_watched_in_its_parents_place`
//! - a directory created between the first look and the arming of its parent: `options_watch::a_directory_made_between_the_look_and_the_arming_of_its_parent_is_found_and_armed_once`
//! - a file that changes between the first read and the arming is read once more: `options_watch::a_file_that_changes_between_the_first_read_and_the_arming_is_read_once_more`
//! - no config dir at all: reload is off, and `started` is said last: `options_watch::with_no_config_dir_reload_is_off`, `start::started_is_the_line_that_says_what_is_in_force`, and the order in a process: `notify_service::a_service_with_no_config_dir_says_reload_is_off_before_started`
//! - the options watch follows a symlinked config dir: `options_watch::a_symlinked_config_dir_is_armed_by_its_real_path_and_a_change_wakes_the_loop`
//! - a symlinked notify.toml is noticed when the link is replaced and not when its target is edited: not applicable here, it is the watch's: `watch::tests::a_symlink_has_no_file_watch_so_its_target_edited_is_not_heard_and_the_link_replaced_is`
//! - linux with the auto backend: `start::a_system_with_no_backend_is_a_reason_to_leave`, and in a process on Linux: `notify_service::on_linux_the_auto_backend_leaves_with_its_reason`
//! - backend none: `start::backend_none_is_a_reason_to_leave`, `start::leaving_says_why_releases_the_lock_and_exits_0`, and `notify_service::backend_none_leaves_at_once_and_releases_the_lock`
//! - the real stream: events.on exists while running and is gone after stop, a line is a notice: `serve::a_line_in_the_events_file_is_a_notice_and_a_stop_removes_the_switch`, and in a process: `notify_service::a_running_service_posts_a_notice_and_stops_on_sigterm`
//! - stopping while a post is in flight: `serve::stopping_precedes_the_notice_of_a_post_in_flight`, `serve::the_watch_closes_first_and_the_lock_goes_last`
//! - drain() resolves only after the post in flight has settled: not applicable: `engine.stop()` runs after the loop, which runs each message to the end, so a drain with a post in flight does not exist; the engine's own `stopping::a_stop_tripped_in_the_middle_of_a_post_lets_that_post_land_and_drops_the_events_behind_it`
//! - a stream that will not close: `serve::a_feed_that_will_not_close_is_a_line_and_the_lock_is_still_released`
//! - a lock that cannot be removed: `hand_over::a_lock_that_cannot_be_released_is_a_line`
//!
//! Cases of the Rust service that node's file does not have: the signal thread and the start gate (`gate`), a watch that ends after `started` (`serve::a_watch_that_ends_behind_a_post_in_flight_...`), the exit codes, the line bytes and the choice of the `tagents` script (`start`).

mod gate;
mod options_watch;
mod serve;
mod settings;
mod start;

use std::{
    fs,
    io::Write,
    path::PathBuf,
    sync::{
        Arc, Mutex,
        mpsc::{self, Receiver, Sender},
    },
};

use super::*;
use crate::{
    notify::{
        feed::Feed,
        log::RecordingLog,
        notifier::{Notice, Notifier, PostResult},
        phrases::{Locale, phrases_for},
    },
    testing::{Recorder, Scratch},
};

/// An events line a hook would write for a turn that ended, `key` naming the agent (the third field, and the pane).
fn stop_line(key: &str) -> String {
    format!("1760000000\tStop\t{key}\tsess-{key}\t\t%{key}\t/tmp/x\t\t\t\t\t\t\n")
}

/// The hook's append to the events file of the state directory `state`: a function, so that the thread that stands for the hook can call it.
fn append_line(state: &str, line: &str) {
    fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(format!("{state}/events.tsv"))
        .unwrap()
        .write_all(line.as_bytes())
        .unwrap();
}

/// A backend that shows what it is given, and keeps the kinds of the notices.
#[derive(Clone, Default)]
struct Shown(Arc<Mutex<Vec<String>>>);

impl Shown {
    fn kinds(&self) -> Vec<String> {
        locked(&self.0).clone()
    }
}

impl Notifier for Shown {
    fn name(&self) -> &str {
        "shown"
    }

    fn post(&mut self, notice: &Notice) -> Result<PostResult, String> {
        locked(&self.0).push(notice.kind.as_str().to_owned());
        Ok(PostResult {
            shown: true,
            why: None,
        })
    }

    fn withdraw(&mut self, _id: &str) -> Result<(), String> {
        Ok(())
    }
}

/// A post in flight that a test holds: `begun` says the post started, the post ends when `release` sends one, and the notice is then shown as `shown` shows it.
struct Gated {
    begun: Sender<()>,
    release: Receiver<()>,
    shown: Shown,
}

impl Notifier for Gated {
    fn name(&self) -> &str {
        "gated"
    }

    fn post(&mut self, notice: &Notice) -> Result<PostResult, String> {
        let _ = self.begun.send(());
        self.release.recv().map_err(|err| err.to_string())?;
        self.shown.post(notice)
    }

    fn withdraw(&mut self, _id: &str) -> Result<(), String> {
        Ok(())
    }
}

/// What a service is made of in a test, minus the parts a test chooses (the notifier, the feed, what the watch closes). `Rig::new` takes the lock the way a start does: the lock file names this process.
struct Rig {
    scratch: Scratch,
    log: RecordingLog,
    arming: Recorder,
    stop: Stop,
    said: Said,
    gate: Arc<StartGate>,
    lock: Lock,
    sender: Sender<Message>,
}

impl Rig {
    fn new() -> (Rig, Receiver<Message>) {
        let scratch = Scratch::new();
        let state = scratch.sub("state");
        let lock = Lock::new(format!("{}/{LOCK_FILE}", state.display()));
        fs::write(lock.file(), format!("{}\n", std::process::id())).unwrap();
        let (sender, messages) = mpsc::channel();
        let rig = Rig {
            scratch,
            log: RecordingLog::new(),
            arming: Recorder::default(),
            stop: Stop::default(),
            said: Said::default(),
            gate: Arc::new(StartGate::default()),
            lock,
            sender,
        };
        (rig, messages)
    }

    fn state(&self) -> String {
        self.scratch
            .path()
            .join("state")
            .to_string_lossy()
            .into_owned()
    }

    /// The config directory, created.
    fn config(&self) -> PathBuf {
        self.scratch.sub("config")
    }

    /// `notify.toml` of the config directory, as `text`.
    fn write_options(&self, text: &str) {
        let plugins = self.config().join("plugins");
        fs::create_dir_all(&plugins).unwrap();
        fs::write(plugins.join("notify.toml"), text).unwrap();
    }

    /// What the hook does: appends one line to the events file.
    fn append(&self, line: &str) {
        append_line(&self.state(), line);
    }

    fn events_on(&self) -> bool {
        fs::exists(format!("{}/events.on", self.state())).unwrap()
    }

    fn lock_held(&self) -> bool {
        fs::exists(self.lock.file()).unwrap()
    }

    fn signalling(&self) -> Signalling {
        Signalling {
            gate: Arc::clone(&self.gate),
            said: self.said.clone(),
            stop: self.stop.clone(),
            messages: self.sender.clone(),
            log: Arc::new(self.log.clone()),
        }
    }

    /// A started service over the real follower of the scratch state directory, as `run` makes one after the lock is taken.
    fn daemon<'a>(
        &'a self,
        notifier: impl Notifier + 'a,
        close_watch: impl FnOnce() + 'a,
    ) -> Daemon<'a> {
        self.daemon_over(
            Box::new(FollowerFeed::new(&self.arming, &self.state())),
            notifier,
            close_watch,
        )
    }

    fn daemon_over<'a>(
        &'a self,
        feed: Box<dyn Feed + 'a>,
        notifier: impl Notifier + 'a,
        close_watch: impl FnOnce() + 'a,
    ) -> Daemon<'a> {
        let log: Arc<dyn Log> = Arc::new(self.log.clone());
        let config = self.config();
        let mut settings = Settings::first(options::load(&config), &*log);
        let mut engine = Engine::new(EngineDeps {
            feed,
            notifier: Box::new(notifier),
            options: settings.current.clone(),
            screen: Box::new(|_| Ok(None)),
            clock: Box::new(SystemClock),
            log: Arc::clone(&log),
            tagents: "/bin/tagents".to_owned(),
            hostname: Box::new(|| "host".to_owned()),
            env: Vec::new(),
            phrases: phrases_for(Locale::En),
            stop: self.stop.clone(),
        });
        engine.start().unwrap();
        let options = OptionsWatch::start(&self.arming, config, &mut settings, &*log);
        engine.reload(settings.current.clone());
        Daemon {
            engine,
            settings,
            options,
            stop: self.stop.clone(),
            said: self.said.clone(),
            lock: &self.lock,
            log,
            close_watch: Box::new(close_watch),
        }
    }
}
