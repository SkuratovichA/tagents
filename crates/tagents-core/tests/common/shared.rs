//! What a test of the MCP server loop shares: a read that gives up every half second, as the shared server's connections do.

use std::{
    io::{self, ErrorKind, Read},
    os::unix::net::UnixStream,
    time::Duration,
};

/// Makes a read of the stream wait half a second at most, as the daemon does for its connections: with `Ticks` it is the one way a scripted server of a test reads.
pub fn ticking(stream: &UnixStream) {
    stream
        .set_read_timeout(Some(Duration::from_millis(500)))
        .unwrap();
}

/// A stream read in ticks (see `ticking`): a read that timed out is made again, and a lost wakeup of the reader is found at the next one.
pub struct Ticks<'a>(pub &'a UnixStream);

impl Read for Ticks<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        loop {
            match self.0.read(buf) {
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
                read => return read,
            }
        }
    }
}
