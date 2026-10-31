//! The daemon's log, the node service's: `<ISO time with milliseconds> <the parts joined by a space>` and a newline, on stderr, each line one write, nothing on stdout (`service.ts:413` writes `ctx.log(new Date().toISOString(), ...parts)` and `plugin-run.ts` appends the newline). The engine, the backends and the service write through `Log`, so a test records what they said and reads it as the parts the code gave.

use std::io::Write;

use crate::date;
use crate::notify::clock::{Clock, SystemClock};

/// Where the daemon's lines go. One call is one line; the parts are joined by a space and are not escaped, as node's are not (a part that may hold a newline is written as JSON by its caller).
pub trait Log: Send + Sync {
    fn line(&self, parts: &[&str]);
}

/// The line `Log::line` writes for `parts` at `at_ms`, with its newline.
pub fn render(at_ms: i64, parts: &[&str]) -> String {
    let mut line = date::iso(at_ms);
    for part in parts {
        line.push(' ');
        line.push_str(part);
    }
    line.push('\n');
    line
}

/// The real writer: stderr, the line built whole and handed over in one `write_all`. A stderr that cannot be written (closed, a full pipe) loses the line, as `process.stderr.write` does, and never panics, which `eprintln!` would.
#[derive(Debug, Clone, Copy, Default)]
pub struct StderrLog;

impl Log for StderrLog {
    fn line(&self, parts: &[&str]) {
        let line = render(SystemClock.now_ms() as i64, parts);
        let _ = std::io::stderr().lock().write_all(line.as_bytes());
    }
}

#[cfg(test)]
pub use recording::RecordingLog;

#[cfg(test)]
mod recording {
    use std::sync::{Arc, Mutex};

    use super::Log;
    use crate::sync::locked;

    /// A log a test reads: every call, as the parts it was given, in order. Clones share one record, so the code under test and the test see the same lines.
    #[derive(Debug, Clone, Default)]
    pub struct RecordingLog(Arc<Mutex<Vec<Vec<String>>>>);

    impl RecordingLog {
        pub fn new() -> RecordingLog {
            RecordingLog::default()
        }

        /// Each line as its parts joined by a space, which is what the time-stamped line reads after its time.
        pub fn lines(&self) -> Vec<String> {
            locked(&self.0)
                .iter()
                .map(|parts| parts.join(" "))
                .collect()
        }

        /// Whether any line contains `text`.
        pub fn has(&self, text: &str) -> bool {
            self.lines().iter().any(|line| line.contains(text))
        }
    }

    impl Log for RecordingLog {
        fn line(&self, parts: &[&str]) {
            locked(&self.0).push(parts.iter().map(|part| (*part).to_owned()).collect());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_line_is_the_iso_time_the_parts_joined_by_a_space_and_a_newline() {
        let line = render(1_700_000_000_123, &["started", "pid 7", "backend log"]);
        assert_eq!(line, "2023-11-14T22:13:20.123Z started pid 7 backend log\n");
    }

    #[test]
    fn a_line_with_no_parts_is_the_time_alone_and_a_part_is_not_escaped() {
        assert_eq!(render(0, &[]), "1970-01-01T00:00:00.000Z\n");
        assert_eq!(
            render(0, &["a  b", "c\nd"]),
            "1970-01-01T00:00:00.000Z a  b c\nd\n"
        );
    }

    #[test]
    fn the_recording_log_keeps_each_call_in_order_and_clones_share_it() {
        let log = RecordingLog::new();
        let other = log.clone();
        log.line(&["post", "x"]);
        other.line(&["withdraw", "x"]);
        assert_eq!(log.lines(), ["post x", "withdraw x"]);
        assert!(log.has("withdraw") && !log.has("stopping"));
    }
}
