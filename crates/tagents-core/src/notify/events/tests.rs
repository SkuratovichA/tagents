//! The event line parser and the follower against real files, driven by hand: a test says when the watch "fired" by calling `wake`, and with what time. Two tests put the real `Watch` in place of the recorder, to see a wake come from the operating system and the re-arming after a replacement keep it coming.
//!
//! The cases of `packages/core/test/agent-events.test.ts` map as follows. Line parser: "a good line gives every field" is `a_good_line_gives_every_field_with_at_in_milliseconds`; "every event the hook writes is accepted" is `every_event_the_hook_writes_is_accepted`; "twelve fields, an unknown event and a non-numeric at give null" is `twelve_fields_an_unknown_event_and_a_bad_time_give_none`; "a trailing carriage return is tolerated" is `a_trailing_carriage_return_is_tolerated`; "a 14th field from a newer hook is ignored" is `a_fourteenth_field_from_a_newer_hook_is_ignored`; "the hook of this tree writes lines parseEventLine reads" runs the shell hook under jq and is node's test of the hook, with no Rust counterpart (the vectors pin the lines the hook writes). Switch: "setEventsOn: on creates the switch and an empty events.tsv, off removes only the switch" and "creates the directory" are `the_first_follower_turns_the_switch_on_and_the_last_turns_it_off`; the five `createAgentFeed` cases are `a_follower_that_dies_is_counted_out_and_the_switch_goes_before_the_death_is_reported`, `followers_of_two_spellings_of_one_directory_count_together`, `a_switch_that_cannot_be_removed_is_reported_and_close_does_not_panic`, and `a_dead_follower_with_a_stuck_switch_reports_both` (the node cases for onDead and onError ordering have no callbacks here: a death is a value of the `Delivery` that also carries the switch's error); "follow delivers what the hook appends, and states() is readAgentState" is the real hook's business and `the_watch_wakes_the_follower...`. Follower: "a line appended after the start is delivered" is `a_line_appended_after_the_start_is_delivered_and_the_lines_before_it_are_not`; "a malformed line is skipped" is `a_malformed_line_is_skipped_and_the_next_one_arrives`; "a line written in two appends" is `a_line_written_in_two_appends_is_delivered_once_complete`; "a multibyte character split across two appends" is `a_multibyte_character_split_across_two_appends_arrives_intact` and `a_character_split_by_the_chunk_of_a_read_arrives_intact`; "truncate then append" is `truncate_then_append_delivers_the_new_line`; "a deleted file followed by an append" is `a_deleted_file_followed_by_an_append_to_the_recreated_path_delivers`; "an external mv followed at once by appends" is `an_external_mv_followed_at_once_by_appends_delivers_them_and_the_old_file_first`; "an external mv that leaves no file" is `an_external_mv_that_leaves_no_file_is_answered_by_recreating_it`; "the follower rotates itself at rotateBytes" is `the_follower_rotates_itself_at_the_size_losing_and_duplicating_nothing`; "a line appended to the OLD file inside the grace" is `a_line_appended_to_the_old_file_inside_the_grace_is_delivered_when_it_ends`; "nothing is delivered after close(), and a second close() is harmless" and "closing from inside the callback stops the lines that came with it" are `nothing_is_delivered_after_close_and_a_second_close_is_harmless` (a call hands its events back whole, so there is no callback to close from); "a missing directory is created" is `a_missing_directory_is_created_and_the_file_in_it`; "an exception thrown by the consumer goes to onError" has no Rust counterpart (no consumer is called). Death: "when watching again fails the follower closes itself" is `when_arming_fails_after_a_replacement_the_follower_dies_once`; "a watching failure during the rotation grace" is `when_arming_fails_during_a_rotation_the_follower_dies_and_drops_the_grace`; "a failed open when the path was replaced is a death" is `when_the_path_cannot_be_opened_again_the_follower_dies_once`; "a failed open of the fresh file after a rotation is a death" shares that site (`open_cursor` through `?`) and cannot be made to fail after a successful rename without a permission the tests may not assume (the container runs as root); the four cases about the watcher's 'error' event, an explicit close and an onDead that throws belong to node's `fs.watch` and callbacks, and the end of the real watch is the engine's `Heard::Ended`; "close() during the grace leaves no timer and no handle" holds by construction (there is no timer, and `Drop` closes the files) and its observable half is in `nothing_is_delivered_after_close...`; "constants: the rotation threshold is 1 MiB" is `the_rotation_threshold_is_one_mebibyte`. `a_line_with_all_its_fields_waits_for_its_newline` has no node counterpart: the half lines of the other tests lack fields, so the parser would drop them anyway, and this one pins the half line that already parses.

use std::cell::{Cell, RefCell};
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver};

use super::*;
use crate::testing::{Scratch, heard, settle};
use crate::watch::Heard;

/// A line as the hook writes it, 13 fields, with `text` in the twelfth.
fn line(text: &str) -> String {
    format!("1760000000\tStop\t12\ts\t\t%12\t/w\t/t\t\t\t\t{text}\t\n")
}

