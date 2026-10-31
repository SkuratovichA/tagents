//! What the options file says now about the options in force, and what each change of it logs.

use super::*;
use crate::notify::options::Click;

fn goto() -> Options {
    Options {
        click: Click::Goto,
        ..Options::default()
    }
}

fn problems(lines: &[&str]) -> Loaded {
    Loaded::Invalid(lines.iter().map(|line| (*line).to_owned()).collect())
}

#[test]
fn a_bad_file_runs_on_the_defaults_and_says_each_problem_at_the_start() {
    let log = RecordingLog::new();
    let settings = Settings::first(
        problems(&[
            "bogus: Unrecognized key",
            "events.turn_done.enabled: Expected boolean",
        ]),
        &log,
    );
    assert_eq!(
        log.lines(),
        [
            "options: bogus: Unrecognized key",
            "options: events.turn_done.enabled: Expected boolean"
        ]
    );
    assert_eq!(settings.current, Options::default());
    assert_eq!(settings.state, "invalid");
}

#[test]
fn the_first_read_logs_no_reload_and_names_the_state_of_the_file() {
    let log = RecordingLog::new();
    let found = Settings::first(Loaded::Found(goto()), &log);
    assert_eq!((found.state, found.current), ("found", goto()));
    let missing = Settings::first(Loaded::Missing(Options::default()), &log);
    assert_eq!(missing.state, "not found");
    assert_eq!(log.lines(), Vec::<String>::new());
}

#[test]
fn each_problem_is_logged_once_however_often_the_file_is_read_and_a_valid_change_is_a_reload() {
    let (bad, worse) = (
        [
            "bogus: Unrecognized key",
            "events.turn_done.enabled: Expected boolean",
        ],
        ["events: Expected object", "click: Invalid enum value"],
    );
    let log = RecordingLog::new();
    let mut settings = Settings::first(problems(&bad), &log);
    let lines = |texts: &[&str]| -> Vec<String> {
        texts
            .iter()
            .map(|text| format!("options: {text}"))
            .collect()
    };
    assert_eq!(
        log.lines(),
        lines(&bad),
        "the file the service started with: each problem once"
    );
    settings.apply(problems(&bad), &log);
    assert_eq!(
        log.lines(),
        lines(&bad),
        "the same problems read again: nothing new"
    );
    settings.apply(problems(&worse), &log);
    assert_eq!(
        log.lines(),
        [lines(&bad), lines(&worse)].concat(),
        "other problems are news, once each"
    );
    settings.apply(problems(&worse), &log);
    assert_eq!(log.lines().len(), 4, "and not news twice");
    settings.apply(Loaded::Found(goto()), &log);
    assert_eq!(
        log.lines().last().map(String::as_str),
        Some("options reloaded")
    );
    assert_eq!(log.lines().len(), 5);
    assert_eq!(settings.state, "found");
    settings.apply(problems(&bad), &log);
    assert_eq!(
        log.lines().len(),
        7,
        "a problem after a valid file is news again, as the defaults are back in force"
    );
    assert_eq!(settings.current, Options::default());
}

#[test]
fn a_reload_to_the_value_in_force_is_ignored_and_a_changed_backend_waits_for_a_restart() {
    let log = RecordingLog::new();
    let mut settings = Settings::first(Loaded::Missing(Options::default()), &log);
    let logging = Options {
        backend: Backend::Log,
        ..Options::default()
    };
    settings.apply(Loaded::Found(logging.clone()), &log);
    assert_eq!(
        log.lines(),
        [
            "options reloaded",
            "backend changes take effect after a restart (tagents notify install)"
        ]
    );
    assert_eq!(
        settings.current, logging,
        "the options are in force at once; the backend is the one the service started with"
    );
    settings.apply(Loaded::Found(logging.clone()), &log);
    assert_eq!(log.lines().len(), 2, "the same value is no reload");
    let goto_too = Options {
        click: Click::Goto,
        ..logging
    };
    settings.apply(Loaded::Found(goto_too), &log);
    assert_eq!(
        log.lines()[2..],
        [
            "options reloaded",
            "backend changes take effect after a restart (tagents notify install)"
        ],
        "the backend still differs from the running one"
    );
}

#[test]
fn a_file_that_is_back_to_the_defaults_after_a_bad_one_is_no_reload() {
    let log = RecordingLog::new();
    let mut settings = Settings::first(Loaded::Missing(Options::default()), &log);
    settings.apply(problems(&["bogus: Unrecognized key"]), &log);
    settings.apply(Loaded::Found(Options::default()), &log);
    assert_eq!(log.lines(), ["options: bogus: Unrecognized key"]);
    assert_eq!(settings.state, "found");
}
