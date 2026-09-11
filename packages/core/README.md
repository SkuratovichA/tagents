# @tagents/core

How a **headless** Claude Code session is spawned, prompted, read and listed.

The `tagents` dashboard at the root of this repo owns the tmux side: panes,
names, the live status bar. It has never owned the sessions that have no pane —
the ones a bot or a cron job starts with `claude -p`. That logic grew inside a
Telegram bot (`tg-orchestrator`), where nothing else could reuse it. This
package is that logic, lifted out and given a contract:

* a **driver** — open a session, run one turn, read its last reply, list what is
  running, abort it;
* a **transcript reader** — the same listing the orchestrator's `sessions.mjs`
  produced, byte for byte;
* an **agent-state reader** — what `hooks/tmux-agent-state.sh` publishes;
* a **CLI** (`tagents-core`) so bash and other languages get all of it too;
* a **plugin contract**, so the bot can become a plugin instead of a fork.

Nothing here touches tmux, and nothing in the dashboard imports this package.

## The turn, and the one rule behind it

**The exit code is not work completion.** A turn is over when its `result` event
arrives. A child that printed its result and then hung on the way out — a stuck
MCP server, a grandchild holding the pipe — is killed afterwards and still
*succeeded*. Reading that kill as a failure is what made the orchestrator re-run
a finished job on 10.09.2026 and deliver every report to its owner twice.

So `prompt()` never throws for a failed turn and never returns a boolean. It
returns a `TurnOutcome`, and the five kinds are the five different things that
actually happen:

| kind | what happened | `formatAttemptError` |
| --- | --- | --- |
| `ok` | `result` with `is_error: false`, clean exit | `null` |
| `killed-after-result` | the work finished, the process had to be killed | `null` |
| `timeout` | our killer fired; no result ever came | `exit=SIGKILL (timeout …ms, N tool call(s)) …` |
| `exited` | the child left without a usable result | `exit=<code\|signal> …` |
| `spawn-failed` | there was never a process (ENOENT, EACCES) | `exit=null spawn: …` |

`formatAttemptError()` reproduces the one-liner `turn.mjs` put in
`attempt.error`, byte for byte, because the orchestrator prints it into a
Telegram topic and its contract tests pin it.

Defaults, with the values the orchestrator runs on: `DEFAULT_TIMEOUT_MS`
(50 min), `TIMEOUT_WARN_BEFORE_MS` (5 min), `RESULT_EXIT_GRACE_MS` (60 s),
`PIPE_DRAIN_MS` (5 s).

## The driver contract

```ts
import { ClaudeHeadlessDriver } from '@tagents/core';

const driver = new ClaudeHeadlessDriver();
const ref = await driver.open({
  kind: 'claude',
  cwd: '/Users/me/git/thing',
  label: 'nightly',          // reaches the child as TA_LABEL
  model: 'fable',
  effort: 'high',
  skipPermissions: true,
  configDir: null,           // see below
});

const outcome = await driver.prompt(ref, 'summarise what changed today', {
  timeoutMs: 10 * 60_000,
  warnBeforeMs: 60_000,
  onWarn: ({ leftMs }) => console.error(`killing in ${leftMs} ms`),
  onEvent: (e) => e.kind === 'tool_use' && console.error(`→ ${e.name}`),
});
```

`open()` starts **no process**. A session here is a transcript plus a claude
session id; the only thing that runs is a prompt.

**`configDir` is tri-state**, and the three states mean different accounts:

| value | meaning |
| --- | --- |
| `undefined` | inherit the parent's `CLAUDE_CONFIG_DIR` |
| `null` | unset it — land on the default account |
| `"/Users/me/.claude-work"` | use that account (how the dashboard picks one) |

Every other `CLAUDE*` variable is dropped before the child sees it: this process
may have been started from a shell carrying somebody else's account, and an
account is a whole login, not a setting — resume a conversation on the wrong one
and there is nothing there.

Tools are refused **by name** (`--disallowedTools`). Never `--tools ""`: it
looks like the same thing and also drops the MCP tools.

## How the dashboard sees headless sessions

Not through this package. `tagents` reads `~/.claude/agent-state/*.tsv`, which
**the hook** writes from inside Claude's own process — so a session shows up in
the dashboard whether it was started by this driver, by a bot, or by a human in
a pane, and it keeps showing up long after whatever started it has exited.

