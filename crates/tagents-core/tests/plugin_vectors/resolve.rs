//! The `resolve` section of the plugin vectors: the tree of packages is laid out in a scratch directory, `plugin::resolve::resolve` answers each argument as node's `resolvePluginPackage` did; and the name, `path.resolve` and `path.relative` twins give node's answers.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::{fs, os::unix::fs::symlink, path::Path};

use serde_json::Value;
use tagents_core::{
    node,
    plugin::{
        default_plugin_name,
        resolve::{self, Env, Failure, Package},
    },
};

use super::{common, section};

fn lay_out(tree: &Value, root: &Path) {
    for entry in tree.as_array().unwrap() {
        let target = root.join(entry["path"].as_str().unwrap());
        match entry["kind"].as_str().unwrap() {
            "dir" => fs::create_dir_all(&target).unwrap(),
            kind => {
                fs::create_dir_all(target.parent().unwrap()).unwrap();
                if kind == "symlink" {
                    symlink(entry["target"].as_str().unwrap(), &target).unwrap();
                } else {
                    fs::write(&target, entry["text"].as_str().unwrap()).unwrap();
                }
            }
        }
    }
}

#[test]
fn every_argument_resolves_as_node_resolved_it() {
    let vectors = section("resolve");
    let root = common::scratch("plugin-vectors-tree")
        .canonicalize()
        .unwrap();
    let root_text = root.to_str().unwrap();
    lay_out(&vectors["tree"], &root);
    let env = Env {
        home: format!("{root_text}/home"),
        node_path: vec![],
    };
    let cases = vectors["cases"].as_array().unwrap();
    assert!(cases.len() > 60, "the vector file lost its cases");
    for case in cases {
        let spec = case["spec"].as_str().unwrap().replace("<root>", root_text);
        let cwd = format!("{root_text}/{}", case["cwd"].as_str().unwrap());
        let answer = resolve::resolve(&spec, &cwd, &env);
        let what = format!(
            "{:?} from {} (node: {})",
            case["spec"], case["cwd"], case["result"]
        );
        let result = &case["result"];
        let text = |key: &str| result[key].as_str().unwrap().replace("<root>", root_text);
        let want = if result["ok"] == true {
            Ok(Package {
                dir: text("dir"),
                from: text("from"),
                package_name: result["packageName"].as_str().unwrap().to_owned(),
                entry: text("entry"),
            })
        } else {
            Err(match result["problem"].as_str().unwrap() {
                "not-found" => Failure::NotFound(text("detail")),
                "bad-manifest" => Failure::BadManifest(text("detail")),
                "no-entry" => Failure::NoEntry(text("detail")),
                other => panic!("a problem named {other}"),
            })
        };
        assert_eq!(answer, want, "{what}");
    }
}

#[test]
fn default_names_are_node_s() {
    for case in section("resolve")["names"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        assert_eq!(
            default_plugin_name(name),
            case["key"].as_str().unwrap(),
            "{name:?}"
        );
    }
}

#[test]
fn resolve_and_relative_are_path_resolve_and_path_relative() {
    let vectors = section("resolve");
    for case in vectors["resolve"].as_array().unwrap() {
        let (base, path) = (
            case["base"].as_str().unwrap(),
            case["path"].as_str().unwrap(),
        );
        assert_eq!(
            node::resolve(base, path),
            case["resolved"].as_str().unwrap(),
            "{base:?} + {path:?}"
        );
    }
    for case in vectors["relative"].as_array().unwrap() {
        let (from, to) = (case["from"].as_str().unwrap(), case["to"].as_str().unwrap());
        assert_eq!(
            node::relative(from, to),
            case["relative"].as_str().unwrap(),
            "{from:?} -> {to:?}"
        );
    }
}
