//! `tagents-core plugin add` and `plugin remove`: the verbs of the plugin group that this binary serves.
//!
//! Each verb answers only what it can prove identical to the node CLI and hands every other call to it (`None`, before anything is written): a verb that stays with node (`list`, bare `plugin`, a word nobody knows), an argument outside the grammar below, a package the resolution cannot prove, a config that cannot be edited, and any I/O error. The texts it does print are the catalogue's, in `spec/cli/messages.json`.
//!
//! The grammar has no error case. A positional is an argument that does not start with `-` (a lone `-` included) and `--` ends the options; `add` takes `--name V` when `V` does not start with `-` and `--name=V` for any `V`, the last one wins; `remove` takes no option. Any other argument that starts with `-` is node's to word, since `util.parseArgs` words its own errors.

pub mod config;
pub mod resolve;
pub mod scaffold;

use config::{Added, Removed};
use resolve::Failure;

use crate::{
    host::config_dir,
    messages::{Locale, Texts},
    node,
    sessions::{Output, exit},
};

/// The verbs this module serves, as the words after the program name. `tagents-core --spec` prints them and a test pins them to `impl: "rust"` in the data file.
pub const VERBS: &[&[&str]] = &[&["plugin", "add"], &["plugin", "remove"]];

/// The config file's name inside the config directory (`CONFIG_BASENAME` of `packages/core/src/host.ts`).
const CONFIG_BASENAME: &str = "config.toml";

/// A call this code will not answer: the node CLI answers it, with the same arguments, before anything has been written.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HandOver;

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
    /// `process.cwd()`.
    pub cwd: String,
    /// `configFile()`.
    pub file: String,
    pub locale: Locale,
    pub env: resolve::Env,
}

impl Setting {
    /// The setting of this process. `None` when the working directory is gone or is not UTF-8: node would fail on the one and read the other with U+FFFD.
    pub fn current() -> Option<Setting> {
        let cwd = std::env::current_dir()
            .ok()?
            .into_os_string()
            .into_string()
            .ok()?;
        Some(Setting {
            cwd,
            file: node::join(&config_dir(), CONFIG_BASENAME),
            locale: Locale::of(std::env::var("TAGENTS_LOCALE").ok().as_deref()),
            env: resolve::Env::current(),
        })
    }
}

/// `plugin(argv)` of the node CLI for the verbs served here: `argv` is the words after `plugin`. `None` hands the call to node.
pub fn run(argv: &[String]) -> Option<Output> {
    serve(argv, &Setting::current()?)
}

/// `run` in a given setting.
pub fn serve(argv: &[String], setting: &Setting) -> Option<Output> {
    let (verb, args) = argv.split_first()?;
    // The bundled catalogue is checked by a test, so it loads; if it ever did not, node words the call.
    let texts = Texts::load(setting.locale).ok()?;
    match verb.as_str() {
        "add" => add(args, setting, &texts),
        "remove" => remove(args, setting, &texts),
        _ => None,
    }
}

/// The arguments of a verb read by the grammar above.
#[derive(Debug, PartialEq, Eq)]
struct Parsed<'a> {
    positionals: Vec<&'a str>,
    name: Option<&'a str>,
}

/// `args` by the grammar; `None` for an argument it does not read. `takes_name` is `add`.
fn parse(args: &[String], takes_name: bool) -> Option<Parsed<'_>> {
    let mut parsed = Parsed {
        positionals: Vec::new(),
        name: None,
    };
    let mut rest = args.iter().map(String::as_str);
    while let Some(arg) = rest.next() {
        if arg == "--" {
            parsed.positionals.extend(rest.by_ref());
        } else if !arg.starts_with('-') || arg == "-" {
            parsed.positionals.push(arg);
        } else if takes_name && arg == "--name" {
            parsed.name = Some(rest.next().filter(|value| !value.starts_with('-'))?);
        } else {
            parsed.name = Some(arg.strip_prefix("--name=").filter(|_| takes_name)?);
        }
    }
    Some(parsed)
}

