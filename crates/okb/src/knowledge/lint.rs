//! Is the folder still telling the truth? `packages/knowledge/src/lint.ts` in Rust.
//!
//! The loader is tolerant, as OKF asks of a consumer; this is the strict layer. It reports a rule of the profile that the loader let through (a tag that is not a slug, a status nobody knows, an unknown key) and a claim a document makes about itself that can rot without anybody touching it: a `generated.at` older than the last commit that changed the text, a source that moved on, a link to a document that was renamed, an `index.md` that no longer lists what the folder holds.

use std::{collections::HashMap, fs, path::Path, process::Command};

use super::doc::{
    self, Document, LEGACY_KEYS, OKF_KEYS, RESERVED_FILES, SCOPES, STATUSES, document_links,
    fragment_matches, has_url_scheme, is_real_date, is_slug, is_stale, list_files,
    parse_offset_datetime, stem_of, utc_date_of,
};
use super::front_matter::Yaml;
use super::paths::expand_home;
use super::toc::{INDEX_FILE, IndexState, index_state};
use tagents_core::{date, js, messages::Texts, node};

/// A finding: the file it is about and what is wrong.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Issue {
    pub file: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LintResult {
    pub checked: usize,
    pub issues: Vec<Issue>,
}

/// The UTC date of the newest commit that touched `file`, or none.
fn last_commit_date(file: &str) -> Option<String> {
    let out = Command::new("git")
        .args([
            "-C",
            &node::dirname(file),
            "log",
            "-1",
            "--format=%cI",
            "--",
            file,
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    utc_date_of(js::trim(&String::from_utf8_lossy(&out.stdout)))
}

fn inside_git_repo(dir: &str) -> bool {
    Command::new("git")
        .args(["-C", dir, "rev-parse", "--is-inside-work-tree"])
        .output()
        .is_ok_and(|out| {
            out.status.success() && js::trim(&String::from_utf8_lossy(&out.stdout)) == "true"
        })
}

/// `String(value)` for what a front matter holds.
fn js_string(value: &Yaml) -> String {
    match value {
        Yaml::Null => "null".to_owned(),
        Yaml::Bool(b) => b.to_string(),
        Yaml::Num(n) => n.clone(),
        Yaml::Str(s) => s.clone(),
        Yaml::Seq(items) => items
            .iter()
            .map(|item| match item {
                Yaml::Null => String::new(),
                other => js_string(other),
            })
            .collect::<Vec<_>>()
            .join(","),
        Yaml::Map(_) => "[object Object]".to_owned(),
    }
}

/// The keys of a mapping in the order `Object.keys` lists them: the ones that are array indexes first, by number, then the others as written.
fn object_keys(entries: &[(String, Yaml)]) -> Vec<&str> {
    let index_of = |key: &str| -> Option<u32> {
        let canonical =
            key == "0" || (!key.starts_with('0') && key.bytes().all(|b| b.is_ascii_digit()));
        canonical
            .then(|| key.parse::<u32>().ok())
            .flatten()
            .filter(|n| *n != u32::MAX)
    };
    let mut indexes: Vec<(u32, &str)> = Vec::new();
    let mut names: Vec<&str> = Vec::new();
    for (key, _) in entries {
        match index_of(key) {
            Some(n) => indexes.push((n, key)),
            None => names.push(key),
        }
    }
    indexes.sort_by_key(|(n, _)| *n);
    indexes
        .into_iter()
        .map(|(_, key)| key)
        .chain(names)
        .collect()
}

/// `by` is a non-blank string and `at` a datetime with an explicit offset.
fn is_stamp(value: &Yaml) -> bool {
    matches!(value, Yaml::Map(_))
        && value
            .get("by")
            .and_then(Yaml::as_str)
            .is_some_and(|by| !js::trim(by).is_empty())
        && value
            .get("at")
            .and_then(Yaml::as_str)
            .is_some_and(|at| parse_offset_datetime(at).is_some())
}

/// The messages of the profile violations in one document's front matter.
fn profile_problems(doc: &Document, t: &Texts) -> Vec<String> {
    let raw = &doc.raw;
    let mut out = Vec::new();
    let Yaml::Map(entries) = raw else {
        return out;
    };
    for key in object_keys(entries) {
        let known = OKF_KEYS.contains(&key) || (doc.meta.legacy && LEGACY_KEYS.contains(&key));
        if !known {
            out.push(t.t("issueUnknownKey", &[("key", key)]));
        }
    }

    let not_string = |key: &str| t.t("issueNotString", &[("key", key)]);
    if raw.get("id").is_some_and(|v| v.as_str().is_none()) {
        out.push(not_string("id"));
    }
    for key in ["title", "description", "resource"] {
        match raw.get(key) {
            Some(value) if value.as_str().is_none() => out.push(not_string(key)),
            Some(Yaml::Str(s)) if key == "description" && js::trim(s).contains('\n') => {
                out.push(t.t("issueDescriptionLines", &[]));
            }
            _ => {}
        }
    }

    if let Some(tags) = raw.get("tags") {
        match tags {
            Yaml::Seq(list) => {
                for tag in list {
                    if !tag.as_str().is_some_and(is_slug) {
                        out.push(t.t("issueTag", &[("tag", &js_string(tag))]));
                    }
                }
            }
            _ => out.push(t.t("issueTagsList", &[])),
        }
    }

    if let Some(status) = raw.get("status")
        && !status.as_str().is_some_and(|s| STATUSES.contains(&s))
    {
        out.push(t.t("issueStatus", &[("value", &js_string(status))]));
    }
    if let Some(scope) = raw.get("scope")
        && !scope.as_str().is_some_and(|s| SCOPES.contains(&s))
    {
        out.push(t.t("issueScope", &[("value", &js_string(scope))]));
    }

    if raw.get("generated").is_some_and(|g| !is_stamp(g)) {
        out.push(t.t("issueGeneratedShape", &[]));
    }
    if let Some(verified) = raw.get("verified") {
        let ok = match verified {
            Yaml::Seq(stamps) => !stamps.is_empty() && stamps.iter().all(is_stamp),
            single => is_stamp(single),
        };
        if !ok {
            out.push(t.t("issueVerifiedShape", &[]));
        }
    }

    if let Some(stale_after) = raw.get("stale_after")
        && !stale_after
            .as_str()
            .is_some_and(|s| parse_offset_datetime(s).is_some())
    {
        out.push(t.t("issueStaleAfter", &[("value", &js_string(stale_after))]));
    }

    if let Some(sources) = raw.get("sources") {
        match sources {
            Yaml::Seq(list) => {
                for (i, entry) in list.iter().enumerate() {
                    let named = matches!(entry, Yaml::Map(_))
                        && entry
                            .get("resource")
                            .and_then(Yaml::as_str)
                            .is_some_and(|r| !js::trim(r).is_empty());
                    if !named {
                        out.push(t.t("issueSourceResource", &[("n", &(i + 1).to_string())]));
                    }
                }
            }
            _ => out.push(t.t("issueSourcesList", &[])),
        }
    }

    if doc.meta.legacy
        && let Some(updated) = raw.get("updated")
        && !updated.as_str().is_some_and(is_real_date)
    {
        out.push(t.t("issueUpdated", &[("value", &js_string(updated))]));
    }
    out
}

/// The existing file a `sources[].resource` names, or none for a URL, a missing file or anything else.
fn source_file(dir: &str, resource: &str) -> Option<String> {
    if has_url_scheme(resource) {
        return None;
    }
    let rest = expand_home(resource, &node::homedir());
    // a leading slash is bundle-relative (OKF); an absolute path is the fallback
    let candidates = if rest.starts_with('/') {
        vec![node::join(dir, &rest), rest]
    } else {
        vec![node::resolve(dir, &rest)]
    };
    candidates.into_iter().find(|c| Path::new(c).is_file())
}

/// The UTC date of a modification time in milliseconds.
fn utc_date(ms: i64) -> String {
    date::iso(ms)[..10].to_owned()
}

/// Lints the folder `dir`; `now_ms` is the clock `stale_after` is held against.
pub fn lint(dir: &str, t: &Texts, now_ms: i64) -> Result<LintResult, String> {
    let mut issues = Vec::new();
    let mut docs: Vec<(String, Document)> = Vec::new();
    let files = list_files(dir)?;
    // The slot of a stem in `docs`, which keeps the order the documents were first seen in.
    let mut slot_of: HashMap<String, usize> = HashMap::new();
    let mut declared_by: HashMap<String, String> = HashMap::new();

    for file in &files {
        let text = match fs::read(file) {
            Ok(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
            Err(e) => {
                issues.push(Issue {
                    file: file.clone(),
                    message: t.t(
                        "issueFrontmatter",
                        &[("detail", &node::io_message(&e, "open", Some(file)))],
                    ),
                });
                continue;
            }
        };
        let parsed = match doc::parse_doc(file, &text) {
            Ok(parsed) => parsed,
            Err(e) => {
                issues.push(Issue {
                    file: file.clone(),
                    message: t.t("issueFrontmatter", &[("detail", &e.message)]),
                });
                continue;
            }
        };
        let stem = stem_of(file);
        if !is_slug(&stem) {
            issues.push(Issue {
                file: file.clone(),
                message: t.t("issueStemSlug", &[("stem", &stem)]),
            });
        }
        if let Some(declared) = &parsed.declared_id {
            if *declared != stem {
                issues.push(Issue {
                    file: file.clone(),
                    message: t.t("issueStem", &[("id", declared), ("stem", &stem)]),
                });
            }
            match declared_by.get(declared) {
                None => {
                    declared_by.insert(declared.clone(), file.clone());
                }
                Some(owner) => issues.push(Issue {
                    file: file.clone(),
                    message: t.t(
                        "issueDuplicateId",
                        &[("id", declared), ("other", node::basename(owner))],
                    ),
                }),
            }
        }
        if parsed.meta.legacy {
            issues.push(Issue {
                file: file.clone(),
                message: t.t("issueLegacy", &[]),
            });
        }
        for message in profile_problems(&parsed, t) {
            issues.push(Issue {
                file: file.clone(),
                message,
            });
        }
        match slot_of.get(&stem) {
            Some(&slot) => docs[slot].1 = parsed,
            None => {
                slot_of.insert(stem.clone(), docs.len());
                docs.push((stem, parsed));
            }
        }
    }

    // The git check only makes sense where there is history to compare against: a folder that is not a repo, or a document not committed yet, is not stale.
    let git = inside_git_repo(dir);
    for (_, doc) in &docs {
        let generated_on = doc.meta.generated.as_ref().and_then(|g| utc_date_of(&g.at));
        if git
            && let Some(updated) = &generated_on
            && let Some(commit) = last_commit_date(&doc.path)
            && utf16_less(updated, &commit)
        {
            issues.push(Issue {
                file: doc.path.clone(),
                message: t.t("issueStale", &[("updated", updated), ("commit", &commit)]),
            });
        }

        if let Some(value) = &doc.meta.stale_after
            && is_stale(Some(value), now_ms)
        {
            issues.push(Issue {
                file: doc.path.clone(),
                message: t.t("issueExpired", &[("value", value)]),
            });
        }

        if let Some(updated) = &generated_on {
            for source in &doc.meta.sources {
                let Some(file) = source_file(dir, &source.resource) else {
                    continue; // a URL, or not on this machine: nothing to compare
                };
                let Ok(meta) = fs::metadata(&file) else {
                    continue;
                };
                let changed = utc_date(node::mtime_ms_floor(&meta));
                if utf16_less(updated, &changed) {
                    issues.push(Issue {
                        file: doc.path.clone(),
                        message: t.t(
                            "issueGenerated",
                            &[
                                ("source", &source.resource),
                                ("changed", &changed),
                                ("updated", updated),
                            ],
                        ),
                    });
                }
            }
        }

        for link in document_links(&doc.body) {
            let reserved = format!("{}.md", link.id);
            if RESERVED_FILES.contains(&reserved.as_str())
                && Path::new(&node::join(dir, &reserved)).exists()
            {
                continue;
            }
            let dead = match slot_of.get(&link.id).map(|&slot| &docs[slot].1) {
                None => true,
                Some(target) => link.fragment.as_deref().is_some_and(|fragment| {
                    !target.chunks.iter().any(|c| {
                        if link.wiki {
                            js::lower(&c.heading) == js::lower(fragment)
                        } else {
                            fragment_matches(fragment, &c.heading)
                        }
                    })
                }),
            };
            if dead {
                issues.push(Issue {
                    file: doc.path.clone(),
                    message: t.t("issueDeadLink", &[("link", &link.raw)]),
                });
            }
        }
    }

    // The same documents `toc` would list: the ones the loader accepts.
    let listed: Vec<&Document> = docs
        .iter()
        .map(|(_, d)| d)
        .filter(|d| is_slug(&d.meta.id))
        .collect();
    let state = index_state(dir, &listed);
    if state != IndexState::Current {
        issues.push(Issue {
            file: node::join(dir, INDEX_FILE),
            message: t.t(
                if state == IndexState::Missing {
                    "issueIndexMissing"
                } else {
                    "issueIndexOutdated"
                },
                &[],
            ),
        });
    }

    Ok(LintResult {
        checked: files.len(),
        issues,
    })
}

/// `a < b` on strings, by UTF-16 code unit as JavaScript compares them.
fn utf16_less(a: &str, b: &str) -> bool {
    a.encode_utf16().lt(b.encode_utf16())
}
