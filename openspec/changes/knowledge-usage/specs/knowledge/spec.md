## MODIFIED Requirements

### Requirement: CLI verbs and flags
The `tagents-knowledge` program SHALL provide the verbs `index [--dir D] [--db F] [--full]`, `search <query…> [--dir] [--db] [--usage-db F] [--verbose] [--tag T] [--type T] [--kind K] [--limit N] [--json]`, `show <id[#heading]> [--dir] [--db] [--usage-db F] [--verbose]`, `list [--dir] [--db] [--type T] [--kind K] [--tag T] [--json]`, `lint [--dir D]`, `toc [--dir D] [--check]`, `usage [--dir] [--db] [--usage-db F] [--top N] [--since <N>d] [--type T] [--all] [--candidates] [--min-gets N] [--min-days N] [--json]`, `mcp` and `serve [--idle S] [--foreground] [--socket P]`. `--kind` is a deprecated alias of `--type`. `help`, `--help` and `-h` SHALL print the usage text on stdout. An invalid `--limit` (not a positive number) SHALL be ignored in favour of the default.

#### Scenario: Verbs match the generated contract
- **WHEN** the CLI contract is generated
- **THEN** it lists exactly `index`, `search`, `show`, `list`, `lint`, `toc`, `usage`, `mcp`, `serve`, in English, with exit codes 0, 1, 2 and 4

### Requirement: MCP server
`tagents-knowledge mcp` SHALL serve the MCP protocol over stdio only, as server `tagents-knowledge`, and exit when the client closes the pipe. It SHALL expose exactly six tools: `knowledge_search`, `knowledge_get`, `knowledge_list`, `knowledge_usage`, `sessions_recent`, `sessions_search`. It SHALL offer no tool that writes, edits, deletes or generates a document or an `index.md`. Tool output is English text, and the server SHALL write nothing to stdout besides the protocol.

#### Scenario: Tool inventory
- **WHEN** a client lists the tools
- **THEN** it sees exactly those six names

### Requirement: One shared server per environment
Every client of the same environment SHALL be served by one daemon, and clients whose environments differ SHALL get separate daemons that answer from their own documents. The environment is `HOME`, `TAGENTS_CONFIG_DIR`, `XDG_CONFIG_HOME`, `TAGENTS_KNOWLEDGE_DIR`, `TAGENTS_KNOWLEDGE_DB`, `TAGENTS_KNOWLEDGE_USAGE_DB` and `CLAUDE_HOMES`, plus the build of the program that runs.

#### Scenario: Two sessions, one daemon
- **WHEN** two sessions start at the same moment in the same environment
- **THEN** one daemon serves both, and it outlives them

#### Scenario: Different documents
- **WHEN** one session sets `TAGENTS_KNOWLEDGE_DIR` to folder A and another to folder B
- **THEN** each daemon lists only its own folder's documents

#### Scenario: Different usage stores
- **WHEN** one session sets `TAGENTS_KNOWLEDGE_USAGE_DB` to file A and another to file B, and each reads a document through its daemon
- **THEN** the two sessions get separate daemons, and each read is recorded in its own file only

### Requirement: What makes a different environment
Relative values of `TAGENTS_CONFIG_DIR`, `XDG_CONFIG_HOME`, `TAGENTS_KNOWLEDGE_DIR`, `TAGENTS_KNOWLEDGE_DB`, `TAGENTS_KNOWLEDGE_USAGE_DB` and the entries of `CLAUDE_HOMES` SHALL count as absolute from the caller's directory, `HOME` and values beginning with `~` count as written, and unset counts as empty. Other variables SHALL NOT split daemons, except that a different `TMPDIR` names a different socket directory and so gets a daemon of its own.

#### Scenario: A variable the server does not read
- **WHEN** a session differs only in `CLAUDE_CONFIG_DIR`
- **THEN** it joins the daemon the others use

