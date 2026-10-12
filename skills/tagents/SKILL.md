---
name: tagents
description: Use when driving tagents from a session or a script — opening, prompting, listing or aborting headless Claude Code sessions with tagents-core, finding a past session, searching the owner's knowledge documents with tagents-knowledge or its MCP tools, reading session cost with tusage, calling a flag of the tagents dashboard or of tnotes, or writing code or a tagents plugin (definePlugin) against @tagents/core, @tagents/knowledge or @tagents/telegram.
---

# tagents

## Overview

tagents is a tmux dashboard for Claude Code sessions plus the packages that drive headless ones. This skill is its contract: every verb, flag, MCP tool and exported signature, generated from the code at this plugin's version. Read the reference for the surface you are about to call instead of guessing a flag.

## Which reference

| You need to | Use | Read |
|---|---|---|
| open, prompt, read, list or abort a headless Claude Code session; list, add, remove or scaffold a tagents plugin; run `doctor` | `tagents-core` | `references/cli.md` |
| find a past session by its project or opening prompt | the `knowledge` MCP tools this plugin registers, or `tagents-core sessions` from a shell | `references/mcp.md`, `references/cli.md` |
| search or read the owner's knowledge documents | the same `knowledge` MCP tools, or `tagents-knowledge` from a shell | `references/mcp.md`, `references/cli.md` |
| read cost and context accounting per session | `tusage` | `references/scripts.md` |
| call a flag of the dashboard or of the notes workspace | `tagents`, `tnotes` | `references/scripts.md` |
| write code against a package, or a tagents plugin with `definePlugin` | `@tagents/core`, `@tagents/knowledge`, `@tagents/telegram` | `references/core.api.md`, `references/knowledge.api.md`, `references/telegram.api.md` |

The same contract as data, for a script that wants to check a verb or a tool schema: `${CLAUDE_PLUGIN_ROOT}/contract.json`.

## What holds everywhere

- A verb the `tagents` script has no flag for is handed to `tagents-core` unchanged, so `tagents session list` and `tagents-core session list` are the same call.
- A verb that prints JSON prints one pretty-printed document on stdout. The exception is `session prompt --events`, which prints one compact JSON line per event and then the outcome.
- Exit codes carry the outcome, and each CLI's table is in its section of `references/cli.md`. Check the exit code before parsing the output.
- `tagents-core` and `tagents-knowledge` must be on `PATH`; the MCP server this plugin registers is `tagents-knowledge mcp`.

## Common mistakes

- **Trusting a remembered flag.** The references are regenerated whenever the code changes, and a flag from memory is a flag from an older version.
- **An unknown verb or flag that the reference lists.** The installed binaries are older than this plugin: compare with `tagents-core help` and rebuild the checkout.
- **Editing a file under `references/` or `contract.json`.** They are generated; the change belongs in the code, and `pnpm plugin:gen` in the tagents repo rewrites them.
