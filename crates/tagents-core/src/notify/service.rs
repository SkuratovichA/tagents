//! The notify service, `tagents-core notify run`: what `packages/notify/src/service.ts` does around the engine, the process that holds the lock, watches the options directory, listens for signals and ends in the order node ends.
//!
//! Three threads and no runtime. The main thread is the engine: it reads `Message`s from one channel, with a timeout of the engine's next deadline, and runs what each means to the end before it reads the next, so a post that takes five seconds holds the loop for five seconds while the other two threads keep queueing. The watch thread (`watch::Watch`) sends `Wake`s and, if it dies, `Ended`. The signal thread (`ending::on_signals`) writes `stopping (<signal>)`, trips the `Stop` the engine checks between jobs and sends `Stop`.
//!
//! `StartGate` decides which thread writes `stopping`. A signal that comes while start runs is only remembered, as node remembers it (`packages/core/src/service.ts:131-137`): when the start succeeds the main thread writes the line after `started`, and when it fails no `stopping` line is written at all.
//!
//! A step before `started` that fails is handed to the node service (`hand_over`); a failure after it is not: an exec there would lose the events queued in the engine and its record of the cache notices it already sent.
//!
//! The node cases of `service.test.ts` (35), `main.test.ts` (6) and `options.test.ts` and the Rust test or suite scenario that covers each are listed in `docs/architecture/rust-core.md`.

use std::{
    cell::RefCell,
    fs, io,
    path::{Path, PathBuf},
    process::ExitCode,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, RecvTimeoutError, Sender},
    },
};

use crate::{
    ending::{self, Stop},
    node,
    notify::{
        clock::{Clock, SystemClock},
        engine::{self, Engine, EngineDeps},
        events::Arming,
        feed::FollowerFeed,
        hand_over::{Lock, hand_over},
        lock::{LOCK_FILE, LockDeps, LockHolder, LockResult, boot_ms, ps_process_start, take_lock},
        log::{Log, StderrLog},
        options::{self, Backend, Loaded, Options},
        phrases, platform, state,
    },
    sync::locked,
    watch::{Heard, Key, Watch},
};

/// What the engine thread reads: a wake of the watch, the end of the watch, or the stop a signal asked for.
#[derive(Debug)]
pub enum Message {
    Wake(Key),
    Ended(io::Error),
    Stop,
}

impl From<Heard> for Message {
    fn from(heard: Heard) -> Message {
        match heard {
            Heard::Fired(key) => Message::Wake(key),
            Heard::Ended(err) => Message::Ended(err),
        }
    }
}

/// Which thread writes `stopping`, decided under one lock by both: `Starting` holds the first signal that came during start, `Running` is after start settled.
pub struct StartGate(Mutex<Gate>);

enum Gate {
    Starting(Option<&'static str>),
    Running,
}

impl Default for StartGate {
    fn default() -> StartGate {
        StartGate(Mutex::new(Gate::Starting(None)))
    }
}

impl StartGate {
    /// Called by the signal thread. True when start has settled: the caller writes `stopping` itself. False when it only recorded the name, the first one; a later signal during start is ignored.
    pub fn signalled(&self, name: &'static str) -> bool {
        match &mut *locked(&self.0) {
            Gate::Running => true,
            Gate::Starting(first) => {
                first.get_or_insert(name);
                false
            }
        }
    }

    /// Called once by the main thread when start settles, after it has written `started`: the signal that came during start, for which the main thread writes `stopping`.
    pub fn settled(&self) -> Option<&'static str> {
        match std::mem::replace(&mut *locked(&self.0), Gate::Running) {
            Gate::Starting(first) => first,
            Gate::Running => None,
        }
    }
}

/// Whether the `stopping` line of a service that was running is written: it is written once, by the signal thread or by the main thread when the watch ends, as node's `stop` returns at its second call.
#[derive(Clone, Default)]
struct Said(Arc<AtomicBool>);

impl Said {
    /// True for the first caller only.
    fn first(&self) -> bool {
        !self.0.swap(true, Ordering::SeqCst)
    }
}

/// What the signal thread shares with the main thread.
#[derive(Clone)]
struct Signalling {
    gate: Arc<StartGate>,
    said: Said,
    stop: Stop,
    messages: Sender<Message>,
    log: Arc<dyn Log>,
}

