//! The usage store against what `packages/knowledge/src/usage.ts` does: the table, the retention, the reports with every argument, the stores that are not what they should be, recording that cannot fail and the parsers of the arguments, case by case from `tests/fixtures/knowledge-vectors.json`.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::{
    fs,
    os::unix::fs::PermissionsExt,
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};
use tagents_core::knowledge::{
    index::open_db,
    search::{Filters, search},
    usage::{
        BUSY_TIMEOUT_MS, Kind, RETENTION_DAYS, ReportError, ReportOptions, UsageEvent, UsageRow,
        append_events, caller_from, get_event, hit_events, open_usage_db, parse_positive,
        parse_since, read_usage_rows, record_reads,
    },
};

use common::{
    knowledge::{index_of, rows, settings, vectors},
    scratch,
};

/// The fixed clock of the vectors: 2026-10-31T12:00:00Z.
const NOW: i64 = 1_793_448_000_000;

const STORE_ROWS: &str =
    "select ts, doc_id, heading, kind, caller from usage_events order by rowid";

fn events_of(value: &Value) -> Vec<UsageEvent> {
    value
        .as_array()
        .unwrap()
        .iter()
        .map(|e| UsageEvent {
            doc_id: e["docId"].as_str().unwrap().to_string(),
            heading: e["heading"].as_str().unwrap().to_string(),
            kind: if e["kind"] == "get" {
                Kind::Get
            } else {
                Kind::Hit
            },
            caller: e["caller"].as_str().map(str::to_string),
        })
        .collect()
}

fn row_json(row: &UsageRow) -> Value {
    json!({"id": row.id, "type": row.type_, "status": row.status, "gets": row.gets, "hits": row.hits, "days": row.days, "last": row.last})
}

fn options_of(value: &Value) -> ReportOptions {
    ReportOptions {
        since_days: value["sinceDays"].as_i64(),
        top: value["top"].as_i64(),
        type_: value["type"].as_str().map(str::to_string),
        all: value["all"].as_bool().unwrap_or(false),
        candidates: value["candidates"].as_bool().unwrap_or(false),
        min_gets: value["minGets"].as_i64(),
        min_days: value["minDays"].as_i64(),
    }
}

#[test]
fn an_open_store_carries_the_settings_node_gives_it() {
    let dir = scratch("knowledge-usage-settings");
    let db = open_usage_db(dir.join("usage.sqlite").to_str().unwrap()).unwrap();
    assert_eq!(
        vectors()["engine"]["schema"]["applied"]["usage"],
        settings(&db)
    );
}

#[test]
fn the_table_and_the_constants_are_the_ones_node_has() {
    let schema = &vectors()["engine"]["schema"];
    assert_eq!(json!(RETENTION_DAYS), schema["retentionDays"]);
    assert_eq!(json!(BUSY_TIMEOUT_MS), schema["usageBusyMs"]);
    let dir = scratch("knowledge-usage-schema");
    let db = open_usage_db(dir.join("nested/usage.sqlite").to_str().unwrap()).unwrap();
    assert_eq!(
        Value::Array(rows(
            &db,
            "select type, name, tbl_name, sql from sqlite_master order by type, name"
        )),
        schema["usageMaster"]
    );
}

#[test]
fn the_rows_after_each_batch_and_the_retention_are_node_s() {
    let snapshots = vectors()["usage"]["batches"]["snapshots"]
        .as_array()
        .unwrap();
    assert_eq!(14, snapshots.len());
    let dir = scratch("knowledge-usage-batches");
    let file = dir.join("usage.sqlite");
    for (n, snapshot) in snapshots.iter().enumerate() {
        let mut db = open_usage_db(file.to_str().unwrap()).unwrap();
        append_events(
            &mut db,
            &events_of(&snapshot["events"]),
            snapshot["now"].as_i64().unwrap(),
        )
        .unwrap();
        drop(db);
        let db = open_usage_db(file.to_str().unwrap()).unwrap();
        assert_eq!(
            snapshot["rows"],
            Value::Array(rows(&db, STORE_ROWS)),
            "after batch {n}"
        );
    }
}

#[test]
fn every_report_of_the_vectors_has_the_rows_node_gives() {
    let reports = &vectors()["usage"]["reports"];
    let (index, _) = index_of("knowledge-usage-reports-index", &reports["files"]);
    let dir = scratch("knowledge-usage-reports");
    let file = dir.join("usage.sqlite");
    let mut store = open_usage_db(file.to_str().unwrap()).unwrap();
    for snapshot in vectors()["usage"]["batches"]["snapshots"]
        .as_array()
        .unwrap()
    {
        append_events(
            &mut store,
            &events_of(&snapshot["events"]),
            snapshot["now"].as_i64().unwrap(),
        )
        .unwrap();
    }
    drop(store);
    let all = reports["reports"].as_array().unwrap();
    assert_eq!(119, all.len());
    let mut with_rows = 0;
    for report in all {
        let got = read_usage_rows(
            &index,
            file.to_str().unwrap(),
            &options_of(&report["options"]),
            reports["now"].as_i64().unwrap(),
        )
        .unwrap();
        assert_eq!(
            report["rows"],
            Value::Array(got.iter().map(row_json).collect()),
            "report for {}",
            report["options"]
        );
        with_rows += usize::from(!got.is_empty());
    }
    assert!(with_rows >= 100, "{with_rows} of 119 reports had rows");
}

