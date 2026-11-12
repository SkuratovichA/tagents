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

The skill gives Claude the exact contract of `tagents-core`, `okb`, `tagents`, `tusage` and `tnotes`: every verb and flag, every MCP tool schema, and the public TypeScript API. It is generated from the code, so it never goes stale ([how](../architecture/contract)). Claude loads it when a task touches tagents instead of guessing at flags.

### The `knowledge` MCP server

The server gives every session search and read access to your markdown notes (`okb`, also reachable as `tagents-knowledge`). The plugin registers `bin/knowledge-mcp` for it.

- It first asks `tagents-knowledge join` whether this machine has the Rust binary (`okb`, installed by `tagents update` when a release matches the checkout). With the binary, the session's process **is** `okb join`: it connects to **one shared Rust knowledge daemon per environment**, starting it when it is not running, and relays the session's input and output to it. There is no node process and no `nc` in the session.
- Without the binary (none installed, or one the installer could not replace), the wrapper answers `join` with exit code 69. The script then goes on to `tagents-knowledge serve` and `tagents-knowledge mcp`, which answer with one line naming `tagents update` and `cargo build --release -p okb`, and exit 69: the session has no knowledge server until a binary is installed.
- A plugin older than the install still calls `tagents-knowledge serve` and `mcp`; that name is an alias of `okb` and the binary serves them.
- If the binary is there and `join` fails with any code besides 0, 69 and 2, the script writes one line naming the code to stderr, which Claude Code keeps in the log of an MCP server, and goes on to the binary's `serve` and `mcp`, a per-session server that needs no daemon.
- `TAGENTS_NO_NATIVE=1` at install time removes a prebuilt binary and installs the wrappers without one; the wrappers no longer read it when they run.
- Either daemon starts on demand and exits after 10 minutes without a client.
- To see which program serves, run `tagents-knowledge join </dev/null; echo $?`: `0` is the Rust binary, `69` is a machine with no binary. `footprint <pid>` on a session's process shows what it holds, and `ps -o command= -p <pid>` shows the `okb join`. What the processes hold, measured, is in [What a knowledge session holds](../architecture/rust-core.md#what-a-knowledge-session-holds).
- The launcher is part of the plugin, so it arrives with a plugin update: run `claude plugin marketplace update tagents` and then `claude plugin update tagents@tagents`, and restart Claude Code. A copy installed before keeps its old launcher, which reaches the same binary through the wrapper as `serve` and `nc -U`: the session then has the Rust daemon and an `nc` until the plugin is updated.
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
- Nothing a call starts outlives the call. If you cancel it, if it has not ended after five minutes, or if the session closes, the program and everything it started in its process group are stopped; a process that starts a session of its own, as a daemon does, is not. The output of a call is cut at 256 KiB with a line that says so.
- The server runs in the prebuilt Rust binary (`tagents-core mcp`) when the installer has put one on the machine, and answers with the needs-binary line and exit 69 otherwise: node no longer has an MCP server of its own.
- The plugin adds no permission. Claude Code asks before each tool runs; the tools say what they start in the first words of their description, and read-only tools are marked as such.
- `tagents-mcp`, `tagents-notify` and `tagents-core` have to be on `$PATH`; `install.sh` writes all of them, and `tagents-mcp` runs the binary, or gives the needs-binary line when there is none. `tagents-notify run` is the notification service the LaunchAgent starts ([which program runs it](./notifications#which-program-runs-the-service)); `tagents-notify send`, which the `notify_send` tool runs, and every other call are the node program's.

## What it does not do

The plugin registers no hooks and no status line. The state hook and the status line stay [steps of the install](./getting-started#tell-claude-code-about-it), because a plugin cannot set a status line.

## Where the rest is documented

- [The generated contract](../architecture/contract), for how the skill is kept honest.
- [`okb`](https://github.com/SkuratovichA/tagents/tree/main/crates/okb), the Rust binary behind the notes documents and the FTS5 index of the server.
