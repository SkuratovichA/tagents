//! Cases of `packages/notify/test/platform.test.ts` and `log-notifier.test.ts`, one Rust test each:
//! - the matrix: darwin and linux against the four backends: `the_matrix_darwin_and_linux_against_the_four_backends`
//! - services: launchd on darwin only: not applicable: the service managers stay node
//! - unsupported refuses to post: `unsupported_refuses_to_post_and_to_withdraw`
//! - the macOS platform: permission asks the helper, setup builds only when not up to date: not applicable: `setup` and `permission` serve CLI verbs that stay node
//! - a post logs one line and reports it shown (log-notifier): `a_post_logs_one_line_and_reports_it_shown`
//! - a withdraw logs one line with the id (log-notifier): `a_withdraw_logs_one_line_with_the_id`
//!
//! Cases the node files do not have: `the_log_line_of_a_post_is_node_s_word_for_word`, `the_helper_app_is_the_environment_s_or_the_application_support_copy`, `the_names_of_the_systems_are_node_s`, `the_backend_words_are_the_options_four`.

use super::*;
use crate::notify::kinds::NoticeKind;
use crate::notify::log::RecordingLog;
use crate::notify::notifier::ClickAction;

fn notice() -> Notice {
    Notice {
        id: "tagents-12".into(),
        thread: "sess-1".into(),
        kind: NoticeKind::TurnDone,
        title: "build".into(),
        subtitle: "Answer ready".into(),
        body: "First line".into(),
        click: ClickAction::default(),
        terminal_pid: None,
        skip_if_frontmost: None,
    }
}

fn name_of(os: &str, backend: Backend) -> Option<&'static str> {
    pick(os, backend, Arc::new(RecordingLog::new()), "/A.app").map(|p| p.name)
}

#[test]
fn the_matrix_darwin_and_linux_against_the_four_backends() {
    let got: Vec<(String, Option<&str>)> = ["darwin", "linux"]
        .iter()
        .flat_map(|os| {
            [
                ("auto", Backend::Auto),
                ("macos", Backend::Macos),
                ("log", Backend::Log),
                ("none", Backend::None),
            ]
            .map(|(word, backend)| (format!("{os}/{word}"), name_of(os, backend)))
        })
        .collect();
    let expected = [
        ("darwin/auto", Some("macos")),
        ("darwin/macos", Some("macos")),
        ("darwin/log", Some("log")),
        ("darwin/none", None),
        ("linux/auto", Some("unsupported")),
        ("linux/macos", Some("unsupported")),
        ("linux/log", Some("log")),
        ("linux/none", None),
    ];
    let expected: Vec<(String, Option<&str>)> = expected
        .iter()
        .map(|(k, v)| ((*k).to_owned(), *v))
        .collect();
    assert_eq!(got, expected);
}

#[test]
fn unsupported_refuses_to_post_and_to_withdraw() {
    let mut platform = pick(
        "linux",
        Backend::Auto,
        Arc::new(RecordingLog::new()),
        "/A.app",
    )
    .unwrap();
    assert_eq!(platform.notifier.name(), "unsupported");
    assert_eq!(
        platform.notifier.withdraw("x"),
        Err("no notification backend for linux yet".into())
    );
    assert_eq!(
        platform.notifier.post(&notice()),
        Err("no notification backend for linux yet".into())
    );
    let mut windows = pick("win32", Backend::Macos, Arc::new(RecordingLog::new()), "").unwrap();
    assert_eq!(
        windows.notifier.withdraw("x"),
        Err("no notification backend for win32 yet".into())
    );
}

#[test]
fn a_post_logs_one_line_and_reports_it_shown() {
    let log = RecordingLog::new();
    let mut platform = pick("linux", Backend::Log, Arc::new(log.clone()), "").unwrap();
    assert_eq!(platform.notifier.name(), "log");
    assert_eq!(
        platform.notifier.post(&notice()),
        Ok(PostResult {
            shown: true,
            why: None
        })
    );
    let lines = log.lines();
    assert_eq!(lines.len(), 1);
    for part in [
        "tagents-12",
        "turn_done",
        "build",
        "Answer ready",
        "First line",
    ] {
        assert!(lines[0].contains(part), "{part}");
    }
}

#[test]
fn a_withdraw_logs_one_line_with_the_id() {
    let log = RecordingLog::new();
    let mut platform = pick("darwin", Backend::Log, Arc::new(log.clone()), "").unwrap();
    assert_eq!(platform.notifier.withdraw("tagents-12"), Ok(()));
    assert_eq!(log.lines(), ["withdraw tagents-12"]);
}

#[test]
fn the_log_line_of_a_post_is_node_s_word_for_word() {
    let log = RecordingLog::new();
    let mut notifier = LogNotifier {
        log: Arc::new(log.clone()),
    };
    let mut n = notice();
    n.body = "two\nlines \"q\"".into();
    n.click = ClickAction {
        argv: vec!["/bin/tagents".into(), "resume".into()],
        env: vec![],
    };
    n.terminal_pid = Some(77);
    n.skip_if_frontmost = Some(true);
    notifier.post(&n).unwrap();
    n.click = ClickAction::default();
    n.terminal_pid = None;
    n.skip_if_frontmost = Some(false);
    notifier.post(&n).unwrap();
    assert_eq!(
        log.lines(),
        [
            r#"post tagents-12 turn_done "build" "Answer ready" "two\nlines \"q\"" click=/bin/tagents resume pid=77 skip-if-frontmost"#,
            r#"post tagents-12 turn_done "build" "Answer ready" "two\nlines \"q\"" click=terminal pid=none always"#,
        ]
    );
}

#[test]
fn the_helper_app_is_the_environment_s_or_the_application_support_copy() {
    assert_eq!(app_path(Some("/x/T.app"), "/h"), "/x/T.app");
    assert_eq!(
        app_path(Some(""), "/h"),
        "/h/Library/Application Support/tagents/TagentsNotify.app"
    );
    assert_eq!(
        app_path(None, "/h/"),
        "/h/Library/Application Support/tagents/TagentsNotify.app"
    );
}

#[test]
fn the_names_of_the_systems_are_node_s() {
    let name = os_name();
    assert_eq!(
        name,
        if cfg!(target_os = "macos") {
            "darwin"
        } else {
            "linux"
        }
    );
}

#[test]
fn the_backend_words_are_the_options_four() {
    assert_eq!(Backend::parse("auto"), Some(Backend::Auto));
    assert_eq!(Backend::parse("macos"), Some(Backend::Macos));
    assert_eq!(Backend::parse("log"), Some(Backend::Log));
    assert_eq!(Backend::parse("none"), Some(Backend::None));
    assert_eq!(Backend::parse("Log"), None);
}
