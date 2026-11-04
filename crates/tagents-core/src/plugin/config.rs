//! Adding and removing `plugins` entries in the config file: the twin of `addPluginEntry` and `removePluginEntry` in `packages/core/src/plugin-config.ts`.
//!
//! The file is the owner's, with comments and spacing of their own, so the edit is a splice of text and the parser only answers questions. `add` appends `[plugins.KEY]` behind one blank line; `remove` cuts the section and its subsections out by their header lines. Both parse the result before writing and refuse it unless it holds what was meant.
//!
//! An edit that cannot be made fails with the line node throws: the TOML parser's message after the file name (the parser's words are the Rust parser's), the fixed texts of `plugin-config.ts`, or the system's text for a read, a stat, a make-directory, a write or a rename that failed. A failure is a `Fault` made before anything is written. The vectors in `tests/fixtures/plugin-vectors.json` hold every document of the corpus with the text node left, or with the failure where node threw.

use std::{fs, io, path::Path};

use toml::de::{DeTable, DeValue};

use crate::{
    js, json, node,
    toml_js::{self, get},
};

/// A failed edit, as the line node prints for it (exit 1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Fault(pub String);

/// The line for a system call that failed.
fn system(err: &io::Error, syscall: &str, path: &str) -> Fault {
    Fault(node::io_message(err, syscall, Some(path)))
}

/// What `add` did.
#[derive(Debug, PartialEq, Eq)]
pub enum Added {
    Written,
    /// The key was listed; nothing was written.
    Exists,
}

/// What `remove` did.
#[derive(Debug, PartialEq, Eq)]
pub enum Removed {
    Written,
    /// The key was not listed, or there was no config; nothing was written.
    Absent,
}

/// A character the dashboard's awk reader cannot take back out of a string (`UNWRITABLE` in `config-file.ts`): a control character. A lone surrogate, the other half of that rule, cannot be in a Rust string.
fn unwritable(c: char) -> bool {
    matches!(c, '\u{0}'..='\u{1f}' | '\u{7f}')
}

/// `value` as a TOML basic string that the dashboard reads back unchanged, or `None` when it cannot be written so (`tomlString`).
pub fn toml_string(value: &str) -> Option<String> {
    if value.chars().any(unwritable) {
        return None;
    }
    let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
    Some(format!("\"{escaped}\""))
}

/// A TOML key as written: bare when it can be (`[A-Za-z0-9_-]+`), the quoted string form when not, `None` when it cannot be written (`tomlKey`).
pub fn toml_key(name: &str) -> Option<String> {
    let bare = !name.is_empty()
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
    if bare {
        Some(name.to_owned())
    } else {
        toml_string(name)
    }
}

/// Add `key` under `plugins`.
pub fn add(file: &str, key: &str, from: &str) -> Result<Added, Fault> {
    let target = write_target(file)?;
    let text = read_text(file)?;
    let before = parse(file, &text, "")?;
    if plugins_of(file, &before, "")?.is_some_and(|plugins| get(plugins, key).is_some()) {
        return Ok(Added::Exists);
    }
    let section = section(file, key, from)?;
    let head = if text.is_empty() || text.ends_with('\n') {
        text.clone()
    } else {
        format!("{text}\n")
    };
    let blank = if head.is_empty() { "" } else { "\n" };
    let next = format!("{head}{blank}{section}");

    let after = parse(file, &next, EDIT)?;
    let took = plugins_of(file, &after, EDIT)?
        .and_then(|plugins| get(plugins, key))
        .is_some_and(|entry| from_of(entry) == Some(from));
    if !took {
        return Err(Fault(format!("{file}: the edit did not take")));
    }
    save(
        &target,
        &next,
        |p, t| fs::write(p, t),
        |a, b| fs::rename(a, b),
    )?;
    Ok(Added::Written)
}

