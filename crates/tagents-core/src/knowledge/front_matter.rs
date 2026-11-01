//! The YAML front matter of a knowledge document, read as the `yaml` package reads it for `doc.ts`: a tree of null, booleans, numbers, strings, lists and mappings, with a mapping's keys as text.
//!
//! saphyr (YAML 1.2, the core schema) does the parsing and this module converts its tree. The differences from `yaml` that remain are listed in `tests::KNOWN_DIFFERENCES` with the reason for each, and the test over the vectors fails when one appears that is not listed or a listed one goes away.

use saphyr::{LoadableYamlNode, Scalar, Yaml as Node};

use crate::js;

/// A parsed value. A number is kept as the text JavaScript prints for it, which is all a reader of the front matter can tell from it.
#[derive(Debug, Clone, PartialEq)]
pub enum Yaml {
    Null,
    Bool(bool),
    Num(String),
    Str(String),
    Seq(Vec<Yaml>),
    /// A mapping in the order of the document, with its keys as text.
    Map(Vec<(String, Yaml)>),
}

impl Yaml {
    /// The value of `key` when this is a mapping that has it. `None` is a missing key and `Some(Yaml::Null)` a key written with a null value, which the front matter rules tell apart.
    pub fn get(&self, key: &str) -> Option<&Yaml> {
        match self {
            Yaml::Map(entries) => entries.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Yaml::Str(s) => Some(s),
            _ => None,
        }
    }
}

/// `yaml.parse(text)`: the value of the one document in `text`, null for none, or the message of why it is not YAML. More than one document is refused, as the package refuses it.
pub fn parse(text: &str) -> Result<Yaml, String> {
    let mut documents = Node::load_from_str(text).map_err(|e| e.to_string())?;
    match documents.len() {
        0 => Ok(Yaml::Null),
        1 => convert(&documents.remove(0)),
        _ => Err(
            "Source contains multiple documents; please use YAML.parseAllDocuments()".to_owned(),
        ),
    }
}

fn convert(node: &Node) -> Result<Yaml, String> {
    Ok(match node {
        Node::Value(scalar) => scalar_of(scalar),
        Node::Sequence(items) => Yaml::Seq(items.iter().map(convert).collect::<Result<_, _>>()?),
        Node::Mapping(entries) => {
            let mut out = Vec::with_capacity(entries.len());
            for (key, value) in entries {
                out.push((key_text(key)?, convert(value)?));
            }
            Yaml::Map(out)
        }
        // A tag that is not the core schema's is dropped and its value kept, as `yaml` does for a tag it does not know.
        Node::Tagged(_, inner) => convert(inner)?,
        Node::Representation(text, _, _) => Yaml::Str(text.to_string()),
        Node::Alias(_) | Node::BadValue => {
            return Err("a value that is not valid for its tag".to_owned());
        }
    })
}

fn scalar_of(scalar: &Scalar) -> Yaml {
    match scalar {
        Scalar::Null => Yaml::Null,
        Scalar::Boolean(b) => Yaml::Bool(*b),
        // A number goes through a double, as it does in JavaScript, so an integer above 2^53 is the double that is nearest to it.
        Scalar::Integer(i) => Yaml::Num(js::number_text(*i as f64)),
        Scalar::FloatingPoint(f) => Yaml::Num(js::number_text(f.0)),
        Scalar::String(s) => Yaml::Str(s.to_string()),
    }
}

