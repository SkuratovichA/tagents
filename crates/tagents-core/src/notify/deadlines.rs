//! The prompt-cache scheduler of `packages/notify/src/deadlines.ts`: "wake me when this session has been idle long enough", for any number of sessions. Node arms one timer; here the engine's one timed wait asks `wait` how long it may block and `take_due` which keys have come due, so the scheduler is a list and a minimum and holds no timer.
//!
//! The wait is capped at five minutes and the wall clock is read again on every wake, because a cache's time-to-live runs in wall time and a monotonic wait does not count the time a Mac spent asleep: one long wait for "47 minutes from now" would end hours late after a lid close, and a short one bounds the lateness to one cap after the machine wakes.

use std::time::Duration;

/// The longest the engine waits for the next deadline before it reads the wall clock again, as `MAX_SLEEP_MS` of `deadlines.ts`.
pub const MAX_SLEEP_MS: f64 = 5.0 * 60_000.0;

/// A key whose time has come, with the idle-since it was armed with.
#[derive(Debug, Clone, PartialEq)]
pub struct Due {
    pub key: String,
    pub idle_since: f64,
}

#[derive(Debug)]
struct Entry {
    key: String,
    idle_since: f64,
    due_at: f64,
}

/// Keys waiting for their time, in the order a `Map` keeps them: arming a key again replaces its deadline where it stands.
#[derive(Debug, Default)]
pub struct Deadlines {
    waiting: Vec<Entry>,
}

impl Deadlines {
    pub fn new() -> Deadlines {
        Deadlines::default()
    }

    /// Wakes `key` at `due_at`; arming a key again replaces its deadline and keeps its place in the order.
    pub fn arm(&mut self, key: &str, idle_since: f64, due_at: f64) {
        match self.waiting.iter_mut().find(|entry| entry.key == key) {
            Some(entry) => {
                entry.idle_since = idle_since;
                entry.due_at = due_at;
            }
            None => self.waiting.push(Entry {
                key: key.to_owned(),
                idle_since,
                due_at,
            }),
        }
    }

    pub fn cancel(&mut self, key: &str) {
        self.waiting.retain(|entry| entry.key != key);
    }

    /// How many keys are waiting.
    pub fn armed(&self) -> usize {
        self.waiting.len()
    }

    /// How long the engine may block before it must look again: until the earliest deadline, never negative and never more than `MAX_SLEEP_MS`. `None` when nothing waits, so that no wake is owed for the deadlines at all.
    pub fn wait(&self, now: f64) -> Option<Duration> {
        let earliest = self
            .waiting
            .iter()
            .map(|entry| entry.due_at)
            .reduce(f64::min)?;
        // `max` then `min` and not `clamp`: a NaN deadline waits not at all, where `clamp` would hand `Duration` a NaN and panic.
        #[allow(clippy::manual_clamp)]
        let ms = (earliest - now).max(0.0).min(MAX_SLEEP_MS);
        Some(Duration::from_secs_f64(ms / 1000.0))
    }

    /// Removes and returns every key whose time has passed by the clock `now`, in the order they were armed. The engine runs them as jobs behind what it already holds, so a job that cancels a key cancels it only if it is armed again: the due ones are already out of the list, as in `wake` of `deadlines.ts`, whose `onDue` only enqueues.
    pub fn take_due(&mut self, now: f64) -> Vec<Due> {
        let (due, waiting): (Vec<Entry>, Vec<Entry>) = std::mem::take(&mut self.waiting)
            .into_iter()
            .partition(|entry| entry.due_at <= now);
        self.waiting = waiting;
        due.into_iter()
            .map(|entry| Due {
                key: entry.key,
                idle_since: entry.idle_since,
            })
            .collect()
    }
}

#[cfg(test)]
mod tests;
