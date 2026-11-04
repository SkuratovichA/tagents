//! `tagents-core plugin add`, `plugin remove` and `plugin new`: the verbs of the plugin group that this binary serves.
//!
//! Every call of them is answered here. A failure prints the line node prints: a table line or a fixed template as the same bytes, the system's text for a call that failed, the TOML parser's message in node's frame with the Rust parser's words. What stays with node is a word the binary does not serve (`list`, bare `plugin`, a word nobody knows), which `serve` answers with `None`. The texts it prints are the catalogue's, in `spec/cli/messages.json`.
//!
//! The options are read by `parse_args`: `add` takes `--name V` and `new` takes `--dir V`, `remove` takes no option, and a command line outside that grammar is refused in node's words with the usage code.

pub mod config;
pub mod resolve;
pub mod scaffold;

use config::{Added, Removed};
use resolve::Failure;

use std::{fs, io, path::Path};

use crate::{
    host::config_file,
    messages::{Locale, Texts},
    node,
    parse_args::{Grammar, Kind},
    sessions::{self, Output, exit},
};

/// The verbs this module serves, as the words after the program name. `tagents-core --spec` prints them and a test pins them to `impl: "rust"` in the data file.
pub const VERBS: &[&[&str]] = &[
    &["plugin", "add"],
    &["plugin", "remove"],
    &["plugin", "new"],
];

/// `@tagents/plugin-telegram` is `telegram`: the key an entry gets by default (`defaultPluginName`).
pub fn default_plugin_name(package_name: &str) -> String {
    let bare = package_name
        .rsplit_once('/')
        .map_or(package_name, |(_, last)| last);
    let trimmed = bare.strip_prefix("tagents-plugin-").unwrap_or(bare);
    let trimmed = trimmed.strip_prefix("plugin-").unwrap_or(trimmed);
    if trimmed.is_empty() { bare } else { trimmed }.to_owned()
}

/// What a call depends on besides its arguments.
pub struct Setting {
    /// `process.cwd()`, with U+FFFD for a byte that is not UTF-8; `None` when the directory is gone, which node fails on at the first plugin verb it runs.
    pub cwd: Option<String>,
    /// `configFile()`.
    pub file: String,
    pub locale: Locale,
    pub env: resolve::Env,
    /// `<root>/packages/core` of the checkout this binary belongs to, which is where the node CLI that `plugin new` links sits; the error says why the root cannot be told.
    pub core_dir: Result<String, String>,
}

impl Setting {
    /// The setting of this process.
    pub fn current() -> Setting {
        Setting {
            cwd: std::env::current_dir()
                .ok()
                .map(|dir| dir.to_string_lossy().into_owned()),
            file: config_file(),
            locale: Locale::current(),
            env: resolve::Env::current(),
            core_dir: node::root()
                .map(|root| root.join("packages/core").to_string_lossy().into_owned()),
        }
    }
}

/// `plugin(argv)` of the node CLI for the verbs served here: `argv` is the words after `plugin`. `None` is a word that stays with node.
pub fn run(argv: &[String]) -> Option<Output> {
    serve(argv, &Setting::current())
}

/// `run` in a given setting.
pub fn serve(argv: &[String], setting: &Setting) -> Option<Output> {
    let (verb, args) = argv.split_first()?;
    if !matches!(verb.as_str(), "add" | "remove" | "new") {
        return None;
    }
    let texts = match sessions::texts(setting.locale) {
        Ok(texts) => texts,
        Err(out) => return Some(out),
    };
    // `plugin(argv, io, t, cwd = process.cwd())` reads the directory before it looks at the verb.
    let Some(cwd) = setting.cwd.as_deref() else {
        return Some(Output::line(exit::ERROR, GONE_CWD));
    };
    Some(match verb.as_str() {
        "add" => add(args, cwd, setting, &texts),
        "remove" => remove(args, setting, &texts),
        _ => new(args, cwd, setting, &texts),
    })
}

/// What `process.cwd()` throws in a directory that was removed.
pub const GONE_CWD: &str = "ENOENT: no such file or directory, uv_cwd";

