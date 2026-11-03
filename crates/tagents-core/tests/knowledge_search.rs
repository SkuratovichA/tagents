//! Search, list and get against what `packages/knowledge/src/search.ts` does: the match expression and the hits of the fuzzed searches, and every search and list call the node MCP server answered over three corpora, case by case from `tests/fixtures/knowledge-vectors.json`.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use rusqlite::params;
use serde_json::{Value, json};
use tagents_core::{
    js,
    knowledge::{
        index::open_db,
        search::{
            DocSummary, Filters, Hit, fts_query, get_doc, get_section, list_docs, parse_address,
            search,
        },
    },
};

use common::{
    knowledge::{index_of, vectors},
    scratch,
};

/// The fixed clock of the vectors: 2026-10-31T12:00:00Z.
const NOW: i64 = 1_793_448_000_000;

/// A number as JavaScript prints it, which is how the vectors hold it.
fn number(n: f64) -> Value {
    serde_json::from_str(&js::number_text(n)).unwrap()
}

fn hit_json(hit: &Hit, folder: &str) -> Value {
    json!({
        "type": hit.life.type_,
        "description": hit.life.description,
        "status": hit.life.status,
        "stale": hit.life.stale,
        "id": hit.id,
        "title": hit.title,
        "heading": hit.heading,
        "score": number(hit.score),
        "snippet": hit.snippet,
        "path": hit.path.replace(folder, "<dir>"),
    })
}

fn summary_json(doc: &DocSummary, folder: &str) -> Value {
    json!({
        "type": doc.life.type_,
        "description": doc.life.description,
        "status": doc.life.status,
        "stale": doc.life.stale,
        "id": doc.id,
        "title": doc.title,
        "tags": doc.tags,
        "updated": doc.updated,
        "path": doc.path.replace(folder, "<dir>"),
        "headings": doc.headings,
    })
}

fn filters(args: &Value) -> Filters<'_> {
    Filters {
        tag: args["tag"].as_str(),
        type_: args["type"].as_str(),
        kind: args["kind"].as_str(),
    }
}

#[test]
fn the_expression_and_the_hits_of_the_fuzzed_searches_are_node_s() {
    let fuzz = &vectors()["corpus"]["fuzz"];
    let (db, folder) = index_of("knowledge-search-fuzz", &fuzz["files"]);
    let cases = fuzz["cases"].as_array().unwrap();
    assert_eq!(196, cases.len());
    // The limits the tools never send (they take 1 to 50): node binds the double it floors, and SQLite makes an integer of it or refuses.
    for limit in [1e300, 1e19, 0.5, 0.0, -1.0] {
        assert!(
            cases.iter().any(|c| c["limit"].as_f64() == Some(limit)),
            "no case with the limit {limit}"
        );
    }
    let mut with_hits = 0;
    for case in cases {
        let words: Vec<&str> = case["words"]
            .as_array()
            .unwrap()
            .iter()
            .map(|w| w.as_str().unwrap())
            .collect();
        assert_eq!(
            case["match"].as_str().unwrap(),
            fts_query(&words),
            "expression for {words:?}"
        );
        let hits = search(
            &db,
            &words,
            &Filters::default(),
            case["limit"].as_f64(),
            NOW,
        );
        let got: Vec<Value> = hits.iter().map(|h| hit_json(h, &folder)).collect();
        assert_eq!(
            case["hits"],
            Value::Array(got),
            "hits for {words:?}, limit {:?}",
            case["limit"]
        );
        with_hits += usize::from(!hits.is_empty());
    }
    // A fuzz that finds nothing proves nothing.
    assert!(
        with_hits >= 20,
        "{with_hits} of {} searches found something",
        cases.len()
    );
}

