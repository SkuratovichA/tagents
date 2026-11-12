//! The six tools of the knowledge server, over MCP (`packages/knowledge/src/mcp/server.ts`).
//!
//! NO TOOL WRITES A DOCUMENT: the documents are a git repository the owner edits, and a tool that wrote them would put an agent's paraphrase into the source of truth without a diff, a review or a commit message. The one thing a read tool leaves behind is an event in the usage store for each document it returns.
//!
//! The list a client reads is `tools.json`, written from the node server's own `tools/list`; the checks of a call's arguments are made against its schemas (`args`). Each call opens the index, brings it in line with the folder, runs one query and closes it, because the documents are edited while a client is connected.
//!
//! A tool's failure and an error it throws are told alike: a result with the flag set and the text. Tool text is machine-facing and English everywhere.

use std::sync::{Mutex, OnceLock};

use rusqlite::Connection;
use serde_json::{Map, Value, json};

use super::{
    args,
    index::{open_db, reindex},
    paths::{DirResult, Env},
    search::{self, DocSummary, Filters, Hit, Lifecycle},
    usage::{self, ReportError, ReportOptions, UsageRow},
};
use tagents_core::{
    ending::Stop,
    js,
    json::pretty,
    mcp::{rpc::CallResult, server::Tools},
    node, sessions,
    sync::locked,
    transcripts::Context,
};

/// How many sessions `sessions_recent` lists when it is not told.
const DEFAULT_SESSIONS: f64 = 15.0;

/// The entries of `tools/list`, in the order the node server announces them.
pub fn listing() -> &'static [Value] {
    static LIST: OnceLock<Vec<Value>> = OnceLock::new();
    LIST.get_or_init(|| serde_json::from_str(include_str!("tools.json")).unwrap_or_default())
}

/// The tools of one client's connection: the environment they work in, the clock their answers are dated by, and the name the client gave.
pub struct KnowledgeTools {
    env: Env,
    clock: fn() -> i64,
    client: Mutex<Option<String>>,
}

impl KnowledgeTools {
    pub fn new(env: Env, clock: fn() -> i64) -> KnowledgeTools {
        KnowledgeTools {
            env,
            clock,
            client: Mutex::new(None),
        }
    }

    /// Who is asking: the name the client gave in the handshake, when it gave one.
    fn caller(&self) -> Option<String> {
        let client = locked(&self.client);
        usage::caller_from(client.as_deref()).map(str::to_owned)
    }

    /// Open the index, bring it in line with the folder, run `query`, close.
    fn with_db<T>(
        &self,
        query: impl FnOnce(&Connection, &str) -> Result<T, String>,
    ) -> Result<T, String> {
        let dir = match self.env.resolve_dir() {
            DirResult::Found(dir) => dir,
            DirResult::Unset { config } => {
                return Err(format!(
                    "no knowledge directory: set TAGENTS_KNOWLEDGE_DIR or knowledge.dir in {config}"
                ));
            }
            DirResult::Missing { dir, .. } => {
                return Err(format!("knowledge directory {dir} does not exist"));
            }
        };
        let index_file = self.env.resolve_db();
        let mut db = open_db(&index_file)?;
        reindex(&mut db, &dir, false)?;
        query(&db, &index_file)
    }

    /// Leave the events of a read in the usage store. Silent: a tool has nobody to tell, and a store that fails never changes an answer.
    fn record(&self, events: &[usage::UsageEvent], index_file: &str) {
        let _ = usage::record_reads(
            &self.env.resolve_usage_db(index_file),
            events,
            (self.clock)(),
        );
    }

    fn tool_search(&self, args: &Map<String, Value>) -> Result<String, String> {
        let query = text(args, "query");
        let filters = filters_of(args);
        let hits = self.with_db(|db, index_file| {
            let hits = search::search(
                db,
                &[query],
                &filters,
                number(args, "limit"),
                (self.clock)(),
            );
            self.record(
                &usage::hit_events(&hits, self.caller().as_deref()),
                index_file,
            );
            Ok(hits)
        })?;
        if hits.is_empty() {
            return Ok(format!("nothing matches \"{query}\""));
        }
        Ok(pretty(&hits.iter().map(hit_json).collect::<Vec<_>>()))
    }

    fn tool_get(&self, args: &Map<String, Value>) -> Result<String, String> {
        let id = text(args, "id");
        self.with_db(|db, index_file| {
            let Some(doc) = search::get_doc(db, id, (self.clock)())? else {
                return Err(format!("no document with id \"{id}\""));
            };
            let Some(heading) = args.get("heading").and_then(Value::as_str) else {
                let text = match node::read_utf8(&doc.path) {
                    Ok(Some(text)) => text,
                    _ => format!("document file {} is gone; run the index", doc.path),
                };
                self.record(
                    &[usage::get_event(&doc.id, "", self.caller().as_deref())],
                    index_file,
                );
                return Ok(text);
            };
            let Some(section) = search::get_section(db, id, heading)? else {
                let headings = doc.headings.join(", ");
                return Err(format!(
                    "document \"{id}\" has no section \"{heading}\"; it has: {}",
                    if headings.is_empty() {
                        "(none)"
                    } else {
                        &headings
                    }
                ));
            };
            self.record(
                &[usage::get_event(
                    &doc.id,
                    &section.heading,
                    self.caller().as_deref(),
                )],
                index_file,
            );
            Ok(format!("## {}\n\n{}\n", section.heading, section.body))
        })
    }

