//! Finding the package `plugin add` was given: the twin of `resolvePluginPackage` in `packages/core/src/plugin-config.ts`.
//!
//! A directory argument (it starts with `.` or `~`, or is absolute) is resolved in full. A bare name is node's `require.resolve('<name>/package.json')` from the working directory, then the global folder `pnpm root -g` names. The resolution walks the `node_modules` directories up from the working directory, then `NODE_PATH` and the two folders in the home directory, and honours the `exports` of the package it meets (the `./package.json` key, a pattern key with one `*`) and the self-reference of a package to its own name. It does not run `--require` hooks and does not know the `lib/node` folder of the node installation. A name it cannot find is `Failure::NotFound`, which is what node says when neither lookup finds it. Nothing here reads more of the package than its `package.json`, and nothing imports it.

use std::fs;

use crate::{
    json::{self, Value},
    node,
};

/// What the answer can depend on besides the arguments and the disk.
pub struct Env {
    /// `os.homedir()`.
    pub home: String,
    /// The directories of `NODE_PATH`, in order.
    pub node_path: Vec<String>,
}

impl Env {
    pub fn current() -> Env {
        Env {
            home: node::homedir(),
            node_path: std::env::var("NODE_PATH")
                .map(|paths| {
                    paths
                        .split(':')
                        .filter(|dir| !dir.is_empty())
                        .map(str::to_owned)
                        .collect()
                })
                .unwrap_or_default(),
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
    /// Nothing was found at a path or under a name (an error, exit 1).
    NotFound(String),
    /// Something is there and is not a plugin: the manifest does not qualify (a refusal, exit 3).
    BadManifest(String),
    /// The manifest names an entry file that does not exist (a refusal, exit 3).
    NoEntry(String),
}

const MANIFEST: &str = "package.json";

/// What `plugin add <spec>` was given, resolved as `cwd` sees it. A directory is written back as an absolute path and a name as itself.
pub fn resolve(spec: &str, cwd: &str, env: &Env) -> Result<Package, Failure> {
    let by_path = spec.starts_with(['.', '~', '/']);
    let dir = if by_path {
        node::resolve(cwd, &expand_tilde(spec, &env.home))
    } else {
        match locate_by_name(spec, cwd, env) {
            Some(dir) => dir,
            None => return Err(Failure::NotFound(spec.to_owned())),
        }
    };

    let manifest_file = node::join(&dir, MANIFEST);
    let manifest = match read_json(&manifest_file) {
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

/// The JSON in `file`: `None` when it cannot be read or is not JSON. Bytes that are not UTF-8 are read with U+FFFD, as node reads them.
fn read_json(file: &str) -> Option<Value> {
    json::parse(&String::from_utf8_lossy(&fs::read(file).ok()?))
}

/// The JSON object in `file`, or `None` when it cannot be read, is not JSON or is not an object.
fn read_object(file: &str) -> Option<Value> {
    read_json(file).filter(|value| matches!(value, Value::Object(_)))
}

/// A package name as npm writes one, split off `spec`: `name` or `@scope/name`, and what follows it.
fn split_package(spec: &str) -> (&str, &str) {
    let mut slashes = spec.match_indices('/').map(|(at, _)| at);
    let end = if spec.starts_with('@') {
        slashes.nth(1)
    } else {
        slashes.next()
    };
    match end {
        Some(at) => (&spec[..at], &spec[at..]),
        None => (spec, ""),
    }
}

/// Does `exports` of a package let `subpath` (`./package.json`) through: the key is listed, or a pattern key with one `*` matches it, and its target is not `null`. A package whose `exports` is a string, an array or conditions names `.` only.
fn exported(exports: &Value, subpath: &str) -> bool {
    let Value::Object(entries) = exports else {
        return false;
    };
    entries.iter().any(|(key, target)| {
        *target != Value::Null
            && (key == subpath
                || key.split_once('*').is_some_and(|(head, tail)| {
                    !tail.contains('*')
                        && subpath.len() >= head.len() + tail.len()
                        && subpath.starts_with(head)
                        && subpath.ends_with(tail)
                }))
    })
}

/// The real directory of the package `spec` names, found as `require.resolve('<spec>/package.json')` finds it from `cwd`, then in the global folder of pnpm; `None` where node finds nothing or throws.
fn locate_by_name(spec: &str, cwd: &str, env: &Env) -> Option<String> {
    found(spec, cwd, env).or_else(|| global(spec))
}

fn found(spec: &str, cwd: &str, env: &Env) -> Option<String> {
    let (package, rest) = split_package(spec);
    let subpath = format!(".{rest}/{MANIFEST}");
    let wanted = format!("{spec}/{MANIFEST}");
    let exports_allow = |root: &str| -> Option<bool> {
        let manifest = read_object(&node::join(root, MANIFEST))?;
        Some(match manifest.get("exports") {
            None | Some(Value::Null) => true,
            Some(exports) => exported(exports, &subpath),
        })
    };

    // The package the working directory is in, when it carries `exports` and the name: a reference to itself comes before every `node_modules`.
    for dir in ancestors(cwd) {
        if last_segment(&dir) == "node_modules" {
            break;
        }
        let file = node::join(&dir, MANIFEST);
        if !fs::metadata(&file).is_ok_and(|meta| meta.is_file()) {
            continue;
        }
        let manifest = read_object(&file)?;
        let named = matches!(manifest.get("name"), Some(Value::String(name)) if name == package);
        if named
            && manifest
                .get("exports")
                .is_some_and(|exports| *exports != Value::Null)
        {
            return exports_allow(&dir)?.then_some(dir);
        }
        break;
    }

    let modules = ancestors(cwd)
        .into_iter()
        .filter(|dir| last_segment(dir) != "node_modules")
        .map(|dir| node::join(&dir, "node_modules"));
    let folders = env.node_path.iter().cloned().chain([
        node::join(&env.home, ".node_modules"),
        node::join(&env.home, ".node_libraries"),
    ]);
    for folder in modules.chain(folders) {
        let manifest = node::join(&folder, &wanted);
        if !fs::metadata(&manifest).is_ok_and(|meta| meta.is_file()) {
            continue;
        }
        // A package with `exports` is resolved by them, and a name they leave out is an error.
        if !exports_allow(&node::join(&folder, package))? {
            return None;
        }
        let real = node::realpath(&manifest).ok()?;
        return match real.rsplit_once('/') {
            Some(("", _)) => Some("/".to_owned()),
            Some((dir, _)) => Some(dir.to_owned()),
            None => None,
        };
    }
    None
}

/// The package in the global folder `pnpm root -g` names, when pnpm answers and the folder is there.
fn global(spec: &str) -> Option<String> {
    let out = std::process::Command::new("pnpm")
        .args(["root", "-g"])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()
        .filter(|out| out.status.success())?;
    let root = String::from_utf8_lossy(&out.stdout).trim().to_owned();
    if root.is_empty() || !std::path::Path::new(&root).exists() {
        return None;
    }
    let dir = node::join(&root, spec);
    fs::metadata(node::join(&dir, MANIFEST))
        .is_ok_and(|meta| meta.is_file())
        .then_some(dir)
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
