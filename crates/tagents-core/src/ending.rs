//! How a process ends: the token a call carries to be told to stop, and the thread that turns a signal into one call of a function. `mcp` ends its calls and then its process with them, and the notification daemon stops its loop with the same two.

use std::io;
use std::sync::{Arc, Mutex};

use signal_hook::consts::{SIGHUP, SIGINT, SIGTERM};
use signal_hook::iterator::Signals;

use crate::sync::locked;

/// Says that a call has to stop: the client cancelled its request, or the process is closing. It is the SDK's `AbortSignal`.
#[derive(Clone, Default)]
pub struct Stop(Arc<Mutex<StopState>>);

#[derive(Default)]
struct StopState {
    stopped: bool,
    watchers: Vec<Box<dyn FnOnce() + Send>>,
}

impl Stop {
    /// Idempotent. The watchers run on the calling thread, once each, outside the lock.
    pub fn stop(&self) {
        let watchers = {
            let mut state = locked(&self.0);
            state.stopped = true;
            std::mem::take(&mut state.watchers)
        };
        for watcher in watchers {
            watcher();
        }
    }

    pub fn is_stopped(&self) -> bool {
        locked(&self.0).stopped
    }

    /// Runs `watcher` when the stop comes, at once when it has come. A watcher is kept until the stop comes, so a stop that several calls share keeps one per call: a call that outlives many others takes a stop of its own.
    pub fn watch(&self, watcher: impl FnOnce() + Send + 'static) {
        let mut state = locked(&self.0);
        if state.stopped {
            drop(state);
            watcher();
        } else {
            state.watchers.push(Box::new(watcher));
        }
    }
}

/// Calls `f`, on a thread of its own, at the first SIGTERM, SIGINT or SIGHUP. A later signal is caught and ignored: the ending `f` starts is over within the grace of the calls it stops and a margin, and leaving before it ends would leave a program that ignores SIGTERM without its SIGKILL. An `Err` says which of the two things it needs, the signal registration and the thread, the system refused.
pub fn on_signals(f: impl FnOnce() + Send + 'static) -> io::Result<()> {
    let mut signals = Signals::new([SIGTERM, SIGINT, SIGHUP])
        .map_err(|e| io::Error::new(e.kind(), format!("cannot watch for signals: {e}")))?;
    std::thread::Builder::new()
        .name("tagents-signals".into())
        .spawn(move || {
            if signals.forever().next().is_some() {
                f();
            }
        })
        .map(drop)
        .map_err(|e| io::Error::new(e.kind(), format!("cannot start a thread: {e}")))
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    /// A watcher that counts how often it ran.
    fn counting(runs: &Arc<AtomicUsize>) -> impl FnOnce() + Send + 'static {
        let runs = Arc::clone(runs);
        move || {
            runs.fetch_add(1, Ordering::SeqCst);
        }
    }

    #[test]
    fn a_stop_runs_each_watcher_once_however_often_it_comes() {
        let stop = Stop::default();
        let runs = Arc::new(AtomicUsize::new(0));
        stop.watch(counting(&runs));
        stop.watch(counting(&runs));
        assert!(!stop.is_stopped());
        assert_eq!(runs.load(Ordering::SeqCst), 0);
        stop.stop();
        stop.stop();
        assert!(stop.is_stopped());
        assert_eq!(runs.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn a_watcher_added_after_the_stop_runs_at_once_and_a_clone_shares_the_stop() {
        let stop = Stop::default();
        let other = stop.clone();
        other.stop();
        assert!(stop.is_stopped());
        let runs = Arc::new(AtomicUsize::new(0));
        stop.watch(counting(&runs));
        assert_eq!(runs.load(Ordering::SeqCst), 1);
    }
}
