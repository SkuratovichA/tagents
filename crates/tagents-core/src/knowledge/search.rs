//! Asking the index a question (`packages/knowledge/src/search.ts`).
//!
//! A hit is a chunk, addressed as `id#heading`. Ranking is bm25 with the heading weighted ten times the body, a deprecated document is ranked after every other and never hidden, and staleness is a question about now, computed per query from the clock the caller hands in.

use rusqlite::{Connection, params_from_iter, types::Value};

use super::doc::{is_stale, one_line, utc_date_of};
use super::index;
use crate::js;

const HEADING_WEIGHT: &str = "10.0";
const BODY_WEIGHT: &str = "1.0";
const DEFAULT_LIMIT: i64 = 10;
const SNIPPET_TOKENS: &str = "14";

/// What a document is, as of the query.
#[derive(Debug, Clone, PartialEq)]
pub struct Lifecycle {
    pub type_: String,
    /// Empty when the document has none.
    pub description: String,
    pub status: String,
    /// `stale_after` has been reached.
    pub stale: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Hit {
    pub life: Lifecycle,
    pub id: String,
    pub title: String,
    /// Empty for the preamble chunk.
    pub heading: String,
    pub score: f64,
    pub snippet: String,
    pub path: String,
}

/// The filters of a search and of a list. `type_` is exact and case-insensitive, `kind` is its deprecated alias, and `type_` wins when both are given.
#[derive(Debug, Default, Clone, Copy)]
pub struct Filters<'a> {
    pub tag: Option<&'a str>,
    pub type_: Option<&'a str>,
    pub kind: Option<&'a str>,
}

/// Words to an FTS5 MATCH expression. Everything typed is quoted, because an unquoted `-` means NOT and an unbalanced `"` is a syntax error; a trailing `*` survives quoting as FTS5's prefix operator.
pub fn fts_query(words: &[&str]) -> String {
    let joined = words.join(" ");
    let terms: Vec<String> = js::split_space(&joined)
        .into_iter()
        .filter_map(|raw| {
            let (bare, prefix) = match raw.strip_suffix('*') {
                Some(bare) => (bare, "*"),
                None => (raw, ""),
            };
            let bare = bare.replace('"', "");
            (!js::trim(&bare).is_empty()).then(|| format!("\"{bare}\"{prefix}"))
        })
        .collect();
    terms.join(" ")
}

/// The SQL of the filters, to be appended to a query that names `docs`, and its parameters.
fn filter_sql(filters: &Filters) -> (String, Vec<Value>) {
    let mut sql = Vec::new();
    let mut params = Vec::new();
    let type_ = filters
        .type_
        .filter(|t| !t.is_empty())
        .or(filters.kind)
        .filter(|t| !t.is_empty());
    if let Some(type_) = type_ {
        sql.push("and docs.type_key = ?");
        params.push(Value::Text(js::lower(type_)));
    }
    if let Some(tag) = filters.tag.filter(|t| !t.is_empty()) {
        sql.push("and exists (select 1 from json_each(docs.tags) where value = ?)");
        params.push(Value::Text(tag.to_string()));
    }
    (sql.join(" "), params)
}

fn lifecycle(
    type_: String,
    description: String,
    status: String,
    stale_after: Option<&str>,
    now_ms: i64,
) -> Lifecycle {
    let status = if ["draft", "stable", "deprecated"].contains(&status.as_str()) {
        status
    } else {
        "stable".to_string()
    };
    Lifecycle {
        type_,
        description,
        status,
        stale: is_stale(stale_after, now_ms),
    }
}

/// The best sections for the words, best first. A limit that is not above zero means the default, and one with a fraction is floored.
/// An expression FTS5 refuses is an empty result, not a failure, and so is any other failure of the query: the node program catches them all.
pub fn search(
    db: &Connection,
    words: &[&str],
    filters: &Filters,
    limit: Option<f64>,
    now_ms: i64,
) -> Vec<Hit> {
    let match_ = fts_query(words);
    if match_.is_empty() {
        return Vec::new();
    }
    let limit = match limit {
        Some(limit) if limit > 0.0 => limit.floor() as i64,
        _ => DEFAULT_LIMIT,
    };
    let (filter, mut params) = filter_sql(filters);
    params.insert(0, Value::Text(match_));
    params.push(Value::Integer(limit));
    let sql = format!(
        "select docs.id, docs.title, docs.path, docs.type, docs.description, docs.status, docs.stale_after, chunks.heading,
                bm25(chunks_fts, 0.0, {HEADING_WEIGHT}, {BODY_WEIGHT}) as rank,
                snippet(chunks_fts, 2, '[', ']', '…', {SNIPPET_TOKENS}) as snip
           from chunks_fts
           join chunks on chunks.rowid = chunks_fts.rowid
           join docs on docs.id = chunks.doc_id
          where chunks_fts match ? {filter}
          order by (docs.status = 'deprecated') asc, rank asc, docs.id asc, chunks.ord asc
          limit ?"
    );
    let query = || -> rusqlite::Result<Vec<Hit>> {
        let mut statement = db.prepare(&sql)?;
        let rows = statement.query_map(params_from_iter(params.iter()), |row| {
            let stale_after: Option<String> = row.get(6)?;
            let rank: f64 = row.get(8)?;
            let snippet: String = row.get(9)?;
            Ok(Hit {
                life: lifecycle(
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    stale_after.as_deref(),
                    now_ms,
                ),
                id: row.get(0)?,
                title: row.get(1)?,
                heading: row.get(7)?,
                // bm25 counts down from zero; callers want "bigger is better".
                score: js::round(-rank * 1000.0) / 1000.0,
                snippet: one_line(&snippet),
                path: row.get(2)?,
            })
        })?;
        rows.collect()
    };
    query().unwrap_or_default()
}

