## Decisions to review

### 1. A second MCP server, `tagents`, in a package of its own that knows no verb

The tools of the plugin are served by `@tagents/mcp` (`tagents-mcp --contract <contract.json>`), registered as `mcpServers.tagents` beside `knowledge`, because a server generic over the contract is the only place where "adding a verb adds a tool" can be true without code. Rejected: adding tools to the knowledge server, which is a per-environment shared daemon behind `nc` whose tools are database reads, and would have to learn about notifications and tmux.

```json
"tagents": { "command": "tagents-mcp", "args": ["--contract", "${CLAUDE_PLUGIN_ROOT}/contract.json"] }
```

### 2. Tools are derived from structured CLI specs by one pure function, used by the generator and by the server

`toolSpecs(clis)` in `packages/mcp/src/tools.ts` turns `CliContract[]` into tools; the contract generator calls it to write `mcp.tagents.tools` and the server calls it on the same specs read back from `contract.json`, so the list a client sees and the list the contract records cannot be two lists (a stdio smoke test pins it). Rejected: deriving tools from the TypeScript API, which has no argument vocabulary an executable could be given, and a hand-written table of tools, which is the thing this change exists to remove.

```ts
const name = toolName(cli.program, command.path); // tagents-core + [session, list] -> core_session_list
tools.set(name, { name, description: sentence(command.summary), inputSchema: inputSchemaOf(name, command, positionals), annotations });
```

### 3. A call runs the CLI and reports how it ended; a verb that serves, or is not for a model, gets no tool

A tool call spawns the verb's program from `PATH` with no stdin and answers with `{exit, outcome, stdout, stderr}`, `stdout` parsed when it is JSON, a non-zero exit being an error and the exit table naming the code. Verbs with `effect: serve` (`tagents-notify run`, `tagents-knowledge mcp` and `serve`) run until stopped and so answer nothing, and a verb whose spec says `tool: false` is not offered either (decision D1 below). Rejected: exposing every verb with stdin closed and a timeout, which would give the model a tool that always times out and leaves a daemon behind.

```ts
const child = spawn(tool.program, [...argv.argv], { env: deps.env, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
process.kill(-child.pid, 'SIGTERM'); // the whole group, on every way a call can end (decision D3 below)
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

Notification is `tagents-notify send`, assembled and posted through the `postThrough` path `test` now shares, so the backend, options, click and error words are the existing ones. A new interactive Claude session is the existing `tagents --new [DIR] [PROFILE]`. A plain window is the new `tagents --window DIR COMMAND`, which takes exactly a directory and one quoted command (any other number of words exits 2 and opens nothing), makes its window in `new_pane_window`, the one place `new_agent` and `new_shell` make theirs, and selects it with `open_agent` unless `--detach` is given. Rejected: a tool that calls `osascript` or `tmux new-window` itself, which would be a second notifier and a second place windows are made.

```sh
pane=$(new_pane_window "$sess" "$dir" "$cmd")
[ -n "$LAUNCH_DETACH" ] || open_agent "$pane"
printf '%s\t%s:%s\n' "$pane" "$sess" "$idx"
```

`send` assembles its own notice (kind `message`, a unique id per send) instead of composing one from an agent event, because there is no event to compose it from; it still goes to the click docking rule of `test` through `clickFor`. Its words are joined with a space, the positional is `<message…>`, and a title over 256 characters or a message over 2048 is refused with exit 2 (`SEND_TITLE_MAX` and `SEND_MESSAGE_MAX` in `packages/notify/src/cli/spec.ts`), because a notification shows a line or two and more is a mistake in the call.

### 6. The script's flags are described by `tagents.cli.json`, pinned to `tagents --help`

The bash `tagents` has no parser to read a spec from, so its non-interactive flags are described in `tagents.cli.json` and a contract test parses `tagents --help` and fails when a described flag is missing from the help or has other positionals, or a help flag is neither described nor in the test's list of flags that are not tools with a reason. `--list`, `--counts` and the other flags that print fzf rows or tmux status markup are not tools. Rejected: a generated spec from the help text, which has no types or effects to read.

```json
{ "path": ["--window"], "positionals": ["<DIR>", "<COMMAND>"], "options": { "detach": { "type": "boolean" } }, "required": [],
  "summary": "opens a tmux window in DIR that runs COMMAND …", "effect": "spawn", "requires": "tmux", "toolDefaults": { "detach": true } }