/// The same line without its newline, which is what the follower hands the parser.
fn bare(text: &str) -> String {
    line(text).trim_end_matches('\n').to_owned()
}

fn append(file: &Path, bytes: impl AsRef<[u8]>) {
    let mut open = OpenOptions::new()
        .append(true)
        .create(true)
        .open(file)
        .unwrap();
    open.write_all(bytes.as_ref()).unwrap();
}

/// The texts of the events of a call that had nothing go wrong.
fn texts(d: &Delivery) -> Vec<&str> {
    assert!(d.errors.is_empty() && d.death.is_none(), "{d:?}");
    d.events.iter().map(|e| e.text.as_str()).collect()
}

/// An `Arming` that arms nothing, writes down what it was asked, and does what it is told: fail the `file` calls from the Nth, fail `dir`, or run something in the middle of the next `file` (what a hook writes between the open of a file and the arming of it).
#[derive(Default)]
struct Recorder {
    calls: RefCell<Vec<String>>,
    file_fails_from: Cell<Option<usize>>,
    dir_fails: Cell<bool>,
    during_file: RefCell<Option<Box<dyn FnOnce()>>>,
}

impl Arming for Recorder {
    fn dir(&self, path: &Path, key: Key) -> io::Result<()> {
        self.calls
            .borrow_mut()
            .push(format!("dir {} {key:?}", path.display()));
        if self.dir_fails.get() {
            return Err(io::Error::from_raw_os_error(24));
        }
        Ok(())
    }

    fn file(&self, path: &Path, key: Key) -> io::Result<()> {
        self.calls
            .borrow_mut()
            .push(format!("file {} {key:?}", path.display()));
        if let Some(run) = self.during_file.borrow_mut().take() {
            run();
        }
        let nth = self
            .calls
            .borrow()
            .iter()
            .filter(|call| call.starts_with("file"))
            .count();
        if self.file_fails_from.get().is_some_and(|from| nth >= from) {
            return Err(io::Error::from_raw_os_error(24));
        }
        Ok(())
    }
}

/// A state directory of a test's own, which does not exist yet.
struct Rig {
    _scratch: Scratch,
    dir: String,
    file: PathBuf,
    recorder: Recorder,
}

impl Rig {
    fn new() -> Rig {
        let scratch = Scratch::new();
        let dir = format!("{}/state", scratch.dir());
        let file = PathBuf::from(format!("{dir}/events.tsv"));
        Rig {
            _scratch: scratch,
            dir,
            file,
            recorder: Recorder::default(),
        }
    }

    fn file(&self) -> &str {
        self.file.to_str().unwrap()
    }

    fn switch(&self) -> PathBuf {
        Path::new(&self.dir).join("events.on")
    }

    fn start(&self) -> Follower {
        let (follower, first) = Follower::start(&self.recorder, &self.dir, 0).unwrap();
        assert_eq!(first, Delivery::default());
        follower
    }

    /// A follower that rotates at `rotate_bytes`, started at time 0.
    fn start_rotating(&self, rotate_bytes: u64) -> Follower {
        let (follower, first) = start_with(&self.recorder, &self.dir, 0, rotate_bytes).unwrap();
        assert_eq!(first, Delivery::default());
        follower
    }

    fn wake(&self, follower: &mut Follower, now_ms: i64) -> Delivery {
        follower.wake(&self.recorder, now_ms)
    }

    /// The path replaced by a link to nothing: the open of it fails (ENOENT), as it does when a disk is full or the descriptors are gone.
    fn replace_with_a_dead_link(&self) {
        fs::remove_file(&self.file).unwrap();
        symlink(
            Path::new(&self.dir).join("no/such/dir/events.tsv"),
            &self.file,
        )
        .unwrap();
    }
}

#[test]
fn a_good_line_gives_every_field_with_at_in_milliseconds() {
    let fields = [
        "1760000000.123",
        "Notification",
        "12",
        "sess-1",
        "agent-9",
        "%12",
        "/Users/demo/git/demo",
        "/t/sess-1.jsonl",
        "/Users/demo/.claude-work",
        "Bash",
        "sub",
        "Claude needs your permission",
        "ticket-agent",
    ];
    let event = parse_event_line(&fields.join("\t")).unwrap();
    assert_eq!(
        event,
        AgentEvent {
            at: 1_760_000_000.123 * 1000.0,
            event: AgentHookEvent::Notification,
            key: "12".into(),
            session_id: "sess-1".into(),
            agent_id: "agent-9".into(),
            pane: "%12".into(),
            cwd: "/Users/demo/git/demo".into(),
            transcript: "/t/sess-1.jsonl".into(),
            config_dir: "/Users/demo/.claude-work".into(),
            tool: "Bash".into(),
            sub: "sub".into(),
            text: "Claude needs your permission".into(),
            label: "ticket-agent".into(),
        }
    );
    let empty = parse_event_line(&bare("")).unwrap();
    assert_eq!(
        (empty.at, empty.event, empty.text.as_str()),
        (1_760_000_000_000.0, AgentHookEvent::Stop, "")
    );
}

