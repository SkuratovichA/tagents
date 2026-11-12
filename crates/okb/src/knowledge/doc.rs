//! A knowledge document as `packages/knowledge/src/doc.ts` reads it: the front matter split off, its fields read tolerantly, the body cut into sections at `## ` headings outside code fences, and a folder listed. `tests/knowledge_doc.rs` pins each rule to the node output.

use std::{fs, path::Path};

use sha2::{Digest, Sha256};
use unicode_normalization::UnicodeNormalization;

use super::front_matter::{self, Yaml};
use tagents_core::{js, node};

pub const STATUSES: [&str; 3] = ["draft", "stable", "deprecated"];
pub const SCOPES: [&str; 2] = ["global", "project"];
pub const RESERVED_FILES: [&str; 2] = ["index.md", "log.md"];

/// The top-level keys the profile knows; `lint` reports the rest.
pub const OKF_KEYS: [&str; 12] = [
    "type",
    "title",
    "description",
    "tags",
    "resource",
    "generated",
    "verified",
    "sources",
    "status",
    "stale_after",
    "scope",
    "id",
];
/// The extra keys a legacy document may carry.
pub const LEGACY_KEYS: [&str; 3] = ["kind", "updated", "generated_from"];

/// Who generated a document and when (an offset datetime).
#[derive(Debug, Clone, PartialEq)]
pub struct Generated {
    pub by: String,
    pub at: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Source {
    pub resource: String,
    pub id: Option<String>,
    pub title: Option<String>,
}

/// The tolerant view of a document's front matter.
#[derive(Debug, Clone, PartialEq)]
pub struct Meta {
    /// The file name without `.md`.
    pub id: String,
    pub type_: String,
    pub title: String,
    pub description: Option<String>,
    pub tags: Vec<String>,
    pub resource: Option<String>,
    pub generated: Option<Generated>,
    pub sources: Vec<Source>,
    pub status: &'static str,
    pub stale_after: Option<String>,
    pub scope: Option<&'static str>,
    /// Written in the legacy form (`kind`, `updated`).
    pub legacy: bool,
}

/// One `## ` section; the prose before the first heading is the section with the heading ``.
#[derive(Debug, Clone, PartialEq)]
pub struct Chunk {
    pub heading: String,
    pub ord: usize,
    pub body: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Document {
    pub meta: Meta,
    /// The front matter mapping as parsed, what `lint` holds to the profile.
    pub raw: Yaml,
    /// The front matter `id` key when it is a string.
    pub declared_id: Option<String>,
    pub path: String,
    /// Everything after the front matter, verbatim.
    pub body: String,
    pub chunks: Vec<Chunk>,
    /// The whole file.
    pub text: String,
    pub hash: String,
}

/// A problem with one file, as the loader and the index report it.
#[derive(Debug, Clone, PartialEq)]
pub struct DocError {
    pub file: String,
    pub message: String,
}

impl DocError {
    fn new(file: &str, message: impl Into<String>) -> DocError {
        DocError {
            file: file.to_owned(),
            message: message.into(),
        }
    }
}

/// The first 32 hex digits of the SHA-256 of the text, which is what the index stores to tell an edit from a touch.
pub fn hash_of(text: &str) -> String {
    let digest = Sha256::digest(text.as_bytes());
    digest.iter().take(16).map(|b| format!("{b:02x}")).collect()
}

/// Whitespace flattened to single spaces: one line of text (`oneLine`).
pub fn one_line(s: &str) -> String {
    js::trim(&js::collapse_space(s)).to_owned()
}

// ---- dates ------------------------------------------------------------------------------------

fn digits(s: &str) -> Option<i64> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}

/// `YYYY-MM-DD` naming a day that exists.
pub fn is_real_date(s: &str) -> bool {
    date_parts(s).is_some()
}

fn date_parts(s: &str) -> Option<(i64, i64, i64)> {
    let b = s.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return None;
    }
    let (year, month, day) = (digits(&s[0..4])?, digits(&s[5..7])?, digits(&s[8..10])?);
    ((1..=12).contains(&month) && day >= 1 && day <= tagents_core::date::days_in_month(year, month))
        .then_some((year, month, day))
}