    fn tool_list(&self, args: &Map<String, Value>) -> Result<String, String> {
        let filters = filters_of(args);
        let docs = self.with_db(|db, _| search::list_docs(db, &filters, (self.clock)()))?;
        Ok(pretty(&docs.iter().map(doc_json).collect::<Vec<_>>()))
    }

    fn tool_usage(&self, args: &Map<String, Value>) -> Result<String, String> {
        let since_days = match args.get("since").and_then(Value::as_str) {
            None => None,
            Some(since) => Some(usage::parse_since(since).ok_or(
                "since must be a positive whole number of days followed by d, such as 30d",
            )?),
        };
        let options = ReportOptions {
            since_days,
            top: number(args, "top"),
            type_: args.get("type").and_then(Value::as_str).map(str::to_owned),
            all: args.get("all").and_then(Value::as_bool).unwrap_or(false),
            candidates: args
                .get("candidates")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            min_gets: number(args, "min_gets").map(|n| n as i64),
            min_days: number(args, "min_days").map(|n| n as i64),
        };
        let rows = self.with_db(|db, index_file| {
            let file = self.env.resolve_usage_db(index_file);
            usage::read_usage_rows(db, &file, &options, (self.clock)()).map_err(|e| match e {
                ReportError::Store(e) => {
                    format!("the usage store {} cannot be read: {}", e.file, e.reason)
                }
                ReportError::Index(reason) => reason,
            })
        })?;
        Ok(pretty(&rows.iter().map(row_json).collect::<Vec<_>>()))
    }

    fn sessions_context(&self) -> Context {
        Context {
            home: self.env.home.clone(),
            claude_homes: self.env.claude_homes.clone(),
            now_ms: (self.clock)(),
        }
    }

    fn tool_sessions_search(&self, args: &Map<String, Value>) -> Result<String, String> {
        let words: Vec<String> = js::split_space(text(args, "words"))
            .into_iter()
            .filter(|word| !word.is_empty())
            .map(str::to_owned)
            .collect();
        sessions::search(&self.sessions_context(), &words)
    }
}

impl Tools for KnowledgeTools {
    fn list(&self) -> Vec<Value> {
        listing().to_vec()
    }

    fn connected(&self, client: &str) {
        *locked(&self.client) = Some(client.to_owned());
    }

    /// An unknown tool is answered here, as a failed call, which is how the SDK server answers it: only a server that wants the loop to answer it as an error of the request returns `None`.
    fn call(
        &self,
        name: &str,
        args: Option<&Map<String, Value>>,
        _stop: &Stop,
    ) -> Option<CallResult> {
        let Some(entry) = listing().iter().find(|entry| entry["name"] == name) else {
            return Some(CallResult::fail(format!(
                "MCP error -32602: Tool {name} not found"
            )));
        };
        if let Some(refusal) = args::refusal(name, &entry["inputSchema"], args) {
            return Some(CallResult::fail(refusal));
        }
        let empty = Map::new();
        let args = args.unwrap_or(&empty);
        let answer = match name {
            "knowledge_search" => self.tool_search(args),
            "knowledge_get" => self.tool_get(args),
            "knowledge_list" => self.tool_list(args),
            "knowledge_usage" => self.tool_usage(args),
            "sessions_recent" => sessions::recent(
                &self.sessions_context(),
                number(args, "limit").unwrap_or(DEFAULT_SESSIONS),
            ),
            _ => self.tool_sessions_search(args),
        };
        Some(match answer {
            Ok(text) => CallResult::ok(text),
            Err(text) => CallResult::fail(text),
        })
    }
}

/// A string argument the check let through, or an empty one for a call that left it out.
fn text<'a>(args: &'a Map<String, Value>, key: &str) -> &'a str {
    args.get(key).and_then(Value::as_str).unwrap_or("")
}

/// A number argument, as the double JavaScript reads it.
fn number(args: &Map<String, Value>, key: &str) -> Option<f64> {
    args.get(key).and_then(Value::as_f64)
}

fn filters_of(args: &Map<String, Value>) -> Filters<'_> {
    let get = |key: &str| args.get(key).and_then(Value::as_str);
    Filters {
        tag: get("tag"),
        type_: get("type"),
        kind: get("kind"),
    }
}

/// The four keys every document and hit starts with.
fn lifecycle(life: &Lifecycle) -> Map<String, Value> {
    let mut map = Map::new();
    map.insert("type".into(), json!(life.type_));
    map.insert("description".into(), json!(life.description));
    map.insert("status".into(), json!(life.status));
    map.insert("stale".into(), json!(life.stale));
    map
}

fn hit_json(hit: &Hit) -> Value {
    let mut map = lifecycle(&hit.life);
    map.insert("id".into(), json!(hit.id));
    map.insert("title".into(), json!(hit.title));
    map.insert("heading".into(), json!(hit.heading));
    map.insert("score".into(), json!(hit.score));
    map.insert("snippet".into(), json!(hit.snippet));
    map.insert("path".into(), json!(hit.path));
    Value::Object(map)
}

pub(super) fn doc_json(doc: &DocSummary) -> Value {
    let mut map = lifecycle(&doc.life);
    map.insert("id".into(), json!(doc.id));
    map.insert("title".into(), json!(doc.title));
    map.insert("tags".into(), json!(doc.tags));
    map.insert("updated".into(), json!(doc.updated));
    map.insert("path".into(), json!(doc.path));
    map.insert("headings".into(), json!(doc.headings));
    Value::Object(map)
}

pub(super) fn row_json(row: &UsageRow) -> Value {
    json!({
        "id": row.id,
        "type": row.type_,
        "status": row.status,
        "gets": row.gets,
        "hits": row.hits,
        "days": row.days,
        "last": row.last,
    })
}
