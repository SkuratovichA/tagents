//! The function of `on_signals` is given the name of the signal that came. A handler registered with `signal-hook` never goes away, so a process that has one swallows SIGINT, SIGTERM and SIGHUP for good: this is a binary of its own, so that no other test shares a process with it.

// Test code: a failed unwrap here is the failure report.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::sync::mpsc;
use std::time::Duration;

use signal_hook::consts::{SIGHUP, SIGINT, SIGTERM};
use signal_hook::low_level::raise;
use tagents_core::ending::on_signals;

#[test]
fn the_function_is_given_the_name_of_the_signal_that_came() {
    // One test for the three: a signal is the process's, so a second test that registers at the same time would hear this one's.
    for (signal, name) in [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT"), (SIGHUP, "SIGHUP")] {
        let (sender, named) = mpsc::channel();
        on_signals(move |name| {
            let _ = sender.send(name);
        })
        .unwrap();
        raise(signal).unwrap();
        assert_eq!(named.recv_timeout(Duration::from_secs(10)), Ok(name));
    }
}
