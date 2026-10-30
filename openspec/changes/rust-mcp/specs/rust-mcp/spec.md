## ADDED Requirements

### Requirement: The server is the verb mcp of tagents-core
`tagents-core mcp --contract <file>` (also `--contract=<file>`) SHALL serve the plugin's tools over stdio from the `cli` section of that contract file, until the client leaves. It SHALL be a verb of the data file with `effect: serve`, so it is not itself a tool.

#### Scenario: The usage line
- **WHEN** `tagents-core mcp` runs without `--contract`, or with an argument it does not know
- **THEN** it prints `usage: tagents-core mcp --contract <contract.json>` on stderr and exits 2

#### Scenario: A server that cannot start
- **WHEN** the contract file is missing, is not JSON, or derives two tools with one name
- **THEN** it prints `tagents-core mcp: <reason>` on stderr, exits 1 and writes nothing to stdout

#### Scenario: Both spellings
- **WHEN** the file is given as `--contract file` and as `--contract=file`
- **THEN** both serve the same tools

### Requirement: The dialogue is the node server's
The server SHALL read newline-delimited JSON-RPC from stdin and write one message per line to stdout. `initialize` SHALL answer the requested `protocolVersion` when the SDK of `packages/mcp` lists it and the latest otherwise, with `capabilities: {"tools": {}}` and `serverInfo` named `tagents`; `ping` SHALL answer `{}`; `tools/list` SHALL answer every tool sorted by name, without a cursor.

#### Scenario: A listed protocol version
- **WHEN** a client initializes with each version the SDK lists
- **THEN** each answer carries the version it asked for

#### Scenario: An unlisted protocol version
- **WHEN** a client initializes with a version the SDK does not list
- **THEN** the answer carries the latest version

#### Scenario: Keys come in the SDK's order
- **WHEN** the server answers a success, an error, a tool result or a tool
- **THEN** the keys are in the order of the node server's answers, so the two compare byte for byte

### Requirement: Unknown requests are answered, noise is ignored
An unknown method SHALL be answered with the error `-32601`, an unknown tool with `-32602` and the text `MCP error -32602: unknown tool <name>`, and params that fail validation with `-32602`. A line that is not a JSON-RPC message and a notification the server does not know SHALL be ignored.

#### Scenario: An unknown method
- **WHEN** the client sends the request `nothing/here`
- **THEN** the answer is the error `-32601`

#### Scenario: An unknown tool
- **WHEN** the client calls a tool that is not in the list
- **THEN** the answer is the error `-32602` naming the tool

#### Scenario: Params that fail validation
- **WHEN** the client sends `initialize` or `tools/call` with params of the wrong shape (missing, a version that is not a string, a tool name that is missing, arguments that are not an object) or `tools/list` with a cursor that is not a string
- **THEN** each is answered with the error `-32602` and a message that starts `Invalid params: `, and none is ignored

#### Scenario: Noise
- **WHEN** the client sends a line that is not JSON and then a notification of an unknown name
- **THEN** nothing is answered, nothing is written to stderr, and the next request is answered

### Requirement: Stdout carries protocol lines only
Nothing but one complete JSON-RPC message per line SHALL be written to stdout, whatever a program the server starts prints, and nothing SHALL be written to stderr after a successful start.

#### Scenario: A program that prints a lot
- **WHEN** a call runs a program that writes to both of its streams
- **THEN** that output is inside the tool result and the server's stdout holds only the answers

### Requirement: The tools follow the rules of the node server
The server SHALL derive its tools, check a call and tell its result by the rules of the `claude-code-plugin` requirements "A tool is named after its verb", "A tool's arguments are the verb's own", "Arguments are checked before anything runs", "A call answers with how the verb ended", "A call's output is capped in bytes", "A call is bounded in time" and "A verb that needs tmux is refused without it".

#### Scenario: One list for both servers
- **WHEN** the node server and `tagents-core mcp` read one contract
- **THEN** their `tools/list` answers are the same bytes

#### Scenario: One result for both servers
- **WHEN** both run the same call against the same stub program
- **THEN** their answers are the same bytes, for every exit code of the verb, for JSON and for text output, and for an output cut at 256 KiB

### Requirement: Nothing a call starts outlives the call
A call SHALL run its program in a process group of its own, and when the program exits, the call times out after five minutes, the client cancels it or the server ends, the whole group SHALL be stopped. A helper that left the group and holds the pipes after its program exited SHALL hold the call no longer than a short drain. A helper that calls `setsid` leaves the group and is not stopped: it outlives the call, with both servers.

#### Scenario: A program that starts a helper
- **WHEN** a program starts a background process in its group and exits
- **THEN** the helper is gone when the answer is written

#### Scenario: A helper that holds the pipes
- **WHEN** a helper outside the group keeps the pipes open after the program exited
- **THEN** the call is answered within the drain and not when the helper lets go

#### Scenario: A helper that leaves the group
- **WHEN** a helper calls `setsid` and so leaves the process group of its program
- **THEN** it outlives the call, with both servers, because only the group is stopped

#### Scenario: A timeout
- **WHEN** a program outlives the call's time limit
- **THEN** its group gets SIGTERM, then SIGKILL after the grace, and the outcome is `timeout` even if the program exited 0

### Requirement: A cancelled request gets no answer
`notifications/cancelled` naming the id of a request in flight SHALL stop that call and the request SHALL get no response, even when the call had finished by then.

#### Scenario: Cancelling a slow call
- **WHEN** the client cancels a call that is running
- **THEN** neither a result nor an error is written for its id, and the program and its group are gone

#### Scenario: Two calls in flight
- **WHEN** a slow call and a fast call are in flight together
- **THEN** the fast one is answered while the slow one still runs

### Requirement: The server ends when its client does
The server SHALL end when stdin ends and on SIGTERM, SIGINT and SIGHUP: it stops every call in flight, answers each with the outcome `cancelled`, and exits 0 within the grace plus a short margin. A write error on stdout SHALL start the same ending, and ending twice SHALL be one ending.

#### Scenario: Stdin closes with a call in flight
- **WHEN** the client closes stdin while a call runs
- **THEN** the call's group is stopped, its answer carries the outcome `cancelled`, and the server exits 0

#### Scenario: A signal
- **WHEN** the server receives SIGTERM while a call runs
- **THEN** it ends in the same way

#### Scenario: A write error on stdout
- **WHEN** an answer cannot be written to stdout
- **THEN** the server starts the ending and leaves, and does not go on serving

#### Scenario: A second signal
- **WHEN** a second signal arrives while the ending is still waiting for a program that ignores SIGTERM
- **THEN** the server ends at once by the default action of that signal

### Requirement: The node server is the reference
`tests/rust-mcp-parity.sh` SHALL feed one script of requests to `packages/mcp` and to `tagents-core mcp` with stub programs on `PATH` and SHALL compare the two answers byte for byte, leaving out only `serverInfo.version`, and the workflow `rust.yml` SHALL run it on every change to either server.

#### Scenario: The servers differ
- **WHEN** one server answers a request differently from the other
- **THEN** the suite fails and prints both lines

#### Scenario: The suite runs in CI
- **WHEN** a pull request changes `packages/mcp/**` or `crates/**`
- **THEN** the `rust` job runs the suite
