# headless-sessions Specification

## Purpose
Opening, prompting, reading, listing and aborting headless Claude Code sessions (`claude -p`) from scripts and agents through the `tagents-core session` verbs and the driver behind them, with a typed outcome for every turn.

## Requirements

### Requirement: JSON verbs print exactly one document
The verbs `session open`, `session last`, `session list`, `session abort` and `session prompt` (without `--events`) SHALL print exactly one pretty-printed JSON document (two-space indent, trailing newline) on stdout and nothing else: no banner, no progress, no second document. The JSON is never translated, whatever `TAGENTS_LOCALE` says.

#### Scenario: One document on stdout
- **WHEN** `tagents-core session open --cwd <dir>` succeeds
- **THEN** stdout parses as a single JSON document and stderr is empty

#### Scenario: Locale does not touch the JSON
- **WHEN** `session list` runs with `TAGENTS_LOCALE=ru` and again without it
- **THEN** both print byte-identical stdout

### Requirement: Exit codes
The `tagents-core` program SHALL exit with 0 for ok, 1 for an error, 2 for a usage error, 3 for a refusal (nothing was done on purpose) and 4 for a timeout. An unknown flag, a missing required option or a missing positional is a usage error (2); any other thrown error prints its message on stderr and exits 1.

#### Scenario: Unknown flag
- **WHEN** `session open --cwd <dir> --invented` runs
- **THEN** the exit code is 2 and stdout is empty

#### Scenario: Unknown session verb
- **WHEN** `tagents-core session bogus` runs
- **THEN** stderr carries `unknown command: session bogus` and the usage text, and the exit code is 2

### Requirement: Opening a session starts nothing
`session open --cwd <dir>` SHALL print a session reference as JSON without starting any process: a session is a transcript plus Claude's session id, and only a prompt ever runs. The reference holds a fresh unique `id`, `claudeSessionId` (null until a turn has run, or the id given to `--resume`), `transcript` (null unless known) and a `spec`.

#### Scenario: Plain open
- **WHEN** `session open --cwd <dir> --label smoke --model fable` runs
- **THEN** stdout is a reference with `claudeSessionId` null and `spec.label` equal to `smoke`
- **AND** the exit code is 0

#### Scenario: Missing working directory
- **WHEN** `session open` runs without `--cwd`
- **THEN** the exit code is 2 and stdout is empty

### Requirement: What the spec of a reference records
The `spec` of the reference printed by `session open` SHALL hold `kind: "claude"`, `cwd` (resolved to an absolute path) and `skipPermissions` (false unless `--skip-permissions` is given), plus, only when given, `label`, `model`, `effort`, `systemPromptFile` (from `--system-prompt-file`) and `mcpConfig` (from `--mcp-config`).

#### Scenario: Relative directory
- **WHEN** `session open --cwd .` runs in `~/projects/app`
- **THEN** `spec.cwd` is the absolute path of `~/projects/app`

#### Scenario: Optional fields absent
- **WHEN** no `--model` is given
- **THEN** the spec has no `model` key

### Requirement: Resuming an earlier conversation
`session open --resume <claude-session-id>` SHALL put that id into the reference as `claudeSessionId`, and the later turns on the reference continue that conversation with `--resume`. The reference's `transcript` is the path the agent-state records hold for that id, or null when they hold none.

#### Scenario: Known transcript
- **WHEN** a record holds a transcript path for session `a1b2c3d4-…` and `session open --cwd <dir> --resume a1b2c3d4-…` runs
- **THEN** the reference carries that id and that transcript path

#### Scenario: Unknown transcript
- **WHEN** no record holds that id
- **THEN** `transcript` is null

### Requirement: The account a session runs on
`session open` SHALL let the caller choose the Claude config directory, which is a whole login, in three distinct ways: leaving both flags out inherits the parent's `CLAUDE_CONFIG_DIR` (the reference has no `configDir` key), `--config-dir <dir>` sets it, and `--no-config-dir` unsets it so the turn lands on the default account (`configDir: null`). Both flags together are a usage error.

#### Scenario: Unset is not the same as absent
- **WHEN** `session open --cwd <dir> --no-config-dir` runs, and again without the flag
- **THEN** the first reference has `spec.configDir` equal to null
- **AND** the second has no `configDir` key

