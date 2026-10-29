# @tagents/mcp

The MCP server of the tagents plugin. It lists one tool for each verb of each structured CLI spec recorded in `contract.json` and runs the verb as a child process, so the tools are the verbs: a verb added to a spec is a tool after `pnpm plugin:gen`, and no tool is written by hand.

```sh
tagents-mcp --contract "$CLAUDE_PLUGIN_ROOT/contract.json"
```

The plugin manifest starts it that way. The command is on `PATH` once `install.sh` has run, as are the programs the tools run (`tagents-core`, `tagents-knowledge`, `tagents-notify`, `tagents`).

## How a verb becomes a tool

| of the verb | in the tool |
|---|---|
| program and path | the name: `tagents-core` `session list` is `core_session_list`, the script's `--new` is `tagents_new` |
| summary | the description, as one sentence |
| `<x>`, `[x]`, `<x…>` positionals | a string, an optional string, a non-empty array of strings property named `x` |
| options and `required` | properties typed as the option is, and `required` |
| `effect` | the annotations: `read` is read-only, `destructive` is destructive, `spawn` reaches outside, no effect is "not read-only" |
| `effect: serve` | no tool: a verb that runs until it is stopped answers nothing |
| `tool: false` | no tool: the verb is not for a model, and stays in the contract and the references |
| `toolDefaults` | a boolean option the call may leave out gets the default: `tagents_new` and `tagents_window` open their window with `detach` |
| `requires: tmux` | the call is refused with exit 3 when the server's environment has no `TMUX` |

`src/tools.ts` holds the rules and is used by the contract generator too, so the list in `contract.json` and the list a client gets are one list.

## A call

The program is run from `PATH` with the server's environment and no stdin. A string option goes as `--name=value`, a boolean as `--name` when it is true, then the positionals, each as one word. A positional that starts with a dash and an argument with a NUL byte are refused with the exit `usage`. The answer is one JSON document:

```json
{ "exit": 0, "outcome": "ok", "stdout": "…", "stderr": "" }
```

`stdout` is parsed when it is a JSON document. A non-zero exit is an error, and `outcome` is the name of the code in the program's exit table, or `cancelled` for a call that was stopped.

Each stream is kept to its first 256 KiB, cut on a character boundary, with a last line `[output cut at 262144 bytes]` and `"truncated": true` in the document. A call that has not ended after five minutes is stopped and answered as exit 4.

## Nothing outlives a call

Each program leads a process group of its own. A call ends when the program exits, at the timeout, when the client cancels the request, and when the server's stdin closes or the server gets SIGTERM, SIGINT or SIGHUP. Except for the first, the group is sent SIGTERM and, two seconds later, SIGKILL. What the program left in its group after it exited is killed at once, and the call waits for the output pipes for a moment only, so a process outside the group that holds them cannot keep the call open.

## Tests

`pnpm --filter @tagents/mcp test`. The smoke test starts the server over stdio against the repository's `contract.json` and a scratch home, and checks that the tools it lists are the ones the contract records.
