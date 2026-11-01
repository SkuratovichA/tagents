//! Finding the package `plugin add` was given: the twin of `resolvePluginPackage` in `packages/core/src/plugin-config.ts`, for the cases it can prove identical.
//!
//! A directory argument (it starts with `.` or `~`, or is absolute) is resolved here in full. A bare name is node's `require.resolve('<name>/package.json')`, which has a long tail (`exports`, `NODE_PATH`, the global folders, `--require` hooks, self-reference), so it is resolved here only when a walk of the `node_modules` directories finds the package and nothing makes node's answer differ; every other name is a `Failure::HandOver`, and the node CLI resolves it. Nothing here reads more of the package than its `package.json`, and nothing imports it.

use std::fs;

use super::HandOver;
use crate::{
    json::{self, Value},
    node,
};

/// What the answer can depend on besides the arguments and the disk.
pub struct Env {
    /// `os.homedir()`.
    pub home: String,
    /// `NODE_OPTIONS` or `NODE_PRESERVE_SYMLINKS` is set: a `--require` hook or the symlink flag changes what `require.resolve` finds.
    pub node_flags: bool,
}

impl Env {
    pub fn current() -> Env {
        Env {
            home: node::homedir(),
            node_flags: ["NODE_OPTIONS", "NODE_PRESERVE_SYMLINKS"]
                .iter()
                .any(|name| std::env::var_os(name).is_some()),
        }
    }
}

/// A package that is a plugin (`PluginPackage`).
#[derive(Debug, PartialEq, Eq)]
pub struct Package {
    /// Where the package really is on disk.
    pub dir: String,
    /// What goes in the config as `from`: an absolute path, or the package name as typed.
    pub from: String,
    /// The `name` in its package.json, or the directory's name.
    pub package_name: String,
    /// Its `tagents.entry`, resolved, and known to exist.
    pub entry: String,
}

/// Why a package could not be added. The text is the file or spec the message names.
#[derive(Debug, PartialEq, Eq)]
pub enum Failure {
    /// Nothing was found at a path (an error, exit 1).
    NotFound(String),
    /// Something is there and is not a plugin: the manifest does not qualify (a refusal, exit 3).
    BadManifest(String),
    /// The manifest names an entry file that does not exist (a refusal, exit 3).
    NoEntry(String),
    /// Node answers this one.
    HandOver,
}

impl From<HandOver> for Failure {
    fn from(_: HandOver) -> Failure {
        Failure::HandOver
    }
}

const MANIFEST: &str = "package.json";

/// What `plugin add <spec>` was given, resolved as `cwd` sees it. A directory is written back as an absolute path and a name as itself.
pub fn resolve(spec: &str, cwd: &str, env: &Env) -> Result<Package, Failure> {
    let by_path = spec.starts_with(['.', '~', '/']);
    let dir = if by_path {
        node::resolve(cwd, &expand_tilde(spec, &env.home))
    } else {
        locate_by_name(spec, cwd, env)?
    };

    let manifest_file = node::join(&dir, MANIFEST);
    let manifest = match read_json(&manifest_file)? {
        Some(manifest) => manifest,
        None if by_path => return Err(Failure::NotFound(manifest_file)),
        None => return Err(Failure::BadManifest(manifest_file)),
    };
    let Some((name, entry)) = qualifies(&manifest) else {
        return Err(Failure::BadManifest(manifest_file));
    };

    let entry = node::resolve(&dir, entry);
    if !std::path::Path::new(&entry).exists() {
        return Err(Failure::NoEntry(entry));
    }
    Ok(Package {
        from: if by_path {
            dir.clone()
        } else {
            spec.to_owned()
        },
        package_name: name.map_or_else(|| node::basename(&dir).to_owned(), str::to_owned),
        entry,
        dir,
    })
}

/// `expandTilde`: `~` and `~/…` are the home directory.
fn expand_tilde(spec: &str, home: &str) -> String {
    match spec {
        "~" => node::join(home, ""),
        _ if spec.starts_with("~/") => node::join(home, &spec[1..]),
        _ => spec.to_owned(),
    }
}

/// The manifest's `name` and `tagents.entry` when it passes `ManifestSchema`: `name` a non-empty string if there is one, `tagents.apiVersion` the number 1, `tagents.entry` a non-empty string. Everything else in it is ignored.
fn qualifies(manifest: &Value) -> Option<(Option<&str>, &str)> {
    let name = match manifest.get("name") {
        None => None,
        Some(Value::String(name)) if !name.is_empty() => Some(name.as_str()),
        Some(_) => return None,
    };
    let tagents = manifest.get("tagents")?;
    if tagents.get("apiVersion") != Some(&Value::Number(1.0)) {
        return None;
    }
    match tagents.get("entry") {
        Some(Value::String(entry)) if !entry.is_empty() => Some((name, entry)),
        _ => None,
    }
}

