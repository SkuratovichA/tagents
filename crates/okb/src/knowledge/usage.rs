//! What was read, and how often (`packages/knowledge/src/usage.ts`).
//!
//! The usage store is a SQLite file of its own, beside the index in use and never inside it: the index is derived and is rebuilt whenever its schema moves, while this is the only copy of what happened. It holds one row per event, because the report asks for a window, for the number of days and for the newest read of any age.
//!
//! Recording is best effort and happens after a read succeeded: it opens the store, writes the events of one call in one transaction and closes it again, so the shared daemon never pins a file its owner may move. What is stored is the document, the heading, whether it was read or only matched, and who read: never the text of a query and never a session id.

use std::{collections::HashMap, fmt, path::Path, time::Duration};

use rusqlite::{Connection, OpenFlags, TransactionBehavior, params};

use tagents_core::{date::MS_PER_DAY, js};

use super::{
    index::{open_file, sql},
    search::{Filters, Hit, list_docs},
};

pub const RETENTION_DAYS: i64 = 365;
pub const BUSY_TIMEOUT_MS: u64 = 250;
pub const DEFAULT_SINCE_DAYS: i64 = 30;
pub const DEFAULT_TOP: i64 = 20;
pub const DEFAULT_MIN_GETS: i64 = 5;
pub const DEFAULT_MIN_DAYS: i64 = 3;

/// The table, text for text as `usage.ts` holds it: SQLite stores the statement as written in `sqlite_master`, and the test compares those rows.
const DDL: &str = r#"
create table if not exists usage_events (
  ts      integer not null,             -- ms since the epoch
  doc_id  text    not null,
  heading text    not null default '',  -- '' for a whole document or a search hit
  kind    text    not null,             -- 'get' | 'hit'
  caller  text                          -- the MCP client or $TA_LABEL; null when nobody said
);
create index if not exists usage_by_doc on usage_events(doc_id, ts);  -- the report groups by document without a sort
create index if not exists usage_by_ts on usage_events(ts);           -- the retention finds what is old without a scan
"#;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Kind {
    /// A get returned the text.
    Get,
    /// A hit only matched a query.
    Hit,
}

