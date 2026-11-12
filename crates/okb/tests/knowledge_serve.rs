//! `tagents-core knowledge serve`: the options it reads as `util.parseArgs` and `Number` read them in the node program, what it prints, and its two sentences in both languages. The argument table is the one `tests/rust-knowledge-vectors/process.mts` runs through the node program (`process.serve` of the knowledge vectors): the Rust parser is pinned by the exit code and the option or the word the refusal names, and by the whole sentence where the sentence is the catalogue's own.

#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::{ffi::OsString, fs, path::Path, sync::atomic::Ordering, thread, time::Duration};

use okb::knowledge::{
    daemon::DEFAULT_IDLE_SECONDS,
    serve::{Refused, Request, answer, parse, texts},
    socket::{Ended, Launch, Starter},
    status,
};
use serde_json::Value;
use tagents_core::{ending::Stop, js, messages::Locale, sessions::Output};

use common::{
    knowledge::vectors,
    rig::until,
    shared::{Daemon, InProcess, ensured_socket, env_in, options},
    short_scratch,
};

/// The words a case of the vectors is run with: the node driver puts `--foreground --socket <socket>` first and the arguments of the case after them, so that a missing value takes nothing from what the driver added.
fn words(case: &Value, socket: &str) -> Vec<OsString> {
    ["--foreground", "--socket", socket]
        .into_iter()
        .map(OsString::from)
        .chain(
            case["args"]
                .as_array()
                .unwrap()
                .iter()
                .map(|word| OsString::from(word.as_str().unwrap().replace("{socket}", socket))),
        )
        .collect()
}

fn args(words: &[&str]) -> Vec<OsString> {
    words.iter().map(OsString::from).collect()
}

fn cases() -> &'static Vec<Value> {
    vectors()["process"]["serve"].as_array().unwrap()
}

/// The value `--idle` has in the words of a case, as the last one given wins.
fn idle_of(case: &Value) -> f64 {
    let words: Vec<&str> = case["args"]
        .as_array()
        .unwrap()
        .iter()
        .map(|word| word.as_str().unwrap())
        .collect();
    let mut idle = DEFAULT_IDLE_SECONDS;
    let mut at = 0;
    while at < words.len() {
        match words[at] {
            "--idle" => {
                idle = js::number(words[at + 1]);
                at += 1;
            }
            word => {
                if let Some(value) = word.strip_prefix("--idle=") {
                    idle = js::number(value);
                }
            }
        }
        at += 1;
    }
    idle
}

fn english() -> tagents_core::messages::Texts {
    texts(Locale::En).unwrap()
}

#[test]
fn the_argument_table_of_the_node_program_is_refused_and_taken_as_it_does() {
    assert_eq!(63, cases().len(), "the table has changed: read it again");
    let en = english();
    let mut refused = 0;
    let mut taken = 0;
    for case in cases() {
        let at = format!("{}", case["args"]);
        let result = parse(&words(case, "/s/x.sock"));
        match case["exit"].as_u64().unwrap() {
            1 => {
                let Ok(Request::Foreground { socket, idle }) = result else {
                    panic!("{at}: {result:?} is not a request to serve in the foreground");
                };
                assert_eq!(Some("/s/x.sock".into()), socket, "{at}");
                assert_eq!(idle_of(case), idle, "{at}");
                taken += 1;
            }
            2 => {
                let Err(refusal) = result else {
                    panic!("{at}: taken, and node exits 2");
                };
                let stderr = case["stderr"].as_str().unwrap();
                match (case["option"].as_str(), case["positional"].as_str()) {
                    (Some(option), _) => {
                        let Refused::Usage(message) = &refusal else {
                            panic!("{at}: {refusal:?}, and node names {option}");
                        };
                        assert!(message.contains(&format!("'{option}")), "{at}: {message}");
                    }
                    (None, Some(positional)) => {
                        let Refused::Usage(message) = &refusal else {
                            panic!("{at}: {refusal:?}, and node names the word {positional:?}");
                        };
                        assert!(
                            message.contains(&format!("Unexpected argument '{positional}'")),
                            "{at}: {message}"
                        );
                    }
                    (None, None) => {
                        assert_eq!(Refused::BadIdle, refusal, "{at}");
                        assert_eq!(stderr, format!("{}\n", refusal.message(&en)), "{at}");
                    }
                }
                refused += 1;
            }
            other => panic!("{at}: node exits {other}, which `serve` never does here"),
        }
    }
    // The two kinds are both there, so that a table that lost one fails here.
    assert!(
        refused >= 40 && taken >= 15,
        "refused {refused}, taken {taken}"
    );
}

