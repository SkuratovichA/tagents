//! `tagents-core mcp --contract <file>`: the plugin's MCP server.
//!
//! One tool per verb of every structured CLI spec the contract records, over stdio, replacing `packages/mcp` (which stays, as the oracle `tests/rust-mcp-parity.sh` compares this server with). The file is read once, at start; a plugin update brings a new file and the next session sees the new tools.
//!
//! `contract` reads the file, `tools` turns it into tools and builds the command line of a call, `run` runs one, `server` is the loop, and `rpc` is the wire. Stdout carries JSON-RPC lines and nothing else: the module denies `print_stdout`, and `rpc::Out` is the only writer.
#![deny(clippy::print_stdout, clippy::dbg_macro)]

pub mod contract;
pub mod rpc;
pub mod run;
pub mod server;
pub mod tools;

use std::collections::HashMap;
use std::ffi::{OsStr, OsString};
use std::io::{self, Read};
use std::process::ExitCode;
use std::sync::Arc;

use crate::sessions::exit;
use crate::{ending, parse_args};
use rpc::Out;
use run::{KILL_GRACE, RunDeps, Runner};
use server::{Config, Identity, SHUTDOWN_MARGIN, Server, Tools};

const USAGE: &str = "usage: tagents-core mcp --contract <contract.json>\n";

/// `util.parseArgs` of node with `{ contract: { type: 'string' } }` and `strict: true`: `--contract <file>` and `--contract=<file>`, the last one winning, and nothing else (`parse_args`).
fn contract_arg(args: &[OsString]) -> Option<OsString> {
    let parsed = parse_args::parse(args, &[("contract", parse_args::Kind::Text)]).ok()?;
    parsed.text("contract").map(OsStr::to_os_string)
}

/// The server: serves the contract's tools on stdin and stdout until the client goes away. The result is the exit code, of a failure to start or of the ending.
pub fn run(args: &[OsString]) -> ExitCode {
    let Some(path) = contract_arg(args) else {
        eprint!("{USAGE}");
        return ExitCode::from(exit::USAGE);
    };
    match serve(&path) {
        Ok(()) => ExitCode::from(exit::OK),
        Err(reason) => {
            eprintln!("tagents-core mcp: {reason}");
            ExitCode::from(exit::ERROR)
        }
    }
}

fn serve(path: &OsString) -> Result<(), String> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("cannot read the contract {}: {e}", path.to_string_lossy()))?;
    let tools = tools::tool_specs(&contract::parse(&text)?)?;
    let env: HashMap<OsString, OsString> = std::env::vars_os().collect();
    let runner = Arc::new(Runner::new(tools, RunDeps::standard(env)));
    let config = Config {
        identity: Identity::PLUGIN,
        kill_grace: KILL_GRACE,
        shutdown_margin: SHUTDOWN_MARGIN,
    };
    serve_stdio(runner, config, io::stdin().lock())
}

/// Serve `tools` to the client on `input` and this process's stdout until the input ends. The client may also go away by a signal: the calls in flight are stopped first, then the process leaves.
pub(crate) fn serve_stdio(
    tools: Arc<dyn Tools>,
    config: Config,
    input: impl Read,
) -> Result<(), String> {
    let server = Server::new(tools, Out::new(io::stdout()), config, || {
        std::process::exit(i32::from(exit::OK))
    });
    let ending = Arc::clone(&server);
    ending::on_signals(move |_| ending.end_and_exit()).map_err(|e| e.to_string())?;
    server.serve(input);
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::os::unix::ffi::OsStringExt;

    use super::*;

    fn arg(words: &[&str]) -> Option<String> {
        let words: Vec<OsString> = words.iter().map(OsString::from).collect();
        contract_arg(&words).map(|v| v.to_string_lossy().into_owned())
    }

    /// Each row is what `parseArgs({ args, options: { contract: { type: 'string' } }, strict: true })` answers on node 22, the value or "throws".
    #[test]
    fn the_arguments_are_read_as_node_parse_args_reads_them_strictly() {
        let table: &[(&[&str], Option<&str>)] = &[
            (&[], None),
            (&["--contract"], None),
            (&["--contract", "f"], Some("f")),
            (&["--contract=f"], Some("f")),
            (&["--contract=f", "--contract=g"], Some("g")),
            (&["--contract", "f", "--contract", "g"], Some("g")),
            (&["--contract", "f", "extra"], None),
            (&["--help"], None),
            (&["--contract", "-x"], None),
            (&["--contract", "-"], Some("-")),
            (&["--contract", "f", "--"], Some("f")),
            (&["--", "--contract", "f"], None),
            (&["--contract="], Some("")),
            (&["--contract", ""], Some("")),
            (&["--contract", "f", "--contract"], None),
            (&["--contract", "--contract=x"], None),
            (&["--contract", "--"], None),
            (&["--contr=f"], None),
            (&["-contract", "f"], None),
            (&["--no-contract"], None),
            (&["--contract=a=b"], Some("a=b")),
            (&["--Contract", "f"], None),
            (&["-c", "f"], None),
            (&["--contract", "f", "-"], None),
        ];
        for (words, expected) in table {
            assert_eq!(arg(words).as_deref(), *expected, "{words:?}");
        }
    }

    #[test]
    fn a_path_that_is_not_utf8_is_still_a_path() {
        let words = [
            OsString::from("--contract"),
            OsString::from_vec(b"/tmp/\xff.json".to_vec()),
        ];
        assert_eq!(
            contract_arg(&words),
            Some(OsString::from_vec(b"/tmp/\xff.json".to_vec()))
        );
    }
}
