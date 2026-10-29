# Proposal

## Why

A Claude Code session with the tagents plugin can read the contract and search the notes, but it cannot do the three things the owner does all day through tagents: put a desktop notification up through tagents' own notifier, open another Claude Code session on a chosen account as a window the dashboard lists (several in a row is how a working day starts), and open a window in a directory running a command. The only MCP tools the plugin offers are the knowledge ones, and a tool written by hand for each verb would be one more place to forget when a verb is added.

The tool surface is therefore generated: a verb that is in a structured CLI spec is a tool the next time `pnpm plugin:gen` runs, the plugin version moves through the digest it already has, and no tool code is written. The three missing abilities become small non-interactive verbs behind such specs, built on the code that already does the work (`Notifier`, `tagents --new`, the one place a window is made).

## What Changes

- A second MCP server, `tagents`, started by the new package `@tagents/mcp` (`tagents-mcp --contract <contract.json>`) and registered in `.claude-plugin/plugin.json` beside `knowledge`. It lists one tool for each verb of each structured CLI spec in `contract.json`, named `<program>_<verb words>` (`core_session_open`, `notify_send`, `tagents_new`), and runs the verb as a child process, answering with its exit code, stdout and stderr. It knows no verb by name.
- Every verb of a structured CLI spec may carry an `effect` (`read`, `write`, `spawn`, `destructive`, `serve`) and a `requires` (`tmux`). The effect becomes the tool's MCP annotations; a verb without one is exposed as not read-only and listed by `pnpm plugin:check` in a notice that does not fail the check. A `serve` verb (one that runs until stopped) gets no tool. All verbs of `tagents-core` and `tagents-knowledge` are classified.
- `tagents-notify` gets a structured CLI spec and a verb `send <message…> [--title <text>]` that posts one notice through the configured backend, the way `test` does, with a title of the caller's choice and a click that docks the caller's pane.
- `tagents --window DIR COMMAND` opens a plain window in DIR running COMMAND, in the tmux session that owns DIR, the way `--new` opens an agent. `tagents.cli.json` at the repository root is the structured spec of the `tagents` script's non-interactive flags (`--new`, `--window`, `--label`, `--profile-for`, `--config`, `--check`), and a test pins it against `tagents --help`.
- A tool that needs the caller's tmux server (`requires: tmux`) is refused with exit `refused` and a message saying so when the server runs outside tmux.
- `install.sh` writes `tagents-notify` and `tagents-mcp` wrappers beside the others, which the server needs on `PATH` to run its verbs; the node-pinning rule covers all four node commands.
- `contract.json` lists the new server's tools under `mcp.tagents.tools`, and records `effect` and `requires` on the verbs.
- The pre-commit hook regenerates the contract when `tagents.cli.json` is staged.
- `skills/tagents/SKILL.md` gets a short "Using the tools" section.

## Capabilities

### Modified Capabilities
- `claude-code-plugin`: the manifest registers the `tagents` server; the tools and what a call does; the installer writes two more wrappers; the skill says how to use the tools.
- `plugin-contract`: the CLI contracts come from four specs, the tool list of the `tagents` server is recorded, verbs carry `effect` and `requires`, and verbs without an effect are reported.
- `notify-service`: the `send` verb; the plugin has six verbs.
- `chat-launch`: `tagents --window`.
- `cli-dispatch`: `--window` is a flag the script answers itself.

## Impact

- Code: new package `packages/mcp`; `packages/core/src/cli/spec.ts` (`effect`, `requires`) and the verb specs of `core` and `knowledge`; `packages/notify` (`send`, `src/cli/spec.ts`); `packages/contract/src` (sources, tools, notice); `tagents`, `lib/tagents/launch.sh`, `tagents.cli.json`; `install.sh`; `.githooks/pre-commit`; `.claude-plugin/plugin.json`.
- Generated: `contract.json`, `skills/tagents/references/*.md` and the plugin version and digest, once, by `pnpm plugin:gen`.
- Docs: `docs/guide/claude-code-plugin.md`, `docs/architecture/contract.md`, `skills/tagents/SKILL.md`.
- Compatibility: nothing is removed. `tagents-knowledge` MCP tools stay as they are; the `tagents` server also lists the knowledge CLI verbs as `knowledge_*` tools (see the open questions in `design.md`).
