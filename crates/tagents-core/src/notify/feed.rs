//! What the engine knows of the agent feed (`AgentFeed` of `packages/core/src/agent-events.ts`): the state directory, the state rows and the follower of `events.tsv`. A small trait, so that the engine's tests put a scripted feed in its place, and `FollowerFeed` the one that is real, over `events::Follower` and the `Watch` that wakes it.

use crate::notify::events::{Arming, Delivery, Follower};
use crate::notify::state::{AgentStateRow, read_agent_state};

#[cfg(test)]
mod tests;

/// The feed as the engine uses it. It holds no thread and no timer: the engine calls `wake` when the watch says the events file changed and when `due` has come.
pub trait Feed {
    /// The state directory: the state rows, the labels and `events.tsv` live in it.
    fn dir(&self) -> &str;

    /// `states()`: every row of the state directory, newest first. A directory that cannot be read is no rows.
    fn states(&self) -> Vec<AgentStateRow>;

    /// `follow()`: starts at the end of the events file and returns what was appended meanwhile. `Err` is the text of the error node's `follow` throws, and then nothing is followed.
    fn start(&mut self, now_ms: i64) -> Result<Delivery, String>;

    /// What the events file gained since the last call, with the errors that left it followed and the death that ended it. Nothing before `start`, after `close` or after a death.
    fn wake(&mut self, now_ms: i64) -> Delivery;

    /// When `wake` must be called though the watch says nothing, in epoch milliseconds: the end of the grace of a rotated file.
    fn due(&self) -> Option<i64>;

    /// Stops following. The text is the error node's `close()` throws when the hook's switch cannot be removed. Idempotent.
    fn close(&mut self) -> Option<String>;
}

/// The real feed: `state_dir()` and the `Follower` of its events file, armed on `arming`, which is the service's `Watch`.
pub struct FollowerFeed<'a, A: Arming> {
    arming: &'a A,
    dir: String,
    follower: Option<Follower>,
}

impl<'a, A: Arming> FollowerFeed<'a, A> {
    pub fn new(arming: &'a A, dir: &str) -> Self {
        FollowerFeed {
            arming,
            dir: dir.to_owned(),
            follower: None,
        }
    }
}

impl<A: Arming> Feed for FollowerFeed<'_, A> {
    fn dir(&self) -> &str {
        &self.dir
    }

    fn states(&self) -> Vec<AgentStateRow> {
        read_agent_state(&self.dir)
    }

    fn start(&mut self, now_ms: i64) -> Result<Delivery, String> {
        let (follower, first) = Follower::start(self.arming, &self.dir, now_ms)?;
        self.follower = Some(follower);
        Ok(first)
    }

    fn wake(&mut self, now_ms: i64) -> Delivery {
        match self.follower.as_mut() {
            Some(follower) => follower.wake(self.arming, now_ms),
            None => Delivery::default(),
        }
    }

    fn due(&self) -> Option<i64> {
        self.follower.as_ref()?.due()
    }

    fn close(&mut self) -> Option<String> {
        self.follower.take()?.close()
    }
}
