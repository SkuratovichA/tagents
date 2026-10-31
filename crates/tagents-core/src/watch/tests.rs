//! The watch against real files, on whichever of inotify and kqueue the machine has. A key that has to come is waited for `HEARD`; a key that must not come is waited for `QUIET` and found missing, so a test of silence can pass by being early but never fails by being late.

use std::collections::VecDeque;
use std::fs::{self, File, OpenOptions};
use std::io::{self, ErrorKind, Read, Write};
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{Arc, Barrier};
use std::time::Duration;
use std::{process, thread};

use super::{Fired, Heard, Key, Poller, Watch, run};

const HEARD: Duration = Duration::from_secs(10);
const QUIET: Duration = Duration::from_millis(400);

/// A directory of a test's own, removed when the test ends.
struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Scratch {
        static COUNT: AtomicUsize = AtomicUsize::new(0);
        let dir = std::env::temp_dir().join(format!(
            "tagents-watch-{}-{}",
            process::id(),
            COUNT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&dir).unwrap();
        Scratch(dir)
    }

    fn dir(&self, name: &str) -> PathBuf {
        let dir = self.0.join(name);
        fs::create_dir_all(&dir).unwrap();
        dir
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn start() -> (Watch, Receiver<Heard>) {
    let (sink, keys) = mpsc::channel();
    (Watch::start(sink).unwrap(), keys)
}

fn heard(keys: &Receiver<Heard>) -> Key {
    match keys.recv_timeout(HEARD).expect("the watch heard nothing") {
        Heard::Fired(key) => key,
        Heard::Ended(err) => panic!("the watch ended: {err}"),
    }
}

fn silent(keys: &Receiver<Heard>) {
    match keys.recv_timeout(QUIET) {
        Err(RecvTimeoutError::Timeout) => {}
        other => panic!("the watch was meant to be silent, and sent {other:?}"),
    }
}

/// Takes every key that one action made, however many batches the system sent it in.
fn settle(keys: &Receiver<Heard>) {
    while keys.recv_timeout(QUIET).is_ok() {}
}

fn append(path: &Path, text: &str) {
    let mut file = OpenOptions::new().append(true).open(path).unwrap();
    file.write_all(text.as_bytes()).unwrap();
}

/// How an editor saves: a file of another name, renamed over the path.
fn replace(path: &Path, text: &str) {
    let temp = path.with_extension("tmp");
    fs::write(&temp, text).unwrap();
    fs::rename(temp, path).unwrap();
}

#[test]
fn a_file_written_in_place_is_heard() {
    let scratch = Scratch::new();
    let path = scratch.dir("d").join("notify.toml");
    fs::write(&path, "a").unwrap();
    let (watch, keys) = start();
    watch.file(&path, Key::Options).unwrap();
    silent(&keys);

    append(&path, "b");

    assert_eq!(heard(&keys), Key::Options);
}

#[test]
fn a_directory_hears_an_entry_added_replaced_and_removed() {
    let scratch = Scratch::new();
    let dir = scratch.dir("d");
    let path = dir.join("notify.toml");
    let (watch, keys) = start();
    watch.dir(&dir, Key::Options).unwrap();

    fs::write(&path, "a").unwrap();
    assert_eq!(heard(&keys), Key::Options);
    settle(&keys);

    replace(&path, "b");
    assert_eq!(heard(&keys), Key::Options);
    settle(&keys);

    fs::remove_file(&path).unwrap();
    assert_eq!(heard(&keys), Key::Options);
}

#[test]
fn keys_are_told_apart() {
    let scratch = Scratch::new();
    let (options, events) = (scratch.dir("options"), scratch.dir("events"));
    let (watch, keys) = start();
    watch.dir(&options, Key::Options).unwrap();
    watch.dir(&events, Key::Events).unwrap();

    fs::write(events.join("events.tsv"), "a").unwrap();

    assert_eq!(heard(&keys), Key::Events);
    settle(&keys);
    fs::write(options.join("notify.toml"), "a").unwrap();
    assert_eq!(heard(&keys), Key::Options);
}

#[test]
fn a_file_saved_by_rename_and_then_edited_in_place_is_heard_again() {
    let scratch = Scratch::new();
    let dir = scratch.dir("d");
    let path = dir.join("notify.toml");
    fs::write(&path, "a").unwrap();
    let (watch, keys) = start();
    watch.dir(&dir, Key::Options).unwrap();
    watch.file(&path, Key::Options).unwrap();

    replace(&path, "b");
    assert_eq!(heard(&keys), Key::Options);
    settle(&keys);
    append(&path, "c");

    assert_eq!(heard(&keys), Key::Options);
}

#[test]
fn a_file_watch_alone_follows_the_path_across_a_rename() {
    let scratch = Scratch::new();
    let path = scratch.dir("d").join("events.tsv");
    fs::write(&path, "a").unwrap();
    let (watch, keys) = start();
    watch.file(&path, Key::Events).unwrap();

    replace(&path, "b");
    assert_eq!(heard(&keys), Key::Events);
    settle(&keys);
    append(&path, "c");

    assert_eq!(heard(&keys), Key::Events);
}

#[test]
fn a_file_replaced_while_a_reader_still_holds_the_old_one_is_followed_to_the_new_one() {
    let scratch = Scratch::new();
    let path = scratch.dir("d").join("events.tsv");
    fs::write(&path, "a").unwrap();
    // The old file is not freed while it is open, so the system says nothing of its removal.
    let _reader = File::open(&path).unwrap();
    let (watch, keys) = start();
    watch.file(&path, Key::Events).unwrap();

    replace(&path, "b");
    assert_eq!(heard(&keys), Key::Events);
    settle(&keys);
    append(&path, "c");

    assert_eq!(heard(&keys), Key::Events);
}

#[test]
fn a_file_truncated_in_place_is_heard() {
    let scratch = Scratch::new();
    let path = scratch.dir("d").join("notify.toml");
    fs::write(&path, "abc").unwrap();
    let (watch, keys) = start();
    watch.file(&path, Key::Options).unwrap();
    silent(&keys);

    let file = OpenOptions::new().write(true).open(&path).unwrap();
    file.set_len(0).unwrap();

    assert_eq!(heard(&keys), Key::Options);
}

#[test]
fn a_file_truncated_by_creating_it_again_is_heard() {
    let scratch = Scratch::new();
    let path = scratch.dir("d").join("notify.toml");
    fs::write(&path, "abc").unwrap();
    let (watch, keys) = start();
    watch.file(&path, Key::Options).unwrap();
    silent(&keys);

    File::create(&path).unwrap();

    assert_eq!(heard(&keys), Key::Options);
}

#[test]
fn a_fifo_does_not_hold_the_watch_thread_for_a_writer() {
    let scratch = Scratch::new();
    let fifo = scratch.dir("d").join("events.tsv");
    assert!(
        Command::new("mkfifo")
            .arg(&fifo)
            .status()
            .unwrap()
            .success()
    );
    let (watch, _keys) = start();
    let watch = Arc::new(watch);

    let (done, finished) = mpsc::channel();
    let armer = Arc::clone(&watch);
    thread::spawn(move || {
        let armed = armer.file(&fifo, Key::Events);
        // Handed back, so that the last owner of the watch is this test and it is dropped here.
        let _ = done.send((armed, armer));
    });

    // Armed or refused, either is an answer; waiting for someone to open the other end is not.
    let (_armed, armer) = finished
        .recv_timeout(HEARD)
        .expect("arming a FIFO waited for a writer");
    drop(armer);
    drop(watch);
}

#[test]
fn a_file_that_did_not_exist_is_watched_from_the_next_directory_event() {
    let scratch = Scratch::new();
    let dir = scratch.dir("d");
    let path = dir.join("notify.toml");
    let (watch, keys) = start();
    watch.dir(&dir, Key::Options).unwrap();
    assert_eq!(
        watch.file(&path, Key::Options).unwrap_err().kind(),
        ErrorKind::NotFound
    );

    fs::write(&path, "a").unwrap();
    assert_eq!(heard(&keys), Key::Options);
    settle(&keys);
    append(&path, "b");

    assert_eq!(heard(&keys), Key::Options);
}

#[test]
fn a_symlink_has_no_file_watch_so_its_target_edited_is_not_heard_and_the_link_replaced_is() {
    let scratch = Scratch::new();
    let (config, elsewhere) = (scratch.dir("config"), scratch.dir("elsewhere"));
    let (first, second) = (elsewhere.join("first.toml"), elsewhere.join("second.toml"));
    fs::write(&first, "a").unwrap();
    fs::write(&second, "b").unwrap();
    let link = config.join("notify.toml");
    symlink(&first, &link).unwrap();
    let (watch, keys) = start();
    watch.dir(&config, Key::Options).unwrap();
    watch.file(&link, Key::Options).unwrap();

    append(&first, "edited");
    silent(&keys);

    let temp = config.join("notify.tmp");
    symlink(&second, &temp).unwrap();
    fs::rename(&temp, &link).unwrap();
    assert_eq!(heard(&keys), Key::Options);
    settle(&keys);

    append(&second, "edited");
    silent(&keys);
    append(&first, "edited again");
    silent(&keys);
}

#[test]
fn a_symlink_that_is_replaced_by_a_file_is_watched_from_then_on() {
    let scratch = Scratch::new();
    let (config, elsewhere) = (scratch.dir("config"), scratch.dir("elsewhere"));
    let target = elsewhere.join("real.toml");
    fs::write(&target, "a").unwrap();
    let link = config.join("notify.toml");
    symlink(&target, &link).unwrap();
    let (watch, keys) = start();
    watch.dir(&config, Key::Options).unwrap();
    watch.file(&link, Key::Options).unwrap();

    replace(&link, "b");
    assert_eq!(heard(&keys), Key::Options);
    settle(&keys);
    append(&link, "c");

    assert_eq!(heard(&keys), Key::Options);
    settle(&keys);
    append(&target, "edited");
    silent(&keys);
}

#[test]
fn a_directory_that_is_a_symlink_is_followed_and_a_file_is_not_a_directory() {
    let scratch = Scratch::new();
    let real = scratch.dir("real");
    let link = scratch.0.join("link");
    symlink(&real, &link).unwrap();
    let file = real.join("notify.toml");
    fs::write(&file, "a").unwrap();
    let (watch, keys) = start();

    watch.dir(&link, Key::Options).unwrap();
    fs::write(real.join("other.toml"), "b").unwrap();
    assert_eq!(heard(&keys), Key::Options);

    assert!(watch.dir(&file, Key::Events).is_err());
}

#[test]
fn a_second_directory_for_a_key_takes_the_place_of_the_first() {
    let scratch = Scratch::new();
    let (old, new) = (scratch.dir("old"), scratch.dir("new"));
    let (watch, keys) = start();
    watch.dir(&old, Key::Options).unwrap();
    watch.dir(&new, Key::Options).unwrap();

    fs::write(old.join("notify.toml"), "a").unwrap();
    silent(&keys);
    fs::write(new.join("notify.toml"), "a").unwrap();

    assert_eq!(heard(&keys), Key::Options);
}

#[test]
fn two_keys_on_one_directory_both_hear_an_entry_written() {
    let scratch = Scratch::new();
    let shared = scratch.dir("shared");
    let (watch, keys) = start();
    watch.dir(&shared, Key::Events).unwrap();
    watch.dir(&shared, Key::Options).unwrap();

    fs::write(shared.join("notify.toml"), "a").unwrap();

    let told = [heard(&keys), heard(&keys)];
    assert!(
        told.contains(&Key::Events) && told.contains(&Key::Options),
        "{told:?}"
    );
}

#[test]
fn a_key_that_leaves_a_directory_does_not_take_the_watch_of_another_key_with_it() {
    let scratch = Scratch::new();
    let (shared, elsewhere) = (scratch.dir("shared"), scratch.dir("elsewhere"));
    let (watch, keys) = start();
    watch.dir(&shared, Key::Events).unwrap();
    watch.dir(&shared, Key::Options).unwrap();

    watch.dir(&elsewhere, Key::Events).unwrap();
    fs::write(shared.join("notify.toml"), "a").unwrap();
    assert_eq!(heard(&keys), Key::Options);
    settle(&keys);
    fs::write(elsewhere.join("events.tsv"), "a").unwrap();

    assert_eq!(heard(&keys), Key::Events);
}

#[test]
fn arming_does_not_wait_for_an_event() {
    let scratch = Scratch::new();
    let dir = scratch.dir("d");
    let (watch, _keys) = start();
    let watch = Arc::new(watch);
    thread::sleep(Duration::from_millis(100));

    let (done, finished) = mpsc::channel();
    let armer = Arc::clone(&watch);
    thread::spawn(move || {
        let _ = done.send(armer.dir(&dir, Key::Options));
    });

    finished
        .recv_timeout(HEARD)
        .expect("arming waited for an event")
        .unwrap();
}

/// A reader of a file as a follower of a log reads it: from where it stopped to the end.
struct Follower {
    file: File,
    text: Vec<u8>,
}

impl Follower {
    fn open(path: &Path) -> Follower {
        Follower {
            file: File::open(path).unwrap(),
            text: Vec::new(),
        }
    }

    fn read(&mut self) {
        self.file.read_to_end(&mut self.text).unwrap();
    }

    /// Arm, then read: what was written since the last read and before the arming is in the read that follows it.
    fn arm_then_read(&mut self, watch: &Watch, path: &Path) {
        watch.file(path, Key::Events).unwrap();
        self.read();
    }
}

#[test]
fn no_byte_is_missed_when_writes_land_as_the_watch_is_armed() {
    const ROUNDS: usize = 200;
    const BYTES: usize = 5;
    let scratch = Scratch::new();
    let dir = scratch.dir("d");
    let (watch, keys) = start();
    for round in 0..ROUNDS {
        // A key left from the last round would satisfy the wait of this one.
        while keys.try_recv().is_ok() {}
        let path = dir.join(format!("events-{round}.tsv"));
        File::create(&path).unwrap();
        let mut follower = Follower::open(&path);
        follower.read();
        let go = Arc::new(Barrier::new(2));
        let writer = {
            let (go, path) = (Arc::clone(&go), path.clone());
            thread::spawn(move || {
                let mut file = OpenOptions::new().append(true).open(path).unwrap();
                go.wait();
                for _ in 0..BYTES {
                    file.write_all(b"x").unwrap();
                }
            })
        };

        go.wait();
        follower.arm_then_read(&watch, &path);
        while follower.text.len() < BYTES {
            keys.recv_timeout(HEARD).unwrap_or_else(|_| {
                panic!(
                    "round {round}: a wake was lost, {} of {BYTES} bytes read",
                    follower.text.len()
                )
            });
            follower.read();
        }
        writer.join().unwrap();
    }
}

#[test]
fn arming_another_watch_loses_no_wake_of_one_already_armed() {
    const BYTES: usize = 300;
    let scratch = Scratch::new();
    let dir = scratch.dir("d");
    let events = dir.join("events.tsv");
    File::create(&events).unwrap();
    let (watch, keys) = start();
    let mut follower = Follower::open(&events);
    follower.arm_then_read(&watch, &events);
    let writer = {
        let events = events.clone();
        thread::spawn(move || {
            let mut file = OpenOptions::new().append(true).open(events).unwrap();
            for _ in 0..BYTES {
                file.write_all(b"x").unwrap();
                thread::yield_now();
            }
        })
    };

    for round in 0..BYTES {
        let options = dir.join(format!("notify-{round}.toml"));
        fs::write(&options, "a").unwrap();
        watch.file(&options, Key::Options).unwrap();
    }
    while follower.text.len() < BYTES {
        keys.recv_timeout(HEARD).unwrap_or_else(|_| {
            panic!(
                "a wake was lost, {} of {BYTES} bytes read",
                follower.text.len()
            )
        });
        follower.read();
    }
    writer.join().unwrap();
}

#[test]
fn a_watch_is_dropped_while_its_thread_waits() {
    let scratch = Scratch::new();
    let (watch, keys) = start();
    watch.dir(&scratch.dir("d"), Key::Options).unwrap();
    thread::sleep(Duration::from_millis(100));

    drop(watch);

    match keys.recv_timeout(QUIET) {
        Err(RecvTimeoutError::Disconnected) => {}
        other => panic!("a dropped watch was meant to end without a word, and sent {other:?}"),
    }
}

/// A backend that is not one: `wait` answers from a list, so that the loop of the thread runs with no operating system behind it.
struct Script(VecDeque<io::Result<Fired>>);

impl Poller for Script {
    fn dir(&mut self, _path: &Path, _key: Key) -> io::Result<()> {
        Ok(())
    }

    fn file(&mut self, _path: &Path, _key: Key) -> io::Result<()> {
        Ok(())
    }

    fn wait(&mut self) -> io::Result<Fired> {
        self.0
            .pop_front()
            .unwrap_or_else(|| Err(io::Error::other("the script is over")))
    }
}

#[test]
fn a_wait_that_fails_is_the_last_thing_the_sink_hears_and_then_the_thread_ends() {
    let script = Script(VecDeque::from([
        Ok(Fired {
            keys: vec![Key::Events],
            ..Fired::default()
        }),
        Err(io::Error::new(
            ErrorKind::BrokenPipe,
            "the descriptor is gone",
        )),
    ]));
    // The sender stays alive: a closed inbox ends the thread before it waits.
    let (_commands, inbox) = mpsc::channel();
    let (sink, keys) = mpsc::channel();
    let thread = thread::spawn(move || run(script, &inbox, &sink));

    assert_eq!(heard(&keys), Key::Events);
    match keys.recv_timeout(HEARD) {
        Ok(Heard::Ended(err)) => assert_eq!(err.kind(), ErrorKind::BrokenPipe),
        other => panic!("a failed wait was meant to reach the sink as Ended, and it got {other:?}"),
    }
    thread.join().unwrap();
    match keys.recv_timeout(QUIET) {
        Err(RecvTimeoutError::Disconnected) => {}
        other => panic!("the thread was meant to end after Ended, and the sink got {other:?}"),
    }
}
