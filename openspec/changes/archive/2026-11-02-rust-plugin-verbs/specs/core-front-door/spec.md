## MODIFIED Requirements

### Requirement: The Rust binary serves the verbs the file marks rust
`target/release/tagents-core` SHALL serve itself every verb whose `impl` is `"rust"`: `sessions recent`, `sessions search`, `sessions show` (and the bare `sessions` that means `recent`), `plugin add`, `plugin remove`, `plugin new` and `doctor`. Everything that starts with `sessions` or `doctor` is answered by the Rust binary with the node CLI's wording and exit codes; a `plugin` call that is not one of its three verbs, or that it cannot prove it answers as node does, is the node CLI's.

#### Scenario: A served verb
- **WHEN** `target/release/tagents-core sessions recent 3` runs
- **THEN** the node CLI is not started and the output is what the node CLI prints for the same call

#### Scenario: A misspelled subcommand
- **WHEN** `target/release/tagents-core sessions rescent` runs
- **THEN** the usage line and exit code are the ones the node CLI gives for it

#### Scenario: A plugin verb
- **WHEN** `target/release/tagents-core plugin remove x` runs
- **THEN** the node CLI is not started

#### Scenario: A plugin call that is not served
- **WHEN** `target/release/tagents-core plugin list`, a bare `plugin` or `plugin bogus` runs
- **THEN** the node CLI receives exactly those arguments and its output and exit code are the call's

### Requirement: Every other word reaches the node CLI untouched
For every argument list the Rust binary does not serve, it SHALL replace itself with `node packages/core/dist/cli/main.js` of the checkout it sits in (`<root>/target/{release,debug}/tagents-core` belongs to `<root>`, symbolic links resolved), with the same arguments, environment, working directory, stdin, stdout and stderr, so that the exit code and the signal the call ends with are the node CLI's own.

#### Scenario: Arguments, input and exit code
- **WHEN** `target/release/tagents-core session prompt ./x "two words"` runs, with input on stdin, and the node CLI exits 3
- **THEN** the node CLI received `session`, `prompt`, `./x` and `two words` and the input, and the binary's exit code is 3

#### Scenario: Ended by a signal
- **WHEN** the node CLI is ended by SIGTERM
- **THEN** the binary's process ends by SIGTERM as well

#### Scenario: A reader that went away
- **WHEN** the output of a served verb is piped into a program that closes the pipe
- **THEN** the binary neither prints an error about it nor changes its exit code