#[test]
fn every_event_the_hook_writes_is_accepted() {
    for name in [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "Notification",
        "Stop",
        "SubagentStop",
        "SessionEnd",
    ] {
        let event = parse_event_line(&bare("").replacen("Stop", name, 1)).unwrap();
        assert_eq!(event.event.as_str(), name);
    }
}

#[test]
fn twelve_fields_an_unknown_event_and_a_bad_time_give_none() {
    let twelve = bare("").strip_suffix('\t').unwrap().to_owned();
    assert_eq!(twelve.matches('\t').count(), 11);
    assert_eq!(parse_event_line(&twelve), None, "twelve fields");
    assert_eq!(
        parse_event_line(&bare("").replacen("Stop", "PreCompact", 1)),
        None,
        "an event the hook does not write"
    );
    assert_eq!(
        parse_event_line(&bare("").replacen("Stop", "stop", 1)),
        None,
        "event names keep their case"
    );
    for at in ["soon", "", "   ", "Infinity", "NaN", "1 2"] {
        assert_eq!(
            parse_event_line(&bare("").replacen("1760000000", at, 1)),
            None,
            "{at:?}"
        );
    }
    assert_eq!(parse_event_line(""), None);
    assert_eq!(parse_event_line("not an event"), None);
}

#[test]
fn a_time_is_read_as_number_reads_it() {
    for (at, ms) in [
        ("0x10", 16_000.0),
        ("1e3", 1_000_000.0),
        (" 17 ", 17_000.0),
        ("0", 0.0),
        ("-5", -5000.0),
    ] {
        let event = parse_event_line(&bare("").replacen("1760000000", at, 1)).unwrap();
        assert_eq!(event.at, ms, "{at:?}");
    }
}

#[test]
fn a_trailing_carriage_return_is_tolerated() {
    let event = parse_event_line(&format!("{}\r", bare("hello"))).unwrap();
    assert_eq!(event.text, "hello");
    assert_eq!(
        event.label, "",
        "the carriage return is not part of the last field"
    );
    let twice = parse_event_line(&format!("{}\r\r", bare("hello"))).unwrap();
    assert_eq!(twice.label, "\r", "only one is dropped");
}

#[test]
fn a_fourteenth_field_from_a_newer_hook_is_ignored() {
    let thirteen = parse_event_line(&bare("same")).unwrap();
    for more in ["\textra", "\textra\tand more"] {
        let longer = format!("{}{more}", bare("same"));
        assert_eq!(parse_event_line(&longer).unwrap(), thirteen, "{more:?}");
    }
    assert_eq!(
        parse_event_line(&bare("same")).unwrap(),
        thirteen,
        "a line of 13 fields is a whole line"
    );
}

#[test]
fn the_rotation_threshold_is_one_mebibyte() {
    assert_eq!(ROTATE_BYTES, 1024 * 1024);
}

#[test]
fn a_line_appended_after_the_start_is_delivered_and_the_lines_before_it_are_not() {
    let rig = Rig::new();
    fs::create_dir_all(&rig.dir).unwrap();
    fs::write(&rig.file, line("before-1") + &line("before-2")).unwrap();
    let mut follower = rig.start();
    assert_eq!(follower.due(), None);
    append(&rig.file, line("after-1"));
    assert_eq!(texts(&rig.wake(&mut follower, 0)), ["after-1"]);
    append(&rig.file, line("after-2"));
    assert_eq!(texts(&rig.wake(&mut follower, 0)), ["after-2"]);
    for _ in 0..3 {
        assert_eq!(
            rig.wake(&mut follower, 0),
            Delivery::default(),
            "a wake that finds nothing finds nothing"
        );
    }
}

#[test]
fn the_arming_comes_before_the_read_at_the_start_and_again_after_a_replacement() {
    let rig = Rig::new();
    // What the hook writes between the open of the file and the arming of the watch raises no wake; the read after the arming is what finds it.
    let file = rig.file.clone();
    *rig.recorder.during_file.borrow_mut() =
        Some(Box::new(move || append(&file, line("landed while arming"))));
    let (mut follower, first) = Follower::start(&rig.recorder, &rig.dir, 0).unwrap();
    assert_eq!(texts(&first), ["landed while arming"]);
    let dir_call = format!("dir {} Events", rig.dir);
    let file_call = format!("file {} Events", rig.file());
    assert_eq!(
        *rig.recorder.calls.borrow(),
        [dir_call.clone(), file_call.clone()],
        "the directory and the file, for the events key"
    );

    // The same for a file the follower opens afresh: only the file is armed again.
    let file = rig.file.clone();
    *rig.recorder.during_file.borrow_mut() =
        Some(Box::new(move || append(&file, line("landed again"))));
    fs::rename(&rig.file, format!("{}.1", rig.file())).unwrap();
    assert_eq!(texts(&rig.wake(&mut follower, 0)), ["landed again"]);
    assert_eq!(
        *rig.recorder.calls.borrow(),
        [dir_call, file_call.clone(), file_call]
    );
}

