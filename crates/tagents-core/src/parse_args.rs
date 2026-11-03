//! `util.parseArgs` of node with `strict: true` and `allowPositionals: false`, for options that take a text or are a flag and have no short form: what a verb that has options and no positionals reads its command line with.
//!
//! The errors are the ones node throws, in its words, at the first word that earns one: an option that is not listed, a text option with nothing after it, a text option whose next word looks like an option (`--idle -5` is refused, `--idle=-5` is not), a flag given a value, and any positional, which includes everything after a `--`. A lone `-` and a word like `-abc` are positionals, because no short option exists that they could be. A text option takes the word after it whatever it is, so `--idle --` names `--` as the value of `--idle` and is refused as ambiguous.
//!
//! `crate::args` is the other reader of a command line, for a verb that hands the node CLI a call it does not read: it words no error, takes UTF-8 text only and reads positionals. What it reads is read here the same way, which a test in this file holds.

use std::collections::HashMap;
use std::ffi::{OsStr, OsString};
use std::fmt;
use std::os::unix::ffi::{OsStrExt, OsStringExt};

use crate::js;

/// What an option is: it takes a text, or it is there or not.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Text,
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

/// The values of a command line that was read without an error. A text option given twice has its last value, as node's does.
#[derive(Debug, Default)]
pub struct Parsed {
    texts: HashMap<&'static str, OsString>,
    flags: Vec<&'static str>,
}

impl Parsed {
    pub fn text(&self, name: &str) -> Option<&OsStr> {
        self.texts.get(name).map(OsString::as_os_str)
    }

    pub fn flag(&self, name: &str) -> bool {
        self.flags.contains(&name)
    }
}

fn lossy(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

/// A word `parseArgs` takes for an option rather than a value: it starts with a dash and has a second character.
fn looks_like_an_option(word: &[u8]) -> bool {
    word.len() > 1 && word[0] == b'-'
}

/// The command line `args` against `options`.
pub fn parse(args: &[OsString], options: &Options) -> Result<Parsed, ParseError> {
    let mut parsed = Parsed::default();
    let mut words = args.iter();
    while let Some(word) = words.next() {
        let bytes = word.as_bytes();
        if bytes == b"--" {
            return match words.next() {
                Some(positional) => Err(positional_error(positional.as_bytes())),
                None => Ok(parsed),
            };
        }
        // `--name`, `--name=value`: a name of nothing (`--=x`) is a name that is not listed.
        let Some(long) = bytes.strip_prefix(b"--").filter(|rest| !rest.is_empty()) else {
            // `-x`: a dash and one UTF-16 unit, which is a short option that no verb here has.
            if bytes.first() == Some(&b'-') && js::len16(&lossy(&bytes[1..])) == 1 {
                return Err(unknown(bytes));
            }
            return Err(positional_error(bytes));
        };
        let (name, inline) = match long.iter().position(|b| *b == b'=') {
            Some(at) => (&long[..at], Some(&long[at + 1..])),
            None => (long, None),
        };
        let raw = &bytes[..2 + name.len()];
        let Some((listed, kind)) = options
            .iter()
            .find(|(listed, _)| listed.as_bytes() == name)
            .copied()
        else {
            return Err(unknown(raw));
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
            (Kind::Text, Some(value)) => {
                parsed
                    .texts
                    .insert(listed, OsString::from_vec(value.to_vec()));
            }
            (Kind::Text, None) => {
                let Some(next) = words.next() else {
                    return Err(ParseError(format!(
                        "Option '--{listed} <value>' argument missing"
                    )));
                };
                if looks_like_an_option(next.as_bytes()) {
                    let raw = lossy(raw);
                    return Err(ParseError(format!(
                        "Option '{raw}' argument is ambiguous.\nDid you forget to specify the option argument for '{raw}'?\nTo specify an option argument starting with a dash use '{raw}=-XYZ'."
                    )));
                }
                parsed.texts.insert(listed, next.clone());
            }
        }
    }
    Ok(parsed)
}

fn unknown(raw: &[u8]) -> ParseError {
    ParseError(format!("Unknown option '{}'", lossy(raw)))
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
    use crate::args::Grammar;

    const OPTIONS: &Options = &[
        ("idle", Kind::Text),
        ("foreground", Kind::Flag),
        ("socket", Kind::Text),
    ];

    fn read(words: &[&str]) -> Result<Parsed, String> {
        let words: Vec<OsString> = words.iter().map(OsString::from).collect();
        parse(&words, OPTIONS).map_err(|e| e.to_string())
    }

    fn refused(words: &[&str]) -> String {
        read(words).expect_err("refused")
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
    fn an_error_is_worded_as_node_words_it() {
        assert_eq!(refused(&["--unknown=1"]), "Unknown option '--unknown'");
        assert_eq!(refused(&["-i", "5"]), "Unknown option '-i'");
        assert_eq!(refused(&["-é"]), "Unknown option '-é'");
        assert_eq!(refused(&["--=x"]), "Unknown option '--'");
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
        for word in ["extra", "-", "-abc", "-😀", ""] {
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

    /// `Grammar` answers `None` for a call it hands to node, so only what it does read has to read the same here.
    #[test]
    fn what_the_grammar_of_args_reads_is_read_here_the_same_way() {
        const GRAMMAR: Grammar = Grammar {
            strings: &["idle", "socket"],
            flags: &["foreground"],
            multiple: &[],
            positionals: false,
        };
        let lines: &[&[&str]] = &[
            &[],
            &["--"],
            &["--idle", "5"],
            &["--idle=5"],
            &["--idle="],
            &["--idle", "5", "--idle", "6"],
            &["--idle=5", "--idle", "6", "--socket=/a"],
            &["--foreground"],
            &["--foreground", "--foreground"],
            &["--foreground", "--"],
            &["--socket", "/a", "--foreground", "--idle", "1"],
            &["--idle", "-"],
            &["--idle", "-1"],
            &["--idle"],
            &["--idle", "--foreground"],
            &["--foreground=1"],
            &["--nope"],
            &["--nope=1"],
            &["--=x"],
            &["-"],
            &["-x"],
            &["x"],
            &["--", "x"],
        ];
        let mut read_by_both = 0;
        for line in lines {
            let words: Vec<String> = line.iter().map(|word| (*word).to_owned()).collect();
            let Some(theirs) = GRAMMAR.parse(&words) else {
                continue;
            };
            let ours = read(line).unwrap_or_else(|error| panic!("{line:?}: {error}"));
            for name in ["idle", "socket"] {
                assert_eq!(
                    ours.text(name),
                    theirs.value(name).map(OsStr::new),
                    "{line:?}: {name}"
                );
            }
            assert_eq!(
                ours.flag("foreground"),
                theirs.flag("foreground"),
                "{line:?}"
            );
            read_by_both += 1;
        }
        assert_eq!(read_by_both, 11);
    }
}