#### Scenario: A different TMPDIR
- **WHEN** one session sets `TMPDIR` to another directory
- **THEN** it gets a daemon of its own

#### Scenario: A relative usage store
- **WHEN** a session sets `TAGENTS_KNOWLEDGE_USAGE_DB` to `usage.sqlite` and starts in directory D
- **THEN** its daemon records into `D/usage.sqlite`, whatever directory the daemon itself runs in

### Requirement: The shared server speaks the same protocol
Each connection to the daemon SHALL get its own MCP server over newline-delimited JSON-RPC, exposing the same six tools with the same behaviour as `tagents-knowledge mcp`.

#### Scenario: Through the bridge
- **WHEN** a session reaches the daemon through the plugin's server entry
- **THEN** it lists exactly the six tools of the MCP server requirement, and closing its stdin ends its connection

## ADDED Requirements

### Requirement: The usage store
Reads SHALL be recorded in a usage store: a SQLite file of its own, apart from the index, whose table `usage_events` has one row per event, with the columns `ts` (milliseconds since the epoch), `doc_id`, `heading` (empty for a whole document or a search hit), `kind` (`get` or `hit`) and `caller` (null when unknown). Rebuilding, upgrading or deleting the index SHALL leave the store untouched.

#### Scenario: The index is rebuilt
- **WHEN** events are recorded, then `index --full` runs, then the index file is deleted and a read builds it again
- **THEN** every recorded event is still in the usage store

### Requirement: Locating the usage store
The usage store SHALL be the file named by `--usage-db`, else by `TAGENTS_KNOWLEDGE_USAGE_DB`, else `knowledge-usage.sqlite` in the directory of the index in use, however that index was chosen. `~` SHALL be expanded. The MCP tools have no flags and SHALL locate the store from the environment alone. The file and its directory SHALL be created when the first event is recorded.

#### Scenario: Beside the index
- **WHEN** `show` runs with `--db /tmp/x/index.sqlite` and no usage setting
- **THEN** its event is recorded in `/tmp/x/knowledge-usage.sqlite`

#### Scenario: Flag, variable, default
- **WHEN** `--usage-db a.sqlite` is given while `TAGENTS_KNOWLEDGE_USAGE_DB` names `b.sqlite`
- **THEN** the event is recorded in `a.sqlite`, and with the variable alone, in `b.sqlite`

### Requirement: What a get records
`show` and `knowledge_get` SHALL record one `get` for each call that returns text: the document `id` as indexed, and the section heading as the document writes it when a section was asked for, otherwise an empty heading. A call that fails, for an unknown id or heading, SHALL record nothing.

#### Scenario: A section
- **WHEN** `show deploy-runbook#rollback` runs on a document whose section is `Rollback`
- **THEN** one `get` is recorded, with `doc_id` `deploy-runbook` and `heading` `Rollback`

#### Scenario: An unknown id
- **WHEN** `knowledge_get` is called with an id that does not exist
- **THEN** the result is a tool error and no event is recorded

### Requirement: What a hit records
`search` and `knowledge_search` SHALL record one `hit` for each distinct document among the results they return, with an empty heading, however many of its sections matched. A search that returns nothing SHALL record nothing.

#### Scenario: Two sections of one document
- **WHEN** a search returns two sections of `deploy-runbook` and one of `mashina-karta`
- **THEN** two `hit` events are recorded, one for each document

#### Scenario: Nothing matches
- **WHEN** a search finds nothing
- **THEN** no event is recorded

### Requirement: Other reads record nothing
`index`, `list`, `lint`, `toc`, `usage`, `knowledge_list`, `knowledge_usage` and the sessions tools SHALL record no event, so that listing or reporting never counts as use.

#### Scenario: A report is not a read
- **WHEN** `usage` runs twice in a row
- **THEN** both reports show the same counts

