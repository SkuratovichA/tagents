//! The options file `<configDir>/plugins/notify.toml` and the lines that report a bad one (`packages/notify/src/options.ts`, `packages/core/src/plugin-options.ts`).
//!
//! The file is parsed by the `toml` crate and checked by hand against the one schema of `options.ts`, because the lines the node service logs are zod's, byte for byte, in zod's order: serde's texts would be other words in another order. Everything that changes a byte is a copy of what node does and is pinned by the vectors (`tests/rust-notify-vectors/options.mts`): the order of unknown keys (a JavaScript object's), the type names, a date read as an empty table, a duration read by `parseDuration`, a number written by `String(x)`.
//!
//! A bad file never stops the service: it runs on `Options::default()` and logs the lines of `Loaded::Invalid`. A file that is not TOML is reported as `<file>: Invalid TOML document: <reason>`, the reason being the parser's own except for an integer beyond 2^53, which the node parser refuses and this one reads.

use std::{
    fs,
    io::{self, Read},
    path::Path,
};

use toml::de::{DeFloat, DeInteger, DeTable, DeValue};

use crate::{js, json, node};

/// The directory of the options files, in the config directory.
const PLUGIN_OPTIONS_DIR: &str = "plugins";
/// The largest integer a JavaScript number holds exactly, `Number.MAX_SAFE_INTEGER`.
const MAX_SAFE_INTEGER: i128 = 9_007_199_254_740_991;
/// The text node's TOML parser gives for an integer it cannot hold: it refuses it, and so does this reader.
const LOSSY_INTEGER: &str = "integer value cannot be represented losslessly";
/// What `after < ttl` failing says, at `events.cache_expiring.after`.
const AFTER_BELOW_TTL: &str =
    "after must be below ttl: a notice about a cache that already expired helps nobody";
const DEFAULT_AFTER_MS: f64 = 3_000_000.0;
const DEFAULT_TTL_MS: f64 = 3_600_000.0;

/// Which backend posts the notices: `backend` of the file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Backend {
    Auto,
    Macos,
    Log,
    None,
}

impl Backend {
    /// The word the file and the log use.
    pub fn as_str(self) -> &'static str {
        match self {
            Backend::Auto => "auto",
            Backend::Macos => "macos",
            Backend::Log => "log",
            Backend::None => "none",
        }
    }
}

/// What a click on a notice does: `click` of the file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Click {
    Dock,
    Goto,
    Focus,
}

impl Click {
    /// The word the file and the log use.
    pub fn as_str(self) -> &'static str {
        match self {
            Click::Dock => "dock",
            Click::Goto => "goto",
            Click::Focus => "focus",
        }
    }
}

/// The two switches every event has.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Toggles {
    pub enabled: bool,
    pub skip_visible: bool,
}

/// `events.cache_expiring`: the switches and the two durations, in milliseconds as node holds them (a JavaScript number, so a huge value is as inexact as it is there).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CacheExpiring {
    pub toggles: Toggles,
    pub after_ms: f64,
    pub ttl_ms: f64,
}

/// `events` of the file.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Events {
    pub question: Toggles,
    pub permission: Toggles,
    pub turn_done: Toggles,
    pub cache_expiring: CacheExpiring,
    pub session_end: Toggles,
}

/// The options of the notify daemon: `NotifyOptions` of `options.ts`, every default filled in.
#[derive(Debug, Clone, PartialEq)]
pub struct Options {
    pub backend: Backend,
    pub click: Click,
    /// The icon as the file wrote it (`~/`, relative or absolute), never empty; none when unset.
    pub icon: Option<String>,
    pub events: Events,
}

impl Default for Options {
    fn default() -> Options {
        let on = Toggles {
            enabled: true,
            skip_visible: true,
        };
        Options {
            backend: Backend::Auto,
            click: Click::Dock,
            icon: None,
            events: Events {
                question: on,
                permission: on,
                turn_done: on,
                cache_expiring: CacheExpiring {
                    toggles: Toggles {
                        enabled: true,
                        skip_visible: false,
                    },
                    after_ms: DEFAULT_AFTER_MS,
                    ttl_ms: DEFAULT_TTL_MS,
                },
                session_end: Toggles {
                    enabled: false,
                    skip_visible: true,
                },
            },
        }
    }
}

/// What reading the options file gives. `Missing` and `Invalid` both run the service on the defaults; the `started` line tells them apart (`not found`, `invalid`), and `Invalid` carries the lines to log as `options: <line>`, each once per distinct set.
#[derive(Debug, Clone, PartialEq)]
pub enum Loaded {
    /// The file is there and valid.
    Found(Options),
    /// No file (`ENOENT`, a dangling symlink included): the defaults.
    Missing(Options),
    /// A file that cannot be read, is not TOML or does not fit the schema: the lines node logs, in its order.
    Invalid(Vec<String>),
}

/// `configDir` of `packages/core/src/host.ts`: `$TAGENTS_CONFIG_DIR` unless blank, else `$XDG_CONFIG_HOME` unless blank, else `~/.config`, then `tagents`.
pub fn config_dir() -> String {
    let env = |name: &str| std::env::var_os(name).map(|v| v.to_string_lossy().into_owned());
    config_dir_from(
        env("TAGENTS_CONFIG_DIR").as_deref(),
        env("XDG_CONFIG_HOME").as_deref(),
        &node::homedir(),
    )
}

/// `config_dir` with the two variables and the home directory given, `None` for an unset variable. A variable that is blank by `String.prototype.trim` (empty, or only JavaScript whitespace, U+FEFF included) is as good as unset, and `$TAGENTS_CONFIG_DIR` is used as written, not trimmed.
pub fn config_dir_from(
    tagents_config_dir: Option<&str>,
    xdg_config_home: Option<&str>,
    home: &str,
) -> String {
    if let Some(dir) = not_blank(tagents_config_dir) {
        return dir.to_owned();
    }
    let base = match not_blank(xdg_config_home) {
        Some(xdg) => xdg.to_owned(),
        None => node::join(home, ".config"),
    };
    node::join(&base, "tagents")
}

