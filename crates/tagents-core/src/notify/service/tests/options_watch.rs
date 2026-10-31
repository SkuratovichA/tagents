//! The watch on the options directory: where it arms, what it reads when it is woken, and what it says when it cannot arm. A `Recorder` stands for the watch where only the calls matter; the one test of what the real watch sends the loop uses the real one.

use std::{cell::RefCell, path::Path};

use super::*;
use crate::testing::HEARD;

const TURN_DONE_OFF: &str = "[events.turn_done]\nenabled = false\n";

fn start<'a>(
    arming: &'a dyn Arming,
    config: &Path,
    log: &RecordingLog,
) -> (OptionsWatch<'a>, Settings) {
    let mut settings = Settings::first(options::load(config), log);
    let watch = OptionsWatch::start(arming, config.to_path_buf(), &mut settings, log);
    (watch, settings)
}

fn reloads(log: &RecordingLog) -> usize {
    log.lines()
        .iter()
        .filter(|line| *line == "options reloaded")
        .count()
}

fn write(dir: &Path, name: &str, text: &str) {
    fs::create_dir_all(dir).unwrap();
    fs::write(dir.join(name), text).unwrap();
}

fn canon(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap()
}

fn calls(arming: &Recorder) -> Vec<String> {
    arming.calls.borrow().clone()
}

/// An `Arming` that runs something just before the first directory it is asked to arm, as a directory that appears in the gap between a look and a watch does.
struct Racing<'a> {
    inner: &'a Recorder,
    before_dir: RefCell<Option<Box<dyn FnOnce()>>>,
}

impl Arming for Racing<'_> {
    fn dir(&self, path: &Path, key: Key) -> io::Result<()> {
        if let Some(run) = self.before_dir.borrow_mut().take() {
            run();
        }
        self.inner.dir(path, key)
    }

    fn file(&self, path: &Path, key: Key) -> io::Result<()> {
        self.inner.file(path, key)
    }
}

#[test]
fn a_symlinked_config_dir_is_armed_by_its_real_path_and_a_change_wakes_the_loop() {
    let scratch = Scratch::new();
    let real = scratch.sub("real");
    fs::create_dir_all(real.join("plugins")).unwrap();
    let link = scratch.path().join("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();

    let arming = Recorder::default();
    let log = RecordingLog::new();
    start(&arming, &link, &log);
    let plugins = canon(&real).join("plugins");
    assert_eq!(
        calls(&arming),
        [
            format!("dir {} Options", plugins.display()),
            format!("file {}/notify.toml Options", plugins.display())
        ],
        "the real directory and the real file, never the link"
    );

    // And through the real watch: a file that appears in the real directory is a wake of the loop.
    let (sender, messages) = mpsc::channel::<Message>();
    let slot = WatchSlot(RefCell::new(Some(Watch::start::<Message>(sender).unwrap())));
    let (mut watch, mut settings) = start(&slot, &link, &log);
    assert_eq!(
        log.lines(),
        Vec::<String>::new(),
        "a file that is not there yet is no failure"
    );
    fs::write(real.join("plugins/notify.toml"), "click = \"goto\"\n").unwrap();
    loop {
        match messages
            .recv_timeout(HEARD)
            .expect("the watch heard nothing")
        {
            Message::Wake(Key::Options) => break,
            other => assert!(matches!(other, Message::Wake(_)), "{other:?}"),
        }
    }
    watch.heard(&mut settings, &log);
    assert_eq!(reloads(&log), 1);
    assert_eq!(settings.current.click, options::Click::Goto);
}

#[test]
fn the_same_value_in_other_words_and_an_unrelated_file_are_no_reload() {
    let scratch = Scratch::new();
    let config = scratch.sub("config");
    let plugins = config.join("plugins");
    write(&plugins, "notify.toml", "click = \"goto\"\n");
    let arming = Recorder::default();
    let log = RecordingLog::new();
    let (mut watch, mut settings) = start(&arming, &config, &log);

    write(&plugins, "unrelated.toml", "");
    watch.heard(&mut settings, &log);
    write(&plugins, "notify.toml", "click = \"goto\"\n");
    watch.heard(&mut settings, &log);
    write(&plugins, "notify.toml", "click = 'goto'\n");
    watch.heard(&mut settings, &log);
    assert_eq!(
        log.lines(),
        Vec::<String>::new(),
        "an unrelated file, the same bytes and the same value in other words say nothing"
    );

    write(&plugins, "notify.toml", "click = \"focus\"\n");
    watch.heard(&mut settings, &log);
    assert_eq!(log.lines(), ["options reloaded"]);
    assert_eq!(settings.current.click, options::Click::Focus);
}

#[test]
fn a_file_that_changes_between_the_first_read_and_the_arming_is_read_once_more() {
    let first = "[events.turn_done]\nenabled = true\n";
    let reloads_after = |during: &'static str| {
        let scratch = Scratch::new();
        let config = scratch.sub("config");
        let plugins = config.join("plugins");
        write(&plugins, "notify.toml", first);
        let arming = Recorder::default();
        let file = plugins.join("notify.toml");
        *arming.during_file.borrow_mut() = Some(Box::new(move || fs::write(file, during).unwrap()));
        let log = RecordingLog::new();
        start(&arming, &config, &log);
        reloads(&log)
    };
    assert_eq!(
        reloads_after(TURN_DONE_OFF),
        1,
        "the change the watch could not see is applied, once"
    );
    assert_eq!(
        reloads_after(first),
        0,
        "the same file read again is no reload"
    );
}

