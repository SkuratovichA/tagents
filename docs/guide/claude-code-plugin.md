# The Claude Code plugin

The sessions the dashboard watches can also know how to use it. This repository is a Claude Code plugin, and its own marketplace, that gives a session two things: a skill with the exact contract of the tagents tools, an MCP server over your markdown notes, and an MCP server whose tools run the tagents commands.

## Install

```
/plugin install tagents --marketplace SkuratovichA/tagents
```

That one line needs Claude Code 2.1.275 or later. Before it, use two commands:

```
/plugin marketplace add SkuratovichA/tagents
/plugin install tagents@tagents
```

## What it adds

### The `tagents` skill

The skill gives Claude the exact contract of `tagents-core`, `tagents-knowledge`, `tagents`, `tusage` and `tnotes`: every verb and flag, every MCP tool schema, and the public TypeScript API. It is generated from the code, so it never goes stale ([how](../architecture/contract)). Claude loads it when a task touches tagents instead of guessing at flags.

### The `knowledge` MCP server

The server gives every session search and read access to your markdown notes (`tagents-knowledge`). The plugin registers `packages/knowledge/bin/knowledge-mcp` for it.

- It asks `tagents-knowledge serve` for the unix socket of **one shared knowledge server per environment** and joins the session to it with `nc -U`. That keeps a session at about 1.4 MB instead of a 30 MB node process.
- The server starts on demand and exits after 10 minutes without a client.
- If `serve` fails, a checkout predates it, or there is no `nc`, the script runs `tagents-knowledge mcp` as before.
- `tagents-knowledge` has to be on `$PATH`.

::: warning A hand-registered server appears twice
If that server is already registered by hand with `claude mcp add`, remove the hand-made entry or its tools appear twice.
:::

### The `tagents` MCP server

The server gives a session a tool for each verb of the contract that is meant for a model, nineteen of them, so Claude can do from a conversation what you do from a shell: send a desktop notification, open another Claude Code session on an account of your choice as a window of your tmux (several in a row is how a day can start), open a window running a command, or list and read sessions and notes.

| ask Claude to | tool | runs |
|---|---|---|
| notify you | `notify_send` | `tagents-notify send` |
| open a session in a directory, on an account | `tagents_new` | `tagents --new` |
| open a window running a command | `tagents_window` | `tagents --window` |
| see what is running | `core_session_list`, `core_session_last`, `core_sessions_show` | `tagents-core session …` |
| run a prompt without a window | `tagents_window` | `tagents --window DIR "tagents-core session prompt …"` |

- A tool is named after its verb and takes its arguments, so the list grows with the commands: a verb added to a spec is a new tool once the plugin updates ([how](../architecture/contract#the-tools-follow-the-verbs)). A verb that opens a session or sends a prompt, and the verbs that need a dialog or run until stopped, are left out on purpose: they stay commands of the CLI.
- `tagents_new` and `tagents_window` open windows in the tmux server Claude Code runs in. Outside tmux they refuse with exit 3 and open nothing. A tool opens its window in the background: the window you are looking at stays selected, the answer says which pane and window it opened, and `detach: false` selects the new one instead. `tagents_new` with the profile `ask` is refused with exit 2 and the list of profiles, because a tool call cannot answer a dialog.
- Nothing a call starts outlives the call. If you cancel it, if it has not ended after five minutes, or if the session closes, the program and everything it started are stopped. The output of a call is cut at 256 KiB with a line that says so.
- The plugin adds no permission. Claude Code asks before each tool runs; the tools say what they start in the first words of their description, and read-only tools are marked as such.
- `tagents-mcp`, `tagents-notify` and `tagents-core` have to be on `$PATH`; `install.sh` writes all of them.

## What it does not do

The plugin registers no hooks and no status line. The state hook and the status line stay [steps of the install](./getting-started#tell-claude-code-about-it), because a plugin cannot set a status line.

## Where the rest is documented

- [The generated contract](../architecture/contract), for how the skill is kept honest.
- [`@tagents/knowledge`](https://github.com/SkuratovichA/tagents/blob/main/packages/knowledge/README.md), for the notes documents and the FTS5 index behind the server.
