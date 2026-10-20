# knowledge Specification

## Purpose
The owner's operational knowledge kept as small markdown documents and made searchable through a full-text index, from a terminal (`tagents-knowledge`) and from any MCP client, either one server process per client or one server shared by every client of the same environment. Documents are only ever read by this capability; writes go through git.

## Requirements

### Requirement: Document file format
A knowledge document SHALL be one markdown file named `<id>.md` in the knowledge folder, opening with a `---` YAML frontmatter block that carries `id`, `title`, `kind`, `tags` and `updated`, and optionally `generated_from` and `scope`, and no other key. A violation of the field rules SHALL make the file invalid, and the error SHALL name the file and the offending field.

#### Scenario: A valid document is accepted
- **WHEN** a file `deploy-runbook.md` has frontmatter with id `deploy-runbook`, a title, kind `runbook`, tags `[deploy, ci]` and `updated: 2026-09-10`
- **THEN** it is indexed and listed with those values

#### Scenario: Invalid frontmatter is refused
- **WHEN** a file has kind `checklist`, or `updated: 2026-02-30`, or `updated: 11.09.2026`, or an id like `Not A Slug`, or no `tags` key, or an extra key such as `author`
- **THEN** the file is refused with a message naming the field that failed

#### Scenario: A file without frontmatter is refused
- **WHEN** a file does not open with a `---` block
- **THEN** it is refused with the message that no YAML frontmatter was found

### Requirement: Frontmatter field rules
`id` and each tag SHALL be slugs (lowercase words joined by single dashes). `title` SHALL be non-empty. `kind` SHALL be one of `cheatsheet`, `runbook`, `map`, `decision`, `note`. `tags` SHALL be an array, possibly empty but present. `updated` SHALL be a real calendar date written `YYYY-MM-DD`. `generated_from`, when given, SHALL be a non-empty string, and `scope`, when given, SHALL be `global` or `project`.

#### Scenario: Optional keys
- **WHEN** a document sets `scope: project` and `generated_from: ../src/hosts.yaml`
- **THEN** it is valid

#### Scenario: Bad scope
- **WHEN** `scope` is `everywhere`
- **THEN** the file is refused naming `scope`

### Requirement: Id equals filename stem
The `id` in a document's frontmatter MUST equal its filename without the `.md` extension, because every verb and tool addresses documents by id. A file whose id differs from its stem SHALL be refused by the loader and the index, and reported by `lint` as a finding.

#### Scenario: Mismatch is refused
- **WHEN** `other-name.md` declares `id: sample`
- **THEN** reading it fails with a message that the id must equal the filename stem

### Requirement: Which files are documents
Only regular files in the top level of the knowledge folder whose name ends in `.md` and does not start with a dot SHALL be considered documents, in id order. Subdirectories and dotfiles SHALL be ignored.

#### Scenario: Hidden files and subfolders are skipped
- **WHEN** the folder holds `.draft.md` and a subdirectory containing `x.md`
- **THEN** neither appears in `index`, `list`, `search` or `lint`

