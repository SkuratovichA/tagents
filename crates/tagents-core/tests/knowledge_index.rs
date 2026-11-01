//! The knowledge index against what `packages/knowledge/src/db.ts` does: the schema text, the schema versions, the life of an index over a folder, the tokenizer and the modification time, case by case from `tests/fixtures/knowledge-vectors.json`.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::{
    collections::BTreeSet,
    fs,
    path::Path,
    sync::mpsc,
    thread,
    time::{Duration, Instant, SystemTime},
};

use rusqlite::{Connection, types::ValueRef};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use tagents_core::knowledge::index::{
    INDEX_BUSY_TIMEOUT_MS, SCHEMA_VERSION, TOKENIZER, doc_count, open_db, reindex,
};
use tagents_core::node;

use common::{
    knowledge::{same_message, vectors},
    scratch,
};

/// The compile options of the SQLite bundled with rusqlite that node's SQLite does not have, each with the reason it does not change what the index does.
/// Everything the vectors name outside these two lists must be equal.
const ONLY_HERE: &[(&str, &str)] = &[
    (
        "DEFAULT_FOREIGN_KEYS",
        "foreign keys are on by default; `open_db` switches them on either way",
    ),
    (
        "ENABLE_API_ARMOR",
        "checks the arguments of the C interface; nothing in SQL",
    ),
    (
        "ENABLE_LOAD_EXTENSION",
        "lets a program enable extension loading; the `load_extension` feature of rusqlite is off and nothing calls it",
    ),
    (
        "ENABLE_STAT4",
        "planner statistics, read after `ANALYZE`, which no program here runs",
    ),
    ("HAVE_ISNAN", "a libc detection for the build"),
    (
        "MAX_SCHEMA=10000000",
        "the default limit on the size of the schema, which a later SQLite lists; the schema is four tables",
    ),
    (
        "SOUNDEX",
        "adds the `soundex()` function, which no statement calls",
    ),
    (
        "USE_URI",
        "reads a file name that starts with `file:` as a URI; no index path does, and `open_file` does not ask for it",
    ),
];

/// The compile options of node's SQLite that the bundled one does not have, each with the reason it does not change what the index does.
const ONLY_IN_NODE: &[(&str, &str)] = &[
    (
        "DEFAULT_MEMSTATUS=0",
        "turns off memory statistics, a speed setting",
    ),
    (
        "ENABLE_GEOPOLY",
        "the geopoly extension, which the index does not create",
    ),
    (
        "ENABLE_MATH_FUNCTIONS",
        "`ceil`, `sqrt` and the like, which no statement of the index or of the usage store calls",
    ),
    (
        "ENABLE_PREUPDATE_HOOK",
        "a C hook for a program that watches changes; none here",
    ),
    ("ENABLE_RBU", "the RBU extension for bulk updates; unused"),
    (
        "ENABLE_SESSION",
        "the session extension that records changes; unused",
    ),
];

fn cell(value: ValueRef) -> Value {
    match value {
        ValueRef::Null => Value::Null,
        ValueRef::Integer(i) => json!(i),
        ValueRef::Real(f) => json!(f),
        ValueRef::Text(bytes) => json!(String::from_utf8(bytes.to_vec()).unwrap()),
        ValueRef::Blob(bytes) => json!(bytes),
    }
}

/// The rows of a query as objects keyed by column name, the shape the vectors hold.
fn rows(db: &Connection, query: &str) -> Vec<Value> {
    let mut statement = db.prepare(query).unwrap();
    let names: Vec<String> = statement.column_names().map(str::to_string).collect();
    statement
        .query_map([], |row| {
            let mut object = Map::new();
            for (i, name) in names.iter().enumerate() {
                object.insert(name.clone(), cell(row.get_ref(i)?));
            }
            Ok(Value::Object(object))
        })
        .unwrap()
        .map(Result::unwrap)
        .collect()
}

#[test]
fn the_constants_are_the_ones_node_has() {
    let schema = &vectors()["engine"]["schema"];
    assert_eq!(json!(SCHEMA_VERSION), schema["schemaVersion"]);
    assert_eq!(json!(TOKENIZER), schema["tokenizer"]);
    assert_eq!(json!(INDEX_BUSY_TIMEOUT_MS), schema["indexBusyMs"]);
}

#[test]
fn a_new_index_has_the_schema_text_of_node() {
    let schema = &vectors()["engine"]["schema"];
    let dir = scratch("knowledge-index-schema");
    let db = open_db(dir.join("nested/index.sqlite").to_str().unwrap()).unwrap();
    assert_eq!(
        Value::Array(rows(&db, "select key, value from meta order by key")),
        schema["meta"]
    );
    assert_eq!(
        Value::Array(rows(
            &db,
            "select type, name, tbl_name, sql from sqlite_master order by type, name"
        )),
        schema["indexMaster"]
    );
}

