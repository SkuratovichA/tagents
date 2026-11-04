//! `util.parseArgs` of node with `strict: true`, for options that take a text, take several, or are a flag and have no short form: what every verb with options reads its command line with, whether it takes positionals or not.
//!
//! The errors are the ones node throws, in its words, at the first word that earns one: an option that is not listed, a text option with nothing after it, a text option whose next word looks like an option (`--idle -5` is refused, `--idle=-5` is not), a flag given a value, and, where the verb takes no positionals, any positional, which includes everything after a `--`. A word that starts with one dash and has a second character is a short option, which no verb here has: `-abc` is the unknown option `-a`, node reading a short group one UTF-16 unit at a time. A lone `-` is a positional. A text option takes the word after it whatever it is, so `--idle --` names `--` as the value of `--idle` and is refused as ambiguous. Where the verb takes positionals, an unknown option's error carries node's hint about `--`.

use std::collections::HashMap;
use std::ffi::{OsStr, OsString};
use std::fmt;
use std::os::unix::ffi::{OsStrExt, OsStringExt};

/// What an option is: it takes a text (a repeated one keeps the last), it takes a text and keeps every one given, or it is there or not.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Text,
    Many,
    Flag,
}

/// The options a verb has, by long name (without the dashes).
pub type Options = [(&'static str, Kind)];

/// What node's `parseArgs` throws, as its message.
#[derive(Debug, PartialEq, Eq)]
pub struct ParseError(String);

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// The values of a command line that was read without an error.
#[derive(Debug, Default)]
pub struct Parsed {
    texts: HashMap<&'static str, Vec<OsString>>,
    flags: Vec<&'static str>,
    positionals: Vec<OsString>,
}

impl Parsed {
    /// The value of a text option: the last one given.
    pub fn text(&self, name: &str) -> Option<&OsStr> {
        self.texts.get(name)?.last().map(OsString::as_os_str)
    }

    /// Every value of an option, in the order given.
    pub fn texts(&self, name: &str) -> impl Iterator<Item = &OsStr> {
        self.texts
            .get(name)
            .into_iter()
            .flatten()
            .map(OsString::as_os_str)
    }

    pub fn flag(&self, name: &str) -> bool {
        self.flags.contains(&name)
    }

    pub fn positionals(&self) -> &[OsString] {
        &self.positionals
    }

    /// `text` as a `&str`, for a command line that is UTF-8 already.
    pub fn value(&self, name: &str) -> Option<&str> {
        self.text(name)?.to_str()
    }

    /// `texts` as `&str`s, for a command line that is UTF-8 already.
    pub fn values(&self, name: &str) -> Vec<&str> {
        self.texts(name).filter_map(OsStr::to_str).collect()
    }

    /// `positionals` as `&str`s, for a command line that is UTF-8 already.
    pub fn words(&self) -> Vec<&str> {
        self.positionals
            .iter()
            .filter_map(|word| word.to_str())
            .collect()
    }
}

fn lossy(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

/// A word `parseArgs` takes for an option rather than a value: it starts with a dash and has a second character.
fn looks_like_an_option(word: &[u8]) -> bool {
    word.len() > 1 && word[0] == b'-'
}

/// What a verb reads: its options and whether it takes positionals.
#[derive(Clone, Copy, Debug)]
pub struct Grammar {
    pub options: &'static Options,
    pub positionals: bool,
}

impl Grammar {
    pub fn parse<S: AsRef<OsStr>>(&self, args: &[S]) -> Result<Parsed, ParseError> {
        read(args, self.options, self.positionals)
    }
}

/// The command line `args` against `options`, for a verb that takes no positionals.
pub fn parse<S: AsRef<OsStr>>(args: &[S], options: &Options) -> Result<Parsed, ParseError> {
    read(args, options, false)
}

/// The command line `args` against `options`, for a verb that takes positionals.
pub fn parse_with_positionals<S: AsRef<OsStr>>(
    args: &[S],
    options: &Options,
) -> Result<Parsed, ParseError> {
    read(args, options, true)
}

fn read<S: AsRef<OsStr>>(
    args: &[S],
    options: &Options,
    positionals: bool,
) -> Result<Parsed, ParseError> {
    let mut parsed = Parsed::default();
    let mut words = args.iter().map(AsRef::as_ref);
    while let Some(word) = words.next() {
        let bytes = word.as_bytes();
        if bytes == b"--" {
            for rest in words.by_ref() {
                if !positionals {
                    return Err(positional_error(rest.as_bytes()));
                }
                parsed.positionals.push(rest.to_owned());
            }
            return Ok(parsed);
        }
        let Some(long) = bytes.strip_prefix(b"--") else {
            if looks_like_an_option(bytes) {
                return Err(unknown(&short(bytes), positionals));
            }
            if !positionals {
                return Err(positional_error(bytes));
            }
            parsed.positionals.push(word.to_owned());
            continue;
        };
        // `--name`, `--name=value`: a name of nothing (`--=x`) makes the whole word the name.
        let (name, inline) = match long.iter().position(|b| *b == b'=') {
            Some(at) if at > 0 => (&long[..at], Some(&long[at + 1..])),
            _ => (long, None),
        };
        let raw = lossy(&bytes[..2 + name.len()]);
        let Some((listed, kind)) = options
            .iter()
            .find(|(listed, _)| listed.as_bytes() == name)
            .copied()
        else {
            return Err(unknown(&raw, positionals));
        };
        match (kind, inline) {
            (Kind::Flag, Some(_)) => {
                return Err(ParseError(format!(
                    "Option '--{listed}' does not take an argument"
                )));
            }
            (Kind::Flag, None) => {
                if !parsed.flags.contains(&listed) {
                    parsed.flags.push(listed);
                }
            }
            (Kind::Text | Kind::Many, Some(value)) => {
                keep(
                    &mut parsed,
                    listed,
                    kind,
                    OsString::from_vec(value.to_vec()),
                );
            }
            (Kind::Text | Kind::Many, None) => {
                let Some(next) = words.next() else {
                    return Err(ParseError(format!(
                        "Option '--{listed} <value>' argument missing"
                    )));
                };
                if looks_like_an_option(next.as_bytes()) {
                    return Err(ParseError(format!(
                        "Option '{raw}' argument is ambiguous.\nDid you forget to specify the option argument for '{raw}'?\nTo specify an option argument starting with a dash use '{raw}=-XYZ'."
                    )));
                }
                keep(&mut parsed, listed, kind, next.to_owned());
            }
        }
    }
    Ok(parsed)
}

fn keep(parsed: &mut Parsed, name: &'static str, kind: Kind, value: OsString) {
    let values = parsed.texts.entry(name).or_default();
    if kind == Kind::Text {
        values.clear();
    }
    values.push(value);
}

/// The short option a word names: a dash and the first UTF-16 unit after it, a half of a pair printing as U+FFFD.
fn short(bytes: &[u8]) -> String {
    let text = lossy(&bytes[1..]);
    let first = text.chars().next().unwrap_or(char::REPLACEMENT_CHARACTER);
    let unit = if first.len_utf16() == 2 {
        char::REPLACEMENT_CHARACTER
    } else {
        first
    };
    format!("-{unit}")
}

fn unknown(raw: &str, positionals: bool) -> ParseError {
    if positionals {
        ParseError(format!(
            "Unknown option '{raw}'. To specify a positional argument starting with a '-', place it at the end of the command after '--', as in '-- \"{raw}\""
        ))
    } else {
        ParseError(format!("Unknown option '{raw}'"))
    }
}

fn positional_error(word: &[u8]) -> ParseError {
    ParseError(format!(
        "Unexpected argument '{}'. This command does not take positional arguments",
        lossy(word)
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plugin::{ADD, NEW, REMOVE};
    use crate::session::prompt::PROMPT;
    use crate::session::read::{LIST, OPEN};
    use tagents_spec::{OptionKind, Spec};

    const OPTIONS: &Options = &[
        ("idle", Kind::Text),
        ("foreground", Kind::Flag),
        ("socket", Kind::Text),
        ("state", Kind::Many),
    ];

    fn read(words: &[&str]) -> Result<Parsed, String> {
        parse(words, OPTIONS).map_err(|e| e.to_string())
    }

    fn read_positionals(words: &[&str]) -> Result<Parsed, String> {
        parse_with_positionals(words, OPTIONS).map_err(|e| e.to_string())
    }

    fn refused(words: &[&str]) -> String {
        read(words).expect_err("refused")
    }

    fn refused_with_positionals(words: &[&str]) -> String {
        read_positionals(words).expect_err("refused")
    }

    #[test]
    fn what_is_given_is_read_and_the_last_text_wins() {
        let parsed = read(&["--idle", "5", "--foreground", "--socket=/a", "--idle=6"]).unwrap();
        assert_eq!(parsed.text("idle"), Some(OsStr::new("6")));
        assert_eq!(parsed.text("socket"), Some(OsStr::new("/a")));
        assert!(parsed.flag("foreground"));
        assert!(!read(&[]).unwrap().flag("foreground"));
        assert_eq!(
            read(&["--idle", "-"]).unwrap().text("idle"),
            Some(OsStr::new("-"))
        );
        assert_eq!(
            read(&["--idle="]).unwrap().text("idle"),
            Some(OsStr::new(""))
        );
        assert!(read(&["--foreground", "--"]).is_ok());
    }

    #[test]
    fn a_many_option_keeps_every_value_in_order() {
        let parsed = read(&["--state", "a", "--state=b", "--idle", "1"]).unwrap();
        assert_eq!(parsed.values("state"), ["a", "b"]);
        assert_eq!(parsed.value("state"), Some("b"));
        assert!(read(&[]).unwrap().values("state").is_empty());
    }

    #[test]
    fn positionals_are_kept_where_the_verb_takes_them() {
        let parsed =
            read_positionals(&["a", "--idle", "5", "-", "b", "--", "--idle", "-x"]).unwrap();
        assert_eq!(parsed.words(), ["a", "-", "b", "--idle", "-x"]);
        assert_eq!(parsed.value("idle"), Some("5"));
        assert!(read_positionals(&[]).unwrap().words().is_empty());
        assert_eq!(read_positionals(&[""]).unwrap().words(), [""]);
    }

    #[test]
    fn an_error_is_worded_as_node_words_it() {
        assert_eq!(refused(&["--unknown=1"]), "Unknown option '--unknown'");
        assert_eq!(refused(&["-i", "5"]), "Unknown option '-i'");
        assert_eq!(refused(&["-é"]), "Unknown option '-é'");
        assert_eq!(refused(&["-abc"]), "Unknown option '-a'");
        assert_eq!(refused(&["-😀"]), "Unknown option '-\u{FFFD}'");
        assert_eq!(refused(&["--=x"]), "Unknown option '--=x'");
        assert_eq!(
            refused(&["--idle"]),
            "Option '--idle <value>' argument missing"
        );
        assert_eq!(
            refused(&["--foreground=true"]),
            "Option '--foreground' does not take an argument"
        );
        assert_eq!(
            refused(&["--socket", "--idle"]),
            "Option '--socket' argument is ambiguous.\nDid you forget to specify the option argument for '--socket'?\nTo specify an option argument starting with a dash use '--socket=-XYZ'."
        );
        for word in ["extra", "-", ""] {
            assert_eq!(
                refused(&[word]),
                format!(
                    "Unexpected argument '{word}'. This command does not take positional arguments"
                )
            );
        }
        assert_eq!(
            refused(&["--", "--idle"]),
            "Unexpected argument '--idle'. This command does not take positional arguments"
        );
    }

    #[test]
    fn an_unknown_option_of_a_verb_with_positionals_carries_the_hint() {
        let hint = |name: &str| {
            format!(
                "Unknown option '{name}'. To specify a positional argument starting with a '-', place it at the end of the command after '--', as in '-- \"{name}\""
            )
        };
        assert_eq!(refused_with_positionals(&["--zz"]), hint("--zz"));
        assert_eq!(refused_with_positionals(&["--zz=1"]), hint("--zz"));
        assert_eq!(refused_with_positionals(&["-x"]), hint("-x"));
        assert_eq!(refused_with_positionals(&["-abc"]), hint("-a"));
        assert_eq!(refused_with_positionals(&["--=x"]), hint("--=x"));
        assert_eq!(
            refused_with_positionals(&["--idle"]),
            "Option '--idle <value>' argument missing"
        );
    }

    #[test]
    fn the_first_word_that_earns_an_error_is_the_one_told() {
        assert_eq!(
            refused(&["--foreground=x", "--idle", "abc", "extra"]),
            "Option '--foreground' does not take an argument"
        );
        assert_eq!(
            refused(&["extra", "--unknown"]),
            "Unexpected argument 'extra'. This command does not take positional arguments"
        );
    }

    /// The tables are copies of the `options` in `spec/cli/tagents-core.json`, as `PARSED` of `packages/core/src/cli/spec.ts` is on the node side, where `sameOptions` holds it to the file.
    #[test]
    fn every_grammar_is_the_options_of_its_command_in_the_data_file() {
        let spec = Spec::bundled().unwrap();
        for (verb, grammar) in [
            ("session open", OPEN),
            ("session list", LIST),
            ("session prompt", PROMPT),
            ("plugin add", ADD),
            ("plugin remove", REMOVE),
            ("plugin new", NEW),
        ] {
            let command = spec
                .commands
                .iter()
                .find(|command| command.path.join(" ") == verb)
                .unwrap_or_else(|| panic!("{verb} is not in the data file"));
            let wanted: Vec<(&str, OptionKind, bool)> = command
                .options
                .iter()
                .map(|(name, shape)| (name.as_str(), shape.kind, shape.multiple.unwrap_or(false)))
                .collect();
            let mut read: Vec<(&str, OptionKind, bool)> = grammar
                .options
                .iter()
                .map(|(name, kind)| match kind {
                    Kind::Text => (*name, OptionKind::String, false),
                    Kind::Many => (*name, OptionKind::String, true),
                    Kind::Flag => (*name, OptionKind::Boolean, false),
                })
                .collect();
            read.sort_by_key(|(name, _, _)| *name);
            assert_eq!(read, wanted, "{verb}");
            assert_eq!(
                grammar.positionals,
                !command.positionals.is_empty(),
                "{verb}: positionals"
            );
        }
    }
}