#[test]
fn every_search_and_list_the_node_server_answered_is_answered_the_same() {
    let corpora = vectors()["corpus"]["corpora"].as_array().unwrap();
    assert_eq!(3, corpora.len());
    let (mut searches, mut lists, mut sections) = (0, 0, 0);
    for corpus in corpora {
        let name = corpus["name"].as_str().unwrap();
        let (db, folder) = index_of(&format!("knowledge-search-{name}"), &corpus["files"]);
        for call in corpus["calls"].as_array().unwrap() {
            let (Some(tool), false) = (
                call["tool"].as_str(),
                call["isError"].as_bool().unwrap_or(true),
            ) else {
                continue;
            };
            let args = &call["args"];
            // A whole document is read from its file by the tool: the vector names the file and holds no text.
            let text = call["text"].as_str().unwrap_or("");
            match tool {
                "knowledge_search" => {
                    let query = args["query"].as_str().unwrap();
                    let hits = search(&db, &[query], &filters(args), args["limit"].as_f64(), NOW);
                    let want = if hits.is_empty() {
                        format!("nothing matches \"{query}\"")
                    } else {
                        serde_json::to_string(&Value::Array(
                            hits.iter().map(|h| hit_json(h, &folder)).collect(),
                        ))
                        .unwrap()
                    };
                    if hits.is_empty() {
                        assert_eq!(want, text, "{name}: search {args}");
                    } else {
                        assert_eq!(
                            serde_json::from_str::<Value>(text).unwrap(),
                            serde_json::from_str::<Value>(&want).unwrap(),
                            "{name}: search {args}"
                        );
                    }
                    searches += 1;
                }
                "knowledge_list" => {
                    let docs = list_docs(&db, &filters(args), NOW).unwrap();
                    let got = Value::Array(docs.iter().map(|d| summary_json(d, &folder)).collect());
                    assert_eq!(
                        serde_json::from_str::<Value>(text).unwrap(),
                        got,
                        "{name}: list {args}"
                    );
                    lists += 1;
                }
                "knowledge_get" if call["whole"].is_string() => {
                    let id = args["id"].as_str().unwrap();
                    assert_eq!(format!("{id}.md"), call["whole"].as_str().unwrap());
                    let doc = get_doc(&db, id, NOW)
                        .unwrap()
                        .unwrap_or_else(|| panic!("{name}: no document for {args}"));
                    assert_eq!(format!("{folder}/{id}.md"), doc.path, "{name}: {args}");
                }
                "knowledge_get" if args["heading"].is_string() => {
                    let id = args["id"].as_str().unwrap();
                    let section = get_section(&db, id, args["heading"].as_str().unwrap()).unwrap();
                    let section = section.unwrap_or_else(|| {
                        panic!("{name}: no section for {args}, node answered {text}")
                    });
                    assert!(text.contains(&section.body), "{name}: section {args}");
                    assert!(get_doc(&db, id, NOW).unwrap().is_some(), "{name}: {args}");
                    sections += 1;
                }
                _ => {}
            }
        }
    }
    // A replay that skipped its calls proves nothing.
    assert!(
        searches >= 100 && lists >= 20 && sections >= 5,
        "replayed {searches} searches, {lists} lists, {sections} sections"
    );
}

#[test]
fn a_heading_is_found_without_case_in_every_script_and_a_missing_one_is_none() {
    let files = json!([{"name": "doc.md", "text": "---\ntype: Note\ntitle: Doc\n---\nPreamble.\n\n## Диски\nпро диски\n\n## Deploy Steps\nrun it\n", "mtimeSec": 1_700_000_000}]);
    let (db, _) = index_of("knowledge-search-heading", &files);
    assert_eq!(
        "про диски",
        get_section(&db, "doc", "диски").unwrap().unwrap().body
    );
    assert_eq!(
        "run it",
        get_section(&db, "doc", "  deploy STEPS ")
            .unwrap()
            .unwrap()
            .body
    );
    assert_eq!(
        "Preamble.",
        get_section(&db, "doc", "").unwrap().unwrap().body
    );
    assert_eq!(None, get_section(&db, "doc", "nothing").unwrap());
    assert_eq!(None, get_section(&db, "nothing", "диски").unwrap());
    assert_eq!(None, get_doc(&db, "nothing", NOW).unwrap());
}

#[test]
fn an_address_is_an_id_and_maybe_a_heading() {
    assert_eq!(("a", None), parse_address("a"));
    assert_eq!(("a", None), parse_address("  a "));
    assert_eq!(("a", Some("B c")), parse_address("a#B c"));
    assert_eq!(("a", Some("B")), parse_address(" a # B "));
    assert_eq!(("", Some("x")), parse_address("#x"));
    assert_eq!(("a", Some("")), parse_address("a#"));
    assert_eq!(("a", Some("b#c")), parse_address("a#b#c"));
}

/// Sections that rank alike come in the order of the document, not in the order the index stored them. The rows are written backwards, so that the storage order is the opposite of the document's: a reindex always writes in the document's order, which is why only rows written by hand can tell the key `chunks.ord` from none.
#[test]
fn sections_that_rank_alike_come_in_the_order_of_the_document() {
    let dir = scratch("knowledge-search-ord-tie");
    let db = open_db(dir.join("index.sqlite").to_str().unwrap()).unwrap();
    db.execute("insert into docs (id, path, title, type, type_key, description, tags, status, mtime, hash) values ('note', 'note.md', 'Note', 'Note', 'note', '', '[]', 'stable', 1, 'h')", []).unwrap();
    for (ord, heading) in [(2, "third"), (1, "second"), (0, "first")] {
        db.execute(
            "insert into chunks (doc_id, heading, ord, body) values ('note', ?1, ?2, 'zyxwv')",
            params![heading, ord],
        )
        .unwrap();
        db.execute(
            "insert into chunks_fts (rowid, doc_id, heading, body) values (last_insert_rowid(), 'note', ?1, 'zyxwv')",
            [heading],
        )
        .unwrap();
    }
    let hits = search(&db, &["zyxwv"], &Filters::default(), None, NOW);
    let headings: Vec<&str> = hits.iter().map(|hit| hit.heading.as_str()).collect();
    assert_eq!(vec!["first", "second", "third"], headings);
    assert!(
        hits.windows(2).all(|pair| pair[0].score == pair[1].score),
        "the sections must tie for the order to come from the key: {hits:?}"
    );
}
