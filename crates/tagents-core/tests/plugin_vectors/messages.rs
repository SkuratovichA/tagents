//! The `messages` section of the plugin vectors: the text the CLI's i18next prints for each key of both catalogues, with the values of each case, and the language each `TAGENTS_LOCALE` selects.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use serde_json::Value;
use tagents_core::{js, messages::Texts, notify::phrases::Locale};

use super::section;

/// A value as the node verbs hand it to i18next: a number prints as JavaScript prints it.
fn variable(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Number(n) => js::number_text(n.as_f64().unwrap()),
        other => panic!("a variable of {other}"),
    }
}

#[test]
fn every_key_prints_what_i18next_prints() {
    let messages = section("messages");
    let cases = messages["cases"].as_array().unwrap();
    assert!(cases.len() > 300, "the vector file lost its cases");
    for case in cases {
        let locale = Locale::of(case["locale"].as_str());
        let texts = Texts::load(locale).expect("the bundled catalogue loads");
        let vars: Vec<(String, String)> = case["vars"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(k, v)| (k.clone(), variable(v)))
            .collect();
        let vars: Vec<(&str, &str)> = vars.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        let key = case["key"].as_str().unwrap();
        assert_eq!(
            texts.t(key, &vars),
            case["text"].as_str().unwrap(),
            "{key} in {} with {}",
            case["locale"],
            case["vars"]
        );
    }
}

#[test]
fn a_key_missing_in_russian_prints_in_english() {
    let messages = section("messages");
    let missing = messages["missingInRu"].as_array().unwrap();
    assert!(!missing.is_empty());
    let (en, ru) = (
        Texts::load(Locale::En).unwrap(),
        Texts::load(Locale::Ru).unwrap(),
    );
    for key in missing {
        let key = key.as_str().unwrap();
        assert_eq!(ru.t(key, &[]), en.t(key, &[]), "{key}");
    }
}

#[test]
fn the_locale_is_exactly_en_or_ru() {
    let messages = section("messages");
    for case in messages["locales"].as_array().unwrap() {
        let locale = Locale::of(case["value"].as_str());
        let texts = Texts::load(locale).unwrap();
        assert_eq!(
            texts.t("pluginRemoved", &[("name", "n"), ("file", "f")]),
            case["text"].as_str().unwrap(),
            "TAGENTS_LOCALE {}",
            case["value"]
        );
    }
}
