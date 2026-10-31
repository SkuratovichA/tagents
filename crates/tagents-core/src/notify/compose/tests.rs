//! Cases of `packages/notify/test/compose.test.ts`, one Rust test each (21, in the node file's order):
//! - untitle gives what the shell function gives, title by title: `untitle_gives_what_the_shell_function_gives`
//! - untitle keeps a one-letter word and drops a symbol glyph: `untitle_keeps_a_one_letter_word_and_drops_a_symbol_glyph`
//! - agentName: a label typed for the session beats one for the pane: `a_label_for_the_session_beats_one_for_the_pane`
//! - agentName: a label typed for the pane beats the pane title: `a_label_for_the_pane_beats_the_pane_title`
//! - agentName: the pane title, without its glyph, beats TA_LABEL: `the_pane_title_without_its_glyph_beats_the_label`
//! - agentName: with no title, TA_LABEL; with no label either, the directory name: `no_title_is_the_label_and_no_label_the_directory`
//! - agentName: a title equal to the hostname falls to the directory name: `a_title_equal_to_the_hostname_falls_to_the_directory`
//! - agentName: a session with no pane looks nothing up by pane: `a_session_with_no_pane_looks_nothing_up_by_pane`
//! - turn_done: the body is the first non-empty line of the last answer: `turn_done_body_is_the_first_non_empty_line`
//! - turn_done: a long first line is clipped to 200 characters: `turn_done_clips_a_long_line_to_200_characters`
//! - turn_done: a missing transcript, or none given, is "Your move": `turn_done_without_a_transcript_is_your_move`
//! - subtitle: the phrase alone when the project is the title: `the_subtitle_names_the_project_unless_it_is_the_title`
//! - question: the event text, or "Asking you something"; a plan has its own subtitle: `a_question_says_its_text_and_a_plan_has_its_own_subtitle`
//! - permission: the event text: `a_permission_says_its_text`
//! - cache_expiring: the idle and the left minutes in the body: `a_cache_notice_says_the_minutes`
//! - session_end: `a_session_end_says_its_reason`
//! - the Russian table speaks Russian and has the same shape: `the_russian_table_speaks_russian` (the same shape is the struct's fields: not applicable as a key comparison)
//! - cache_expiring: minutes left below one read "within a minute": `minutes_left_below_one_read_within_a_minute_in_both_languages`
//! - permission: an empty message falls back to a phrase: `an_empty_permission_message_falls_back_to_a_phrase`
//! - session_end: an empty reason falls back to a phrase: `an_empty_session_end_reason_falls_back_to_a_phrase`
//! - turn_done: the event text wins over the transcript, and is clipped: `the_event_text_wins_over_the_transcript`

use std::fs;
use std::path::Path;

use super::super::events::AgentHookEvent;
use super::super::phrases::{Locale, phrases_for};
use super::*;
use crate::testing::Scratch;
use crate::testing::gate::names_sh;

fn event() -> AgentEvent {
    AgentEvent {
        at: 1_700_000_000_000.0,
        event: AgentHookEvent::Stop,
        key: "12".into(),
        session_id: "sess-1".into(),
        agent_id: String::new(),
        pane: "%12".into(),
        cwd: "/work/proj".into(),
        transcript: String::new(),
        config_dir: String::new(),
        tool: String::new(),
        sub: String::new(),
        text: String::new(),
        label: String::new(),
    }
}

fn en() -> &'static Phrases {
    phrases_for(Locale::En)
}

fn ru() -> &'static Phrases {
    phrases_for(Locale::Ru)
}

fn no_extra() -> Extra {
    Extra::default()
}

fn say(kind: NoticeKind, e: &AgentEvent, name: &str, extra: &Extra, p: &Phrases) -> Composed {
    compose(kind, e, name, extra, p)
}

