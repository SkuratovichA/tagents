//! The state rows and the labels against real files. The cases of `packages/core/test/agent-state.test.ts` map as follows: "records are read newest first" is `rows_are_newest_first_and_only_real_keys`; "the seventh column is the account" is `the_seventh_column_is_the_account_and_its_absence_is_not_an_empty_one`; "an eighth column is the headless pid", "the columns past the account belong to the rows with no pane" and "a history line names the parent of a child" read columns and a reader this module does not port (see its doc), so the fixture keeps rows of 7, 10 and 12 fields and `rows_with_more_columns_read_the_same_first_seven` pins that they parse as before; "a truncated or nonsense line is skipped" is `a_truncated_or_nonsense_line_is_skipped`; "a missing directory is no agents" is `a_missing_directory_is_no_agents_and_no_labels`; "TA_STATE_DIR decides where the records are" is `the_state_dir_is_the_variable_or_the_default`; "history carries the labels" is `history_carries_the_labels_and_the_latest_start_wins`; "labels.tsv is read per key exactly as label_of reads it" is `labels_are_read_per_key_exactly_as_label_of_reads_them`; the two cases that drive `ClaudeHeadlessDriver` ("the driver lists what the hook published", "last() reads the transcript") test the node driver and have no Rust counterpart. The vectors in `tests/notify_vectors/feed.rs` pin the same functions to node's answers.

use std::fs;
use std::path::Path;
use std::process::Command;

use super::*;
use crate::testing::Scratch;

fn write(scratch: &Scratch, name: &str, text: &str) {
    fs::write(scratch.path().join(name), text).unwrap();
}

fn tsv(fields: &[&str]) -> String {
    format!("{}\n", fields.join("\t"))
}

/// What the hook published: a row of seven fields for a session with a pane, six for one written before the account column, ten for a headless session, twelve for its child.
fn published() -> Scratch {
    let s = Scratch::new();
    let work = "/Users/demo/git/demo";
    write(
        &s,
        "12.tsv",
        &tsv(&[
            "1760000000",
            "working",
            "sess-a",
            work,
            "/Users/demo/.claude/projects/-Users-demo-git-demo/sess-a.jsonl",
            "Bash ls",
            "",
        ]),
    );
    write(
        &s,
        "s-sess-b.tsv",
        &tsv(&[
            "1760000100",
            "blocked",
            "sess-b",
            "/Users/demo/git/other",
            "",
            "Claude needs your permission to use Bash",
            "/Users/demo/.claude-work",
            "4242",
        ]),
    );
    write(
        &s,
        "13.tsv",
        &tsv(&["1759000000", "done", "sess-c", "", "", ""]),
    );
    write(
        &s,
        "s-sess-d.tsv",
        &tsv(&[
            "1760000050",
            "working",
            "sess-d",
            work,
            "",
            "",
            "",
            "5151",
            "/tmp/ticket-agent.log",
            "ticket-agent",
        ]),
    );
    write(
        &s,
        "s-sess-e.tsv",
        &tsv(&[
            "1760000060",
            "working",
            "sess-e",
            "/Users/demo/git/scratch",
            "",
            "",
            "",
            "5252",
            "",
            "",
            "s-sess-d",
            "sess-d",
        ]),
    );
    write(&s, "not-a-key.tsv", "garbage\n");
    fs::create_dir_all(s.path().join("sub")).unwrap();
    write(
        &s,
        "history.tsv",
        &[
            tsv(&["1760000000", "start", "sess-a", "%12", "dashboard", work]),
            tsv(&[
                "1760000100",
                "start",
                "sess-b",
                "%0",
                "tg-orchestrator",
                "/Users/demo/git/other",
            ]),
            tsv(&[
                "1760000200",
                "turn",
                "sess-b",
                "%0",
                "tg-orchestrator",
                "/Users/demo/git/other",
            ]),
            tsv(&[
                "1760000300",
                "start",
                "sess-e",
                "",
                "",
                "/Users/demo/git/scratch",
                "sess-d",
            ]),
        ]
        .concat(),
    );
    s
}

#[test]
fn rows_are_newest_first_and_only_real_keys() {
    let s = published();
    let keys: Vec<String> = read_agent_state(s.dir())
        .into_iter()
        .map(|r| r.key)
        .collect();
    assert_eq!(keys, ["s-sess-b", "s-sess-e", "s-sess-d", "12", "13"]);
}

#[test]
fn rows_with_the_same_time_keep_the_order_of_their_names() {
    let s = Scratch::new();
    for name in ["s-a", "5", "10", "s-B", "9"] {
        write(
            &s,
            &format!("{name}.tsv"),
            &tsv(&["1760000000", "done", name, "", "", ""]),
        );
    }
    let keys: Vec<String> = read_agent_state(s.dir())
        .into_iter()
        .map(|r| r.key)
        .collect();
    assert_eq!(
        keys,
        ["10", "5", "9", "s-B", "s-a"],
        "readdirSync lists names bytewise, and the sort of rows is stable"
    );
}