#[test]
fn a_malformed_line_is_skipped_and_the_next_one_arrives() {
    let rig = Rig::new();
    let mut follower = rig.start();
    let unknown = line("x").replacen("Stop", "PreCompact", 1);
    append(
        &rig.file,
        format!("not an event\n\n{unknown}{}", line("good")),
    );
    assert_eq!(texts(&rig.wake(&mut follower, 0)), ["good"]);
}

#[test]
fn a_line_written_in_two_appends_is_delivered_once_complete() {
    let rig = Rig::new();
    let mut follower = rig.start();
    let second = line("second, in two halves");
    let cut = second.len() / 2;
    // The first append carries one whole line and the first half of the next, so by the time the whole line is delivered the half has been read.
    append(&rig.file, line("first") + &second[..cut]);
    assert_eq!(texts(&rig.wake(&mut follower, 0)), ["first"]);
    append(&rig.file, &second[cut..]);
    assert_eq!(
        texts(&rig.wake(&mut follower, 0)),
        ["second, in two halves"]
    );
    assert_eq!(rig.wake(&mut follower, 0), Delivery::default());
}

#[test]
fn a_line_with_all_its_fields_waits_for_its_newline() {
    let rig = Rig::new();
    let mut follower = rig.start();
    // Everything but the newline: 13 fields, so the parser would take it for a line.
    append(&rig.file, bare("whole but for the newline"));
    assert_eq!(rig.wake(&mut follower, 0), Delivery::default());
    append(&rig.file, "\n");
    assert_eq!(
        texts(&rig.wake(&mut follower, 0)),
        ["whole but for the newline"]
    );
    assert_eq!(rig.wake(&mut follower, 0), Delivery::default());
}

#[test]
fn a_multibyte_character_split_across_two_appends_arrives_intact() {
    let rig = Rig::new();
    let mut follower = rig.start();
    let text = "Готово… ждёт ответа";
    let bytes = line(text).into_bytes();
    // One byte into the ellipsis (E2 80 A6), so the first read ends in the middle of a character.
    let cut = bytes.windows(3).position(|w| w == "…".as_bytes()).unwrap() + 1;
    let mut first = line("anchor").into_bytes();
    first.extend_from_slice(&bytes[..cut]);
    append(&rig.file, first);
    assert_eq!(texts(&rig.wake(&mut follower, 0)), ["anchor"]);
    append(&rig.file, &bytes[cut..]);
    let d = rig.wake(&mut follower, 0);
    assert_eq!(texts(&d), [text]);
    assert!(
        !d.events[0].text.contains('\u{fffd}'),
        "no replacement character"
    );
}

#[test]
fn a_character_split_by_the_chunk_of_a_read_arrives_intact() {
    let rig = Rig::new();
    let mut follower = rig.start();
    // The second line starts with a two byte character whose first byte is the last of the first chunk: one wake reads it in two chunks.
    let prefix = line("").len() - "\t\n".len();
    let fill = CHUNK_BYTES - 1 - prefix - line("").len();
    append(
        &rig.file,
        line(&"a".repeat(fill)) + &line("жжж") + &line("end"),
    );
    let d = rig.wake(&mut follower, 0);
    assert_eq!(
        texts(&d),
        ["a".repeat(fill), "жжж".to_owned(), "end".to_owned()]
    );
}

#[test]
fn a_file_much_larger_than_a_chunk_is_read_whole_and_in_order() {
    let rig = Rig::new();
    let mut follower = rig.start();
    let want: Vec<String> = (0..3000)
        .map(|i| format!("n{i}-{}", "x".repeat(i % 97)))
        .collect();
    append(&rig.file, want.iter().map(|t| line(t)).collect::<String>());
    assert!(fs::metadata(&rig.file).unwrap().len() > 2 * CHUNK_BYTES as u64);
    let d = rig.wake(&mut follower, 0);
    assert_eq!(
        texts(&d),
        want.iter().map(String::as_str).collect::<Vec<_>>()
    );
}

#[test]
fn truncate_then_append_delivers_the_new_line() {
    let rig = Rig::new();
    let mut follower = rig.start();
    append(
        &rig.file,
        line(&"a long first line that sets the offset well past the next one".repeat(2)),
    );
    assert_eq!(rig.wake(&mut follower, 0).events.len(), 1);
    OpenOptions::new()
        .write(true)
        .open(&rig.file)
        .unwrap()
        .set_len(0)
        .unwrap();
    append(&rig.file, line("short"));
    assert_eq!(texts(&rig.wake(&mut follower, 0)), ["short"]);
}

#[test]
fn a_truncation_drops_the_half_line_that_came_before_it() {
    let rig = Rig::new();
    let mut follower = rig.start();
    append(&rig.file, bare("cut off, no newline"));
    assert_eq!(rig.wake(&mut follower, 0), Delivery::default());
    OpenOptions::new()
        .write(true)
        .open(&rig.file)
        .unwrap()
        .set_len(0)
        .unwrap();
    append(&rig.file, "\n");
    append(&rig.file, line("fresh"));
    assert_eq!(texts(&rig.wake(&mut follower, 0)), ["fresh"]);
}

