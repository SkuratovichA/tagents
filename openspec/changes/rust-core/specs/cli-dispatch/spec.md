## MODIFIED Requirements

### Requirement: Where tagents-core is looked for
The script SHALL use the `tagents-core` found on `PATH` first, because that is the installed one and the one the user chose. Failing that, in a repository checkout it SHALL use the Rust binary `target/release/tagents-core` beside the script when that is an executable file, which serves the verbs ported to Rust and hands every other word to the node CLI. Failing that it SHALL use the built `packages/core/dist/cli/main.js` beside the script, executing it directly when it is executable and through `node` when it is only readable and `node` is on `PATH`. A Rust binary that is present and cannot be run is an error of its own, never a reason to try the next one.

#### Scenario: A checkout with nothing on PATH
- **WHEN** a built core sits beside the script and no `tagents-core` is on `PATH`
- **THEN** the verb is handed to the built file with its exit code passed through

#### Scenario: Installed beats checkout
- **WHEN** both exist
- **THEN** the one on `PATH` is used

#### Scenario: A Rust binary beside the script
- **WHEN** an executable `target/release/tagents-core` and a built core sit beside the script and no `tagents-core` is on `PATH`
- **THEN** the verb is handed to the Rust binary with the whole argument list and its exit code is passed through

#### Scenario: A Rust binary that is not executable
- **WHEN** `target/release/tagents-core` exists without the executable bit and a built core sits beside the script
- **THEN** the verb is handed to the built core

#### Scenario: A Rust binary that cannot run
- **WHEN** an executable file `target/release/tagents-core` whose interpreter is missing sits beside the script and no `tagents-core` is on `PATH`
- **THEN** the command fails with a non-zero exit code and a message on stderr, and the node CLI is not run

#### Scenario: A directory where the Rust binary would be
- **WHEN** `target/release/tagents-core` is a directory and a built core sits beside the script
- **THEN** the verb is handed to the built core

#### Scenario: No Rust binary
- **WHEN** there is no `target/release/tagents-core` beside the script
- **THEN** the verb is handled exactly as it was before the Rust binary existed

### Requirement: Without tagents-core the verb says where it went
When there is no `tagents-core` on `PATH`, no executable Rust binary and no built file beside the script, a forwarded verb SHALL print one line on stderr, `tagents: no tagents-core on PATH and none at <path to packages/core/dist/cli/main.js>, so "<verb>" goes nowhere`, and exit 2, the code of a usage error.

#### Scenario: Nothing to forward to
- **WHEN** `tagents session list` runs with neither a `tagents-core` on `PATH`, nor a Rust binary, nor a built core
- **THEN** exactly one line is printed, naming the verb, saying there is no `tagents-core` on `PATH` and naming the built path, and the exit code is 2