/// The JSON in `file`: `None` when it cannot be read or is not JSON, a hand-over when the bytes are not UTF-8 (node reads them with U+FFFD and may still parse them).
fn read_json(file: &str) -> Result<Option<Value>, HandOver> {
    match fs::read(file) {
        Ok(bytes) => Ok(json::parse(
            &String::from_utf8(bytes).map_err(|_| HandOver)?,
        )),
        Err(_) => Ok(None),
    }
}

/// The JSON object in `file`; a hand-over when it cannot be read, is not JSON or is not an object, since node would fail on it or read it differently.
fn read_object(file: &str) -> Result<Value, HandOver> {
    read_json(file)?
        .filter(|value| matches!(value, Value::Object(_)))
        .ok_or(HandOver)
}

/// A package name as npm writes one, `name` or `@scope/name`: letters, digits and `._~-`, a segment never empty and never starting with `.` or `_`. A request outside it can be a subpath, a builtin or an import, which `require.resolve` reads differently.
fn is_package_name(spec: &str) -> bool {
    let segment = |s: &str| {
        !s.is_empty()
            && !s.starts_with(['.', '_'])
            && s.bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'~' | b'-'))
    };
    match spec.strip_prefix('@') {
        Some(scoped) => scoped
            .split_once('/')
            .is_some_and(|(scope, name)| segment(scope) && segment(name)),
        None => segment(spec),
    }
}

/// The real directory of the package `spec` names, found by walking the `node_modules` directories from `cwd` up, as `require.resolve('<spec>/package.json')` does before it goes to the global folders. A hand-over when anything else could decide.
fn locate_by_name(spec: &str, cwd: &str, env: &Env) -> Result<String, Failure> {
    if env.node_flags || !is_package_name(spec) || names_itself(spec, cwd)? {
        return Err(Failure::HandOver);
    }
    let manifest = ancestors(cwd)
        .into_iter()
        .filter(|dir| last_segment(dir) != "node_modules")
        .map(|dir| {
            node::join(
                &node::join(&dir, "node_modules"),
                &format!("{spec}/{MANIFEST}"),
            )
        })
        .find(|file| fs::metadata(file).is_ok_and(|meta| meta.is_file()))
        .ok_or(HandOver)?;

    // A package with `exports` is resolved by them, and node may refuse what the file system has.
    let package = read_object(&manifest)?;
    if package
        .get("exports")
        .is_some_and(|exports| *exports != Value::Null)
    {
        return Err(Failure::HandOver);
    }
    let real = node::realpath(&manifest).map_err(|_| HandOver)?;
    match real.rsplit_once('/') {
        Some(("", _)) => Ok("/".to_owned()),
        Some((dir, _)) => Ok(dir.to_owned()),
        None => Err(Failure::HandOver),
    }
}

/// Does the nearest `package.json` at or above `cwd` (the package scope) carry the name that `spec` begins, with an `exports` key? Node then resolves `spec` as a reference to that package, before any `node_modules`. The scope ends at a directory named `node_modules`. A package.json that cannot be read or is not an object is a hand-over, as node would fail on it.
fn names_itself(spec: &str, cwd: &str) -> Result<bool, HandOver> {
    for dir in ancestors(cwd) {
        if last_segment(&dir) == "node_modules" {
            return Ok(false);
        }
        let file = node::join(&dir, MANIFEST);
        if !fs::metadata(&file).is_ok_and(|meta| meta.is_file()) {
            continue;
        }
        let package = read_object(&file)?;
        let named = match package.get("name") {
            Some(Value::String(name)) => {
                format!("{spec}/{MANIFEST}").starts_with(&format!("{name}/"))
            }
            _ => false,
        };
        return Ok(package.get("exports").is_some() && named);
    }
    Ok(false)
}

/// `cwd` and each directory above it, nearest first, ending at the root.
fn ancestors(cwd: &str) -> Vec<String> {
    let segments: Vec<&str> = cwd.split('/').filter(|s| !s.is_empty()).collect();
    (0..=segments.len())
        .rev()
        .map(|n| format!("/{}", segments[..n].join("/")))
        .collect()
}

fn last_segment(dir: &str) -> &str {
    dir.rsplit('/').next().unwrap_or("")
}