/// Drop `key` from `plugins`.
pub fn remove(file: &str, key: &str) -> Result<Removed, Fault> {
    let target = write_target(file)?;
    let text = read_text(file)?;
    if text.is_empty() {
        return Ok(Removed::Absent);
    }
    let before = parse(file, &text, "")?;
    // Node's schema check drops the key `__proto__` from `plugins`, so node never sees it there.
    let listed = |plugins: Option<&DeTable<'_>>| {
        key != "__proto__" && plugins.is_some_and(|p| get(p, key).is_some())
    };
    let before_plugins = plugins_of(file, &before, "")?;
    if !listed(before_plugins) {
        return Ok(Removed::Absent);
    }

    let lines: Vec<&str> = text.split_inclusive('\n').collect();
    let next = cut_sections(&lines, key).concat();

    let after = parse(file, &next, EDIT)?;
    let after_plugins = plugins_of(file, &after, EDIT)?;
    if listed(after_plugins) {
        let shown = toml_key(key).unwrap_or_else(|| json::quote(key));
        return Err(Fault(format!(
            "{file}: {key} is not written as a [plugins.{shown}] section, so it cannot be removed here — remove it by hand"
        )));
    }
    let rest_is_the_same = same_table(Some(&before), Some(&after), Some("plugins"))
        && same_table(before_plugins, after_plugins, Some(key));
    if !rest_is_the_same {
        return Err(Fault(format!(
            "{file}: removing {key} would change something else, so nothing was written"
        )));
    }
    save(
        &target,
        &next,
        |p, t| fs::write(p, t),
        |a, b| fs::rename(a, b),
    )?;
    Ok(Removed::Written)
}

/// The text of the section an entry is written as (`tomlEntry`).
fn section(file: &str, key: &str, from: &str) -> Result<String, Fault> {
    let unwritable = |value: &str| {
        Fault(format!(
            "{file}: {} has a control character or a lone surrogate in it, which cannot be written in a config tagents reads",
            json::quote(value)
        ))
    };
    let written = toml_string(from).ok_or_else(|| unwritable(from))?;
    let key = toml_key(key).ok_or_else(|| unwritable(key))?;
    Ok(format!("[plugins.{key}]\nfrom = {written}\n"))
}

/// What `parseTomlFile` says before its message when the text is the edit.
const EDIT: &str = "the edit would not parse: ";

/// The document parsed the way node's parser reads it: a syntax error, and an integer beyond what a JavaScript number holds, are refused, with the file and the parser's message (`parseTomlFile`). The words of the message are the Rust parser's.
fn parse<'a>(file: &str, text: &'a str, what: &str) -> Result<DeTable<'a>, Fault> {
    let table = DeTable::parse(text)
        .map_err(|err| Fault(format!("{file}: {what}{}", err.message())))?
        .into_inner();
    if toml_js::table_holds_lossy_integer(&table) {
        return Err(Fault(format!(
            "{file}: {what}integer out of the range of a JavaScript number"
        )));
    }
    Ok(table)
}

/// The `plugins` table of a document: `None` when there is none, a refusal when it is not a table (`TomlDoc` in `plugin-config.ts`).
fn plugins_of<'a, 'i>(
    file: &str,
    doc: &'a DeTable<'i>,
    what: &str,
) -> Result<Option<&'a DeTable<'i>>, Fault> {
    match get(doc, "plugins") {
        None => Ok(None),
        Some(DeValue::Table(plugins)) => Ok(Some(plugins)),
        Some(_) => Err(Fault(format!(
            "{file}: {what}plugins must be a table of tables"
        ))),
    }
}

/// The `from` of an entry that is a table with a string in it (`fromOf`).
fn from_of<'a>(entry: &'a DeValue<'_>) -> Option<&'a str> {
    let DeValue::Table(table) = entry else {
        return None;
    };
    match get(table, "from") {
        Some(DeValue::String(from)) => Some(from.as_ref()),
        _ => None,
    }
}

/// The first two keys of the table a `[a.b]` or `[[a.b]]` header line names, from that line parsed alone; `None` for a line that is not a header (`headerPath`). Only the first two are ever asked for.
fn header_path(line: &str) -> Option<Vec<String>> {
    if !line.trim_start_matches(js::is_space).starts_with('[') {
        return None;
    }
    let parsed = DeTable::parse(line).ok()?.into_inner();
    let mut keys = Vec::new();
    let mut table = &parsed;
    while keys.len() < 2 {
        let mut entries = table.iter();
        let (Some((key, value)), None) = (entries.next(), entries.next()) else {
            break;
        };
        keys.push(key.get_ref().to_string());
        table = match value.get_ref() {
            DeValue::Table(inner) => inner,
            DeValue::Array(items) => match items.first().map(|item| item.get_ref()) {
                Some(DeValue::Table(inner)) => inner,
                _ => break,
            },
            _ => break,
        };
    }
    Some(keys)
}

fn blank(line: &str) -> bool {
    js::trim(line).is_empty()
}

fn comment_only(line: &str) -> bool {
    line.trim_start_matches(js::is_space).starts_with('#')
}