#[test]
fn a_directory_that_appears_later_is_adopted_and_watched_in_its_parents_place() {
    let scratch = Scratch::new();
    let config = scratch.sub("config");
    let arming = Recorder::default();
    let log = RecordingLog::new();
    let (mut watch, mut settings) = start(&arming, &config, &log);
    assert_eq!(
        calls(&arming),
        [format!("dir {} Options", canon(&config).display())]
    );

    write(&config.join("plugins"), "notify.toml", TURN_DONE_OFF);
    watch.heard(&mut settings, &log);
    let plugins = canon(&config).join("plugins");
    assert_eq!(
        calls(&arming)[1..],
        [
            format!("dir {} Options", plugins.display()),
            format!("file {}/notify.toml Options", plugins.display())
        ]
    );
    assert_eq!(
        reloads(&log),
        1,
        "the file that came with the directory is read"
    );
    watch.heard(&mut settings, &log);
    assert_eq!(calls(&arming).len(), 3, "nothing is armed again");
    write(&plugins, "notify.toml", "click = \"goto\"\n");
    watch.heard(&mut settings, &log);
    assert_eq!(
        reloads(&log),
        2,
        "a change in the adopted directory is read"
    );
}

#[test]
fn a_directory_made_between_the_look_and_the_arming_of_its_parent_is_found_and_armed_once() {
    let scratch = Scratch::new();
    let config = scratch.sub("config");
    let plugins = config.join("plugins");
    let recorder = Recorder::default();
    let made = plugins.clone();
    let arming = Racing {
        inner: &recorder,
        before_dir: RefCell::new(Some(Box::new(move || {
            write(&made, "notify.toml", TURN_DONE_OFF)
        }))),
    };
    let log = RecordingLog::new();
    let (mut watch, mut settings) = start(&arming, &config, &log);
    // The events the gap swallowed, arriving after all (twice, as a rename and a change do).
    watch.heard(&mut settings, &log);
    watch.heard(&mut settings, &log);
    let armed = format!("dir {} Options", canon(&plugins).display());
    assert_eq!(
        calls(&recorder)
            .iter()
            .filter(|call| **call == armed)
            .count(),
        1,
        "the directory is watched once"
    );
    assert_eq!(
        reloads(&log),
        1,
        "the file that came with the directory is read"
    );
}

#[test]
fn with_no_config_dir_reload_is_off() {
    let scratch = Scratch::new();
    let config = scratch.path().join("missing");
    let arming = Recorder::default();
    let log = RecordingLog::new();
    let (mut watch, mut settings) = start(&arming, &config, &log);
    assert_eq!(
        log.lines(),
        [format!(
            "options reload is off: {} does not exist",
            config.display()
        )]
    );
    assert_eq!(calls(&arming), Vec::<String>::new());
    watch.heard(&mut settings, &log);
    assert_eq!(log.lines().len(), 1);
}

#[test]
fn a_directory_that_cannot_be_armed_is_logged_and_the_service_goes_on_without_a_reload() {
    let scratch = Scratch::new();
    let config = scratch.sub("config");
    let plugins = config.join("plugins");
    write(&plugins, "notify.toml", "");
    let arming = Recorder::default();
    arming.dir_fails.set(true);
    let log = RecordingLog::new();
    let (mut watch, mut settings) = start(&arming, &config, &log);
    let real = canon(&plugins);
    let path = real.display();
    assert_eq!(
        log.lines(),
        [format!(
            "options watch failed {path} EMFILE: too many open files, watch '{path}'"
        )]
    );
    write(&plugins, "notify.toml", TURN_DONE_OFF);
    watch.heard(&mut settings, &log);
    assert_eq!(reloads(&log), 0, "nothing reads the file: reload is off");
}

#[test]
fn a_parent_that_cannot_be_armed_is_logged_the_same_way() {
    let scratch = Scratch::new();
    let config = scratch.sub("config");
    let arming = Recorder::default();
    arming.dir_fails.set(true);
    let log = RecordingLog::new();
    start(&arming, &config, &log);
    let path = canon(&config);
    let path = path.display();
    assert_eq!(
        log.lines(),
        [format!(
            "options watch failed {path} EMFILE: too many open files, watch '{path}'"
        )]
    );
}

#[test]
fn a_file_that_cannot_be_armed_is_logged_and_the_directory_still_tells_of_what_replaces_it() {
    let scratch = Scratch::new();
    let config = scratch.sub("config");
    let plugins = config.join("plugins");
    write(&plugins, "notify.toml", "");
    let arming = Recorder::default();
    arming.file_fails_from.set(Some(1));
    let log = RecordingLog::new();
    let (mut watch, mut settings) = start(&arming, &config, &log);
    let file = canon(&plugins).join("notify.toml");
    let path = file.display();
    assert_eq!(
        log.lines(),
        [format!(
            "options watch failed {path} EMFILE: too many open files, watch '{path}'"
        )]
    );
    write(&plugins, "notify.toml", TURN_DONE_OFF);
    watch.heard(&mut settings, &log);
    assert_eq!(
        reloads(&log),
        1,
        "the directory watch is armed and the file is read"
    );
}