/// A mapping key as `yaml` turns it into a property name: a scalar key is its text. A key that is itself a list or a mapping has no text that matches node's, which is a known difference.
fn key_text(key: &Node) -> Result<String, String> {
    Ok(match convert(key)? {
        Yaml::Str(s) | Yaml::Num(s) => s,
        Yaml::Bool(b) => b.to_string(),
        // `yaml` makes a property name of a null key by `String(key ?? '')`.
        Yaml::Null => String::new(),
        Yaml::Seq(_) | Yaml::Map(_) => String::new(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn vectors() -> Value {
        let file = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/knowledge-vectors.json"
        );
        serde_json::from_str(&std::fs::read_to_string(file).unwrap()).unwrap()
    }

    /// The tree of a vector, `{"t": "map", "v": [[key, tree], ...]}` and the like.
    fn from_vector(v: &Value) -> Yaml {
        let inner = &v["v"];
        match v["t"].as_str().unwrap() {
            "null" => Yaml::Null,
            "bool" => Yaml::Bool(inner.as_bool().unwrap()),
            "num" => Yaml::Num(inner.as_str().unwrap().to_owned()),
            "str" => Yaml::Str(inner.as_str().unwrap().to_owned()),
            "seq" => Yaml::Seq(inner.as_array().unwrap().iter().map(from_vector).collect()),
            "map" => Yaml::Map(
                inner
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|pair| (pair[0].as_str().unwrap().to_owned(), from_vector(&pair[1])))
                    .collect(),
            ),
            other => panic!("a tree of type {other}"),
        }
    }

    /// Mapping entries ordered by the UTF-16 units of their keys, as the generator writes them.
    fn sorted(y: Yaml) -> Yaml {
        match y {
            Yaml::Seq(items) => Yaml::Seq(items.into_iter().map(sorted).collect()),
            Yaml::Map(entries) => {
                let mut entries: Vec<(String, Yaml)> =
                    entries.into_iter().map(|(k, v)| (k, sorted(v))).collect();
                entries.sort_by(|a, b| a.0.encode_utf16().cmp(b.0.encode_utf16()));
                Yaml::Map(entries)
            }
            other => other,
        }
    }

    /// Sources whose value is not the one `yaml` gives, each with the reason. The test fails for a source that differs and is not here, and for one that is here and no longer differs.
    const KNOWN_DIFFERENCES: &[(&str, &str)] = &[
        (
            "a: !!str 5\nb: !!int '7'\nc: !custom x",
            "saphyr resolves an explicit core tag on a quoted scalar to a string before the converter sees the tag, so `!!int '7'` is the string 7 here and the number 7 in node",
        ),
        (
            "? [complex, key]\n: v",
            "a mapping key that is a list or a mapping has the text `[ complex, key ]` in node and none here",
        ),
        (
            "%YAML 1.1\n---\na: yes\nb: 0o17",
            "saphyr reads every document as YAML 1.2 and ignores the `%YAML 1.1` directive, so `yes` is a string here and a boolean in node",
        ),
        (
            "a: !!float 1\nb: !!bool true\nc: !!null \"\"\nd: !!str\ne: !!seq [1]\nf: !!map {g: 1}",
            "saphyr resolves an explicit core tag on a quoted or empty scalar itself and drops the tag, as in the first case",
        ),
        (
            "a: !!int abc",
            "a value that does not fit its explicit core tag is refused here and read as a string by node",
        ),
        (
            "a: !!bool maybe",
            "a value that does not fit its explicit core tag is refused here and read as a string by node",
        ),
        (
            "a: !!binary aGk=\nb: !!set {x}\nc: !!timestamp 2026-10-31",
            "the tags `!!binary`, `!!set` and `!!timestamp` are not core-schema tags: saphyr refuses their values, node reads them as bytes or an empty mapping",
        ),
        (
            "a: 0xFFFFFFFFFFFFFFFFFF\nb: 0o7777777777777777777777\nc: -0x10\nd: 0x",
            "a hexadecimal or octal integer above the range of i64 is a string in saphyr and a double in node, and the converter cannot tell a plain scalar from a quoted one to correct it",
        ),
        (
            "a: \"\\ud83d\\ude00\"",
            "a surrogate pair written as two `\\u` escapes is refused by saphyr, as YAML 1.2 defines `\\u` as one code point",
        ),
        (
            "a:\tb",
            "a tab after the colon of a mapping entry is refused by saphyr and accepted by node",
        ),
        (
            "a: x\0y",
            "a control character inside a scalar is refused by saphyr and accepted by node",
        ),
        (
            "a: \"x\0y\"",
            "a control character inside a scalar is refused by saphyr and accepted by node",
        ),
        (
            "!x",
            "a tagged empty scalar is null in saphyr and the empty string in node",
        ),
        (
            "a: !b",
            "a tagged empty scalar is null in saphyr and the empty string in node",
        ),
    ];

    #[test]
    fn every_source_of_the_vectors_reads_as_node_reads_it_or_is_a_listed_difference() {
        let v = vectors();
        let mut differing: Vec<String> = Vec::new();
        for case in v["yaml"].as_array().unwrap() {
            let text = case["text"].as_str().unwrap();
            let got = parse(text).map(sorted);
            let same = match (case.get("ok"), &got) {
                (Some(want), Ok(got)) => from_vector(want) == *got,
                (None, Err(_)) => true,
                _ => false,
            };
            if !same {
                differing.push(format!(
                    "{text:?}: node {} and Rust {got:?}",
                    case.get("ok")
                        .map_or_else(|| format!("refuses ({})", case["error"]), |w| w.to_string())
                ));
            }
        }
        let listed: Vec<&str> = KNOWN_DIFFERENCES.iter().map(|(text, _)| *text).collect();
        let unlisted: Vec<&String> = differing
            .iter()
            .filter(|d| !listed.iter().any(|l| d.starts_with(&format!("{l:?}:"))))
            .collect();
        let gone: Vec<&&str> = listed
            .iter()
            .filter(|l| !differing.iter().any(|d| d.starts_with(&format!("{l:?}:"))))
            .collect();
        assert!(
            unlisted.is_empty() && gone.is_empty(),
            "unlisted differences:\n{}\nlisted but no longer different: {gone:?}",
            unlisted
                .iter()
                .map(|s| s.as_str())
                .collect::<Vec<_>>()
                .join("\n")
        );
    }
}