/// A datetime with an explicit offset (`2026-10-31T10:00:00+02:00`, `Z`, seconds optional, a fraction kept to the millisecond) as milliseconds since the epoch, or `None`.
pub fn parse_offset_datetime(value: &str) -> Option<i64> {
    let (date, rest) = value.split_once('T')?;
    let (year, month, day) = date_parts(date)?;
    let (clock, offset_ms) = match rest.strip_suffix('Z') {
        Some(clock) => (clock, 0),
        None => {
            let at = rest.len().checked_sub(6)?;
            let (clock, zone) = (rest.get(..at)?, rest.get(at..)?);
            let sign = match zone.as_bytes()[0] {
                b'+' => 1,
                b'-' => -1,
                _ => return None,
            };
            if zone.as_bytes()[3] != b':' {
                return None;
            }
            let (hours, minutes) = (digits(&zone[1..3])?, digits(&zone[4..6])?);
            if hours >= 24 || minutes >= 60 {
                return None;
            }
            (clock, sign * (hours * 60 + minutes) * 60_000)
        }
    };
    let (hm, tail) = match clock.get(5..) {
        Some(tail) if !tail.is_empty() => (clock.get(..5)?, Some(tail)),
        _ => (clock, None),
    };
    if hm.len() != 5 || hm.as_bytes()[2] != b':' {
        return None;
    }
    let (hour, minute) = (digits(&hm[0..2])?, digits(&hm[3..5])?);
    let (second, fraction_ms) = match tail {
        None => (0, 0),
        Some(tail) => {
            let tail = tail.strip_prefix(':')?;
            let (sec, fraction) = match tail.split_once('.') {
                Some((sec, fraction)) => (sec, Some(fraction)),
                None => (tail, None),
            };
            if sec.len() != 2 {
                return None;
            }
            let ms = match fraction {
                None => 0,
                Some(f) => {
                    digits(f)?;
                    let first3: String = f
                        .chars()
                        .take(3)
                        .chain(std::iter::repeat('0'))
                        .take(3)
                        .collect();
                    digits(&first3)?
                }
            };
            (digits(sec)?, ms)
        }
    };
    if hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    let day_ms =
        tagents_core::date::days_from_civil(year, month, day) * tagents_core::date::MS_PER_DAY;
    Some(day_ms + hour * 3_600_000 + minute * 60_000 + second * 1000 + fraction_ms - offset_ms)
}

/// The UTC day (`YYYY-MM-DD`) of an offset datetime.
pub fn utc_date_of(at: &str) -> Option<String> {
    parse_offset_datetime(at).map(|ms| tagents_core::date::iso(ms)[..10].to_owned())
}

/// A document past its `stale_after`: false for none, or one that is not an offset datetime.
pub fn is_stale(stale_after: Option<&str>, now_ms: i64) -> bool {
    stale_after
        .and_then(parse_offset_datetime)
        .is_some_and(|limit| now_ms >= limit)
}

// ---- splitting and sections -------------------------------------------------------------------

/// The front matter block and the rest, neither validated: `None` unless the text (after a byte-order mark) opens with `---` and a line starting `---` closes it.
pub fn split_frontmatter(text: &str) -> Option<(String, String)> {
    let normalized = text.strip_prefix('\u{FEFF}').unwrap_or(text);
    if !normalized.starts_with("---") {
        return None;
    }
    let end = 3 + normalized.get(3..)?.find("\n---")?;
    let first_line_end = normalized.find('\n')?;
    // The `\r` of a CRLF break that ends the last line goes with its `\n`: node cuts it, and a YAML reader takes a lone `\r` for part of the last value.
    let stop = if normalized[..end].ends_with('\r') {
        end - 1
    } else {
        end
    };
    let yaml = if first_line_end + 1 >= stop {
        ""
    } else {
        &normalized[first_line_end + 1..stop]
    };
    let body = match normalized[end + 1..].find('\n') {
        Some(at) => &normalized[end + 1 + at + 1..],
        None => "",
    };
    Some((yaml.to_owned(), body.to_owned()))
}

