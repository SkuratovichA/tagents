//! The descriptors of a file watch: dropping the `Watch` closes every one it opened, and a child spawned beside a live one inherits none of them.
//!
//! These tests count what the whole process holds, so they are a binary of their own and take turns: a test of the library that opens a file beside them would move the count.

// Test code: a failed unwrap here is the failure report.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::{
    fs,
    process::Command,
    sync::{Mutex, PoisonError, mpsc},
};

use tagents_core::watch::{Key, Watch};

static ONE_AT_A_TIME: Mutex<()> = Mutex::new(());

/// The numbers of the descriptors this process holds. The one that reading the directory opens is in every list.
fn open_fds() -> Vec<String> {
    let dir = if cfg!(target_os = "linux") {
        "/proc/self/fd"
    } else {
        "/dev/fd"
    };
    let mut fds: Vec<String> = fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    fds.sort();
    fds
}

/// The descriptors a child sees: the shell lists its own `/dev/fd`.
fn fds_of_a_child() -> String {
    let output = common::run(Command::new("/bin/sh").args(["-c", "echo /dev/fd/*"]));
    assert!(output.status.success());
    String::from_utf8(output.stdout).unwrap()
}

fn armed_watch(root: &std::path::Path) -> Watch {
    let (sink, _keys) = mpsc::channel::<Key>();
    let watch = Watch::start(sink).unwrap();
    let file = root.join("events.tsv");
    fs::write(&file, "").unwrap();
    watch.dir(root, Key::Options).unwrap();
    watch.file(&file, Key::Events).unwrap();
    watch
}

#[test]
fn dropping_a_watch_closes_every_descriptor_it_opened() {
    let _turn = ONE_AT_A_TIME.lock().unwrap_or_else(PoisonError::into_inner);
    let root = common::scratch("watch-fds-drop");
    let before = open_fds();

    for _ in 0..5 {
        let watch = armed_watch(&root);
        assert!(
            open_fds().len() > before.len(),
            "a live watch holds descriptors"
        );
        drop(watch);
        assert_eq!(open_fds(), before);
    }
}

#[test]
fn a_child_spawned_beside_a_live_watch_inherits_none_of_its_descriptors() {
    let _turn = ONE_AT_A_TIME.lock().unwrap_or_else(PoisonError::into_inner);
    let root = common::scratch("watch-fds-child");
    let without = fds_of_a_child();
    assert!(
        without.contains("/dev/fd/2"),
        "the child lists its descriptors: {without}"
    );

    let watch = armed_watch(&root);
    let with = fds_of_a_child();
    drop(watch);

    assert_eq!(with, without);
}
