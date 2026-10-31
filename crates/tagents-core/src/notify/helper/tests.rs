//! Cases of `packages/notify/test/helper.test.ts` (9, in the node file's order), against a stub helper app on disk, which is the real child path:
//! - post sends the notice on stdin and maps shown: `post_sends_the_notice_on_stdin_and_maps_shown`; the 5000 ms deadline: `the_deadline_of_a_call_is_five_seconds`
//! - post maps why when not shown: `post_maps_why_when_not_shown`
//! - ok:false rejects with the helper error text: `ok_false_is_an_error_with_the_helper_text`
//! - a timeout rejects naming the seconds: `a_timeout_names_the_seconds_and_kills_the_helper`
//! - unparseable output rejects with stdout and stderr, cut at 200 characters: `unreadable_output_gives_stdout_and_stderr_cut_at_200_units`
//! - a missing binary names the app and the install command: `a_missing_binary_names_the_app_and_the_install_command`
//! - withdraw passes the id as an argument: `withdraw_passes_the_id_as_an_argument_and_no_input`
//! - status, delivered and authorize: not applicable: `helperStatus`, `helperDelivered` and `helperAuthorize` serve CLI verbs that stay node
//! - authorize reports its own timeout in seconds: not applicable: `helperAuthorize` stays node; the seconds text of the daemon's calls is `a_timeout_names_the_seconds_and_kills_the_helper`
//!
//! Cases of the Rust copy that node's file does not have: the helper's input is `JSON.stringify` of the notice (`the_input_is_the_notice_with_node_keys_in_node_order`, `the_input_escapes_as_json_stringify_does`), the schema (`a_field_of_the_wrong_type_makes_the_line_unreadable`) the exit code is not read (`the_exit_code_is_not_read`) and the cut of the unreadable output that falls inside a surrogate pair (`a_cut_between_the_halves_of_a_pair_is_written_as_the_escape_of_the_high_half`).

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::time::{Duration, Instant};

use super::*;
use crate::notify::kinds::NoticeKind;
use crate::notify::notifier::ClickAction;
use crate::testing::Scratch;
use crate::testing::gate::{forking, write_executable};

/// A helper app of a test's own: `<dir>/T.app/Contents/MacOS/tagents-notify` is a shell script.
struct App(Scratch);

impl App {
    fn new(script: &str) -> App {
        let scratch = Scratch::new();
        write_executable(
            &scratch.path().join("T.app/Contents/MacOS/tagents-notify"),
            &format!("#!/bin/sh\n{script}\n"),
        );
        App(scratch)
    }

    fn app(&self) -> String {
        self.0.path().join("T.app").to_string_lossy().into_owned()
    }

    fn file(&self, name: &str) -> String {
        fs::read_to_string(self.0.path().join(name)).unwrap()
    }

    /// A script that records its arguments and its input, then prints `answer`.
    fn recording(answer: &str) -> App {
        App::new(&format!(
            "D=\"$(dirname \"$0\")/../../..\"; echo \"$@\" > \"$D/args\"; cat > \"$D/input\"; printf '%s' '{answer}'"
        ))
    }
}

fn notice() -> Notice {
    Notice {
        id: "n1".into(),
        thread: "t".into(),
        kind: NoticeKind::TurnDone,
        title: "T".into(),
        subtitle: "S".into(),
        body: "B".into(),
        click: ClickAction {
            argv: vec!["a".into()],
            env: vec![],
        },
        terminal_pid: None,
        skip_if_frontmost: None,
    }
}

#[test]
fn post_sends_the_notice_on_stdin_and_maps_shown() {
    let app = App::recording("{\"ok\":true,\"shown\":true}\n");
    let _forking = forking();
    let result = HelperNotifier::new(&app.app()).post(&notice()).unwrap();
    assert_eq!(
        result,
        PostResult {
            shown: true,
            why: None
        }
    );
    assert_eq!(
        helper_binary("/Apps/T.app"),
        "/Apps/T.app/Contents/MacOS/tagents-notify"
    );
    assert_eq!(app.file("args"), "post\n");
    assert_eq!(
        app.file("input"),
        r#"{"id":"n1","thread":"t","kind":"turn_done","title":"T","subtitle":"S","body":"B","click":{"argv":["a"],"env":{}}}"#
    );
    assert_eq!(HelperNotifier::new("x").name(), "macos");
}

