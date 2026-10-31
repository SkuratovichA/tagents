//! The `options` section of the notify vectors.
//! The options file `<configDir>/plugins/notify.toml` and the lines that report a bad one (`packages/notify/src/options.ts`, `packages/core/src/plugin-options.ts`): each document is written to a scratch config directory and read by `notify::options::load`, and the result is what the node service reaches for the same file. `configDir` is checked against the same section.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::Value;
use tagents_core::js;
use tagents_core::notify::options::{Loaded, Options, config_dir_from, load, options_file};

use super::section;

const FILE: &str = "<file>";

/// A scratch config directory, removed when it goes out of scope.
struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Scratch {
        static COUNT: AtomicUsize = AtomicUsize::new(0);
        let dir = std::env::temp_dir().join(format!(
            "tagents-options-vectors-{}-{}",
            std::process::id(),
            COUNT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&dir).unwrap();
        Scratch(dir)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let file = self.0.join("plugins/notify.toml");
        if fs::metadata(&file).is_ok() {
            fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).ok();
        }
        fs::remove_dir_all(&self.0).ok();
    }
}

fn hex_bytes(hex: &str) -> Vec<u8> {
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
        .collect()
}

/// Lay the case's file out under `dir`, as the generator did.
fn lay_out(case: &Value, dir: &Path) {
    let bytes = match (
        case.get("hex").and_then(Value::as_str),
        case.get("toml").and_then(Value::as_str),
    ) {
        (Some(hex), _) => hex_bytes(hex),
        (None, Some(text)) => text.as_bytes().to_vec(),
        (None, None) => Vec::new(),
    };
    let plugins = dir.join("plugins");
    let file = plugins.join("notify.toml");
    match case["setup"].as_str().unwrap() {
        "missing" => {}
        "plugins-is-a-file" => fs::write(&plugins, "not a directory").unwrap(),
        "directory" => fs::create_dir_all(&file).unwrap(),
        "dangling-symlink" => {
            fs::create_dir_all(&plugins).unwrap();
            symlink(dir.join("nowhere.toml"), &file).unwrap();
        }
        "yaml-only" => {
            fs::create_dir_all(&plugins).unwrap();
            fs::write(plugins.join("notify.yaml"), bytes).unwrap();
        }
        "symlink" => {
            fs::create_dir_all(&plugins).unwrap();
            fs::write(dir.join("real.toml"), bytes).unwrap();
            symlink(dir.join("real.toml"), &file).unwrap();
        }
        "unreadable" => {
            fs::create_dir_all(&plugins).unwrap();
            fs::write(&file, bytes).unwrap();
            fs::set_permissions(&file, fs::Permissions::from_mode(0o000)).unwrap();
        }
        "document" => {
            fs::create_dir_all(&plugins).unwrap();
            fs::write(&file, bytes).unwrap();
        }
        other => panic!("unknown setup {other}"),
    }
}

/// The options of node's JSON as `path=value` lines, numbers as JavaScript writes them, so a double compares as a double.
fn flatten(value: &Value, path: &str, out: &mut Vec<String>) {
    match value {
        Value::Object(map) => map
            .iter()
            .for_each(|(key, inner)| flatten(inner, &format!("{path}.{key}"), out)),
        Value::Number(n) => out.push(format!("{path}={}", js::number_text(n.as_f64().unwrap()))),
        other => out.push(format!("{path}={other}")),
    }
}

/// The same lines from the options this reader made.
fn describe(o: &Options) -> Vec<String> {
    let toggles = |name: &str, t: tagents_core::notify::options::Toggles| {
        vec![
            format!(".events.{name}.enabled={}", t.enabled),
            format!(".events.{name}.skip_visible={}", t.skip_visible),
        ]
    };
    let mut lines = vec![
        format!(".backend=\"{}\"", o.backend.as_str()),
        format!(".click=\"{}\"", o.click.as_str()),
    ];
    if let Some(icon) = &o.icon {
        lines.push(format!(".icon={}", Value::String(icon.clone())));
    }
    let e = &o.events;
    lines.extend(toggles("question", e.question));
    lines.extend(toggles("permission", e.permission));
    lines.extend(toggles("turn_done", e.turn_done));
    lines.extend(toggles("cache_expiring", e.cache_expiring.toggles));
    lines.push(format!(
        ".events.cache_expiring.after={}",
        js::number_text(e.cache_expiring.after_ms)
    ));
    lines.push(format!(
        ".events.cache_expiring.ttl={}",
        js::number_text(e.cache_expiring.ttl_ms)
    ));
    lines.extend(toggles("session_end", e.session_end));
    lines
}