impl Kind {
    fn as_str(self) -> &'static str {
        match self {
            Kind::Get => "get",
            Kind::Hit => "hit",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct UsageEvent {
    pub doc_id: String,
    /// Empty for a whole document or a search hit.
    pub heading: String,
    pub kind: Kind,
    pub caller: Option<String>,
}

/// Open (creating it, and its directory, if need be) and bring the table up to date.
pub fn open_usage_db(file: &str) -> Result<Connection, String> {
    let db = open_file(file)?;
    db.busy_timeout(Duration::from_millis(BUSY_TIMEOUT_MS))
        .map_err(sql)?;
    // Switching a new file to WAL does not wait for a lock: when two callers create the store at once, the second is refused at once. The file works in either mode and the next call finds it switched, so this is not a reason to lose the event.
    let _ = db.execute_batch("pragma journal_mode = wal");
    // A power cut may take the last event; a read must not wait for the disk.
    db.execute_batch("pragma synchronous = normal")
        .map_err(sql)?;
    db.execute_batch(DDL).map_err(sql)?;
    Ok(db)
}

/// One transaction: the events older than the retention go, the new ones come in.
pub fn append_events(
    db: &mut Connection,
    events: &[UsageEvent],
    now_ms: i64,
) -> Result<(), String> {
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(sql)?;
    tx.execute(
        "delete from usage_events where ts < ?1",
        [now_ms - RETENTION_DAYS * MS_PER_DAY],
    )
    .map_err(sql)?;
    {
        let mut insert = tx
            .prepare("insert into usage_events (ts, doc_id, heading, kind, caller) values (?1, ?2, ?3, ?4, ?5)")
            .map_err(sql)?;
        for e in events {
            insert
                .execute(params![
                    now_ms,
                    e.doc_id,
                    e.heading,
                    e.kind.as_str(),
                    e.caller
                ])
                .map_err(sql)?;
        }
    }
    tx.commit().map_err(sql)
}

/// Record the events of one successful read, and say why when that was not possible. Never fails: the read that called goes on.
pub fn record_reads(file: &str, events: &[UsageEvent], now_ms: i64) -> Option<String> {
    if events.is_empty() {
        return None;
    }
    open_usage_db(file)
        .and_then(|mut db| append_events(&mut db, events, now_ms))
        .err()
}

pub fn get_event(doc_id: &str, heading: &str, caller: Option<&str>) -> UsageEvent {
    UsageEvent {
        doc_id: doc_id.to_string(),
        heading: heading.to_string(),
        kind: Kind::Get,
        caller: caller.map(str::to_string),
    }
}

/// A search matched sections; what it tells is which documents, once each, in the order of the results.
pub fn hit_events(hits: &[Hit], caller: Option<&str>) -> Vec<UsageEvent> {
    let mut seen: Vec<&str> = Vec::new();
    for hit in hits {
        if !seen.contains(&hit.id.as_str()) {
            seen.push(&hit.id);
        }
    }
    seen.into_iter()
        .map(|id| UsageEvent {
            doc_id: id.to_string(),
            heading: String::new(),
            kind: Kind::Hit,
            caller: caller.map(str::to_string),
        })
        .collect()
}

/// A caller is a name that is not empty: the name a client gave in the handshake. Anything else is nobody, and the environment is not asked.
pub fn caller_from(name: Option<&str>) -> Option<&str> {
    name.filter(|name| !name.is_empty())
}

// ---- the report ------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub struct UsageRow {
    pub id: String,
    /// None for an id that is no longer in the folder.
    pub type_: Option<String>,
    pub status: Option<String>,
    pub gets: i64,
    pub hits: i64,
    /// Distinct UTC dates with a get inside the window.
    pub days: i64,
    /// The UTC date of the newest get of any age, none when there is none.
    pub last: Option<String>,
}

#[derive(Debug, Default, Clone)]
pub struct ReportOptions {
    pub since_days: Option<i64>,
    /// How many rows to keep, as `slice(0, top)` keeps them: a fraction is cut off and a negative number drops rows from the end.
    pub top: Option<f64>,
    /// Keep the documents of this type, matched as `list` matches it; ids no longer in the folder are dropped.
    pub type_: Option<String>,
    /// Also list the ids that have events but are no longer in the folder.
    pub all: bool,
    /// Keep the documents that were read often enough on enough days.
    pub candidates: bool,
    pub min_gets: Option<i64>,
    pub min_days: Option<i64>,
}

#[derive(Debug, Default, Clone)]
struct Counts {
    gets: i64,
    hits: i64,
    days: i64,
    last: Option<String>,
}

/// The events by document: the window for the counts, all of time for `last`. The dates are UTC, the calendar `utc_date_of` in doc.rs uses for the dates of a document.
fn counts_by_doc(usage: &Connection, since_ms: i64) -> rusqlite::Result<HashMap<String, Counts>> {
    let mut statement = usage.prepare(
        "select doc_id,
                count(case when kind = 'get' and ts >= ?1 then 1 end) as gets,
                count(case when kind = 'hit' and ts >= ?1 then 1 end) as hits,
                count(distinct case when kind = 'get' and ts >= ?1 then date(ts / 1000, 'unixepoch') end) as days,
                date(max(case when kind = 'get' then ts end) / 1000, 'unixepoch') as last
           from usage_events
          group by doc_id",
    )?;
    let rows = statement.query_map([since_ms], |row| {
        Ok((
            row.get(0)?,
            Counts {
                gets: row.get(1)?,
                hits: row.get(2)?,
                days: row.get(3)?,
                last: row.get(4)?,
            },
        ))
    })?;
    rows.collect()
}

/// The documents of the folder, joined by id with what the store counted, sorted and cut.
fn join_rows(
    index: &Connection,
    counts: &HashMap<String, Counts>,
    options: &ReportOptions,
    now_ms: i64,
) -> Result<Vec<UsageRow>, String> {
    // An empty type filters nothing, as it does for `list` and `search`.
    let type_ = options.type_.as_deref().filter(|t| !t.is_empty());
    let docs = list_docs(
        index,
        &Filters {
            type_,
            ..Filters::default()
        },
        now_ms,
    )?;
    let row = |id: &str, type_: Option<String>, status: Option<String>| {
        let c = counts.get(id).cloned().unwrap_or_default();
        UsageRow {
            id: id.to_string(),
            type_,
            status,
            gets: c.gets,
            hits: c.hits,
            days: c.days,
            last: c.last,
        }
    };
    let mut rows: Vec<UsageRow> = docs
        .iter()
        .map(|d| {
            row(
                &d.id,
                Some(d.life.type_.clone()).filter(|t| !t.is_empty()),
                Some(d.life.status.clone()),
            )
        })
        .collect();
    if options.all && type_.is_none() {
        for id in counts
            .keys()
            .filter(|id| !docs.iter().any(|d| &d.id == *id))
        {
            rows.push(row(id, None, None));
        }
    }
    let min_gets = options.min_gets.unwrap_or(DEFAULT_MIN_GETS);
    let min_days = options.min_days.unwrap_or(DEFAULT_MIN_DAYS);
    rows.retain(|r| {
        !options.candidates
            || (r.status.as_deref().is_some_and(|s| s != "deprecated")
                && r.gets >= min_gets
                && r.days >= min_days)
    });
    // Ids are ordered as JavaScript orders strings, by UTF-16 code unit.
    rows.sort_by(|a, b| {
        b.gets
            .cmp(&a.gets)
            .then(b.hits.cmp(&a.hits))
            .then_with(|| a.id.encode_utf16().cmp(b.id.encode_utf16()))
    });
    rows.truncate(js::slice_end(
        options.top.unwrap_or(DEFAULT_TOP as f64),
        rows.len(),
    ));
    Ok(rows)
}

fn window_start(options: &ReportOptions, now_ms: i64) -> i64 {
    now_ms.saturating_sub(
        options
            .since_days
            .unwrap_or(DEFAULT_SINCE_DAYS)
            .saturating_mul(MS_PER_DAY),
    )
}

/// A usage store that exists and cannot be read.
#[derive(Debug, Clone, PartialEq)]
pub struct UsageStoreError {
    pub file: String,
    pub reason: String,
}

impl fmt::Display for UsageStoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.file, self.reason)
    }
}