impl Signalling {
    /// What the callback of `ending::on_signals` does. The stop is tripped after the line so that `stopping` precedes the `notice` of a post in flight.
    fn signal(&self, name: &'static str) {
        if self.gate.signalled(name) && self.said.first() {
            self.log.line(&[&format!("stopping ({name})")]);
        }
        self.stop.stop();
        let _ = self.messages.send(Message::Stop);
    }

    /// What the main thread does when start has settled: the `stopping` line of a signal that came during start, unless a line was written already.
    fn settle(&self) {
        if let Some(name) = self.gate.settled()
            && self.said.first()
        {
            self.log.line(&[&format!("stopping ({name})")]);
        }
    }
}

/// What the file says now about the options in force: `apply` of `service.ts`.
struct Settings {
    current: Options,
    /// The problems of the file as last logged, so that a file read again with the same ones says nothing.
    problems_seen: String,
    /// The word the `started` line puts after the file: `found`, `not found` or `invalid`.
    state: &'static str,
    /// The backend the service started with: a change of it needs a restart. `None` until the first read has been applied.
    running: Option<Backend>,
}

impl Settings {
    /// The first read: applied without a `running` backend, so it logs the problems and nothing else.
    fn first(loaded: Loaded, log: &dyn Log) -> Settings {
        let mut settings = Settings {
            current: Options::default(),
            problems_seen: String::new(),
            state: "found",
            running: None,
        };
        settings.apply(loaded, log);
        settings.running = Some(settings.current.backend);
        settings
    }

    /// A problem is logged once, however often the file is read; the options are the defaults while the file is invalid; a file that says what is in force already says nothing.
    fn apply(&mut self, loaded: Loaded, log: &dyn Log) {
        let (value, state) = match loaded {
            Loaded::Invalid(lines) => {
                self.state = "invalid";
                let seen = lines.join("\n");
                if seen != self.problems_seen {
                    for line in &lines {
                        log.line(&[&format!("options: {line}")]);
                    }
                }
                self.problems_seen = seen;
                self.current = Options::default();
                return;
            }
            Loaded::Found(value) => (value, "found"),
            Loaded::Missing(value) => (value, "not found"),
        };
        self.problems_seen.clear();
        self.state = state;
        if value == self.current {
            return;
        }
        let backend = value.backend;
        self.current = value;
        let Some(running) = self.running else {
            return;
        };
        log.line(&["options reloaded"]);
        if backend != running {
            log.line(&["backend changes take effect after a restart (tagents notify install)"]);
        }
    }
}

/// Where the options watch is: on the plugin directory, waiting for it to exist, or off.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Plugins,
    Parent,
    Off,
}

/// The watch on the options directory: `watchPlugins`, `adopt` and the wait of `service.ts`. Every wake of `Key::Options` reads the file, because the watch cannot filter by name, and `Settings::apply` ignores what changed nothing.
struct OptionsWatch<'a> {
    arming: &'a dyn Arming,
    config_dir: PathBuf,
    mode: Mode,
}

