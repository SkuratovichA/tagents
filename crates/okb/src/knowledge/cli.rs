//! The verbs of `okb` that read and write the folder from a terminal: `index`, `search`, `show`, `list`, `lint`, `toc` and `usage`, as `packages/knowledge/src/cli/main.ts` ran them.
//!
//! Text output is for a human and comes from the catalogue in `texts.json`; `--json` output is a contract and is never translated. Every read verb brings the index in line with the folder first, so there is no searching yesterday's copy of a runbook. `search` and `show` also leave a line in the usage store once they have answered, best effort: a store that cannot take it never changes what was printed or the exit code, and `--verbose` is the only way to hear about it.
//!
//! Exit codes: 0 ok, 1 error, 2 usage, 4 nothing found.

use std::{ffi::OsString, fs};

use rusqlite::Connection;
use serde_json::{Map, Value, json};

use super::{
    doc::{Document, load_dir},
    index::{open_db, reindex},
    lint::lint,
    paths::{DirResult, Env},
    search::{self, DocSummary, Filters, Hit},
    toc::{IndexState, index_state, write_index},
    tools::{doc_json, row_json},
    usage::{
        self, DEFAULT_MIN_DAYS, DEFAULT_MIN_GETS, DEFAULT_SINCE_DAYS, DEFAULT_TOP, ReportError,
        ReportOptions, UsageRow,
    },
};
use tagents_core::{
    js,
    json::pretty,
    messages::Texts,
    node,
    parse_args::{Grammar, Kind, Parsed},
    sessions::{Output, exit},
};

/// Nothing matched, which is not an error but is not a success either.
const NOT_FOUND: u8 = 4;

const INDEX: Grammar = Grammar {
    options: &[
        ("dir", Kind::Text),
        ("db", Kind::Text),
        ("full", Kind::Flag),
    ],
    positionals: false,
};

const SEARCH: Grammar = Grammar {
    options: &[
        ("dir", Kind::Text),
        ("db", Kind::Text),
        ("tag", Kind::Text),
        ("type", Kind::Text),
        ("kind", Kind::Text),
        ("limit", Kind::Text),
        ("json", Kind::Flag),
        ("usage-db", Kind::Text),
        ("verbose", Kind::Flag),
    ],
    positionals: true,
};

const SHOW: Grammar = Grammar {
    options: &[
        ("dir", Kind::Text),
        ("db", Kind::Text),
        ("usage-db", Kind::Text),
        ("verbose", Kind::Flag),
    ],
    positionals: true,
};

const LIST: Grammar = Grammar {
    options: &[
        ("dir", Kind::Text),
        ("db", Kind::Text),
        ("type", Kind::Text),
        ("kind", Kind::Text),
        ("tag", Kind::Text),
        ("json", Kind::Flag),
    ],
    positionals: false,
};

const LINT: Grammar = Grammar {
    options: &[("dir", Kind::Text)],
    positionals: false,
};

const TOC: Grammar = Grammar {
    options: &[("dir", Kind::Text), ("check", Kind::Flag)],
    positionals: false,
};

const USAGE: Grammar = Grammar {
    options: &[
        ("dir", Kind::Text),
        ("db", Kind::Text),
        ("usage-db", Kind::Text),
        ("since", Kind::Text),
        ("top", Kind::Text),
        ("type", Kind::Text),
        ("all", Kind::Flag),
        ("candidates", Kind::Flag),
        ("min-gets", Kind::Text),
        ("min-days", Kind::Text),
        ("json", Kind::Flag),
    ],
    positionals: false,
};

/// The verbs this module serves.
pub const VERBS: [&str; 7] = ["index", "search", "show", "list", "lint", "toc", "usage"];

/// What a verb writes while it runs; the exit code is its result.
struct Run<'a> {
    texts: &'a Texts,
    env: Env,
    now_ms: i64,
    out: String,
    err: String,
}

/// A line to the error stream.
fn said(text: &str) -> String {
    format!("{text}\n")
}

