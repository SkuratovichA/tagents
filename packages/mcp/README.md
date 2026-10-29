# @tagents/mcp

The MCP server of the tagents plugin. It lists one tool for each verb of each structured CLI spec recorded in `contract.json` and runs the verb as a child process, so the tools are the verbs: a verb added to a spec is a tool after `pnpm plugin:gen`, and no tool is written by hand.

```sh
tagents-mcp --contract "$CLAUDE_PLUGIN_ROOT/contract.json"
```

The plugin manifest starts it that way. The command is on `PATH` once `install.sh` has run, as are the programs the tools run (`tagents-core`, `tagents-knowledge`, `tagents-notify`, `tagents`).

## How a verb becomes a tool

| of the verb | in the tool |
|---|---|
| program and path | the name: `tagents-core` `session open` is `core_session_open`, the script's `--new` is `tagents_new` |
| summary | the description, as one sentence |
| `<x>`, `[x]`, `<x…>` positionals | a string, an optional string, a non-empty array of strings property named `x` |
| options and `required` | properties typed as the option is, and `required` |
| `effect` | the annotations: `read` is read-only, `destructive` is destructive, `spawn` reaches outside, no effect is "not read-only" |
| `effect: serve` | no tool: a verb that runs until it is stopped answers nothing |
| `requires: tmux` | the call is refused with exit 3 when the server's environment has no `TMUX` |

`src/tools.ts` holds the rules and is used by the contract generator too, so the list in `contract.json` and the list a client gets are one list.

## A call

The program is run from `PATH` with the server's environment and no stdin. Options go as `--name=value`, then the positionals, and a positional that starts with a dash is refused. The answer is one JSON document:

```json
{ "exit": 0, "outcome": "ok", "stdout": "…", "stderr": "" }
```

`stdout` is parsed when it is a JSON document. A non-zero exit is an error, `outcome` is the name of the code in the program's exit table, and a call that has not ended after an hour is stopped and answered as exit 4.

## Tests

`pnpm --filter @tagents/mcp test`. The smoke test starts the server over stdio against the repository's `contract.json` and a scratch home, and checks that the tools it lists are the ones the contract records.
