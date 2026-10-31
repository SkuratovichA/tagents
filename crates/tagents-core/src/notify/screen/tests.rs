//! Cases of `packages/notify/test/screen.test.ts`, one Rust test each (15, in the node file's order):
//! - a client looking at the pane's window: `a_client_on_the_panes_window_is_visible`
//! - no client on the window: `no_client_on_the_window_is_not_visible`
//! - two clients on the window: `two_clients_on_the_window_the_more_active_gets_the_click`
//! - no clients at all: `no_clients_at_all_has_no_pid`
//! - a title that holds the separator: `a_title_that_holds_the_separator_keeps_the_rest`
//! - an empty title is a title: `an_empty_title_is_a_title`
//! - empty output, or output with no pane line, is null: `no_pane_line_is_nothing`
//! - a client line that is not numbers is skipped: `a_client_line_that_is_not_numbers_is_skipped`
//! - seen through the viewport: `seen_through_the_viewport_the_dashboard_terminal_stands_in`
//! - the dashboard is not on screen: `a_pane_only_the_viewport_shows_is_not_visible`
//! - a real client on the window beats the viewport: `a_real_client_beats_the_viewport_and_an_unset_option_changes_nothing`
//! - tmuxScreen asks tmux once, with two commands and no tab in a format: `the_probe_runs_tmux_once_with_the_node_arguments`
//! - a pane line with no window id is the pane tmux 3.7 answers with: `a_pane_line_with_no_window_id_is_no_such_pane`
//! - tmuxScreen: tmux saying the pane is not there is NO_SUCH_PANE, and only that: `only_tmux_saying_so_is_no_such_pane`
//! - tmuxScreen: a failing tmux, a timeout and a tmux that cannot start are all null: `a_failing_a_slow_and_a_missing_tmux_say_nothing`

use std::fs;
use std::time::{Duration, Instant};

use super::*;
use crate::testing::Scratch;

fn screen(visible: bool, client_pid: Option<u32>, title: &str) -> Option<ScreenAnswer> {
    Some(ScreenAnswer::Screen(Screen {
        visible,
        client_pid,
        pane_title: title.to_owned(),
    }))
}

const VIEWPORT: &str = "C|@|1700000900|@|5555|@|@3|@|/dev/ttys009|@|alpha";

#[test]
fn a_client_on_the_panes_window_is_visible() {
    let out = [
        "P|@|@3|@|✳ build",
        "C|@|1700000100|@|4001|@|@3",
        "C|@|1700000200|@|4002|@|@1",
        "",
    ]
    .join("\n");
    assert_eq!(parse_screen(&out), screen(true, Some(4001), "✳ build"));
}

#[test]
fn no_client_on_the_window_is_not_visible() {
    let out = [
        "P|@|@3|@|build",
        "C|@|1700000100|@|4001|@|@1",
        "C|@|1700000900|@|4002|@|@2",
        "C|@|1700000500|@|4003|@|@1",
    ]
    .join("\n");
    assert_eq!(parse_screen(&out), screen(false, Some(4002), "build"));
}

#[test]
fn two_clients_on_the_window_the_more_active_gets_the_click() {
    let out = [
        "P|@|@3|@|build",
        "C|@|1700000100|@|4001|@|@3",
        "C|@|1700000900|@|4002|@|@3",
        "C|@|1700009999|@|4003|@|@9",
    ]
    .join("\n");
    assert_eq!(parse_screen(&out), screen(true, Some(4002), "build"));
}

#[test]
fn equally_active_clients_give_the_click_to_the_first() {
    let out = ["P|@|@3|@|b", "C|@|5|@|4001|@|@3", "C|@|5|@|4002|@|@3"].join("\n");
    assert_eq!(parse_screen(&out), screen(true, Some(4001), "b"));
}

#[test]
fn no_clients_at_all_has_no_pid() {
    assert_eq!(
        parse_screen("P|@|@3|@|build\n"),
        screen(false, None, "build")
    );
}

#[test]
fn a_title_that_holds_the_separator_keeps_the_rest() {
    let s = parse_screen("P|@|@3|@|a |@| b |@|\nC|@|1|@|9|@|@3");
    assert_eq!(s, screen(true, Some(9), "a |@| b |@|"));
}

