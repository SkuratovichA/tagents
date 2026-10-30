//! The watch against real files, on whichever of inotify and kqueue the machine has. A key that has to come is waited for `HEARD`; a key that must not come is waited for `QUIET` and found missing, so a test of silence can pass by being early but never fails by being late.

use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{Arc, Barrier};
use std::time::Duration;
use std::{process, thread};

use super::{Key, Watch};

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

fn start() -> (Watch, Receiver<Key>) {
    let (sink, keys) = mpsc::channel();
    (Watch::start(sink).unwrap(), keys)
}

fn heard(keys: &Receiver<Key>) -> Key {
    keys.recv_timeout(HEARD).expect("the watch heard nothing")
}

fn silent(keys: &Receiver<Key>) {
    assert_eq!(keys.recv_timeout(QUIET), Err(RecvTimeoutError::Timeout));
}

/// Takes every key that one action made, however many batches the system sent it in.
fn settle(keys: &Receiver<Key>) {
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

/// A reader of a file as the daemon reads the events file: from where it stopped to the end.
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

    assert_eq!(
        keys.recv_timeout(QUIET),
        Err(RecvTimeoutError::Disconnected)
    );
}
