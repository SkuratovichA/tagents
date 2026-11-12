//! `tagents-core knowledge join`: connects the standard streams of a session to the shared knowledge server, starting it when none answers.
//!
//! It is a byte relay and adds three things to a copy. When the input ends it shuts the writing half of the connection and goes on copying replies until the server closes it, then exits 0. When the connection ends before the first reply byte it connects once more and sends again what it had sent, which covers a server that left as the session arrived. When the connection ends after a reply byte with the input still open the server died in the middle of the session: it exits 1 with a line on stderr, so that the client sees its server die and reconnects. A server that cannot be had at all is no error: the session is served by this process, as `mcp` serves it.
//!
//! What was sent is kept up to `REPLAY_CAP` bytes and dropped at the first reply byte, so that a session of any length costs a buffer of one chunk. The relay never reads the bytes it copies, so it cannot tell a request that was half served from one that was not: a crash is better seen than hidden, and there is no replay after a reply.
//!
//! `relay` takes its streams and the two ways out as arguments so that a test runs it on a pipe against a server it scripts connection by connection.

use std::{
    ffi::OsString,
    io::{self, Cursor, Read, Write},
    net::Shutdown,
    os::{
        fd::{AsFd, BorrowedFd, OwnedFd},
        unix::net::UnixStream,
    },
    sync::Mutex,
    thread,
};

use rustix::{
    event::{PollFd, PollFlags, poll},
    io::Errno,
};

use super::{
    USAGE,
    daemon::DEFAULT_IDLE_SECONDS,
    mcp,
    paths::Env,
    socket::{self, Detached},
};
use tagents_core::{sessions::exit, sync::locked, watch};

/// What is kept of what was sent before the first reply byte: the most a retry can send again.
pub const REPLAY_CAP: usize = 64 * 1024;

/// The line `join` ends with when the server goes after it has answered.
pub const WENT_AWAY: &str = "tagents-knowledge: the shared server went away";

/// How much is copied at a time.
const CHUNK: usize = 8 * 1024;

#[derive(Clone, Copy, Default, PartialEq, Eq)]
enum Kept {
    /// Everything sent so far is in `bytes`.
    #[default]
    All,
    /// More was sent than `REPLAY_CAP`, so a retry could not send it again.
    TooMuch,
    /// A reply byte came, after which nothing is kept and nothing is retried.
    Replied,
}

/// What both directions know of the session. The upstream records what it sends before it sends it, so that what a retry sends again is never less than what the server may have read.
#[derive(Default)]
struct Sent {
    bytes: Vec<u8>,
    kept: Kept,
    /// The input has ended.
    ended: bool,
}

impl Sent {
    fn record(&mut self, chunk: &[u8]) {
        if self.kept != Kept::All {
            return;
        }
        if self.bytes.len() + chunk.len() > REPLAY_CAP {
            self.kept = Kept::TooMuch;
            self.bytes = Vec::new();
        } else {
            self.bytes.extend_from_slice(chunk);
        }
    }

    fn replied(&mut self) {
        self.kept = Kept::Replied;
        self.bytes = Vec::new();
    }

    /// Whether a connection that ended with no reply is worth another. A session that has sent nothing and has not ended waits for the server it would have had, so it retries too; one that has ended with nothing sent has nothing to ask.
    fn retryable(&self) -> bool {
        self.kept == Kept::All && (!self.bytes.is_empty() || !self.ended)
    }
}

/// How one connection ended.
enum Ended {
    /// The server closed it.
    Closed,
    /// Whoever reads the replies is gone.
    OutputGone,
}