/// `NAME` of `cli/plugin.ts`: a config key and a directory name, so it is typeable and greppable.
fn is_name(name: &str) -> bool {
    let mut bytes = name.bytes();
    bytes.next().is_some_and(|b| b.is_ascii_alphanumeric())
        && bytes.all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// A line on stderr and an exit code that says it was not done.
fn failure(code: u8, line: String) -> Output {
    Output {
        code,
        ..Output::fail(format!("{line}\n"))
    }
}

/// `add(argv)` of `cli/plugin.ts`.
fn add(args: &[String], setting: &Setting, texts: &Texts) -> Option<Output> {
    let parsed = parse(args, true)?;
    let Some(spec) = parsed.positionals.first() else {
        return Some(failure(
            exit::USAGE,
            texts.t("missingOption", &[("option", "<package-or-path>")]),
        ));
    };

    let package = match resolve::resolve(spec, &setting.cwd, &setting.env) {
        Ok(package) => package,
        Err(Failure::HandOver) => return None,
        Err(Failure::NotFound(detail)) => {
            return Some(failure(
                exit::ERROR,
                texts.t("pluginUnresolved", &[("spec", &detail)]),
            ));
        }
        Err(Failure::NoEntry(detail)) => {
            return Some(failure(
                exit::REFUSED,
                texts.t("pluginNoEntry", &[("file", &detail)]),
            ));
        }
        Err(Failure::BadManifest(detail)) => {
            return Some(failure(
                exit::REFUSED,
                texts.t("pluginBadManifest", &[("file", &detail)]),
            ));
        }
    };

    let name = parsed
        .name
        .map_or_else(|| default_plugin_name(&package.package_name), str::to_owned);
    if !is_name(&name) {
        return Some(failure(
            exit::USAGE,
            texts.t("pluginBadName", &[("name", &name)]),
        ));
    }

    let file = &setting.file;
    match config::add(file, &name, &package.from).ok()? {
        Added::Exists => Some(failure(
            exit::REFUSED,
            texts.t("pluginExists", &[("name", &name), ("file", file)]),
        )),
        Added::Written => Some(Output::out(format!(
            "{}\n",
            texts.t(
                "pluginAdded",
                &[("name", &name), ("from", &package.from), ("file", file)]
            )
        ))),
    }
}

/// `remove(argv)` of `cli/plugin.ts`.
fn remove(args: &[String], setting: &Setting, texts: &Texts) -> Option<Output> {
    let parsed = parse(args, false)?;
    let Some(name) = parsed.positionals.first() else {
        return Some(failure(
            exit::USAGE,
            texts.t("missingOption", &[("option", "<name>")]),
        ));
    };
    let file = &setting.file;
    match config::remove(file, name).ok()? {
        Removed::Absent => Some(failure(
            exit::REFUSED,
            texts.t("pluginNotListed", &[("name", name), ("file", file)]),
        )),
        Removed::Written => Some(Output::out(format!(
            "{}\n",
            texts.t("pluginRemoved", &[("name", name), ("file", file)])
        ))),
    }
}

#[cfg(test)]
mod tests {
    use std::{fs, path::Path};

    use super::*;
    use crate::testing::Scratch;

    fn words(args: &[&str]) -> Vec<String> {
        args.iter().map(|a| (*a).to_owned()).collect()
    }

    fn parsed<'a>(positionals: &[&'a str], name: Option<&'a str>) -> Option<Parsed<'a>> {
        Some(Parsed {
            positionals: positionals.to_vec(),
            name,
        })
    }

    #[test]
    fn the_grammar_reads_positionals_and_name_and_nothing_else() {
        for (args, takes_name, want) in [
            (&[][..], true, parsed(&[], None)),
            (&["pkg"], true, parsed(&["pkg"], None)),
            (&["pkg", "--name", "x"], true, parsed(&["pkg"], Some("x"))),
            (&["--name", "x", "pkg"], true, parsed(&["pkg"], Some("x"))),
            (&["--name=x", "pkg"], true, parsed(&["pkg"], Some("x"))),
            (&["--name=", "pkg"], true, parsed(&["pkg"], Some(""))),
            (&["--name=-x", "pkg"], true, parsed(&["pkg"], Some("-x"))),
            (
                &["--name", "a", "--name=b", "p"],
                true,
                parsed(&["p"], Some("b")),
            ),
            (
                &["--name=a", "--name", "b", "p"],
                true,
                parsed(&["p"], Some("b")),
            ),
            (&["a", "b", "c"], true, parsed(&["a", "b", "c"], None)),
            (&["-"], true, parsed(&["-"], None)),
            (
                &["--", "-x", "--name", "--"],
                true,
                parsed(&["-x", "--name", "--"], None),
            ),
            (
                &["p", "--", "--name=x"],
                true,
                parsed(&["p", "--name=x"], None),
            ),
            (&["x", "y"], false, parsed(&["x", "y"], None)),
            (&["--", "--name"], false, parsed(&["--name"], None)),
            // What node words itself.
            (&["--name"], true, None),
            (&["p", "--name"], true, None),
            (&["--name", "-x"], true, None),
            (&["--name", "-"], true, None),
            (&["--name", "--other"], true, None),
            (&["--nam", "x"], true, None),
            (&["--name-x", "p"], true, None),
            (&["--json"], true, None),
            (&["-n", "x"], true, None),
            (&["-abc"], true, None),
            (&["--no-name", "p"], true, None),
            (&["--name=x"], false, None),
            (&["--name", "x"], false, None),
            (&["-x"], false, None),
        ] {
            assert_eq!(
                parse(&words(args), takes_name),
                want,
                "{args:?} (takes_name: {takes_name})"
            );
        }
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
    fn the_verbs_are_add_and_remove() {
        assert_eq!(VERBS, [&["plugin", "add"][..], &["plugin", "remove"]]);
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
            cwd: root.clone(),
            file: format!("{root}/cfg/config.toml"),
            locale,
            env: resolve::Env {
                home: format!("{root}/home"),
                node_flags: false,
            },
        };
        Fixture {
            _scratch: scratch,
            root,
            setting,
        }
    }

    fn said(out: Option<Output>) -> (String, String, u8) {
        let out = out.expect("served, not handed over");
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
    fn what_node_words_is_handed_over_and_nothing_is_written() {
        let fx = fixture(Locale::En);
        for args in [
            &[][..],
            &["list"],
            &["new", "x"],
            &["bogus"],
            &["add", "--bogus", "./pkg"],
            &["add", "./pkg", "--name"],
            &["add", "-n", "x", "./pkg"],
            &["add", "./pkg", "--json"],
            &["add", "pkg-from-nowhere"],
            &["remove", "--name", "x"],
            &["remove", "-x"],
            &["remove", "__proto__"],
        ] {
            assert_eq!(serve(&words(args), &fx.setting), None, "{args:?}");
        }
        assert!(
            !Path::new(&fx.setting.file).exists()
                && !Path::new(&format!("{}/cfg", fx.root)).exists()
        );
    }
}
