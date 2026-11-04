//! `tagents-core session …`: the verbs that drive a headless Claude Code session, served as the node CLI's `session()` of `packages/core/src/cli/main.ts` serves them.
//!
//! Every call is answered here: a verb nobody knows (or none) prints `unknownCommand` and the usage line, and an argument outside a verb's grammar prints the parser's own error, both with the usage exit code.

pub mod abort;
#[cfg(target_os = "macos")]
pub mod awake;
pub mod command;
pub mod outcome;
pub mod prompt;
pub mod read;
pub mod reference;
pub mod spawn;
pub mod stream;
pub mod turn;

use crate::sessions::{self, Output, exit};
use read::Setting;

/// The verbs this module serves, as the words after the program name. `tagents-core --spec` prints them and a test pins them to `impl: "rust"` in the data file.
pub const VERBS: &[&[&str]] = &[
    &["session", "open"],
    &["session", "prompt"],
    &["session", "last"],
    &["session", "list"],
    &["session", "abort"],
];

/// `session(argv)` of the node CLI: `argv` is the words after `session`.
pub fn run(argv: &[String]) -> Output {
    run_in(argv, &Setting::current())
}

fn run_in(argv: &[String], setting: &Setting) -> Output {
    let texts = match sessions::texts(setting.locale) {
        Ok(texts) => texts,
        Err(out) => return out,
    };
    let serve = match argv.first().map(String::as_str) {
        Some("open") => read::open,
        Some("list") => read::list,
        Some("last") => read::last,
        Some("prompt") => prompt::prompt,
        Some("abort") => abort::abort,
        verb => {
            let command = format!("session {}", verb.unwrap_or_default());
            let command = command.trim();
            return Output::line(
                exit::USAGE,
                &format!(
                    "{}\n{}",
                    texts.t("unknownCommand", &[("command", command)]),
                    texts.t("usage", &[])
                ),
            );
        }
    };
    serve(&argv[1..], setting, &texts)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::messages::Locale;

    fn argv(words: &[&str]) -> Vec<String> {
        words.iter().map(|a| (*a).to_owned()).collect()
    }

    #[test]
    fn the_group_serves_its_verbs_and_words_the_rest() {
        let setting = Setting {
            cwd: Some("/base".to_owned()),
            state_dir: "/no/such/state".to_owned(),
            locale: Locale::En,
        };
        for (words, command) in [
            (&[][..], "session\n"),
            (&["bogus"], "session bogus\n"),
            (&["--help"], "session --help\n"),
        ] {
            let out = run_in(&argv(words), &setting);
            assert_eq!(out.code, exit::USAGE, "{words:?}");
            assert!(out.stdout.is_empty(), "{words:?}");
            assert!(
                out.stderr.contains(command.trim_end()),
                "{words:?}: {}",
                out.stderr
            );
            assert!(out.stderr.lines().count() >= 2, "{words:?}: {}", out.stderr);
        }
        for words in [
            &["prompt", "--unknown"][..],
            &["open", "--unknown"],
            &["list", "extra"],
        ] {
            let out = run_in(&argv(words), &setting);
            assert_eq!(out.code, exit::USAGE, "{words:?}");
        }
        let list = run_in(&argv(&["list"]), &setting);
        assert_eq!(list.stdout, "[]\n");
        let open = run_in(&argv(&["open", "--cwd", "/w"]), &setting);
        assert!(open.stdout.contains("\"cwd\": \"/w\""), "{}", open.stdout);
        let last = run_in(&argv(&["last", "nothing"]), &setting);
        assert_eq!(last.code, 1);
    }
}