/// The line is `^\s*(```|~~~)`: the marker it opens or closes a code fence with.
fn fence_marker(line: &str) -> Option<&'static str> {
    let rest = line.trim_start_matches(js::is_space);
    if rest.starts_with("```") {
        Some("```")
    } else if rest.starts_with("~~~") {
        Some("~~~")
    } else {
        None
    }
}

/// The characters `.` does not match in a regular expression without the `s` flag.
fn is_line_terminator(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{2028}' | '\u{2029}')
}

/// `/^##\s+(.+?)\s*$/` on one line: the heading text, following the backtracking order of the regular expression (`\s+` takes as many characters as it can and gives them back one at a time, `.+?` takes as few as it can).
fn heading_of(line: &str) -> Option<String> {
    let chars: Vec<char> = line.strip_prefix("##")?.chars().collect();
    let n = chars.len();
    // `all_space_from[i]`: every character from `i` on is whitespace, which `\s*$` needs.
    let mut all_space_from = vec![true; n + 1];
    for i in (0..n).rev() {
        all_space_from[i] = all_space_from[i + 1] && js::is_space(chars[i]);
    }
    let spaces = chars.iter().take_while(|c| js::is_space(**c)).count();
    for k in (1..=spaces).rev() {
        for end in k + 1..=n {
            if is_line_terminator(chars[end - 1]) {
                break;
            }
            if all_space_from[end] {
                return Some(chars[k..end].iter().collect());
            }
        }
    }
    None
}

/// The body cut at `## ` headings, code fences ignored: a shell comment that starts with `##` inside a fence is not a boundary.
pub fn chunk(body: &str) -> Vec<Chunk> {
    let mut chunks: Vec<Chunk> = Vec::new();
    let mut heading = String::new();
    let mut lines: Vec<&str> = Vec::new();
    let flush = |chunks: &mut Vec<Chunk>, heading: &str, lines: &mut Vec<&str>| {
        let text = js::trim(&lines.join("\n")).to_owned();
        lines.clear();
        // A document that opens with a heading has no preamble.
        if heading.is_empty() && text.is_empty() {
            return;
        }
        chunks.push(Chunk {
            heading: heading.to_owned(),
            ord: chunks.len(),
            body: text,
        });
    };
    let mut fence: Option<&str> = None;
    for line in body.split('\n') {
        let in_fence = match fence_marker(line) {
            Some(marker) => {
                match fence {
                    None => fence = Some(marker),
                    Some(open) if open == marker => fence = None,
                    Some(_) => {}
                }
                true
            }
            None => fence.is_some(),
        };
        if !in_fence && let Some(found) = heading_of(line) {
            flush(&mut chunks, &heading, &mut lines);
            heading = found;
            continue;
        }
        lines.push(line);
    }
    flush(&mut chunks, &heading, &mut lines);
    chunks
}

// ---- fields -----------------------------------------------------------------------------------

/// A string with something in it besides whitespace, kept as written.
fn non_empty(v: Option<&Yaml>) -> Option<String> {
    v.and_then(Yaml::as_str)
        .filter(|s| !js::trim(s).is_empty())
        .map(str::to_owned)
}

fn capitalise(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(first) if first.len_utf16() == 1 => first.to_uppercase().chain(chars).collect(),
        _ => s.to_owned(),
    }
}

fn generated_of(v: Option<&Yaml>) -> Option<Generated> {
    let v = v.filter(|v| matches!(v, Yaml::Map(_)))?;
    let by = non_empty(v.get("by"))?;
    let at = v.get("at")?.as_str()?;
    parse_offset_datetime(at).map(|_| Generated {
        by,
        at: at.to_owned(),
    })
}

fn sources_of(v: Option<&Yaml>) -> Vec<Source> {
    let Some(Yaml::Seq(entries)) = v else {
        return Vec::new();
    };
    entries
        .iter()
        .filter(|entry| matches!(entry, Yaml::Map(_)))
        .filter_map(|entry| {
            Some(Source {
                resource: non_empty(entry.get("resource"))?,
                id: non_empty(entry.get("id")),
                title: non_empty(entry.get("title")),
            })
        })
        .collect()
}

