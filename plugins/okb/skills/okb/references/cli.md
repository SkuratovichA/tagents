# CLI reference

This file is generated from the code by `pnpm plugin:gen`. Do not edit it by hand: change the code and regenerate.

## okb

### Exit codes

| Code | Outcome |
|---|---|
| 0 | ok |
| 1 | error |
| 2 | usage |
| 4 | notFound |
| 69 | noBinary |

### index

brings the index in line with the folder; --full rebuilds it from nothing

Tool: `okb_index`

Usage: `okb index [--dir <dir>] [--db <db>] [--full]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--dir` | string | no | no |
| `--db` | string | no | no |
| `--full` | boolean | no | no |

### search

prints one line per hit: id#heading, score and snippet; --type filters by type (--kind is its deprecated alias); deprecated documents come last; each document it returns is recorded as a hit in the usage store (--usage-db F names the file, --verbose says why a read was not recorded)

CLI only: no tool runs this verb.

Usage: `okb search <query…> [--dir <dir>] [--db <db>] [--tag <tag>] [--type <type>] [--kind <kind>] [--limit <limit>] [--json] [--usage-db <usage-db>] [--verbose]`

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

CLI only: no tool runs this verb.

Usage: `okb show <id[#heading]> [--dir <dir>] [--db <db>] [--usage-db <usage-db>] [--verbose]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--dir` | string | no | no |
| `--db` | string | no | no |
| `--usage-db` | string | no | no |
| `--verbose` | boolean | no | no |

### list

prints one line per document: id, type, updated, title and tags; --type filters by type (--kind is its deprecated alias); deprecated documents come last

CLI only: no tool runs this verb.

Usage: `okb list [--dir <dir>] [--db <db>] [--type <type>] [--kind <kind>] [--tag <tag>] [--json]`

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

Tool: `okb_lint`

Usage: `okb lint [--dir <dir>]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--dir` | string | no | no |

### toc

writes index.md, the OKF table of contents of the folder, grouped by type; --check writes nothing and exits 1 when index.md is absent or out of date

Tool: `okb_toc`

Usage: `okb toc [--dir <dir>] [--check]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--dir` | string | no | no |
| `--check` | boolean | no | no |

### usage

reports what was read: one line per document with its type, status, gets, hits, the UTC days with a get and the date of the last get, the most read first; --since Nd sets the window (default 30d), --top N the number of lines (default 20), --type T keeps one type, --all adds ids that left the folder, --candidates keeps the documents read at least --min-gets times (default 5) on at least --min-days days (default 3), the ones worth turning into a skill; --usage-db F names the usage store

CLI only: no tool runs this verb.

Usage: `okb usage [--dir <dir>] [--db <db>] [--usage-db <usage-db>] [--since <since>] [--top <top>] [--type <type>] [--all] [--candidates] [--min-gets <min-gets>] [--min-days <min-days>] [--json]`

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

serves the six knowledge tools to an MCP client over stdin and stdout in this process until the client closes them

CLI only: no tool runs this verb.

Usage: `okb mcp`

This verb takes no flags.

### serve

prints the socket of the shared knowledge server of this environment and starts that server when nothing answers; with --foreground it is the server itself

CLI only: no tool runs this verb.

Usage: `okb serve [--idle <idle>] [--foreground] [--socket <socket>]`

| Flag | Type | Required | Repeatable |
|---|---|---|---|
| `--idle` | string | no | no |
| `--foreground` | boolean | no | no |
| `--socket` | string | no | no |

### join

connects stdin and stdout to the shared knowledge server, starting it when none runs, and serves in this process when none can be started

CLI only: no tool runs this verb.

Usage: `okb join`

This verb takes no flags.