#[test]
fn a_deleted_file_followed_by_an_append_to_the_recreated_path_delivers() {
    let rig = Rig::new();
    let mut follower = rig.start();
    append(&rig.file, line("before the delete"));
    assert_eq!(texts(&rig.wake(&mut follower, 0)), ["before the delete"]);
    fs::remove_file(&rig.file).unwrap();
    append(&rig.file, line("after the delete"));
    assert_eq!(texts(&rig.wake(&mut follower, 0)), ["after the delete"]);
    append(&rig.file, line("and one more"));
    assert_eq!(texts(&rig.wake(&mut follower, 0)), ["and one more"]);
}

#[test]
fn an_external_mv_followed_at_once_by_appends_delivers_them_and_the_old_file_first() {
    let rig = Rig::new();
    let mut follower = rig.start();
    append(&rig.file, line("before the mv"));
    assert_eq!(texts(&rig.wake(&mut follower, 0)), ["before the mv"]);
    // A line that reached the old file and was never heard, then the hook's rotation and a line to the new file, all before one wake: the old file is read to its end before the path is opened again.
    append(&rig.file, line("written, not yet woken for"));
    fs::rename(&rig.file, format!("{}.1", rig.file())).unwrap();
    append(&rig.file, line("after the mv"));
    assert_eq!(
        texts(&rig.wake(&mut follower, 0)),
        ["written, not yet woken for", "after the mv"]
    );
    append(&rig.file, line("and one more"));
    assert_eq!(texts(&rig.wake(&mut follower, 0)), ["and one more"]);
}

#[test]
fn an_external_mv_that_leaves_no_file_is_answered_by_recreating_it() {
    let rig = Rig::new();
    let mut follower = rig.start();
    append(&rig.file, line("before the mv"));
    assert_eq!(texts(&rig.wake(&mut follower, 0)), ["before the mv"]);
    fs::rename(&rig.file, format!("{}.1", rig.file())).unwrap();
    assert_eq!(rig.wake(&mut follower, 0), Delivery::default());
    assert!(rig.file.exists(), "the follower created events.tsv again");
    append(&rig.file, line("after the mv"));
    assert_eq!(texts(&rig.wake(&mut follower, 0)), ["after the mv"]);
}

#[test]
fn the_follower_rotates_itself_at_the_size_losing_and_duplicating_nothing() {
    let rig = Rig::new();
    let mut follower = rig.start_rotating(200);
    let want: Vec<String> = (0..50).map(|i| format!("n{i}")).collect();
    let mut got = Vec::new();
    for (i, text) in want.iter().enumerate() {
        append(&rig.file, line(text));
        if i % 5 == 4 {
            // Ten milliseconds apart: all inside the grace of the first rotation, so there is only one.
            got.extend(
                texts(&rig.wake(&mut follower, i as i64 * 10))
                    .into_iter()
                    .map(str::to_owned),
            );
        }
    }
    assert_eq!(got, want);
    let rolled = format!("{}.1", rig.file());
    let held = |path: &str| -> Vec<String> {
        fs::read_to_string(path)
            .unwrap()
            .lines()
            .map(|l| parse_event_line(l).unwrap().text)
            .collect()
    };
    assert!(
        !held(&rolled).is_empty(),
        "events.tsv.1 holds the lines that moved out of events.tsv"
    );
    assert_eq!(
        [held(&rolled), held(rig.file())].concat(),
        want,
        "the two files together hold the stream, each line once"
    );

    // Once the grace is over the next call may rotate again, and still nothing is lost or doubled.
    assert_eq!(rig.wake(&mut follower, 10_000), Delivery::default());
    assert_eq!(
        follower.due(),
        Some(12_000),
        "it rotated again, at the time of that call"
    );
    append(&rig.file, line("last"));
    assert_eq!(texts(&rig.wake(&mut follower, 10_001)), ["last"]);
}

#[test]
fn a_line_appended_to_the_old_file_inside_the_grace_is_delivered_when_it_ends() {
    let rig = Rig::new();
    let mut follower = rig.start_rotating(200);
    // A hook that opened the path just before the rename keeps this descriptor.
    let mut hook = OpenOptions::new().append(true).open(&rig.file).unwrap();
    let fill: String = (0..5).map(|i| line(&format!("fill{i}"))).collect();
    append(&rig.file, fill);
    let d = rig.wake(&mut follower, 1000);
    assert_eq!(texts(&d).len(), 5);
    assert!(
        Path::new(&format!("{}.1", rig.file())).exists(),
        "the follower rotated"
    );
    assert_eq!(
        follower.due(),
        Some(3000),
        "the grace lasts 2 seconds from the call that rotated"
    );

    hook.write_all(line("late, on the old file").as_bytes())
        .unwrap();
    append(&rig.file, line("on the new file"));
    assert_eq!(texts(&rig.wake(&mut follower, 1500)), ["on the new file"]);
    assert_eq!(follower.due(), Some(3000));
    assert_eq!(
        rig.wake(&mut follower, 2999),
        Delivery::default(),
        "one millisecond early"
    );
    assert_eq!(follower.due(), Some(3000));
    assert_eq!(
        texts(&rig.wake(&mut follower, 3000)),
        ["late, on the old file"]
    );
    assert_eq!(
        follower.due(),
        None,
        "nothing is pending once the grace is over"
    );
    assert_eq!(rig.wake(&mut follower, 3001), Delivery::default());
}

