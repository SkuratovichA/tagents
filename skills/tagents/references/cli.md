# CLI reference

This file is generated from the code by `pnpm plugin:gen`. Do not edit it by hand: change the code and regenerate.

## tagents-core

### Exit codes

| Code | Outcome |
|---|---|
| 0 | ok |
| 1 | error |
| 2 | usage |
| 3 | refused |
| 4 | timeout |

### session open

starts a headless Claude session and prints its SessionRef as JSON

Usage: `tagents-core session open --cwd <cwd> [--label <label>] [--model <model>] [--effort <effort>] [--resume <resume>] [--system-prompt-file <system-prompt-file>] [--mcp-config <mcp-config>] [--config-dir <config-dir>] [--no-config-dir] [--skip-permissions]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--cwd` | string | yes | no |
| `--label` | string | no | no |
| `--model` | string | no | no |
| `--effort` | string | no | no |
| `--resume` | string | no | no |
| `--system-prompt-file` | string | no | no |
| `--mcp-config` | string | no | no |
| `--config-dir` | string | no | no |
| `--no-config-dir` | boolean | no | no |
| `--skip-permissions` | boolean | no | no |

### session prompt

sends one prompt to a session and prints the TurnOutcome as JSON; with --events, NDJSON events with the outcome last

Usage: `tagents-core session prompt <ref-json-or-id> <text> [--timeout <timeout>] [--warn-before <warn-before>] [--events]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--timeout` | string | no | no |
| `--warn-before` | string | no | no |
| `--events` | boolean | no | no |

### session last

prints the last assistant text of a session and when it came, as JSON, or null

Usage: `tagents-core session last <ref-json-or-id>`

This verb takes no flags.

### session list

prints the known sessions as a JSON array of SessionRef, filtered by label and state

Usage: `tagents-core session list [--label <label>] [--state <state>…]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--label` | string | no | no |
| `--state` | string | no | yes |

### session abort

stops the turn running in a session and prints whether it did, with the id and pid, as JSON

Usage: `tagents-core session abort <ref-json-or-id>`

This verb takes no flags.

### sessions recent

prints the most recent transcripts as text

Usage: `tagents-core sessions recent [N]`

This verb takes no flags.

### sessions search

prints the transcripts that match the words, as text

Usage: `tagents-core sessions search <words…>`

This verb takes no flags.

### sessions show

prints the full text of one transcript, picked by id prefix

Usage: `tagents-core sessions show <id-prefix>`

This verb takes no flags.

### plugin list

lists the configured plugins and what each offers, as lines or with --json one JSON document

Usage: `tagents-core plugin list [--json]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--json` | boolean | no | no |

### plugin add

validates a package manifest and writes the plugin into config.yaml

Usage: `tagents-core plugin add <package-or-path> [--name <name>]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--name` | string | no | no |

### plugin remove

takes one plugin entry back out of config.yaml

Usage: `tagents-core plugin remove <name>`

This verb takes no flags.

### plugin new

scaffolds a package that is already a plugin

Usage: `tagents-core plugin new <name> [--dir <dir>]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--dir` | string | no | no |

### doctor

prints the node version, the state directory, the config file and whether claude is on PATH

Usage: `tagents-core doctor`

This verb takes no flags.

## tagents-knowledge

### Exit codes

| Code | Outcome |
|---|---|
| 0 | ok |
| 1 | error |
| 2 | usage |
| 4 | notFound |

### index

brings the index in line with the folder; --full rebuilds it from nothing

Usage: `tagents-knowledge index [--dir <dir>] [--db <db>] [--full]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--dir` | string | no | no |
| `--db` | string | no | no |
| `--full` | boolean | no | no |

### search

prints one line per hit: id#heading, score and snippet

Usage: `tagents-knowledge search <query…> [--dir <dir>] [--db <db>] [--tag <tag>] [--kind <kind>] [--limit <limit>] [--json]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--dir` | string | no | no |
| `--db` | string | no | no |
| `--tag` | string | no | no |
| `--kind` | string | no | no |
| `--limit` | string | no | no |
| `--json` | boolean | no | no |

### show

prints the markdown of a document, or of one section of it

Usage: `tagents-knowledge show <id[#heading]> [--dir <dir>] [--db <db>]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--dir` | string | no | no |
| `--db` | string | no | no |

### list

prints one line per document: id, kind, updated, title and tags

Usage: `tagents-knowledge list [--dir <dir>] [--db <db>] [--kind <kind>] [--tag <tag>] [--json]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--dir` | string | no | no |
| `--db` | string | no | no |
| `--kind` | string | no | no |
| `--tag` | string | no | no |
| `--json` | boolean | no | no |

### lint

checks the claims each document makes about itself

Usage: `tagents-knowledge lint [--dir <dir>]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--dir` | string | no | no |

### mcp

serves the knowledge tools over stdio as an MCP server

Usage: `tagents-knowledge mcp`

This verb takes no flags.

### serve

starts the shared MCP server for this environment if it is not running and prints its unix socket; --idle S is how many seconds without a client before it exits (default 600); --foreground runs the server in this process, on --socket P

Usage: `tagents-knowledge serve [--idle <idle>] [--foreground] [--socket <socket>]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--idle` | string | no | no |
| `--foreground` | boolean | no | no |
| `--socket` | string | no | no |
