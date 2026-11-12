//! The OKF progressive-disclosure file, `index.md` at the folder root, as `packages/knowledge/src/toc.ts` writes and checks it. `toc` writes it and `lint` checks it, and both go through `render_index`, so what lint calls out of date is what toc would change. The output is a pure function of the documents: same folder, same bytes.

use std::fs;

use super::doc::{Document, one_line};
use tagents_core::{js, node};

pub const INDEX_FILE: &str = "index.md";

const HEAD: &str = "---\nokf_version: \"0.2\"\n---\n";

/// Brackets in link text are escaped, so a title like `Plan ] draft` stays one link.
fn link_text(s: &str) -> String {
    one_line(s).replace('[', "\\[").replace(']', "\\]")
}

/// Code-unit order, not locale order: the same folder gives the same bytes on every machine.
fn by_text(a: &str, b: &str) -> std::cmp::Ordering {
    a.encode_utf16().cmp(b.encode_utf16())
}

/// The text of `index.md` for these documents: groups by type, entries by id.
pub fn render_index(docs: &[&Document]) -> String {
    let mut sorted: Vec<&&Document> = docs.iter().collect();
    sorted.sort_by(|a, b| by_text(&a.meta.id, &b.meta.id));
    // (lowercased type, first spelling, entries)
    let mut groups: Vec<(String, String, Vec<String>)> = Vec::new();
    for doc in sorted {
        let key = js::lower(&doc.meta.type_);
        let position = match groups.iter().position(|(k, _, _)| *k == key) {
            Some(position) => position,
            None => {
                groups.push((key, one_line(&doc.meta.type_), Vec::new()));
                groups.len() - 1
            }
        };
        let description = doc
            .meta
            .description
            .as_deref()
            .map_or_else(String::new, |d| format!(" - {}", one_line(d)));
        let deprecated = if doc.meta.status == "deprecated" {
            " (deprecated)"
        } else {
            ""
        };
        groups[position].2.push(format!(
            "* [{}]({}.md){description}{deprecated}",
            link_text(&doc.meta.title),
            doc.meta.id
        ));
    }
    if groups.is_empty() {
        return HEAD.to_owned();
    }
    groups.sort_by(|a, b| by_text(&a.0, &b.0));
    let body: Vec<String> = groups
        .iter()
        .map(|(_, heading, lines)| format!("# {heading}\n\n{}", lines.join("\n")))
        .collect();
    format!("{HEAD}\n{}\n", body.join("\n\n"))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndexState {
    Current,
    Missing,
    Outdated,
}

/// How the `index.md` on disk compares with what `render_index` gives for `docs`.
pub fn index_state(dir: &str, docs: &[&Document]) -> IndexState {
    let Ok(bytes) = fs::read(node::join(dir, INDEX_FILE)) else {
        return IndexState::Missing;
    };
    if String::from_utf8_lossy(&bytes) == render_index(docs) {
        IndexState::Current
    } else {
        IndexState::Outdated
    }
}

/// Writes `index.md` and returns its path, or what node says of the failure.
pub fn write_index(dir: &str, docs: &[&Document]) -> Result<String, String> {
    let file = node::join(dir, INDEX_FILE);
    fs::write(&file, render_index(docs)).map_err(|e| node::io_message(&e, "open", Some(&file)))?;
    Ok(file)
}
