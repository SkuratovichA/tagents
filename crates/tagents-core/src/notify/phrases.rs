//! The words of a notice in each locale (`packages/notify/src/phrases.ts`). The locale is `TAGENTS_LOCALE` as `isLocale` and `DEFAULT_LOCALE` of `packages/core/src/i18n/index.ts` read it: exactly `en` or `ru`, English for anything else; this is the one Rust copy of that rule, pinned by the `words` vectors.

use crate::js;

/// A language the notices speak.
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
}

/// Every string a person reads in a banner, for one locale.
#[derive(Debug, PartialEq, Eq)]
pub struct Phrases {
    locale: Locale,
    pub kind_question: &'static str,
    pub kind_plan: &'static str,
    pub kind_permission: &'static str,
    pub kind_turn_done: &'static str,
    pub kind_cache_expiring: &'static str,
    pub kind_session_end: &'static str,
    /// Body of a question that came with no text.
    pub question_body: &'static str,
    /// Body of a finished turn whose answer could not be read.
    pub turn_done_body: &'static str,
    /// Body of a permission prompt that came with no message.
    pub permission_body: &'static str,
    /// Body of a session end that came with no reason.
    pub session_end_body: &'static str,
}

static EN: Phrases = Phrases {
    locale: Locale::En,
    kind_question: "Asks you something",
    kind_plan: "Plan ready for review",
    kind_permission: "Needs your permission",
    kind_turn_done: "Answer ready",
    kind_cache_expiring: "Prompt cache expiring",
    kind_session_end: "Session ended",
    question_body: "Asking you something",
    turn_done_body: "Your move",
    permission_body: "Waiting for your permission",
    session_end_body: "No reason given",
};

static RU: Phrases = Phrases {
    locale: Locale::Ru,
    kind_question: "Задаёт вопрос",
    kind_plan: "План готов к проверке",
    kind_permission: "Нужно ваше разрешение",
    kind_turn_done: "Ответ готов",
    kind_cache_expiring: "Кэш промпта истекает",
    kind_session_end: "Сессия завершена",
    question_body: "Хочет что-то спросить",
    turn_done_body: "Ваш ход",
    permission_body: "Ждёт вашего разрешения",
    session_end_body: "Причина не указана",
};

impl Phrases {
    /// The body of a cache notice. The minutes are written as JavaScript writes a number; below one minute left the sentence says "within a minute", never "~0 min".
    pub fn cache_body(&self, idle_min: f64, left_min: f64) -> String {
        let idle = js::number_text(idle_min);
        let left = js::number_text(left_min);
        match self.locale {
            Locale::En => {
                let within = if left_min < 1.0 {
                    "a minute".to_owned()
                } else {
                    format!("~{left} min")
                };
                format!("Idle {idle} min — send anything within {within} to keep the prompt cache")
            }
            Locale::Ru => {
                let within = if left_min < 1.0 {
                    "минуты".to_owned()
                } else {
                    format!("~{left} мин")
                };
                format!(
                    "Простой {idle} мин — отправьте что угодно в течение {within}, чтобы сохранить кэш промпта"
                )
            }
        }
    }
}

/// The table of one locale.
pub fn phrases_for(locale: Locale) -> &'static Phrases {
    match locale {
        Locale::En => &EN,
        Locale::Ru => &RU,
    }
}

/// The table for `TAGENTS_LOCALE`, English when it is unset or not one we speak.
pub fn current_phrases() -> &'static Phrases {
    phrases_for(Locale::of(std::env::var("TAGENTS_LOCALE").ok().as_deref()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_exact_names_pick_a_locale() {
        assert_eq!(Locale::of(Some("ru")), Locale::Ru);
        assert_eq!(Locale::of(Some("en")), Locale::En);
        for v in [
            None,
            Some(""),
            Some("RU"),
            Some("ru "),
            Some("de"),
            Some("ru_RU"),
        ] {
            assert_eq!(Locale::of(v), Locale::En, "{v:?}");
        }
    }

    #[test]
    fn the_english_cache_body_reads_within_a_minute_below_one() {
        let en = phrases_for(Locale::En);
        assert_eq!(
            en.cache_body(55.0, 0.0),
            "Idle 55 min — send anything within a minute to keep the prompt cache"
        );
        assert_eq!(
            en.cache_body(50.0, 10.0),
            "Idle 50 min — send anything within ~10 min to keep the prompt cache"
        );
    }

    #[test]
    fn the_russian_cache_body_reads_within_a_minute_below_one() {
        let ru = phrases_for(Locale::Ru);
        assert_eq!(
            ru.cache_body(55.0, 0.0),
            "Простой 55 мин — отправьте что угодно в течение минуты, чтобы сохранить кэш промпта"
        );
        assert!(ru.cache_body(55.0, 5.0).contains("в течение ~5 мин"));
    }
}
