# rust-session Specification

## Purpose
The five `session` verbs (`open`, `list`, `last`, `prompt`, `abort`) as verbs of the Rust binary: `tagents-core session <verb>` prints the same bytes, leaves the same files and ends with the same exit code as the node CLI in `packages/core`, which stays as the fallback and as the reference that the differential suite compares against; a call the binary cannot prove identical goes to node before anything is written or started.

## Requirements

### Requirement: The five session verbs are answered by the Rust binary
`tagents-core session open`, `session prompt`, `session last`, `session list` and `session abort` SHALL be answered by the Rust binary with the node CLI's stdout, stderr, exit code, key order and number format, in `en` and `ru`. A `session` call with no verb, or with a verb that is not one of the five, SHALL stay the node CLI's.

#### Scenario: A served verb
- **WHEN** `tagents-core session list` runs
- **THEN** the node CLI is not started, and stdout, stderr and the exit code are what the node CLI gives for the same call and the same state directory

#### Scenario: Another language
- **WHEN** `TAGENTS_LOCALE=ru` is set and `session open` runs with no `--cwd`
- **THEN** stderr is the Russian text of `missingOption` that the node CLI prints, and the exit code is 2

#### Scenario: Not one of the five
- **WHEN** `tagents-core session` or `tagents-core session bogus` runs
- **THEN** the node CLI receives exactly those arguments, and its output and exit code are the call's

### Requirement: What Rust cannot prove identical goes to node before anything starts
A call outside the subset Rust answers exactly SHALL be run by the node CLI with the same arguments and environment, before Rust reads a file, writes one or starts `claude`: arguments the node parser rejects, a value that node's `spawn` refuses, an argument that is not UTF-8, and, for a verb that starts a child, an environment entry that is not UTF-8, no node on the machine, and a `spawn` that fails with an errno other than `ENOENT`, `EACCES` or `ENOTDIR`.

#### Scenario: An option node rejects
- **WHEN** `session open --cwd /x --bogus` runs
- **THEN** the node CLI receives those arguments and answers with its usage error and exit code 2

#### Scenario: A read verb starts no child
- **WHEN** `session open`, `session list` or `session last` runs with an environment entry that is not UTF-8, or with no node on the machine
- **THEN** the binary answers the call itself, because neither class can change what a verb that starts no child prints

#### Scenario: A value spawn refuses
- **WHEN** `session prompt` is given a reference whose `spec.env` holds a name that contains `=`
- **THEN** the node CLI answers, and `claude` is started once, by the node CLI

#### Scenario: An argument that is not UTF-8
- **WHEN** `session list --label` runs with an argument that is not valid UTF-8
- **THEN** the node CLI receives that argument byte for byte

#### Scenario: No node
- **WHEN** a `session` call has to go to the node CLI and no node can be found
- **THEN** the front door's own error for that case is printed, with its exit code

### Requirement: The options are read the way the node parser reads them
A string option SHALL take the next argument when that does not start with `-`, or the text after `=`; the last occurrence SHALL win; a flag SHALL take no value; `--` SHALL end the options; a lone `-` SHALL be a positional. Any other argument that starts with `-`, and a positional where the verb takes none, SHALL go to the node CLI, which words its own usage error.

#### Scenario: An inline value
- **WHEN** `session open --cwd=/x --label a --label=b` runs
- **THEN** the reference has `cwd` `/x` and `label` `b`

#### Scenario: A value that looks like an option
- **WHEN** `session open --cwd -x` runs
- **THEN** the node CLI answers with its usage error and exit code 2

#### Scenario: A text after the end of the options
- **WHEN** `session prompt <ref> -- "-x go"` runs
- **THEN** the last argument of the child is `-x go`

### Requirement: The child is started as the node driver starts it
`session prompt` SHALL start `claude`, or the reference's `bin`, exactly once, with the arguments and environment that `headless-sessions` gives for the child, the prompt last, standard input closed, in the working directory of the spec, and with a `PATH` that begins with the directory of the real path of the node binary, then `~/.local/bin`, then the inherited entries without duplicates.

