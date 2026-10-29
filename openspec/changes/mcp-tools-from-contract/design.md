## Decisions to review

### 1. A second MCP server, `tagents`, in a package of its own that knows no verb

The tools of the plugin are served by `@tagents/mcp` (`tagents-mcp --contract <contract.json>`), registered as `mcpServers.tagents` beside `knowledge`, because a server generic over the contract is the only place where "adding a verb adds a tool" can be true without code. Rejected: adding tools to the knowledge server, which is a per-environment shared daemon behind `nc` whose tools are database reads, and would have to learn about notifications and tmux.

```json
"tagents": { "command": "tagents-mcp", "args": ["--contract", "${CLAUDE_PLUGIN_ROOT}/contract.json"] }
```

### 2. Tools are derived from structured CLI specs by one pure function, used by the generator and by the server

`toolSpecs(clis)` in `packages/mcp/src/tools.ts` turns `CliContract[]` into tools; the contract generator calls it to write `mcp.tagents.tools` and the server calls it on the same specs read back from `contract.json`, so the list a client sees and the list the contract records cannot be two lists (a stdio smoke test pins it). Rejected: deriving tools from the TypeScript API, which has no argument vocabulary an executable could be given, and a hand-written table of tools, which is the thing this change exists to remove.

```ts
const name = toolName(cli.program, command.path); // tagents-core + [session, open] -> core_session_open
tools.set(name, { name, description: sentence(command.summary), inputSchema: inputSchemaOf(name, command, positionals), annotations });
```

### 3. A call runs the CLI and reports how it ended; a verb that serves gets no tool

A tool call spawns the verb's program from `PATH` with no stdin and answers with `{exit, outcome, stdout, stderr}`, `stdout` parsed when it is JSON, a non-zero exit being an error and the exit table naming the code. Verbs with `effect: serve` (`tagents-notify run`, `tagents-knowledge mcp` and `serve`) run until stopped and so answer nothing. Rejected: exposing every verb with stdin closed and a timeout, which would give the model a tool that always times out and leaves a daemon behind.

```ts
const child = spawn(tool.program, [...argv.argv], { env: deps.env, stdio: ['ignore', 'pipe', 'pipe'] });
child.on('close', (code) => resolve(finish(code ?? 1, outcomeOf(tool.exit, code ?? 1), stdout, stderr)));
```

### 4. The verb declares its effect; the effect becomes the tool's annotations; an unclassified verb is conservative and reported, never refused

`effect` (`read`, `write`, `spawn`, `destructive`, `serve`) and `requires: 'tmux'` are optional fields of a command spec; they are what a client's permission prompt sees (`readOnlyHint`, `destructiveHint`, `openWorldHint`). A verb with no effect gets `readOnlyHint: false` and nothing else, and `pnpm plugin:gen` and `plugin:check` print a `notice:` naming it without failing, so another change that adds a verb (the open `tagents-core config convert`) needs nothing from this one to come out as a cautious tool. Rejected: making a missing effect a test failure, which would block that change on this one's vocabulary.

```ts
const ANNOTATIONS = {
  read: { readOnlyHint: true, openWorldHint: false },
  destructive: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
  /* write, spawn … */
};
const UNCLASSIFIED = { readOnlyHint: false };
```

`tagents-core session open` is `read`: it only prepares a reference and starts no process (`ClaudeHeadlessDriver.open`), and `session prompt`, which runs the turn, is `spawn` and says `runs one Claude turn` first.

### 5. The three missing abilities are small verbs on code that already did the work

Notification is `tagents-notify send`, assembled and posted through the `postThrough` path `test` now shares, so the backend, options, click and error words are the existing ones. A new interactive Claude session is the existing `tagents --new [DIR] [PROFILE]` with no change. A plain window is the new `tagents --window DIR COMMAND`, which makes its window in `new_pane_window`, the one place `new_agent` and `new_shell` make theirs, and selects it with `open_agent`. Rejected: a tool that calls `osascript` or `tmux new-window` itself, which would be a second notifier and a second place windows are made.

```sh
pane=$(new_pane_window "$sess" "$dir" "$cmd")
open_agent "$pane"
printf '%s\t%s:%s\n' "$pane" "$sess" "$idx"
```

`send` assembles its own notice (kind `message`, a unique id per send) instead of composing one from an agent event, because there is no event to compose it from; it still goes to the click docking rule of `test` through `clickFor`.

### 6. The script's flags are described by `tagents.cli.json`, pinned to `tagents --help`

