# rust-knowledge Specification

## Purpose
The knowledge MCP server, its shared daemon and the relay a session runs in front of it are verbs of the `tagents-core` binary, and a session starts them through the installer's wrapper and the launcher, with the node server kept as the way out when the binary is missing, of another version or failing, or switched off with `TAGENTS_NO_NATIVE=1`.

## Requirements

### Requirement: Each tool answers as the node server does
For the same documents, index and usage store, every result of the six tools SHALL be the bytes the node server answers: ranking, scores, snippets, the lines for a missing document or section, and the `isError` results for an unknown tool or invalid arguments, with the node server's wording. `tools/list` SHALL be the node server's list, in its order.

#### Scenario: Equal ranks
- **WHEN** two sections rank equally for a query and one document is deprecated
- **THEN** both programs return the same order, the deprecated one last

#### Scenario: Diacritics
- **WHEN** a query is written with other diacritics than the document, in Latin or in Cyrillic
- **THEN** both programs return the same sections with the same snippets

#### Scenario: Invalid arguments
- **WHEN** `knowledge_search` is called with an empty query, a limit of 51, a limit of 1.5 or a null query
- **THEN** each program answers the same `isError` result naming the same issue

#### Scenario: An unknown tool
- **WHEN** `tools/call` names a tool that does not exist
- **THEN** the result is `isError` with the node server's line

### Requirement: The handshake names the server
`initialize` SHALL be answered as the node server answers it: the server name `tagents-knowledge`, the capability `tools` with `listChanged`, and the protocol version the node server would negotiate for the same client. The server version SHALL be the version of the binary.

#### Scenario: A client of an older protocol
- **WHEN** a client asks for a protocol version both programs support, and then for one neither supports
- **THEN** each program answers the version the node server answers, and only the server version differs

### Requirement: One index file for both programs
The server SHALL read and write the index file of the `knowledge` capability in place: the same tables, tokenizer, match expression, ranking, snippet and rules for what to read again, so that either program answers identically from an index the other built or changed. Opening an index SHALL NOT change its journal mode, SHALL NOT rebuild an index of the current schema, and SHALL wait for a lock the other program holds as long as the `knowledge` capability says.

#### Scenario: Built by one, read by the other
- **WHEN** the node program builds the index and the Rust program searches, and then the reverse
- **THEN** the answers are the same and neither rebuilds the index

#### Scenario: The other program is writing
- **WHEN** the node program holds a write transaction on the index for 400 ms and the Rust program opens the index in that time
- **THEN** it waits for the commit and answers, and the reverse holds too

#### Scenario: Changed text, same text
- **WHEN** a document is edited, and another is touched without a change to its text
- **THEN** the edited one is reindexed and the touched one is not, whichever program runs next

#### Scenario: A document that stops parsing
- **WHEN** a document's front matter is broken
- **THEN** it leaves the index in both programs and returns when it is repaired

### Requirement: One usage store for both programs
Reads the server records SHALL go to the usage store of the `knowledge` capability in its format, and the server's report SHALL count the events either program recorded. The caller of an event SHALL be the name the client gave in the handshake. A failure to record SHALL NOT change an answer.

#### Scenario: Recorded by one, counted by the other
- **WHEN** a client named `a` reads a document through each program
- **THEN** the report of each program counts both reads, with the caller `a`

#### Scenario: A store that cannot be written
- **WHEN** the usage store is read-only and a document is read
- **THEN** the answer is the document's text, and nothing is reported

### Requirement: A document is read to the same values
A document SHALL be parsed to the same fields, sections, legacy mapping and dates by either program, and a document one program refuses the other SHALL refuse. The only exceptions SHALL be those the documentation lists as known differences.

#### Scenario: Tags and numbers in front matter
- **WHEN** a front matter holds an explicit core tag, a custom tag, a number above 2^53 or no keys at all
- **THEN** both programs read the same values, and an empty block is read as no fields

#### Scenario: A bad date
- **WHEN** `stale_after` is not an offset datetime or names a day that does not exist
- **THEN** both programs treat the field as the `knowledge` capability says

### Requirement: The shared server has a socket of its own
The shared server of the binary SHALL listen on a socket named and placed as the `knowledge` capability says, with a key that is never a key of the node program, so that a node daemon and a native daemon of one environment are two servers on two sockets and neither serves the other's. A replaced binary SHALL get a new key.

#### Scenario: Both programs, one environment
- **WHEN** `tagents-knowledge serve` runs once through each program in one environment
- **THEN** two different sockets are printed and two daemons run, each serving its own clients

#### Scenario: A replaced binary
- **WHEN** the binary is replaced by a build of another modification time and `serve` runs
- **THEN** it prints another socket

### Requirement: The native daemon meets the daemon requirements
The native `serve`, `serve --foreground` and the daemon SHALL meet the requirements of the `knowledge` capability for the node daemon: one daemon under concurrent starts, a dead socket replaced under the lock, a client that closes its writing side released at once, exit after `--idle`, and the socket and pid file removed on exit. The daemon SHALL run detached in a process group of its own.

#### Scenario: Four proxies meet a dead socket
- **WHEN** the native daemon is killed with SIGKILL and four `join` processes start together
- **THEN** one new daemon listens on the same socket and serves all four

