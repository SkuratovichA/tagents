//! The options of a verb: `util.parseArgs` of node as far as this binary models it, and nothing else.
//!
//! The grammar has no error case. A positional is an argument that does not start with `-` (a lone `-` included), and `--` ends the options. A string option is read as `--name V`, when `V` does not start with `-`, or as `--name=V` for any `V`; a repeated one keeps its last value, unless the table lists it as `multiple`, which keeps all of them in the order given. A flag is a bare `--name`. Anything else is `None`: any other argument that starts with `-` (a short option, an unknown name), a missing value or one that starts with `-`, a flag with `=`, and a positional where the verb takes none. `None` is a call node words itself, since `parseArgs` words its own errors and its exit code comes from the error, so no error text is copied. Taking more than node does is the one thing this reader must not do, and handing over a call node would accept (`--cwd -`) is allowed.

/// What a verb reads: the names of its options, written without their dashes, and whether it takes positionals.
#[derive(Debug, Clone, Copy)]
pub struct Grammar {
    /// Options that take a value; a repeated one keeps its last.
    pub strings: &'static [&'static str],
    /// Options that take none.
    pub flags: &'static [&'static str],
    /// Options that take a value and keep every one they are given.
    pub multiple: &'static [&'static str],
    pub positionals: bool,
}

/// The arguments of a verb read by its `Grammar`.
#[derive(Debug, PartialEq, Eq)]
pub struct Parsed<'a> {
    pub positionals: Vec<&'a str>,
    /// The value of each string option, as (name, value) in the order kept.
    given: Vec<(&'static str, &'a str)>,
    flags: Vec<&'static str>,
}

impl Grammar {
    /// `args` by this grammar, or `None` for a call it does not read.
    pub fn parse<'a>(&self, args: &'a [String]) -> Option<Parsed<'a>> {
        let mut parsed = Parsed {
            positionals: Vec::new(),
            given: Vec::new(),
            flags: Vec::new(),
        };
        let mut rest = args.iter().map(String::as_str);
        while let Some(arg) = rest.next() {
            if arg == "--" {
                parsed.positionals.extend(rest.by_ref());
            } else if !arg.starts_with('-') || arg == "-" {
                parsed.positionals.push(arg);
            } else {
                let (name, inline) = match arg.strip_prefix("--")?.split_once('=') {
                    Some((name, value)) => (name, Some(value)),
                    None => (&arg[2..], None),
                };
                if let Some(flag) = self.flags.iter().find(|flag| **flag == name) {
                    if inline.is_some() {
                        return None;
                    }
                    parsed.flags.push(flag);
                } else {
                    let option = self
                        .strings
                        .iter()
                        .chain(self.multiple)
                        .find(|option| **option == name)?;
                    let value = match inline {
                        Some(value) => value,
                        None => rest.next().filter(|value| !value.starts_with('-'))?,
                    };
                    if !self.multiple.contains(option) {
                        parsed.given.retain(|(given, _)| given != option);
                    }
                    parsed.given.push((option, value));
                }
            }
        }
        (self.positionals || parsed.positionals.is_empty()).then_some(parsed)
    }
}