#[test]
fn the_deadline_of_a_call_is_five_seconds() {
    assert_eq!(HELPER_TIMEOUT_MS, 5000);
}

#[test]
fn post_maps_why_when_not_shown() {
    let app = App::recording("{\"ok\":true,\"shown\":false,\"why\":\"frontmost\"}");
    let bare = App::recording("{\"ok\":true}");
    let _forking = forking();
    let result = HelperNotifier::new(&app.app()).post(&notice()).unwrap();
    assert_eq!(
        result,
        PostResult {
            shown: false,
            why: Some("frontmost".into())
        }
    );
    assert_eq!(
        HelperNotifier::new(&bare.app()).post(&notice()).unwrap(),
        PostResult {
            shown: false,
            why: None
        }
    );
}

#[test]
fn ok_false_is_an_error_with_the_helper_text() {
    let app = App::recording("{\"ok\":false,\"error\":\"notifications are denied\"}");
    let bare = App::recording("{\"ok\":false}");
    let _forking = forking();
    assert_eq!(
        HelperNotifier::new(&app.app()).post(&notice()),
        Err("notifications are denied".into())
    );
    assert_eq!(
        HelperNotifier::new(&bare.app()).post(&notice()),
        Err("the notification helper failed".into())
    );
}

#[test]
fn the_exit_code_is_not_read() {
    let app = App::new("echo '{\"ok\":true,\"shown\":true}'; exit 1");
    let _forking = forking();
    assert!(
        HelperNotifier::new(&app.app())
            .post(&notice())
            .unwrap()
            .shown
    );
}

#[test]
fn a_timeout_names_the_seconds_and_kills_the_helper() {
    let app = App::new("sleep 30");
    let five = App::new("sleep 30");
    let _forking = forking();
    let began = Instant::now();
    let failed = run_helper(&app.app(), &["withdraw", "x"], None, 200).unwrap_err();
    assert_eq!(failed, "the notification helper timed out after 0.2 s");
    assert!(began.elapsed() < Duration::from_secs(10));
    assert_eq!(
        run_helper(&five.app(), &["post"], None, 1000).unwrap_err(),
        "the notification helper timed out after 1 s"
    );
}

#[test]
fn unreadable_output_gives_stdout_and_stderr_cut_at_200_units() {
    let long = "x".repeat(500);
    let app = App::new(&format!("printf '%s' '{long}'; echo boom >&2"));
    let empty = App::new("true");
    let _forking = forking();
    let failed = HelperNotifier::new(&app.app()).post(&notice()).unwrap_err();
    let cut = "x".repeat(200);
    assert_eq!(
        failed,
        format!(
            "unreadable output from the notification helper: stdout \"{cut}\", stderr \"boom\\n\""
        )
    );
    assert_eq!(
        HelperNotifier::new(&empty.app())
            .post(&notice())
            .unwrap_err(),
        "unreadable output from the notification helper: stdout \"\", stderr \"\""
    );
}

/// The parity scenario `helper: emoji garbage, cut in half of a pair` (`tests/rust-notify-parity.sh`): node stringifies `stdout.slice(0, 200)`, a cut that can leave the high half of a pair, which `JSON.stringify` writes as an escape and never as U+FFFD.
#[test]
fn a_cut_between_the_halves_of_a_pair_is_written_as_the_escape_of_the_high_half() {
    let app = App::new(
        "printf 'a'; i=0; while [ $i -lt 100 ]; do printf '😀'; i=$((i+1)); done; echo b >&2",
    );
    let _forking = forking();
    let failed = HelperNotifier::new(&app.app()).post(&notice()).unwrap_err();
    assert_eq!(
        failed,
        format!(
            "unreadable output from the notification helper: stdout \"a{}\\ud83d\", stderr \"b\\n\"",
            "😀".repeat(99)
        )
    );
}