/// The options of the three verbs.
pub(crate) const ADD: Grammar = Grammar {
    options: &[("name", Kind::Text)],
    positionals: true,
};
pub(crate) const REMOVE: Grammar = Grammar {
    options: &[],
    positionals: true,
};
pub(crate) const NEW: Grammar = Grammar {
    options: &[("dir", Kind::Text)],
    positionals: true,
};

/// `NAME` of `cli/plugin.ts`: a config key and a directory name, so it is typeable and greppable.
fn is_name(name: &str) -> bool {
    let mut bytes = name.bytes();
    bytes.next().is_some_and(|b| b.is_ascii_alphanumeric())
        && bytes.all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// A line on stderr and an exit code that says it was not done.
fn failure(code: u8, line: String) -> Output {
    Output::line(code, &line)
}

/// `add(argv)` of `cli/plugin.ts`.
fn add(args: &[String], cwd: &str, setting: &Setting, texts: &Texts) -> Output {
    let parsed = match ADD.parse(args) {
        Ok(parsed) => parsed,
        Err(err) => return Output::refused_args(&err),
    };
    let Some(spec) = parsed.words().first().copied() else {
        return failure(
            exit::USAGE,
            texts.t("missingOption", &[("option", "<package-or-path>")]),
        );
    };

    let package = match resolve::resolve(spec, cwd, &setting.env) {
        Ok(package) => package,
        Err(Failure::NotFound(detail)) => {
            return failure(
                exit::ERROR,
                texts.t("pluginUnresolved", &[("spec", &detail)]),
            );
        }
        Err(Failure::NoEntry(detail)) => {
            return failure(
                exit::REFUSED,
                texts.t("pluginNoEntry", &[("file", &detail)]),
            );
        }
        Err(Failure::BadManifest(detail)) => {
            return failure(
                exit::REFUSED,
                texts.t("pluginBadManifest", &[("file", &detail)]),
            );
        }
    };

    let name = parsed
        .value("name")
        .map_or_else(|| default_plugin_name(&package.package_name), str::to_owned);
    if !is_name(&name) {
        return failure(exit::USAGE, texts.t("pluginBadName", &[("name", &name)]));
    }

    let file = &setting.file;
    match config::add(file, &name, &package.from) {
        Err(config::Fault(line)) => failure(exit::ERROR, line),
        Ok(Added::Exists) => failure(
            exit::REFUSED,
            texts.t("pluginExists", &[("name", &name), ("file", file)]),
        ),
        Ok(Added::Written) => Output::out(format!(
            "{}\n",
            texts.t(
                "pluginAdded",
                &[("name", &name), ("from", &package.from), ("file", file)]
            )
        )),
    }
}

/// `remove(argv)` of `cli/plugin.ts`.
fn remove(args: &[String], setting: &Setting, texts: &Texts) -> Output {
    let parsed = match REMOVE.parse(args) {
        Ok(parsed) => parsed,
        Err(err) => return Output::refused_args(&err),
    };
    let Some(name) = parsed.words().first().copied() else {
        return failure(
            exit::USAGE,
            texts.t("missingOption", &[("option", "<name>")]),
        );
    };
    let file = &setting.file;
    match config::remove(file, name) {
        Err(config::Fault(line)) => failure(exit::ERROR, line),
        Ok(Removed::Absent) => failure(
            exit::REFUSED,
            texts.t("pluginNotListed", &[("name", name), ("file", file)]),
        ),
        Ok(Removed::Written) => Output::out(format!(
            "{}\n",
            texts.t("pluginRemoved", &[("name", name), ("file", file)])
        )),
    }
}

/// One file of the scaffold written as node writes it: `mkdirSync(dirname, { recursive: true })`, then `writeFileSync`. The error is node's line for the call that failed.
fn write_file(path: &str, body: &str) -> Result<(), String> {
    if let Some(parent) = Path::new(path).parent() {
        let parent = parent.display().to_string();
        fs::create_dir_all(&parent).map_err(|err| {
            // `mkdirSync` with `recursive` finds no directory at a link to nowhere, where `create_dir_all` finds the name taken.
            let dangling =
                err.kind() == io::ErrorKind::AlreadyExists && fs::metadata(&parent).is_err();
            let err = if dangling {
                io::Error::from_raw_os_error(2)
            } else {
                err
            };
            node::io_message(&err, "mkdir", Some(&parent))
        })?;
    }
    fs::write(path, body).map_err(|err| node::io_message(&err, "open", Some(path)))
}

/// Whether `dir` holds anything, as `fs.existsSync(dir) && fs.readdirSync(dir).length > 0` finds out. The error is node's line for a directory that cannot be listed (a file, no permission).
fn holds_anything(dir: &str) -> Result<bool, String> {
    // `existsSync` is false for a link to nowhere and for any path that cannot be looked at.
    if fs::metadata(dir).is_err() {
        return Ok(false);
    }
    let scandir = |err: io::Error| node::io_message(&err, "scandir", Some(dir));
    Ok(fs::read_dir(dir)
        .map_err(scandir)?
        .next()
        .transpose()
        .map_err(scandir)?
        .is_some())
}

/// Writes `files` below `dir` in order with `put`. A step that fails undoes what the sequence made and returns the line to print.
fn write_files(
    dir: &str,
    files: &[scaffold::File],
    put: &dyn Fn(&str, &str) -> Result<(), String>,
) -> Result<(), String> {
    let topmost = topmost_missing(dir);
    for (done, file) in files.iter().enumerate() {
        if let Err(line) = put(&node::join(dir, &file.path), &file.body) {
            undo(dir, &files[..=done], topmost);
            return Err(line);
        }
    }
    Ok(())
}

/// The directory nearest the root that is not there yet on the way down to `dir`: `dir` itself or one above it, and `None` when `dir` is there. A link to nowhere is there.
fn topmost_missing(dir: &str) -> Option<&Path> {
    Path::new(dir)
        .ancestors()
        .take_while(|above| {
            matches!(fs::symlink_metadata(above), Err(err) if err.kind() == io::ErrorKind::NotFound)
        })
        .last()
}

/// Removes what writing `attempted` may have left: the files, whole or half written, then the directories made for them below `dir`, deepest first, then, when `dir` was missing, `dir` and the directories made on the way to it, up to `topmost`, the first that was missing. The target was missing or empty, so all of it is ours, and a directory that was there stays. A removal that fails is skipped: node words whatever is left.
fn undo(dir: &str, attempted: &[scaffold::File], topmost: Option<&Path>) {
    let mut made = std::collections::BTreeSet::new();
    for file in attempted {
        let _ = fs::remove_file(node::join(dir, &file.path));
        made.extend(
            Path::new(&file.path)
                .ancestors()
                .skip(1)
                .filter(|above| !above.as_os_str().is_empty())
                .map(|above| above.display().to_string()),
        );
    }
    for above in made.iter().rev() {
        let _ = fs::remove_dir(node::join(dir, above));
    }
    let Some(topmost) = topmost else {
        return;
    };
    for above in Path::new(dir).ancestors() {
        if fs::remove_dir(above).is_err() || above == topmost {
            break;
        }
    }
}

/// `new(argv)` of `cli/plugin.ts`.
fn new(args: &[String], cwd: &str, setting: &Setting, texts: &Texts) -> Output {
    create(args, cwd, setting, texts, &write_file)
}

/// `new` with `put` as the write of one file, which the tests make fail.
fn create(
    args: &[String],
    cwd: &str,
    setting: &Setting,
    texts: &Texts,
    put: &dyn Fn(&str, &str) -> Result<(), String>,
) -> Output {
    let parsed = match NEW.parse(args) {
        Ok(parsed) => parsed,
        Err(err) => return Output::refused_args(&err),
    };
    let Some(name) = parsed.words().first().copied() else {
        return failure(
            exit::USAGE,
            texts.t("missingOption", &[("option", "<name>")]),
        );
    };
    if !is_name(name) {
        return failure(exit::USAGE, texts.t("pluginBadName", &[("name", name)]));
    }
    let dir = node::resolve(cwd, parsed.value("dir").unwrap_or(name));
    match holds_anything(&dir) {
        Err(line) => return failure(exit::ERROR, line),
        Ok(true) => {
            return failure(
                exit::REFUSED,
                texts.t("pluginTargetExists", &[("dir", &dir)]),
            );
        }
        Ok(false) => {}
    }
    let core_dir = match &setting.core_dir {
        Ok(core_dir) => core_dir,
        Err(why) => return failure(exit::ERROR, format!("tagents-core: {why}")),
    };
    let files = scaffold::files(name, &dir, core_dir);
    if let Err(line) = write_files(&dir, &files, put) {
        return failure(exit::ERROR, line);
    }
    Output::out(format!(
        "{}\n",
        texts.t("pluginScaffolded", &[("dir", &dir)])
    ))
}

#[cfg(test)]
mod tests {
    use std::{fs, path::Path};

    use super::*;
    use crate::testing::Scratch;

    fn words(args: &[&str]) -> Vec<String> {
        args.iter().map(|a| (*a).to_owned()).collect()
    }

    #[test]
    fn a_name_is_what_cli_plugin_ts_accepts() {
        for name in ["a", "A", "0", "a.b", "a_b", "a-b", "9x._-", "telegram"] {
            assert!(is_name(name), "{name:?}");
        }
        for name in [
            "",
            ".a",
            "_a",
            "-a",
            "a b",
            "a/b",
            "a\n",
            "\né",
            "é",
            "a\u{fe0f}",
            "a\0",
        ] {
            assert!(!is_name(name), "{name:?}");
        }
    }

    #[test]
    fn the_verbs_are_add_remove_and_new() {
        assert_eq!(
            VERBS,
            [
                &["plugin", "add"][..],
                &["plugin", "remove"],
                &["plugin", "new"]
            ]
        );
    }

    /// A working directory with a plugin at `pkg` and a config directory of its own, in English.
    struct Fixture {
        _scratch: Scratch,
        root: String,
        setting: Setting,
    }

    fn fixture(locale: Locale) -> Fixture {
        let scratch = Scratch::new();
        let root = fs::canonicalize(scratch.path())
            .unwrap()
            .to_str()
            .unwrap()
            .to_owned();
        fs::create_dir_all(format!("{root}/pkg/src")).unwrap();
        fs::write(
            format!("{root}/pkg/package.json"),
            r#"{"name":"@tagents/plugin-demo","tagents":{"apiVersion":1,"entry":"./src/plugin.ts"}}"#,
        )
        .unwrap();
        fs::write(format!("{root}/pkg/src/plugin.ts"), "").unwrap();
        let setting = Setting {
            cwd: Some(root.clone()),
            file: format!("{root}/cfg/config.toml"),
            locale,
            env: resolve::Env {
                home: format!("{root}/home"),
                node_path: vec![],
            },
            core_dir: Ok(format!("{root}/core")),
        };
        Fixture {
            _scratch: scratch,
            root,
            setting,
        }
    }

    fn said(out: impl Into<Option<Output>>) -> (String, String, u8) {
        let out = out.into().expect("a verb of the group answers");
        (out.stdout, out.stderr, out.code)
    }

    #[test]
    fn add_and_remove_print_the_catalogue_lines_and_the_codes_node_gives() {
        let fx = fixture(Locale::En);
        let file = &fx.setting.file;
        let serve = |args: &[&str]| serve(&words(args), &fx.setting);

        assert_eq!(
            said(serve(&["add", "./pkg"])),
            (
                format!("added demo → {root}/pkg to {file}\n", root = fx.root),
                String::new(),
                0
            )
        );
        assert_eq!(
            fs::read_to_string(file).unwrap(),
            format!("[plugins.demo]\nfrom = \"{}/pkg\"\n", fx.root)
        );
        assert_eq!(
            said(serve(&["add", "./pkg"])),
            (
                String::new(),
                format!("demo is already listed in {file}\n"),
                3
            )
        );
        assert_eq!(
            said(serve(&["remove", "demo"])),
            (format!("removed demo from {file}\n"), String::new(), 0)
        );
        assert_eq!(
            said(serve(&["remove", "demo"])),
            (String::new(), format!("demo is not listed in {file}\n"), 3)
        );
    }

    #[test]
    fn the_refusals_of_add_come_in_the_order_node_checks_them() {
        let fx = fixture(Locale::En);
        let serve = |args: &[&str]| said(serve(&words(args), &fx.setting));
        fs::create_dir_all(format!("{}/bare", fx.root)).unwrap();
        fs::write(
            format!("{}/bare/package.json", fx.root),
            r#"{"name":"bare"}"#,
        )
        .unwrap();
        fs::create_dir_all(format!("{}/no-entry", fx.root)).unwrap();
        fs::write(
            format!("{}/no-entry/package.json", fx.root),
            r#"{"tagents":{"apiVersion":1,"entry":"./gone.ts"}}"#,
        )
        .unwrap();

        // No package: usage, before anything is looked for.
        assert_eq!(
            serve(&["add"]),
            (
                String::new(),
                "missing required option <package-or-path>\n".to_owned(),
                2
            )
        );
        // Nothing at the path: an error. Something that is not a plugin, or has no entry: a refusal.
        let (out, err, code) = serve(&["add", "./nothing"]);
        assert_eq!((out.as_str(), code), ("", 1), "{err}");
        assert!(err.contains("nothing/package.json"), "{err}");
        assert_eq!(serve(&["add", "./bare"]).2, 3);
        assert_eq!(serve(&["add", "./no-entry"]).2, 3);
        // The name is checked after the package, and never writes.
        let (_, err, code) = serve(&["add", "./pkg", "--name", "bad name"]);
        assert_eq!(
            (err.as_str(), code),
            ("not a usable plugin name: bad name\n", 2)
        );
        assert_eq!(serve(&["add", "./nothing", "--name", "bad name"]).2, 1);
        assert!(!Path::new(&fx.setting.file).exists());
        // A good name wins over the default, and `--name=` is an empty one.
        assert_eq!(serve(&["add", "./pkg", "--name", "mine"]).2, 0);
        assert_eq!(serve(&["add", "./pkg", "--name="]).2, 2);
    }

    #[test]
    fn the_language_is_the_locales() {
        let fx = fixture(Locale::Ru);
        let (out, _, code) = said(serve(&words(&["add", "./pkg"]), &fx.setting));
        assert_eq!(code, 0);
        assert!(out.starts_with("demo → "), "{out}");
        assert_eq!(
            said(serve(&words(&["add"]), &fx.setting)).1,
            "не хватает обязательного параметра <package-or-path>\n"
        );
    }

    #[test]
    fn the_words_node_hosts_are_left_to_it_and_every_other_call_is_answered_without_a_write() {
        let fx = fixture(Locale::En);
        for args in [&[][..], &["list"], &["bogus"]] {
            assert_eq!(serve(&words(args), &fx.setting), None, "{args:?}");
        }
        for args in [
            &["add", "--bogus", "./pkg"][..],
            &["add", "./pkg", "--name"],
            &["add", "-n", "x", "./pkg"],
            &["add", "./pkg", "--json"],
            &["add", "pkg-from-nowhere"],
            &["remove", "--name", "x"],
            &["remove", "-x"],
            &["remove", "__proto__"],
        ] {
            let out = serve(&words(args), &fx.setting).unwrap_or_else(|| panic!("{args:?}"));
            assert!(out.stdout.is_empty() || out.code == 0, "{args:?}: {out:?}");
        }
        assert!(
            !Path::new(&fx.setting.file).exists()
                && !Path::new(&format!("{}/cfg", fx.root)).exists()
        );
    }

    /// The tree below `dir` as `path` lines, directories with a trailing slash, sorted.
    fn tree(dir: &str) -> Vec<String> {
        fn walk(dir: &Path, base: &Path, out: &mut Vec<String>) {
            let Ok(entries) = fs::read_dir(dir) else {
                return;
            };
            for entry in entries.map(|e| e.unwrap().path()) {
                let rel = entry.strip_prefix(base).unwrap().display().to_string();
                if entry.is_dir() {
                    out.push(format!("{rel}/"));
                    walk(&entry, base, out);
                } else {
                    out.push(rel);
                }
            }
        }
        let mut out = Vec::new();
        walk(Path::new(dir), Path::new(dir), &mut out);
        out.sort();
        out
    }

    const SCAFFOLD: [&str; 7] = [
        "README.md",
        "package.json",
        "src/",
        "src/plugin.ts",
        "test/",
        "test/plugin.test.ts",
        "tsconfig.json",
    ];

    /// `create` with the real write.
    fn create_here(fx: &Fixture, args: &[&str]) -> Output {
        let texts = Texts::load(fx.setting.locale).unwrap();
        create(&words(args), &fx.root, &fx.setting, &texts, &write_file)
    }

    #[test]
    fn new_writes_the_five_files_below_the_name_and_says_where() {
        let fx = fixture(Locale::En);
        let dir = format!("{}/demo", fx.root);
        assert_eq!(
            said(create_here(&fx, &["demo"])),
            (
                format!("wrote {dir} — install it with: tagents plugin add {dir}\n"),
                String::new(),
                0
            )
        );
        assert_eq!(tree(&dir), SCAFFOLD);
        let package = fs::read_to_string(format!("{dir}/package.json")).unwrap();
        assert!(
            package.contains(r#""@tagents/core": "link:../core""#),
            "{package}"
        );
    }

    #[test]
    fn new_takes_a_directory_from_dir_and_resolves_it_against_the_working_directory() {
        let fx = fixture(Locale::En);
        assert_eq!(said(create_here(&fx, &["x", "--dir", "a/b/../c"])).2, 0);
        assert_eq!(tree(&format!("{}/a/c", fx.root)), SCAFFOLD);
        assert!(!Path::new(&format!("{}/x", fx.root)).exists());
        // `--dir=` is an empty directory argument, which `path.resolve` reads as the working directory: here the one that holds `pkg`, so it is refused.
        let (_, err, code) = said(create_here(&fx, &["x", "--dir="]));
        assert_eq!(
            (err, code),
            (format!("{} exists and is not empty\n", fx.root), 3)
        );
    }

    #[test]
    fn new_accepts_an_empty_directory_and_refuses_one_that_holds_anything() {
        let fx = fixture(Locale::En);
        let empty = format!("{}/empty", fx.root);
        fs::create_dir(&empty).unwrap();
        assert_eq!(said(create_here(&fx, &["empty"])).2, 0);
        assert_eq!(tree(&empty), SCAFFOLD);

        for (kind, make) in [("a file", "f"), (".hidden", ".h"), ("a directory", "d/")] {
            let busy = format!(
                "{}/busy-{}",
                fx.root,
                make.trim_end_matches('/').trim_start_matches('.')
            );
            fs::create_dir(&busy).unwrap();
            if let Some(dir) = make.strip_suffix('/') {
                fs::create_dir(format!("{busy}/{dir}")).unwrap();
            } else {
                fs::write(format!("{busy}/{make}"), "mine").unwrap();
            }
            let before = tree(&busy);
            let name = busy.rsplit('/').next().unwrap();
            let (out, err, code) = said(create_here(&fx, &["x", "--dir", name]));
            assert_eq!(
                (out.as_str(), err.as_str(), code),
                ("", format!("{busy} exists and is not empty\n").as_str(), 3),
                "{kind}"
            );
            assert_eq!(tree(&busy), before, "{kind}: left alone");
        }
    }

    #[test]
    fn new_checks_its_arguments_in_the_order_node_does() {
        let fx = fixture(Locale::En);
        let serve = |args: &[&str]| said(create_here(&fx, args));
        assert_eq!(
            serve(&[]),
            (
                String::new(),
                "missing required option <name>\n".to_owned(),
                2
            )
        );
        assert_eq!(
            serve(&["--dir", "d"]),
            (
                String::new(),
                "missing required option <name>\n".to_owned(),
                2
            )
        );
        for bad in ["", ".a", "a b", "a/b", "é", "-"] {
            let (out, err, code) = serve(&["--", bad]);
            assert_eq!(
                (out.as_str(), err.as_str(), code),
                ("", format!("not a usable plugin name: {bad}\n").as_str(), 2),
                "{bad:?}"
            );
        }
        // A second positional is ignored.
        assert_eq!(serve(&["one", "two"]).2, 0);
        assert!(Path::new(&format!("{}/one/package.json", fx.root)).exists());
        assert!(!Path::new(&format!("{}/two", fx.root)).exists());
    }

    #[test]
    fn new_answers_in_the_language_of_the_locale() {
        let fx = fixture(Locale::Ru);
        let dir = format!("{}/demo", fx.root);
        assert_eq!(
            said(create_here(&fx, &["demo"])).0,
            format!("создан {dir} — подключить: tagents plugin add {dir}\n")
        );
        assert_eq!(
            said(create_here(&fx, &["demo"])).1,
            format!("{dir} существует и не пуст\n")
        );
    }

    /// `new demo --dir <target>` with the directories `existing` made first and the write number `fail_at` failing: the tree is as it was, and the call fails with the system's line.
    fn assert_a_failed_write_is_undone(fail_at: usize, existing: &[&str], target: &str) {
        let fx = fixture(Locale::En);
        let texts = Texts::load(Locale::En).unwrap();
        for dir in existing {
            fs::create_dir_all(format!("{}/{dir}", fx.root)).unwrap();
        }
        let before = tree(&fx.root);
        let calls = std::cell::Cell::new(0);
        // The step that fails has written its file by then, as a write that stops half way has.
        let put = |path: &str, body: &str| {
            let n = calls.get();
            calls.set(n + 1);
            write_file(path, body)?;
            if n == fail_at {
                return Err("ENOSPC: no space left on device, write".to_owned());
            }
            Ok(())
        };
        let out = create(
            &words(&["demo", "--dir", target]),
            &fx.root,
            &fx.setting,
            &texts,
            &put,
        );
        assert_eq!(
            (out.stderr.as_str(), out.code),
            ("ENOSPC: no space left on device, write\n", exit::ERROR),
            "{target} after {existing:?}, step {fail_at}"
        );
        assert_eq!(calls.get(), fail_at + 1, "it stopped at the failure");
        assert_eq!(
            tree(&fx.root),
            before,
            "{target} after {existing:?}, step {fail_at}"
        );
    }

    #[test]
    fn a_failed_write_leaves_the_tree_as_it_was_and_says_the_system_s_line() {
        for fail_at in 0..5 {
            // The target was there and empty: it stays, empty.
            assert_a_failed_write_is_undone(fail_at, &["demo"], "demo");
            // The target was not there: it is not there after, and neither are the directories made on the way to it.
            assert_a_failed_write_is_undone(fail_at, &[], "demo");
            assert_a_failed_write_is_undone(fail_at, &[], "deep/er/demo");
            // A directory on the way that was there stays.
            assert_a_failed_write_is_undone(fail_at, &["deep"], "deep/er/demo");
        }
    }

    #[test]
    fn what_node_words_with_the_system_s_text_is_answered_before_a_write() {
        let fx = fixture(Locale::En);
        // The target is a file, or a link to nowhere, or below a file: the system's text, or a parse error.
        fs::write(format!("{}/a-file", fx.root), "x").unwrap();
        std::os::unix::fs::symlink(
            format!("{}/nowhere", fx.root),
            format!("{}/dangling", fx.root),
        )
        .unwrap();
        for (args, code) in [
            (&["x", "--dir", "a-file"][..], exit::ERROR),
            (&["x", "--dir", "a-file/below"], exit::ERROR),
            (&["x", "--dir", "dangling"], exit::ERROR),
            (&["x", "--bogus"], exit::USAGE),
            (&["x", "--dir"], exit::USAGE),
            (&["x", "--dir", "-d"], exit::USAGE),
            (&["x", "-d", "y"], exit::USAGE),
            (&["x", "--name", "y"], exit::USAGE),
        ] {
            let out = create_here(&fx, args);
            assert_eq!(out.code, code, "{args:?}");
            assert!(
                out.stderr.ends_with('\n') && out.stdout.is_empty(),
                "{args:?}"
            );
        }
        let mut no_core = fixture(Locale::En);
        no_core.setting.core_dir = Err("no core".to_owned());
        let out = create_here(&no_core, &["demo"]);
        assert_eq!(
            (out.stderr.as_str(), out.code),
            ("tagents-core: no core\n", exit::ERROR)
        );
        assert!(!Path::new(&format!("{}/demo", no_core.root)).exists());
        // What is refused is refused without it: nothing is written and nothing needs the root.
        assert_eq!(said(create_here(&no_core, &["a b"])).2, 2);
    }
}