The bash `tagents` has no parser to read a spec from, so its non-interactive flags are described in `tagents.cli.json` and a contract test parses `tagents --help` and fails when a described flag is missing from the help or has other positionals, or a help flag is neither described nor in the test's list of flags that are not tools with a reason. `--list`, `--counts` and the other flags that print fzf rows or tmux status markup are not tools. Rejected: a generated spec from the help text, which has no types or effects to read.

```json
{ "path": ["--window"], "positionals": ["<DIR>", "<COMMAND>"], "options": {}, "required": [],
  "summary": "opens a tmux window in DIR that runs COMMAND …", "effect": "spawn", "requires": "tmux" }
```

### 7. Arguments reach the verb as `--name=value` and a positional cannot start with a dash

The server checks the arguments against the schema first, because the CLIs drop what they do not know, then writes each option as one `--name=value` word and refuses a positional that starts with a dash, since not every verb takes `--` to end its options. Rejected: passing `--` before the positionals, which `tagents --new` and the bash flags do not honour.

```ts
flags.push(`--${option}=${value}`);
if (given.some((v) => v.startsWith('-'))) return refuse(`argument "${p.name}" starts with a dash …`);
```

### 8. The tmux that a window tool uses is the one of the calling process; without one the tool is refused

A tool recorded `requires: tmux` is refused with exit `refused` (3) and a message when `TMUX` is empty in the server's environment, so a Claude Code session outside tmux learns why instead of getting a window in some other server or an unexplained exit. `--new` itself still works outside tmux (it falls back to a session called `agents`), and is left as it is. Rejected: pointing the tool at the default tmux socket, which is the user's live server whenever the plugin runs somewhere else.

```ts
if (tool.command.requires === 'tmux' && (deps.env['TMUX'] ?? '') === '')
  return refusal(tool.exit['refused'] ?? 3, 'refused', `${tool.name} needs a tmux server of its own …`);
```

### 9. The plugin adds no permission; the first words of the description say what the call starts

The plugin writes no allow rule and touches no `~/.claude*` settings: Claude Code asks before each tool, and the prompt shows the description and the annotations. Spawning summaries therefore open with the verb that says what starts (`starts a new interactive Claude Code session …`, `opens a tmux window …`, `runs one Claude turn …`), and a test pins that for every `spawn` verb. Rejected: shipping allow rules for the read-only tools, which is a decision for each user's settings.

### 10. The commands the tools run have to be on PATH, so the installer writes `tagents-notify` and `tagents-mcp`

The brief did not list this gap: `install.sh` wrote wrappers for `tagents`, `tusage`, `tnotes`, `tagents-core` and `tagents-knowledge` only, and the plugin starts `tagents-mcp` and runs `tagents-notify`. Both join the node-pinning table, so each runs the node that installed it.

```sh
for pair in tagents-core:core/dist/cli/main.js tagents-knowledge:knowledge/dist/cli/main.js tagents-notify:notify/dist/main.js tagents-mcp:mcp/dist/main.js; do
```

The pre-commit hook's source list also gains `tagents.cli.json`, which the contract is now generated from.

## Open questions for Sasha

1. The knowledge CLI verbs (`knowledge_search`, `knowledge_show`, `knowledge_list`, `knowledge_index`, `knowledge_lint`, `knowledge_toc`, `knowledge_usage`) are also tools of the `tagents` server, next to the same-named tools of the `knowledge` server (`mcp__tagents__knowledge_search` and `mcp__tagents-knowledge__knowledge_search`), and the seven names cost context in every session. Should the `knowledge` CLI be left out of the `tagents` tools, with an effect like `serve` that means "no tool", or is the duplication fine because the CLI covers `index` and `toc`, which the MCP server does not?
2. `notify_install` and `notify_uninstall` are tools: they install or remove a LaunchAgent and ask macOS for permission. Claude Code asks before each one, but should a model be able to reach them at all?
3. `tagents --new` and `tagents --window` select the new window the way a key in the dashboard does, so a "start my day" run of several `tagents_new` calls moves the user's screen to the last one. Should the tools open windows without selecting them (a `--detach` option on both flags)?
4. There are thirty-one tools in the `tagents` server, so every session pays for them in its tool list. Is that acceptable, or should the server list only the verbs marked for models in the spec (a `tool: false` field) and keep the rest to the CLI and the references?
5. `core_session_prompt` blocks its caller for the whole headless turn (up to the 50 minutes `tagents-core` allows), because a tool call has no way to hand back a handle. Should it stay a tool, or should models start such a turn with `tagents_window` running `tagents-core session prompt` where the user can see it?