#### Scenario: Both flags
- **WHEN** `session open --cwd <dir> --config-dir /x --no-config-dir` runs
- **THEN** the exit code is 2

### Requirement: Session references
Every verb that takes `<ref-json-or-id>` SHALL accept either the JSON that `session open` printed, or a plain string naming a session the agent-state hook knows (see the `agent-state` capability). The JSON is validated: it needs `id`, `claudeSessionId`, `transcript` and a `spec` with at least `kind: "claude"`, `cwd` and `skipPermissions`, and an absent `configDir` key stays distinct from a null one.

#### Scenario: Hand-edited reference
- **WHEN** a reference printed by `session open` is given back with `spec.bin` changed
- **THEN** it is accepted and the changed field is kept

#### Scenario: Not a reference
- **WHEN** the JSON lacks `spec`
- **THEN** it is rejected like an unknown reference

### Requirement: Resolving a plain string to a session
A plain string given as a reference SHALL match the first record whose key or Claude session id equals it, and failing that the first record whose Claude session id starts with the string. A reference that is invalid JSON, fails validation or matches no record SHALL print `no session matches <ref>` on stderr, leave stdout empty and exit 1.

#### Scenario: Exact session id
- **WHEN** `session abort sess-live` runs and a record has the session id `sess-live`
- **THEN** the reference resolves to that record

#### Scenario: Prefix of a session id
- **WHEN** a record has the session id `a1b2c3d4-0000-0000-0000-000000000000` and `session last a1b2c3d4` runs
- **THEN** the reference resolves to that record

#### Scenario: Nobody knows the reference
- **WHEN** `session prompt no-such-session go` runs
- **THEN** stdout is empty, stderr says `no session matches no-such-session` and the exit code is 1

### Requirement: Prompting a session
`session prompt <ref-json-or-id> <text>` SHALL run exactly one turn of the session and print the turn's outcome as one JSON document. A turn is never re-run on its own: one prompt starts the Claude child exactly once. A missing reference or text is a usage error (2), and so is a text that is empty or only whitespace (stderr: `nothing to say: the prompt text is empty`).

#### Scenario: A clean turn
- **WHEN** a turn ends with a result that is not an error and the process exits with code 0
- **THEN** stdout is one document with `kind` equal to `ok`, `toolUses` counting the tool calls and `text` holding the assistant text
- **AND** the exit code is 0 and stderr is empty

#### Scenario: Empty text
- **WHEN** `session prompt <ref> "   "` runs
- **THEN** the exit code is 2

### Requirement: Exit code of a prompt
`session prompt` SHALL exit 0 when the outcome is `ok` or `killed-after-result`, 4 when it is `timeout`, and 1 for `exited` and `spawn-failed`. The exit code is a function of the outcome only, with or without `--events`.

#### Scenario: Timed-out turn
- **WHEN** `session prompt <ref> go --timeout 400` runs against a child that never answers
- **THEN** the exit code is 4 and stdout holds an outcome of kind `timeout`

#### Scenario: Failed turn
- **WHEN** the child exits with code 1 without a result
- **THEN** the exit code is 1

### Requirement: The error line of a failed turn
When the outcome of a `session prompt` is a failure, the program SHALL write one extra line to stderr: `exit=<code, else signal, else null> <detail>` for `exited`, `exit=SIGKILL (timeout <limit>ms, <n> tool call(s)) <detail>` for `timeout` and `exit=null spawn: <detail>` for `spawn-failed`. A successful turn, killed afterwards or not, writes no error line.

#### Scenario: Timeout line
- **WHEN** a turn with a 400 ms limit and no tool calls times out
- **THEN** stderr starts with `exit=SIGKILL (timeout 400ms, 0 tool call(s))`

#### Scenario: Killed after its result
- **WHEN** the outcome is `killed-after-result`
- **THEN** stderr is empty

### Requirement: Streaming events
`session prompt ... --events` SHALL stream one compact JSON object per line (no indentation) on stdout while the turn runs, one per event in the order Claude emitted them, and print the turn's outcome as the last line. An event has a `kind`: `tool_use` (with `name` and `input`), `text` (with `text`), `result` (with `isError` and the result `payload` as Claude printed it) or `other` (with the Claude event's `type`).

#### Scenario: Events then outcome
- **WHEN** a turn makes one tool call, says something and finishes, with `--events`
- **THEN** the lines are events of kind `other`, `tool_use`, `text` and `result`, followed by a last line whose `kind` is `ok`
- **AND** no line contains a line break inside the JSON