#[test]
fn the_call_that_ends_the_grace_reads_the_old_file_before_the_fresh_one() {
    let rig = Rig::new();
    let mut follower = rig.start_rotating(200);
    let mut hook = OpenOptions::new().append(true).open(&rig.file).unwrap();
    append(
        &rig.file,
        (0..5)
            .map(|i| line(&format!("fill{i}")))
            .collect::<String>(),
    );
    assert_eq!(rig.wake(&mut follower, 0).events.len(), 5);
    hook.write_all(line("late").as_bytes()).unwrap();
    append(&rig.file, line("newer"));
    // The old file first, so that a rotation that is due can follow in the same call; each event carries its own time.
    assert_eq!(texts(&rig.wake(&mut follower, 2000)), ["late", "newer"]);
}

#[test]
fn a_rotation_that_cannot_rename_is_reported_and_the_follower_goes_on() {
    let rig = Rig::new();
    let mut follower = rig.start_rotating(200);
    let rolled = format!("{}.1", rig.file());
    fs::create_dir(&rolled).unwrap();
    append(
        &rig.file,
        (0..5)
            .map(|i| line(&format!("fill{i}")))
            .collect::<String>(),
    );
    let d = rig.wake(&mut follower, 0);
    assert_eq!(d.events.len(), 5);
    assert_eq!(d.death, None);
    assert_eq!(
        d.errors,
        [format!(
            "EISDIR: illegal operation on a directory, rename '{}' -> '{rolled}'",
            rig.file()
        )]
    );
    assert_eq!(follower.due(), None, "no grace without a rotation");
    append(&rig.file, line("still followed"));
    let d = rig.wake(&mut follower, 1);
    assert_eq!(d.events.len(), 1);
    assert_eq!(d.death, None);
}

#[test]
fn nothing_is_delivered_after_close_and_a_second_close_is_harmless() {
    let rig = Rig::new();
    let mut follower = rig.start();
    append(&rig.file, line("while open"));
    assert_eq!(texts(&rig.wake(&mut follower, 0)), ["while open"]);
    assert_eq!(follower.close(), None);
    assert_eq!(follower.close(), None);
    append(&rig.file, line("after close"));
    assert_eq!(rig.wake(&mut follower, 0), Delivery::default());
    assert_eq!(follower.due(), None);
}

#[test]
fn a_missing_directory_is_created_and_the_file_in_it() {
    let rig = Rig::new();
    let nested = format!("{}/not/yet/there", rig.dir);
    let (mut follower, first) = Follower::start(&rig.recorder, &nested, 0).unwrap();
    assert_eq!(first, Delivery::default());
    assert!(Path::new(&format!("{nested}/events.tsv")).exists());
    append(
        Path::new(&format!("{nested}/events.tsv")),
        line("in the new directory"),
    );
    assert_eq!(
        texts(&follower.wake(&rig.recorder, 0)),
        ["in the new directory"]
    );
}

#[test]
fn when_the_path_cannot_be_opened_again_the_follower_dies_once() {
    let rig = Rig::new();
    let mut follower = rig.start();
    append(&rig.file, line("before"));
    // The line the old file gained before the path was replaced is still delivered by the call that finds the death.
    append(&rig.file, line("the old file's last"));
    rig.replace_with_a_dead_link();
    let d = rig.wake(&mut follower, 0);
    assert_eq!(
        d.events.iter().map(|e| e.text.as_str()).collect::<Vec<_>>(),
        ["before", "the old file's last"]
    );
    assert_eq!(
        d.death,
        Some(format!(
            "ENOENT: no such file or directory, open '{}'",
            rig.file()
        ))
    );
    assert!(d.errors.is_empty(), "a death is not an error as well");
    assert_eq!(
        rig.wake(&mut follower, 0),
        Delivery::default(),
        "it closed itself: nothing more, and no second death"
    );
    assert_eq!(follower.close(), None);
}

#[test]
fn when_arming_fails_after_a_replacement_the_follower_dies_once() {
    let rig = Rig::new();
    let mut follower = rig.start();
    append(&rig.file, line("while it could hear"));
    rig.recorder.file_fails_from.set(Some(2));
    // What the hook's rotation does: the path goes away, the follower opens it again and has to arm the new file.
    fs::rename(&rig.file, format!("{}.1", rig.file())).unwrap();
    let d = rig.wake(&mut follower, 0);
    assert_eq!(
        d.events.iter().map(|e| e.text.as_str()).collect::<Vec<_>>(),
        ["while it could hear"]
    );
    assert_eq!(
        d.death,
        Some(format!(
            "EMFILE: too many open files, watch '{}'",
            rig.file()
        ))
    );
    assert!(d.errors.is_empty());
    let files = rig
        .recorder
        .calls
        .borrow()
        .iter()
        .filter(|c| c.starts_with("file"))
        .count();
    assert_eq!(
        files, 2,
        "one attempt to arm again, and no retry of its own"
    );

    // Closed means closed: a line in the file it had just reopened is not delivered, and there is no second death.
    append(&rig.file, line("after the death"));
    assert_eq!(rig.wake(&mut follower, 0), Delivery::default());
    assert_eq!(
        rig.recorder
            .calls
            .borrow()
            .iter()
            .filter(|c| c.starts_with("file"))
            .count(),
        2
    );
}

