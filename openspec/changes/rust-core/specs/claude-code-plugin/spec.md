## ADDED Requirements

### Requirement: The tagents-core wrapper runs a Rust binary built before the install
When `$TAGENTS_HOME/target/release/tagents-core` is an executable file at the time of the install, the `tagents-core` wrapper SHALL run it, with the node it pinned passed on as `TAGENTS_NODE`, for as long as it is an executable file, and the node CLI otherwise. Both files belong to the managed copy, so the wrapper runs nothing outside it, and the installer never builds that binary.

#### Scenario: A Rust binary built before the install
- **WHEN** `$TAGENTS_HOME/target/release/tagents-core` is executable when the installer runs, and `tagents-core sessions recent` is run
- **THEN** the wrapper runs that binary with the whole argument list, its exit code is the result, and `TAGENTS_NODE` holds the node the installer pinned

#### Scenario: The Rust binary is gone
- **WHEN** the binary the wrapper names has been removed, or replaced by a directory or by a file without the executable bit, after the install
- **THEN** the wrapper runs the node CLI exactly as the wrapper of an install with no Rust binary does

#### Scenario: A Rust binary that cannot run
- **WHEN** a file that is executable but cannot run, because its interpreter is missing, sits at `target/release/tagents-core` when the installer runs
- **THEN** the installed wrapper names it and runs it, and the failure to run it is an error and never a fallback to the node CLI

### Requirement: Without a usable Rust binary the wrapper is the old one
When `$TAGENTS_HOME/target/release/tagents-core` is not an executable file at the time of the install, whether it does not exist, lacks the executable bit or is a directory, the `tagents-core` wrapper SHALL be byte for byte the one written when no Rust binary existed.

#### Scenario: No Rust binary
- **WHEN** the installer runs and `$TAGENTS_HOME/target/release/tagents-core` does not exist
- **THEN** every wrapper it writes is byte for byte what the installer wrote before the Rust binary existed

#### Scenario: A file without the executable bit
- **WHEN** a file without the executable bit sits at `$TAGENTS_HOME/target/release/tagents-core` when the installer runs
- **THEN** the plain wrapper is written, which runs the node CLI and names no Rust binary

#### Scenario: A directory where the Rust binary would be
- **WHEN** a directory sits at `$TAGENTS_HOME/target/release/tagents-core` when the installer runs
- **THEN** the plain wrapper is written, which runs the node CLI and names no Rust binary
