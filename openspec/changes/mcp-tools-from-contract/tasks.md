## 1. Effects in the CLI specs

- [x] 1.1 Add `effect` and `requires` to the command spec and to `CliContract`, and classify every verb of `tagents-core` and `tagents-knowledge` (`packages/contract` `sources.test.ts`, the effects test).
- [x] 1.2 Give `tagents-notify` a structured CLI spec in `packages/notify/src/cli/spec.ts` that cannot drift from its verbs (`packages/notify` `test/cli-spec.test.ts`).

## 2. The notification verb

- [x] 2.1 Add `tagents-notify send <message…> [--title]`, posting through the path `test` shares and docking `$TMUX_PANE` (`packages/notify` `test/commands.test.ts`, the `send` tests).

## 3. The window verb

- [x] 3.1 Add `tagents --window DIR COMMAND` to `lib/tagents/launch.sh` and the dispatch and help of `tagents` (`tests/launch.sh` section 12; `tests/dispatch.sh`).
- [x] 3.2 Describe the script's non-interactive flags in `tagents.cli.json` and pin them to `tagents --help` (`packages/contract` `test/bash-spec.test.ts`).

## 4. The tools

- [x] 4.1 Derive tools from specs: names, descriptions, input schemas, annotations, `serve` left out (`packages/mcp` `test/tools.test.ts`).
- [x] 4.2 Run a verb and answer with its exit, outcome, stdout and stderr; refuse a `tmux` verb without `TMUX`; refuse bad arguments (`packages/mcp` `test/run.test.ts`).
- [x] 4.3 Serve the tools over MCP, the same list the contract records, and answer a read-only tool against scratch state (`packages/mcp` `test/server.test.ts`, `test/smoke.test.ts`).
- [x] 4.4 Register the server in `.claude-plugin/plugin.json` (`packages/mcp` `test/registration.test.ts`).

## 5. The contract

- [x] 5.1 Read the four CLI specs, record `effect`, `requires` and `mcp.tagents.tools`, and stop on an unreadable spec (`packages/contract` `test/sources.test.ts`, `test/tools.test.ts`).
- [x] 5.2 A verb added to a CLI spec is a new tool and a different digest and a minor move, with no tool code written; a reworded summary is a patch (`packages/contract` `test/tools.test.ts`).
- [x] 5.3 Print a `notice:` for verbs without an effect and fail nothing (`packages/contract` `test/tools.test.ts`).
- [x] 5.4 Regenerate the contract when `tagents.cli.json` is staged (`.githooks/pre-commit`; `packages/contract` `test/hook.test.ts` pins its pattern to the files the generator reads).

## 6. The installer

- [x] 6.1 Write `tagents-notify` and `tagents-mcp` wrappers that pin the installing node (`tests/install.sh` sections 1 and 10).

## 7. Specs and docs

- [x] 7.1 Add "Using the tools" to the hand-written part of `skills/tagents/SKILL.md` and update the plugin, contract, notifications and accounts pages of `docs/` and the READMEs of `packages/mcp` and `packages/notify` (`claude plugin validate . --strict`, `claude plugin validate skills --strict`).
- [x] 7.2 Validate the change against the specs (`pnpm spec:check`).

## 8. Fixes from review

- [x] 8.1 Let a verb opt out of being a tool with `tool: false` and default a boolean option for its tool with `toolDefaults`; twelve verbs opt out, nineteen tools remain (`packages/contract` `test/tools.test.ts`, `packages/mcp` `test/tools.test.ts`, `test/contract-file.test.ts`).
- [x] 8.2 Start every program as a process group leader and stop the group on timeout, cancellation, stdin end and SIGTERM, SIGINT or SIGHUP; kill what is left when the program exits; bound the wait for the pipes; the timeout is five minutes (`packages/mcp` `test/process.test.ts`).
- [x] 8.3 Cap each stream at 256 KiB counted in bytes, cut on a character boundary, with a marker and `truncated` (`packages/mcp` `test/run.test.ts`).
- [x] 8.4 Pass a boolean option as `--name`, one word per positional, and refuse a NUL byte (`packages/mcp` `test/tools.test.ts`, `test/run.test.ts`).
- [x] 8.5 Add `--detach` to `--new` and `--window`, default it for the tools, refuse `--new --detach` when the account would be asked (`tests/launch.sh` sections 12 and 13; `packages/contract` `test/bash-spec.test.ts`).
- [x] 8.6 Make `--window` take exactly a directory and one command, put `--` before the command for tmux, and read DIR with `CDPATH` unset (`tests/launch.sh` section 12).
- [x] 8.7 Refuse a title over 256 and a message over 2048 characters in `send` (`packages/notify` `test/commands.test.ts`).
- [x] 8.8 Refuse `session abort` on a row that belongs to a tmux pane (`packages/core` `test/cli.test.ts`).
- [x] 8.9 Update the plugin and contract pages, the README of `packages/mcp` and the specs of this change to the decisions above.
- [x] 8.10 Schedule the capture a launch leaves for later in the tmux server (`run-shell -b`), so the process-group kill at the end of a call does not cancel it (`tests/resurrect.sh` section 15e).
- [x] 8.11 Say in the skill which tools exist and that `session open` and `session prompt` are CLI only; document the limits of `send` in the README of `packages/notify`.
- [x] 8.12 Mark each verb in `references/cli.md` as a tool or CLI only, from the function the tools are made by (`packages/contract` `test/render.test.ts`).
- [x] 8.13 Print the pane and where the window is for `--new --detach`, the line `--window` prints (`tests/launch.sh` section 13).
- [x] 8.14 Write the reason for a refused detached launch to standard error as well as to the tmux message (`tests/launch.sh` section 13).
- [x] 8.15 Make a relative or symlinked directory of `--new` and `--window` the physical absolute path, refuse a name that is not a directory (`tests/launch.sh` sections 12 and 13).
- [x] 8.16 Quote the script path of the delayed capture with `cfg_quote`, and fall back to the default delay for a value that is not a plain number (`tests/resurrect.sh` section 15e).
- [x] 8.17 Pin that `tagents` runs from a copy with no workspace beside it: `tests/dispatch.sh` runs it from a directory holding only the script and `lib/tagents`, with no `packages/` and no `node_modules`, and checks the dispatch of the verbs, the forwarded flags, `--help`, `--viewport`, an unknown flag and the run with no `tagents-core` on `PATH`. `tusage` and `tnotes` are not run from such a copy.
- [x] 8.18 Carry `effect` (the five words) and `tool: false` in `spec/cli/tagents-core.json`, the schema, `crates/tagents-spec` and the loader of `packages/core`, so the contract of `tagents-core` stays what it was after merging the Rust front door (`packages/core` `test/cli-spec.test.ts`, `cargo test -p tagents-spec`, `packages/contract` `test/effects.test.ts`, `pnpm plugin:check`).
