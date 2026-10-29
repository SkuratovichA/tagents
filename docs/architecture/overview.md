# Overview

tagents is a bash dashboard plus a small family of TypeScript packages. This page says what is in the repository, how the parts form one system, and where a session with no tmux pane fits.

## What is in the repository

| path | what it does |
|------|--------------|
| `tagents` | the dashboard itself: the tree, the list and viewport, the timeline |
| `lib/tagents/` | what the dashboard is made of: one file per part, sourced by `tagents`. [What each one is](https://github.com/SkuratovichA/tagents/blob/main/lib/tagents/README.md) |
| `tusage` | per-session cost, dollars and context accounting, read from the transcripts |
| `tnotes` | the notes editor beside a chat |
| `hooks/tmux-agent-state.sh` | the Claude Code hook that publishes session state |
| `hooks/claude-statusline.sh` | the Claude Code status line, and the only source for which model a session is *set* to |
| `hooks/notes-context.sh` | the Claude Code hook that carries the notes folder's diff into the prompt |
| `hooks/notes-autocommit.sh` | the Claude Code hook that commits what Claude writes into the notes folder |
| `hooks/notes-freshness.sh`, `hooks/ticket-ledger.sh` | two more optional notes hooks |
| `config.example.toml`, `schemas/config.schema.json` | a commented example of the optional config, and the JSON Schema that editors use to check and explain it |
| `packages/core/` | `@tagents/core`, the TypeScript package for **headless** sessions |
| `packages/knowledge/` | [`@tagents/knowledge`](https://github.com/SkuratovichA/tagents/blob/main/packages/knowledge/README.md), your notes as markdown documents with an FTS5 index, a `tagents-knowledge` CLI and an MCP server |
| `packages/telegram/` | [`@tagents/telegram`](https://github.com/SkuratovichA/tagents/blob/main/packages/telegram/README.md), the Telegram Bot API typed and small: one client for every plugin that has a bot token |
| `packages/notify/` | [`@tagents/notify`](https://github.com/SkuratovichA/tagents/blob/main/packages/notify/README.md), desktop notifications, see [Notifications](../guide/notifications) |
| `packages/contract/` | `@tagents/contract`, private: generates the contract of the [Claude Code plugin](../guide/claude-code-plugin) from the code and moves the plugin's version |
| `.claude-plugin/`, `skills/tagents/`, `contract.json` | the plugin: its manifest, its skill, and the contract generated from the code |
| `openspec/` | the [specs](../development#specs): what every part of tagents does, one capability per spec, and the changes proposed against them |

## One system

The parts are one system:

1. The **hook** writes a record per session into `~/.claude/agent-state/`.
2. `tagents` joins those records with the live tmux pane list and renders them.
3. `tusage` supplies the two cost columns, joined on the session id.

Two of these are optional. `tusage` is only run once `usage.watch` names a profile (see `config.example.toml`); without it no cost is shown anywhere. `tagents` degrades gracefully when `tusage` or the status line is missing. Without the state hook there is nothing to show.

How the list stays current is [its own page](./refresh).

## Sessions with no pane

Everything above is about sessions you can look at. The ones a bot or a cron job runs headlessly (`claude -p`) have no pane and no window, and the dashboard sees them only through the same hook.

Spawning, prompting and reading **those** lives in [`packages/core`](https://github.com/SkuratovichA/tagents/blob/main/packages/core/README.md): a TypeScript package (`@tagents/core`) with a `tagents-core` CLI, so bash gets it too. It is a separate workspace at the root of the repository; the scripts above neither import it nor need it.

How such a session reads on the list is in [States and order](../guide/states#headless-sessions).

## The ecosystem

| package | what it is |
|---------|------------|
| `tagents` (the script) | the dashboard: tmux, fzf, the tree, the cockpit. Bash, no dependencies of its own. The entry point, with the rest of it in `lib/tagents/` |
| [`@tagents/core`](https://github.com/SkuratovichA/tagents/blob/main/packages/core/README.md) | headless sessions (spawn, prompt, read, list) plus the plugin contract and host, behind a `tagents-core` CLI |
| [`@tagents/knowledge`](https://github.com/SkuratovichA/tagents/blob/main/packages/knowledge/README.md) | your notes as markdown documents with an FTS5 index, a `tagents-knowledge` CLI and an MCP server |
| [`@tagents/telegram`](https://github.com/SkuratovichA/tagents/blob/main/packages/telegram/README.md) | the Telegram Bot API, typed and small: one envelope-parsing `call()`, the methods a bot actually uses, and the 4096-character split |
| [`@tagents/notify`](https://github.com/SkuratovichA/tagents/blob/main/packages/notify/README.md) | desktop notifications, a plugin |
| plugins, e.g. `@tagents/plugin-telegram` | a package the config names: one `definePlugin({ … })` object offering CLI verbs, long-running services and MCP tools |

One name reaches all of it. A verb `tagents` has no flag for (`tagents plugin list`, `tagents session list`, `tagents doctor`) is handed to `tagents-core` unchanged, found on `$PATH` or beside the script in a checkout.

## The plugin model

A plugin is an ordinary package that default-exports one `definePlugin({ name, apiVersion: 1, commands, services, mcpTools, locales })` object and declares where that object lives in its own `package.json`:

```json
{
  "tagents": { "apiVersion": 1, "entry": "./src/plugin.ts" }
}
```

- `tagents plugin add <package-or-path>` checks that manifest, without importing anything, and writes the package as a `[plugins.<name>]` table in `~/.config/tagents/config.toml` (a `config.yaml` that is there instead is edited as before).
- The host loads exactly what that map names and never scans `node_modules`, because scanning is how a machine ends up running code nobody chose.
- `tagents plugin new <name>` scaffolds a package that is already a plugin and typechecks as written.

See [the core package README](https://github.com/SkuratovichA/tagents/blob/main/packages/core/README.md#plugins) for the full story.

## The checkout rule

`tagents` is the entry point of a checkout, not a file to copy on its own. The rest of it is `lib/tagents/*.sh` beside it, which it finds by following a symlink back to the real file, or by being run from where it lives, as the installer's wrapper does. Copied alone it says so and stops, rather than half-working.