#### Scenario: Every option of the reference
- **WHEN** a turn runs for a reference with a model, an effort, disallowed tools, an MCP config, skipped permissions, a system prompt file, a label, a log file, `env` and a known Claude session id
- **THEN** the arguments and the environment the stub `claude` records are the ones the node CLI's turn records

#### Scenario: The inherited account
- **WHEN** the parent has `CLAUDE_CONFIG_DIR=/a` and `CLAUDE_X=1` and the spec has no `configDir`
- **THEN** the child sees `CLAUDE_CONFIG_DIR=/a` and no `CLAUDE_X`

#### Scenario: The path of the child
- **WHEN** the CLI runs with `PATH=/a:/b:/a`
- **THEN** the child's `PATH` is the node directory, `~/.local/bin`, `/a`, `/b`

### Requirement: A claude that cannot be started is reported as node reports it
When the file is missing or not executable, or the working directory does not exist, `session prompt` SHALL print an outcome of kind `spawn-failed` with the detail `spawn <bin> <CODE>`, the line `exit=null spawn: <detail>` on stderr and exit 1. When the working directory is not a directory, it SHALL print only `spawn ENOTDIR` on stderr and exit 1.

#### Scenario: No claude on PATH
- **WHEN** `session prompt` runs and no `claude` is on the `PATH` of the child
- **THEN** stdout is an outcome with `kind` `spawn-failed` and `detail` `spawn claude ENOENT`, and the exit code is 1

#### Scenario: A working directory that is a file
- **WHEN** the reference's `cwd` names a file
- **THEN** stderr is `spawn ENOTDIR`, stdout is empty and the exit code is 1

### Requirement: A turn ends when node's turn ends
A turn SHALL be over at the first `result` event that matches the result schema, at the time limit (the child killed by SIGKILL) and, when the child has not left 60 seconds after its result, by a kill that leaves the turn a success. Once the child has exited, the turn SHALL wait for both of its pipes to close for at most 5 seconds and SHALL read every line already written before it decides.

#### Scenario: A result that fails the schema
- **WHEN** the child prints a `result` event whose `is_error` is `null`
- **THEN** the line is an event of kind `other` and the turn does not end

#### Scenario: A line written just before the exit
- **WHEN** the child prints its result line and exits at once
- **THEN** the outcome is `ok` with that result, and no line is lost

#### Scenario: A pipe that stays open
- **WHEN** the child exits and a grandchild keeps its stdout open
- **THEN** the outcome is printed 5 seconds after the exit, with the lines read so far

### Requirement: The events and the outcome are written as node writes them
With `--events`, each event line SHALL be written when its line has been read, and the outcome SHALL follow as one compact line. Keys SHALL be in node's order: `ok` has `kind, text, sessionId, toolUses, costUsd, numTurns, durationMs`; `killed-after-result` adds `code`; `timeout`, `exited` and `spawn-failed` are as in the scenarios. Numbers print as `JSON.stringify` prints them.

#### Scenario: A timeout
- **WHEN** a turn with `--timeout 400` and `--events` times out
- **THEN** the last line has the keys `kind, sessionId, toolUses, limitMs, detail, sawText, sawResult` in that order

#### Scenario: A child that exited
- **WHEN** the child leaves with code 1 and no result
- **THEN** the outcome has the keys `kind, sessionId, toolUses, code, signal, detail, sawText, sawResult` in that order

#### Scenario: An event as it is read
- **WHEN** the child prints a tool call, waits one second and prints its result, with `--events`
- **THEN** the `tool_use` line is on stdout before the result line is written

#### Scenario: Numbers
- **WHEN** a result payload has `total_cost_usd` of `1e21` and `duration_ms` of `-0`
- **THEN** the payload line prints `1e+21` and `0`

### Requirement: Strings keep their UTF-16 meaning
A lone surrogate in a text, a tool input, a result payload or a transcript reply SHALL be printed as the escape `\udXXX`, two halves from two text blocks SHALL join into one character, and `detail` SHALL be cut at 300 UTF-16 units, so a cut inside a pair leaves a lone surrogate that prints as an escape.

#### Scenario: A lone surrogate
- **WHEN** the child's text holds the escape `\ud83d` alone
- **THEN** the event line and the outcome print `\ud83d`

