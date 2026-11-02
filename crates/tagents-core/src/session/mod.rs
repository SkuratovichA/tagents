//! `tagents-core session …`: the verbs that drive a headless Claude Code session, served as the node CLI's `session()` of `packages/core/src/cli/main.ts` serves them.
//!
//! A call answers only what it can prove identical to node's and hands every other call to the node CLI (`None`, before anything is read, written or started): a verb that stays with node, a verb nobody knows, an argument outside the grammar of `args`.

use crate::sessions::Output;

/// The verbs this module serves, as the words after the program name. `tagents-core --spec` prints them and a test pins them to `impl: "rust"` in the data file.
pub const VERBS: &[&[&str]] = &[];

/// `session(argv)` of the node CLI for the verbs served here: `argv` is the words after `session`. `None` hands the call to node.
pub fn run(_argv: &[String]) -> Option<Output> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_group_hands_every_call_to_node_while_no_verb_is_served() {
        for argv in [
            &[][..],
            &["bogus"],
            &["open"],
            &["open", "--cwd", "/w"],
            &["list"],
            &["last", "s-1"],
            &["prompt", "s-1", "text"],
            &["abort", "s-1"],
        ] {
            let argv: Vec<String> = argv.iter().map(|a| (*a).to_owned()).collect();
            assert_eq!(run(&argv), None, "{argv:?}");
        }
        assert!(VERBS.is_empty());
    }
}