/// An environment variable that is set and not blank: JavaScript's `value && value.trim()`.
fn not_blank(value: Option<&str>) -> Option<&str> {
    value.filter(|v| !js::trim(v).is_empty())
}

/// `pluginOptionsFile(configDir, 'notify')`: `<configDir>/plugins/notify.toml`, whether it is there or not. No file of another name is looked at.
pub fn options_file(config_dir: &Path) -> String {
    node::join(
        &config_dir.to_string_lossy(),
        &format!("{PLUGIN_OPTIONS_DIR}/notify.toml"),
    )
}

/// `loadPluginOptions(configDir, 'notify', NotifyOptionsSchema)`: read the file, parse it, check it. Nothing here fails: every outcome is a `Loaded`.
pub fn load(config_dir: &Path) -> Loaded {
    let file = options_file(config_dir);
    match read(&file, |path| fs::File::open(path)) {
        Ok(Some(text)) => match parse(&text, &file) {
            Ok(options) => Loaded::Found(options),
            Err(lines) => Loaded::Invalid(lines),
        },
        Ok(None) => Loaded::Missing(Options::default()),
        Err(why) => Loaded::Invalid(vec![format!("{file}: {why}")]),
    }
}

/// macOS fails an open with EINVAL when the path crosses a symlink that a rename is replacing; the daemon reads at an event of any name in the directory, so it can read during that rename (node reads only at an event named `notify.toml`, after it). Three tries close the window.
const OPEN_TRIES: u32 = 3;

/// `open(file)`, tried again while it fails with EINVAL, `OPEN_TRIES` tries in all.
fn open_with(
    file: &str,
    mut open: impl FnMut(&str) -> io::Result<fs::File>,
) -> io::Result<fs::File> {
    let mut tried = 1;
    loop {
        match open(file) {
            Err(err)
                if err.raw_os_error() == Some(rustix::io::Errno::INVAL.raw_os_error())
                    && tried < OPEN_TRIES =>
            {
                tried += 1;
            }
            other => return other,
        }
    }
}

/// `fs.readFileSync(file, 'utf8')`: the text, `None` for `ENOENT`, and for any other failure the text node prints. Bytes that are not UTF-8 become U+FFFD, as node decodes them. `open` is `fs::File::open` in `load`, a parameter so a test can feed it errors.
fn read(
    file: &str,
    open: impl FnMut(&str) -> io::Result<fs::File>,
) -> Result<Option<String>, String> {
    let mut handle = match open_with(file, open) {
        Ok(handle) => handle,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(node::io_message(&err, "open", Some(file))),
    };
    let mut bytes = Vec::new();
    handle
        .read_to_end(&mut bytes)
        .map_err(|err| node::io_message(&err, "read", None))?;
    Ok(Some(String::from_utf8_lossy(&bytes).into_owned()))
}

/// The text of the file, parsed and checked: the options, or the lines that report it.
fn parse(text: &str, file: &str) -> Result<Options, Vec<String>> {
    let root = match DeTable::parse(text) {
        Ok(root) => root.into_inner(),
        Err(err) => {
            return Err(vec![format!(
                "{file}: Invalid TOML document: {}",
                err.message()
            )]);
        }
    };
    if table_holds_lossy_integer(&root) {
        return Err(vec![format!(
            "{file}: Invalid TOML document: {LOSSY_INTEGER}"
        )]);
    }
    let mut issues = Vec::new();
    let options = check(&root, &mut issues);
    if issues.is_empty() {
        Ok(options)
    } else {
        Err(issues)
    }
}

/// An integer anywhere in the document that a JavaScript number cannot hold exactly: the node parser refuses the whole file for it, whatever key it is under.
fn table_holds_lossy_integer(table: &DeTable<'_>) -> bool {
    table
        .values()
        .any(|value| holds_lossy_integer(value.get_ref()))
}

fn holds_lossy_integer(value: &DeValue<'_>) -> bool {
    match value {
        DeValue::Integer(int) => integer(int).is_none(),
        DeValue::Array(items) => items.iter().any(|item| holds_lossy_integer(item.get_ref())),
        DeValue::Table(table) => table_holds_lossy_integer(table),
        _ => false,
    }
}

/// An integer as a JavaScript number, or `None` when it is not a safe integer (`Number.isSafeInteger`).
fn integer(int: &DeInteger<'_>) -> Option<f64> {
    let value = i128::from_str_radix(int.as_str(), int.radix()).ok()?;
    (value.abs() <= MAX_SAFE_INTEGER).then_some(value as f64)
}

/// A float as `parseFloat` of its text gives it: an overflow is infinity, `nan` and `inf` are the special values.
fn float(f: &DeFloat<'_>) -> f64 {
    let text = f.as_str().replace('_', "");
    match text.trim_start_matches(['+', '-']) {
        "inf" => {
            if text.starts_with('-') {
                f64::NEG_INFINITY
            } else {
                f64::INFINITY
            }
        }
        "nan" => f64::NAN,
        _ => text.parse().unwrap_or(f64::NAN),
    }
}

/// The table of a value that stands where the schema wants an object. A missing key is an empty one (`.prefault({})`), and so is a date or a time, which zod takes for an object with no keys.
struct Object<'a, 'i> {
    table: Option<&'a DeTable<'i>>,
}

impl<'a, 'i> Object<'a, 'i> {
    fn get(&self, key: &str) -> Option<&'a DeValue<'i>> {
        let table = self.table?;
        table
            .iter()
            .find(|(name, _)| name.get_ref().as_ref() == key)
            .map(|(_, value)| value.get_ref())
    }

    /// The keys that are not in `known`, in the order a JavaScript object lists its own: the keys that are array indexes in ascending order, then the others as the file wrote them.
    fn unknown(&self, known: &[&str]) -> Vec<&'a str> {
        let Some(table) = self.table else {
            return Vec::new();
        };
        let (mut indexes, others): (Vec<&str>, Vec<&str>) = table
            .keys()
            .map(|name| name.get_ref().as_ref())
            .filter(|name| !known.contains(name))
            .partition(|name| array_index(name).is_some());
        indexes.sort_by_key(|name| array_index(name));
        indexes.extend(others);
        indexes
    }
}