/// A flag's value when it says something: `givenPath` and `resolveDir` ignore a blank one.
fn given(value: Option<&str>) -> Option<String> {
    value.filter(|v| !js::trim(v).is_empty()).map(str::to_owned)
}

/// What the dialect of `--dir`, `--db` and `--usage-db` is: a flag that says something replaces the variable of the same name.
fn env_with(env: &Env, parsed: &Parsed) -> Env {
    let mut env = env.clone();
    if let Some(dir) = given(parsed.value("dir")) {
        env.okb_dir = Some(dir);
    }
    if let Some(db) = given(parsed.value("db")) {
        env.knowledge_db = Some(db);
    }
    if let Some(usage_db) = given(parsed.value("usage-db")) {
        env.knowledge_usage_db = Some(usage_db);
    }
    env
}

/// ` [deprecated]` and ` [stale]`: the lifecycle marks at the end of a hit or list line.
fn marks(status: &str, stale: bool) -> String {
    format!(
        "{}{}",
        if status == "deprecated" {
            " [deprecated]"
        } else {
            ""
        },
        if stale { " [stale]" } else { "" }
    )
}

/// `n.toFixed(2)`: the nearest hundredth, a tie going away from zero.
fn to_fixed2(x: f64) -> String {
    let magnitude = if x == 0.0 { 0.0 } else { x };
    let exact = format!("{:.60}", magnitude.abs());
    let tie = exact.split_once('.').is_some_and(|(_, fraction)| {
        fraction.get(2..3) == Some("5") && fraction[3..].bytes().all(|b| b == b'0')
    });
    if tie {
        let hundredths = (magnitude.abs() * 100.0).floor() + 1.0;
        let text = format!("{hundredths:.0}");
        let padded = format!("{text:0>3}");
        let (whole, fraction) = padded.split_at(padded.len() - 2);
        let sign = if magnitude < 0.0 { "-" } else { "" };
        return format!("{sign}{whole}.{fraction}");
    }
    format!("{magnitude:.2}")
}

/// A hit as `--json` prints it: a contract, so the keys are listed in this order.
fn hit_json(hit: &Hit) -> Value {
    let mut map = Map::new();
    map.insert("id".into(), json!(hit.id));
    map.insert("title".into(), json!(hit.title));
    map.insert("heading".into(), json!(hit.heading));
    map.insert("score".into(), json!(hit.score));
    map.insert("snippet".into(), json!(hit.snippet));
    map.insert("path".into(), json!(hit.path));
    map.insert("type".into(), json!(hit.life.type_));
    map.insert("description".into(), json!(hit.life.description));
    map.insert("status".into(), json!(hit.life.status));
    map.insert("stale".into(), json!(hit.life.stale));
    Value::Object(map)
}

