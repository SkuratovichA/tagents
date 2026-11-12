//! `okb serve`: prints the socket of the shared server of this environment, starting that server when nothing answers, and with `--foreground` is that server.
//!
//! The options are `--idle S`, `--foreground` and `--socket P`, read by `parse_args` as `util.parseArgs` of the node program reads them, strictly. `--idle` is read as `Number` reads it and must be finite and positive. `--socket` is read and left alone unless `--foreground` is given, as the node program does. Two sentences are this verb's own, `badIdle` and `serveFailed`, in the catalogue `texts.json`, in the language `TAGENTS_LOCALE` names.
//!
//! What is asked (`parse`) is kept apart from running it (`answer`), so that a test reads every command line without a daemon or a signal handler; `run` is the program's verb: it installs the handlers for the foreground only, since a signal that came while a server is being looked for has to end the process, as it does in the node program.

use std::{ffi::OsString, path::PathBuf, time::Duration};

use super::{
    daemon::{self, DEFAULT_IDLE_SECONDS},
    paths::Env,
    socket::{self, Detached, Starter},
};
use tagents_core::{
    ending::{self, Stop},
    front_door, js,
    messages::{Locale, Texts},
    parse_args::{self, Kind, Options},
    sessions::{Output, exit},
};

const OPTIONS: &Options = &[
    ("idle", Kind::Text),
    ("foreground", Kind::Flag),
    ("socket", Kind::Text),
];

/// The sentences of the verbs of `okb` in `locale`.
pub fn texts(locale: Locale) -> Result<Texts, serde_json::Error> {
    super::texts(locale)
}

/// What a command line asks for.
#[derive(Debug, PartialEq)]
pub enum Request {
    /// The server itself, on `socket` or on the one of this environment.
    Foreground { socket: Option<PathBuf>, idle: f64 },
    /// The socket of the server of this environment, which is started when none answers.
    Ensure { idle: f64 },
}

/// Why a command line is refused, always with exit code 2.
#[derive(Debug, PartialEq, Eq)]
pub enum Refused {
    /// What `util.parseArgs` of node says, which is worded as node words it.
    Usage(String),
    BadIdle,
}

impl Refused {
    pub fn message(&self, texts: &Texts) -> String {
        match self {
            Refused::Usage(message) => message.clone(),
            Refused::BadIdle => texts.t("badIdle", &[]),
        }
    }
}

/// The request of the words after `serve`.
pub fn parse(args: &[OsString]) -> Result<Request, Refused> {
    let parsed =
        parse_args::parse(args, OPTIONS).map_err(|error| Refused::Usage(error.to_string()))?;
    let idle = parsed.text("idle").map_or(DEFAULT_IDLE_SECONDS, |text| {
        js::number(&text.to_string_lossy())
    });
    if !idle.is_finite() || idle <= 0.0 {
        return Err(Refused::BadIdle);
    }
    Ok(if parsed.flag("foreground") {
        Request::Foreground {
            socket: parsed.text("socket").map(PathBuf::from),
            idle,
        }
    } else {
        Request::Ensure { idle }
    })
}

/// What `serve` writes and its exit code, for `args` with `starter` as what starts a server and `stop` as what ends the foreground.
pub fn answer(
    args: &[OsString],
    texts: &Texts,
    env: &Env,
    starter: &dyn Starter,
    stop: &Stop,
) -> Output {
    match parse(args) {
        Ok(request) => execute(&request, texts, env, starter, stop),
        Err(refused) => refusal(&refused, texts),
    }
}

fn refusal(refused: &Refused, texts: &Texts) -> Output {
    Output {
        stdout: String::new(),
        stderr: format!("{}\n", refused.message(texts)),
        code: exit::USAGE,
    }
}

fn failure(reason: &str, texts: &Texts) -> Output {
    Output {
        stdout: String::new(),
        stderr: format!("{}\n", texts.t("serveFailed", &[("reason", reason)])),
        code: exit::ERROR,
    }
}

fn execute(
    request: &Request,
    texts: &Texts,
    env: &Env,
    starter: &dyn Starter,
    stop: &Stop,
) -> Output {
    let said = match request {
        Request::Foreground { socket, idle } => {
            foreground(socket.as_deref(), *idle, env, starter, stop).map(|()| String::new())
        }
        Request::Ensure { idle } => socket::ensure(env, *idle, starter)
            .map(|socket| format!("{}\n", socket.to_string_lossy())),
    };
    match said {
        Ok(stdout) => Output {
            stdout,
            stderr: String::new(),
            code: exit::OK,
        },
        Err(reason) => failure(&reason, texts),
    }
}

/// The daemon, until it has been idle for `idle` seconds or `stop` comes. One that is already there is left alone, which is no failure.
fn foreground(
    socket: Option<&std::path::Path>,
    idle: f64,
    env: &Env,
    starter: &dyn Starter,
    stop: &Stop,
) -> Result<(), String> {
    let socket = match socket {
        Some(socket) => socket.to_owned(),
        None => socket::default_socket(env, starter)?,
    };
    // A time beyond what a `Duration` holds is as long as one can be.
    let idle = Duration::try_from_secs_f64(idle).unwrap_or(Duration::MAX);
    daemon::run(daemon::Options::new(socket, idle, env.clone()), stop).map(|_| ())
}

/// The verb: `args` are the words after `serve`, the result is the exit code.
pub fn run(args: &[OsString]) -> u8 {
    let locale = Locale::current();
    let texts = match texts(locale) {
        Ok(texts) => texts,
        Err(error) => {
            eprintln!("okb: the texts of serve do not load: {error}");
            return exit::ERROR;
        }
    };
    let request = match parse(args) {
        Ok(request) => request,
        Err(refused) => return finish(&refusal(&refused, &texts)),
    };
    let stop = Stop::default();
    if matches!(request, Request::Foreground { .. }) {
        let signalled = stop.clone();
        if let Err(error) = ending::on_signals(move |_| signalled.stop()) {
            return finish(&failure(&error.to_string(), &texts));
        }
    }
    let starter = match Detached::current() {
        Ok(starter) => starter,
        Err(reason) => return finish(&failure(&reason, &texts)),
    };
    finish(&execute(
        &request,
        &texts,
        &Env::from_process(),
        &starter,
        &stop,
    ))
}

fn finish(out: &Output) -> u8 {
    front_door::print(out);
    out.code
}
