//! The `okb` program: see `okb::knowledge`.
use std::process::ExitCode;

fn main() -> ExitCode {
    okb::knowledge::run(&std::env::args_os().skip(1).collect::<Vec<_>>())
}