fn strings_of(v: Option<&Yaml>) -> Vec<String> {
    match v {
        Some(Yaml::Seq(items)) => items
            .iter()
            .filter_map(|t| t.as_str().map(str::to_owned))
            .collect(),
        _ => Vec::new(),
    }
}

/// The last path segment without a trailing `.md`: the id a file's name promises.
pub fn stem_of(file: &str) -> String {
    let base = node::basename(file);
    base.strip_suffix(".md").unwrap_or(base).to_owned()
}

pub fn is_slug(stem: &str) -> bool {
    !stem.is_empty()
        && stem.split('-').all(|word| {
            !word.is_empty()
                && word
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        })
}

/// Parse one document: the file decides the id (its stem), the text decides the rest. A stem that is not a slug is not refused here; `read_doc` does that.
pub fn parse_doc(file: &str, text: &str) -> Result<Document, DocError> {
    let Some((yaml, body)) = split_frontmatter(text) else {
        return Err(DocError::new(
            file,
            "no YAML frontmatter: the file must open with a --- block",
        ));
    };
    let parsed = front_matter::parse(&yaml)
        .map_err(|e| DocError::new(file, format!("frontmatter is not YAML: {e}")))?;
    let raw = match &parsed {
        Yaml::Null => Yaml::Map(Vec::new()),
        Yaml::Map(_) => parsed,
        _ => {
            return Err(DocError::new(
                file,
                "frontmatter: (root): expected a mapping of keys to values",
            ));
        }
    };

    let legacy = raw.get("type").is_none() && raw.get("kind").is_some();
    let type_key = if legacy { "kind" } else { "type" };
    if raw.get(type_key).is_none() {
        return Err(DocError::new(
            file,
            "frontmatter: type: required — a document needs a `type` (legacy: `kind`)",
        ));
    }
    let Some(written) = non_empty(raw.get(type_key)) else {
        return Err(DocError::new(
            file,
            format!("frontmatter: {type_key}: must be a non-empty string"),
        ));
    };

    let id = stem_of(file);
    let updated = raw
        .get("updated")
        .and_then(Yaml::as_str)
        .filter(|s| is_real_date(s))
        .map(str::to_owned);
    let generated_from = non_empty(raw.get("generated_from"));
    let status = STATUSES
        .iter()
        .copied()
        .find(|s| raw.get("status").and_then(Yaml::as_str) == Some(s))
        .unwrap_or("stable");
    let scope = SCOPES
        .iter()
        .copied()
        .find(|s| raw.get("scope").and_then(Yaml::as_str) == Some(s));
    let stale_after = raw
        .get("stale_after")
        .and_then(Yaml::as_str)
        .filter(|s| parse_offset_datetime(s).is_some())
        .map(str::to_owned);
    let meta = Meta {
        title: non_empty(raw.get("title")).unwrap_or_else(|| id.clone()),
        type_: if legacy {
            capitalise(&written)
        } else {
            written
        },
        description: non_empty(raw.get("description")).map(|d| js::trim(&d).to_owned()),
        tags: strings_of(raw.get("tags")),
        resource: non_empty(raw.get("resource")),
        generated: if legacy {
            updated.map(|u| Generated {
                by: "legacy".to_owned(),
                at: format!("{u}T00:00:00Z"),
            })
        } else {
            generated_of(raw.get("generated"))
        },
        sources: if legacy {
            generated_from
                .map(|resource| Source {
                    resource,
                    id: None,
                    title: None,
                })
                .into_iter()
                .collect()
        } else {
            sources_of(raw.get("sources"))
        },
        status,
        stale_after,
        scope,
        legacy,
        id,
    };
    Ok(Document {
        declared_id: raw.get("id").and_then(Yaml::as_str).map(str::to_owned),
        path: file.to_owned(),
        chunks: chunk(&body),
        hash: hash_of(text),
        text: text.to_owned(),
        body,
        meta,
        raw,
    })
}