`list()` reads the same files, which is why it can list sessions this process
never opened. That is the point: the driver that started a session is usually
gone by the time somebody asks what is running.

```
key.tsv  at · state · sessionId · cwd · transcript · detail [· configDir [· pid]]
```

Six fields is a record written before the account column existed and says
*nothing* about the account — which is not the same as an empty seventh field
(that one means the default account). `TA_LABEL` only ever reaches disk through
`history.tsv`, which is where `list({ label })` gets its names.

## CLI

`tagents-core` — JSON verbs print **exactly one** pretty-printed JSON document
on stdout and nothing else; text verbs print what `sessions.mjs` printed.

| command | prints |
| --- | --- |
| `session open --cwd P [--label N] [--model M] [--effort E] [--resume ID] [--system-prompt-file F] [--mcp-config F] [--config-dir D \| --no-config-dir] [--skip-permissions]` | a `SessionRef` |
| `session prompt <ref-json-or-id> <text> [--timeout MS] [--warn-before MS] [--events]` | a `TurnOutcome` (with `--events`: NDJSON events, the outcome last) |
| `session last <ref-json-or-id>` | `{ text, at }` or `null` |
| `session list [--label N] [--state S]...` | `SessionRef[]` |
| `session abort <ref-json-or-id>` | `{ aborted, id, pid }` |
| `sessions recent [N] \| search <words…> \| show <id-prefix>` | text, byte-identical to `sessions.mjs` |
| `plugin list` | the configured plugins and what each offers |
| `doctor` | node, state dir, config file, `claude` on PATH |

Exit codes: **0** ok · **1** error · **2** usage · **3** refused · **4** timeout.

Human strings (usage, `doctor`) go through i18next — `TAGENTS_LOCALE=ru` for
Russian. JSON output and the `sessions.*` text never do: they are contracts.

The text of `sessions recent|search|show` still refers callers to
`sessions.mjs`. That is deliberate: parity is the whole point of the port, the
fixtures under `test/fixtures/sessions/` are the ones recorded from the .mjs,
and the day the wording changes, both sides change together.

## Plugins

A plugin is a package that default-exports one `definePlugin({ … })` object and
is **named explicitly** in `~/.config/tagents/config.yaml`:

```yaml
plugins:
  tg-orchestrator:
    from: ../telegram-bots/orchestrator   # a path, or a package name
```

The host never scans `node_modules` — scanning is how a machine ends up running
code nobody chose. `from` points at a package; the package says where its code
is in its own `package.json`:

```json
{ "tagents": { "entry": "./dist/plugin.js" } }
```

A plugin offers `commands` (CLI verbs), `services` (things that keep running,
each with `drain()` and `stop()`), `mcpTools` and `locales`. One broken plugin
is reported, not thrown: the host stays usable with the ones that work.

## Testing against it

`@tagents/core` exports its own testkit, so a consumer's tests drive a **real**
child process instead of a stub:

```ts
import { ClaudeHeadlessDriver, fakeClaude } from '@tagents/core';

const fake = fakeClaude({ tools: ['Bash'], result: { text: 'done' }, hangAfterResult: true });
const driver = new ClaudeHeadlessDriver();
const ref = await driver.open({ kind: 'claude', cwd: process.cwd(), skipPermissions: false, bin: fake.bin });
const outcome = await driver.prompt(ref, 'go', { timeoutMs: 5_000, exitGraceMs: 300 });
// → 'killed-after-result': finished work, stuck shutdown. Not a failure.
```

`fakeClaude` writes a real executable named `claude`; put its directory on the
child's PATH or pass `bin`. It is single-shot by construction, and `countFile`
records every invocation, so a test can *assert* that a turn ran once rather
than trust it.

## Install

```sh
pnpm add link:../tagents/packages/core        # development: the source, live
pnpm add github:…/tagents#path:/packages/core # a git consumer
```

Both work, and `dist/` is why. Node strips types from `.ts` files you own, but
**refuses to do it under `node_modules`** — a git install that shipped only
`src/` would fail to import. `prepare` builds `dist/` on install; `files` ships
nothing else.

## Development

```sh
pnpm install      # builds the package (prepare)
pnpm -r build
pnpm -r typecheck
pnpm -r test
```

No `any`, anywhere: `test/lint-no-any.test.ts` is the gate, because `tsc` cannot
catch a declared one. Erasable syntax only (no enums, no parameter properties) —
the source runs unbuilt under Node's type stripping.
