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

prepares a headless Claude session for a directory and prints its SessionRef as JSON; no process starts until a prompt is sent to it

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

runs one Claude turn: sends the prompt to a session, waits for the answer and prints the TurnOutcome as JSON; with --events, NDJSON events with the outcome last

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

prints one line per hit: id#heading, score and snippet; --type filters by type (--kind is its deprecated alias); deprecated documents come last; each document it returns is recorded as a hit in the usage store (--usage-db F names the file, --verbose says why a read was not recorded)

Usage: `tagents-knowledge search <query…> [--dir <dir>] [--db <db>] [--tag <tag>] [--type <type>] [--kind <kind>] [--limit <limit>] [--json] [--usage-db <usage-db>] [--verbose]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--dir` | string | no | no |
| `--db` | string | no | no |
| `--tag` | string | no | no |
| `--type` | string | no | no |
| `--kind` | string | no | no |
| `--limit` | string | no | no |
| `--json` | boolean | no | no |
| `--usage-db` | string | no | no |
| `--verbose` | boolean | no | no |

### show

prints the markdown of a document, or of one section of it; the read is recorded as a get in the usage store (--usage-db F names the file, --verbose says why a read was not recorded)

Usage: `tagents-knowledge show <id[#heading]> [--dir <dir>] [--db <db>] [--usage-db <usage-db>] [--verbose]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--dir` | string | no | no |
| `--db` | string | no | no |
| `--usage-db` | string | no | no |
| `--verbose` | boolean | no | no |

### list

prints one line per document: id, type, updated, title and tags; --type filters by type (--kind is its deprecated alias); deprecated documents come last

Usage: `tagents-knowledge list [--dir <dir>] [--db <db>] [--type <type>] [--kind <kind>] [--tag <tag>] [--json]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--dir` | string | no | no |
| `--db` | string | no | no |
| `--type` | string | no | no |
| `--kind` | string | no | no |
| `--tag` | string | no | no |
| `--json` | boolean | no | no |

### lint

checks the claims each document makes about itself

Usage: `tagents-knowledge lint [--dir <dir>]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--dir` | string | no | no |

### toc

writes index.md, the OKF table of contents of the folder, grouped by type; --check writes nothing and exits 1 when index.md is absent or out of date

Usage: `tagents-knowledge toc [--dir <dir>] [--check]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--dir` | string | no | no |
| `--check` | boolean | no | no |

### usage

reports what was read: one line per document with its type, status, gets, hits, the UTC days with a get and the date of the last get, the most read first; --since Nd sets the window (default 30d), --top N the number of lines (default 20), --type T keeps one type, --all adds ids that left the folder, --candidates keeps the documents read at least --min-gets times (default 5) on at least --min-days days (default 3), the ones worth turning into a skill; --usage-db F names the usage store

Usage: `tagents-knowledge usage [--dir <dir>] [--db <db>] [--usage-db <usage-db>] [--since <since>] [--top <top>] [--type <type>] [--all] [--candidates] [--min-gets <min-gets>] [--min-days <min-days>] [--json]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--dir` | string | no | no |
| `--db` | string | no | no |
| `--usage-db` | string | no | no |
| `--since` | string | no | no |
| `--top` | string | no | no |
| `--type` | string | no | no |
| `--all` | boolean | no | no |
| `--candidates` | boolean | no | no |
| `--min-gets` | string | no | no |
| `--min-days` | string | no | no |
| `--json` | boolean | no | no |

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

## tagents-notify

### Exit codes

| Code | Outcome |
|---|---|
| 0 | ok |
| 1 | error |
| 2 | usage |

### run

runs the notification service in the foreground until it is stopped

Usage: `tagents-notify run`

This verb takes no flags.

### install

installs and starts the notification service as a login item, builds its helper app and asks macOS for permission to notify

Usage: `tagents-notify install`

This verb takes no flags.

### uninstall

stops and removes the notification service; with purge it also deletes the helper app

Usage: `tagents-notify uninstall [--purge]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--purge` | boolean | no | no |

### status

prints whether notifications will arrive: the service, the permission, the options and the click script

Usage: `tagents-notify status`

This verb takes no flags.

### test

posts one sample notice of the given kind through the configured backend, which shows it on the screen

Usage: `tagents-notify test [--kind <kind>]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--kind` | string | no | no |

### send

posts a desktop notification with this message (the words are joined with a space) through the configured backend, which shows it on the screen; a click docks the pane the command runs in; a title over 256 characters or a message over 2048 is refused

Usage: `tagents-notify send <message…> [--title <title>]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--title` | string | no | no |

## tagents

### Exit codes

| Code | Outcome |
|---|---|
| 0 | ok |
| 1 | error |
| 2 | usage |

### --new

starts a new interactive Claude Code session in DIR (default: the current directory) on the account PROFILE (default: the one the config rules pick), as a window of the tmux server this runs in, which the dashboard lists; detach (the default for a tool call) does not show or select the window and never opens a dialog, so when the rules say to ask which account it fails and names the profiles to pass

Usage: `tagents --new [DIR] [PROFILE] [--detach]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--detach` | boolean | no | no |

### --window

opens a tmux window in DIR that runs COMMAND, one string for the shell, and prints the new pane and where it is; the window closes when the command ends, and it lands in the session that owns DIR on the tmux server this runs in; detach (the default for a tool call) does not show or select the window

Usage: `tagents --window <DIR> <COMMAND> [--detach]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--detach` | boolean | no | no |

### --label

names an agent on the dashboard; K is its session id or pane id, and an empty NAME clears the name back to the window title

Usage: `tagents --label <K> <NAME>`

This verb takes no flags.

### --profile-for

prints which account profile the config rules pick for DIR (and the tmux SESSION, when given), or ask, without starting anything; prints nothing and exits 1 when no profiles are configured

Usage: `tagents --profile-for <DIR> [SESSION]`

This verb takes no flags.

### --config

prints the config as tagents reads it, one path and value per line, which includes the account profiles a session can be started on

Usage: `tagents --config`

This verb takes no flags.

### --check

prints what is wrong with the config, one line each, and exits 1 while anything is; prints nothing and exits 0 when it is sound

Usage: `tagents --check`

This verb takes no flags.