impl Run<'_> {
    fn t(&self, key: &str, vars: &[(&str, &str)]) -> String {
        self.texts.t(key, vars)
    }

    fn out_line(&mut self, text: &str) {
        self.out.push_str(text);
        self.out.push('\n');
    }

    fn err_line(&mut self, text: &str) {
        self.err.push_str(&said(text));
    }

    /// The folder, or the sentence that says why there is none.
    fn need_dir(&mut self, env: &Env) -> Option<String> {
        let message = match env.resolve_dir() {
            DirResult::Found(dir) => return Some(dir),
            DirResult::Unset { config } => self.t(
                "noDir",
                &[
                    ("config", &config),
                    ("snippet", "  dir = \"~/git/personal/knowledge\""),
                ],
            ),
            DirResult::Missing { dir, .. } => self.t("missingDir", &[("dir", &dir)]),
        };
        self.err_line(&message);
        None
    }

    /// Resolves the folder, opens the index and brings it in line with the folder, the files that stopped parsing named on stderr. None when there is no folder.
    fn open_index(&mut self, env: &Env) -> Result<Option<(Connection, String, String)>, String> {
        let Some(dir) = self.need_dir(env) else {
            return Ok(None);
        };
        let index_file = env.resolve_db();
        let mut db = open_db(&index_file)?;
        for e in reindex(&mut db, &dir, false)?.errors {
            self.err_line(&format!("{}: {}", node::basename(&e.file), e.message));
        }
        Ok(Some((db, dir, index_file)))
    }

    /// Leaves the events of a read that answered in the usage store; a store that cannot take them is named on stderr only for `--verbose`.
    fn record(&mut self, events: &[usage::UsageEvent], env: &Env, index_file: &str, verbose: bool) {
        let file = env.usage_file(index_file);
        if let Some(reason) = usage::record_reads(&file, events, self.now_ms)
            && verbose
        {
            let line = self.t("notRecorded", &[("file", &file), ("reason", &reason)]);
            self.err_line(&line);
        }
    }

    fn index(&mut self, parsed: &Parsed) -> Result<u8, String> {
        let env = env_with(&self.env, parsed);
        let Some(dir) = self.need_dir(&env) else {
            return Ok(exit::ERROR);
        };
        let file = env.resolve_db();
        let mut db = open_db(&file)?;
        let stats = reindex(&mut db, &dir, parsed.flag("full"))?;
        let line = self.t(
            "indexed",
            &[
                ("db", &file),
                ("added", &stats.added.to_string()),
                ("changed", &stats.changed.to_string()),
                ("unchanged", &stats.unchanged.to_string()),
                ("removed", &stats.removed.to_string()),
            ],
        );
        self.out_line(&line);
        for e in &stats.errors {
            self.err_line(&format!("{}: {}", node::basename(&e.file), e.message));
        }
        if stats.errors.is_empty() {
            return Ok(exit::OK);
        }
        let line = self.t("indexErrors", &[("count", &stats.errors.len().to_string())]);
        self.err_line(&line);
        Ok(exit::ERROR)
    }

    fn search(&mut self, parsed: &Parsed) -> Result<u8, String> {
        let words = parsed.words();
        if words.is_empty() || js::trim(&words.join(" ")).is_empty() {
            let line = self.t("missingOption", &[("option", "<query…>")]);
            self.err_line(&line);
            return Ok(exit::USAGE);
        }
        let limit = parsed.value("limit").map_or(f64::NAN, js::number);
        let env = env_with(&self.env, parsed);
        let Some((db, _, index_file)) = self.open_index(&env)? else {
            return Ok(exit::ERROR);
        };
        let filters = Filters {
            tag: parsed.value("tag"),
            type_: parsed.value("type"),
            kind: parsed.value("kind"),
        };
        let hits = search::search(
            &db,
            &words,
            &filters,
            limit.is_finite().then_some(limit),
            self.now_ms,
        );
        let caller = std::env::var("TA_LABEL").ok();
        let events = usage::hit_events(&hits, usage::caller_from(caller.as_deref()));
        let verbose = parsed.flag("verbose");
        if parsed.flag("json") {
            let text = pretty(&hits.iter().map(hit_json).collect::<Vec<_>>());
            self.out_line(&text);
            self.record(&events, &env, &index_file, verbose);
            return Ok(if hits.is_empty() { NOT_FOUND } else { exit::OK });
        }
        if hits.is_empty() {
            let query = format!("\"{}\"", words.join(" "));
            let line = self.t("noHits", &[("query", &query)]);
            self.err_line(&line);
            return Ok(NOT_FOUND);
        }
        for h in &hits {
            let address = if h.heading.is_empty() {
                h.id.clone()
            } else {
                format!("{}#{}", h.id, h.heading)
            };
            let line = format!(
                "{} {:>7}  {}{}",
                js::pad_end(&address, 38),
                to_fixed2(h.score),
                h.snippet,
                marks(&h.life.status, h.life.stale)
            );
            self.out_line(&line);
        }
        self.record(&events, &env, &index_file, verbose);
        Ok(exit::OK)
    }

    fn show(&mut self, parsed: &Parsed) -> Result<u8, String> {
        let words = parsed.words();
        let Some(address) = words.first().filter(|a| !js::trim(a).is_empty()) else {
            let line = self.t("missingOption", &[("option", "<id[#heading]>")]);
            self.err_line(&line);
            return Ok(exit::USAGE);
        };
        let (id, heading) = search::parse_address(address);
        let env = env_with(&self.env, parsed);
        let Some((db, _, index_file)) = self.open_index(&env)? else {
            return Ok(exit::ERROR);
        };
        let Some(doc) = search::get_doc(&db, id, self.now_ms)? else {
            let line = self.t("unknownId", &[("id", id)]);
            self.err_line(&line);
            return Ok(NOT_FOUND);
        };
        let caller = std::env::var("TA_LABEL").ok();
        let verbose = parsed.flag("verbose");
        let got = |run: &mut Self, section: &str| {
            let event = usage::get_event(&doc.id, section, usage::caller_from(caller.as_deref()));
            run.record(&[event], &env, &index_file, verbose);
        };
        let Some(heading) = heading else {
            let Ok(bytes) = fs::read(&doc.path) else {
                let line = self.t("unknownId", &[("id", id)]);
                self.err_line(&line);
                return Ok(NOT_FOUND);
            };
            let text = String::from_utf8_lossy(&bytes);
            self.out.push_str(&text);
            if !text.ends_with('\n') {
                self.out.push('\n');
            }
            got(self, "");
            return Ok(exit::OK);
        };
        let Some(section) = search::get_section(&db, id, heading)? else {
            let line = self.t("unknownHeading", &[("id", id), ("heading", heading)]);
            self.err_line(&line);
            return Ok(NOT_FOUND);
        };
        if section.heading.is_empty() {
            self.out_line(&section.body);
        } else {
            let text = format!("## {}\n\n{}", section.heading, section.body);
            self.out_line(&text);
        }
        got(self, &section.heading);
        Ok(exit::OK)
    }

    fn list(&mut self, parsed: &Parsed) -> Result<u8, String> {
        let env = env_with(&self.env, parsed);
        let Some((db, dir, _)) = self.open_index(&env)? else {
            return Ok(exit::ERROR);
        };
        let filters = Filters {
            tag: parsed.value("tag"),
            type_: parsed.value("type"),
            kind: parsed.value("kind"),
        };
        let docs: Vec<DocSummary> = search::list_docs(&db, &filters, self.now_ms)?;
        if parsed.flag("json") {
            let text = pretty(&docs.iter().map(doc_json).collect::<Vec<_>>());
            self.out_line(&text);
            return Ok(if docs.is_empty() { NOT_FOUND } else { exit::OK });
        }
        if docs.is_empty() {
            let line = self.t("noDocs", &[("dir", &dir)]);
            self.err_line(&line);
            return Ok(NOT_FOUND);
        }
        for d in &docs {
            let tags = if d.tags.is_empty() {
                String::new()
            } else {
                format!("  #{}", d.tags.join(" #"))
            };
            let line = format!(
                "{} {} {}  {}{tags}{}",
                js::pad_end(&d.id, 28),
                js::pad_end(&d.life.type_, 10),
                d.updated,
                d.title,
                marks(&d.life.status, d.life.stale)
            );
            self.out_line(&line);
        }
        Ok(exit::OK)
    }

    fn lint(&mut self, parsed: &Parsed) -> Result<u8, String> {
        let env = env_with(&self.env, parsed);
        let Some(dir) = self.need_dir(&env) else {
            return Ok(exit::ERROR);
        };
        let result = lint(&dir, self.texts, self.now_ms)?;
        for issue in &result.issues {
            self.out_line(&format!(
                "{}: {}",
                node::basename(&issue.file),
                issue.message
            ));
        }
        let count = if result.issues.is_empty() {
            result.checked
        } else {
            result.issues.len()
        };
        let key = if result.issues.is_empty() {
            "lintClean"
        } else {
            "lintProblems"
        };
        let line = self.t(key, &[("count", &count.to_string()), ("dir", &dir)]);
        self.out_line(&line);
        Ok(if result.issues.is_empty() {
            exit::OK
        } else {
            exit::ERROR
        })
    }

    fn toc(&mut self, parsed: &Parsed) -> Result<u8, String> {
        let env = env_with(&self.env, parsed);
        let Some(dir) = self.need_dir(&env) else {
            return Ok(exit::ERROR);
        };
        let (docs, errors) = load_dir(&dir)?;
        let listed: Vec<&Document> = docs.iter().collect();
        if parsed.flag("check") {
            if index_state(&dir, &listed) == IndexState::Current {
                return Ok(exit::OK);
            }
            let line = self.t("tocOutOfDate", &[]);
            self.err_line(&line);
            return Ok(exit::ERROR);
        }
        for e in &errors {
            self.err_line(&format!("{}: {}", node::basename(&e.file), e.message));
        }
        let path = write_index(&dir, &listed)?;
        let line = self.t("tocWrote", &[("path", &path)]);
        self.out_line(&line);
        Ok(exit::OK)
    }

    /// A count flag: its value, the default when it is absent, none (after saying which flag) when it is not a positive whole number.
    fn count_flag(&mut self, flag: &str, value: Option<&str>, fallback: i64) -> Option<i64> {
        let Some(value) = value else {
            return Some(fallback);
        };
        let n = usage::parse_positive(value);
        if n.is_none() {
            let line = self.t("badCount", &[("flag", flag)]);
            self.err_line(&line);
        }
        n
    }

    /// The report as text: the header, then a line per row, the columns at least two spaces apart and the counts flush right.
    fn usage_table(&self, rows: &[UsageRow]) -> Vec<String> {
        let columns = self.t("usageColumns", &[]);
        let header: Vec<String> = columns.split(' ').map(str::to_owned).collect();
        let dash = || "-".to_owned();
        let mut table = vec![header.clone()];
        for r in rows {
            table.push(vec![
                r.id.clone(),
                r.type_.clone().unwrap_or_else(dash),
                r.status.clone().unwrap_or_else(dash),
                r.gets.to_string(),
                r.hits.to_string(),
                r.days.to_string(),
                r.last.clone().unwrap_or_else(dash),
            ]);
        }
        let widths: Vec<usize> = (0..header.len())
            .map(|i| {
                table
                    .iter()
                    .map(|row| row.get(i).map_or(0, |c| js::len16(c)))
                    .max()
                    .unwrap_or(0)
            })
            .collect();
        table
            .iter()
            .map(|row| {
                let cells: Vec<String> = row
                    .iter()
                    .enumerate()
                    .map(|(i, cell)| {
                        let width = widths.get(i).copied().unwrap_or(0);
                        if (3..=5).contains(&i) {
                            format!(
                                "{}{cell}",
                                " ".repeat(width.saturating_sub(js::len16(cell)))
                            )
                        } else {
                            js::pad_end(cell, width)
                        }
                    })
                    .collect();
                cells.join("  ").trim_end_matches(js::is_space).to_owned()
            })
            .collect()
    }

    fn usage(&mut self, parsed: &Parsed) -> Result<u8, String> {
        let since_days = match parsed.value("since") {
            None => Some(DEFAULT_SINCE_DAYS),
            Some(since) => usage::parse_since(since),
        };
        if since_days.is_none() {
            let line = self.t("badSince", &[]);
            self.err_line(&line);
        }
        let top = self.count_flag("top", parsed.value("top"), DEFAULT_TOP);
        let min_gets = self.count_flag("min-gets", parsed.value("min-gets"), DEFAULT_MIN_GETS);
        let min_days = self.count_flag("min-days", parsed.value("min-days"), DEFAULT_MIN_DAYS);
        let (Some(since_days), Some(top), Some(min_gets), Some(min_days)) =
            (since_days, top, min_gets, min_days)
        else {
            return Ok(exit::USAGE);
        };
        let env = env_with(&self.env, parsed);
        let Some((db, _, index_file)) = self.open_index(&env)? else {
            return Ok(exit::ERROR);
        };
        let file = env.usage_file(&index_file);
        let options = ReportOptions {
            since_days: Some(since_days),
            top: Some(top as f64),
            type_: parsed.value("type").map(str::to_owned),
            all: parsed.flag("all"),
            candidates: parsed.flag("candidates"),
            min_gets: Some(min_gets),
            min_days: Some(min_days),
        };
        let rows = match usage::read_usage_rows(&db, &file, &options, self.now_ms) {
            Ok(rows) => rows,
            Err(ReportError::Store(e)) => {
                let line = self.t(
                    "usageUnreadable",
                    &[("file", &e.file), ("reason", &e.reason)],
                );
                self.err_line(&line);
                return Ok(exit::ERROR);
            }
            Err(ReportError::Index(reason)) => return Err(reason),
        };
        if parsed.flag("json") {
            let text = pretty(&rows.iter().map(row_json).collect::<Vec<_>>());
            self.out_line(&text);
            return Ok(if rows.is_empty() { NOT_FOUND } else { exit::OK });
        }
        if rows.is_empty() {
            let line = self.t("noUsageRows", &[]);
            self.err_line(&line);
            return Ok(NOT_FOUND);
        }
        for line in self.usage_table(&rows) {
            self.out_line(&line);
        }
        Ok(exit::OK)
    }
}

