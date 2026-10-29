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