/// Where the cases of the vectors fail to start: below a regular file, so that no directory can be made.
fn socket_below_a_file(dir: &Path) -> String {
    let file = dir.join("regular-file");
    fs::write(&file, "").unwrap();
    file.join("x.sock").to_str().unwrap().to_owned()
}

#[test]
fn a_server_that_cannot_start_says_why_as_the_node_program_does_and_exits_1() {
    let dir = short_scratch("serve-fail");
    let socket = socket_below_a_file(&dir);
    let env = env_in(&dir);
    let en = english();
    let starter = InProcess::default();
    let mut served = 0;
    for case in cases().iter().filter(|case| case["exit"] == 1) {
        let Output {
            stdout,
            stderr,
            code,
        } = answer(&words(case, &socket), &en, &env, &starter, &Stop::default());
        let at = format!("{}", case["args"]);
        let want = case["stderr"]
            .as_str()
            .unwrap()
            .replace("<dir>", dir.to_str().unwrap());
        assert_eq!(
            ("", want.as_str(), 1),
            (stdout.as_str(), stderr.as_str(), code),
            "{at}"
        );
        served += 1;
    }
    assert_eq!(17, served);
    assert_eq!(0, starter.starts.load(Ordering::SeqCst));
}

#[test]
fn an_idle_time_too_large_for_a_duration_or_too_small_to_count_is_no_panic() {
    let dir = short_scratch("serve-huge");
    let socket = socket_below_a_file(&dir);
    let env = env_in(&dir);
    for idle in ["1e308", "1.7976931348623157e308", "5e-324"] {
        let out = answer(
            &args(&["--foreground", "--socket", &socket, "--idle", idle]),
            &english(),
            &env,
            &InProcess::default(),
            &Stop::default(),
        );
        assert_eq!(1, out.code, "{idle}: {}", out.stderr);
        assert!(out.stderr.contains("EEXIST"), "{idle}: {}", out.stderr);
    }
}

#[test]
fn idle_is_read_as_number_reads_it_and_must_be_finite_and_positive() {
    // Written `--idle=<value>`, so that a value that starts with a dash is a value.
    let idle = |value: &str| {
        parse(&[OsString::from(format!("--idle={value}"))]).map(|request| match request {
            Request::Ensure { idle } => idle,
            other => panic!("{other:?}"),
        })
    };
    for (text, number) in [
        ("5", 5.0),
        ("0.5", 0.5),
        ("1e3", 1000.0),
        (" 5 ", 5.0),
        ("\t5\n", 5.0),
        ("0x10", 16.0),
        ("0b11", 3.0),
        ("0o17", 15.0),
        (".5", 0.5),
        ("5.", 5.0),
        ("+5", 5.0),
        ("00012", 12.0),
        ("1e308", 1e308),
        ("5e-324", 5e-324),
    ] {
        assert_eq!(Ok(number), idle(text), "{text:?}");
    }
    for text in [
        "0",
        "-0",
        "-5",
        "-Infinity",
        "Infinity",
        "NaN",
        "1e999",
        "",
        "   ",
        "0x",
        "0x1g",
        "1_0",
        "5 6",
        "5px",
        "١٢",
    ] {
        assert_eq!(Err(Refused::BadIdle), idle(text), "{text:?}");
    }
}

#[test]
fn without_foreground_the_server_is_looked_for_and_the_socket_option_is_read_and_left_alone() {
    assert_eq!(
        Ok(Request::Ensure {
            idle: DEFAULT_IDLE_SECONDS
        }),
        parse(&[])
    );
    assert_eq!(600.0, DEFAULT_IDLE_SECONDS);
    assert_eq!(
        Ok(Request::Ensure { idle: 30.0 }),
        parse(&args(&["--idle", "30", "--socket", "/a/b.sock"]))
    );
    assert_eq!(
        Ok(Request::Foreground {
            socket: None,
            idle: DEFAULT_IDLE_SECONDS
        }),
        parse(&args(&["--foreground"]))
    );
    // A socket given twice is the last one, as node's `parseArgs` has it.
    assert_eq!(
        Ok(Request::Foreground {
            socket: Some("/b".into()),
            idle: 5.0
        }),
        parse(&args(&[
            "--socket=/a",
            "--idle",
            "5",
            "--foreground",
            "--socket",
            "/b"
        ]))
    );
}