#[test]
fn the_seventh_column_is_the_account_and_its_absence_is_not_an_empty_one() {
    let s = published();
    let rows = read_agent_state(s.dir());
    let config_dir = |key: &str| {
        rows.iter()
            .find(|r| r.key == key)
            .unwrap()
            .config_dir
            .clone()
    };
    assert_eq!(
        config_dir("12"),
        Some(String::new()),
        "an empty seventh field is the default account"
    );
    assert_eq!(
        config_dir("s-sess-b"),
        Some("/Users/demo/.claude-work".to_owned())
    );
    assert_eq!(
        config_dir("13"),
        None,
        "six fields are a row written before the column existed"
    );
}

#[test]
fn rows_with_more_columns_read_the_same_first_seven() {
    let s = published();
    let rows = read_agent_state(s.dir());
    let child = rows.iter().find(|r| r.key == "s-sess-e").unwrap();
    assert_eq!(child.at, 1_760_000_060.0);
    assert_eq!(child.state, RowState::Working);
    assert_eq!(child.session_id, "sess-e");
    assert_eq!(child.cwd, "/Users/demo/git/scratch");
    assert_eq!(child.config_dir, Some(String::new()));
    let blocked = rows.iter().find(|r| r.key == "s-sess-b").unwrap();
    assert_eq!(blocked.state, RowState::Blocked);
    assert_eq!(blocked.detail, "Claude needs your permission to use Bash");
}

#[test]
fn every_state_the_hook_writes_is_read_and_no_other() {
    for (name, want) in [
        ("new", RowState::New),
        ("working", RowState::Working),
        ("blocked", RowState::Blocked),
        ("done", RowState::Done),
        ("gone", RowState::Gone),
        ("subdone", RowState::Subdone),
    ] {
        let row = parse_state_line("9", &format!("1760000000\t{name}\ts\t/c\t/t\td")).unwrap();
        assert_eq!(row.state, want, "{name}");
    }
    assert_eq!(
        parse_state_line("9", "1760000000\tWorking\ts\t/c\t/t\td"),
        None,
        "the names are spelled in lower case"
    );
}

#[test]
fn a_truncated_or_nonsense_line_is_skipped() {
    assert_eq!(parse_state_line("9", "nope"), None);
    assert_eq!(
        parse_state_line("9", "1760000000\tworking\tsess"),
        None,
        "fewer than six fields"
    );
    assert_eq!(
        parse_state_line("9", "not-a-number\tworking\ts\t/c\t/t\td\t"),
        None
    );
    assert_eq!(
        parse_state_line("9", "1760000000\tinvented\ts\t/c\t/t\td\t"),
        None,
        "an unknown state"
    );
    assert_eq!(
        parse_state_line("9", "Infinity\tworking\ts\t/c\t/t\td"),
        None,
        "a time that is not finite"
    );
}

#[test]
fn a_time_is_read_as_number_reads_it() {
    for (at, want) in [
        ("", 0.0),
        (" 17 ", 17.0),
        ("0x10", 16.0),
        ("1e3", 1000.0),
        ("1760000000.5", 1_760_000_000.5),
    ] {
        let row = parse_state_line("9", &format!("{at}\tworking\ts\t/c\t/t\td")).unwrap();
        assert_eq!(row.at, want, "{at:?}");
    }
}

#[test]
fn one_trailing_newline_is_dropped_and_no_more() {
    let row = parse_state_line("9", "1\tdone\ts\t/c\t/t\td\n").unwrap();
    assert_eq!(row.detail, "d");
    let row = parse_state_line("9", "1\tdone\ts\t/c\t/t\td\r").unwrap();
    assert_eq!(
        row.detail, "d\r",
        "a carriage return is part of the field, as in node"
    );
}

#[test]
fn only_the_first_line_of_a_file_is_the_row() {
    let s = Scratch::new();
    write(
        &s,
        "7.tsv",
        "1\tdone\ts\t/c\t/t\tfirst\n2\tworking\tt\t/c\t/t\tsecond\n",
    );
    let rows = read_agent_state(s.dir());
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].detail, "first");
}

#[test]
fn keys_are_digits_or_s_dash_and_a_word() {
    for (key, want) in [
        ("12", true),
        ("0", true),
        ("s-sess-b", true),
        ("s-a.b_c-d", true),
        ("", false),
        ("s-", false),
        ("1a", false),
        ("s-a b", false),
        ("S-x", false),
        ("s-é", false),
        ("٣", false),
        ("-1", false),
        ("not-a-key", false),
    ] {
        assert_eq!(is_key(key), want, "{key:?}");
    }
}

#[test]
fn a_file_that_is_not_utf8_is_read_with_replacement_characters() {
    let s = Scratch::new();
    fs::write(
        s.path().join("4.tsv"),
        b"1\tdone\ts\t/c\xff/t\t/tr\t\xe2\x82\n",
    )
    .unwrap();
    let rows = read_agent_state(s.dir());
    assert_eq!(rows[0].cwd, "/c\u{fffd}/t");
    assert_eq!(rows[0].detail, "\u{fffd}");
}