/// The lines left after cutting every section of `plugins.KEY`, its own `[plugins.KEY]` and any `[plugins.KEY.…]` under it. A section runs from its header to the next header, less the comment lines just above that header, which belong to it; comments above the removed header stay (`cutSections`).
fn cut_sections<'a>(lines: &[&'a str], key: &str) -> Vec<&'a str> {
    let mut cut = vec![false; lines.len()];
    let mut close = |start: usize, end: usize| {
        let mut stop = end;
        while stop > start && comment_only(lines[stop - 1]) {
            stop -= 1;
        }
        // At the end of the file the blank line `add` put before the section goes with it.
        let first = if end == lines.len() && start > 0 && blank(lines[start - 1]) {
            start - 1
        } else {
            start
        };
        cut[first..stop].fill(true);
    };
    let mut open: Option<usize> = None;
    for (i, line) in lines.iter().enumerate() {
        let Some(keys) = header_path(line) else {
            continue;
        };
        if let Some(start) = open {
            close(start, i);
        }
        let ours = keys.first().map(String::as_str) == Some("plugins")
            && keys.get(1).map(String::as_str) == Some(key);
        open = ours.then_some(i);
    }
    if let Some(start) = open {
        close(start, lines.len());
    }
    lines
        .iter()
        .zip(&cut)
        .filter(|(_, cut)| !**cut)
        .map(|(line, _)| *line)
        .collect()
}

/// A TOML number as the JavaScript number the node parser makes of it.
fn number(value: &DeValue<'_>) -> Option<f64> {
    match value {
        DeValue::Integer(int) => toml_js::integer(int),
        DeValue::Float(float) => Some(toml_js::float(float)),
        _ => None,
    }
}

/// `util.isDeepStrictEqual` of two parsed values: numbers are `Object.is`-equal (NaN equals NaN, 0 differs from -0, an integer and a float of one value are one number). A date is equal only to the same text, which is stricter than node, so a doubt hands the call over and never writes.
fn same(a: &DeValue<'_>, b: &DeValue<'_>) -> bool {
    match (a, b) {
        (DeValue::String(x), DeValue::String(y)) => x == y,
        (DeValue::Boolean(x), DeValue::Boolean(y)) => x == y,
        (DeValue::Datetime(x), DeValue::Datetime(y)) => x == y,
        (DeValue::Array(x), DeValue::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| same(p.get_ref(), q.get_ref()))
        }
        (DeValue::Table(x), DeValue::Table(y)) => same_table(Some(x), Some(y), None),
        _ => match (number(a), number(b)) {
            (Some(x), Some(y)) => (x.is_nan() && y.is_nan()) || x.to_bits() == y.to_bits(),
            _ => false,
        },
    }
}

/// Two tables hold the same keys with the same values, order aside, leaving out `skip` on both sides; no table is an empty one, as `plugins` is `{}` where it is missing.
fn same_table(a: Option<&DeTable<'_>>, b: Option<&DeTable<'_>>, skip: Option<&str>) -> bool {
    fn kept<'a, 'i>(
        table: Option<&'a DeTable<'i>>,
        skip: Option<&str>,
    ) -> Vec<(String, &'a DeValue<'i>)> {
        table
            .into_iter()
            .flat_map(|t| t.iter())
            .filter(|(name, _)| Some(name.get_ref().as_ref()) != skip)
            .map(|(name, value)| (name.get_ref().to_string(), value.get_ref()))
            .collect()
    }
    let (a, b) = (kept(a, skip), kept(b, skip));
    a.len() == b.len()
        && a.iter().all(|(name, x)| {
            b.iter()
                .find(|(other, _)| other == name)
                .is_some_and(|(_, y)| same(x, y))
        })
}

/// The file an edit of `file` replaces: `file` itself, or the file a symbolic link at that path ends in, so that a config kept in a dotfiles repository stays a link. A path with nothing at it is not a link. Any other failure, and a link that leads nowhere or in a loop, is the system's error (`writeTarget`).
fn write_target(file: &str) -> Result<String, Fault> {
    match fs::symlink_metadata(file) {
        Ok(meta) if meta.file_type().is_symlink() => {
            // `realpathSync` stats a link before it reads it.
            fs::metadata(file).map_err(|err| system(&err, "stat", file))?;
            node::realpath(file).map_err(|err| system(&err, "stat", file))
        }
        Ok(_) => Ok(file.to_owned()),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(file.to_owned()),
        Err(err) => Err(system(&err, "lstat", file)),
    }
}