### Requirement: Turn outcome kinds
A turn SHALL never throw for failing: it resolves with an outcome of exactly one of five kinds. `ok` is a result that is not an error plus a clean exit; `killed-after-result` is the same work with a process that had to be killed; `timeout` is the time limit reached; `exited` is a child that left without a usable result, or printed a result with `is_error` true; `spawn-failed` is a process that never existed (missing or unexecutable binary).

#### Scenario: Failed resume
- **WHEN** the child exits with code 1 and writes `No conversation found with session ID: abc` on stderr without printing a result
- **THEN** the outcome is `exited` with `code` 1

#### Scenario: Missing binary
- **WHEN** the binary of the session does not exist
- **THEN** the outcome is `spawn-failed` and `detail` mentions ENOENT

### Requirement: Fields of an outcome
`ok` SHALL carry `text`, `sessionId`, `toolUses`, `costUsd`, `numTurns` and `durationMs` (cost and turn count are null when Claude did not report them); `killed-after-result` carries the same plus the exit `code`; `timeout` carries `sessionId`, `toolUses`, `limitMs` and `detail`; `exited` carries `sessionId`, `toolUses`, `code`, `signal` and `detail`; `spawn-failed` carries `detail`. `detail` is whitespace-squeezed to one line and cut at 300 characters.

#### Scenario: Error result
- **WHEN** the child prints a result with `is_error` true and the text `the model refused`
- **THEN** the outcome is `exited` with `detail` equal to `the model refused` and the session id of the turn

#### Scenario: Stderr as detail
- **WHEN** the child fails without a result and wrote to stderr
- **THEN** `detail` is the squeezed stderr text

### Requirement: A turn ends with its result, not with the process
A turn SHALL be over when its `result` event arrives, whatever the process does afterwards. If the child is still alive 60 seconds after printing its result (a stuck MCP server, a grandchild holding the pipe), it is killed with SIGKILL and the outcome is `killed-after-result`, which is a success: it carries the text and has no error line. A turn is `ok` only when the process also exited with code 0.

#### Scenario: Hanging after the result
- **WHEN** the child prints a successful result and then does not exit
- **THEN** after 60 seconds the child is killed
- **AND** the outcome is `killed-after-result` with the work's `text` and a non-zero `code`
- **AND** `session prompt` exits 0

### Requirement: Failed turns carry evidence of what they did
An outcome of kind `timeout` or `exited` SHALL carry `sawText` (at least one assistant text event arrived) and `sawResult` (a result event arrived, error or not) beside `toolUses`, so a caller can judge whether re-running the turn would repeat work. A timeout never has `sawResult` true. A `spawn-failed` outcome has no process and so no evidence.

#### Scenario: Timed out after speaking
- **WHEN** a turn has printed assistant text and then hits its time limit
- **THEN** the outcome is `timeout` with `sawText` true and `sawResult` false

#### Scenario: Crash before anything happened
- **WHEN** the child exits with code 1 and prints nothing but stderr
- **THEN** the outcome is `exited` with `sawText` false, `sawResult` false and `toolUses` 0

### Requirement: Time limit
`session prompt --timeout <ms>` SHALL set the hard limit of the turn in milliseconds, 50 minutes when the flag is absent, not a number or not positive. When the limit is reached the child is killed with SIGKILL and the outcome is `timeout` with `limitMs` equal to the limit. A result that arrives first cancels the limit.

#### Scenario: Bad value
- **WHEN** `--timeout abc` or `--timeout 0` is given
- **THEN** the limit is 50 minutes

#### Scenario: Limit reached
- **WHEN** a child that never prints a result runs past the limit
- **THEN** it is killed and the outcome is `timeout`

### Requirement: The limit counts awake time
The time limit SHALL count time the machine was awake: elapsed time is added up every 10 seconds, and a gap of more than two such intervals (the machine slept) counts as two. Each sleep is noted once in the turn's log as `turn: machine slept ~<n> min, not counted` (in seconds under a minute), and the kill is logged as `claude timed out after <n> min — killing`.

#### Scenario: An hour of sleep
- **WHEN** the machine sleeps for 60 minutes under a turn with the default limit
- **THEN** the turn is not killed at 50 wall-clock minutes
- **AND** it is killed only once 50 awake minutes have passed

