## MODIFIED Requirements

### Requirement: The five session verbs are answered by the Rust binary
`tagents-core session open`, `session prompt`, `session last`, `session list` and `session abort` SHALL be answered by the Rust binary with the node CLI's stdout, stderr, exit code, key order and number format, in `en` and `ru`. A `session` call with no verb or with another one SHALL print `unknownCommand` for `session <verb>` and the usage line, with exit 2.

#### Scenario: A served verb
- **WHEN** `tagents-core session list` runs
- **THEN** the node CLI is not started, and stdout, stderr and the exit code are what the node CLI gives for the same call and the same state directory

#### Scenario: Another language
- **WHEN** `TAGENTS_LOCALE=ru` is set and `session open` runs with no `--cwd`
- **THEN** stderr is the Russian text of `missingOption` that the node CLI prints, and the exit code is 2

#### Scenario: Not one of the five
- **WHEN** `tagents-core session` or `tagents-core session bogus` runs
- **THEN** the node CLI is not started, stderr is the `unknownCommand` line and the usage line node prints, and the exit code is 2

### Requirement: The options are read the way the node parser reads them
A string option SHALL take the next argument when that does not start with `-`, or the text after `=`; the last occurrence SHALL win; a flag SHALL take no value; `--` SHALL end the options; a lone `-` SHALL be a positional. Any other argument that starts with `-`, and a positional where the verb takes none, SHALL print the text of the node parser's error on stderr and exit 2.

#### Scenario: An inline value
- **WHEN** `session open --cwd=/x --label a --label=b` runs
- **THEN** the reference has `cwd` `/x` and `label` `b`

#### Scenario: A value that looks like an option
- **WHEN** `session open --cwd -x` runs
- **THEN** stderr is the text node's parser gives for it and the exit code is 2

#### Scenario: A text after the end of the options
- **WHEN** `session prompt <ref> -- "-x go"` runs
- **THEN** the last argument of the child is `-x go`

### Requirement: The binary is kept equal to node by a suite and by vectors
A suite SHALL run each scenario on the node CLI and on the binary, on copies of one tree, with a stub `claude` and a stub `caffeinate` on `PATH`, and compare stdout, stderr, the exit code, the stub's recorded arguments and environment and the state directory; a scenario whose words cannot match SHALL state what the binary prints instead, and `docs/architecture/rust-core.md` SHALL list it. Vectors written by node's own functions SHALL pin the pieces that exist twice.

#### Scenario: A binary that hands everything to node
- **WHEN** a scenario marked as answered by Rust is run against a binary that forwards the call
- **THEN** the suite fails

#### Scenario: Stale vectors
- **WHEN** the vector file is regenerated and differs from the committed one
- **THEN** the CI step that checks `git diff --exit-code` fails

#### Scenario: A call the words of which differ
- **WHEN** a reference holds a name that `spawn` refuses
- **THEN** the suite requires the binary's own line and exit code, and the page lists the scenario

## REMOVED Requirements

### Requirement: What Rust cannot prove identical goes to node before anything starts
**Reason**: No call of a verb of the binary reaches node.
**Migration**: The classes are answered by the binary: an option the parser rejects with the parser's text and exit 2, an argument or an environment entry that is not UTF-8 read lossily, a reference it cannot hold with `badRef` and exit 1, a failed `spawn` with the detail node prints.

## ADDED Requirements

### Requirement: What the binary cannot hold is read lossily or refused
An argument or an environment entry that is not UTF-8 SHALL be decoded as node decodes it, with U+FFFD for each bad byte. A reference that holds a lone surrogate, a NUL, an empty `bin`, a relative `bin` with a slash or an environment name with `=` SHALL give `badRef` and exit 1 on `last` and `prompt`, and `abort` SHALL do the same. A SIGCHLD ignored at the start of `session prompt` SHALL NOT stop the verb.

#### Scenario: An argument that is not UTF-8
- **WHEN** `session list --label` runs with an argument that is not valid UTF-8
- **THEN** the label is the lossy text and the node CLI is not started

#### Scenario: A reference the binary cannot hold
- **WHEN** `session prompt` is given a reference whose `spec.env` holds a name that contains `=`
- **THEN** stderr is the `badRef` line for it, the exit code is 1 and `claude` is not started

#### Scenario: No node
- **WHEN** a `session` call runs on a machine with no node
- **THEN** the binary answers it, because it asks node nothing