/// The config's text, empty when there is no config yet. Every other failure to read it is the system's error: an edit of a config that could not be read would replace it. Bytes that are not UTF-8 are read as U+FFFD and written back so (`readText`).
fn read_text(file: &str) -> Result<String, Fault> {
    node::read_utf8(file)
        .map(Option::unwrap_or_default)
        .map_err(Fault)
}

/// Replace `target` with `text`: the directory made if it is not there, the text written to `<target>.<pid>.tmp` and renamed over it (`save` and `writeAtomic`). A write or a rename that fails removes the temporary file and is the system's error. `write` and `rename` are `fs::write` and `fs::rename`, parameters so a test can make either fail.
fn save(
    target: &str,
    text: &str,
    write: impl FnOnce(&str, &str) -> io::Result<()>,
    rename: impl FnOnce(&str, &str) -> io::Result<()>,
) -> Result<(), Fault> {
    if let Some(dir) = Path::new(target).parent() {
        let dir = dir.display().to_string();
        fs::create_dir_all(&dir).map_err(|err| system(&err, "mkdir", &dir))?;
    }
    let temporary = format!("{target}.{}.tmp", std::process::id());
    let fault = write(&temporary, text)
        .map_err(|err| system(&err, "open", &temporary))
        .and_then(|()| {
            rename(&temporary, target)
                .map_err(|err| system(&err, "rename", &format!("{temporary}' -> '{target}")))
        })
        .err();
    if let Some(fault) = fault {
        let _ = fs::remove_file(&temporary);
        return Err(fault);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::{PermissionsExt, symlink};

    use super::*;
    use crate::testing::Scratch;

    /// `<dir>/config.toml` of a scratch directory, and the directory's listing.
    fn config_in(scratch: &Scratch) -> String {
        format!("{}/config.toml", scratch.dir())
    }

    fn listing(dir: &str) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    fn is_root() -> bool {
        rustix::process::geteuid().is_root()
    }

    #[test]
    fn a_write_that_fails_leaves_no_temporary_file_and_the_config_as_it_was() {
        let scratch = Scratch::new();
        let file = config_in(&scratch);
        fs::write(&file, "keep = 1\n").unwrap();

        let torn = save(
            &file,
            "new\n",
            |path, _| {
                fs::write(path, "par")?;
                Err(io::Error::other("disk full"))
            },
            |a, b| fs::rename(a, b),
        );
        assert!(torn.is_err());
        let unrenamed = save(
            &file,
            "new\n",
            |p, t| fs::write(p, t),
            |_, _| Err(io::Error::other("busy")),
        );
        assert!(unrenamed.is_err());

        assert_eq!(listing(scratch.dir()), ["config.toml"]);
        assert_eq!(fs::read_to_string(&file).unwrap(), "keep = 1\n");
    }

    #[test]
    fn a_missing_directory_and_a_missing_config_are_made_by_add_and_not_by_remove() {
        let scratch = Scratch::new();
        let file = format!("{}/a/b/config.toml", scratch.dir());
        assert_eq!(remove(&file, "k"), Ok(Removed::Absent));
        assert!(!Path::new(&file).exists() && !scratch.path().join("a").exists());

        assert_eq!(add(&file, "k", "pkg"), Ok(Added::Written));
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            "[plugins.k]\nfrom = \"pkg\"\n"
        );
        assert_eq!(listing(&format!("{}/a/b", scratch.dir())), ["config.toml"]);
    }

    #[test]
    fn a_config_that_is_a_link_is_edited_through_it_and_stays_a_link() {
        let scratch = Scratch::new();
        scratch.sub("dotfiles");
        scratch.sub("home");
        let real = format!("{}/dotfiles/tagents.toml", scratch.dir());
        let link = format!("{}/home/config.toml", scratch.dir());
        fs::write(&real, "[plugins.old]\nfrom = \"old\"\n").unwrap();
        symlink("../dotfiles/tagents.toml", &link).unwrap();

        assert_eq!(add(&link, "new", "pkg"), Ok(Added::Written));
        assert!(
            fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(
            fs::read_link(&link).unwrap().to_str(),
            Some("../dotfiles/tagents.toml")
        );
        assert_eq!(
            fs::read_to_string(&real).unwrap(),
            "[plugins.old]\nfrom = \"old\"\n\n[plugins.new]\nfrom = \"pkg\"\n"
        );

        assert_eq!(remove(&link, "old"), Ok(Removed::Written));
        assert!(
            fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(
            fs::read_to_string(&real).unwrap(),
            "[plugins.new]\nfrom = \"pkg\"\n"
        );
        assert_eq!(
            listing(&format!("{}/dotfiles", scratch.dir())),
            ["tagents.toml"]
        );
        assert_eq!(listing(&format!("{}/home", scratch.dir())), ["config.toml"]);
    }

    #[test]
    fn a_link_that_leads_nowhere_is_node_s_and_nothing_is_made() {
        let scratch = Scratch::new();
        let file = config_in(&scratch);
        symlink("missing.toml", &file).unwrap();
        assert!(add(&file, "k", "pkg").is_err());
        assert!(remove(&file, "k").is_err());
        assert_eq!(listing(scratch.dir()), ["config.toml"]);

        fs::remove_file(&file).unwrap();
        symlink("config.toml", &file).unwrap();
        assert!(add(&file, "k", "pkg").is_err());
        assert_eq!(listing(scratch.dir()), ["config.toml"]);
    }

    #[test]
    fn a_config_behind_a_chain_of_33_links_is_node_s_and_nothing_is_written() {
        let scratch = Scratch::new();
        let dir = scratch.dir();
        let real = format!("{dir}/real.toml");
        fs::write(&real, "[plugins.old]\nfrom = \"pkg\"\n").unwrap();
        for number in 1..33 {
            symlink(format!("link{}", number + 1), format!("{dir}/link{number}")).unwrap();
        }
        symlink("real.toml", format!("{dir}/link33")).unwrap();
        let file = config_in(&scratch);
        symlink("link1", &file).unwrap();

        // The kernel may follow 40 links, as on Linux, so the limit of `realpath` is what hands this over there.
        assert!(write_target(&file).is_err());
        assert!(add(&file, "new", "pkg").is_err());
        assert!(remove(&file, "old").is_err());
        assert_eq!(
            fs::read_to_string(&real).unwrap(),
            "[plugins.old]\nfrom = \"pkg\"\n"
        );
        assert_eq!(
            listing(dir).len(),
            35,
            "no temporary file or other file was made"
        );
    }

    #[test]
    fn a_config_that_cannot_be_read_is_never_taken_for_an_empty_one() {
        let scratch = Scratch::new();
        // A directory in the config's place.
        let file = config_in(&scratch);
        fs::create_dir(&file).unwrap();
        assert!(add(&file, "k", "pkg").is_err());
        assert!(remove(&file, "k").is_err());
        assert!(fs::metadata(&file).unwrap().is_dir());
        assert_eq!(listing(scratch.dir()), ["config.toml"]);
        fs::remove_dir(&file).unwrap();

        // A file nobody may read: the check is moot for root, who reads everything.
        if is_root() {
            return;
        }
        fs::write(&file, "[plugins.k]\nfrom = \"x\"\n").unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o000)).unwrap();
        assert!(add(&file, "other", "pkg").is_err());
        assert!(remove(&file, "k").is_err());
        fs::set_permissions(&file, fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            "[plugins.k]\nfrom = \"x\"\n"
        );
        assert_eq!(listing(scratch.dir()), ["config.toml"]);
    }

    #[test]
    fn a_config_that_is_not_utf8_is_read_with_the_replacement_character() {
        let scratch = Scratch::new();
        let file = config_in(&scratch);
        fs::write(&file, b"# \xff\n[plugins.k]\nfrom = \"x\"\n").unwrap();
        assert_eq!(add(&file, "other", "pkg"), Ok(Added::Written));
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            "# \u{FFFD}\n[plugins.k]\nfrom = \"x\"\n\n[plugins.other]\nfrom = \"pkg\"\n"
        );
    }

    #[test]
    fn a_not_a_number_elsewhere_in_the_config_is_equal_to_itself() {
        let scratch = Scratch::new();
        let file = config_in(&scratch);
        fs::write(
            &file,
            "x = nan\ny = [nan, 1]\n[plugins.k]\nfrom = \"p\"\n[other]\nz = -nan\n",
        )
        .unwrap();
        assert_eq!(remove(&file, "k"), Ok(Removed::Written));
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            "x = nan\ny = [nan, 1]\n[other]\nz = -nan\n"
        );
    }

    #[test]
    fn a_zero_and_a_negative_zero_are_not_the_same_value_and_an_integer_is_its_float() {
        let zero = parse("f", "z = 0.0\n", "").unwrap();
        let negative = parse("f", "z = -0.0\n", "").unwrap();
        let integer = parse("f", "z = 0\n", "").unwrap();
        assert!(!same_table(Some(&zero), Some(&negative), None));
        assert!(same_table(Some(&zero), Some(&integer), None));
    }
}