/// Copies `input` to the server and its replies to `output` until the session is over, and returns the exit code.
///
/// `connect` gives a connection to the shared server, starting it when none answers. `serve_here` serves the session in this process, from the bytes that were read already followed by the rest of the input, and is what is left when `connect` fails.
pub fn relay(
    input: BorrowedFd<'_>,
    output: &mut dyn Write,
    errors: &mut dyn Write,
    connect: &dyn Fn() -> Result<UnixStream, String>,
    serve_here: &mut dyn FnMut(Vec<u8>) -> u8,
) -> u8 {
    let Ok((woken, wake)) = watch::wake_pipe() else {
        return serve_here(Vec::new());
    };
    let sent = Mutex::new(Sent::default());
    let mut retried = false;
    loop {
        let replay = locked(&sent).bytes.clone();
        let Ok(link) = connect() else {
            return serve_here(replay);
        };
        let ended = thread::scope(|scope| {
            scope.spawn(|| forward(input, &woken, &link, &replay, &sent));
            let ended = copy_replies(&link, &sent, output);
            // The upstream may be waiting for the input or for a server that no longer reads.
            let _ = link.shutdown(Shutdown::Both);
            watch::wake(&wake);
            ended
        });
        watch::drain(&woken);
        let sent = locked(&sent);
        if matches!(ended, Ended::OutputGone) {
            return exit::OK;
        }
        if !retried && sent.retryable() {
            retried = true;
            continue;
        }
        if sent.ended {
            return exit::OK;
        }
        let _ = writeln!(errors, "{WENT_AWAY}");
        return exit::ERROR;
    }
}

/// The input to the server: first what a retry sends again, then the input as it comes, until it ends, `cancel` is woken or the server stops reading.
fn forward(
    input: BorrowedFd<'_>,
    cancel: &OwnedFd,
    mut link: &UnixStream,
    replay: &[u8],
    sent: &Mutex<Sent>,
) {
    if link.write_all(replay).is_err() {
        return;
    }
    let mut chunk = [0; CHUNK];
    loop {
        let mut fds = [
            PollFd::new(&input, PollFlags::IN),
            PollFd::new(cancel, PollFlags::IN),
        ];
        match poll(&mut fds, None) {
            Ok(_) => {}
            Err(Errno::INTR) => continue,
            Err(_) => return,
        }
        if !fds[1].revents().is_empty() {
            return;
        }
        if fds[0].revents().is_empty() {
            continue;
        }
        match rustix::io::read(input, &mut chunk) {
            Err(Errno::INTR | Errno::AGAIN) => {}
            Ok(n) if n > 0 => {
                locked(sent).record(&chunk[..n]);
                if link.write_all(&chunk[..n]).is_err() {
                    return;
                }
            }
            // The end of the input, or an input that cannot be read any more.
            _ => {
                locked(sent).ended = true;
                let _ = link.shutdown(Shutdown::Write);
                return;
            }
        }
    }
}

/// The replies to `output` until the server closes the connection or `output` cannot be written. A connection that fails to read is a closed one.
fn copy_replies(mut link: &UnixStream, sent: &Mutex<Sent>, output: &mut dyn Write) -> Ended {
    let mut chunk = [0; CHUNK];
    loop {
        let n = match link.read(&mut chunk) {
            Ok(0) => return Ended::Closed,
            Ok(n) => n,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return Ended::Closed,
        };
        locked(sent).replied();
        if output
            .write_all(&chunk[..n])
            .and_then(|()| output.flush())
            .is_err()
        {
            return Ended::OutputGone;
        }
    }
}

/// The verb: `join` takes no argument, and it relays this process's standard streams to the server of the environment.
pub fn run(args: &[OsString]) -> u8 {
    if !args.is_empty() {
        eprint!("{USAGE}");
        return exit::USAGE;
    }
    let env = Env::from_process();
    let connect = || {
        let starter = Detached::current()?;
        let socket = socket::ensure(&env, DEFAULT_IDLE_SECONDS, &starter)?;
        UnixStream::connect(socket).map_err(|e| e.to_string())
    };
    let stdin = io::stdin();
    relay(
        stdin.as_fd(),
        &mut io::stdout(),
        &mut io::stderr(),
        &connect,
        &mut |replay| mcp::serve(Cursor::new(replay).chain(io::stdin())),
    )
}