fn sorted(mut lines: Vec<String>) -> Vec<String> {
    lines.sort();
    lines
}

/// What is wrong with the result of one case, or none.
fn judge(case: &Value) -> Option<String> {
    let setup = case["setup"].as_str().unwrap();
    if setup == "unreadable" && rustix::process::geteuid().is_root() {
        return None;
    }
    let scratch = Scratch::new();
    lay_out(case, &scratch.0);
    let file = options_file(&scratch.0);
    let got = load(&scratch.0);
    let want = &case["expect"];
    let kind = want["kind"].as_str().unwrap();
    match (kind, got) {
        ("found" | "missing", got) => {
            let (got_kind, options) = match got {
                Loaded::Found(o) => ("found", o),
                Loaded::Missing(o) => ("missing", o),
                Loaded::Invalid(lines) => {
                    return Some(format!(
                        "node reads it ({kind}), Rust says invalid: {lines:?}"
                    ));
                }
            };
            let mut expected = Vec::new();
            flatten(&want["options"], "", &mut expected);
            if got_kind != kind {
                return Some(format!("node says {kind}, Rust says {got_kind}"));
            }
            (sorted(expected.clone()) != sorted(describe(&options))).then(|| {
                format!(
                    "options differ\n  node: {expected:?}\n  rust: {:?}",
                    describe(&options)
                )
            })
        }
        ("invalid", Loaded::Invalid(lines)) => {
            let expected: Vec<String> = want["problems"]
                .as_array()
                .unwrap()
                .iter()
                .map(|l| l.as_str().unwrap().replace(FILE, &file))
                .collect();
            if want["syntax"].as_bool() == Some(true) {
                let prefix = format!("{file}: Invalid TOML document: ");
                let pinned = want["pinned"].as_bool() == Some(true);
                let ok = lines.len() == 1
                    && lines[0].starts_with(&prefix)
                    && (!pinned || lines == expected);
                return (!ok).then(|| format!("node: {expected:?}\n  rust: {lines:?}"));
            }
            (lines != expected).then(|| format!("node: {expected:?}\n  rust: {lines:?}"))
        }
        ("invalid", got) => Some(format!(
            "node says invalid {:?}, Rust says {got:?}",
            want["problems"]
        )),
        (other, _) => panic!("unknown kind {other}"),
    }
}

#[test]
fn every_document_gives_what_node_gives() {
    let section = section("options");
    let cases = section["documents"].as_array().unwrap();
    assert!(
        cases.len() >= 100,
        "the vectors hold {} documents",
        cases.len()
    );
    let failures: Vec<String> = cases
        .iter()
        .filter_map(|case| {
            judge(case).map(|why| format!("{}: {why}", case["name"].as_str().unwrap()))
        })
        .collect();
    assert!(
        failures.is_empty(),
        "{} of {} documents differ:\n{}",
        failures.len(),
        cases.len(),
        failures.join("\n")
    );
}

#[test]
fn the_config_dir_is_the_one_node_picks() {
    let section = section("options");
    let cases = section["configDirs"].as_array().unwrap();
    assert!(
        cases.len() >= 20,
        "the vectors hold {} environments",
        cases.len()
    );
    for case in cases {
        let var = |name: &str| case["env"].get(name).and_then(Value::as_str);
        let got = config_dir_from(
            var("TAGENTS_CONFIG_DIR"),
            var("XDG_CONFIG_HOME"),
            case["home"].as_str().unwrap(),
        );
        assert_eq!(got, case["expect"].as_str().unwrap(), "{}", case["env"]);
    }
}
