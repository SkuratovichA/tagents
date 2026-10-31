//! Is the agent's pane on someone's screen right now, and whose? One tmux process answers both questions, so the answer is one consistent snapshot and the cost is one fork (`parseScreen` and `tmuxScreen` of `packages/notify/src/screen.ts`). The notification skips a pane that is already in front of the person (`skip_visible`) and a click raises the right terminal window, which is what the client pid is for.

use std::process::Command;
use std::time::Duration;

use crate::child::{self, Policy};
use crate::ending::Stop;
use crate::js;

/// What tmux says about a pane that exists.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Screen {
    /// Some client's current window is the pane's window.
    pub visible: bool,
    /// The terminal behind the client that shows the pane, else the most recently active client; none when no client is attached.
    pub client_pid: Option<u32>,
    pub pane_title: String,
}

/// What tmux said that is worth acting on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScreenAnswer {
    Screen(Screen),
    /// tmux answered, and the pane is not there: a pane closed without a `SessionEnd`.
    NoSuchPane,
}

// The fields are joined with this and never with a tab: a literal tab in a tmux format renders as "_" outside a UTF-8 locale, and the LaunchAgent that runs this has none, so every field would merge into one (`lib/tagents/names.sh:181`). The title goes last because it is the one field that carries arbitrary text, and is rejoined from everything after the second separator.
const SEP: &str = "|@|";
/// tmux's own message for a pane it cannot find, which older tmux fails with.
const NO_PANE_MESSAGE: &str = "can't find pane";
/// The cockpit's dashboard session: the terminals attached to it stand in for the viewport that shows a chat inside it.
const DASHBOARD_SESSION: &str = "tagents";
/// How long tmux has to answer before it is stopped.
const PROBE_TIMEOUT: Duration = Duration::from_millis(2000);
/// What node's `execFile` keeps of a stream by default: 1 MiB.
const MAX_BUFFER: usize = 1024 * 1024;

struct Client<'a> {
    activity: f64,
    pid: u32,
    window_id: &'a str,
    tty: &'a str,
    session: &'a str,
}

/// `/^\d+$/`: ASCII digits only, and at least one.
fn is_digits(text: &str) -> bool {
    !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit())
}

/// The client with the greatest activity, the first of equals.
fn most_active<'a, 'c>(clients: impl Iterator<Item = &'a Client<'c>>) -> Option<&'a Client<'c>>
where
    'c: 'a,
{
    let mut best: Option<&Client> = None;
    for c in clients {
        if best.is_none_or(|b| c.activity > b.activity) {
            best = Some(c);
        }
    }
    best
}

/// Parses the output of the probe's tmux command; `None` when it holds no pane line. tmux 3.7 answers for a pane that does not exist with exit 0 and a pane line whose window id is empty, where older ones fail with "can't find pane": both are `NoSuchPane`. A client line whose pid is not a `u32` is skipped (no real pid is that large; node would keep it as a float).
pub fn parse_screen(out: &str) -> Option<ScreenAnswer> {
    let mut pane: Option<(&str, String)> = None;
    let mut viewport_tty = "";
    let mut clients: Vec<Client> = Vec::new();
    for line in out.split('\n') {
        let f: Vec<&str> = line.split(SEP).collect();
        match f[0] {
            "P" if pane.is_none() && f.len() >= 3 => pane = Some((f[1], f[2..].join(SEP))),
            "V" if f.len() == 2 => viewport_tty = f[1],
            "C" if f.len() == 4 || f.len() == 6 => {
                let (activity, pid) = (f[1], f[2]);
                let field = |at: usize| f.get(at).copied().unwrap_or("");
                if let (true, true, Ok(pid)) = (is_digits(activity), is_digits(pid), pid.parse()) {
                    clients.push(Client {
                        activity: js::number(activity),
                        pid,
                        window_id: field(3),
                        tty: field(4),
                        session: field(5),
                    });
                }
            }
            _ => {}
        }
    }
    let (window_id, title) = pane?;
    if window_id.is_empty() {
        return Some(ScreenAnswer::NoSuchPane);
    }
    // The viewport is a nested tmux client: it is never the terminal the person looks at, so it is no candidate for the pid, and a pane it shows is on screen only through the most active terminal attached to the dashboard.
    let viewport = if viewport_tty.is_empty() {
        None
    } else {
        clients.iter().position(|c| c.tty == viewport_tty)
    };
    let real = || {
        clients
            .iter()
            .enumerate()
            .filter(|(at, _)| Some(*at) != viewport)
            .map(|(_, c)| c)
    };
    let direct = most_active(real().filter(|c| c.window_id == window_id));
    let through_viewport = match (direct, viewport) {
        (None, Some(at)) if clients[at].window_id == window_id => {
            most_active(real().filter(|c| c.session == DASHBOARD_SESSION))
        }
        _ => None,
    };
    let showing = direct.or(through_viewport);
    let client = showing.or_else(|| most_active(real()));
    Some(ScreenAnswer::Screen(Screen {
        visible: showing.is_some(),
        client_pid: client.map(|c| c.pid),
        pane_title: title,
    }))
}

/// The probe over a real tmux: the pane's window, its title and every client, in one call. `None` when tmux did not answer, or answered with nothing to read: nothing is known about the pane.
pub fn tmux_screen(pane: &str, stop: &Stop) -> Option<ScreenAnswer> {
    probe(Command::new("tmux"), pane, stop)
}

/// `tmux_screen` with the command to run, so a test can stand a stub in for tmux.
fn probe(mut command: Command, pane: &str, stop: &Stop) -> Option<ScreenAnswer> {
    command.args([
        "display".to_owned(),
        "-p".to_owned(),
        "-t".to_owned(),
        pane.to_owned(),
        format!("P{SEP}#{{window_id}}{SEP}#{{pane_title}}"),
        ";".to_owned(),
        "list-clients".to_owned(),
        "-F".to_owned(),
        format!(
            "C{SEP}#{{client_activity}}{SEP}#{{client_pid}}{SEP}#{{window_id}}{SEP}#{{client_tty}}{SEP}#{{client_session}}"
        ),
        ";".to_owned(),
        "display".to_owned(),
        "-p".to_owned(),
        "-t".to_owned(),
        pane.to_owned(),
        format!("V{SEP}#{{@tagents_viewport_tty}}"),
    ]);
    let policy = Policy {
        input: None,
        timeout: PROBE_TIMEOUT,
        // SIGKILL at the deadline: a tmux that is stuck is not going to handle a polite signal either.
        kill_grace: None,
        drain: Duration::from_millis(250),
        cap: MAX_BUFFER,
    };
    // A tmux that is not installed or not on this service's PATH is the same as it not answering.
    let finished = child::run(command, &policy, stop).ok()?;
    if finished.reason.is_some() {
        return None;
    }
    if finished.code == Some(0) {
        return parse_screen(&finished.stdout);
    }
    // Only tmux saying so counts (older tmux): a missing server or a failed spawn says nothing about the pane.
    finished
        .stderr
        .contains(NO_PANE_MESSAGE)
        .then_some(ScreenAnswer::NoSuchPane)
}

#[cfg(test)]
mod tests;
