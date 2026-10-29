---
name: tagents
description: Use when driving tagents from a session or a script — opening, prompting, listing or aborting headless Claude Code sessions with tagents-core, finding a past session, searching the owner's knowledge documents with tagents-knowledge or its MCP tools, sending a desktop notification, opening Claude Code sessions or a command in tmux windows, reading session cost with tusage, calling a flag of the tagents dashboard or of tnotes, or writing code or a tagents plugin (definePlugin) against @tagents/core, @tagents/knowledge, @tagents/notify or @tagents/telegram.
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
| send a desktop notification, open another Claude Code session in a tmux window, or run a command in one | the `tagents` MCP tools this plugin registers | [Using the tools](#using-the-tools) |
| read cost and context accounting per session | `tusage` | `references/scripts.md` |
| call a flag of the dashboard or of the notes workspace | `tagents`, `tnotes` | `references/scripts.md` |
| write code against a package, or a tagents plugin with `definePlugin` | `@tagents/core`, `@tagents/knowledge`, `@tagents/notify`, `@tagents/telegram` | `references/core.api.md`, `references/knowledge.api.md`, `references/notify.api.md`, `references/telegram.api.md` |

The same contract as data, for a script that wants to check a verb or a tool schema: `${CLAUDE_PLUGIN_ROOT}/contract.json`.

## What holds everywhere

- A verb the `tagents` script has no flag for is handed to `tagents-core` unchanged, so `tagents session list` and `tagents-core session list` are the same call.
- A verb that prints JSON prints one pretty-printed document on stdout. The exception is `session prompt --events`, which prints one compact JSON line per event and then the outcome.
- Exit codes carry the outcome, and each CLI's table is in its section of `references/cli.md`. Check the exit code before parsing the output.
- `tagents-core`, `tagents-knowledge`, `tagents-notify` and `tagents-mcp` must be on `PATH`; the installer writes all four.

## Using the tools

The plugin registers an MCP server, `tagents`, with one tool for each verb of the contract that is meant for a model: `core_session_list` is `tagents-core session list`, `notify_send` is `tagents-notify send`, `tagents_new` is `tagents --new`, and a tool takes the arguments its verb takes (its schema, or `references/cli.md`, which marks each verb as a tool or as CLI only). A call answers with `exit`, `outcome`, `stdout` and `stderr`, and a non-zero exit is an error. A verb added to tagents is a new tool once the plugin is updated, so list the tools instead of assuming which exist.

- To tell the owner something (a long job finished, an answer is waiting), call `notify_send` with the `message` words and, when it helps, a `title`. It posts through tagents' own notifier on macOS, and a click on it docks the tmux pane the call ran in, when there is one.
- To open another Claude Code session, call `tagents_new` with `dir` and, to choose the account, `profile`. `tagents_config` lists the profiles and `tagents_profile_for` says which one the rules pick for a directory. The session is a window of the tmux server this one runs in, listed by the dashboard. Several calls in a row open several sessions, which is how a day starts: one call per project.
- To run a command in a window the owner can watch, call `tagents_window` with `dir` and `command`, one string for the shell. The window closes when the command ends.
- To see what the sessions are doing, call `core_session_list`, then `core_session_last` for the last answer of one and `core_sessions_show` for a whole transcript.
- To run a prompt without a window, run `tagents-core session open` and then `tagents-core session prompt` with the reference it printed, in a window the owner can watch, through `tagents_window`. These two verbs are CLI only and have no tool, because the message of an arbitrary prompt can carry anything and an unattended turn can run for a long time.
- `tagents_new` and `tagents_window` need this session to run inside tmux; outside it they answer exit 3 and open nothing.
- Claude Code asks the owner before each of these tools runs. Say in plain words what the call will start before making it, and do not repeat a call the owner refused.

## Common mistakes

- **Trusting a remembered flag.** The references are regenerated whenever the code changes, and a flag from memory is a flag from an older version.
- **An unknown verb or flag that the reference lists.** The installed binaries are older than this plugin: compare with `tagents-core help` and rebuild the checkout.
- **Editing a file under `references/` or `contract.json`.** They are generated; the change belongs in the code, and `pnpm plugin:gen` in the tagents repo rewrites them.