### Requirement: Sections
The body of a document SHALL be split into sections at lines beginning with `## `. Text before the first such heading is the preamble section, whose heading is the empty string; a document that opens directly with a `## ` heading has no preamble section. Deeper headings (`###` and below) SHALL stay inside their section, and a `## ` line inside a fenced code block (``` or ~~~) SHALL NOT start a section. A search hit or a section read is addressed as `id#heading`.

#### Scenario: Fenced shell comments do not split
- **WHEN** a section contains a fenced block with the line `## not a heading, a shell comment`
- **THEN** the line stays in that section and no new section starts

#### Scenario: No preamble when the body starts with a heading
- **WHEN** a body begins with `## Only`
- **THEN** the document has exactly one section, `Only`

### Requirement: Wikilinks
The forms `[[id]]` and `[[id#Heading]]` SHALL be recognised as links to a document, or to a section of one, and are checked by `lint`. No other link syntax is understood.

#### Scenario: Both forms are read
- **WHEN** a body contains `[[other-doc]]` and `[[other-doc#Some Heading]]`
- **THEN** both links are recognised, the second with its heading

### Requirement: Locating the documents folder
The folder of documents SHALL be chosen, in order of precedence, from the `--dir` flag, the `TAGENTS_KNOWLEDGE_DIR` environment variable, then `knowledge.dir` in the tagents `config.yaml` (in the tagents config directory, `~/.config/tagents` unless `TAGENTS_CONFIG_DIR` moves it). There SHALL be no default folder, and a blank value is treated as not given.

#### Scenario: Environment beats config, flag beats both
- **WHEN** config names folder A, `TAGENTS_KNOWLEDGE_DIR` names folder B and `--dir` names folder C
- **THEN** the CLI uses C; without `--dir` it uses B; with neither it uses A

#### Scenario: Config alone is enough
- **WHEN** only `config.yaml` holds `knowledge: { dir: ./knowledge }`
- **THEN** `tagents-knowledge list` reads the `knowledge` folder next to the config file

#### Scenario: Blank value ignored
- **WHEN** `TAGENTS_KNOWLEDGE_DIR` is set to an empty or whitespace string and config names a folder
- **THEN** the config folder is used

#### Scenario: Nobody said where
- **WHEN** no flag, variable or config key names a folder
- **THEN** the command exits 1 and stderr explains that `TAGENTS_KNOWLEDGE_DIR`, `--dir` or the `config.yaml` key must be set

#### Scenario: The chosen folder does not exist
- **WHEN** the chosen path does not exist
- **THEN** the command exits 1 and stderr says the knowledge directory does not exist

### Requirement: Path forms in the folder setting
A leading `~` in `--dir`, `TAGENTS_KNOWLEDGE_DIR` or `knowledge.dir` SHALL be expanded to the home directory, and only at the start. A relative `knowledge.dir` SHALL be resolved against the directory that holds the config file. A config file that is missing, unparseable, or without `knowledge.dir` SHALL count as not set, and its other keys (such as `plugins:`) SHALL be ignored.

#### Scenario: Tilde in config
- **WHEN** config holds `knowledge: { dir: ~/knowledge }`
- **THEN** the folder is `knowledge` under the home directory

#### Scenario: Config without a knowledge section
- **WHEN** config holds only `plugins: {}`, or does not exist
- **THEN** the folder counts as not set

### Requirement: Locating the index
The search index SHALL be a single SQLite file chosen from the `--db` flag, then the `TAGENTS_KNOWLEDGE_DB` environment variable, then `knowledge.sqlite` in the tagents config directory. Unlike the documents folder, the index has a default. The file and its parent directories SHALL be created when missing. The index is derived data: when it was written by an incompatible schema version it SHALL be discarded and rebuilt from the documents, and deleting it SHALL lose nothing.

#### Scenario: Default location
- **WHEN** neither `--db` nor `TAGENTS_KNOWLEDGE_DB` is given and `TAGENTS_CONFIG_DIR` is `/cfg`
- **THEN** the index is `/cfg/knowledge.sqlite`

#### Scenario: Environment moves the index
- **WHEN** `TAGENTS_KNOWLEDGE_DB` names another file
- **THEN** that file is used, unless `--db` is also given, in which case `--db` wins

### Requirement: Incremental indexing
Bringing the index in line with the folder SHALL add new documents, re-index changed ones, drop the documents whose file is gone, and report the counts of added, changed, unchanged and removed documents. A file whose modification time has not moved SHALL NOT be read. A file whose modification time moved SHALL be compared by content hash, and counted unchanged when the bytes did not change.

#### Scenario: Second run reads nothing
- **WHEN** `index` runs twice on a folder of five documents
- **THEN** the first reports `5 new, 0 changed, 0 unchanged, 0 removed` and the second `0 new, 0 changed, 5 unchanged`

#### Scenario: Touching a file is not a change
- **WHEN** a file's mtime is moved without changing its bytes
- **THEN** it is counted unchanged

#### Scenario: Edit and delete
- **WHEN** a document gains a new section and another document file is deleted
- **THEN** the next run reports one changed and one removed, the new section becomes searchable and the deleted document does not answer

### Requirement: Full rebuild
`index --full` SHALL empty the index and rebuild it from the folder, ending in the same content as an incremental run.

#### Scenario: Rebuild from nothing
- **WHEN** `index --full` runs on a folder of five documents already indexed
- **THEN** it reports five added and none unchanged, and `list` returns the same documents as before

### Requirement: Unreadable documents
A document that fails validation SHALL be reported per file as `<filename>: <message>` on stderr, SHALL be removed from the index (it must not keep serving its last good text), and SHALL NOT stop the rest of the folder from being indexed. The `index` verb SHALL print the counts, report `N file(s) could not be read; run lint` and exit 1 when any file failed; read verbs (`search`, `show`, `list`) report the failing files on stderr and carry on with their own exit code.

#### Scenario: One bad file among good ones
- **WHEN** `slomannyj.md` lacks a `kind` and `search rollback` runs
- **THEN** stderr names `slomannyj.md: frontmatter…`, the hits from the good documents are printed and the exit code is 0
- **AND** `index` on the same folder exits 1

### Requirement: Freshness of reads
Every read verb (`search`, `show`, `list`) and every MCP knowledge tool SHALL bring the index in line with the folder before answering, so that an edit made since the last call is visible.

#### Scenario: A new document is found at once
- **WHEN** a document is added to the folder after the last `index` and `search` runs for a word it contains
- **THEN** the new document is among the hits

### Requirement: Search semantics
A search SHALL match sections of documents, returning for each hit the document `id`, `title`, section `heading` (empty for the preamble), `score`, `snippet` and absolute `path`. Every whitespace-separated word of the query SHALL appear in the same section, and a word ending in `*` SHALL match as a prefix. Words are split Unicode-aware with diacritics folded and punctuation as a separator, so Cyrillic is searchable and `agent state` finds `tmux-agent-state.sh`. There is no stemming.

#### Scenario: Russian and English corpora
- **WHEN** searching `бэкапы`
- **THEN** only the Russian section containing that word is returned, and searching `бэкапы embeddings` returns nothing

#### Scenario: No morphology
- **WHEN** a section holds `бэкапы` and the query is `бэкап`
- **THEN** it is not found, while `бэкап*` finds it

#### Scenario: Prefix form
- **WHEN** the query is `релиз*`
- **THEN** sections containing `релизы` are found

### Requirement: Queries cannot break the search
Words typed into a search SHALL be matched literally: operators such as `-`, `OR`, `NOT` and quotation marks carry no special meaning, and no query can cause a syntax error. A query that matches nothing, or consists only of quotes or whitespace, SHALL return no hits.

#### Scenario: Hostile characters are harmless
- **WHEN** the query is `"` or `tmux-agent-state.sh OR`
- **THEN** the search returns no hits and does not fail

#### Scenario: Identifier with punctuation
- **WHEN** the query is `tmux-agent-state.sh`
- **THEN** it is treated as one phrase of words, not as an exclusion

### Requirement: Ranking, score and snippet
Hits SHALL be ordered best first, with a match in a section's heading weighing ten times a match in its body. The score SHALL be a number rounded to three decimals where a bigger value is a better match, and equal scores SHALL be ordered by document id, then section order. The snippet SHALL be one line of about 14 tokens with the matched words wrapped in `[` and `]`. The default limit is 10 hits.

#### Scenario: Heading beats mention
- **WHEN** searching `rollback` in a corpus where one section is titled `Rollback` and another mentions it once
- **THEN** the titled section is first, the mention is still returned later, and the first score is greater than the second

#### Scenario: Snippet shape
- **WHEN** a hit is returned
- **THEN** its snippet contains no newline and marks the matched word as `[word]`

### Requirement: Filters and limit
Search and list SHALL accept an exact `kind` filter and a `tag` filter that keeps documents carrying that tag; given together they combine. Search SHALL accept a limit of hits.

#### Scenario: Kind and tag narrow results
- **WHEN** `search релиз* --kind note` runs, and `search rollback --tag tmux --limit 1` runs
- **THEN** the first returns only hits from documents of kind `note`, the second returns exactly one hit, from a document tagged `tmux`

#### Scenario: Unknown tag
- **WHEN** the tag matches no document
- **THEN** the result is empty

### Requirement: Listing documents
A list SHALL return every indexed document in id order with `id`, `title`, `kind`, `tags`, `updated`, absolute `path` and `headings` (the section headings in document order, without the preamble), optionally filtered by `kind` and `tag`.

#### Scenario: Headings
- **WHEN** a document has a preamble and sections `Диски` and `Сервисы`
- **THEN** its `headings` are `["Диски", "Сервисы"]`

### Requirement: Reading a document or section
Reading by address SHALL accept `id` for the whole document (the file as it is on disk, frontmatter included) or `id#heading` for one section. Heading matching SHALL be case-insensitive and work for non-ASCII letters (`диски` finds `Диски`). An empty heading (`id#`) addresses the preamble.

#### Scenario: One section only
- **WHEN** `show mashina-karta#Диски` runs
- **THEN** the output starts with `## Диски`, a blank line, and the section body, and does not contain other sections

#### Scenario: Preamble
- **WHEN** `show mashina-karta#` runs
- **THEN** the output is the preamble text without a heading line

### Requirement: CLI verbs and flags
The `tagents-knowledge` program SHALL provide the verbs `index [--dir D] [--db F] [--full]`, `search <query…> [--dir] [--db] [--tag T] [--kind K] [--limit N] [--json]`, `show <id[#heading]> [--dir] [--db]`, `list [--dir] [--db] [--kind K] [--tag T] [--json]`, `lint [--dir D]`, `mcp` and `serve [--idle S] [--foreground] [--socket P]`. `help`, `--help` and `-h` SHALL print the usage text on stdout. An invalid `--limit` (not a positive number) SHALL be ignored in favour of the default.

#### Scenario: Verbs match the generated contract
- **WHEN** the CLI contract is generated
- **THEN** it lists exactly `index`, `search`, `show`, `list`, `lint`, `mcp`, `serve`, in English, with exit codes 0, 1, 2 and 4

### Requirement: CLI exit codes
The CLI SHALL exit with 0 for success, 1 for an error (no or missing documents folder, a folder that could not be indexed clean, lint findings), 2 for a usage error, and 4 when nothing was found.

#### Scenario: Usage errors
- **WHEN** `search` or `show` runs without an argument, or a verb receives an unknown flag, or the verb is unknown, or no verb is given
- **THEN** the exit code is 2; for an unknown verb the usage text goes to stderr, with no verb it goes to stdout

#### Scenario: Nothing found
- **WHEN** a search has no hits, or `show` names an unknown id or heading, or `list` finds no documents
- **THEN** the exit code is 4 and a sentence on stderr says what was missing

### Requirement: Search output
Without `--json`, `search` SHALL print one line per hit: the address (`id#heading`, or just `id` for the preamble) padded to 38 characters, the score with two decimals, then the snippet. With `--json` it SHALL print a JSON array of objects with exactly the keys `id`, `title`, `heading`, `score`, `snippet`, `path`; with no hits it prints `[]` and still exits 4.

#### Scenario: First line
- **WHEN** `search rollback` runs on the fixture corpus
- **THEN** the first line matches `deploy-runbook#Rollback`, a decimal score and a snippet

### Requirement: List output
Without `--json`, `list` SHALL print one line per document: id padded to 28, kind padded to 10, `updated`, title, then ` #tag` for each tag. With `--json` it SHALL print the JSON array of document summaries; an empty result prints `[]` and exits 4.

#### Scenario: Text line
- **WHEN** `list --kind runbook` runs
- **THEN** the single line reads like `deploy-runbook  runbook  2026-09-10  Deploying the demo service  #deploy #ci`

### Requirement: Human text is localised, machine output is not
Human-facing CLI text (usage, messages, lint findings) SHALL follow `TAGENTS_LOCALE` (`en` or `ru`), with any other value meaning English. `--json` output, lint finding codes, the generated CLI contract and the text returned by MCP tools SHALL stay in English whatever the locale.

#### Scenario: Russian messages
- **WHEN** `TAGENTS_LOCALE=ru` and a search finds nothing
- **THEN** stderr says `ничего не найдено…`, and the exit code is 4

#### Scenario: Unknown locale
- **WHEN** `TAGENTS_LOCALE=xx` and `help` runs
- **THEN** the English usage is printed

### Requirement: Quiet stderr
The CLI SHALL NOT print Node's experimental-SQLite warning on any verb; every other warning is unaffected.

#### Scenario: No experimental notice
- **WHEN** `lint`, `help`, `list` or `search` runs
- **THEN** stderr does not contain `ExperimentalWarning`

### Requirement: Lint
`lint` SHALL check the claims each document makes about itself, without using the index, and report each finding as `<filename>: <message>` on stdout. The finding kinds are `frontmatter`, `stem`, `duplicate-id`, `stale`, `generated` and `dead-link`. A file with invalid frontmatter SHALL be one finding, not the end of the report. With no findings `lint` SHALL print `N document(s) in DIR: no problems` and exit 0; otherwise it prints `N problem(s) in DIR` after the findings and exits 1.



#### Scenario: Clean corpus
- **WHEN** `lint --dir` points at a folder of five valid documents with no links broken
- **THEN** the output says `5 document(s)… no problems` and the exit code is 0

#### Scenario: Broken file is one finding
- **WHEN** a file has no frontmatter at all
- **THEN** it yields one `frontmatter` finding, it still counts in the number of documents checked, and the other files are still checked

### Requirement: Lint freshness checks
A `stale` finding SHALL mean that `updated` is older than the date of the newest git commit touching the file, and is checked only inside a git work tree and only for committed files.

#### Scenario: Stale update date
- **WHEN** a committed document says `updated: 2020-01-01` and its newest commit is later
- **THEN** exactly that document gets a `stale` finding

#### Scenario: Outside git
- **WHEN** the folder is not a git work tree
- **THEN** no `stale` findings are produced

### Requirement: Lint generated documents
A `generated` finding SHALL mean that the file named by `generated_from` (resolved against the folder, `~` expanded) was modified on a UTC date later than `updated`. It SHALL be skipped when that source does not exist on this machine.

#### Scenario: Generated source moved on
- **WHEN** `generated_from` names a file modified on 2026-09-20 and the document says `updated: 2026-09-11`
- **THEN** a `generated` finding mentioning 2026-09-20 is reported, and it disappears once `updated` is 2026-09-20 or later

#### Scenario: Missing source is not a finding
- **WHEN** the file named by `generated_from` does not exist
- **THEN** no `generated` finding is reported

### Requirement: Lint dead links
A `dead-link` finding SHALL mean that a wikilink targets a missing document, or a heading the target does not have (compared case-insensitively).

#### Scenario: Dead links
- **WHEN** a document links `[[sqlite-over-vectors]]` after that file was deleted, or `[[deploy-runbook#Нет раздела]]` for a missing heading
- **THEN** each is reported as `dead link [[…]]`

### Requirement: MCP server
`tagents-knowledge mcp` SHALL serve the MCP protocol over stdio only, as server `tagents-knowledge`, and exit when the client closes the pipe. It SHALL expose exactly five tools: `knowledge_search`, `knowledge_get`, `knowledge_list`, `sessions_recent`, `sessions_search`. It SHALL offer no tool that writes, edits or deletes a document. Tool output is English text, and the server SHALL write nothing to stdout besides the protocol.

#### Scenario: Tool inventory
- **WHEN** a client lists the tools
- **THEN** it sees exactly those five names

### Requirement: MCP document source
The MCP knowledge tools SHALL locate the folder and the index from the environment alone (`TAGENTS_KNOWLEDGE_DIR` or config `knowledge.dir`, and `TAGENTS_KNOWLEDGE_DB`), SHALL refresh the index on each call, and SHALL return a tool error (`isError: true`) with a message naming `TAGENTS_KNOWLEDGE_DIR` and the config file when no folder is configured, or saying the directory does not exist when it is configured but absent.

#### Scenario: Unconfigured server
- **WHEN** a client calls `knowledge_list` with no folder configured
- **THEN** the result is an error whose text mentions `TAGENTS_KNOWLEDGE_DIR`

### Requirement: The serve verb
`tagents-knowledge serve` SHALL print on stdout the unix socket of the shared server for the caller's environment and exit 0, starting that server first, detached, when nothing answers on the socket. `--idle S` SHALL be a positive number of seconds, default 600; any other value SHALL exit 2 with a message naming `--idle`. A server that cannot be started SHALL exit 1 with a message on stderr.

#### Scenario: The same socket twice
- **WHEN** `serve` runs twice while the server lives
- **THEN** both print the same socket and one server process exists

#### Scenario: A bad idle time
- **WHEN** `serve --idle` is given `0`, `-3` or `soon`
- **THEN** it exits 2 and stderr names `--idle`

### Requirement: The server run in the foreground
`serve --foreground` SHALL be the shared server itself, run in the calling process: it listens on `--socket P` (default the socket of the caller's environment), serves until it has been idle for `--idle` seconds or receives SIGTERM or SIGINT, and exits 0. When another server already answers on that socket it SHALL exit 0 at once. The directory of P SHALL be owned by the caller and is tightened to mode 0700; when it is not, `serve --foreground` exits 1 with a message on stderr.

#### Scenario: Another server holds the socket
- **WHEN** `serve --foreground` is started on a socket that a live server holds
- **THEN** it exits 0 without disturbing that server

### Requirement: One shared server per environment
Every client of the same environment SHALL be served by one daemon, and clients whose environments differ SHALL get separate daemons that answer from their own documents. The environment is `HOME`, `TAGENTS_CONFIG_DIR`, `XDG_CONFIG_HOME`, `TAGENTS_KNOWLEDGE_DIR`, `TAGENTS_KNOWLEDGE_DB` and `CLAUDE_HOMES`, plus the build of the program that runs.

#### Scenario: Two sessions, one daemon
- **WHEN** two sessions start at the same moment in the same environment
- **THEN** one daemon serves both, and it outlives them

#### Scenario: Different documents
- **WHEN** one session sets `TAGENTS_KNOWLEDGE_DIR` to folder A and another to folder B
- **THEN** each daemon lists only its own folder's documents

### Requirement: What makes a different environment
Relative values of `TAGENTS_CONFIG_DIR`, `XDG_CONFIG_HOME`, `TAGENTS_KNOWLEDGE_DIR`, `TAGENTS_KNOWLEDGE_DB` and the entries of `CLAUDE_HOMES` SHALL count as absolute from the caller's directory, `HOME` and values beginning with `~` count as written, and unset counts as empty. Other variables SHALL NOT split daemons, except that a different `TMPDIR` names a different socket directory and so gets a daemon of its own.

#### Scenario: A variable the server does not read
- **WHEN** a session differs only in `CLAUDE_CONFIG_DIR`
- **THEN** it joins the daemon the others use

#### Scenario: A different TMPDIR
- **WHEN** one session sets `TMPDIR` to another directory
- **THEN** it gets a daemon of its own

### Requirement: Where the shared server lives
The daemon SHALL listen on `knowledge-<12 hex digits>.sock` in the directory `tagents-<uid>` under `TMPDIR` (the system temporary directory when blank), or under `/tmp` when the socket name would not fit an address. The directory SHALL be mode 0700 and owned by the user: a looser one is tightened and one owned by another user or not a directory is refused. The daemon SHALL write `<socket>.pid` once it listens and remove the socket and that file when it leaves.

#### Scenario: A private directory
- **WHEN** `serve` has started a daemon
- **THEN** the printed socket is in the `tagents-<uid>` directory, whose mode is 0700, and `<socket>.pid` holds the daemon's pid

#### Scenario: A clean exit
- **WHEN** the daemon is sent SIGTERM
- **THEN** it leaves and the socket and the pid file are gone, and the next `serve` starts a new daemon

### Requirement: Starting the daemon is safe under races
The daemon SHALL run detached, in a process group of its own and in the directory `/`, with no output of its own, so that it outlives the session that started it. Starters that meet in the same moment SHALL end up with one daemon. A socket file left by a daemon that was killed SHALL be replaced under the lock `<socket>.lock`, so that bridges meeting it together start exactly one new daemon on the same name.

#### Scenario: Four bridges meet a dead socket
- **WHEN** the daemon is killed with SIGKILL and four sessions start together
- **THEN** one new daemon listens on the same socket name and serves all four

### Requirement: The daemon leaves when it is idle
The daemon SHALL exit after `--idle` seconds (default 600) with no client connected, counted from the last disconnect or, if none ever connected, from its start, and SHALL NOT exit while a client stays connected. A client that closes only its writing side SHALL be released at once, so that it does not keep the daemon alive.

#### Scenario: A client holds it open
- **WHEN** the idle time is 1 second and a client stays connected for 2 seconds
- **THEN** the daemon is still running, and leaves after the client goes

#### Scenario: Nobody ever connects
- **WHEN** a daemon is started and no client connects
- **THEN** it exits after the idle time

### Requirement: One bad client does not stop the others
A client that sends rubbish (text that is not JSON, JSON that is not a request, bytes that are not text, an unknown method, a cut-off line) or whose connection fails while it is set up SHALL cost only its own connection. An exception or rejection nobody caught SHALL be reported on stderr as a line starting `tagents-knowledge:` that names what failed, followed by the error's stack, and the daemon SHALL go on serving. A signal SHALL stop it.

#### Scenario: Garbage, then a real client
- **WHEN** a client sends rubbish and disconnects, and a session then connects
- **THEN** the daemon pid is unchanged and the session lists the five tools

### Requirement: The shared server speaks the same protocol
Each connection to the daemon SHALL get its own MCP server over newline-delimited JSON-RPC, exposing the same five tools with the same behaviour as `tagents-knowledge mcp`.

#### Scenario: Through the bridge
- **WHEN** a session reaches the daemon through the plugin's server entry
- **THEN** it lists exactly the five tools of the MCP server requirement, and closing its stdin ends its connection

### Requirement: Tool knowledge_search
`knowledge_search` SHALL take `query` (required, non-empty string), `tag` and `kind` (optional strings) and `limit` (optional integer from 1 to 50, default 10), with the same matching and ranking as the CLI. It SHALL return the hits as pretty-printed JSON text, an array of objects with `id`, `title`, `heading`, `score`, `snippet`, `path`; when nothing matches it returns the plain text `nothing matches "<query>"`, which is not an error.

#### Scenario: Ranked hits
- **WHEN** a client searches `rollback`
- **THEN** the first hit has id `deploy-runbook`, heading `Rollback` and a numeric score

#### Scenario: Schema
- **WHEN** the tool list is read
- **THEN** the input properties are `kind`, `limit`, `query`, `tag` and only `query` is required

### Requirement: Tool knowledge_get
`knowledge_get` SHALL take `id` (required, non-empty) and `heading` (optional). Without `heading` it SHALL return the document's file text including its frontmatter. With `heading` it SHALL return `## <heading>`, a blank line, the section body and a newline. An unknown id SHALL be a tool error saying there is no document with that id; an unknown heading SHALL be a tool error that names the document's available headings.

#### Scenario: Whole document
- **WHEN** `knowledge_get` is called with id `mashina-karta`
- **THEN** the text begins with `---\nid: mashina-karta` and contains the document's sections

#### Scenario: One section
- **WHEN** it is called with a heading `Диски`
- **THEN** the text begins with `## Диски` and holds no other section

#### Scenario: Unknown id
- **WHEN** the id does not exist
- **THEN** the result is a tool error, not an empty answer

### Requirement: Tool knowledge_list
`knowledge_list` SHALL take optional `kind` and `tag` strings and return the matching documents as pretty-printed JSON, an array of objects with `id`, `title`, `kind`, `tags`, `updated`, `path`, `headings`; an empty match is the JSON `[]`, not an error.

#### Scenario: Filter by kind
- **WHEN** called with `kind: runbook`
- **THEN** the array holds only the runbook documents

### Requirement: Session tools
`sessions_recent` SHALL take an optional integer `limit` from 1 to 50 (default 15) and return the latest Claude sessions across every Claude account on the machine, newest first. `sessions_search` SHALL take a required non-empty string `words`, split on whitespace, and return the sessions whose project path or opening prompt contains every word. Both return the same text the sessions CLI prints, as the `session-history` capability defines it.

#### Scenario: No Claude homes
- **WHEN** the machine has no Claude account directories
- **THEN** the tools still answer with text rather than failing

#### Scenario: Recent sessions
- **WHEN** `sessions_recent` is called with `limit: 3`
- **THEN** the text is the sessions listing and ends with the hint about `sessions.mjs show <id-prefix>`

#### Scenario: No matching session
- **WHEN** `sessions_search` is called with words that match nothing
- **THEN** the text says that nothing matches