#### Scenario: Detached
- **WHEN** a session's `join` and its process group are killed after it started the daemon
- **THEN** the daemon is still running and its group differs from the proxy's

### Requirement: join connects a session to the shared server
`knowledge join` SHALL connect its standard input and output to the shared server of the caller's environment, starting it when none answers, and SHALL exit 0 when its input ends. When the connection ends before the first reply, it SHALL connect once more and send again what it had sent. When it ends later, `join` SHALL exit 1 with a line on stderr. When no server can be started it SHALL serve in its own process.

#### Scenario: Input ends
- **WHEN** the session closes the input of `join`
- **THEN** `join` exits 0 and the daemon does not count the connection

#### Scenario: The daemon leaves as the session arrives
- **WHEN** the daemon's idle time ends between the connect and the first reply
- **THEN** `join` connects to a new daemon and the session gets its answers

#### Scenario: The daemon dies mid-session
- **WHEN** the daemon is killed after its first reply
- **THEN** `join` exits 1 and says on stderr that the shared server went away

#### Scenario: No daemon can start
- **WHEN** the socket directory cannot be created
- **THEN** `join` serves the session in its own process

### Requirement: The binary carries its own SQLite
The binary SHALL contain a SQLite with full-text search and the tokenizer of the index, so that no system SQLite is needed on any release target, and its tokenization of every character SHALL be the node program's, or the difference SHALL be listed as a known difference.

#### Scenario: No system SQLite
- **WHEN** the binary runs on a machine with no SQLite library
- **THEN** it indexes and searches

#### Scenario: Tokenizer sweep
- **WHEN** both programs tokenize every code point of the Basic Multilingual Plane, of U+10000 to U+3FFFF and of U+E0000 to U+E01FF with the index's tokenizer
- **THEN** the terms are equal, or each difference is listed

### Requirement: Equality is kept by generated files and a suite
The tool list and the texts the binary prints (`tools.json` and `texts.json` of `crates/okb/src/knowledge`) SHALL be frozen files. A differential suite SHALL run the same scenarios against the node server of the oracle tag `v0.6.7` (`tests/parity-oracle.sh`) and `okb` on copies of one corpus, with the verbs of the command line and the servers, comparing bytes, with each program reading the index and usage store the other wrote. CI SHALL fail when the suite fails.

#### Scenario: The binary drifts from the oracle
- **WHEN** a tool description or a text of the binary changes and the oracle still answers the old one
- **THEN** the suite fails, unless the scenario names the difference as `OWN_ERR`

#### Scenario: The wrong process
- **WHEN** the process the suite starts as the Rust side is the node CLI
- **THEN** the suite fails at its first check

#### Scenario: The node list moves
- **WHEN** a tool description changes in the node server of the oracle
- **THEN** the oracle is a tag and does not move; the frozen list is changed by hand with the suite beside it

### Requirement: Differences are listed
Every way the binary's server differs from the node server SHALL be listed in `docs/architecture/rust-core.md` with its reason, and the suite SHALL drop or relax only what the list names.

#### Scenario: A new difference
- **WHEN** the suite shows a difference that is not on the list
- **THEN** it fails until the list names it or the code is fixed

### Requirement: okb serves every verb of the knowledge base
`okb` SHALL serve `index`, `search`, `show`, `list`, `lint`, `toc`, `usage`, `mcp`, `serve` and `join` from its own crate, and no verb SHALL start a node program. The first seven SHALL print the same bytes on standard output and standard error and exit with the same code as the node program of the oracle tag, for the same arguments, environment and files, errors included. `mcp`, `serve` and `join` SHALL do what `tagents-core knowledge` did with them.

#### Scenario: A read verb
- **WHEN** `okb search`, `show`, `list`, `lint`, `toc` or `usage` runs on a copy of the corpus the suite holds, with a flag, with `--json` and with a bad flag
- **THEN** standard output, standard error and the exit code equal those of the node program of the oracle (`tests/rust-knowledge-parity.sh`)

#### Scenario: A write verb
- **WHEN** `okb index` and `okb index --full` run, and `okb toc` writes `index.md`
- **THEN** the files they write and the lines they print are the oracle's, and the index file is read by both programs (`tests/rust-knowledge-parity.sh`)

#### Scenario: The usage text
- **WHEN** `okb`, `okb help`, `okb --help`, `okb -h` and `okb bogus` run
- **THEN** the text, the stream it goes to and the exit code are the oracle's, byte for byte, so the program name in the text is still `tagents-knowledge` until pull request B renames it (`tests/rust-knowledge-parity.sh`)

#### Scenario: Arguments of mcp and serve
- **WHEN** `okb mcp extra words` runs, and `okb serve` gets `--idle 0`, an unknown option or a positional word
- **THEN** `mcp` ignores the words and runs; `serve` exits 2, and for `--idle` its message names `--idle` (`cargo test -p okb`)

#### Scenario: tagents-core holds no knowledge code
- **WHEN** the workspace is built without the `okb` crate
- **THEN** `tagents-core` builds and passes its tests (`cargo test --workspace --locked`)