### Requirement: The caller of an event
The `caller` of an event SHALL be the client name given in the MCP handshake for the tools, the value of `TA_LABEL` for the CLI verbs when it is set and not empty, and null otherwise. The text of a query and any session identifier SHALL NOT be stored.

#### Scenario: A client name
- **WHEN** a client that calls itself `knowledge-suite` calls `knowledge_get`
- **THEN** the event's `caller` is `knowledge-suite`

#### Scenario: A label
- **WHEN** `show` runs with `TA_LABEL=builder`
- **THEN** the event's `caller` is `builder`

#### Scenario: A query is not stored
- **WHEN** `search` runs with a query that matches a document
- **THEN** no column of any row of the store contains the query text

### Requirement: Recording never fails a read
A usage store that cannot be opened, stays locked for more than 250 ms, or cannot be written SHALL NOT change the output or the exit code of the read that tried to record. `search` and `show` with `--verbose` SHALL then say on stderr that the read was not recorded and why; without it they SHALL stay silent.

#### Scenario: An unwritable store
- **WHEN** `TAGENTS_KNOWLEDGE_USAGE_DB` names a path that cannot be opened and `show deploy-runbook` runs
- **THEN** stdout and the exit code are those of a run without the problem, and stderr is empty

#### Scenario: Verbose
- **WHEN** the same run has `--verbose`
- **THEN** stderr names the usage store, and the exit code is still 0

### Requirement: Retention of usage events
Recording an event SHALL delete the events older than 365 days.

#### Scenario: Old events go
- **WHEN** a store holds one event 366 days old and another 364 days old, and a read is recorded
- **THEN** the older event is gone and the other stays

### Requirement: The usage report
`usage` SHALL print a header line and then one line per document with the columns `id`, `type`, `status`, `gets`, `hits`, `days` and `last`, separated by at least two spaces, sorted by `gets` descending, then `hits` descending, then `id`, and limited to `--top N` lines (default 20). A value that is unknown is printed as `-`.

#### Scenario: Order and columns
- **WHEN** `deploy-runbook` has 4 `get` events on 2 UTC dates and 1 `hit`, and `mashina-karta` has none, all inside the window
- **THEN** `deploy-runbook` is listed first with 4, 1 and 2 and the date of its newest `get`, and `mashina-karta` after it with 0, 0, 0 and `-`

#### Scenario: Top
- **WHEN** the folder holds 25 documents and `usage` runs without `--top`
- **THEN** 20 document lines follow the header

### Requirement: Counts in the report
`gets` and `hits` SHALL count the events not older than the window, `--since <N>d` (default `30d`), a day being 24 hours. `days` SHALL be the number of distinct UTC dates on which the document has a `get` in the window. `last` SHALL be the UTC date of its newest `get` in the store, whatever its age, and `-` when it has none.

#### Scenario: The window
- **WHEN** a document has a `get` 31 days old and another 29 days old
- **THEN** with the default window its `gets` is 1 and its `last` is the date of the newer one

#### Scenario: Days
- **WHEN** a document has three `get` events on one UTC date and one on the next
- **THEN** its `gets` is 4 and its `days` is 2

#### Scenario: Only an old get
- **WHEN** the only `get` of a document is 100 days old
- **THEN** its `gets` and `days` are 0 and its `last` is that date

### Requirement: Arguments of the usage verb
`--since` SHALL be a positive whole number followed by `d`; `--top`, `--min-gets` and `--min-days` SHALL be positive whole numbers. Any other value SHALL exit 2 with a message on stderr that names the flag.

#### Scenario: Bad values
- **WHEN** `--since` is given `30`, `0d` or `soon`, or `--top` is given `0` or `many`
- **THEN** the exit code is 2 and stderr names the flag

### Requirement: Documents in the report
`usage` SHALL list every document of the folder, the unread ones with zeros. An id that has events but is no longer in the folder SHALL be listed only with `--all`, with `-` (JSON `null`) as its type and status. `--type T` SHALL keep only the documents of that type, matched as `list` matches it, and so drops ids no longer in the folder.