/// `k` as an array index (`"0"`, `"17"`, up to `"4294967294"`), the keys a JavaScript object lists first and in numeric order.
fn array_index(key: &str) -> Option<u64> {
    let canonical = !key.is_empty()
        && key.bytes().all(|b| b.is_ascii_digit())
        && (key == "0" || !key.starts_with('0'));
    canonical
        .then(|| key.parse::<u64>().ok())
        .flatten()
        .filter(|index| *index <= 4_294_967_294)
}

/// The name zod gives a value in `received <type>`.
fn type_name(value: &DeValue<'_>) -> &'static str {
    match value {
        DeValue::String(_) => "string",
        DeValue::Integer(_) => "number",
        DeValue::Float(f) => match float(f) {
            x if x.is_nan() => "NaN",
            f64::INFINITY => "Infinity",
            f64::NEG_INFINITY => "-Infinity",
            _ => "number",
        },
        DeValue::Boolean(_) => "boolean",
        DeValue::Datetime(_) => "TomlDate",
        DeValue::Array(_) => "array",
        DeValue::Table(_) => "object",
    }
}

/// `<path>: <message>`, or the bare message at the root: a line of `issueLines`.
fn issue(issues: &mut Vec<String>, path: &str, message: &str) {
    issues.push(if path.is_empty() {
        message.to_owned()
    } else {
        format!("{path}: {message}")
    });
}

fn wrong_type(issues: &mut Vec<String>, path: &str, expected: &str, value: &DeValue<'_>) {
    issue(
        issues,
        path,
        &format!(
            "Invalid input: expected {expected}, received {}",
            type_name(value)
        ),
    );
}

fn child(path: &str, key: &str) -> String {
    if path.is_empty() {
        key.to_owned()
    } else {
        format!("{path}.{key}")
    }
}

/// The value at `key` of `parent` as an object.
fn object<'a, 'i>(
    parent: &Object<'a, 'i>,
    key: &str,
    path: &str,
    issues: &mut Vec<String>,
) -> Object<'a, 'i> {
    match parent.get(key) {
        None | Some(DeValue::Datetime(_)) => Object { table: None },
        Some(DeValue::Table(table)) => Object { table: Some(table) },
        Some(other) => {
            wrong_type(issues, path, "object", other);
            Object { table: None }
        }
    }
}

/// The object's `Unrecognized key` issue, after the issues of its own keys.
fn unknown_keys(object: &Object<'_, '_>, known: &[&str], path: &str, issues: &mut Vec<String>) {
    let unknown = object.unknown(known);
    let list = unknown
        .iter()
        .map(|key| format!("\"{key}\""))
        .collect::<Vec<_>>()
        .join(", ");
    match unknown.len() {
        0 => {}
        1 => issue(issues, path, &format!("Unrecognized key: {list}")),
        _ => issue(issues, path, &format!("Unrecognized keys: {list}")),
    }
}

/// A value from a list of words: `z.enum(...)`, whatever the value's type.
fn choice<T: Copy>(
    object: &Object<'_, '_>,
    key: &str,
    words: &[(&str, T)],
    default: T,
    issues: &mut Vec<String>,
) -> T {
    let Some(value) = object.get(key) else {
        return default;
    };
    if let Some((_, chosen)) = words.iter().find(|(word, _)| value.as_str() == Some(*word)) {
        return *chosen;
    }
    let list = words
        .iter()
        .map(|(word, _)| format!("\"{word}\""))
        .collect::<Vec<_>>()
        .join("|");
    issue(
        issues,
        key,
        &format!("Invalid option: expected one of {list}"),
    );
    default
}

fn boolean(
    object: &Object<'_, '_>,
    key: &str,
    path: &str,
    default: bool,
    issues: &mut Vec<String>,
) -> bool {
    match object.get(key) {
        None => default,
        Some(DeValue::Boolean(value)) => *value,
        Some(other) => {
            wrong_type(issues, &child(path, key), "boolean", other);
            default
        }
    }
}

fn toggles(
    object: &Object<'_, '_>,
    path: &str,
    default: Toggles,
    issues: &mut Vec<String>,
) -> Toggles {
    Toggles {
        enabled: boolean(object, "enabled", path, default.enabled, issues),
        skip_visible: boolean(object, "skip_visible", path, default.skip_visible, issues),
    }
}

/// An event with only the two switches: `events.<key>`.
fn simple(
    events: &Object<'_, '_>,
    key: &str,
    default: Toggles,
    issues: &mut Vec<String>,
) -> Toggles {
    let path = child("events", key);
    let event = object(events, key, &path, issues);
    let result = toggles(&event, &path, default, issues);
    unknown_keys(&event, &["enabled", "skip_visible"], &path, issues);
    result
}

/// `Number.isSafeInteger(x)`.
fn is_safe_integer(x: f64) -> bool {
    x.is_finite() && x.fract() == 0.0 && x.abs() <= MAX_SAFE_INTEGER as f64
}

/// `parseDuration` of `options.ts` for a number: whole non-negative seconds, as milliseconds.
fn duration_of_number(x: f64) -> Option<f64> {
    (is_safe_integer(x) && x >= 0.0).then_some(x * 1000.0)
}

/// `parseDuration` for a string: ASCII digits are seconds, else `^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$` with the empty string refused, and the total a safe integer.
fn duration_of_text(text: &str) -> Option<f64> {
    if text.is_empty() {
        return None;
    }
    if text.bytes().all(|b| b.is_ascii_digit()) {
        return duration_of_number(js::number(text));
    }
    let mut rest = text;
    let mut parts = [0.0_f64; 3];
    for (part, unit) in parts.iter_mut().zip(['h', 'm', 's']) {
        let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
        if digits > 0 && rest[digits..].starts_with(unit) {
            *part = js::number(&rest[..digits]);
            rest = &rest[digits + 1..];
        }
    }
    if !rest.is_empty() {
        return None;
    }
    let seconds = parts[0] * 3600.0 + parts[1] * 60.0 + parts[2];
    is_safe_integer(seconds).then_some(seconds * 1000.0)
}

/// The text of a duration problem: the value as `JSON.stringify` writes it, a string quoted and a number as `String(x)`.
fn not_a_duration(json: &str) -> String {
    format!("not a duration: {json} (use 90, 45s, 50m, 2h or 1h30m)")
}

/// `Duration` of `options.ts`, in milliseconds: a string or a number that `parseDuration` accepts. A value of any other type, and a number that is not finite, is the bare `Invalid input` of the union.
fn duration(
    object: &Object<'_, '_>,
    key: &str,
    path: &str,
    default: f64,
    issues: &mut Vec<String>,
) -> f64 {
    let Some(value) = object.get(key) else {
        return default;
    };
    let (parsed, json) = match value {
        DeValue::String(text) => (duration_of_text(text), json::quote(text)),
        DeValue::Integer(int) => {
            let number = integer(int).unwrap_or(f64::NAN);
            (duration_of_number(number), js::number_text(number))
        }
        DeValue::Float(f) if float(f).is_finite() => {
            let number = float(f);
            (duration_of_number(number), js::number_text(number))
        }
        _ => {
            issue(issues, &child(path, key), "Invalid input");
            return default;
        }
    };
    parsed.unwrap_or_else(|| {
        issue(issues, &child(path, key), &not_a_duration(&json));
        default
    })
}

fn cache_expiring(
    events: &Object<'_, '_>,
    default: CacheExpiring,
    issues: &mut Vec<String>,
) -> CacheExpiring {
    let path = "events.cache_expiring";
    let before = issues.len();
    let section = object(events, "cache_expiring", path, issues);
    let result = CacheExpiring {
        toggles: toggles(&section, path, default.toggles, issues),
        after_ms: duration(&section, "after", path, default.after_ms, issues),
        ttl_ms: duration(&section, "ttl", path, default.ttl_ms, issues),
    };
    // The check that `after` is below `ttl` runs only when every key of the object was well formed, and an unknown key does not stop it.
    let well_formed = issues.len() == before;
    unknown_keys(
        &section,
        &["enabled", "skip_visible", "after", "ttl"],
        path,
        issues,
    );
    if well_formed && result.after_ms >= result.ttl_ms {
        issue(issues, &child(path, "after"), AFTER_BELOW_TTL);
    }
    result
}

/// `NotifyOptionsSchema.safeParse` of the document: the options, and the lines of every problem in `issueLines`' order, pushed to `issues`.
fn check(root: &DeTable<'_>, issues: &mut Vec<String>) -> Options {
    let top = Object { table: Some(root) };
    let default = Options::default();
    let backend = choice(
        &top,
        "backend",
        &[
            ("auto", Backend::Auto),
            ("macos", Backend::Macos),
            ("log", Backend::Log),
            ("none", Backend::None),
        ],
        default.backend,
        issues,
    );
    let click = choice(
        &top,
        "click",
        &[
            ("dock", Click::Dock),
            ("goto", Click::Goto),
            ("focus", Click::Focus),
        ],
        default.click,
        issues,
    );
    let icon = match top.get("icon") {
        None => None,
        Some(DeValue::String(text)) if text.is_empty() => {
            issue(
                issues,
                "icon",
                "Too small: expected string to have >=1 characters",
            );
            None
        }
        Some(DeValue::String(text)) => Some(text.to_string()),
        Some(other) => {
            wrong_type(issues, "icon", "string", other);
            None
        }
    };
    let events_object = object(&top, "events", "events", issues);
    let events = Events {
        question: simple(&events_object, "question", default.events.question, issues),
        permission: simple(
            &events_object,
            "permission",
            default.events.permission,
            issues,
        ),
        turn_done: simple(
            &events_object,
            "turn_done",
            default.events.turn_done,
            issues,
        ),
        cache_expiring: cache_expiring(&events_object, default.events.cache_expiring, issues),
        session_end: simple(
            &events_object,
            "session_end",
            default.events.session_end,
            issues,
        ),
    };
    unknown_keys(
        &events_object,
        &[
            "question",
            "permission",
            "turn_done",
            "cache_expiring",
            "session_end",
        ],
        "events",
        issues,
    );
    unknown_keys(&top, &["backend", "click", "icon", "events"], "", issues);
    Options {
        backend,
        click,
        icon,
        events,
    }
}

#[cfg(test)]
mod tests {
    //! The cases of `packages/notify/test/options.test.ts` that read and validate options, one line each:
    //! - no option lets a subagent, a child session or a headless one post: the old switches are problems: `the_old_switches_are_problems`
    //! - every default is the one the documentation shows: `every_default_is_the_one_the_documentation_shows`
    //! - a partial file keeps every other default, one level down as well: `a_partial_file_keeps_every_other_default_one_level_down_as_well`
    //! - durations in the file become milliseconds, 1h30m among them: `durations_in_the_file_become_milliseconds`
    //! - parseDuration: units combine, a bare number is seconds, anything looser is null: `duration_of_text_and_number_follow_parse_duration`
    //! - after at or above ttl is a problem located at after: `after_at_or_above_ttl_is_a_problem_located_at_after`
    //! - a bad duration is a problem located at that key: `a_bad_duration_is_a_problem_located_at_that_key`
    //! - an unknown key is a problem at the top, in sessions, in events and inside an event: `an_unknown_key_is_a_problem_at_every_level`
    //! - the enums reject a value they do not list: `the_enums_reject_a_value_they_do_not_list`
    //! - icon is an optional non-empty string and has no default: `icon_is_an_optional_non_empty_string_and_has_no_default`
    //! - the package exports the schema beside the type derived from it: not applicable: a module export of a TypeScript package, nothing a Rust file reads

    use std::fs;
    use std::os::unix::fs::{PermissionsExt, symlink};
    use std::path::PathBuf;

    use super::*;
    use crate::testing::Scratch;

    const FILE: &str = "<file>";

    fn options(text: &str) -> Options {
        parse(text, FILE).unwrap_or_else(|lines| panic!("{text:?} is invalid: {lines:?}"))
    }

    fn problems(text: &str) -> Vec<String> {
        match parse(text, FILE) {
            Ok(options) => panic!("{text:?} is valid: {options:?}"),
            Err(lines) => lines,
        }
    }

    fn cache(after: &str, ttl: &str) -> String {
        format!("[events.cache_expiring]\nafter = {after}\nttl = {ttl}\n")
    }

    /// What these tests ask of a scratch directory besides its path.
    trait OptionsDir {
        fn plugins(&self) -> PathBuf;
        fn file(&self) -> String;
    }

    impl OptionsDir for Scratch {
        fn plugins(&self) -> PathBuf {
            let dir = self.0.join("plugins");
            fs::create_dir_all(&dir).unwrap();
            dir
        }

        fn file(&self) -> String {
            options_file(&self.0)
        }
    }

    #[test]
    fn the_old_switches_are_problems() {
        assert_eq!(
            problems("[sessions]\nheadless = true\n"),
            ["Unrecognized key: \"sessions\""]
        );
        assert_eq!(
            problems("[events.subagent_done]\nenabled = true\n"),
            ["events: Unrecognized key: \"subagent_done\""]
        );
    }

    #[test]
    fn every_default_is_the_one_the_documentation_shows() {
        let on = Toggles {
            enabled: true,
            skip_visible: true,
        };
        let want = Options {
            backend: Backend::Auto,
            click: Click::Dock,
            icon: None,
            events: Events {
                question: on,
                permission: on,
                turn_done: on,
                cache_expiring: CacheExpiring {
                    toggles: Toggles {
                        enabled: true,
                        skip_visible: false,
                    },
                    after_ms: 3_000_000.0,
                    ttl_ms: 3_600_000.0,
                },
                session_end: Toggles {
                    enabled: false,
                    skip_visible: true,
                },
            },
        };
        assert_eq!(options(""), want);
        assert_eq!(Options::default(), want);
    }

    #[test]
    fn a_partial_file_keeps_every_other_default_one_level_down_as_well() {
        let o = options("click = \"goto\"\n[events.question]\nenabled = false\n");
        assert!(!o.events.question.enabled);
        assert!(o.events.question.skip_visible);
        assert_eq!(o.click, Click::Goto);
        assert_eq!(o.backend, Backend::Auto);
        assert!(o.events.turn_done.enabled);
        assert_eq!(o.events.cache_expiring.ttl_ms, 60.0 * 60_000.0);
    }

    #[test]
    fn durations_in_the_file_become_milliseconds() {
        let o = options(&cache("\"1h30m\"", "\"2h\""));
        assert_eq!(o.events.cache_expiring.after_ms, 5_400_000.0);
        assert_eq!(o.events.cache_expiring.ttl_ms, 7_200_000.0);
        assert_eq!(
            options("[events.cache_expiring]\nafter = 90\n")
                .events
                .cache_expiring
                .after_ms,
            90_000.0
        );
        assert_eq!(
            options("[events.cache_expiring]\nafter = 1.0e1\n")
                .events
                .cache_expiring
                .after_ms,
            10_000.0
        );
    }

    #[test]
    fn duration_of_text_and_number_follow_parse_duration() {
        for (text, ms) in [
            ("90", 90_000.0),
            ("1h30m", 5_400_000.0),
            ("50m", 3_000_000.0),
            ("45s", 45_000.0),
            ("1h2m3s", 3_723_000.0),
            ("00090", 90_000.0),
            ("0s", 0.0),
        ] {
            assert_eq!(duration_of_text(text), Some(ms), "{text:?}");
        }
        for bad in [
            "",
            "5x",
            "m",
            "1.5h",
            "30m1h",
            "1h 30m",
            " 5m",
            "5m ",
            "5m\n",
            "90\n",
            "\u{663}",
            "\u{ff19}\u{ff10}",
            "1H",
            "-1",
            "+5",
            "1e3",
            "0x10",
            "9007199254740992",
            "2501999792984h",
        ] {
            assert_eq!(duration_of_text(bad), None, "{bad:?}");
        }
        assert_eq!(duration_of_number(90.0), Some(90_000.0));
        for bad in [-1.0, 1.5, f64::NAN, f64::INFINITY, 9_007_199_254_740_992.0] {
            assert_eq!(duration_of_number(bad), None, "{bad}");
        }
    }

    #[test]
    fn after_at_or_above_ttl_is_a_problem_located_at_after() {
        let line = format!("events.cache_expiring.after: {AFTER_BELOW_TTL}");
        for (after, ttl) in [("\"60m\"", "\"60m\""), ("\"2h\"", "\"1h\"")] {
            assert_eq!(problems(&cache(after, ttl)), std::slice::from_ref(&line));
        }
        assert_eq!(
            problems("[events.cache_expiring]\nafter = \"2h\"\n"),
            std::slice::from_ref(&line)
        );
        assert_eq!(problems("[events.cache_expiring]\nttl = \"30m\"\n"), [line]);
    }

    #[test]
    fn a_bad_duration_is_a_problem_located_at_that_key() {
        assert_eq!(
            problems("[events.cache_expiring]\nttl = \"1.5h\"\n"),
            ["events.cache_expiring.ttl: not a duration: \"1.5h\" (use 90, 45s, 50m, 2h or 1h30m)"]
        );
        assert_eq!(
            problems("[events.cache_expiring]\nafter = 5e-1\n"),
            ["events.cache_expiring.after: not a duration: 0.5 (use 90, 45s, 50m, 2h or 1h30m)"]
        );
        assert_eq!(
            problems("[events.cache_expiring]\nafter = true\n"),
            ["events.cache_expiring.after: Invalid input"]
        );
        assert_eq!(
            problems("[events.cache_expiring]\nafter = 1979-05-27\n"),
            ["events.cache_expiring.after: Invalid input"]
        );
    }

    #[test]
    fn an_unknown_key_is_a_problem_at_every_level() {
        for text in [
            "bogus = 1\n",
            "[sessions]\nheadles = true\n",
            "[events.question_asked]\nenabled = true\n",
            "[events.question]\nenabld = true\n",
            "[events.cache_expiring]\nafterr = \"5m\"\n",
        ] {
            assert_eq!(problems(text).len(), 1, "{text:?}");
        }
    }

    #[test]
    fn unknown_keys_are_listed_in_the_order_of_a_javascript_object() {
        assert_eq!(
            problems("b = 1\n\"2\" = 1\n\"1\" = 1\n"),
            ["Unrecognized keys: \"1\", \"2\", \"b\""]
        );
        assert_eq!(
            problems("z = 1\n\"4294967295\" = 1\n\"4294967294\" = 1\n\"01\" = 1\n\"0\" = 1\n"),
            ["Unrecognized keys: \"0\", \"4294967294\", \"z\", \"4294967295\", \"01\""]
        );
        assert_eq!(problems("\"a\\\"b\" = 1\n"), ["Unrecognized key: \"a\"b\""]);
    }

    #[test]
    fn the_enums_reject_a_value_they_do_not_list() {
        let backend =
            "backend: Invalid option: expected one of \"auto\"|\"macos\"|\"log\"|\"none\"";
        let click = "click: Invalid option: expected one of \"dock\"|\"goto\"|\"focus\"";
        assert_eq!(problems("backend = \"smtp\"\n"), [backend]);
        assert_eq!(problems("click = \"bounce\"\n"), [click]);
        assert_eq!(problems("click = 3\n"), [click]);
        assert_eq!(
            problems("click = \"tap\"\nbackend = \"x\"\nicn = 1\n"),
            [backend, click, "Unrecognized key: \"icn\""]
        );
        for (word, backend) in [
            ("auto", Backend::Auto),
            ("macos", Backend::Macos),
            ("log", Backend::Log),
            ("none", Backend::None),
        ] {
            assert_eq!(options(&format!("backend = \"{word}\"\n")).backend, backend);
            assert_eq!(backend.as_str(), word);
        }
        for (word, click) in [
            ("dock", Click::Dock),
            ("goto", Click::Goto),
            ("focus", Click::Focus),
        ] {
            assert_eq!(options(&format!("click = \"{word}\"\n")).click, click);
            assert_eq!(click.as_str(), word);
        }
    }

    #[test]
    fn icon_is_an_optional_non_empty_string_and_has_no_default() {
        assert_eq!(options("").icon, None);
        assert_eq!(
            options("icon = \"~/pics/tagents.png\"\n").icon.as_deref(),
            Some("~/pics/tagents.png")
        );
        assert_eq!(
            problems("icon = \"\"\n"),
            ["icon: Too small: expected string to have >=1 characters"]
        );
        assert_eq!(
            problems("icon = 3\n"),
            ["icon: Invalid input: expected string, received number"]
        );
    }

    #[test]
    fn the_type_names_zod_gives_a_value() {
        for (value, name) in [
            ("1", "number"),
            ("1.5", "number"),
            ("true", "boolean"),
            ("[1]", "array"),
            ("{ a = 1 }", "object"),
            ("1979-05-27", "TomlDate"),
            ("07:32:00", "TomlDate"),
            ("1979-05-27T07:32:00Z", "TomlDate"),
            ("nan", "NaN"),
            ("-nan", "NaN"),
            ("inf", "Infinity"),
            ("+inf", "Infinity"),
            ("-inf", "-Infinity"),
            ("1e400", "Infinity"),
            ("-1e400", "-Infinity"),
        ] {
            assert_eq!(
                problems(&format!("icon = {value}\n")),
                [format!(
                    "icon: Invalid input: expected string, received {name}"
                )],
                "{value}"
            );
        }
    }

    #[test]
    fn a_date_where_a_table_is_expected_is_an_empty_table() {
        for text in [
            "events = 1979-05-27\n",
            "[events]\nquestion = 07:32:00\n",
            "[events]\ncache_expiring = 1979-05-27T07:32:00\n",
        ] {
            assert_eq!(options(text), Options::default(), "{text:?}");
        }
        assert_eq!(
            problems("events = [1]\n"),
            ["events: Invalid input: expected object, received array"]
        );
    }

    #[test]
    fn the_issues_of_an_object_come_in_the_order_of_its_shape_then_its_unknown_keys() {
        let text = "zz = 1\nicon = \"\"\nclick = 1\nbackend = 2\n[events]\nquestion = \"x\"\n";
        assert_eq!(
            problems(text),
            [
                "backend: Invalid option: expected one of \"auto\"|\"macos\"|\"log\"|\"none\"",
                "click: Invalid option: expected one of \"dock\"|\"goto\"|\"focus\"",
                "icon: Too small: expected string to have >=1 characters",
                "events.question: Invalid input: expected object, received string",
                "Unrecognized key: \"zz\"",
            ]
        );
        assert_eq!(
            problems("[events.cache_expiring]\nttl = \"x\"\nafter = \"y\"\nskip_visible = 2\nenabled = 3\n").iter().map(|l| l.split(':').next().unwrap().to_owned()).collect::<Vec<_>>(),
            ["events.cache_expiring.enabled", "events.cache_expiring.skip_visible", "events.cache_expiring.after", "events.cache_expiring.ttl"]
        );
    }

    #[test]
    fn a_type_problem_inside_cache_expiring_skips_the_after_below_ttl_check_and_an_unknown_key_does_not()
     {
        assert_eq!(
            problems("[events.cache_expiring]\nenabled = \"x\"\nafter = \"2h\"\nttl = \"1h\"\n")
                .len(),
            1
        );
        assert_eq!(
            problems("[events.cache_expiring]\nafter = \"5x\"\nttl = \"1h\"\n").len(),
            1
        );
        assert_eq!(
            problems("[events.cache_expiring]\nafter = \"2h\"\nttl = \"1h\"\nzz = 1\n"),
            [
                "events.cache_expiring: Unrecognized key: \"zz\"".to_owned(),
                format!("events.cache_expiring.after: {AFTER_BELOW_TTL}"),
            ]
        );
    }

    #[test]
    fn an_integer_beyond_2_pow_53_is_refused_wherever_it_stands_with_node_s_reason() {
        let reason = format!("{FILE}: Invalid TOML document: {LOSSY_INTEGER}");
        for text in [
            "zzz = 9007199254740993\n",
            "[events.cache_expiring]\nafter = 9007199254740992\n",
            "zzz = [1, [9007199254740993]]\n",
            "zzz = { a = { b = -9007199254740993 } }\n",
            "[[zzz]]\na = 9007199254740993\n",
            "zzz = 18446744073709551616\n",
            "zzz = -9223372036854775808\n",
            "zzz = 0x20000000000000\n",
            "zzz = 0o400000000000000000\n",
            "zzz = 0b100000000000000000000000000000000000000000000000000000\n",
            "zzz = 340282366920938463463374607431768211456\n",
        ] {
            assert_eq!(problems(text), std::slice::from_ref(&reason), "{text:?}");
        }
        assert_eq!(
            problems("zzz = 9007199254740991\n"),
            ["Unrecognized key: \"zzz\""]
        );
    }

    #[test]
    fn a_file_that_is_not_toml_is_one_problem_with_the_parser_s_reason() {
        for text in [
            "click = \n",
            "click = \"goto\"\nclick = \"dock\"\n",
            "[events\n",
            "after = 01\n",
        ] {
            let lines = problems(text);
            assert_eq!(lines.len(), 1, "{text:?}");
            assert!(
                lines[0].starts_with(&format!("{FILE}: Invalid TOML document: ")),
                "{lines:?}"
            );
        }
    }

    #[test]
    fn numbers_that_toml_writes_in_other_ways_are_numbers() {
        for (literal, ms) in [
            ("+5", 5000.0),
            ("1_000", 1_000_000.0),
            ("0b101", 5000.0),
            ("0o17", 15_000.0),
            ("0x1F", 31_000.0),
            ("1e1", 10_000.0),
            ("1.0", 1000.0),
            ("0.1e1", 1000.0),
        ] {
            assert_eq!(
                options(&cache("0", literal)).events.cache_expiring.ttl_ms,
                ms,
                "{literal}"
            );
        }
        assert_eq!(
            options(&cache("-0", "5")).events.cache_expiring.after_ms,
            0.0
        );
        assert_eq!(
            problems(&cache("0", "1_0.5")),
            ["events.cache_expiring.ttl: not a duration: 10.5 (use 90, 45s, 50m, 2h or 1h30m)"]
        );
        assert_eq!(
            problems(&cache("0", "1e21")),
            ["events.cache_expiring.ttl: not a duration: 1e+21 (use 90, 45s, 50m, 2h or 1h30m)"]
        );
        assert_eq!(
            problems(&cache("0", "-1e400")),
            ["events.cache_expiring.ttl: Invalid input"]
        );
    }

    #[test]
    fn a_duration_string_is_quoted_as_json_stringify_quotes_it() {
        for (toml_text, shown) in [
            ("\"a\\\"b\"", "\"a\\\"b\""),
            ("\"a\\\\b\"", "\"a\\\\b\""),
            ("\"5\\n\"", "\"5\\n\""),
            ("\"\\t5m\"", "\"\\t5m\""),
            ("\"5\\u0001\"", "\"5\\u0001\""),
            ("\"5\\u007f\"", "\"5\u{7f}\""),
            ("\"\\u2028\"", "\"\u{2028}\""),
        ] {
            assert_eq!(
                problems(&cache("0", toml_text)),
                [format!(
                    "events.cache_expiring.ttl: not a duration: {shown} (use 90, 45s, 50m, 2h or 1h30m)"
                )],
                "{toml_text}"
            );
        }
    }

    #[test]
    fn the_path_is_plugins_notify_toml_and_nothing_else() {
        assert_eq!(options_file(Path::new("/c")), "/c/plugins/notify.toml");
        assert_eq!(
            options_file(Path::new("/a//b/../c/")),
            "/a/c/plugins/notify.toml"
        );
    }

    #[test]
    fn a_missing_file_is_the_defaults() {
        let scratch = Scratch::new();
        assert_eq!(load(&scratch.0), Loaded::Missing(Options::default()));
        scratch.plugins();
        assert_eq!(load(&scratch.0), Loaded::Missing(Options::default()));
    }

    #[test]
    fn a_dangling_symlink_is_a_missing_file() {
        let scratch = Scratch::new();
        symlink(
            scratch.0.join("nowhere.toml"),
            scratch.plugins().join("notify.toml"),
        )
        .unwrap();
        assert_eq!(load(&scratch.0), Loaded::Missing(Options::default()));
    }

    #[test]
    fn only_a_yaml_file_is_not_looked_at() {
        let scratch = Scratch::new();
        fs::write(scratch.plugins().join("notify.yaml"), "click: goto\n").unwrap();
        fs::write(scratch.plugins().join("notify.yml"), "click: goto\n").unwrap();
        assert_eq!(load(&scratch.0), Loaded::Missing(Options::default()));
    }

    #[test]
    fn a_directory_named_notify_toml_is_one_problem_with_the_text_node_prints() {
        let scratch = Scratch::new();
        fs::create_dir_all(scratch.plugins().join("notify.toml")).unwrap();
        assert_eq!(
            load(&scratch.0),
            Loaded::Invalid(vec![format!(
                "{}: EISDIR: illegal operation on a directory, read",
                scratch.file()
            )])
        );
    }

    #[test]
    fn a_file_without_read_permission_is_one_problem_with_the_text_node_prints() {
        if rustix::process::geteuid().is_root() {
            return;
        }
        let scratch = Scratch::new();
        let file = scratch.plugins().join("notify.toml");
        fs::write(&file, "click = \"goto\"\n").unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o000)).unwrap();
        let path = scratch.file();
        assert_eq!(
            load(&scratch.0),
            Loaded::Invalid(vec![format!(
                "{path}: EACCES: permission denied, open '{path}'"
            )])
        );
    }

    /// An opener that gives the errors of `errors` one per call, then opens `file`; `calls` counts the calls.
    fn opener<'a>(
        errors: &'a [i32],
        file: &'a Path,
        calls: &'a std::cell::Cell<usize>,
    ) -> impl FnMut(&str) -> io::Result<fs::File> + 'a {
        move |_| {
            let call = calls.get();
            calls.set(call + 1);
            match errors.get(call) {
                Some(&number) => Err(io::Error::from_raw_os_error(number)),
                None => fs::File::open(file),
            }
        }
    }

    const EINVAL: i32 = rustix::io::Errno::INVAL.raw_os_error();

    #[test]
    fn an_open_that_fails_with_einval_twice_is_tried_a_third_time() {
        let scratch = Scratch::new();
        let file = scratch.0.join("real.toml");
        fs::write(&file, "click = \"goto\"\n").unwrap();
        let calls = std::cell::Cell::new(0);
        assert_eq!(
            read("<file>", opener(&[EINVAL, EINVAL], &file, &calls)),
            Ok(Some("click = \"goto\"\n".to_string()))
        );
        assert_eq!(calls.get(), 3);
    }

    #[test]
    fn an_open_that_always_fails_with_einval_is_tried_three_times_and_reports_it() {
        let calls = std::cell::Cell::new(0);
        let err = io::Error::from_raw_os_error(EINVAL);
        let expected = node::io_message(&err, "open", Some("<file>"));
        assert_eq!(
            read(
                "<file>",
                opener(&[EINVAL; 5], Path::new("/nowhere"), &calls)
            ),
            Err(expected)
        );
        assert_eq!(calls.get(), 3);
    }

    #[test]
    fn an_open_that_fails_with_enoent_or_eacces_is_tried_once() {
        let calls = std::cell::Cell::new(0);
        let enoent = rustix::io::Errno::NOENT.raw_os_error();
        assert_eq!(
            read("<file>", opener(&[enoent], Path::new("/nowhere"), &calls)),
            Ok(None)
        );
        assert_eq!(calls.get(), 1);

        let calls = std::cell::Cell::new(0);
        let eacces = rustix::io::Errno::ACCESS.raw_os_error();
        let expected = node::io_message(
            &io::Error::from_raw_os_error(eacces),
            "open",
            Some("<file>"),
        );
        assert_eq!(
            read("<file>", opener(&[eacces], Path::new("/nowhere"), &calls)),
            Err(expected)
        );
        assert_eq!(calls.get(), 1);
    }

    #[test]
    fn a_plugins_that_is_a_file_is_one_problem_with_the_text_node_prints() {
        let scratch = Scratch::new();
        fs::write(scratch.0.join("plugins"), "not a directory").unwrap();
        let path = scratch.file();
        assert_eq!(
            load(&scratch.0),
            Loaded::Invalid(vec![format!(
                "{path}: ENOTDIR: not a directory, open '{path}'"
            )])
        );
    }

    #[test]
    fn a_file_is_read_and_checked_whether_or_not_it_is_a_symlink() {
        let scratch = Scratch::new();
        fs::write(scratch.0.join("real.toml"), "click = \"goto\"\n").unwrap();
        symlink(
            scratch.0.join("real.toml"),
            scratch.plugins().join("notify.toml"),
        )
        .unwrap();
        let Loaded::Found(found) = load(&scratch.0) else {
            panic!("not found")
        };
        assert_eq!(found.click, Click::Goto);
    }

    #[test]
    fn bytes_that_are_not_utf_8_are_read_as_the_replacement_character() {
        let scratch = Scratch::new();
        fs::write(
            scratch.plugins().join("notify.toml"),
            b"icon = \"\xff.png\"\n",
        )
        .unwrap();
        let Loaded::Found(found) = load(&scratch.0) else {
            panic!("not found")
        };
        assert_eq!(found.icon.as_deref(), Some("\u{fffd}.png"));
    }

    #[test]
    fn an_invalid_file_is_invalid_with_the_lines_in_order() {
        let scratch = Scratch::new();
        fs::write(
            scratch.plugins().join("notify.toml"),
            "icn = 1\nclick = \"tap\"\n",
        )
        .unwrap();
        assert_eq!(
            load(&scratch.0),
            Loaded::Invalid(vec![
                "click: Invalid option: expected one of \"dock\"|\"goto\"|\"focus\"".to_owned(),
                "Unrecognized key: \"icn\"".to_owned()
            ])
        );
    }

    #[test]
    fn config_dir_follows_the_rules_of_host_ts() {
        for (dir, xdg, want) in [
            (Some("/c"), None, "/c"),
            (Some(" /c "), None, " /c "),
            (Some(""), None, "/h/.config/tagents"),
            (Some("  \t"), None, "/h/.config/tagents"),
            (Some("\u{feff}"), Some("/x"), "/x/tagents"),
            (Some("\u{a0}\u{2028}"), None, "/h/.config/tagents"),
            (Some("\u{200b}"), None, "\u{200b}"),
            (None, Some("/x"), "/x/tagents"),
            (None, Some("/x/../y/"), "/y/tagents"),
            (None, Some(" "), "/h/.config/tagents"),
            (None, Some(""), "/h/.config/tagents"),
            (None, None, "/h/.config/tagents"),
            (Some("/c"), Some("/x"), "/c"),
            (Some(" "), Some("/x"), "/x/tagents"),
        ] {
            assert_eq!(config_dir_from(dir, xdg, "/h"), want, "{dir:?} {xdg:?}");
        }
    }
}