impl<'a> OptionsWatch<'a> {
    /// ~/.config/tagents is usually a symlink into a dotfiles repo, and a watch on the link sees nothing: the real directory is what changes. When `plugins` does not exist yet its parent is watched until it does.
    fn start(
        arming: &'a dyn Arming,
        config_dir: PathBuf,
        settings: &mut Settings,
        log: &dyn Log,
    ) -> OptionsWatch<'a> {
        let mut watch = OptionsWatch {
            arming,
            config_dir,
            mode: Mode::Off,
        };
        match fs::canonicalize(watch.plugins()) {
            Ok(real) => watch.watch_plugins(&real, settings, log),
            Err(_) => watch.wait_for_plugins(settings, log),
        }
        watch
    }

    /// `<configDir>/plugins`, the directory of the options file.
    fn plugins(&self) -> PathBuf {
        let file = options::options_file(&self.config_dir);
        Path::new(&file)
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default()
    }

    /// Arms the directory and then the file, and reads once more: a write between the first read and the arming raised no wake. A directory that cannot be armed is logged and the service runs without a reload; so is a file that cannot be, though the directory still tells of what replaces it.
    fn watch_plugins(&mut self, real: &Path, settings: &mut Settings, log: &dyn Log) {
        if let Err(err) = self.arming.dir(real, Key::Options) {
            self.mode = Mode::Off;
            log_watch_failed(log, real, &err);
            return;
        }
        self.mode = Mode::Plugins;
        let file = real.join(node::basename(&options::options_file(&self.config_dir)));
        match self.arming.file(&file, Key::Options) {
            Err(err) if err.kind() != io::ErrorKind::NotFound => log_watch_failed(log, &file, &err),
            _ => {}
        }
        settings.apply(options::load(&self.config_dir), log);
    }

    fn wait_for_plugins(&mut self, settings: &mut Settings, log: &dyn Log) {
        let real = match fs::canonicalize(&self.config_dir) {
            Ok(real) => real,
            Err(_) => {
                log.line(&[&format!(
                    "options reload is off: {} does not exist",
                    self.config_dir.display()
                )]);
                return;
            }
        };
        if let Err(err) = self.arming.dir(&real, Key::Options) {
            log_watch_failed(log, &real, &err);
            return;
        }
        self.mode = Mode::Parent;
        // A directory made after the look that failed and before this watch was armed raised no wake, and nothing would ever announce it.
        self.adopt(settings, log);
    }

    /// The directory exists now: watch it in place of its parent, and read the file that may have come with it. Idempotent, because it runs for the wake and for the look after the arming.
    fn adopt(&mut self, settings: &mut Settings, log: &dyn Log) {
        if self.mode != Mode::Parent {
            return;
        }
        let Ok(real) = fs::canonicalize(self.plugins()) else {
            return;
        };
        if real.is_dir() {
            self.watch_plugins(&real, settings, log);
        }
    }

    /// A wake of `Key::Options`.
    fn heard(&mut self, settings: &mut Settings, log: &dyn Log) {
        match self.mode {
            Mode::Plugins => settings.apply(options::load(&self.config_dir), log),
            Mode::Parent => self.adopt(settings, log),
            Mode::Off => {}
        }
    }
}

fn log_watch_failed(log: &dyn Log, path: &Path, err: &io::Error) {
    let path = path.to_string_lossy();
    log.line(&[
        "options watch failed",
        &path,
        &node::io_message(err, "watch", Some(&path)),
    ]);
}

/// Everything `serve` runs and, when it ends, closes. The lifetime is that of the watch slot the engine and the options watch arm through.
struct Daemon<'a> {
    engine: Engine<'a>,
    settings: Settings,
    options: OptionsWatch<'a>,
    stop: Stop,
    said: Said,
    lock: &'a Lock,
    log: Arc<dyn Log>,
    /// Closes the watch: its thread ends and its descriptors close.
    close_watch: Box<dyn FnOnce() + 'a>,
}

/// Why `serve` ends.
enum Ending {
    /// A signal: its line is written already, and the exit is 0.
    Signal,
    /// The watch died after `started`: the stop of a signal with the reason `watch failed: <why>`, and the exit is 1 so that launchd starts the service again.
    WatchFailed(io::Error),
}

/// `engine.stop()`, whose failure is a line.
fn drain(engine: &mut Engine<'_>, log: &dyn Log) {
    if let Err(why) = engine.stop() {
        log.line(&["drain failed", &why]);
    }
}

/// Serves the wakes of the engine until a signal or the end of the watch: each message runs to the end before the next is read, so the post in flight and the wakes queued ahead of an `Ended` are served first, in channel order. The loop looks at the stop before each message, so wakes queued behind a signal are dropped.
fn serve(messages: Receiver<Message>, mut daemon: Daemon<'_>) -> ExitCode {
    let ending = loop {
        let heard = match daemon.engine.next_due() {
            Some(wait) => messages.recv_timeout(wait),
            None => messages.recv().map_err(|_| RecvTimeoutError::Disconnected),
        };
        if daemon.stop.is_stopped() {
            break Ending::Signal;
        }
        match heard {
            Ok(Message::Wake(Key::Events)) => daemon.engine.wake(),
            Err(RecvTimeoutError::Timeout) => daemon.engine.tick(),
            Ok(Message::Wake(Key::Options)) => {
                daemon.options.heard(&mut daemon.settings, &*daemon.log);
                daemon.engine.reload(daemon.settings.current.clone());
            }
            Ok(Message::Ended(err)) => break Ending::WatchFailed(err),
            Ok(Message::Stop) | Err(RecvTimeoutError::Disconnected) => break Ending::Signal,
        }
    };
    end(daemon, ending)
}