#### Scenario: No sleep
- **WHEN** the ticks arrive on time
- **THEN** no `slept` line is logged

### Requirement: Warning before the limit
A caller of the driver library that passes a warning callback SHALL be told when the turn has 5 minutes left (or the `warnBeforeMs` it chose) before the kill, once, never for a turn that finishes first and not at all when the limit is not longer than the warning window. The callback gets the awake time elapsed and `leftMs` equal to the nominal window even when the warning lands late.

#### Scenario: Warning on time
- **WHEN** a library turn has a 700 ms limit and a 300 ms warning window
- **THEN** the callback is called once, at 400 ms of awake time, with `leftMs` 300
- **AND** the kill follows 300 ms later

#### Scenario: Finished turn
- **WHEN** a turn finishes before the warning point
- **THEN** the callback is never called

### Requirement: The command line of the Claude child
For each turn the driver SHALL run `claude -p` with the flags of the session's spec (`--model`, `--effort`, `--disallowedTools` comma-joined, `--strict-mcp-config --mcp-config`, `--dangerously-skip-permissions`, `--append-system-prompt-file`), always `--output-format stream-json --verbose`, `--resume <claude session id>` when the session is known, and the prompt last.

#### Scenario: Minimal turn
- **WHEN** a fresh session with no options is prompted with `hello`
- **THEN** the arguments are `-p --output-format stream-json --verbose hello`

#### Scenario: Fully loaded turn
- **WHEN** a session has a model, an effort, skipped permissions, a system prompt file, an MCP config, disallowed tools and a known Claude session id
- **THEN** the arguments are `-p --model <m> --effort <e> --disallowedTools <list> --strict-mcp-config --mcp-config <f> --output-format stream-json --verbose --dangerously-skip-permissions --append-system-prompt-file <f> --resume <id> <prompt>`

### Requirement: The prompt is never swallowed by an option
The prompt SHALL be the last argument of the child's command line, and no variadic option (`--disallowedTools`, `--mcp-config`) is ever the last option before it. Tools are refused by name with `--disallowedTools`, never with an empty `--tools`, which would drop the MCP tools as well.

#### Scenario: Variadic option present
- **WHEN** a spec has disallowed tools or an MCP config, with or without a resumed session
- **THEN** the prompt is the last argument and each variadic option is followed by one value and then another option

#### Scenario: Empty tool list
- **WHEN** the spec's disallowed tools are empty
- **THEN** the arguments are the same as for a spec without any

### Requirement: Where and with what the child runs
The child SHALL run in `spec.cwd`, and the binary is `claude` unless the reference's `spec.bin` names another. The fields `disallowedTools`, `env`, `bin` and `logFile` of a spec have no CLI flags but are kept when present in a hand-edited reference. `logFile` reaches the child as `TA_LOG` so the dashboard can preview the session's log.

#### Scenario: Another binary
- **WHEN** a reference has `spec.bin` set to a script
- **THEN** that script is run instead of `claude`

#### Scenario: Log file
- **WHEN** a spec has `logFile`
- **THEN** the child's environment has `TA_LOG` with that path

### Requirement: The environment of the Claude child
The child SHALL get the parent's environment minus every variable whose name starts with `CLAUDE`, then `CLAUDE_CONFIG_DIR` set according to the account choice (inherited, unset or explicit). Its `PATH` starts with the directory of the running Node binary and `~/.local/bin`, then the inherited entries, without duplicates. `TA_LABEL` is set from the spec's label, and `spec.env` is merged last and wins over everything computed.

#### Scenario: Foreign login is dropped
- **WHEN** the parent environment has `CLAUDE_CONFIG_DIR=/a/.claude-work` and `CLAUDE_CODE_X=1`, and the spec has `configDir: null`
- **THEN** the child sees neither variable

#### Scenario: Env wins
- **WHEN** the spec has label `a` and `env` of `{ "TA_LABEL": "b" }`
- **THEN** the child's `TA_LABEL` is `b`

### Requirement: Messages that arrive during a turn
A library caller SHALL be able to give a turn an asynchronous stream of input messages. The prompt then becomes the first line of Claude's streaming input and the child runs with `--input-format stream-json --replay-user-messages`; every message is written at once, and the turn lasts until a result arrives with no written line still waiting to be echoed. Without input, the child gets no stdin and the outcome has no `delivered` list.

