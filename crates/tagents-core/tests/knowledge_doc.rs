//! The knowledge document reader against what `packages/knowledge/src/doc.ts` does, case by case from `tests/fixtures/knowledge-vectors.json`.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::fs;

use serde_json::{Value, json};
use tagents_core::knowledge::doc::{
    Meta, chunk, hash_of, is_real_date, is_stale, list_files, parse_doc, parse_offset_datetime,
    read_doc, split_frontmatter, utc_date_of,
};

use common::{
    knowledge::{same_message, vectors},
    scratch,
};

fn meta_json(meta: &Meta) -> Value {
    json!({
        "id": meta.id,
        "type": meta.type_,
        "title": meta.title,
        "description": meta.description,
        "tags": meta.tags,
        "resource": meta.resource,
        "generated": meta.generated.as_ref().map(|g| json!({"by": g.by, "at": g.at})),
        "sources": meta.sources.iter().map(|s| json!({"resource": s.resource, "id": s.id, "title": s.title})).collect::<Vec<_>>(),
        "status": meta.status,
        "staleAfter": meta.stale_after,
        "scope": meta.scope,
        "legacy": meta.legacy,
    })
}

fn chunks_json(body: &str) -> Value {
    Value::Array(
        chunk(body)
            .iter()
            .map(|c| json!({"heading": c.heading, "ord": c.ord, "body": c.body}))
            .collect(),
    )
}

/// Documents whose reading differs from node's, each with the reason. The test fails for a document that differs and is not here, and for one that is here and no longer differs.
const KNOWN_DIFFERENCES: &[(&str, &str)] = &[
    (
        "CRLF line endings",
        "the `yaml` package keeps a lone carriage return that ends the front matter as part of the last plain scalar (`title: Crlf` is `Crlf\\r`) and refuses a quoted or flow value that ends it; saphyr takes it for a line break",
    ),
    (
        "an explicit int tag on a title",
        "saphyr resolves an explicit core tag on a quoted scalar to a string and drops the tag (see `front_matter::tests::KNOWN_DIFFERENCES`)",
    ),
];

#[test]
fn every_document_splits_parses_and_cuts_into_sections_as_node_does() {
    // Every case runs, so a failure names all the documents that differ and not only the first.
    let mut failed: Vec<&str> = vectors()["docs"]["documents"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|case| std::panic::catch_unwind(|| check_document(case)).is_err())
        .map(|case| case["name"].as_str().unwrap())
        .collect();
    let mut listed: Vec<&str> = KNOWN_DIFFERENCES.iter().map(|(name, _)| *name).collect();
    failed.sort_unstable();
    listed.sort_unstable();
    assert_eq!(
        failed, listed,
        "documents that differ from node (left) against the listed known differences (right)"
    );
}

fn check_document(case: &Value) {
    {
        let name = case["name"].as_str().unwrap();
        let text = case["text"].as_str().unwrap();
        match (&case["split"], split_frontmatter(text)) {
            (Value::Null, got) => assert!(got.is_none(), "{name}: node finds no front matter"),
            (want, got) => {
                let (yaml, body) = got.unwrap_or_else(|| panic!("{name}: no front matter found"));
                assert_eq!(
                    (
                        want["yaml"].as_str().unwrap(),
                        want["body"].as_str().unwrap()
                    ),
                    (yaml.as_str(), body.as_str()),
                    "{name}"
                );
            }
        }
        let parsed = parse_doc(case["file"].as_str().unwrap(), text);
        let result = &case["result"];
        if let Some(want) = result.get("error") {
            let want = want.as_str().unwrap();
            let got = parsed
                .err()
                .unwrap_or_else(|| panic!("{name}: node refuses it and Rust reads it"))
                .message;
            assert!(same_message(&got, want), "{name}: {got}");
            return;
        }
        let want = &result["ok"];
        let doc =
            parsed.unwrap_or_else(|e| panic!("{name}: node reads it and Rust says {}", e.message));
        assert_eq!(meta_json(&doc.meta), want["meta"], "{name}");
        assert_eq!(
            doc.declared_id.as_deref(),
            want["declaredId"].as_str(),
            "{name}"
        );
        assert_eq!(doc.body, want["body"].as_str().unwrap(), "{name}");
        assert_eq!(chunks_json(&doc.body), want["chunks"], "{name}");
        assert_eq!(doc.hash, want["hash"].as_str().unwrap(), "{name}");
    }
}

