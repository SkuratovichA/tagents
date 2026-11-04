## MODIFIED Requirements

### Requirement: The Rust binary serves the verbs the file marks rust
`target/release/tagents-core` SHALL answer itself every call of a verb whose `impl` is `"rust"`: `sessions`, `plugin add`, `remove` and `new`, `doctor`, `notify run` and every `session` call, whatever follows the verb. With no word it SHALL print the usage line and exit 2, with `help`, `--help` or `-h` print it and exit 0. Only `plugin list`, a bare `plugin`, a `plugin` word it does not know and a word the file does not list SHALL reach the node CLI.

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

#### Scenario: A session verb
- **WHEN** `target/release/tagents-core session list` runs
- **THEN** the node CLI is not started

#### Scenario: A session call that is not served
- **WHEN** `target/release/tagents-core session`, `session bogus` or `session open --bogus` runs
- **THEN** the node CLI is not started, and stdout, stderr and the exit code are what the node CLI gives for the same call

#### Scenario: The usage words
- **WHEN** `tagents-core` runs with no word, and with `help`, `--help` and `-h`
- **THEN** the usage line is printed, the exit code is 2 for no word and 0 for the others, and the node CLI is not started