/// The grammar of a verb of this module, or none for a word that is not one.
fn grammar(verb: &str) -> Option<&'static Grammar> {
    match verb {
        "index" => Some(&INDEX),
        "search" => Some(&SEARCH),
        "show" => Some(&SHOW),
        "list" => Some(&LIST),
        "lint" => Some(&LINT),
        "toc" => Some(&TOC),
        "usage" => Some(&USAGE),
        _ => None,
    }
}

/// What the verb `verb` writes and its exit code for `args`, the words after it.
pub fn answer(verb: &str, args: &[OsString], texts: &Texts, env: Env, now_ms: i64) -> Output {
    let mut run = Run {
        texts,
        env,
        now_ms,
        out: String::new(),
        err: String::new(),
    };
    let code = match grammar(verb).map(|g| g.parse(args)) {
        None => exit::USAGE,
        Some(Err(error)) => {
            run.err_line(&error.to_string());
            exit::USAGE
        }
        Some(Ok(parsed)) => {
            let result = match verb {
                "index" => run.index(&parsed),
                "search" => run.search(&parsed),
                "show" => run.show(&parsed),
                "list" => run.list(&parsed),
                "lint" => run.lint(&parsed),
                "toc" => run.toc(&parsed),
                _ => run.usage(&parsed),
            };
            result.unwrap_or_else(|message| {
                run.err_line(&message);
                exit::ERROR
            })
        }
    };
    Output {
        stdout: run.out,
        stderr: run.err,
        code,
    }
}

