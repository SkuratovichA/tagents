//! Time as the engine sees it: a reading of the wall clock in epoch milliseconds. The engine's one timed wait is a `recv_timeout` on its channel, so nothing here sleeps or arms a timer; the deadlines are wall-clock times and the wait they ask for is capped (`deadlines::MAX_SLEEP_MS`) and asked again on every wake, which is what keeps a Mac that slept through a deadline within one cap of it.

use std::time::{SystemTime, UNIX_EPOCH};

/// A reading of the wall clock. `f64` is the type of `AgentEvent::at` and of the deadline arithmetic of `engine.ts`, which `Date.now()` and event times share.
pub trait Clock {
    /// Epoch milliseconds, as `Date.now()` reads them.
    fn now_ms(&self) -> f64;
}

/// The real clock, over `SystemTime`. A clock set before 1970 reads 0.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_ms(&self) -> f64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0.0, |since| since.as_millis() as f64)
    }
}

#[cfg(test)]
pub use fake::FakeClock;

#[cfg(test)]
mod fake {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::Clock;

    /// A clock a test moves by hand. Clones share one reading, so the engine under test and the test move the same clock. The reading is kept as the bits of an `f64` in an atomic: no lock to poison, nothing to unwrap.
    #[derive(Debug, Clone)]
    pub struct FakeClock(Arc<AtomicU64>);

    impl FakeClock {
        pub fn new(start_ms: f64) -> FakeClock {
            FakeClock(Arc::new(AtomicU64::new(start_ms.to_bits())))
        }

        /// Sets the reading: a wall clock that jumps (a sleep, a correction) is a `set`.
        pub fn set(&self, ms: f64) {
            self.0.store(ms.to_bits(), Ordering::SeqCst);
        }

        /// Moves the reading forward by `ms`.
        pub fn advance(&self, ms: f64) {
            self.set(self.now_ms() + ms);
        }
    }

    impl Clock for FakeClock {
        fn now_ms(&self) -> f64 {
            f64::from_bits(self.0.load(Ordering::SeqCst))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_system_clock_reads_the_wall_clock_in_milliseconds() {
        let before = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as f64;
        let read = SystemClock.now_ms();
        let after = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as f64;
        assert!(before <= read && read <= after, "{before} {read} {after}");
        assert_eq!(read.fract(), 0.0, "whole milliseconds");
    }

    #[test]
    fn clones_of_a_fake_clock_share_one_reading() {
        let clock = FakeClock::new(1000.0);
        let seen_by_engine = clock.clone();
        clock.advance(250.0);
        assert_eq!(seen_by_engine.now_ms(), 1250.0);
        seen_by_engine.set(5.0);
        assert_eq!(clock.now_ms(), 5.0);
    }
}