/// A transcript whose last answer is `text`, written into `dir`, and its path.
fn transcript(dir: &Scratch, text: &str) -> String {
    let file = dir.path().join("t.jsonl");
    let line = serde_json::json!({ "type": "assistant", "message": { "content": [{ "type": "text", "text": text }] } });
    fs::write(&file, format!("{line}\n")).unwrap();
    file.to_string_lossy().into_owned()
}

fn bom() -> String {
    char::from_u32(0xfeff).unwrap().to_string()
}

/// The titles `compose.test.ts` runs the shell function on.
fn titles() -> Vec<String> {
    let mut all: Vec<String> = [
        "✳ два слова",
        "два слова",
        "✳ Search index rebuild",
        "Search index rebuild",
        "A thing",
        "⚠️ two code points",
        " leading space",
        "x",
        "",
        "✳  two spaces after the glyph",
        "7 days",
        "я иду",
        "é tout",
        "ω omega",
        "中 文",
        "· middle dot",
        "- dash",
        "⠂ braille spinner",
        "→ arrow",
        "🚀 rocket",
    ]
    .map(String::from)
    .to_vec();
    // The edges of the glyph ranges, which the node cases do not reach.
    for cp in [
        0x1fff, 0x2000, 0x2bff, 0x2c00, 0x1efff, 0x1f000, 0x1ffff, 0x7f, 0x80,
    ] {
        all.push(format!("{} word", char::from_u32(cp).unwrap()));
    }
    all
}

/// `untitle_of` of `lib/tagents/names.sh`, run by bash on `title`.
fn shell_untitle(title: &str) -> String {
    names_sh("untitle_of", title, Path::new("/nonexistent"))
}

#[test]
fn untitle_gives_what_the_shell_function_gives() {
    for title in titles() {
        assert_eq!(untitle(&title), shell_untitle(&title), "{title:?}");
    }
}

#[test]
fn untitle_keeps_a_one_letter_word_and_drops_a_symbol_glyph() {
    assert_eq!(untitle("⠂ build agent"), "build agent");
    assert_eq!(untitle("я иду"), "я иду");
    assert_eq!(untitle("🚀 rocket"), "rocket");
    assert_eq!(untitle("✳  two spaces"), "two spaces");
    assert_eq!(untitle("✳"), "✳");
    assert_eq!(untitle(" lead"), " lead");
}

fn name_inputs<'a>(labels: &'a HashMap<String, String>) -> NameInputs<'a> {
    NameInputs {
        session_id: "sess-1",
        pane: "%12",
        pane_title: "✳ pane title",
        label: "ticket-agent",
        cwd: "/work/some-project",
        hostname: "mbp.local",
        labels,
    }
}

fn labels(pairs: &[(&str, &str)]) -> HashMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
        .collect()
}

#[test]
fn a_label_for_the_session_beats_one_for_the_pane() {
    let l = labels(&[("sess-1", "by session"), ("%12", "by pane")]);
    assert_eq!(agent_name(&name_inputs(&l)), "by session");
}

#[test]
fn a_label_for_the_pane_beats_the_pane_title() {
    let l = labels(&[("%12", "by pane")]);
    assert_eq!(agent_name(&name_inputs(&l)), "by pane");
}

#[test]
fn the_pane_title_without_its_glyph_beats_the_label() {
    let l = labels(&[]);
    assert_eq!(agent_name(&name_inputs(&l)), "pane title");
}

#[test]
fn no_title_is_the_label_and_no_label_the_directory() {
    let l = labels(&[]);
    assert_eq!(
        agent_name(&NameInputs {
            pane_title: "",
            ..name_inputs(&l)
        }),
        "ticket-agent"
    );
    assert_eq!(
        agent_name(&NameInputs {
            pane_title: "",
            label: "",
            ..name_inputs(&l)
        }),
        "some-project"
    );
}