/// Read one document and hold it to the slug rule. The bytes are decoded as node decodes UTF-8: a byte-order mark kept, an invalid byte as U+FFFD.
pub fn read_doc(file: &str) -> Result<Document, DocError> {
    let stem = stem_of(file);
    if !is_slug(&stem) {
        return Err(DocError::new(
            file,
            format!(
                "filename stem \"{stem}\" must be a slug: lowercase words joined by single dashes"
            ),
        ));
    }
    let bytes = fs::read(file)
        .map_err(|e| DocError::new(file, node::io_message(&e, "open", Some(file))))?;
    parse_doc(file, &String::from_utf8_lossy(&bytes))
}

/// Every document file of a folder sorted by path (UTF-16 order, as `Array.prototype.sort` does): `.md` files that are not dotfiles, `index.md` or `log.md`, and not directories or symbolic links.
pub fn list_files(dir: &str) -> Result<Vec<String>, String> {
    let cannot = || format!("knowledge directory {dir} cannot be read");
    let mut files: Vec<String> = Vec::new();
    for entry in fs::read_dir(Path::new(dir)).map_err(|_| cannot())? {
        let entry = entry.map_err(|_| cannot())?;
        let name = entry.file_name().to_string_lossy().into_owned();
        let is_file = entry.file_type().is_ok_and(|t| t.is_file());
        if is_file
            && name.ends_with(".md")
            && !name.starts_with('.')
            && !RESERVED_FILES.contains(&name.as_str())
        {
            files.push(node::join(dir, &name));
        }
    }
    files.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
    Ok(files)
}

// ---- links ------------------------------------------------------------------------------------

/// A link from one document to another or to one of its sections, in either form.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DocLink {
    /// True for `[[id]]`, false for `[text](id.md)`.
    pub wiki: bool,
    /// The link as written, for messages.
    pub raw: String,
    pub id: String,
    /// The heading (wikilink) or fragment (markdown link) as written.
    pub fragment: Option<String>,
}

/// `/^[a-z][a-z0-9+.-]*:/i`: a target with a URL scheme.
pub fn has_url_scheme(target: &str) -> bool {
    let mut chars = target.chars();
    if !chars.next().is_some_and(|c| c.is_ascii_alphabetic()) {
        return false;
    }
    for c in chars {
        if c == ':' {
            return true;
        }
        if !(c.is_ascii_alphanumeric() || matches!(c, '+' | '.' | '-')) {
            return false;
        }
    }
    false
}

/// Each line of a body with whether it sits in, opens or closes a fenced code block.
fn scan_fences(body: &str) -> Vec<(&str, bool)> {
    let mut fence: Option<&'static str> = None;
    body.split('\n')
        .map(|line| match fence_marker(line) {
            Some(marker) => {
                match fence {
                    None => fence = Some(marker),
                    Some(open) if open == marker => fence = None,
                    Some(_) => {}
                }
                (line, true)
            }
            None => (line, fence.is_some()),
        })
        .collect()
}

/// A line with its inline code spans blanked out, one space per UTF-16 unit: a link inside backticks is not a link. The pattern is `(`+)[^`]*?\1`, so a run of backticks gives back its length until a closing run of the same length is found.
fn without_code_spans(line: &str) -> String {
    let chars: Vec<char> = line.chars().collect();
    let mut out = String::with_capacity(line.len());
    let mut i = 0;
    while i < chars.len() {
        let end = if chars[i] == '`' {
            code_span_end(&chars, i)
        } else {
            None
        };
        match end {
            Some(end) => {
                let units: usize = chars[i..end].iter().map(|c| c.len_utf16()).sum();
                out.extend(std::iter::repeat_n(' ', units));
                i = end;
            }
            None => {
                out.push(chars[i]);
                i += 1;
            }
        }
    }
    out
}