#[test]
fn serve_prints_the_socket_of_the_server_it_finds_or_starts_and_nothing_else() {
    let dir = short_scratch("serve-ensure");
    let env = env_in(&dir);
    let starter = InProcess::default();
    let socket = ensured_socket(&dir);
    for _ in 0..2 {
        let out = answer(
            &args(&["--idle", "30"]),
            &english(),
            &env,
            &starter,
            &Stop::default(),
        );
        assert_eq!(
            Output {
                stdout: format!("{}\n", socket.display()),
                stderr: String::new(),
                code: 0
            },
            out
        );
    }
    assert_eq!(1, starter.starts.load(Ordering::SeqCst));
    starter.stop_all();
}

/// A starter whose process cannot be run.
struct Missing;

impl Starter for Missing {
    fn stamp(&self) -> Result<String, String> {
        Ok("test".to_owned())
    }

    fn start(&self, _: &Launch<'_>) -> std::io::Result<Ended> {
        Err(std::io::Error::from(std::io::ErrorKind::NotFound))
    }
}

#[test]
fn a_server_that_cannot_be_started_is_exit_1_and_the_sentence_of_the_locale() {
    let dir = short_scratch("serve-missing");
    let env = env_in(&dir);
    for (locale, head) in [
        (Locale::En, "could not start the shared knowledge server: "),
        (Locale::Ru, "не удалось запустить общий сервер знаний: "),
    ] {
        let out = answer(
            &[],
            &texts(locale).unwrap(),
            &env,
            &Missing,
            &Stop::default(),
        );
        assert_eq!((String::new(), 1), (out.stdout.clone(), out.code));
        assert!(out.stderr.starts_with(head), "{}", out.stderr);
        assert!(out.stderr.ends_with("\n"), "{}", out.stderr);
        assert!(
            out.stderr.contains("cannot start the knowledge server"),
            "{}",
            out.stderr
        );
    }
}

#[test]
fn the_foreground_is_the_daemon_itself_until_it_is_stopped_and_it_leaves_no_socket() {
    let dir = short_scratch("serve-fg");
    let env = env_in(&dir);
    let socket = dir.join("s.sock");
    let stop = Stop::default();
    let running = thread::spawn({
        let (stop, socket, env) = (stop.clone(), socket.clone(), env.clone());
        move || {
            answer(
                &args(&["--foreground", "--socket", socket.to_str().unwrap()]),
                &english(),
                &env,
                &InProcess::default(),
                &stop,
            )
        }
    });
    assert!(until(|| socket.exists(), 5000), "no daemon listened");
    stop.stop();
    let out = running.join().unwrap();
    assert_eq!(
        Output {
            stdout: String::new(),
            stderr: String::new(),
            code: 0
        },
        out
    );
    assert!(!socket.exists());
}

#[test]
fn the_foreground_beside_a_server_that_answers_leaves_it_alone_and_is_not_an_error() {
    let dir = short_scratch("serve-taken");
    let held = Daemon::start(options(&dir, Duration::from_secs(60)));
    let out = answer(
        &args(&["--foreground", "--socket", held.socket.to_str().unwrap()]),
        &english(),
        &env_in(&dir),
        &InProcess::default(),
        &Stop::default(),
    );
    assert_eq!(0, out.code);
    assert_eq!(("", ""), (out.stdout.as_str(), out.stderr.as_str()));
    assert!(held.socket.exists());
}

#[test]
fn the_two_sentences_are_the_catalogues_in_both_languages() {
    let en = texts(Locale::En).unwrap();
    let ru = texts(Locale::Ru).unwrap();
    assert_eq!(
        "--idle must be a positive number of seconds",
        Refused::BadIdle.message(&en)
    );
    assert_eq!(
        "--idle — положительное число секунд",
        Refused::BadIdle.message(&ru)
    );
    assert_eq!(
        "could not start the shared knowledge server: boom",
        en.t("serveFailed", &[("reason", "boom")])
    );
    assert_eq!(
        "не удалось запустить общий сервер знаний: boom",
        ru.t("serveFailed", &[("reason", "boom")])
    );
    // A refusal of the parser is node's sentence in either language.
    let usage = Refused::Usage("Unknown option '--x'".to_owned());
    assert_eq!("Unknown option '--x'", usage.message(&ru));
}

#[test]
fn join_takes_no_argument_serve_is_strict_and_any_other_word_is_a_usage_error() {
    assert_eq!(2, status(&args(&["join", "x"])));
    assert_eq!(2, status(&args(&["serve", "--bogus"])));
    assert_eq!(2, status(&args(&["frobnicate"])));
    assert_eq!(2, status(&[]));
}
