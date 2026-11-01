//! The index of the knowledge documents: SQLite with one FTS5 table over the chunks, the same file `packages/knowledge/src/db.ts` makes and reads.
//!
//! The index is a derived artefact, rebuilt from the markdown, and both programs open the same file: the schema text, the tokenizer and the busy timeout are the node ones, and `tests/knowledge_index.rs` pins them against `tests/fixtures/knowledge-vectors.json`.
//!
//! Errors are the messages the node program would show: SQLite's own text, or the `mkdir` error of Node.

use std::{
    collections::{HashMap, HashSet},
    fs,
    path::Path,
    time::Duration,
};

use rusqlite::{Connection, OpenFlags, TransactionBehavior, params, types::ValueRef};

use super::doc::{DocError, Document, list_files, read_doc, stem_of};
use crate::{js, json, node};

/// The version of the schema below; a file of another version is dropped and made again.
pub const SCHEMA_VERSION: i64 = 2;

/// The tokenizer of the one FTS5 table: Unicode-aware word splitting, with diacritics folded for multi-byte text.
pub const TOKENIZER: &str = "unicode61 remove_diacritics 2";

/// How long a connection waits for a lock another connection holds before it fails with `database is locked`: the node program waits as long, and without it a write of either program would fail the call of the other.
pub const INDEX_BUSY_TIMEOUT_MS: u64 = 5000;

/// The schema, text for text as `db.ts` holds it: SQLite stores the statement as written in `sqlite_master`, and the test compares those rows.
const DDL: &str = r#"
create table if not exists meta (key text primary key, value text not null);

create table if not exists docs (
  id      text primary key,
  path    text not null,
  title   text not null,
  type    text not null,           -- as written (legacy 'kind' is capitalised)
  type_key text not null,          -- the type lowercased in JS: the filter compares this, SQLite's lower() folds ASCII only
  description text not null,       -- '' when the document has none
  tags    text not null,           -- a JSON array, queried with json_each
  status  text not null,           -- draft | stable | deprecated
  stale_after  text,               -- ISO 8601 with offset; staleness is computed on read, never stored
  generated_at text,               -- ISO 8601 with offset; null when the document has no 'generated'
  mtime   integer not null,        -- ms, the file's mtime at index time
  hash    text not null            -- sha256 of the file, first 32 hex chars
);

create table if not exists chunks (
  doc_id  text not null references docs(id) on delete cascade,
  heading text not null,           -- '' is the preamble before the first '## '
  ord     integer not null,
  body    text not null,
  primary key (doc_id, ord)
);

create index if not exists chunks_by_doc on chunks(doc_id);

create virtual table if not exists chunks_fts using fts5(
  doc_id unindexed,
  heading,
  body,
  tokenize='@@TOKENIZER@@'
);
"#;

/// What a failed SQLite call says, as the node program would show it.
fn sql(err: rusqlite::Error) -> String {
    err.to_string()
}

/// Open a SQLite file, making its directory if need be, for reading and writing as `node:sqlite` opens one. The index and the usage store both start here.
pub fn open_file(file: &str) -> Result<Connection, String> {
    if file != ":memory:"
        && let Some(dir) = Path::new(file).parent()
    {
        fs::create_dir_all(dir)
            .map_err(|e| node::io_message(&e, "mkdir", Some(&dir.to_string_lossy())))?;
    }
    let flags = OpenFlags::SQLITE_OPEN_READ_WRITE
        | OpenFlags::SQLITE_OPEN_CREATE
        | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    Connection::open_with_flags(file, flags).map_err(sql)
}

/// Open (creating it if need be) and bring the schema up to date.
pub fn open_db(file: &str) -> Result<Connection, String> {
    let db = open_file(file)?;
    db.busy_timeout(Duration::from_millis(INDEX_BUSY_TIMEOUT_MS))
        .map_err(sql)?;
    db.execute_batch("pragma foreign_keys = on").map_err(sql)?;
    let mut stored = stored_version(&db);
    // No migration path while the schema is one version old: the index is a derived artefact, and rebuilding it from the markdown costs milliseconds.
    // The stored text is read as a JavaScript number, so `' 2 '` and `'2.0'` are version 2 and `'abc'` is none.
    if stored
        .as_deref()
        .is_some_and(|v| js::number(v) != SCHEMA_VERSION as f64)
    {
        for table in ["chunks_fts", "chunks", "docs", "meta"] {
            db.execute_batch(&format!("drop table if exists {table}"))
                .map_err(sql)?;
        }
        stored = None;
    }
    db.execute_batch(&DDL.replace("@@TOKENIZER@@", TOKENIZER))
        .map_err(sql)?;
    // Written only when it differs: a write lock on every open would make every reader wait for it.
    let version = SCHEMA_VERSION.to_string();
    if stored.as_deref() != Some(version.as_str()) {
        db.execute(
            "insert or replace into meta (key, value) values ('schema_version', ?1)",
            [&version],
        )
        .map_err(sql)?;
    }
    Ok(db)
}

/// The text of the stored schema version, or none when the file has no meta table yet (or is no database: the DDL that follows says so).
fn stored_version(db: &Connection) -> Option<String> {
    db.query_row(
        "select value from meta where key = 'schema_version'",
        [],
        |row| {
            Ok(match row.get_ref(0)? {
                ValueRef::Text(bytes) => String::from_utf8_lossy(bytes).into_owned(),
                ValueRef::Integer(i) => i.to_string(),
                ValueRef::Real(f) => f.to_string(),
                ValueRef::Null => "0".to_string(),
                ValueRef::Blob(_) => "NaN".to_string(),
            })
        },
    )
    .ok()
}