#[test]
fn when_arming_fails_during_a_rotation_the_follower_dies_and_drops_the_grace() {
    let rig = Rig::new();
    let mut follower = rig.start_rotating(200);
    rig.recorder.file_fails_from.set(Some(2));
    append(
        &rig.file,
        (0..5)
            .map(|i| line(&format!("fill{i}")))
            .collect::<String>(),
    );
    let d = rig.wake(&mut follower, 0);
    assert_eq!(
        d.events.len(),
        5,
        "what was read before the failure is delivered"
    );
    assert_eq!(
        d.death,
        Some(format!(
            "EMFILE: too many open files, watch '{}'",
            rig.file()
        ))
    );
    assert!(
        Path::new(&format!("{}.1", rig.file())).exists(),
        "the rename had happened"
    );
    assert_eq!(follower.due(), None, "a dead follower waits for nothing");
    assert_eq!(rig.wake(&mut follower, 5000), Delivery::default());
}

#[test]
fn a_start_that_fails_says_what_node_says_and_leaves_no_switch_and_no_count() {
    let rig = Rig::new();
    // The directory cannot be made: its parent is a file.
    let scratch_file = format!("{}/plain", rig.dir);
    fs::create_dir_all(&rig.dir).unwrap();
    fs::write(&scratch_file, "").unwrap();
    let under = format!("{scratch_file}/state");
    assert_eq!(
        Follower::start(&rig.recorder, &under, 0).err(),
        Some(format!("ENOTDIR: not a directory, mkdir '{under}'"))
    );

    // The watch cannot be armed: the directory, then the file.
    rig.recorder.dir_fails.set(true);
    assert_eq!(
        Follower::start(&rig.recorder, &rig.dir, 0).err(),
        Some(format!("EMFILE: too many open files, watch '{}'", rig.dir))
    );
    rig.recorder.dir_fails.set(false);
    rig.recorder.file_fails_from.set(Some(1));
    assert_eq!(
        Follower::start(&rig.recorder, &rig.dir, 0).err(),
        Some(format!(
            "EMFILE: too many open files, watch '{}'",
            rig.file()
        ))
    );
    rig.recorder.file_fails_from.set(None);
    assert!(
        !rig.switch().exists(),
        "the switch comes on after the arming"
    );

    // The switch cannot be made: events.on is a directory.
    fs::create_dir(rig.switch()).unwrap();
    let err = Follower::start(&rig.recorder, &rig.dir, 0).err();
    assert_eq!(
        err,
        Some(format!(
            "EISDIR: illegal operation on a directory, open '{}'",
            rig.switch().display()
        ))
    );
    // No count was left behind: the next start, once the directory is gone, makes the switch itself.
    fs::remove_dir(rig.switch()).unwrap();
    let _follower = rig.start();
    assert!(rig.switch().is_file());
}

#[test]
fn the_first_follower_turns_the_switch_on_and_the_last_turns_it_off() {
    let rig = Rig::new();
    assert!(
        !Path::new(&rig.dir).exists(),
        "no session has made the directory yet"
    );
    let mut one = rig.start();
    assert!(
        rig.switch().is_file() && rig.file.is_file(),
        "the switch and an empty events.tsv"
    );
    assert_eq!(fs::metadata(&rig.file).unwrap().len(), 0);
    let mut two = rig.start();
    assert_eq!(one.close(), None);
    assert!(rig.switch().exists(), "the second follower still counts");
    drop(one);
    assert_eq!(two.close(), None);
    assert!(!rig.switch().exists(), "the last close removes the switch");
    assert!(
        rig.file.exists(),
        "and nothing else: the log stays for whoever reads it next"
    );
    // A follower dropped without close counts out too.
    let three = rig.start();
    assert!(rig.switch().exists());
    drop(three);
    assert!(!rig.switch().exists());
}

#[test]
fn a_follower_that_dies_is_counted_out_and_the_switch_goes_before_the_death_is_reported() {
    let rig = Rig::new();
    let mut other = rig.start();
    let mut follower = rig.start();
    rig.replace_with_a_dead_link();
    let d = rig.wake(&mut follower, 0);
    assert!(d.death.is_some());
    assert!(
        rig.switch().exists(),
        "another follower of the directory is still open"
    );
    assert_eq!(other.close(), None);
    assert!(
        !rig.switch().exists(),
        "the dead follower had been counted out, so the last close takes the switch off"
    );

    // The last follower dying takes the switch off before its death is returned.
    let rig = Rig::new();
    let mut only = rig.start();
    rig.replace_with_a_dead_link();
    let d = only.wake(&rig.recorder, 0);
    assert!(d.death.is_some());
    assert!(!rig.switch().exists());
    assert_eq!(
        only.close(),
        None,
        "a close after a death counts nothing out twice"
    );
}