/// What the store at `file` counted. A file that is not there counts nothing, and is not created. A read-only connection to a WAL file leaves its `-wal` and `-shm` beside it until the next write closes them, which is harmless.
fn read_counts(file: &str, since_ms: i64) -> Result<HashMap<String, Counts>, UsageStoreError> {
    if !Path::new(file).exists() {
        return Ok(HashMap::new());
    }
    let broken = |e: rusqlite::Error| UsageStoreError {
        file: file.to_string(),
        reason: sql(e),
    };
    let usage = Connection::open_with_flags(
        file,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(broken)?;
    usage
        .busy_timeout(Duration::from_millis(BUSY_TIMEOUT_MS))
        .map_err(broken)?;
    // A file that is a database without the table, or has nothing in it yet, is an empty store, not a broken one.
    let mut table = usage
        .prepare("select 1 from sqlite_master where type = 'table' and name = 'usage_events'")
        .map_err(broken)?;
    if !table.exists([]).map_err(broken)? {
        return Ok(HashMap::new());
    }
    counts_by_doc(&usage, since_ms).map_err(broken)
}

/// Why a report could not be made.
#[derive(Debug, Clone, PartialEq)]
pub enum ReportError {
    /// The usage store is there and cannot be read.
    Store(UsageStoreError),
    /// The index could not be read.
    Index(String),
}

/// The report over the store at `file`.
pub fn read_usage_rows(
    index: &Connection,
    file: &str,
    options: &ReportOptions,
    now_ms: i64,
) -> Result<Vec<UsageRow>, ReportError> {
    let counts = read_counts(file, window_start(options, now_ms)).map_err(ReportError::Store)?;
    join_rows(index, &counts, options, now_ms).map_err(ReportError::Index)
}

/// `30d` is 30. A window is a positive whole number of days, written with the d.
pub fn parse_since(value: &str) -> Option<i64> {
    value.strip_suffix('d').and_then(parse_positive)
}

/// `20` is 20. Anything that is not a whole number from 1 up, and one JavaScript cannot count exactly, is none.
pub fn parse_positive(value: &str) -> Option<i64> {
    if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    value
        .parse::<i64>()
        .ok()
        .filter(|n| (1..=9_007_199_254_740_991).contains(n))
}