/// What one pass over the folder did.
#[derive(Debug, Default, PartialEq)]
pub struct IndexStats {
    pub added: usize,
    pub changed: usize,
    pub unchanged: usize,
    pub removed: usize,
    pub errors: Vec<DocError>,
}

struct Known {
    mtime: i64,
    hash: String,
}

fn delete_doc(db: &Connection, id: &str) -> Result<(), String> {
    for statement in [
        "delete from chunks_fts where doc_id = ?1",
        "delete from chunks where doc_id = ?1",
        "delete from docs where id = ?1",
    ] {
        db.prepare(statement)
            .map_err(sql)?
            .execute([id])
            .map_err(sql)?;
    }
    Ok(())
}

fn insert_doc(db: &Connection, doc: &Document, mtime: i64) -> Result<(), String> {
    let meta = &doc.meta;
    let tags = meta
        .tags
        .iter()
        .map(|tag| json::quote(tag))
        .collect::<Vec<_>>()
        .join(",");
    db.prepare(
        "insert into docs (id, path, title, type, type_key, description, tags, status, stale_after, generated_at, mtime, hash) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
    )
    .map_err(sql)?
    .execute(params![
        meta.id,
        doc.path,
        meta.title,
        meta.type_,
        js::lower(&meta.type_),
        meta.description.as_deref().unwrap_or(""),
        format!("[{tags}]"),
        meta.status,
        meta.stale_after,
        meta.generated.as_ref().map(|g| g.at.as_str()),
        mtime,
        doc.hash,
    ])
    .map_err(sql)?;
    let mut chunks = db
        .prepare("insert into chunks (doc_id, heading, ord, body) values (?1, ?2, ?3, ?4)")
        .map_err(sql)?;
    let mut fts = db
        .prepare("insert into chunks_fts (rowid, doc_id, heading, body) values (?1, ?2, ?3, ?4)")
        .map_err(sql)?;
    for chunk in &doc.chunks {
        chunks
            .execute(params![
                meta.id,
                chunk.heading,
                chunk.ord as i64,
                chunk.body
            ])
            .map_err(sql)?;
        // The FTS table shares the chunks rowid: that is the join, and it is why a delete has to walk both tables.
        fts.execute(params![
            db.last_insert_rowid(),
            meta.id,
            chunk.heading,
            chunk.body
        ])
        .map_err(sql)?;
    }
    Ok(())
}

fn known_docs(db: &Connection) -> Result<HashMap<String, Known>, String> {
    let mut statement = db
        .prepare("select id, mtime, hash from docs")
        .map_err(sql)?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get(0)?,
                Known {
                    mtime: row.get(1)?,
                    hash: row.get(2)?,
                },
            ))
        })
        .map_err(sql)?;
    rows.collect::<rusqlite::Result<_>>().map_err(sql)
}

/// Bring the index in line with the folder.
///
/// A file whose mtime is unchanged is not even read; one whose mtime moved is read and compared by hash, so `git checkout` (which rewrites mtimes and not content) costs a hash, not a reindex. Documents whose file is gone are dropped, and so is one that stopped parsing: it must not keep serving its last good text.
///
/// The whole pass is one transaction that takes the write lock first, so another program's pass waits for this one instead of failing halfway, and a failure leaves the index as it was.
pub fn reindex(db: &mut Connection, dir: &str, full: bool) -> Result<IndexStats, String> {
    let files = list_files(dir)?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(sql)?;
    if full {
        tx.execute_batch("delete from chunks_fts; delete from chunks; delete from docs")
            .map_err(sql)?;
    }
    let known = known_docs(&tx)?;
    let mut seen: HashSet<String> = HashSet::new();
    let mut stats = IndexStats::default();
    for file in &files {
        let id = stem_of(file);
        // A file that vanished between the listing and the stat.
        let Ok(stat) = fs::metadata(file) else {
            continue;
        };
        let mtime = node::mtime_ms_floor(&stat);
        seen.insert(id.clone());
        let before = known.get(&id);
        if before.is_some_and(|b| b.mtime == mtime) {
            stats.unchanged += 1;
            continue;
        }
        let doc = match read_doc(file) {
            Ok(doc) => doc,
            Err(error) => {
                stats.errors.push(error);
                if before.is_some() {
                    delete_doc(&tx, &id)?;
                }
                seen.remove(&id);
                continue;
            }
        };
        if let Some(before) = before {
            if before.hash == doc.hash {
                tx.execute(
                    "update docs set mtime = ?1 where id = ?2",
                    params![mtime, id],
                )
                .map_err(sql)?;
                stats.unchanged += 1;
                continue;
            }
            delete_doc(&tx, &id)?;
            stats.changed += 1;
        } else {
            stats.added += 1;
        }
        insert_doc(&tx, &doc, mtime)?;
    }
    for id in known.keys().filter(|id| !seen.contains(*id)) {
        delete_doc(&tx, id)?;
        stats.removed += 1;
    }
    tx.commit().map_err(sql)?;
    Ok(stats)
}

/// How many documents the index holds.
pub fn doc_count(db: &Connection) -> Result<i64, String> {
    db.query_row("select count(*) from docs", [], |row| row.get(0))
        .map_err(sql)
}