#[test]
fn followers_of_two_spellings_of_one_directory_count_together() {
    let rig = Rig::new();
    fs::create_dir_all(&rig.dir).unwrap();
    let link = format!("{}/link", Path::new(&rig.dir).parent().unwrap().display());
    symlink(&rig.dir, &link).unwrap();
    let mut plain = rig.start();
    let (mut slash, _) = Follower::start(&rig.recorder, &format!("{}/", rig.dir), 0).unwrap();
    let (mut linked, _) = Follower::start(&rig.recorder, &link, 0).unwrap();
    assert_eq!(plain.close(), None);
    assert!(rig.switch().exists(), "the other spellings still count");
    assert_eq!(slash.close(), None);
    assert!(rig.switch().exists());
    assert_eq!(linked.close(), None);
    assert!(!rig.switch().exists());
}

#[test]
fn a_switch_that_cannot_be_removed_is_reported_and_close_does_not_panic() {
    let rig = Rig::new();
    let mut follower = rig.start();
    // `rm` of a directory without `recursive` fails.
    fs::remove_file(rig.switch()).unwrap();
    fs::create_dir(rig.switch()).unwrap();
    let want = format!(
        "Path is a directory: rm returned EISDIR (is a directory) {}",
        rig.switch().display()
    );
    assert_eq!(follower.close(), Some(want));
    assert_eq!(
        follower.close(),
        None,
        "a second close reports nothing more"
    );
}

#[test]
fn a_dead_follower_with_a_stuck_switch_reports_both() {
    let rig = Rig::new();
    let mut follower = rig.start();
    fs::remove_file(rig.switch()).unwrap();
    fs::create_dir(rig.switch()).unwrap();
    rig.replace_with_a_dead_link();
    let d = rig.wake(&mut follower, 0);
    assert_eq!(
        d.errors,
        [format!(
            "Path is a directory: rm returned EISDIR (is a directory) {}",
            rig.switch().display()
        )]
    );
    assert_eq!(
        d.death,
        Some(format!(
            "ENOENT: no such file or directory, open '{}'",
            rig.file()
        ))
    );
}

fn watching() -> (Watch, Receiver<Heard>) {
    let (sink, keys) = mpsc::channel();
    (Watch::start(sink).unwrap(), keys)
}

#[test]
fn the_watch_wakes_the_follower_for_an_append_a_replacement_and_a_rotation() {
    let rig = Rig::new();
    let (watch, keys) = watching();
    let (mut follower, first) = start_with(&watch, &rig.dir, 0, 200).unwrap();
    assert_eq!(first, Delivery::default());
    settle(&keys);

    append(&rig.file, line("append"));
    assert_eq!(heard(&keys), Key::Events);
    settle(&keys);
    assert_eq!(texts(&follower.wake(&watch, 0)), ["append"]);
    settle(&keys);

    // The hook rotates: the path is moved away and a line goes into a new file. Every wake after it must still come, which is the file being armed again.
    fs::rename(&rig.file, format!("{}.1", rig.file())).unwrap();
    append(&rig.file, line("after the mv"));
    assert_eq!(heard(&keys), Key::Events);
    settle(&keys);
    assert_eq!(texts(&follower.wake(&watch, 0)), ["after the mv"]);
    settle(&keys);
    append(&rig.file, line("on the new inode"));
    assert_eq!(
        heard(&keys),
        Key::Events,
        "the file the follower opened again is watched"
    );
    settle(&keys);
    assert_eq!(texts(&follower.wake(&watch, 0)), ["on the new inode"]);
    settle(&keys);

    // The follower rotates itself, and the fresh file is watched too.
    append(
        &rig.file,
        (0..5)
            .map(|i| line(&format!("fill{i}")))
            .collect::<String>(),
    );
    assert_eq!(heard(&keys), Key::Events);
    settle(&keys);
    assert_eq!(texts(&follower.wake(&watch, 1000)).len(), 5);
    assert_eq!(follower.due(), Some(3000));
    settle(&keys);
    append(&rig.file, line("on the fresh file"));
    assert_eq!(
        heard(&keys),
        Key::Events,
        "the file of a rotation is watched"
    );
    settle(&keys);
    assert_eq!(texts(&follower.wake(&watch, 1001)), ["on the fresh file"]);
    assert_eq!(follower.close(), None);
}

#[test]
fn a_deleted_events_file_is_made_again_and_heard() {
    let rig = Rig::new();
    let (watch, keys) = watching();
    let (mut follower, _) = Follower::start(&watch, &rig.dir, 0).unwrap();
    settle(&keys);
    fs::remove_file(&rig.file).unwrap();
    assert_eq!(heard(&keys), Key::Events);
    settle(&keys);
    assert_eq!(follower.wake(&watch, 0), Delivery::default());
    assert!(rig.file.exists());
    settle(&keys);
    append(&rig.file, line("after the delete"));
    assert_eq!(heard(&keys), Key::Events);
    settle(&keys);
    assert_eq!(texts(&follower.wake(&watch, 0)), ["after the delete"]);
}