/// A document as the list and the get tools show it.
#[derive(Debug, Clone, PartialEq)]
pub struct DocSummary {
    pub life: Lifecycle,
    pub id: String,
    pub title: String,
    pub tags: Vec<String>,
    /// The UTC date of `generated.at`, or `-` when the document has no `generated`.
    pub updated: String,
    pub path: String,
    pub headings: Vec<String>,
}

fn tags_of(text: &str) -> Result<Vec<String>, String> {
    let parsed: serde_json::Value = serde_json::from_str(if text.is_empty() { "[]" } else { text })
        .map_err(|e| e.to_string())?;
    Ok(match parsed {
        serde_json::Value::Array(items) => items
            .into_iter()
            .filter_map(|item| item.as_str().map(str::to_string))
            .collect(),
        _ => Vec::new(),
    })
}

const SUMMARY_COLUMNS: &str =
    "id, title, path, type, description, status, stale_after, generated_at, tags";

fn summary(db: &Connection, row: &rusqlite::Row, now_ms: i64) -> Result<DocSummary, String> {
    let id: String = row.get(0).map_err(index::sql)?;
    let stale_after: Option<String> = row.get(6).map_err(index::sql)?;
    let generated_at: Option<String> = row.get(7).map_err(index::sql)?;
    let tags: String = row.get(8).map_err(index::sql)?;
    let mut statement = db
        .prepare("select heading from chunks where doc_id = ? order by ord asc")
        .map_err(index::sql)?;
    let headings = statement
        .query_map([&id], |r| r.get::<_, String>(0))
        .map_err(index::sql)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(index::sql)?
        .into_iter()
        .filter(|h| !h.is_empty())
        .collect();
    Ok(DocSummary {
        life: lifecycle(
            row.get(3).map_err(index::sql)?,
            row.get(4).map_err(index::sql)?,
            row.get(5).map_err(index::sql)?,
            stale_after.as_deref(),
            now_ms,
        ),
        title: row.get(1).map_err(index::sql)?,
        tags: tags_of(&tags)?,
        updated: generated_at
            .as_deref()
            .and_then(utc_date_of)
            .unwrap_or_else(|| "-".to_string()),
        path: row.get(2).map_err(index::sql)?,
        headings,
        id,
    })
}

/// Every document that passes the filters, the live ones first.
pub fn list_docs(
    db: &Connection,
    filters: &Filters,
    now_ms: i64,
) -> Result<Vec<DocSummary>, String> {
    let (filter, params) = filter_sql(filters);
    let mut statement = db
        .prepare(&format!("select {SUMMARY_COLUMNS} from docs where 1 = 1 {filter} order by (docs.status = 'deprecated') asc, docs.id asc"))
        .map_err(index::sql)?;
    let mut rows = statement
        .query(params_from_iter(params.iter()))
        .map_err(index::sql)?;
    let mut docs = Vec::new();
    while let Some(row) = rows.next().map_err(index::sql)? {
        docs.push(summary(db, row, now_ms)?);
    }
    Ok(docs)
}

/// One document, or none.
pub fn get_doc(db: &Connection, id: &str, now_ms: i64) -> Result<Option<DocSummary>, String> {
    let mut statement = db
        .prepare(&format!("select {SUMMARY_COLUMNS} from docs where id = ?"))
        .map_err(index::sql)?;
    let mut rows = statement.query([id]).map_err(index::sql)?;
    match rows.next().map_err(index::sql)? {
        Some(row) => summary(db, row, now_ms).map(Some),
        None => Ok(None),
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Section {
    pub id: String,
    pub heading: String,
    pub ord: i64,
    pub body: String,
}

/// One `## ` section (heading empty is the preamble), or none. The heading is matched without case in JavaScript's way and not with `collate nocase`, which folds ASCII only, so `диски` finds `Диски`.
pub fn get_section(db: &Connection, id: &str, heading: &str) -> Result<Option<Section>, String> {
    let want = js::lower(js::trim(heading));
    let mut statement = db
        .prepare("select heading, ord, body from chunks where doc_id = ? order by ord asc")
        .map_err(index::sql)?;
    let rows = statement
        .query_map([id], |r| {
            Ok(Section {
                id: id.to_string(),
                heading: r.get(0)?,
                ord: r.get(1)?,
                body: r.get(2)?,
            })
        })
        .map_err(index::sql)?;
    for row in rows {
        let section = row.map_err(index::sql)?;
        if js::lower(&section.heading) == want {
            return Ok(Some(section));
        }
    }
    Ok(None)
}

/// `id#heading` to its two halves. A bare id means the whole document.
pub fn parse_address(address: &str) -> (&str, Option<&str>) {
    match address.find('#') {
        None => (js::trim(address), None),
        Some(hash) => (
            js::trim(&address[..hash]),
            Some(js::trim(&address[hash + 1..])),
        ),
    }
}