#[test]
fn a_missing_directory_is_no_agents_and_no_labels() {
    let s = Scratch::new();
    let gone = s.path().join("nope");
    let gone = gone.to_str().unwrap();
    assert!(read_agent_state(gone).is_empty());
    assert!(labels_by_session(gone).is_empty());
    assert!(read_labels(gone).is_empty());
}

#[test]
fn the_state_dir_is_the_variable_or_the_default() {
    assert_eq!(state_dir_in(Some("/x/state"), "/home/u"), "/x/state");
    assert_eq!(state_dir_in(None, "/home/u"), "/home/u/.claude/agent-state");
    assert_eq!(
        state_dir_in(Some(""), "/home/u"),
        "/home/u/.claude/agent-state"
    );
    assert_eq!(
        state_dir_in(Some(" \t\n"), "/home/u"),
        "/home/u/.claude/agent-state",
        "white space is nothing"
    );
    assert_eq!(
        state_dir_in(Some(" /x "), "/home/u"),
        " /x ",
        "a value that has more than white space is kept as it is"
    );
    // The reader of the real environment: it cannot set a variable here, so it is checked against whatever the run has.
    let want = match std::env::var("TA_STATE_DIR") {
        Ok(dir) if !dir.trim().is_empty() => dir,
        _ => format!("{}/.claude/agent-state", node::homedir()),
    };
    assert_eq!(state_dir(), want);
}

#[test]
fn history_carries_the_labels_and_the_latest_start_wins() {
    let s = published();
    let labels = labels_by_session(s.dir());
    assert_eq!(labels.get("sess-a").map(String::as_str), Some("dashboard"));
    assert_eq!(
        labels.get("sess-b").map(String::as_str),
        Some("tg-orchestrator")
    );
    assert_eq!(
        labels.get("sess-e"),
        None,
        "a start with no label names nobody"
    );
    assert_eq!(labels.len(), 2);

    write(
        &s,
        "history.tsv",
        &[
            tsv(&["1", "start", "x", "%1", "first", "/c"]),
            tsv(&["2", "turn", "x", "%1", "second", "/c"]),
            tsv(&["3", "end", "x", "%1", "", "/c"]),
            tsv(&["4", "bogus", "x", "%1", "bogus kind", "/c"]),
            tsv(&["nan", "start", "x", "%1", "bogus time", "/c"]),
            tsv(&["5", "start", "x", "%1", "short"]),
            tsv(&["6", "start", "", "%1", "no session", "/c"]),
            "\n".to_owned(),
            tsv(&["7", "start", "y", "%1", "other", "/c", "parent"]),
        ]
        .concat(),
    );
    let labels = labels_by_session(s.dir());
    assert_eq!(
        labels.get("x").map(String::as_str),
        Some("second"),
        "an empty label does not replace one"
    );
    assert_eq!(
        labels.get("y").map(String::as_str),
        Some("other"),
        "a seventh column is the parent and changes nothing"
    );
    assert_eq!(labels.len(), 2);
}

/// The shell owns labels.tsv (`lib/tagents/names.sh`), so the reader is pinned to `label_of` itself rather than to a copy of its rule: every key, a missing one included, must give what the dashboard's own lookup gives.
#[test]
fn labels_are_read_per_key_exactly_as_label_of_reads_them() {
    let s = Scratch::new();
    // `k` has an empty name on its first line and a real one on a later line: the shell answers with the first line, empty or not.
    let lines = [
        "sess-a\tRenamed agent",
        "%12\tpane name",
        "no-tab-here",
        "\tno key",
        "sess-b\t",
        "sess-a\tlater line",
        "sess-c\tname\textra",
        "k\t",
        "k\tx",
    ];
    write(&s, "labels.tsv", &format!("{}\n", lines.join("\n")));
    let labels = read_labels(s.dir());
    let mut got: Vec<(&str, &str)> = labels
        .iter()
        .map(|(k, v)| (k.as_str(), v.as_str()))
        .collect();
    got.sort();
    assert_eq!(
        got,
        [
            ("%12", "pane name"),
            ("k", ""),
            ("no-tab-here", ""),
            ("sess-a", "Renamed agent"),
            ("sess-b", ""),
            ("sess-c", "name")
        ]
    );
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    for key in [
        "sess-a",
        "%12",
        "sess-b",
        "sess-c",
        "no-tab-here",
        "k",
        "missing",
    ] {
        let out = Command::new("bash")
            .arg("-c")
            .arg(r#"TAB=$'\t'; . "$1/lib/tagents/names.sh" && label_of "$2""#)
            .arg("_")
            .arg(&root)
            .arg(key)
            .env("STATE_DIR", s.path())
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let shell = String::from_utf8_lossy(&out.stdout);
        assert_eq!(
            labels.get(key).map_or("", String::as_str),
            shell.strip_suffix('\n').unwrap_or(&shell),
            "{key}"
        );
    }
}