```

### 7. Arguments reach the verb as `--name=value` and a positional cannot start with a dash

The server checks the arguments against the schema first, because the CLIs drop what they do not know, then writes each option as one `--name=value` word (a boolean as `--name`, or nothing when false), refuses a positional that starts with a dash, since not every verb takes `--` to end its options, and refuses an argument with a NUL byte, which no program can be started with. A boolean option the spec defaults for its tool (`toolDefaults`) is given when the call leaves it out. Rejected: passing `--` before the positionals, which `tagents --new` and the bash flags do not honour.

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

## Decisions taken

The five questions that stood here (the duplicated knowledge tools, `install` and `uninstall` as tools, selecting the new window, the number of tools, and `session prompt` as a tool) are settled by the decisions below, and the later ones (D5) answer questions raised in review. Each has the choice, the reason and the alternative that was rejected.

### D1. Nineteen tools, not thirty-one: a verb opts out with `tool: false`

A command in a spec may say `tool: false`. Twelve verbs do: `tagents-core` `session open`, `session prompt`, `session abort`, `plugin add`, `sessions recent` and `sessions search`; `tagents-notify` `install` and `uninstall`; `tagents-knowledge` `search`, `show`, `list` and `usage`. They stay in `contract.json` (the `cli` section, marked `"tool": false`) and in the references, so the CLI is still documented, and the `tagents` server lists exactly nineteen tools: `core_doctor`, `core_plugin_list`, `core_plugin_new`, `core_plugin_remove`, `core_session_last`, `core_session_list`, `core_sessions_show`, `knowledge_index`, `knowledge_lint`, `knowledge_toc`, `notify_send`, `notify_status`, `notify_test`, `tagents_check`, `tagents_config`, `tagents_label`, `tagents_new`, `tagents_profile_for`, `tagents_window`.

The reasons, by verb. `session open` makes a reference that only `session prompt` uses. `session prompt` is an unattended `claude -p` that blocks its caller for up to 50 minutes and may skip permissions, so a model that wants one runs `tagents-core session prompt` in a window the owner can watch, through `tagents_window`. `session abort` kills the process a model-supplied reference names, and `plugin add` registers code the host later `import()`s outside any permission prompt. `install` and `uninstall` write a LaunchAgent and pop a macOS permission dialog, a one-time human action. The `knowledge` MCP server already offers `sessions_recent`, `sessions_search`, `knowledge_search`, `knowledge_get`, `knowledge_list` and `knowledge_usage`, and two names for one thing double the tool descriptions in every turn.

Rejected: keeping both knowledge tool sets (two names for one thing double the context); making `install` a tool with a prompt (it still pops the macOS dialog and writes a LaunchAgent); keeping `session prompt` as a tool with a confirmation (an unattended turn can run 50 minutes and may skip permissions).

```ts
{ path: ['session', 'prompt'], summary: 'summarySessionPrompt', effect: 'spawn', tool: false }
```

### D2. Windows opened by a tool do not take the screen: `--detach`, defaulted for tools by `toolDefaults`

`tagents --new` and `tagents --window` take `--detach`: the window is made and registered where it belongs but is not selected, no client is switched and no dialog is opened. Their spec entries carry `toolDefaults: { detach: true }`, so the tools default to detached and a model passes `detach: false` to land in the window; the human default of the CLI is unchanged. With `--detach`, `--new` whose profile resolves to `ask` exits 2 and lists the configured profiles, because a dialog on the owner's screen blocks the call until a human answers. With `--detach`, `--new` prints the line `--window` prints (the pane, a tab and `session:index`, from `window_line` in `lib/tagents/launch.sh`), because a model that cannot see the screen has no other way to say which window it opened; without it `--new` prints nothing, as before.

The reason is that a window a model opens must not take the screen from someone who is typing, and that a "start my day" run of several `tagents_new` calls would otherwise leave the owner in the last one. Rejected: always selecting the new window (it takes the screen from someone typing); never selecting it (a human at the CLI expects to land in the window they opened).

```json
{ "path": ["--new"], "options": { "detach": { "type": "boolean" } }, "toolDefaults": { "detach": true } }
```

### D3. Nothing a call starts outlives the call

A child leads a process group of its own. A call ends by the program's exit, by the timeout, by the cancellation of its request, by the closing of the server's stdin, or by SIGTERM, SIGINT or SIGHUP of the server, and each time the whole group gets SIGTERM and then SIGKILL once a grace of two seconds has passed; whatever is left in the group after the direct child has exited is killed at once. After the exit the call waits for the output pipes for a moment only (a process that left the group can hold them for good) and then answers. A call that was cancelled answers `outcome: cancelled`.

The reason is that a cancelled call, a closed Claude session and a program that ignores SIGTERM used to leave a `claude -p` running for up to 50 minutes, and a grandchild holding the stdout pipe kept the call from ever ending. Rejected: signalling the direct child only, which is what left the grandchildren running.

```ts
child = spawn(tool.program, argv, { env, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
const stop = () => { signalGroup('SIGTERM'); graceTimer = setTimeout(() => signalGroup('SIGKILL'), grace); };
child.once('exit', () => signalGroup('SIGKILL')); // what the program left behind
```

### D4. A call is bounded at five minutes, not an hour

`CALL_TIMEOUT_MS` in `packages/mcp/src/main.ts` drops from one hour to five minutes. The one-hour figure was there for a headless turn of 50 minutes; with `session prompt` no longer a tool, no tool is expected to run for more than a few seconds, and a call that holds a conversation for minutes is a hung one. Rejected: keeping the hour, which only lets a stuck program hold a session. Each of `stdout` and `stderr` is also capped, in bytes and not in UTF-16 units: the first 256 KiB are kept, cut before a character the cap fell in, and a marker and `"truncated": true` say so.

```ts
const CALL_TIMEOUT_MS = 5 * 60 * 1000;
```

### D5. A detached launch keeps the one-line tmux message and also writes a refusal to standard error

`--detach` keeps the tmux message a launch ends with (`tagents: new agent in …`, `tagents: new window in …`): it is the only sign the person at the keyboard gets that a window appeared in the background, and it does not take the screen. What `--detach` adds is that a refusal (a directory that is not one, no claude profile, no window could be opened) is also written to standard error through `launch_refusal` in `lib/tagents/launch.sh`, because the caller is a program that reads standard error and the exit status and not the screen, so a failed `tagents_new` call carries its reason. Rejected: silence under `--detach` (a background window nobody is told about is invisible); standard error for every caller (a `run-shell` key binding would show a pane for an ordinary refusal).

```bash
launch_refusal() {  # <message>
  [ -z "$LAUNCH_DETACH" ] || echo "$1" >&2
  notice "$1"
}
```

### Dropped

- A positional that starts with a dash stays refused (section 7): it is a documented decision with a clear refusal.
- The per-package copy of the no-`any` lint test stays: it is the repository's own pattern.
- The pre-commit hook still generates from the working tree and not from the index: a partly staged file is read whole (the hook's scenario), and `pnpm plugin:check` in CI catches a tree that is stale.