/// The stop, in node's order: the watchers close, the engine stops and hands back what it has in flight, and the lock is released last, so a restart cannot overlap what is still being drained.
fn end(daemon: Daemon<'_>, ending: Ending) -> ExitCode {
    let Daemon {
        mut engine,
        stop,
        said,
        lock,
        log,
        close_watch,
        ..
    } = daemon;
    let code = match ending {
        Ending::Signal => ExitCode::SUCCESS,
        Ending::WatchFailed(err) => {
            if said.first() {
                log.line(&[&format!(
                    "stopping (watch failed: {})",
                    node::io_message(&err, "watch", None)
                )]);
            }
            stop.stop();
            ExitCode::from(1)
        }
    };
    close_watch();
    drain(&mut engine, &*log);
    drop(engine);
    lock.release(&*log);
    code
}

/// The watch the engine's follower and the options watch arm through, which the service can close while they still hold it: closing joins the watch thread and closes its descriptors, which the node service that a failed start is handed to must not inherit.
struct WatchSlot(RefCell<Option<Watch>>);

impl WatchSlot {
    fn close(&self) {
        drop(self.0.borrow_mut().take());
    }

    fn with(&self, arm: impl FnOnce(&Watch) -> io::Result<()>) -> io::Result<()> {
        match &*self.0.borrow() {
            Some(watch) => arm(watch),
            None => Err(io::Error::other("the watch is closed")),
        }
    }
}

impl Arming for WatchSlot {
    fn dir(&self, path: &Path, key: Key) -> io::Result<()> {
        self.with(|watch| watch.dir(path, key))
    }

    fn file(&self, path: &Path, key: Key) -> io::Result<()> {
        self.with(|watch| watch.file(path, key))
    }
}

/// The value of `name` in `env`.
fn var<'a>(env: &'a [(String, String)], name: &str) -> Option<&'a str> {
    env.iter()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.as_str())
}

/// The `tagents` script a click runs: `TA_NOTIFY_TAGENTS` when set, else what `script_on` finds.
fn tagents_script(env: &[(String, String)]) -> String {
    if let Some(script) = var(env, "TA_NOTIFY_TAGENTS").filter(|script| !script.is_empty()) {
        return script.to_owned();
    }
    script_on(var(env, "PATH"), node::root().ok().as_deref())
}

/// The first `tagents` on `path_var`, as found (a symlink stays the symlink), else the checkout's script when `root` has one, else the bare name, which the click's own PATH may still find. tagents re-installs the global tmux focus hooks pointing at whichever script ran, so a click must run the one the person's dashboard runs, which is the one on their PATH; a release binary has no checkout above it, so a root with no script names nothing.
fn script_on(path_var: Option<&str>, root: Option<&Path>) -> String {
    if let Some(found) = path_var.and_then(|path| node::find_on_path("tagents", path)) {
        return found;
    }
    root.map(|root| node::join(&root.to_string_lossy(), "tagents"))
        .filter(|script| Path::new(script).is_file())
        .unwrap_or_else(|| "tagents".to_owned())
}

/// `os.hostname()`: macOS renames the host with the network, so each notice reads it afresh.
fn hostname() -> String {
    rustix::system::uname()
        .nodename()
        .to_string_lossy()
        .into_owned()
}

/// The backend of a start, or why there is nothing to post: the text that goes before `; exiting`.
fn backend_for(
    os: &str,
    backend: Backend,
    log: Arc<dyn Log>,
    app: &str,
) -> Result<platform::Platform, String> {
    match platform::pick(os, backend, log, app) {
        None => Err("backend none: nothing to post".to_owned()),
        Some(platform) if platform.name == "unsupported" => {
            Err(format!("no notification backend for {os} yet"))
        }
        Some(platform) => Ok(platform),
    }
}

/// A deliberate exit: the line, the lock released, exit 0, and no `stopping` line, which belongs to a service that logged `started`.
fn leave(why: &str, lock: &Lock, log: &dyn Log) -> ExitCode {
    log.line(&[&format!("{why}; exiting")]);
    lock.release(log);
    ExitCode::SUCCESS
}