#[test]
fn a_title_equal_to_the_hostname_falls_to_the_directory() {
    let l = labels(&[]);
    assert_eq!(
        agent_name(&NameInputs {
            pane_title: "mbp.local",
            ..name_inputs(&l)
        }),
        "some-project"
    );
    assert_eq!(
        agent_name(&NameInputs {
            pane_title: "mbp",
            ..name_inputs(&l)
        }),
        "some-project"
    );
    assert_eq!(
        agent_name(&NameInputs {
            pane_title: "",
            label: "mbp",
            ..name_inputs(&l)
        }),
        "some-project"
    );
}

#[test]
fn a_session_with_no_pane_looks_nothing_up_by_pane() {
    let l = labels(&[("", "must not be used")]);
    assert_eq!(
        agent_name(&NameInputs {
            pane: "",
            pane_title: "",
            ..name_inputs(&l)
        }),
        "ticket-agent"
    );
}

#[test]
fn an_empty_label_is_a_label_and_a_directory_is_named_as_basename_names_it() {
    // `labels.get(..) ?? ..` keeps an empty string, then the empty name falls to the TA_LABEL.
    let l = labels(&[("sess-1", "")]);
    assert_eq!(
        agent_name(&NameInputs {
            pane_title: "✳ ignored",
            ..name_inputs(&l)
        }),
        "ticket-agent"
    );
    let none = labels(&[]);
    for (cwd, name) in [
        ("/", ""),
        ("", ""),
        ("/a/b/", "b"),
        ("a/..", ".."),
        ("a/.", "."),
    ] {
        let inputs = NameInputs {
            pane_title: "",
            label: "",
            cwd,
            ..name_inputs(&none)
        };
        assert_eq!(agent_name(&inputs), name, "{cwd:?}");
    }
}

#[test]
fn turn_done_body_is_the_first_non_empty_line() {
    let dir = Scratch::new();
    let e = AgentEvent {
        transcript: transcript(&dir, "\n\nFirst line\nsecond"),
        ..event()
    };
    assert_eq!(
        say(NoticeKind::TurnDone, &e, "proj", &no_extra(), en()).body,
        "First line"
    );
}

#[test]
fn a_line_is_trimmed_as_javascript_trims_it() {
    let dir = Scratch::new();
    let b = bom();
    let e = AgentEvent {
        transcript: transcript(&dir, &format!("{b}\n {b} \n{b}First{b}\nsecond")),
        ..event()
    };
    assert_eq!(
        say(NoticeKind::TurnDone, &e, "proj", &no_extra(), en()).body,
        "First"
    );
    let only = AgentEvent {
        transcript: transcript(&dir, &format!("{b}\n{b}")),
        ..event()
    };
    assert_eq!(
        say(NoticeKind::TurnDone, &only, "proj", &no_extra(), en()).body,
        "Your move"
    );
}

#[test]
fn turn_done_clips_a_long_line_to_200_characters() {
    let dir = Scratch::new();
    let e = AgentEvent {
        transcript: transcript(&dir, &"x".repeat(500)),
        ..event()
    };
    let body = say(NoticeKind::TurnDone, &e, "proj", &no_extra(), en()).body;
    assert_eq!(body.chars().count(), 200);
    assert!(body.ends_with('…'));
    let exact = AgentEvent {
        transcript: transcript(&dir, &"y".repeat(200)),
        ..event()
    };
    assert_eq!(
        say(NoticeKind::TurnDone, &exact, "proj", &no_extra(), en()).body,
        "y".repeat(200)
    );
}

#[test]
fn the_clip_counts_code_points_and_not_utf16_units() {
    // 199 plain characters and one outside the BMP: 200 code points (201 UTF-16 units) stay whole.
    let rocket = char::from_u32(0x1f680).unwrap();
    let whole = format!("{}{rocket}", "a".repeat(199));
    let e = AgentEvent {
        text: whole.clone(),
        ..event()
    };
    assert_eq!(
        say(NoticeKind::TurnDone, &e, "p", &no_extra(), en()).body,
        whole
    );
    let long = format!("{}{rocket}", "a".repeat(200));
    let e = AgentEvent {
        text: long,
        ..event()
    };
    assert_eq!(
        say(NoticeKind::TurnDone, &e, "p", &no_extra(), en()).body,
        format!("{}…", "a".repeat(199))
    );
}

