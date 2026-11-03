//! The CLI's human strings in the language of `TAGENTS_LOCALE`, from `spec/cli/messages.json`.
//!
//! Interpolation is the part of i18next the catalogue uses and nothing else (the exporter refuses a text that uses more): each `{{name}}` is replaced once, left to right, by the value given for it, and a value is never scanned again, so a path that holds `{{x}}` or `$t(pluginNone)` prints as typed. A key `ru` lacks prints its English text; a key neither has prints as the key, as i18next prints it. The `messages` vectors in `tests/fixtures/plugin-vectors.json` pin all of it against the node CLI.

use tagents_spec::Messages;

/// A language the CLI speaks. The locale is `TAGENTS_LOCALE` as `isLocale` and `DEFAULT_LOCALE` of `packages/core/src/i18n/index.ts` read it: exactly `en` or `ru`, English for anything else. This is the one Rust copy of that rule, pinned by the `words` and `messages` vectors, and `notify::phrases` re-exports it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Locale {
    En,
    Ru,
}

impl Locale {
    /// The locale a `TAGENTS_LOCALE` value names: only the exact text `en` or `ru`, else English (the unset variable included).
    pub fn of(value: Option<&str>) -> Locale {
        match value {
            Some("ru") => Locale::Ru,
            _ => Locale::En,
        }
    }

    /// The locale of this process: its `TAGENTS_LOCALE`, read by `of`.
    pub fn current() -> Locale {
        Locale::of(std::env::var("TAGENTS_LOCALE").ok().as_deref())
    }
}

/// The catalogue read for one language.
#[derive(Debug)]
pub struct Texts {
    locale: Locale,
    messages: Messages,
}

impl Texts {
    /// The bundled catalogue, read in `locale`.
    pub fn load(locale: Locale) -> Result<Texts, serde_json::Error> {
        Ok(Texts {
            locale,
            messages: Messages::bundled()?,
        })
    }

    /// The catalogue in `text`, read in `locale`: the texts of a program that has a file of its own beside the bundled one.
    pub fn from_json(locale: Locale, text: &str) -> Result<Texts, serde_json::Error> {
        Ok(Texts {
            locale,
            messages: Messages::parse(text)?,
        })
    }

    /// The text of `key` with each `{{name}}` that `vars` names filled in; one that it does not name stays as typed.
    pub fn t(&self, key: &str, vars: &[(&str, &str)]) -> String {
        let table = match self.locale {
            Locale::En => &self.messages.en,
            Locale::Ru => &self.messages.ru,
        };
        match table.get(key).or_else(|| self.messages.en.get(key)) {
            Some(text) => interpolate(text, vars),
            None => key.to_owned(),
        }
    }
}

/// `text` with each `{{name}}` that `vars` names replaced, the way i18next 26 does it with `escapeValue: false`: left to right, each value skipped over once it is in, so a value is not read for placeholders of its own.
///
/// The one quirk kept is i18next's: it replaces the *first* occurrence of the placeholder's text in the whole string, which is the match unless an earlier value holds the same text. A name `{{file}}` given to `{{name}} in {{file}}` therefore prints the file where the name went, and leaves the real placeholder standing.
fn interpolate(text: &str, vars: &[(&str, &str)]) -> String {
    let mut out = text.to_owned();
    let mut from = 0;
    while let Some((start, end)) = placeholder(&out, from) {
        let whole = out[start..end].to_owned();
        from = end;
        let Some((_, value)) = vars
            .iter()
            .find(|(name, _)| *name == &whole[2..whole.len() - 2])
        else {
            continue;
        };
        out = out.replacen(&whole, value, 1);
        from = from + value.len() - whole.len();
    }
    out
}

/// The first `{{…}}` at or after byte `from`, as the pattern `\{\{(.+?)\}\}` finds it: the name is at least one character and none of them a line terminator. Returns where it starts and ends.
fn placeholder(text: &str, from: usize) -> Option<(usize, usize)> {
    let mut at = from;
    while let Some(found) = text.get(at..)?.find("{{") {
        let open = at + found;
        let mut close = open + 2;
        for ch in text[close..].chars() {
            if matches!(ch, '\n' | '\r' | '\u{2028}' | '\u{2029}') {
                break;
            }
            close += ch.len_utf8();
            if text[close..].starts_with("}}") {
                return Some((open, close + 2));
            }
        }
        at = open + 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_value_is_not_scanned_for_placeholders() {
        assert_eq!(interpolate("{{a}}", &[("a", "$t(x) {{a}}")]), "$t(x) {{a}}");
        assert_eq!(
            interpolate("{{a}} and {{c}}", &[("a", "{{b}}"), ("c", "second")]),
            "{{b}} and second"
        );
    }

    #[test]
    fn a_value_that_holds_a_later_placeholder_takes_its_value_instead_of_the_placeholder() {
        let vars = [("name", "{{error}}"), ("error", "second")];
        assert_eq!(
            interpolate("{{name}}: {{error}}", &vars),
            "second: {{error}}"
        );
    }

    #[test]
    fn a_placeholder_is_one_or_more_characters_on_one_line() {
        assert_eq!(placeholder("a {{b}} c", 0), Some((2, 7)));
        assert_eq!(placeholder("{{}}}", 0), Some((0, 5)));
        assert_eq!(placeholder("{{}}", 0), None);
        assert_eq!(placeholder("{{a\nb}} {{c}}", 0), Some((8, 13)));
        assert_eq!(placeholder("{{{a}}", 0), Some((0, 6)));
        assert_eq!(placeholder("{{a}}", 1), None);
        assert_eq!(placeholder("{{a}}", 99), None);
    }

    #[test]
    fn a_placeholder_nobody_names_stays_as_typed() {
        assert_eq!(
            interpolate("x {{nope}} y {{a}", &[("a", "1")]),
            "x {{nope}} y {{a}"
        );
        assert_eq!(interpolate("no placeholders", &[]), "no placeholders");
    }

    #[test]
    fn a_key_nobody_has_prints_as_the_key() {
        let texts = Texts::load(Locale::Ru).expect("loads");
        assert_eq!(texts.t("noSuchKey", &[]), "noSuchKey");
    }
}
