//! `FollowerFeed` over a real state directory and an `Arming` that arms nothing: the adapter hands what the follower and the state reader find to the engine, and the tests of the follower itself (`events/tests.rs`) cover what the follower does with a file.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::Path;

use super::*;
use crate::testing::{Recorder, Scratch};

/// A line as the hook writes it, 13 fields, with `text` in the twelfth.
fn line(text: &str) -> String {
    format!("1760000000\tStop\t12\ts\t\t%12\t/w\t/t\t\t\t\t{text}\t\n")
}

fn append(dir: &str, bytes: &str) {
    let mut file = OpenOptions::new()
        .append(true)
        .create(true)
        .open(format!("{dir}/events.tsv"))
        .unwrap();
    file.write_all(bytes.as_bytes()).unwrap();
}

/// A state directory that does not exist yet, inside a scratch directory of the test's own.
fn state_dir(scratch: &Scratch) -> String {
    format!("{}/state", scratch.dir())
}

fn texts(delivery: &Delivery) -> Vec<&str> {
    delivery.events.iter().map(|e| e.text.as_str()).collect()
}

#[test]
fn the_feed_names_the_directory_it_was_given() {
    let arming = Recorder::default();
    let feed = FollowerFeed::new(&arming, "/some/state");
    assert_eq!(feed.dir(), "/some/state");
}

#[test]
fn start_makes_the_directory_and_the_file_and_delivers_nothing_from_before_it() {
    let scratch = Scratch::new();
    let dir = state_dir(&scratch);
    let arming = Recorder::default();
    let mut feed = FollowerFeed::new(&arming, &dir);
    assert_eq!(feed.start(0), Ok(Delivery::default()));
    assert!(Path::new(&dir).join("events.tsv").exists());
    assert_eq!(feed.close(), None);
}

#[test]
fn a_line_appended_after_start_is_delivered_by_wake_once() {
    let scratch = Scratch::new();
    let dir = state_dir(&scratch);
    let arming = Recorder::default();
    let mut feed = FollowerFeed::new(&arming, &dir);
    feed.start(0).unwrap();
    append(&dir, &line("hello"));
    let delivery = feed.wake(0);
    assert_eq!(texts(&delivery), ["hello"]);
    assert!(delivery.errors.is_empty() && delivery.death.is_none());
    assert_eq!(feed.wake(0), Delivery::default());
    assert_eq!(feed.close(), None);
}

#[test]
fn wake_before_start_and_after_close_finds_nothing() {
    let scratch = Scratch::new();
    let dir = state_dir(&scratch);
    let arming = Recorder::default();
    let mut feed = FollowerFeed::new(&arming, &dir);
    assert_eq!(feed.wake(0), Delivery::default());
    feed.start(0).unwrap();
    assert_eq!(feed.close(), None);
    append(&dir, &line("after the close"));
    assert_eq!(feed.wake(0), Delivery::default());
}

#[test]
fn close_is_idempotent_and_before_start_it_closes_nothing() {
    let scratch = Scratch::new();
    let dir = state_dir(&scratch);
    let arming = Recorder::default();
    let mut feed = FollowerFeed::new(&arming, &dir);
    assert_eq!(feed.close(), None);
    feed.start(0).unwrap();
    assert_eq!(feed.close(), None);
    assert_eq!(feed.close(), None);
}

#[test]
fn a_directory_that_cannot_be_made_is_an_err_with_a_reason_and_nothing_is_followed() {
    let scratch = Scratch::new();
    let blocker = format!("{}/not-a-directory", scratch.dir());
    fs::write(&blocker, "").unwrap();
    let arming = Recorder::default();
    let mut feed = FollowerFeed::new(&arming, &format!("{blocker}/state"));
    let why = feed.start(0).unwrap_err();
    assert!(!why.is_empty());
    assert_eq!(feed.wake(0), Delivery::default());
    assert_eq!(feed.due(), None);
}

#[test]
fn states_reads_the_rows_of_the_directory_newest_first() {
    let scratch = Scratch::new();
    let dir = scratch.dir();
    fs::write(
        format!("{dir}/12.tsv"),
        "1700000000\tdone\tsess-1\t/w\t\t\n",
    )
    .unwrap();
    fs::write(
        format!("{dir}/13.tsv"),
        "1700000100\tblocked\tsess-2\t/v\t\t\n",
    )
    .unwrap();
    let arming = Recorder::default();
    let feed = FollowerFeed::new(&arming, dir);
    let keys: Vec<String> = feed.states().into_iter().map(|row| row.key).collect();
    assert_eq!(keys, ["13", "12"]);
}

#[test]
fn a_directory_that_cannot_be_read_has_no_rows() {
    let arming = Recorder::default();
    let feed = FollowerFeed::new(&arming, "/no/such/state/directory");
    assert!(feed.states().is_empty());
}

#[test]
fn due_is_the_end_of_the_grace_of_a_file_the_follower_replaced() {
    let scratch = Scratch::new();
    let dir = state_dir(&scratch);
    let arming = Recorder::default();
    let mut feed = FollowerFeed::new(&arming, &dir);
    assert_eq!(feed.due(), None, "no follower, nothing to wake for");
    feed.start(0).unwrap();
    assert_eq!(feed.due(), None);
    // The hook's rotation: the file moves away and a line goes to the path again, so the old file is read to its end and kept open for a grace.
    append(&dir, &line("before the rotation"));
    assert_eq!(texts(&feed.wake(1000)), ["before the rotation"]);
    fs::rename(format!("{dir}/events.tsv"), format!("{dir}/events.tsv.1")).unwrap();
    append(&dir, &line("after the rotation"));
    assert_eq!(texts(&feed.wake(1500)), ["after the rotation"]);
    assert_eq!(
        feed.due(),
        None,
        "a rename the follower did not make has no grace"
    );
    assert_eq!(feed.close(), None);
}