#[test]
fn turn_done_without_a_transcript_is_your_move() {
    let missing = AgentEvent {
        transcript: "/nonexistent/t.jsonl".into(),
        ..event()
    };
    assert_eq!(
        say(NoticeKind::TurnDone, &missing, "p", &no_extra(), en()).body,
        "Your move"
    );
    assert_eq!(
        say(NoticeKind::TurnDone, &event(), "p", &no_extra(), en()).body,
        "Your move"
    );
}

#[test]
fn the_subtitle_names_the_project_unless_it_is_the_title() {
    let e = event();
    assert_eq!(
        say(NoticeKind::TurnDone, &e, "proj", &no_extra(), en()).subtitle,
        "Answer ready"
    );
    assert_eq!(
        say(NoticeKind::TurnDone, &e, "build agent", &no_extra(), en()).subtitle,
        "Answer ready · proj"
    );
    let no_cwd = AgentEvent {
        cwd: String::new(),
        ..event()
    };
    assert_eq!(
        say(
            NoticeKind::TurnDone,
            &no_cwd,
            "build agent",
            &no_extra(),
            en()
        )
        .subtitle,
        "Answer ready"
    );
    assert_eq!(
        say(NoticeKind::TurnDone, &e, "build agent", &no_extra(), en()).title,
        "build agent"
    );
}

#[test]
fn the_project_is_the_basename_as_node_gives_it() {
    for (cwd, subtitle) in [
        ("/", "Answer ready"),
        (".", "Answer ready · ."),
        ("a/..", "Answer ready · .."),
        ("a/.", "Answer ready · ."),
        ("/work/proj/", "Answer ready · proj"),
    ] {
        let e = AgentEvent {
            cwd: cwd.into(),
            ..event()
        };
        assert_eq!(
            say(NoticeKind::TurnDone, &e, "n", &no_extra(), en()).subtitle,
            subtitle,
            "{cwd:?}"
        );
    }
}

#[test]
fn a_question_says_its_text_and_a_plan_has_its_own_subtitle() {
    let q = say(
        NoticeKind::Question,
        &AgentEvent {
            text: "Which database?".into(),
            ..event()
        },
        "proj",
        &no_extra(),
        en(),
    );
    assert_eq!(q.subtitle, "Asks you something");
    assert_eq!(q.body, "Which database?");
    assert_eq!(
        say(NoticeKind::Question, &event(), "proj", &no_extra(), en()).body,
        "Asking you something"
    );
    let plan = Extra {
        plan: true,
        ..Extra::default()
    };
    assert_eq!(
        say(NoticeKind::Question, &event(), "proj", &plan, en()).subtitle,
        "Plan ready for review"
    );
}

#[test]
fn a_permission_says_its_text() {
    let e = AgentEvent {
        text: "Claude needs your permission to use Bash".into(),
        ..event()
    };
    let c = say(NoticeKind::Permission, &e, "proj", &no_extra(), en());
    assert_eq!(c.subtitle, "Needs your permission");
    assert_eq!(c.body, "Claude needs your permission to use Bash");
}

#[test]
fn a_cache_notice_says_the_minutes() {
    let extra = Extra {
        idle_min: Some(50.0),
        left_min: Some(10.0),
        ..Extra::default()
    };
    let c = say(NoticeKind::CacheExpiring, &event(), "proj", &extra, en());
    assert_eq!(c.subtitle, "Prompt cache expiring");
    assert_eq!(
        c.body,
        "Idle 50 min — send anything within ~10 min to keep the prompt cache"
    );
    let missing = say(
        NoticeKind::CacheExpiring,
        &event(),
        "proj",
        &no_extra(),
        en(),
    );
    assert_eq!(
        missing.body,
        "Idle 0 min — send anything within a minute to keep the prompt cache"
    );
}

