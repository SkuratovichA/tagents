//! `tagents-core session …`: the verbs that drive a headless Claude Code session, served as the node CLI's `session()` of `packages/core/src/cli/main.ts` serves them.
//!
//! A call answers only what it can prove identical to node's and hands every other call to the node CLI (`None`, before anything is read, written or started): a verb that stays with node, a verb nobody knows, an argument outside the grammar of `args`.

#[cfg(target_os = "macos")]
pub mod awake;
pub mod command;
pub mod outcome;
pub mod read;
pub mod reference;
pub mod spawn;
pub mod stream;
pub mod turn;

use crate::{messages::Texts, sessions::Output};
use read::Setting;

/// The verbs this module serves, as the words after the program name. `tagents-core --spec` prints them and a test pins them to `impl: "rust"` in the data file.
pub const VERBS: &[&[&str]] = &[
    &["session", "open"],
    &["session", "last"],
    &["session", "list"],
];

/// `session(argv)` of the node CLI for the verbs served here: `argv` is the words after `session`. `None` hands the call to node.
pub fn run(argv: &[String]) -> Option<Output> {
    let setting = Setting::current()?;
    run_in(argv, &setting)
}

fn run_in(argv: &[String], setting: &Setting) -> Option<Output> {
    let (verb, args) = argv.split_first()?;
    let serve = match verb.as_str() {
        "open" => read::open,
        "list" => read::list,
        "last" => read::last,
        _ => return None,
    };
    serve(args, setting, &Texts::load(setting.locale).ok()?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::messages::Locale;

    fn argv(words: &[&str]) -> Vec<String> {
        words.iter().map(|a| (*a).to_owned()).collect()
    }

    #[test]
    fn the_group_serves_the_three_read_verbs_and_hands_over_the_rest() {
        let setting = Setting {
            cwd: "/base".to_owned(),
            state_dir: "/no/such/state".to_owned(),
            locale: Locale::En,
        };
        for words in [
            &[][..],
            &["bogus"],
            &["prompt", "s-1", "text"],
            &["abort", "s-1"],
            &["open", "--unknown"],
            &["list", "extra"],
        ] {
            assert_eq!(run_in(&argv(words), &setting), None, "{words:?}");
        }
        let list = run_in(&argv(&["list"]), &setting).unwrap();
        assert_eq!(list.stdout, "[]\n");
        let open = run_in(&argv(&["open", "--cwd", "/w"]), &setting).unwrap();
        assert!(open.stdout.contains("\"cwd\": \"/w\""), "{}", open.stdout);
        let last = run_in(&argv(&["last", "nothing"]), &setting).unwrap();
        assert_eq!(last.code, 1);
    }
}