#### Scenario: Message mid-turn
- **WHEN** a message with id `m1` is offered while the turn runs and Claude echoes it
- **THEN** a `replay` event with id `m1` is heard and the turn ends on one result

#### Scenario: Message after the first result
- **WHEN** Claude echoes a message only after printing a first result
- **THEN** a second result follows in the same process and the outcome is the last one, with the cost of the last result and the turn counts summed

### Requirement: Delivery report of input messages
An outcome of a turn that was given input SHALL carry `delivered`: every message pulled, in order, with `replayed` true only if Claude echoed it back, which is the one proof the model read it. A message written and lost with a killed process, or one that arrives after input was closed (and so is not written), is reported with `replayed` false.

#### Scenario: Killed before the echo
- **WHEN** a message was written and the turn is killed before Claude echoed it
- **THEN** the outcome's `delivered` lists it with `replayed` false

#### Scenario: Too late
- **WHEN** a message arrives after stdin was closed
- **THEN** it is not written and is listed with `replayed` false

### Requirement: Stopping a turn from inside the process
A library caller SHALL be able to stop the turn running for a reference, with the driver's abort for that reference or with an abort signal given to the turn. The child is killed with SIGKILL and the turn resolves as `exited` with `signal` equal to `SIGKILL`. Aborting a reference with no turn running is a no-op.

#### Scenario: Abort signal
- **WHEN** the caller aborts the signal 150 ms into a turn with a silent child
- **THEN** the turn resolves with kind `exited`

#### Scenario: Abort by reference
- **WHEN** the driver aborts a reference with a turn in flight
- **THEN** the outcome is `exited` with `signal` `SIGKILL`

### Requirement: Per-turn diagnostics
A library turn SHALL write its diagnostic lines (the kill, abort, long-turn, sleep and keep-awake lines) to the log it was given, and only without one to the driver's own log. The CLI keeps no such log.

#### Scenario: Own sink
- **WHEN** a turn is given its own log and is killed after its result
- **THEN** the line `claude printed its result but did not exit within <ms> ms — killing` is in that log and not in the driver's

### Requirement: Keeping the machine awake
On macOS, for the length of every turn, the driver SHALL hold an idle-sleep assertion by running `caffeinate -i -w <child pid>`, released when the turn ends. It does not keep a machine with a closed lid awake. It is off on other platforms and when `TA_KEEP_AWAKE=0` is in the environment of the process running turns; a library caller can also turn it off in the driver options.

#### Scenario: Held for the child only
- **WHEN** a turn runs on macOS with the default settings
- **THEN** one assertion is taken for the pid of the Claude child and released exactly once when the turn ends

#### Scenario: Off switch
- **WHEN** `TA_KEEP_AWAKE=0` is set
- **THEN** no assertion is taken

### Requirement: Keeping awake is best effort
A failure to hold the machine awake SHALL never fail the turn. A missing `caffeinate` or a failed spawn writes the single line `keep-awake: caffeinate failed (<reason>) — the turn runs without it` to the turn's log.

#### Scenario: Caffeinate is missing
- **WHEN** `caffeinate` cannot be started
- **THEN** the turn still ends `ok` and its log holds exactly the one `keep-awake: caffeinate failed` line

#### Scenario: Release after a failure
- **WHEN** the hold failed and the turn ends
- **THEN** releasing does nothing and does not throw