/// The usage text with the exit code of a bare `okb` (2), of `help` (0) and of an unknown word (2, on stderr, after the line that names it).
pub fn usage_answer(word: Option<&str>, texts: &Texts) -> Output {
    let usage = texts.t("usage", &[]);
    match word {
        None => Output {
            stdout: format!("{usage}\n"),
            stderr: String::new(),
            code: exit::USAGE,
        },
        Some("help" | "--help" | "-h") => Output {
            stdout: format!("{usage}\n"),
            stderr: String::new(),
            code: exit::OK,
        },
        Some(command) => Output {
            stdout: String::new(),
            stderr: format!(
                "{}\n{usage}\n",
                texts.t("unknownCommand", &[("command", command)])
            ),
            code: exit::USAGE,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::to_fixed2;

    #[test]
    fn to_fixed_rounds_as_javascript_does() {
        assert_eq!(to_fixed2(0.125), "0.13");
        assert_eq!(to_fixed2(2.5), "2.50");
        assert_eq!(to_fixed2(1.005), "1.00");
        assert_eq!(to_fixed2(-0.125), "-0.13");
        assert_eq!(to_fixed2(-0.0), "0.00");
        assert_eq!(to_fixed2(-0.001), "-0.00");
        assert_eq!(to_fixed2(12.3456), "12.35");
    }
}