impl<'a> Parsed<'a> {
    /// The last value given to the string option `name`.
    pub fn value(&self, name: &str) -> Option<&'a str> {
        self.given
            .iter()
            .rev()
            .find(|(given, _)| *given == name)
            .map(|(_, value)| *value)
    }

    /// Every value given to `name`, in order: one at most for an option that is not `multiple`.
    pub fn values(&self, name: &str) -> Vec<&'a str> {
        self.given
            .iter()
            .filter(|(given, _)| *given == name)
            .map(|(_, value)| *value)
            .collect()
    }

    /// Was the flag `name` given?
    pub fn flag(&self, name: &str) -> bool {
        self.flags.contains(&name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(args: &[&str]) -> Vec<String> {
        args.iter().map(|a| (*a).to_owned()).collect()
    }

    /// What a successful reading holds: the positionals, the string options as (name, value) in the order the values were kept, and the flags that were given.
    fn parsed<'a>(
        positionals: &[&'a str],
        given: &[(&'static str, &'a str)],
        flags: &[&'static str],
    ) -> Option<Parsed<'a>> {
        Some(Parsed {
            positionals: positionals.to_vec(),
            given: given.to_vec(),
            flags: flags.to_vec(),
        })
    }

    /// The tables `plugin add`, `plugin new` and `plugin remove` read their arguments through.
    const ADD: Grammar = Grammar {
        strings: &["name"],
        flags: &[],
        multiple: &[],
        positionals: true,
    };
    const NEW: Grammar = Grammar {
        strings: &["dir"],
        flags: &[],
        multiple: &[],
        positionals: true,
    };
    const REMOVE: Grammar = Grammar {
        strings: &[],
        flags: &[],
        multiple: &[],
        positionals: true,
    };

    /// A table like `session open`'s and one like `session list`'s: no positionals, a flag, a string option, and a repeated one.
    const OPEN: Grammar = Grammar {
        strings: &["cwd", "label"],
        flags: &["no-config-dir", "skip-permissions"],
        multiple: &[],
        positionals: false,
    };
    const LIST: Grammar = Grammar {
        strings: &["label"],
        flags: &[],
        multiple: &["state"],
        positionals: false,
    };

    #[test]
    fn the_grammar_reads_positionals_and_its_one_option_and_nothing_else() {
        for (args, grammar, want) in [
            (&[][..], &ADD, parsed(&[], &[], &[])),
            (&["pkg"], &ADD, parsed(&["pkg"], &[], &[])),
            (
                &["pkg", "--name", "x"],
                &ADD,
                parsed(&["pkg"], &[("name", "x")], &[]),
            ),
            (
                &["--name", "x", "pkg"],
                &ADD,
                parsed(&["pkg"], &[("name", "x")], &[]),
            ),
            (
                &["--name=x", "pkg"],
                &ADD,
                parsed(&["pkg"], &[("name", "x")], &[]),
            ),
            (
                &["--name=", "pkg"],
                &ADD,
                parsed(&["pkg"], &[("name", "")], &[]),
            ),
            (
                &["--name=-x", "pkg"],
                &ADD,
                parsed(&["pkg"], &[("name", "-x")], &[]),
            ),
            (
                &["--name", "a", "--name=b", "p"],
                &ADD,
                parsed(&["p"], &[("name", "b")], &[]),
            ),
            (
                &["--name=a", "--name", "b", "p"],
                &ADD,
                parsed(&["p"], &[("name", "b")], &[]),
            ),
            (&["a", "b", "c"], &ADD, parsed(&["a", "b", "c"], &[], &[])),
            (&["-"], &ADD, parsed(&["-"], &[], &[])),
            (
                &["--", "-x", "--name", "--"],
                &ADD,
                parsed(&["-x", "--name", "--"], &[], &[]),
            ),
            (
                &["p", "--", "--name=x"],
                &ADD,
                parsed(&["p", "--name=x"], &[], &[]),
            ),
            (&["x", "y"], &REMOVE, parsed(&["x", "y"], &[], &[])),
            (&["--", "--name"], &REMOVE, parsed(&["--name"], &[], &[])),
            // `new` reads `--dir` the same way, and `--name` is not its option.
            (
                &["x", "--dir", "d"],
                &NEW,
                parsed(&["x"], &[("dir", "d")], &[]),
            ),
            (
                &["--dir=d", "x"],
                &NEW,
                parsed(&["x"], &[("dir", "d")], &[]),
            ),
            (&["--dir=", "x"], &NEW, parsed(&["x"], &[("dir", "")], &[])),
            (
                &["--dir=-d", "x"],
                &NEW,
                parsed(&["x"], &[("dir", "-d")], &[]),
            ),
            (
                &["--dir", "a", "--dir=b", "x"],
                &NEW,
                parsed(&["x"], &[("dir", "b")], &[]),
            ),
            (
                &["x", "--", "--dir"],
                &NEW,
                parsed(&["x", "--dir"], &[], &[]),
            ),
            (&["--dir"], &NEW, None),
            (&["--dir", "-d"], &NEW, None),
            (&["--dir-x=d"], &NEW, None),
            (&["--directory=d"], &NEW, None),
            (&["--name", "x"], &NEW, None),
            (&["--dir", "d"], &ADD, None),
            // What node words itself.
            (&["--name"], &ADD, None),
            (&["p", "--name"], &ADD, None),
            (&["--name", "-x"], &ADD, None),
            (&["--name", "-"], &ADD, None),
            (&["--name", "--other"], &ADD, None),
            (&["--nam", "x"], &ADD, None),
            (&["--name-x", "p"], &ADD, None),
            (&["--json"], &ADD, None),
            (&["-n", "x"], &ADD, None),
            (&["-abc"], &ADD, None),
            (&["--no-name", "p"], &ADD, None),
            (&["--name=x"], &REMOVE, None),
            (&["--name", "x"], &REMOVE, None),
            (&["-x"], &REMOVE, None),
        ] {
            assert_eq!(grammar.parse(&words(args)), want, "{args:?}");
        }
    }

    #[test]
    fn an_empty_value_is_a_value_and_a_value_is_split_at_its_first_equals_sign() {
        for (args, want) in [
            (
                &["--name", "", "p"][..],
                parsed(&["p"], &[("name", "")], &[]),
            ),
            (
                &["--name=a=b", "p"],
                parsed(&["p"], &[("name", "a=b")], &[]),
            ),
            (&["--name==", "p"], parsed(&["p"], &[("name", "=")], &[])),
            (&["--=x", "p"], None),
            (&["--", "--"], parsed(&["--"], &[], &[])),
            (&["--name", "--"], None),
            (&["---name", "x"], None),
            (&["--Name", "x"], None),
        ] {
            assert_eq!(ADD.parse(&words(args)), want, "{args:?}");
        }
    }

    #[test]
    fn a_flag_is_bare_and_takes_neither_a_value_nor_an_equals_sign() {
        for (args, want) in [
            (
                &["--no-config-dir"][..],
                parsed(&[], &[], &["no-config-dir"]),
            ),
            (
                &["--skip-permissions", "--cwd", "/w", "--no-config-dir"],
                parsed(
                    &[],
                    &[("cwd", "/w")],
                    &["skip-permissions", "no-config-dir"],
                ),
            ),
            // The same flag twice is the flag.
            (
                &["--no-config-dir", "--no-config-dir"],
                parsed(&[], &[], &["no-config-dir", "no-config-dir"]),
            ),
            (&["--no-config-dir=1"], None),
            (&["--no-config-dir="], None),
            // A word after a flag is a positional, and this grammar has none.
            (&["--no-config-dir", "x"], None),
            (&["--no-config", "x"], None),
            (&["--cwd"], None),
            (&["-x"], None),
            (&["--bogus"], None),
        ] {
            assert_eq!(OPEN.parse(&words(args)), want, "{args:?}");
        }
    }

    #[test]
    fn a_positional_is_refused_where_none_is_allowed() {
        for (args, want) in [
            (&[][..], parsed(&[], &[], &[])),
            (&["x"], None),
            (&["-"], None),
            (&["--cwd", "/w", "x"], None),
            (&["--"], parsed(&[], &[], &[])),
            (&["--cwd", "/w", "--"], parsed(&[], &[("cwd", "/w")], &[])),
            (&["--", "x"], None),
            (&["--", "--cwd"], None),
        ] {
            assert_eq!(OPEN.parse(&words(args)), want, "{args:?}");
        }
    }

    #[test]
    fn a_repeated_string_option_keeps_its_last_value_and_a_repeated_multiple_keeps_all() {
        let args = words(&[
            "--state=a",
            "--label",
            "one",
            "--state",
            "b",
            "--label=two",
            "--state=a",
        ]);
        let list = LIST.parse(&args).unwrap();
        assert_eq!(list.value("label"), Some("two"));
        assert_eq!(list.values("label"), ["two"]);
        assert_eq!(list.values("state"), ["a", "b", "a"]);
        assert_eq!(list.value("state"), Some("a"));
        assert_eq!(list.value("missing"), None);
        assert!(list.values("missing").is_empty());

        let args = words(&["--cwd", "/a", "--no-config-dir", "--cwd=/b"]);
        let open = OPEN.parse(&args).unwrap();
        assert_eq!(open.value("cwd"), Some("/b"));
        assert_eq!(open.values("cwd"), ["/b"]);
        assert!(open.flag("no-config-dir"));
        assert!(!open.flag("skip-permissions"));
        assert_eq!(open.value("label"), None);

        // A value that starts with `-` is refused after the space and kept after `=`, for a multiple option as for the others.
        assert_eq!(LIST.parse(&words(&["--state", "-a"])), None);
        let args = words(&["--state=-a"]);
        assert_eq!(LIST.parse(&args).unwrap().values("state"), ["-a"]);
        assert_eq!(LIST.parse(&words(&["--state"])), None);
    }

    #[test]
    fn a_value_is_kept_as_it_is_whatever_it_holds() {
        // An argument that is not UTF-8 never gets here (the front door hands such a call to node), but one that holds U+FFFD, a quote, a space, a newline or an escape is read as the text it is, and so is a value that looks like an option after `=`.
        let odd = [
            "\u{fffd}", "a b", "x\ny", "\"q\"", "\\u0041", "--cwd", "é😀",
        ];
        for value in odd {
            let args = words(&["--cwd", value]);
            let want = value.starts_with('-');
            assert_eq!(OPEN.parse(&args).is_none(), want, "{value:?}");
            let args = words(&[&format!("--cwd={value}")]);
            assert_eq!(OPEN.parse(&args).unwrap().value("cwd"), Some(value));
        }
    }
}