#[test]
fn a_store_that_is_not_what_it_should_be_is_empty_or_refused_as_node_does() {
    let dir = scratch("knowledge-usage-broken");
    let index = open_db(dir.join("index.sqlite").to_str().unwrap()).unwrap();
    for case in vectors()["usage"]["brokenStores"].as_array().unwrap() {
        let setup = case["setup"].as_str().unwrap();
        let file = dir.join(format!("{setup}.sqlite"));
        match setup {
            "absent" => {}
            "empty-database" => drop(Connection::open(&file).unwrap()),
            "other-table" => Connection::open(&file)
                .unwrap()
                .execute_batch("create table other (x integer)")
                .unwrap(),
            "not-a-database" => fs::write(
                &file,
                "this is not a database file at all, and it is longer than one page header needs",
            )
            .unwrap(),
            "directory" => fs::create_dir(&file).unwrap(),
            "wrong-shape" => Connection::open(&file)
                .unwrap()
                .execute_batch("create table usage_events (x integer)")
                .unwrap(),
            other => panic!("a setup the vectors do not name: {other}"),
        }
        let result = read_usage_rows(
            &index,
            file.to_str().unwrap(),
            &ReportOptions::default(),
            NOW,
        );
        match (&case["error"], result) {
            (Value::Null, Ok(got)) => {
                assert_eq!(
                    case["rows"],
                    Value::Array(got.iter().map(row_json).collect()),
                    "{setup}"
                );
                assert_eq!(
                    setup == "absent" && file.exists(),
                    case["created"].as_bool().unwrap(),
                    "{setup}: created"
                );
            }
            (error, Err(ReportError::Store(got))) => {
                assert_eq!(
                    error["reason"].as_str().unwrap(),
                    got.reason.replace(dir.to_str().unwrap(), "<dir>"),
                    "{setup}"
                );
                assert_eq!(file.to_str().unwrap(), got.file);
            }
            (_, other) => panic!("{setup}: node and Rust differ: {other:?}"),
        }
    }
}

/// The node test of the same name holds the lock from the same thread for as long as the call lasts; here another thread lets go when the call is over or after three seconds, whichever is first, so a call that waited for it would end late and the assertion on the time would say so.
#[test]
fn a_store_that_stays_locked_is_given_up_on_after_the_busy_timeout() {
    let dir = scratch("knowledge-usage-locked");
    let file = dir.join("usage.sqlite");
    let file = file.to_str().unwrap().to_string();
    drop(open_usage_db(&file).unwrap());
    let (locked, wait) = mpsc::channel();
    let (done, release) = mpsc::channel::<()>();
    let holder = {
        let file = file.clone();
        thread::spawn(move || {
            let other = open_usage_db(&file).unwrap();
            other.execute_batch("begin immediate").unwrap();
            locked.send(()).unwrap();
            let _ = release.recv_timeout(Duration::from_secs(3));
            other.execute_batch("rollback").unwrap();
        })
    };
    wait.recv().unwrap();
    let start = Instant::now();
    let reason = record_reads(&file, &[get_event("alpha", "", None)], NOW);
    let waited = start.elapsed();
    done.send(()).unwrap();
    holder.join().unwrap();
    assert!(
        waited >= Duration::from_millis(BUSY_TIMEOUT_MS - 50),
        "gave up before the busy timeout: {waited:?}"
    );
    assert!(
        waited < Duration::from_secs(1),
        "waited for the holder instead of giving up: {waited:?}"
    );
    assert_eq!(Some("database is locked".to_string()), reason);
    let db = open_usage_db(&file).unwrap();
    assert_eq!(
        vec![json!({"n": 0})],
        rows(&db, "select count(*) as n from usage_events")
    );
}

