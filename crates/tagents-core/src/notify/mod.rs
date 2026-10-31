//! The notification daemon, `tagents-core notify run`: the port of `packages/notify` (`service.ts`, `engine.ts` and what they call) that the OpenSpec change `rust-notify` describes. The node daemon stays as the fallback and as the oracle of `tests/rust-notify-parity.sh`; `tests/rust-notify-vectors.mts` pins every ported helper against the node function it copies.

pub mod clock;
pub mod compose;
pub mod deadlines;
pub mod engine;
pub mod events;
pub mod feed;
pub mod hand_over;
pub mod helper;
pub mod kinds;
pub mod lock;
pub mod log;
pub mod notifier;
pub mod options;
pub mod phrases;
pub mod platform;
pub mod screen;
pub mod service;
pub mod state;