#[test]
fn an_index_that_exists_is_opened_as_it_is() {
    let dir = scratch("knowledge-index-twice");
    let file = dir.join("index.sqlite");
    let file = file.to_str().unwrap();
    let db = open_db(file).unwrap();
    db.execute("insert into docs (id, path, title, type, type_key, description, tags, status, mtime, hash) values ('a', 'p', 't', 'Note', 'note', '', '[]', 'stable', 1, 'h')", []).unwrap();
    drop(db);
    let db = open_db(file).unwrap();
    assert_eq!(1, doc_count(&db).unwrap());
}

#[test]
fn a_file_of_another_schema_version_is_rebuilt_the_way_node_reads_the_version() {
    let cases = vectors()["engine"]["schemaVersions"]["cases"]
        .as_array()
        .unwrap();
    assert_eq!(16, cases.len());
    let dir = scratch("knowledge-index-versions");
    for (i, case) in cases.iter().enumerate() {
        let file = dir.join(format!("v-{i}.sqlite"));
        let seed = Connection::open(&file).unwrap();
        let setup = case["setup"].as_array().unwrap();
        seed.execute_batch(setup[0].as_str().unwrap()).unwrap();
        seed.execute(
            "insert into meta (key, value) values ('schema_version', ?1)",
            [case["value"].as_str().unwrap()],
        )
        .unwrap();
        for statement in &setup[1..] {
            seed.execute_batch(statement.as_str().unwrap()).unwrap();
        }
        drop(seed);
        let db = open_db(file.to_str().unwrap()).unwrap();
        let kept = rows(
            &db,
            "select 1 as one from pragma_table_info('docs') where name = 'note'",
        )
        .len()
            == 1;
        assert_eq!(
            case["keptOldRows"],
            json!(kept),
            "rows kept for version {:?}",
            case["value"]
        );
        assert_eq!(
            case["version"],
            Value::Array(rows(
                &db,
                "select value from meta where key = 'schema_version'"
            )),
            "version written for {:?}",
            case["value"]
        );
        assert_eq!(
            case["tables"],
            Value::Array(rows(
                &db,
                "select name from sqlite_master where type = 'table' and name not like 'chunks_fts_%' order by name"
            )),
            "tables for {:?}",
            case["value"]
        );
    }
}

#[test]
fn a_file_that_is_no_database_is_refused_with_the_message_of_node() {
    let garbage = &vectors()["engine"]["schemaVersions"]["garbage"];
    let dir = scratch("knowledge-index-garbage");
    let file = dir.join("garbage.sqlite");
    fs::write(
        &file,
        "this is not a database file at all, and it is longer than one page header needs",
    )
    .unwrap();
    let error = open_db(file.to_str().unwrap()).unwrap_err();
    assert_eq!(garbage["error"], json!(error));
}

fn set_mtime(file: &Path, sec: u64) {
    let handle = fs::File::options().write(true).open(file).unwrap();
    handle
        .set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(sec))
        .unwrap();
}

fn dump(db: &Connection, folder: &str) -> Map<String, Value> {
    let mut docs = rows(
        db,
        "select id, path, title, type, type_key, description, tags, status, stale_after, generated_at, mtime, hash from docs order by id",
    );
    for doc in &mut docs {
        let path = doc["path"].as_str().unwrap().replace(folder, "<dir>");
        doc["path"] = json!(path);
    }
    let mut dump = Map::new();
    dump.insert(
        "meta".into(),
        Value::Array(rows(db, "select key, value from meta order by key")),
    );
    dump.insert("docs".into(), Value::Array(docs));
    dump.insert(
        "chunks".into(),
        Value::Array(rows(
            db,
            "select rowid, doc_id, heading, ord, body from chunks order by rowid",
        )),
    );
    dump.insert(
        "fts".into(),
        Value::Array(rows(
            db,
            "select rowid, doc_id, heading, body from chunks_fts order by rowid",
        )),
    );
    dump
}