#[test]
fn recording_that_cannot_succeed_says_why_and_does_not_fail() {
    let want = &vectors()["usage"]["recording"];
    let dir = scratch("knowledge-usage-record");
    let events = [
        get_event("alpha", "", Some("client")),
        UsageEvent {
            doc_id: "beta".into(),
            heading: String::new(),
            kind: Kind::Hit,
            caller: None,
        },
    ];
    let reasons = |file: &std::path::Path| -> Value {
        json!(
            record_reads(file.to_str().unwrap(), &events, NOW)
                .map(|r| r.replace(dir.to_str().unwrap(), "<dir>"))
                .into_iter()
                .collect::<Vec<_>>()
        )
    };
    let read_only = dir.join("readonly.sqlite");
    Connection::open(&read_only)
        .unwrap()
        .execute_batch("create table usage_events (ts integer not null, doc_id text not null, heading text not null default '', kind text not null, caller text)")
        .unwrap();
    fs::set_permissions(&read_only, fs::Permissions::from_mode(0o444)).unwrap();
    let directory = dir.join("directory.sqlite");
    fs::create_dir(&directory).unwrap();
    let garbage = dir.join("garbage.sqlite");
    fs::write(
        &garbage,
        "this is not a database file at all, and it is longer than one page header needs",
    )
    .unwrap();
    let untouched = dir.join("untouched.sqlite");
    assert_eq!(None, record_reads(untouched.to_str().unwrap(), &[], NOW));
    let fine = dir.join("fine.sqlite");
    assert_eq!(want["readOnly"], reasons(&read_only), "read-only");
    assert_eq!(want["directory"], reasons(&directory), "directory");
    assert_eq!(want["notADatabase"], reasons(&garbage), "not a database");
    assert_eq!(want["noEventsCreatesNothing"], json!(!untouched.exists()));
    assert_eq!(want["ok"], reasons(&fine));
    let db = Connection::open_with_flags(&fine, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    assert_eq!(want["okRows"], Value::Array(rows(&db, STORE_ROWS)));
    fs::set_permissions(&read_only, fs::Permissions::from_mode(0o644)).unwrap();
}

#[test]
fn the_window_and_the_counts_are_parsed_as_node_parses_them() {
    let usage = &vectors()["usage"];
    for case in usage["parseSince"].as_array().unwrap() {
        assert_eq!(
            case["days"].as_i64(),
            parse_since(case["value"].as_str().unwrap()),
            "since {}",
            case["value"]
        );
    }
    for case in usage["parsePositive"].as_array().unwrap() {
        assert_eq!(
            case["n"].as_i64(),
            parse_positive(case["value"].as_str().unwrap()),
            "positive {}",
            case["value"]
        );
    }
}

#[test]
fn the_caller_is_the_name_of_the_handshake_or_nobody() {
    assert_eq!(Some("client"), caller_from(Some("client")));
    assert_eq!(None, caller_from(Some("")));
    assert_eq!(None, caller_from(None));
}

#[test]
fn the_events_of_a_search_and_of_a_get_are_the_ones_the_node_server_recorded() {
    let (mut hits_checked, mut gets_checked) = (0, 0);
    for corpus in vectors()["corpus"]["corpora"].as_array().unwrap() {
        let name = corpus["name"].as_str().unwrap();
        let (db, _) = index_of(&format!("knowledge-usage-events-{name}"), &corpus["files"]);
        for call in corpus["calls"].as_array().unwrap() {
            let (Some(tool), false) = (
                call["tool"].as_str(),
                call["isError"].as_bool().unwrap_or(true),
            ) else {
                continue;
            };
            let args = &call["args"];
            let client = call["client"].as_str();
            let caller = caller_from(client);
            match tool {
                "knowledge_search" => {
                    let filters = Filters {
                        tag: args["tag"].as_str(),
                        type_: args["type"].as_str(),
                        kind: args["kind"].as_str(),
                    };
                    let hits = search(
                        &db,
                        &[args["query"].as_str().unwrap()],
                        &filters,
                        args["limit"].as_f64(),
                        NOW,
                    );
                    let got: Vec<Value> =
                        hit_events(&hits, caller).iter().map(event_json).collect();
                    assert_eq!(
                        call["events"].as_array().unwrap_or(&Vec::new()),
                        &got,
                        "{name}: {args}"
                    );
                    hits_checked += 1;
                }
                "knowledge_get" if args["heading"].is_string() => {
                    let section = tagents_core::knowledge::search::get_section(
                        &db,
                        args["id"].as_str().unwrap(),
                        args["heading"].as_str().unwrap(),
                    )
                    .unwrap()
                    .unwrap();
                    let got = event_json(&get_event(&section.id, &section.heading, caller));
                    assert_eq!(call["events"][0], got, "{name}: {args}");
                    gets_checked += 1;
                }
                _ => {}
            }
        }
    }
    assert!(
        hits_checked >= 100 && gets_checked >= 50,
        "checked {hits_checked} searches and {gets_checked} gets"
    );
}

fn event_json(event: &UsageEvent) -> Value {
    json!({"docId": event.doc_id, "heading": event.heading, "kind": if event.kind == Kind::Get { "get" } else { "hit" }, "caller": event.caller})
}