fn code_span_end(chars: &[char], start: usize) -> Option<usize> {
    let run = chars[start..].iter().take_while(|c| **c == '`').count();
    for n in (1..=run).rev() {
        let mut pos = start + n;
        loop {
            let closes = chars.len() >= pos + n && chars[pos..pos + n].iter().all(|c| *c == '`');
            if closes {
                return Some(pos + n);
            }
            match chars.get(pos) {
                Some(c) if *c != '`' => pos += 1,
                _ => break,
            }
        }
    }
    None
}

/// `\[\[([^\]|#]+)(?:#([^\]|]+))?\]\]` at `at`: the match end, the id and the heading.
fn wikilink_at(chars: &[char], at: usize) -> Option<(usize, String, Option<String>)> {
    if chars.get(at) != Some(&'[') || chars.get(at + 1) != Some(&'[') {
        return None;
    }
    let id_start = at + 2;
    let mut i = id_start;
    while i < chars.len() && !matches!(chars[i], ']' | '|' | '#') {
        i += 1;
    }
    if i == id_start {
        return None;
    }
    let id: String = chars[id_start..i].iter().collect();
    let mut heading = None;
    if chars.get(i) == Some(&'#') {
        let head_start = i + 1;
        let mut j = head_start;
        while j < chars.len() && !matches!(chars[j], ']' | '|') {
            j += 1;
        }
        if j == head_start {
            return None;
        }
        heading = Some(chars[head_start..j].iter().collect::<String>());
        i = j;
    }
    (chars.get(i) == Some(&']') && chars.get(i + 1) == Some(&']')).then_some((i + 2, id, heading))
}

/// `(?<!!)\[(?:\\.|[^\]\\])*\]\(([^)\s]+)(?:\s+"[^"]*")?\)` at `at`: the match end and the target.
fn markdown_link_at(chars: &[char], at: usize) -> Option<(usize, String)> {
    if chars.get(at) != Some(&'[') || (at > 0 && chars[at - 1] == '!') {
        return None;
    }
    let mut i = at + 1;
    loop {
        match chars.get(i)? {
            '\\' => {
                // `.` takes any one character but a line terminator
                let next = chars.get(i + 1)?;
                if matches!(next, '\n' | '\r' | '\u{2028}' | '\u{2029}') {
                    return None;
                }
                i += 2;
            }
            ']' => break,
            _ => i += 1,
        }
    }
    if chars.get(i + 1) != Some(&'(') {
        return None;
    }
    let target_start = i + 2;
    let mut j = target_start;
    while j < chars.len() && chars[j] != ')' && !js::is_space(chars[j]) {
        j += 1;
    }
    if j == target_start {
        return None;
    }
    let target: String = chars[target_start..j].iter().collect();
    if chars.get(j) == Some(&')') {
        return Some((j + 1, target));
    }
    let mut k = j;
    while k < chars.len() && js::is_space(chars[k]) {
        k += 1;
    }
    if k == j || chars.get(k) != Some(&'"') {
        return None;
    }
    k += 1;
    while k < chars.len() && chars[k] != '"' {
        k += 1;
    }
    (chars.get(k) == Some(&'"') && chars.get(k + 1) == Some(&')')).then_some((k + 2, target))
}

/// A markdown target that names a document: the id and the fragment, none for a URL, a file that is not `.md` or an empty id.
fn markdown_target(target: &str) -> Option<(String, Option<String>)> {
    if has_url_scheme(target) {
        return None;
    }
    let (file, fragment) = match target.find('#') {
        Some(hash) => (&target[..hash], Some(&target[hash + 1..])),
        None => (target, None),
    };
    let id = file.strip_suffix(".md")?;
    let id = id
        .strip_prefix("./")
        .or_else(|| id.strip_prefix('/'))
        .unwrap_or(id);
    if id.is_empty() {
        return None;
    }
    Some((
        id.to_owned(),
        fragment.filter(|f| !f.is_empty()).map(str::to_owned),
    ))
}