#[test]
fn an_index_follows_a_folder_through_the_life_node_gives_it() {
    let scenarios = vectors()["engine"]["reindex"].as_array().unwrap();
    assert_eq!(3, scenarios.len());
    for scenario in scenarios {
        let dir = scratch("knowledge-index-life");
        let folder = dir.join("folder");
        fs::create_dir(&folder).unwrap();
        let folder_text = folder.to_str().unwrap();
        let mut db = open_db(dir.join("index.sqlite").to_str().unwrap()).unwrap();
        let name = scenario["name"].as_str().unwrap();
        for (n, step) in scenario["steps"].as_array().unwrap().iter().enumerate() {
            let target = folder.join(step["name"].as_str().unwrap_or(""));
            match step["op"].as_str().unwrap() {
                "write" => {
                    fs::write(&target, step["text"].as_str().unwrap()).unwrap();
                    set_mtime(&target, step["mtimeSec"].as_u64().unwrap());
                }
                "delete" => fs::remove_dir_all(&target)
                    .or_else(|_| fs::remove_file(&target))
                    .unwrap(),
                "mkdir" => fs::create_dir(&target).unwrap(),
                "reindex" => {
                    let full = step["full"].as_bool().unwrap_or(false);
                    let stats = reindex(&mut db, folder_text, full).unwrap();
                    let mut after = Map::new();
                    after.insert("added".into(), json!(stats.added));
                    after.insert("changed".into(), json!(stats.changed));
                    after.insert("unchanged".into(), json!(stats.unchanged));
                    after.insert("removed".into(), json!(stats.removed));
                    after.insert(
                        "errors".into(),
                        Value::Array(
                            stats
                                .errors
                                .iter()
                                .map(|e| json!({"file": node::basename(&e.file), "message": e.message}))
                                .collect(),
                        ),
                    );
                    after.extend(dump(&db, folder_text));
                    let want = &step["after"];
                    // The wording of a YAML error is a known difference: the errors are compared by file and by `same_message`, the rest as it is.
                    let (got_errors, want_errors) = (
                        after.remove("errors").unwrap(),
                        want["errors"].as_array().unwrap(),
                    );
                    let got_errors = got_errors.as_array().unwrap();
                    assert_eq!(
                        want_errors.len(),
                        got_errors.len(),
                        "{name}, step {n}: errors"
                    );
                    for (got, want) in got_errors.iter().zip(want_errors) {
                        assert_eq!(want["file"], got["file"], "{name}, step {n}: error file");
                        let (got, want) = (
                            got["message"].as_str().unwrap(),
                            want["message"].as_str().unwrap(),
                        );
                        assert!(same_message(got, want), "{name}, step {n}: {got}");
                    }
                    let mut want = want.as_object().unwrap().clone();
                    want.remove("errors");
                    assert_eq!(
                        Value::Object(want),
                        Value::Object(after),
                        "{name}, step {n}"
                    );
                }
                other => panic!("a step the vectors do not name: {other}"),
            }
        }
    }
}

#[test]
fn a_folder_that_cannot_be_read_is_an_error_and_changes_nothing() {
    let dir = scratch("knowledge-index-unreadable");
    let mut db = open_db(dir.join("index.sqlite").to_str().unwrap()).unwrap();
    let missing = dir.join("missing");
    let error = reindex(&mut db, missing.to_str().unwrap(), true).unwrap_err();
    assert_eq!(
        format!("knowledge directory {} cannot be read", missing.display()),
        error
    );
}

#[test]
fn a_pass_waits_for_a_lock_another_connection_holds() {
    let dir = scratch("knowledge-index-lock");
    let folder = dir.join("folder");
    fs::create_dir(&folder).unwrap();
    let file = dir.join("index.sqlite");
    let mut db = open_db(file.to_str().unwrap()).unwrap();
    let (locked, wait) = mpsc::channel();
    let holder = {
        let file = file.clone();
        thread::spawn(move || {
            let other = Connection::open(file).unwrap();
            other.execute_batch("begin immediate").unwrap();
            locked.send(()).unwrap();
            thread::sleep(Duration::from_millis(400));
            other.execute_batch("commit").unwrap();
        })
    };
    wait.recv().unwrap();
    let start = Instant::now();
    reindex(&mut db, folder.to_str().unwrap(), false).unwrap();
    assert!(
        start.elapsed() >= Duration::from_millis(300),
        "the pass did not wait: {:?}",
        start.elapsed()
    );
    holder.join().unwrap();
}

#[test]
fn the_modification_time_is_floored_as_node_floors_it() {
    let dir = scratch("knowledge-index-mtime");
    let file = dir.join("f");
    fs::write(&file, "").unwrap();
    let mtime = &vectors()["engine"]["mtime"];
    for pair in mtime["pairs"].as_array().unwrap() {
        let (sec, nsec) = (
            pair["sec"].as_i64().unwrap(),
            pair["nsec"].as_i64().unwrap(),
        );
        assert_eq!(
            pair["floor"].as_i64().unwrap(),
            node::mtime_ms_floor_of(sec, nsec),
            "{sec} s {nsec} ns"
        );
    }
    // A file whose time is set to whole milliseconds reads back as them.
    set_mtime(&file, 1_700_000_000);
    assert_eq!(
        1_700_000_000_000,
        node::mtime_ms_floor(&fs::metadata(&file).unwrap())
    );
}

