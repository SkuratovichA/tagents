//! The `tagents-core` program: see `front_door`.
use std::process::ExitCode;

fn main() -> ExitCode {
    tagents_core::front_door::run(std::env::args_os().skip(1).collect())
}
