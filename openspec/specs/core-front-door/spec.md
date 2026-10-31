# core-front-door Specification

## Purpose
The Rust binary `tagents-core` as the front door of the CLI: `spec/cli/tagents-core.json` lists every verb and the program that serves it, the binary answers the verbs marked `rust` itself, and every other word reaches the node CLI unchanged.

## Requirements

### Requirement: The verbs of tagents-core are data
The verbs, flags and exit codes of `tagents-core` SHALL be described by one JSON file, `spec/cli/tagents-core.json`, checked by the JSON Schema `spec/cli/cli-spec.schema.json`. Every implementation of the CLI (the node CLI, the contract generator and the Rust binary) SHALL read that file rather than keep a list of its own.

#### Scenario: The file matches its schema
- **WHEN** `spec/cli/tagents-core.json` is checked against `spec/cli/cli-spec.schema.json`
- **THEN** it is valid, and the node CLI refuses to start on a copy that is not

### Requirement: Each command says which program serves it
Each command in the file SHALL carry its `path`, `positionals`, `options`, `required`, an i18n `summary` key and an `impl` of `"rust"` or `"node"`; it MAY carry an `effect`, one of `read`, `write`, `spawn`, `destructive` or `serve`, and a `tool` of `false`, and no other property.

#### Scenario: A property nobody declared
- **WHEN** a command in the file carries a property other than the declared ones, `effect` and `tool`
- **THEN** the file does not match the schema

#### Scenario: A command with an effect
- **WHEN** a command carries `"effect": "write"`
- **THEN** the file matches the schema and the node CLI parses that command as before

#### Scenario: An effect nobody declared
- **WHEN** a command carries `"effect": "writes"`
- **THEN** the file does not match the schema, and the node CLI and the Rust crate refuse it

#### Scenario: A command kept out of the tools
- **WHEN** a command carries `"tool": false`
- **THEN** the file matches the schema
- **AND** it does not match when the command carries `"tool": true`

#### Scenario: An implementation that does not exist
- **WHEN** a command says `"impl": "python"`
- **THEN** the file does not match the schema

### Requirement: The Rust binary serves the verbs the file marks rust
`target/release/tagents-core` SHALL serve itself every verb whose `impl` is `"rust"`: `sessions recent`, `sessions search` and `sessions show`, and the bare `sessions` that means `recent`. It decides by the first word, so everything that starts with `sessions`, including a misspelled subcommand, is answered by the Rust binary with the node CLI's wording and exit codes.

#### Scenario: A served verb
- **WHEN** `target/release/tagents-core sessions recent 3` runs
- **THEN** the node CLI is not started and the output is what the node CLI prints for the same call

#### Scenario: A misspelled subcommand
- **WHEN** `target/release/tagents-core sessions rescent` runs
- **THEN** the usage line and exit code are the ones the node CLI gives for it

### Requirement: --spec prints the table of served verbs
When its arguments are exactly `--spec`, the Rust binary SHALL print the entries of the data file whose `impl` is `"rust"` as JSON on stdout, exit 0 and start no other program. Any other argument list that contains `--spec` is an ordinary call.

#### Scenario: The served table
- **WHEN** `target/release/tagents-core --spec` runs
- **THEN** stdout holds exactly the `impl: rust` commands of `spec/cli/tagents-core.json` and nothing else, and the exit code is 0

#### Scenario: --spec with more words
- **WHEN** `target/release/tagents-core --spec x` runs
- **THEN** the call is handed to the node CLI like any word the binary does not serve

### Requirement: Every other word reaches the node CLI untouched
For every argument list the Rust binary does not serve, it SHALL replace itself with `node packages/core/dist/cli/main.js` of the checkout it sits in (`<root>/target/{release,debug}/tagents-core` belongs to `<root>`, symbolic links resolved), with the same arguments, environment, working directory, stdin, stdout and stderr, so that the exit code and the signal the call ends with are the node CLI's own.

#### Scenario: Arguments, input and exit code
- **WHEN** `target/release/tagents-core plugin add ./x "two words"` runs, with input on stdin, and the node CLI exits 3
- **THEN** the node CLI received `plugin`, `add`, `./x` and `two words` and the input, and the binary's exit code is 3

#### Scenario: Ended by a signal
- **WHEN** the node CLI is ended by SIGTERM
- **THEN** the binary's process ends by SIGTERM as well

#### Scenario: A reader that went away
- **WHEN** the output of a served verb is piped into a program that closes the pipe
- **THEN** the binary neither prints an error about it nor changes its exit code

### Requirement: Which node runs the node CLI
The `node` that runs the node CLI SHALL be `$TAGENTS_NODE` when that is set and not empty, and the `node` on `PATH` otherwise.

#### Scenario: The pinned node
- **WHEN** `TAGENTS_NODE=/opt/node/bin/node` is set and a word that is not served runs
- **THEN** the node CLI runs on `/opt/node/bin/node`

#### Scenario: No pin
- **WHEN** `TAGENTS_NODE` is not set and a word that is not served runs
- **THEN** the node CLI runs on the `node` that `PATH` finds

### Requirement: When the node CLI cannot be run
When a word has to go to the node CLI and `packages/core/dist/cli/main.js` does not exist in the checkout, the Rust binary SHALL print one line on stderr that names the path it looked at and says it has to stay in `<root>/target/<profile>/` next to a built `packages/core/dist/cli/main.js`, and exit 2. When the node program cannot be started, it SHALL print one line naming it and exit 127 if no such program exists and 126 if it exists and cannot be run.

#### Scenario: Not built
- **WHEN** a word that is not served runs from a checkout with no `packages/core/dist/cli/main.js`
- **THEN** one line on stderr names the path looked at and `<root>/target/<profile>/`, and the exit code is 2

#### Scenario: No node
- **WHEN** a word that is not served runs and `$TAGENTS_NODE` names a file that does not exist
- **THEN** one line on stderr names it and the exit code is 127

#### Scenario: A node that cannot run
- **WHEN** `$TAGENTS_NODE` names a file that exists and is not executable
- **THEN** one line on stderr names it and the exit code is 126