### Requirement: Listing sessions
`session list` SHALL print a JSON array of references for the sessions the agent-state hook knows (see the `agent-state` capability), newest record first, including sessions this process never opened. Each reference has `id` (the record's key), `claudeSessionId` (or null), `transcript` (or null) and a `spec` with `kind`, `cwd`, `skipPermissions: false` and, when known, `label` and `configDir` (null for the default account; absent for a record that says nothing about the account).

#### Scenario: Listing from records
- **WHEN** one record is in the state `working` with the session id `sess-live`
- **THEN** `session list` prints one reference whose `claudeSessionId` is `sess-live`

#### Scenario: Nothing known
- **WHEN** the state directory is missing or empty
- **THEN** `session list` prints `[]` and exits 0

### Requirement: Filtering the list
`session list --state <state>` SHALL keep only sessions in that state and may be repeated; the states are `new`, `working`, `blocked`, `done` and `gone`, and any other value (including `subdone`) is a usage error (2). `--label <name>` keeps only sessions started with that `TA_LABEL`. Records in the `subdone` state (finished subagent children) are never listed.

#### Scenario: State filter
- **WHEN** the only record is `working` and `session list --state done` runs
- **THEN** it prints `[]`

#### Scenario: Unknown state
- **WHEN** `session list --state invented` runs
- **THEN** the exit code is 2

### Requirement: Reading the last reply
`session last <ref-json-or-id>` SHALL print `{ "text": ..., "at": ... }` as JSON, where `text` is the last assistant text block in the final 48 KiB of the session's transcript and `at` is the transcript's modification time in epoch milliseconds. It prints `null` when the session has no transcript, the file cannot be read, or the window holds no assistant text. A missing reference is a usage error (2).

#### Scenario: Last reply
- **WHEN** a transcript ends with an assistant message `Deploy script fixed and staging is green.`
- **THEN** `session last` prints that text together with the file's modification time

#### Scenario: Nothing to read
- **WHEN** the reference has no known transcript
- **THEN** `session last` prints `null` and exits 0

### Requirement: Which transcript is read
The transcript of `session last` SHALL be the reference's `transcript` when it has one, otherwise the transcript the agent-state records hold for the reference's Claude session id.

#### Scenario: Reference without a path
- **WHEN** the reference has a Claude session id and a record for that id names a transcript
- **THEN** that file is read

#### Scenario: Neither
- **WHEN** the reference has no transcript and no Claude session id
- **THEN** the result is `null`

### Requirement: Aborting a session from another process
`session abort <ref-json-or-id>` SHALL stop a running turn that another process started, through the pid the agent-state hook recorded for the session's record (matched by key or by Claude session id): it sends SIGKILL and prints `{ "aborted": true, "id": <ref id>, "pid": <pid> }`. An unknown reference exits 1 and a missing one 2.

#### Scenario: Running turn
- **WHEN** the record holds the pid of a live process
- **THEN** that process receives SIGKILL and stdout holds `aborted` true with the reference id and the pid

#### Scenario: Unknown reference
- **WHEN** nothing matches the reference
- **THEN** the exit code is 1

### Requirement: Aborting refuses to fake
When the record has no pid, the pid is not alive, or the kill fails, `session abort` SHALL do nothing: stdout stays empty, stderr says `nothing is running for <ref>` and the exit code is 3.

#### Scenario: No process behind it
- **WHEN** `session abort sess-live` runs and the record holds no pid
- **THEN** stdout is empty and the exit code is 3

#### Scenario: Dead pid
- **WHEN** the record holds a pid that no longer exists
- **THEN** the exit code is 3

### Requirement: Liveness of a pid
A pid SHALL count as alive when it is a positive integer and the operating system confirms a process with that id, without a signal being sent. A process that exists but belongs to another user counts as alive. Zero, negative, fractional and unknown pids are dead. `session abort` relies on this before it kills.

#### Scenario: Own process
- **WHEN** the pid is that of the running program
- **THEN** it is alive

#### Scenario: Nonsense pid
- **WHEN** the pid is 0, -5 or 1.5
- **THEN** it is dead

### Requirement: Closed pipes
Writes to stdout and stderr SHALL be best effort: a reader that stops early (`tagents-core sessions recent | head -1`) never turns into an error trace or a non-zero exit.

#### Scenario: Half-read output
- **WHEN** `tagents-core sessions recent | head -1` runs
- **THEN** the exit status is 0 and stderr is empty

### Requirement: Usage and unknown verbs
With no arguments `tagents-core` SHALL print the usage and exit 2; `help`, `--help` and `-h` print it and exit 0. A verb that is not a core verb is offered to the configured plugins (see the `cli-dispatch` and `plugin-system` capabilities) before it is refused with `unknown command: <verb>` and the usage on stderr (exit 2). The core verbs `session`, `sessions`, `plugin`, `doctor` and `help` always win over a plugin's verbs.

#### Scenario: Unknown verb
- **WHEN** `tagents-core nonsense` runs and no plugin offers it
- **THEN** stderr has `unknown command: nonsense` and `usage: tagents-core`, and the exit code is 2

#### Scenario: Help
- **WHEN** `tagents-core --help` runs
- **THEN** the exit code is 0