#[test]
fn a_session_end_says_its_reason() {
    let e = AgentEvent {
        sub: "prompt_input_exit".into(),
        ..event()
    };
    let end = say(NoticeKind::SessionEnd, &e, "proj", &no_extra(), en());
    assert_eq!(end.subtitle, "Session ended");
    assert_eq!(end.body, "prompt_input_exit");
}

#[test]
fn the_russian_table_speaks_russian() {
    let extra = Extra {
        idle_min: Some(50.0),
        left_min: Some(10.0),
        ..Extra::default()
    };
    let c = say(NoticeKind::CacheExpiring, &event(), "proj", &extra, ru());
    assert!(
        c.subtitle
            .chars()
            .any(|ch| ('а'..='я').contains(&ch.to_lowercase().next().unwrap()))
    );
    assert!(c.body.contains("50") && c.body.contains("10"));
}

#[test]
fn minutes_left_below_one_read_within_a_minute_in_both_languages() {
    let at = |idle: f64, left: f64| Extra {
        idle_min: Some(idle),
        left_min: Some(left),
        ..Extra::default()
    };
    let body = |p: &Phrases, left: f64| {
        say(NoticeKind::CacheExpiring, &event(), "p", &at(55.0, left), p).body
    };
    assert_eq!(
        body(en(), 0.0),
        "Idle 55 min — send anything within a minute to keep the prompt cache"
    );
    assert_eq!(
        body(ru(), 0.0),
        "Простой 55 мин — отправьте что угодно в течение минуты, чтобы сохранить кэш промпта"
    );
    assert!(body(en(), 1.0).contains("within ~1 min"));
    assert!(body(ru(), 5.0).contains("в течение ~5 мин"));
}

#[test]
fn an_empty_permission_message_falls_back_to_a_phrase() {
    let e = event();
    assert_eq!(
        say(NoticeKind::Permission, &e, "p", &no_extra(), en()).body,
        "Waiting for your permission"
    );
    assert_eq!(
        say(NoticeKind::Permission, &e, "p", &no_extra(), ru()).body,
        "Ждёт вашего разрешения"
    );
    let asked = AgentEvent {
        text: "Run rm?".into(),
        ..event()
    };
    assert_eq!(
        say(NoticeKind::Permission, &asked, "p", &no_extra(), en()).body,
        "Run rm?"
    );
}

#[test]
fn an_empty_session_end_reason_falls_back_to_a_phrase() {
    let e = event();
    assert_eq!(
        say(NoticeKind::SessionEnd, &e, "p", &no_extra(), en()).body,
        "No reason given"
    );
    assert_eq!(
        say(NoticeKind::SessionEnd, &e, "p", &no_extra(), ru()).body,
        "Причина не указана"
    );
    let out = AgentEvent {
        sub: "logout".into(),
        ..event()
    };
    assert_eq!(
        say(NoticeKind::SessionEnd, &out, "p", &no_extra(), en()).body,
        "logout"
    );
}

#[test]
fn the_event_text_wins_over_the_transcript() {
    let dir = Scratch::new();
    let file = transcript(&dir, "Older answer");
    let fresh = AgentEvent {
        text: "Fresh answer".into(),
        transcript: file.clone(),
        ..event()
    };
    assert_eq!(
        say(NoticeKind::TurnDone, &fresh, "p", &no_extra(), en()).body,
        "Fresh answer"
    );
    let long = AgentEvent {
        text: "z".repeat(500),
        transcript: file.clone(),
        ..event()
    };
    assert_eq!(
        say(NoticeKind::TurnDone, &long, "p", &no_extra(), en())
            .body
            .chars()
            .count(),
        200
    );
    let read = AgentEvent {
        transcript: file,
        ..event()
    };
    assert_eq!(
        say(NoticeKind::TurnDone, &read, "p", &no_extra(), en()).body,
        "Older answer"
    );
}