#[test]
fn an_empty_title_is_a_title() {
    assert_eq!(parse_screen("P|@|@3|@|\n"), screen(false, None, ""));
}

#[test]
fn no_pane_line_is_nothing() {
    assert_eq!(parse_screen(""), None);
    assert_eq!(parse_screen("\n"), None);
    assert_eq!(parse_screen("C|@|1|@|9|@|@3\n"), None);
    assert_eq!(
        parse_screen("P|@|@3\n"),
        None,
        "a pane line of two fields is no pane line"
    );
}

#[test]
fn only_the_first_pane_line_counts() {
    assert_eq!(
        parse_screen("P|@|@3|@|first\nP|@|@4|@|second"),
        screen(false, None, "first")
    );
}

#[test]
fn a_client_line_that_is_not_numbers_is_skipped() {
    let s = parse_screen("P|@|@3|@|t\nC|@|soon|@|9|@|@3\nC|@|5|@|x|@|@3\nC|@|7|@|8|@|@1");
    assert_eq!(s, screen(false, Some(8), "t"));
    // `\d` is ASCII only, and an empty field is no number.
    let arabic = "٣";
    let odd = format!(
        "P|@|@3|@|t\nC|@|{arabic}|@|9|@|@3\nC|@||@|9|@|@3\nC|@|1|@|+9|@|@3\nC|@|1|@|0x9|@|@3"
    );
    assert_eq!(parse_screen(&odd), screen(false, None, "t"));
}

#[test]
fn a_client_line_needs_four_or_six_fields() {
    let s = parse_screen(
        "P|@|@3|@|t\nC|@|1|@|9\nC|@|1|@|9|@|@3|@|tty\nC|@|1|@|9|@|@3|@|tty|@|s|@|extra",
    );
    assert_eq!(s, screen(false, None, "t"));
}

#[test]
fn seen_through_the_viewport_the_dashboard_terminal_stands_in() {
    let out = [
        "P|@|@3|@|build",
        "V|@|/dev/ttys009",
        VIEWPORT,
        "C|@|1700000100|@|4001|@|@7|@|/dev/ttys001|@|tagents",
        "C|@|1700000300|@|4002|@|@7|@|/dev/ttys002|@|tagents",
        "C|@|1700009999|@|4003|@|@1|@|/dev/ttys003|@|beta",
        "",
    ]
    .join("\n");
    assert_eq!(parse_screen(&out), screen(true, Some(4002), "build"));
}

#[test]
fn a_pane_only_the_viewport_shows_is_not_visible() {
    let out = [
        "P|@|@3|@|build",
        "V|@|/dev/ttys009",
        VIEWPORT,
        "C|@|1700000100|@|4003|@|@1|@|/dev/ttys003|@|beta",
        "",
    ]
    .join("\n");
    assert_eq!(parse_screen(&out), screen(false, Some(4003), "build"));
    let alone = ["P|@|@3|@|build", "V|@|/dev/ttys009", VIEWPORT].join("\n");
    assert_eq!(parse_screen(&alone), screen(false, None, "build"));
}

#[test]
fn a_real_client_beats_the_viewport_and_an_unset_option_changes_nothing() {
    let direct = [
        "P|@|@3|@|b",
        "V|@|/dev/ttys009",
        VIEWPORT,
        "C|@|1|@|4001|@|@3|@|/dev/ttys001|@|beta",
        "C|@|2|@|4002|@|@7|@|/dev/ttys002|@|tagents",
    ]
    .join("\n");
    assert_eq!(parse_screen(&direct), screen(true, Some(4001), "b"));
    let unset = [
        "P|@|@3|@|b",
        "V|@|",
        "C|@|5|@|5555|@|@3|@|/dev/ttys009|@|alpha",
        "C|@|2|@|4002|@|@7|@|/dev/ttys002|@|tagents",
    ]
    .join("\n");
    assert_eq!(parse_screen(&unset), screen(true, Some(5555), "b"));
}

#[test]
fn a_pane_line_with_no_window_id_is_no_such_pane() {
    assert_eq!(
        parse_screen("P|@||@|\nC|@|5|@|9|@|@3\n"),
        Some(ScreenAnswer::NoSuchPane)
    );
    assert_eq!(
        parse_screen("C|@|5|@|9|@|@3\n"),
        None,
        "no pane line at all says nothing"
    );
}

