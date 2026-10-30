## Why

Every Claude Code session starts the plugin's `tagents` MCP server as a node process of its own, `tagents-mcp --contract contract.json`, and each of them holds about 35 MB resident (measured with `footprint` on 30.10.2026): eight sessions keep about 280 MB busy for a server that spends its life waiting on stdin. What the server does is small: it reads newline-delimited JSON-RPC, answers `initialize`, `tools/list` and `tools/call`, and a call runs the program of a contract verb with a bounded output and tells how it ended. The Rust `tagents-core` already ships as a checksummed prebuilt binary, so the runtime is there; the server is a subcommand of it.

The change also builds the stdio layer (framing, request ids, cancellation, orderly shutdown) that the knowledge server will reuse when it moves to Rust, which is why it comes before that server.

## What Changes

- `tagents-core mcp --contract <file>` (new verb, `impl: rust`, `effect: serve`, so it is not itself a tool) serves the plugin's tools over stdio from the contract: the same tools, hints, input schemas, argument rules, result bodies, output cap, timeout and shutdown as `packages/mcp`.
- The installer's `tagents-mcp` command runs `tagents-core mcp` when the native binary is installed and the node server otherwise. `plugin.json` does not change, and a machine without the binary behaves as before.
- `tests/rust-mcp-parity.sh` (new) feeds one script of JSON-RPC requests to the node server and to the Rust server, with stub programs on `PATH`, and compares what they answer; it runs in the Rust workflow.
- The node server stays in the tree as the fallback and the oracle of that suite. Retiring it is a later change.
- The workspace version is raised (the binary has a new verb), and the new dependencies are listed with their reason and cost.

## Capabilities

### New Capabilities

- `rust-mcp`: the MCP server as a verb of the Rust binary: what it answers, how a call runs and ends, what it never does, and how it is kept equal to the node server.

### Modified Capabilities

- `claude-code-plugin`: the `tagents-mcp` command runs the native server when the binary is installed.

## Impact

- Code: `crates/tagents-core/src/mcp/` (new), `crates/tagents-core/src/front_door.rs` (one arm), `crates/tagents-core/src/lib.rs`, `crates/tagents-core/Cargo.toml`, `Cargo.toml` and `Cargo.lock` (dependencies and the version), `spec/cli/tagents-core.json` (one verb), `packages/core/src/i18n/{en,ru}.ts` (its summary), `install.sh` (the wrapper), `.github/workflows/rust.yml` (path filters and the new suite), `tests/rust-mcp-parity.sh` and its node driver (new), `tests/install.sh`.
- Documents: `docs/architecture/rust-core.md` (the server, its dependencies and its limits), the sentences that say node runs the MCP server.
- The generated contract and the skill references gain one entry, the `mcp` verb; no tool is added or changed, because a `serve` verb is not a tool.
- A machine without a release for its version, or with no native binary, keeps running `packages/mcp`.
- New dependencies: `rustix` (process groups), `signal-hook` (end on SIGTERM, SIGINT, SIGHUP), and two features of `serde_json` (`preserve_order`, `arbitrary_precision`). No async runtime.
- Not done: tagging the version this ships in (that needs Sasha's word; until then the installer falls back to node for it), retiring `packages/mcp`, the knowledge and notify servers, a Windows build.