#[test]
fn a_line_is_a_heading_where_the_regular_expression_says_it_is() {
    for case in vectors()["docs"]["headings"].as_array().unwrap() {
        let line = case["line"].as_str().unwrap();
        let chunks = chunk(line);
        let got = chunks
            .first()
            .filter(|c| !c.heading.is_empty())
            .map(|c| c.heading.as_str());
        assert_eq!(got, case["heading"].as_str(), "{line:?}");
    }
}

#[test]
fn dates_and_staleness_are_node_s() {
    let dates = &vectors()["docs"]["dates"];
    for case in dates["values"].as_array().unwrap() {
        let value = case["value"].as_str().unwrap();
        assert_eq!(
            parse_offset_datetime(value),
            case["offsetMs"].as_i64(),
            "{value:?}"
        );
        assert_eq!(
            utc_date_of(value).as_deref(),
            case["utcDate"].as_str(),
            "{value:?}"
        );
    }
    for case in dates["stale"].as_array().unwrap() {
        let at = case["staleAfter"].as_str().unwrap();
        assert_eq!(
            is_stale(Some(at), case["now"].as_i64().unwrap()),
            case["stale"].as_bool().unwrap(),
            "{at:?}"
        );
    }
    assert!(!is_stale(None, 0));
    for case in dates["realDates"].as_array().unwrap() {
        let value = case["value"].as_str().unwrap();
        assert_eq!(
            is_real_date(value),
            case["real"].as_bool().unwrap(),
            "{value:?}"
        );
    }
}

#[test]
fn the_hash_is_the_first_32_digits_of_the_sha256_of_the_text() {
    for case in vectors()["docs"]["hashes"].as_array().unwrap() {
        assert_eq!(
            hash_of(case["text"].as_str().unwrap()),
            case["hash"].as_str().unwrap()
        );
    }
}

#[test]
fn a_file_is_decoded_as_node_decodes_it_and_read_whole() {
    let dir = scratch("knowledge-decode");
    for case in vectors()["docs"]["decode"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let hex = case["hex"].as_str().unwrap();
        let bytes: Vec<u8> = (0..hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
            .collect();
        let file = dir.join(format!("{}.md", case["stem"].as_str().unwrap()));
        fs::write(&file, bytes).unwrap();
        let doc =
            read_doc(file.to_str().unwrap()).unwrap_or_else(|e| panic!("{name}: {}", e.message));
        assert_eq!(doc.hash, case["hash"].as_str().unwrap(), "{name}");
        assert_eq!(chunks_json(&doc.body), case["chunks"], "{name}");
        assert_eq!(meta_json(&doc.meta), case["meta"], "{name}");
    }
}

#[test]
fn a_folder_lists_the_documents_node_lists_and_holds_each_to_the_slug_rule() {
    let folder = &vectors()["docs"]["folder"];
    let dir = scratch("knowledge-folder");
    let dir_text = dir.to_str().unwrap().to_owned();
    for name in folder["names"].as_array().unwrap() {
        let name = name.as_str().unwrap();
        if name == "dir.md (a directory)" {
            fs::create_dir(dir.join("dir.md")).unwrap();
        } else if name == "link.md (a symlink)" {
            std::os::unix::fs::symlink(dir.join("a.md"), dir.join("link.md")).unwrap();
        } else {
            fs::write(
                dir.join(name),
                format!("---\ntype: Note\n---\nbody of {name}\n"),
            )
            .unwrap();
        }
    }
    let listed: Vec<String> = list_files(&dir_text)
        .unwrap()
        .iter()
        .map(|f| f.rsplit('/').next().unwrap().to_owned())
        .collect();
    let want: Vec<&str> = folder["listed"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n.as_str().unwrap())
        .collect();
    assert_eq!(listed, want);
    for read in folder["reads"].as_array().unwrap() {
        let name = read["name"].as_str().unwrap();
        let got = read_doc(&format!("{dir_text}/{name}"));
        match read.get("ok") {
            Some(ok) => {
                let doc = got.unwrap_or_else(|e| panic!("{name}: {}", e.message));
                assert_eq!(
                    (doc.meta.id.as_str(), doc.hash.as_str()),
                    (ok["id"].as_str().unwrap(), ok["hash"].as_str().unwrap()),
                    "{name}"
                );
            }
            None => assert_eq!(
                got.err().unwrap().message.replace(&dir_text, "<dir>"),
                read["error"].as_str().unwrap(),
                "{name}"
            ),
        }
    }
    let missing = list_files(&format!("{dir_text}/nowhere")).unwrap_err();
    assert_eq!(
        missing.replace(&dir_text, "<dir>"),
        folder["missingFolder"].as_str().unwrap()
    );
}