/// Every link to a document of the bundle in a body, in document order: `[[id]]`, `[[id#Heading]]` and `[t](/id.md#frag)`, `[t](./id.md)`, `[t](id.md)`. Links in fenced code or inline code spans are not links.
pub fn document_links(body: &str) -> Vec<DocLink> {
    let mut out = Vec::new();
    for (line, in_fence) in scan_fences(body) {
        if in_fence {
            continue;
        }
        let text = without_code_spans(line);
        let chars: Vec<char> = text.chars().collect();
        let mut found: Vec<(usize, DocLink)> = Vec::new();
        let mut i = 0;
        while i < chars.len() {
            if let Some((end, id, heading)) = wikilink_at(&chars, i) {
                let id = js::trim(&id).to_owned();
                if !id.is_empty() {
                    found.push((
                        i,
                        DocLink {
                            wiki: true,
                            raw: chars[i..end].iter().collect(),
                            id,
                            fragment: heading.map(|h| js::trim(&h).to_owned()),
                        },
                    ));
                }
                i = end;
            } else {
                i += 1;
            }
        }
        let mut i = 0;
        while i < chars.len() {
            if let Some((end, target)) = markdown_link_at(&chars, i) {
                if let Some((id, fragment)) = markdown_target(&target) {
                    found.push((
                        i,
                        DocLink {
                            wiki: false,
                            raw: chars[i..end].iter().collect(),
                            id,
                            fragment,
                        },
                    ));
                }
                i = end;
            } else {
                i += 1;
            }
        }
        found.sort_by_key(|(at, _)| *at);
        out.extend(found.into_iter().map(|(_, link)| link));
    }
    out
}

/// The anchor of a heading as GitHub makes it, as `headingSlug` writes it: NFC, trimmed, lowercase, everything but letters, marks, digits, white space and dashes dropped, white space to dashes.
fn heading_slug(heading: &str) -> String {
    js::lower(js::trim(&nfc(heading)))
        .chars()
        .filter(|c| is_letter_mark_or_number(*c) || js::is_space(*c) || *c == '-')
        .map(|c| if js::is_space(c) { '-' } else { c })
        .collect()
}

fn nfc(text: &str) -> String {
    text.nfc().collect()
}

/// `\p{L}`, `\p{M}` and `\p{N}` of a regular expression with the `u` flag: the general categories whose first letter is L, M or N.
fn is_letter_mark_or_number(c: char) -> bool {
    use unicode_general_category::{get_general_category, GeneralCategory as G};
    matches!(
        get_general_category(c),
        G::UppercaseLetter
            | G::LowercaseLetter
            | G::TitlecaseLetter
            | G::ModifierLetter
            | G::OtherLetter
            | G::NonspacingMark
            | G::SpacingMark
            | G::EnclosingMark
            | G::DecimalNumber
            | G::LetterNumber
            | G::OtherNumber
    )
}

/// A markdown-link fragment names a heading when it equals the text (NFC, case-insensitive, URL-decoded) or its slug.
pub fn fragment_matches(fragment: &str, heading: &str) -> bool {
    let want = js::lower(js::trim(&nfc(&percent_decoded(fragment))));
    js::lower(js::trim(&nfc(heading))) == want || heading_slug(heading) == want
}

/// `decodeURIComponent`, or the text as written when an escape is malformed.
fn percent_decoded(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'%' {
            out.push(bytes[i]);
            i += 1;
            continue;
        }
        let hex = bytes
            .get(i + 1..i + 3)
            .filter(|h| h.iter().all(u8::is_ascii_hexdigit))
            .and_then(|h| std::str::from_utf8(h).ok())
            .and_then(|h| u8::from_str_radix(h, 16).ok());
        match hex {
            Some(byte) => {
                out.push(byte);
                i += 3;
            }
            None => return text.to_owned(),
        }
    }
    String::from_utf8(out).unwrap_or_else(|_| text.to_owned())
}

/// Every document of a folder, a file that cannot be read or parsed reported beside them and not thrown. Ids are stems, so they cannot collide.
pub fn load_dir(dir: &str) -> Result<(Vec<Document>, Vec<DocError>), String> {
    let mut docs = Vec::new();
    let mut errors = Vec::new();
    for file in list_files(dir)? {
        match read_doc(&file) {
            Ok(doc) => docs.push(doc),
            Err(error) => errors.push(error),
        }
    }
    Ok((docs, errors))
}