#### Scenario: The cut of the detail
- **WHEN** the stderr of a failed child holds 299 letters followed by an emoji
- **THEN** `detail` ends with the escape `\ud83d`

### Requirement: The call ends when the output pipes of the child close
`session prompt` SHALL write the outcome and the error line as soon as the turn is over, and SHALL end only when both output pipes of the child have closed, so a grandchild that keeps one open keeps the call running after the outcome.

#### Scenario: A grandchild holding the pipe
- **WHEN** the child exits and a background process it started keeps its stdout open for 14 seconds
- **THEN** the outcome is on stdout 5 seconds after the exit and the process ends when the pipe closes

### Requirement: A signal ends the CLI and leaves the child running
A signal that ends `session prompt` while a turn runs SHALL end the process by that signal and SHALL NOT stop the Claude child; `session list` finds it and `session abort` stops it.

#### Scenario: SIGTERM during a turn
- **WHEN** SIGTERM is sent to `session prompt` while the child runs
- **THEN** the process ends by SIGTERM and the child's pid is still alive

### Requirement: open and list answer what node answers
`session open` SHALL print a reference with a fresh version 4 `id` and an absolute `cwd`, and exit 2 without `--cwd` or with both `--config-dir` and `--no-config-dir`. `session list` SHALL print the references of the state records that are not `subdone`, in the order the reader returns them, filtered by `--label` and `--state`, and exit 2 for a state that is not one of `new`, `working`, `blocked`, `done` and `gone`.

#### Scenario: A relative working directory
- **WHEN** `session open --cwd ./x` runs in `/work`
- **THEN** the reference's `cwd` is `/work/x`

#### Scenario: An unknown state
- **WHEN** `session list --state a,b` runs
- **THEN** stderr is the text of `unknownOption` for `--state a,b` and the exit code is 2

### Requirement: last and abort answer what node answers
`session last` SHALL print the last assistant text of the transcript and the file's modification time in milliseconds, or `null`. `session abort` SHALL kill the headless session's pid with SIGKILL and print the id and pid; it SHALL exit 3 for a pane's record, for a record with no pid and for a pid that is not alive, a pid beyond 32-bit integers being not alive, and 1 with `no session matches <ref>` when nothing matches.

#### Scenario: A pane's record
- **WHEN** `session abort` names a record whose key does not start with `s-`
- **THEN** stderr is the text of `abortPaneAgent` and the exit code is 3

#### Scenario: A pid beyond 32 bits
- **WHEN** `session abort` names a record whose pid is 4294967297
- **THEN** stderr is the text of `nothingToAbort` and the exit code is 3

#### Scenario: A reply with a lone surrogate
- **WHEN** the transcript's last text holds the escape `\ud83d` alone
- **THEN** `session last` prints `\ud83d` in `text`

### Requirement: The texts come from one catalogue
Every line the five verbs print that is not an outcome, an event or a JSON document SHALL come from `spec/cli/messages.json` in the language `TAGENTS_LOCALE` and the environment choose, and no text SHALL be copied into the Rust code. The lines `exit=...` and `spawn ENOTDIR` are node's own words in both languages.

#### Scenario: Both languages
- **WHEN** each of `missingOption`, `unknownOption`, `noPrompt`, `badRef`, `abortPaneAgent` and `nothingToAbort` is triggered in `en` and in `ru`
- **THEN** stderr equals the node CLI's for the same call

### Requirement: The binary is kept equal to node by a suite and by vectors
A suite SHALL run each scenario on the node CLI and on the binary, on copies of one tree, with a stub `claude` and a stub `caffeinate` on `PATH`, and compare stdout, stderr, the exit code, the stub's recorded arguments and environment and the state directory; vectors written by node's own functions SHALL pin the pieces that exist twice.

#### Scenario: A binary that hands everything to node
- **WHEN** a scenario marked as answered by Rust is run against a binary that forwards the call
- **THEN** the suite fails

#### Scenario: Stale vectors
- **WHEN** the vector file is regenerated and differs from the committed one
- **THEN** the CI step that checks `git diff --exit-code` fails