#[test]
fn a_field_of_the_wrong_type_makes_the_line_unreadable() {
    for line in [
        "{\"ok\":1}",
        "{\"ok\":true,\"shown\":\"yes\"}",
        "{\"ok\":true,\"why\":null}",
        "{\"ok\":true,\"status\":5}",
        "{\"ok\":true,\"ids\":[1]}",
        "[{\"ok\":true}]",
        "null",
    ] {
        assert!(read_line(line).is_none(), "{line}");
    }
    assert!(read_line("{\"ok\":true,\"extra\":[1,{}],\"ids\":[\"a\"]}").is_some());
    assert_eq!(
        read_line("{\"ok\":false,\"ok\":true}\n"),
        Some(Ok(HelperLine {
            shown: None,
            why: None
        })),
        "the last key wins"
    );
}

#[test]
fn a_missing_binary_names_the_app_and_the_install_command() {
    let dir = App::new("true");
    let _forking = forking();
    let failed = HelperNotifier::new("/no/such/T.app")
        .withdraw("x")
        .unwrap_err();
    assert_eq!(
        failed,
        "cannot start the notification helper at /no/such/T.app (spawn /no/such/T.app/Contents/MacOS/tagents-notify ENOENT); run `tagents notify install`"
    );
    let path = dir.0.path().join("T.app/Contents/MacOS/tagents-notify");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    let failed = HelperNotifier::new(&dir.app()).withdraw("x").unwrap_err();
    assert!(
        failed.ends_with("EACCES); run `tagents notify install`"),
        "{failed}"
    );
}

#[test]
fn withdraw_passes_the_id_as_an_argument_and_no_input() {
    let app = App::recording("{\"ok\":true}");
    let _forking = forking();
    HelperNotifier::new(&app.app()).withdraw("abc").unwrap();
    assert_eq!(app.file("args"), "withdraw abc\n");
    assert_eq!(app.file("input"), "");
}

#[test]
fn the_input_is_the_notice_with_node_keys_in_node_order() {
    let mut n = notice();
    n.click = ClickAction {
        argv: vec!["/bin/x".into(), "y z".into()],
        env: vec![("TA".into(), "1".into()), ("B".into(), "2".into())],
    };
    n.terminal_pid = Some(4242);
    n.skip_if_frontmost = Some(true);
    assert_eq!(
        notice_json(&n),
        r#"{"id":"n1","thread":"t","kind":"turn_done","title":"T","subtitle":"S","body":"B","click":{"argv":["/bin/x","y z"],"env":{"TA":"1","B":"2"}},"terminalPid":4242,"skipIfFrontmost":true}"#
    );
    n.terminal_pid = None;
    assert!(!notice_json(&n).contains("terminalPid"));
    n.skip_if_frontmost = None;
    assert!(!notice_json(&n).contains("skipIfFrontmost"));
    for kind in [
        NoticeKind::Question,
        NoticeKind::Permission,
        NoticeKind::CacheExpiring,
        NoticeKind::SessionEnd,
    ] {
        n.kind = kind;
        assert!(notice_json(&n).contains(&format!("\"kind\":\"{}\"", kind.as_str())));
    }
}

/// The escaping itself is pinned by `json::tests::quote_escapes_as_json_stringify_does`; here the input reaches the line through the same writer.
#[test]
fn the_input_escapes_as_json_stringify_does() {
    let text = "a\"\\\n\t\u{1f}\u{2028}\u{2029}\u{e9}\u{8}\u{c}\r\u{7f}\u{0}";
    let mut n = notice();
    n.body = text.to_owned();
    assert!(notice_json(&n).contains(&format!("\"body\":{}", json::quote(text))));
}

/// Node: `JSON.parse(('﻿{"ok":true,"shown":true}﻿').trim())` is `{ ok: true, shown: true }`.
#[test]
fn a_u_feff_at_both_ends_of_the_helper_output_is_trimmed_before_it_is_parsed() {
    let bom = '\u{feff}';
    assert_eq!(
        read_line(&format!("{bom}{{\"ok\":true,\"shown\":true}}{bom}")),
        Some(Ok(HelperLine {
            shown: Some(true),
            why: None
        }))
    );
}
