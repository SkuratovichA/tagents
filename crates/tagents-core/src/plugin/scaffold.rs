//! The files `plugin new` writes: `spec/cli/scaffold/plugin.txt`, the text `packages/core/src/cli/scaffold.ts` reads at run time, rendered for a name, a directory and the core package.
//!
//! A line `@@ <path>` starts a file and its body runs to the next such line. `{{name}}`, `{{dir}}` and `{{core|json}}` are replaced in one pass, so a value that holds `{{name}}` is written as typed; any other `{{…}}` stays. The vectors pin the output against node's for each triple of `packages/core/test/fixtures/scaffold/triples.ts`.

use crate::{json, node};

/// One file of the scaffold, in the order `plugin new` writes it.
#[derive(Debug, PartialEq, Eq)]
pub struct File {
    /// Relative to the package directory, with forward slashes.
    pub path: String,
    pub body: String,
}

const TEMPLATE: &str = include_str!("../../../../spec/cli/scaffold/plugin.txt");

/// What the placeholders stand for.
struct Values<'a> {
    name: &'a str,
    dir: &'a str,
    /// What follows `link:`, as the JSON string escape without the quotes.
    core_json: &'a str,
}

/// The files of the scaffold for the plugin `name` written to `dir`, linking the core package at `core_dir`.
pub fn files(name: &str, dir: &str, core_dir: &str) -> Vec<File> {
    let quoted = json::quote(&relative_specifier(dir, core_dir));
    let values = Values {
        name,
        dir,
        core_json: &quoted[1..quoted.len() - 1],
    };
    sections(TEMPLATE)
        .into_iter()
        .map(|(path, body)| File {
            path: path.to_owned(),
            body: render(body, &values),
        })
        .collect()
}

/// `relativeSpecifier` of `cli/scaffold.ts`, quirk included: `.` for an empty path, the path as it is when it starts with `.` (`.hidden/x` gets no `./`), else `./` and the path.
fn relative_specifier(from: &str, to: &str) -> String {
    let rel = node::relative(from, to);
    if rel.is_empty() {
        ".".to_owned()
    } else if rel.starts_with('.') {
        rel
    } else {
        format!("./{rel}")
    }
}

/// The `(path, body)` of each section of `text`: a line `@@ <path>` starts one, and what comes before the first is ignored.
fn sections(text: &str) -> Vec<(&str, &str)> {
    let mut found: Vec<(&str, usize, usize)> = Vec::new();
    let mut at = 0;
    for line in text.split_inclusive('\n') {
        if let Some(path) = line.strip_prefix("@@ ") {
            if let Some(last) = found.last_mut() {
                last.2 = at;
            }
            found.push((path.trim_end_matches('\n'), at + line.len(), text.len()));
        }
        at += line.len();
    }
    found
        .into_iter()
        .map(|(path, start, end)| (path, &text[start..end]))
        .collect()
}

/// `text` with each placeholder replaced once, as `/\{\{([\w|]+)\}\}/g` finds them: a `{{` that does not open one is skipped by a character, so `{{{name}}` holds one.
fn render(text: &str, values: &Values) -> String {
    let mut out = String::with_capacity(text.len());
    let mut from = 0;
    while let Some(found) = text[from..].find("{{") {
        let open = from + found;
        let rest = &text[open + 2..];
        let name_len = rest
            .bytes()
            .take_while(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'|'))
            .count();
        let value = rest[name_len..]
            .starts_with("}}")
            .then(|| match &rest[..name_len] {
                "name" => Some(values.name),
                "dir" => Some(values.dir),
                "core|json" => Some(values.core_json),
                _ => None,
            })
            .flatten();
        match value {
            Some(value) => {
                out.push_str(&text[from..open]);
                out.push_str(value);
                from = open + 2 + name_len + 2;
            }
            None => {
                out.push_str(&text[from..=open]);
                from = open + 1;
            }
        }
    }
    out.push_str(&text[from..]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn values() -> Values<'static> {
        Values {
            name: "demo",
            dir: "/w/d",
            core_json: "../c",
        }
    }

    #[test]
    fn a_placeholder_is_replaced_once_and_a_value_is_never_read_again() {
        let v = Values {
            name: "{{dir}}",
            dir: "$& {{core|json}}",
            core_json: "x",
        };
        assert_eq!(
            render("{{name}} {{dir}} {{core|json}}", &v),
            "{{dir}} $& {{core|json}} x"
        );
        assert_eq!(render("a{{name}}b{{name}}c", &values()), "ademobdemoc");
    }

    #[test]
    fn what_is_not_a_known_placeholder_stays() {
        for text in [
            "",
            "plain",
            "{{",
            "}}",
            "{{}}",
            "{{ name }}",
            "{{core}}",
            "{{Name}}",
            "{{name",
            "{name}}",
            "{{na-me}}",
            "{{core|JSON}}",
            "{{name}",
            "é{{é}}",
        ] {
            assert_eq!(render(text, &values()), text, "{text:?}");
        }
        // A `{{` that opens nothing is skipped by one character, as the regex does.
        assert_eq!(render("{{{name}}", &values()), "{demo");
        assert_eq!(render("{{ {{name}}}}", &values()), "{{ demo}}");
        assert_eq!(render("{{name}}}}{{dir}}", &values()), "demo}}/w/d");
    }

    #[test]
    fn sections_start_at_a_line_that_begins_with_at_at() {
        let text = "ignored\n@@ a\none\ntwo\n@@ b/c\n\n@@ d\nx @@ y\n";
        assert_eq!(
            sections(text),
            [("a", "one\ntwo\n"), ("b/c", "\n"), ("d", "x @@ y\n")]
        );
        assert_eq!(sections("no header"), []);
        assert_eq!(sections("@@ a"), [("a", "")]);
    }

    #[test]
    fn the_template_is_the_five_files_and_the_three_placeholders() {
        let paths: Vec<_> = sections(TEMPLATE)
            .into_iter()
            .map(|(path, _)| path)
            .collect();
        assert_eq!(
            paths,
            [
                "package.json",
                "tsconfig.json",
                "src/plugin.ts",
                "test/plugin.test.ts",
                "README.md"
            ]
        );
        assert!(TEMPLATE.starts_with("@@ package.json\n") && TEMPLATE.ends_with('\n'));
        // Every `{{` of the template opens a placeholder the renderer knows: rendering with a marker leaves none.
        let marked = Values {
            name: "N",
            dir: "D",
            core_json: "C",
        };
        assert!(!render(TEMPLATE, &marked).contains("{{"));
    }

    #[test]
    fn the_specifier_is_node_s_with_its_quirk() {
        for (from, to, want) in [
            ("/work/demo", "/work/demo", "."),
            ("/work/demo", "/work/packages/core", "../packages/core"),
            ("/work/demo", "/work/demo/packages/core", "./packages/core"),
            ("/work/demo", "/work/demo/.hidden/core", ".hidden/core"),
            ("/work/demo", "/work/demo/..odd", "..odd"),
            ("/work/demo", "/", "../.."),
            ("/", "/packages/core", "./packages/core"),
        ] {
            assert_eq!(relative_specifier(from, to), want, "{from} {to}");
        }
    }

    #[test]
    fn a_quote_and_a_backslash_are_escaped_in_package_json_only() {
        let written = files("demo", "/w/a\"b\\c", "/w/q\"r\\s/packages/core");
        assert!(
            written[0]
                .body
                .contains(r#""@tagents/core": "link:../q\"r\\s/packages/core""#)
        );
        assert!(
            written[4]
                .body
                .contains("tagents plugin add /w/a\"b\\c       #")
        );
    }
}
