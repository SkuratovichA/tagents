## Why

The notification service is one long-lived node process per machine, `node packages/notify/dist/main.js run`, started by a LaunchAgent. On 30.10.2026 it held 31 MB (`footprint`, peak 40 MB) after two days and four hours of waiting on a file that changes a few times an hour. What it does is small: it follows the events file the hooks append to, decides which events deserve a notice, keeps one prompt-cache deadline per idle session, and runs a helper app once per notice. The Rust `tagents-core` already ships as a checksummed prebuilt binary and already serves `sessions` and the MCP server, so the runtime is there; the daemon is a verb of it.

The change also builds what the next ports reuse: a file watch that does not poll, a child process that is given input and a deadline, and the ending that every Rust server needs on SIGTERM.

## What Changes

- `tagents-core notify run` (new verb, `impl: rust`, `effect: serve`, so it is not itself a tool) runs the notification service: the same lock, options, stream following, decisions, deadlines, helper calls, log lines, exit codes and shutdown as `packages/notify`. Every other word after `notify` goes to the node CLI as before.
- The installer's `tagents-notify` command runs `tagents-core notify run` when its first argument is `run` and the native binary is installed, and the node program otherwise. The LaunchAgent names that command, so a removed or outdated binary falls back to node at run time and `uninstall` and `install` stay node.
- `notify.toml` is read by the `toml` crate, and the problems of a bad options file are the node daemon's lines, byte for byte, including the texts zod writes. This widens the policy that no parser but `serde_json` is in the tree.
- An options file that is YAML only (`notify.yaml` with no `notify.toml`) is not read by Rust: the daemon starts the node daemon in its place, at start and when a running daemon finds the options moved. A start that fails (a watch that cannot be armed) is handed to the node daemon the same way, so a defect of the new code is not retried every 300 seconds by launchd.
- A directory and file watch (inotify on Linux, kqueue on macOS) follows `events.tsv` and the options directory without polling. The options file is also watched as a file opened with `O_NOFOLLOW`, so a symlink's target is never followed.
- The spawn-with-deadline of the MCP server (`child.rs`) and its ending on a signal (`ending.rs`, with `Stop`) are lifted into modules the daemon shares, with no change to what `mcp` does.
- `tests/rust-notify-parity.sh` (new) starts the node daemon and the Rust daemon on the same scratch state, config and stub helper, feeds both the same events, and compares what they post, log and leave behind. A generated file of vectors pins the helpers that exist twice.
- The workspace version is raised, and the new dependencies are listed with their reason and cost.
- The node daemon stays in the tree as the fallback and as the oracle of that suite. Retiring it is a later change.

## Capabilities

### New Capabilities

- `rust-notify`: the notification service as a verb of the Rust binary: what it reads, how it words an options problem, how it watches, how it hands a YAML options file to node, where it knowingly differs, and how it is kept equal to the node daemon.

### Modified Capabilities

- `claude-code-plugin`: the `tagents-notify` command runs the native daemon for `run` when the binary is installed.
- `notify-service`: the LaunchAgent runs the installer's `tagents-notify` command when there is one.

## Impact

- Code: `crates/tagents-core/src/notify/` (new), `crates/tagents-core/src/child.rs` and `crates/tagents-core/src/ending.rs` (lifted from `mcp/run.rs` and `mcp/server.rs`), `crates/tagents-core/src/watch/` (new), `crates/tagents-core/src/front_door.rs` (one arm and a second forward target), `crates/tagents-core/src/lib.rs`, `crates/tagents-core/Cargo.toml`, `Cargo.toml` and `Cargo.lock` (dependencies, the lint note and the version), `spec/cli/tagents-core.json` (one verb), `packages/core/src/i18n/{en,ru}.ts` (its summary), `packages/notify/src/plugin.ts` (`runSpecFor`), `install.sh` (the wrapper), `.github/workflows/rust.yml` (path filters, the suite and the vectors check), `tests/rust-notify-parity.sh` and its driver, `tests/rust-notify-vectors.mts`, `tests/install.sh`.
- Documents: `docs/architecture/rust-core.md` (the daemon, its dependencies, the parser policy, the known differences), `docs/guide/notifications.md` and the sentences that say node runs the service.
- The generated contract and the skill references gain one entry, the `notify run` verb; no tool is added or changed, because a `serve` verb is not a tool.
- A machine without a release for its version, or with no native binary, keeps running `packages/notify`.
- New dependencies: `toml` (parse only), `kqueue` (macOS only, a safe binding of kqueue because `rustix` declares `kevent` unsafe), and three more features of `rustix` (`fs` for inotify, `pipe`, `system` for the host name). No async runtime.
- Not done: tagging the version this ships in (that needs Sasha's word; until then the installer falls back to node for it), retiring `packages/notify`, the knowledge server, `install`, `uninstall`, `status`, `test` and `send` in Rust, a YAML reader, a notification backend for Linux, a Windows build.
- Assumes `rust-mcp` (#38) is merged: this change lifts code that exists only there and copies its wrapper seam.