/// A stand-in for tmux: `/bin/sh` running `script`, which sees the arguments the probe gives tmux. It is never an executable file of its own, so no other test's fork can hold it busy for writing.
fn stub(script: &str) -> (Command, Scratch) {
    let dir = Scratch::new();
    let file = dir.path().join("tmux.sh");
    fs::write(&file, script).unwrap();
    let mut command = Command::new("/bin/sh");
    command.arg(&file);
    (command, dir)
}

fn ask(command: Command) -> Option<ScreenAnswer> {
    probe(command, "%12", &Stop::default())
}

#[test]
fn the_probe_runs_tmux_once_with_the_node_arguments() {
    let (command, dir) = stub(
        r#"printf '%s\n' "$@" > "$(dirname "$0")/args"; echo run >> "$(dirname "$0")/runs"; printf 'P|@|@3|@|build\nC|@|5|@|9|@|@3\n'"#,
    );
    assert_eq!(ask(command), screen(true, Some(9), "build"));
    let args = fs::read_to_string(dir.path().join("args")).unwrap();
    let expected = [
        "display",
        "-p",
        "-t",
        "%12",
        "P|@|#{window_id}|@|#{pane_title}",
        ";",
        "list-clients",
        "-F",
        "C|@|#{client_activity}|@|#{client_pid}|@|#{window_id}|@|#{client_tty}|@|#{client_session}",
        ";",
        "display",
        "-p",
        "-t",
        "%12",
        "V|@|#{@tagents_viewport_tty}",
    ];
    assert_eq!(args.lines().collect::<Vec<_>>(), expected);
    assert_eq!(
        fs::read_to_string(dir.path().join("runs")).unwrap(),
        "run\n"
    );
    assert!(
        !args.contains('\t'),
        "a literal tab in a tmux format renders as _ without a UTF-8 locale"
    );
}

#[test]
fn the_probe_gives_tmux_the_environment_it_has() {
    let (command, dir) =
        stub(r#"printf '%s' "$PATH" > "$(dirname "$0")/path"; printf 'P|@|@3|@|t\n'"#);
    assert!(ask(command).is_some());
    assert_eq!(
        fs::read_to_string(dir.path().join("path")).unwrap(),
        std::env::var("PATH").unwrap()
    );
}

#[test]
fn only_tmux_saying_so_is_no_such_pane() {
    let (exit_zero, _dir) = stub("printf 'P|@||@|\\n'");
    assert_eq!(ask(exit_zero), Some(ScreenAnswer::NoSuchPane));
    let (older_tmux, _dir) = stub("echo \"can't find pane: %99\" >&2; exit 1");
    assert_eq!(ask(older_tmux), Some(ScreenAnswer::NoSuchPane));
    let (no_server, _dir) = stub("echo 'no server running on /tmp/tmux-501/default' >&2; exit 1");
    assert_eq!(
        ask(no_server),
        None,
        "no server could be the wrong socket, not a closed pane"
    );
}

#[test]
fn a_failing_a_slow_and_a_missing_tmux_say_nothing() {
    let (failing, _dir) = stub("echo 'unknown option' >&2; exit 1");
    assert_eq!(ask(failing), None);
    let (empty, _dir) = stub("exit 0");
    assert_eq!(ask(empty), None);
    assert_eq!(ask(Command::new("/nonexistent/tmux")), None);
    let (slow, _dir) = stub("trap '' TERM; echo \"can't find pane: %99\" >&2; sleep 30");
    let started = Instant::now();
    assert_eq!(
        ask(slow),
        None,
        "a timeout is not an answer, whatever it said before"
    );
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "the probe stops tmux at its deadline"
    );
}

#[test]
fn a_stop_ends_the_probe_with_no_answer() {
    let (slow, _dir) = stub("trap '' TERM; sleep 30");
    let stop = Stop::default();
    stop.stop();
    let started = Instant::now();
    assert_eq!(probe(slow, "%12", &stop), None);
    assert!(started.elapsed() < Duration::from_secs(10));
}