/// The terms of `x<c>x` for the code points of the vectors, read through `fts5vocab` as the generator reads them.
#[test]
fn the_tokenizer_splits_every_code_point_as_node_does() {
    let tokenizer = &vectors()["engine"]["tokenizer"];
    let db = Connection::open_in_memory().unwrap();
    db.execute_batch(&format!(
        "create virtual table t using fts5(body, tokenize='{TOKENIZER}')"
    ))
    .unwrap();
    db.execute_batch("create virtual table v using fts5vocab(t, 'instance')")
        .unwrap();
    let points: Vec<u32> = (0..=0xffff_u32)
        .filter(|cp| !(0xd800..=0xdfff).contains(cp))
        .collect();
    assert_eq!(
        tokenizer["codePoints"].as_u64().unwrap() as usize,
        points.len()
    );
    let supplementary: Vec<u32> = tokenizer["supplementary"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["cp"].as_u64().unwrap() as u32)
        .collect();
    let all: Vec<u32> = points.iter().chain(&supplementary).copied().collect();
    db.execute_batch("begin").unwrap();
    {
        let mut insert = db
            .prepare("insert into t (rowid, body) values (?1, ?2)")
            .unwrap();
        for (i, cp) in all.iter().enumerate() {
            let probe = format!("x{}x", char::from_u32(*cp).unwrap());
            insert
                .execute(rusqlite::params![i as i64 + 1, probe])
                .unwrap();
        }
    }
    db.execute_batch("commit").unwrap();
    let mut terms: Vec<Vec<String>> = vec![Vec::new(); all.len()];
    for row in rows(&db, "select doc, term from v order by doc, offset") {
        let doc = row["doc"].as_i64().unwrap() as usize;
        terms[doc - 1].push(row["term"].as_str().unwrap().to_string());
    }
    let mut blocks: Vec<(u32, String)> = Vec::new();
    for (i, cp) in points.iter().enumerate() {
        let block = cp >> 8;
        if blocks.last().is_none_or(|(b, _)| *b != block) {
            blocks.push((block, String::new()));
        }
        let line = format!("{cp:04X} {}\n", terms[i].join(" "));
        blocks.last_mut().unwrap().1.push_str(&line);
    }
    let digests: Vec<Value> = blocks
        .iter()
        .map(|(block, text)| {
            let digest: String = Sha256::digest(text.as_bytes())
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect();
            json!({"first": block << 8, "digest": digest})
        })
        .collect();
    let wrong: Vec<String> = digests
        .iter()
        .zip(tokenizer["blocks"].as_array().unwrap())
        .filter(|(ours, theirs)| ours != theirs)
        .map(|(ours, _)| format!("{:#06x}", ours["first"].as_u64().unwrap()))
        .collect();
    assert_eq!(tokenizer["blocks"].as_array().unwrap().len(), digests.len());
    assert!(wrong.is_empty(), "blocks that differ: {}", wrong.join(" "));
    for (i, expected) in tokenizer["supplementary"]
        .as_array()
        .unwrap()
        .iter()
        .enumerate()
    {
        assert_eq!(
            expected["terms"],
            json!(terms[points.len() + i]),
            "code point {:#x}",
            supplementary[i]
        );
    }
}

#[test]
fn the_compile_options_are_node_s_but_for_the_listed_ones() {
    let schema = &vectors()["engine"]["schema"];
    let db = Connection::open_in_memory().unwrap();
    let ours: BTreeSet<String> = rows(&db, "pragma compile_options")
        .iter()
        .map(|r| r["compile_options"].as_str().unwrap().to_string())
        .filter(|o| !o.starts_with("COMPILER="))
        .collect();
    let node_has: BTreeSet<String> = schema["compileOptions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| o.as_str().unwrap().to_string())
        .collect();
    let only_here: Vec<&String> = ours.difference(&node_has).collect();
    let only_node: Vec<&String> = node_has.difference(&ours).collect();
    assert_eq!(
        ONLY_HERE
            .iter()
            .map(|(option, _)| *option)
            .collect::<Vec<_>>(),
        only_here,
        "options only the bundled SQLite has"
    );
    assert_eq!(
        ONLY_IN_NODE
            .iter()
            .map(|(option, _)| *option)
            .collect::<Vec<_>>(),
        only_node,
        "options only node's SQLite has"
    );
}