#### Scenario: An unread document
- **WHEN** `mashina-karta` has no events
- **THEN** it is listed with `gets`, `hits` and `days` 0 and `last` `-`

#### Scenario: A removed document
- **WHEN** events exist for `old-runbook`, which is not in the folder
- **THEN** `usage` does not list it, and `usage --all` does, with `-` as its type and status

### Requirement: Candidates for a skill
`--candidates` SHALL keep only the documents of the folder whose status is not `deprecated` and that have at least `--min-gets` `get` events (default 5) on at least `--min-days` distinct UTC dates (default 3) inside the window. Hits do not count. It only names documents: it creates, edits and ranks nothing.

#### Scenario: At the thresholds
- **WHEN** a stable document has 5 `get` events on 3 UTC dates inside the window
- **THEN** `usage --candidates` lists it, and does not when it has 5 on 2 dates or 4 on 3

#### Scenario: Deprecated documents and hits
- **WHEN** a deprecated document has 9 `get` events on 5 dates, and another has 2 `get` and 40 `hit` events
- **THEN** `usage --candidates` lists neither

#### Scenario: Own thresholds
- **WHEN** `--min-gets 2 --min-days 1` is given and a document has 2 `get` events on one date
- **THEN** it is listed

### Requirement: Usage report output
With `--json`, `usage` SHALL print a JSON array of objects with exactly the keys `id`, `type`, `status`, `gets`, `hits`, `days` and `last`, where `type`, `status` and `last` are null when unknown. When no row is left it SHALL exit 4, printing `[]` with `--json` and a sentence on stderr without it.

#### Scenario: JSON
- **WHEN** `usage --json` runs on a folder with one read document
- **THEN** stdout is an array whose objects have exactly those seven keys, with `gets`, `hits` and `days` as numbers

#### Scenario: Nothing left
- **WHEN** `usage --candidates --json` finds no candidate
- **THEN** stdout is `[]` and the exit code is 4

### Requirement: A missing or damaged usage store
A usage store that does not exist SHALL count as holding no events, and `usage` SHALL NOT create it. A store that exists but cannot be read SHALL make `usage` exit 1 with a message on stderr that names the file.

#### Scenario: No store yet
- **WHEN** `usage` runs before any read was recorded
- **THEN** every document is listed with zeros, the exit code is 0 and the store file does not exist afterwards

#### Scenario: A damaged store
- **WHEN** the store file holds text that is not a database
- **THEN** `usage` exits 1 and stderr names the file

### Requirement: Tool knowledge_usage
`knowledge_usage` SHALL take optional `since` (as `--since`, default `30d`), `top` (integer from 1, default 20), `type` (string), `all` and `candidates` (booleans), `min_gets` and `min_days` (integers from 1), and return the rows of `usage --json` as pretty-printed JSON text; no row is the JSON `[]`, not an error. A bad `since` SHALL be a tool error that names `since`.

#### Scenario: The same rows as the CLI
- **WHEN** `knowledge_usage` is called with `candidates: true` and `usage --candidates --json` runs on the same store
- **THEN** the two arrays are equal

#### Scenario: Schema
- **WHEN** the tool list is read
- **THEN** the input properties are `all`, `candidates`, `min_days`, `min_gets`, `since`, `top`, `type` and none is required

#### Scenario: A bad window
- **WHEN** it is called with `since: "soon"`
- **THEN** the result is a tool error whose text names `since`

### Requirement: Usage does not rank
The order of the results of `search` and `knowledge_search` SHALL NOT depend on the usage store: the same query on the same documents returns the same hits in the same order, whatever has been recorded.

#### Scenario: A busy document
- **WHEN** one of two equally matching documents has many `get` events and the other none
- **THEN** a search lists them in the same order as it does with an empty usage store