/// The last line of a start, which says the lock, the stream, the engine and the watchers are all up.
fn log_started(log: &dyn Log, pid: u32, backend: &str, options_file: &str, state: &str) {
    log.line(&[
        "started",
        &format!("pid {pid}"),
        &format!("backend {backend}"),
        &format!("options {options_file} ({state})"),
    ]);
}

/// The verb: serves until a signal or the end of the watch, and returns the exit code. Returns only after the node service could not be handed to, or when it ends.
pub fn run() -> ExitCode {
    let log: Arc<dyn Log> = Arc::new(StderrLog);
    let stop = Stop::default();
    let (sender, messages) = mpsc::channel::<Message>();
    let signalling = Signalling {
        gate: Arc::new(StartGate::default()),
        said: Said::default(),
        stop: stop.clone(),
        messages: sender.clone(),
        log: Arc::clone(&log),
    };
    let dir = state::state_dir();
    let lock = Lock::new(node::join(&dir, LOCK_FILE));
    // A step of the start that fails before anything is open to close.
    let fail = |why: &str| hand_over(why, &stop, &lock, &*log, || {});

    // Signals first, so that a signal during start is remembered.
    let on_signal = signalling.clone();
    if let Err(err) = ending::on_signals(move |name| on_signal.signal(name)) {
        return fail(&err.to_string());
    }
    if let Err(err) = fs::create_dir_all(&dir) {
        return fail(&node::io_message(&err, "mkdir", Some(&dir)));
    }
    let pid = std::process::id();
    let deps = LockDeps {
        me: LockHolder {
            pid: u64::from(pid),
            started: ps_process_start(u64::from(pid)),
        },
        boot_ms: boot_ms(SystemClock.now_ms() as i64),
        process_start: &ps_process_start,
    };
    match take_lock(lock.file(), &deps) {
        Err(why) => return fail(&why),
        Ok(LockResult::Held { holder }) => {
            log.line(&[&format!(
                "another notify service holds {} (pid {holder}); exiting",
                lock.file()
            )]);
            return ExitCode::SUCCESS;
        }
        Ok(LockResult::Taken) => {}
    }

    let config_dir = PathBuf::from(options::config_dir());
    let options_file = options::options_file(&config_dir);
    let mut settings = Settings::first(options::load(&config_dir), &*log);
    let os = platform::os_name();
    let app = platform::app_path(
        std::env::var("TA_NOTIFY_APP").ok().as_deref(),
        &node::homedir(),
    );
    let backend = match backend_for(os, settings.current.backend, Arc::clone(&log), &app) {
        Ok(backend) => backend,
        Err(why) => return leave(&why, &lock, &*log),
    };

    let watch = match Watch::start::<Message>(sender) {
        Ok(watch) => watch,
        Err(err) => return fail(&node::io_message(&err, "watch", None)),
    };
    let slot = WatchSlot(RefCell::new(Some(watch)));
    let env: Vec<(String, String)> = std::env::vars_os()
        .map(|(key, value)| {
            (
                key.to_string_lossy().into_owned(),
                value.to_string_lossy().into_owned(),
            )
        })
        .collect();
    let backend_name = backend.name;
    let mut engine = Engine::new(EngineDeps {
        feed: Box::new(FollowerFeed::new(&slot, &dir)),
        notifier: backend.notifier,
        options: settings.current.clone(),
        screen: Box::new(engine::tmux_probe),
        clock: Box::new(SystemClock),
        log: Arc::clone(&log),
        tagents: tagents_script(&env),
        hostname: Box::new(hostname),
        env,
        phrases: phrases::current_phrases(),
        stop: stop.clone(),
    });
    if let Err(why) = engine.start() {
        return hand_over(&why, &stop, &lock, &*log, || {
            slot.close();
            drain(&mut engine, &*log);
        });
    }
    let options = OptionsWatch::start(&slot, config_dir, &mut settings, &*log);
    engine.reload(settings.current.clone());

    // Last, because the line marks the end of start: whoever waits for it, a reader of the log or a test that signals the process, finds the lock, the stream, the engine and the watchers all up.
    log_started(&*log, pid, backend_name, &options_file, settings.state);
    signalling.settle();
    serve(
        messages,
        Daemon {
            engine,
            settings,
            options,
            stop,
            said: signalling.said.clone(),
            lock: &lock,
            log: Arc::clone(&log),
            close_watch: Box::new(|| slot.close()),
        },
    )
}

#[cfg(test)]
mod tests;
