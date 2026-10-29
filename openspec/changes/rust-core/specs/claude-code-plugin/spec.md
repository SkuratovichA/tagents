## MODIFIED Requirements

### Requirement: The installer writes wrappers, not symlinks
`install.sh` SHALL write a real-file wrapper into `~/.local/bin` for each of `tagents`, `tusage`, `tnotes`, `tagents-core` and `tagents-knowledge`, and one per `hooks/*.sh` into `~/.claude/hooks` or each repeatable `--hooks-dir DIR`; a wrapper runs the same file of the managed copy. It writes only over a symlink or a file with the installer's marker line; any other file is left alone with a warning and exit 1 at the end. A wrapper whose hook the project dropped is removed. When `$TAGENTS_HOME/target/release/tagents-core` is an executable file at the time of the install, the `tagents-core` wrapper SHALL run it, with the node it pinned passed on as `TAGENTS_NODE`, for as long as it is an executable file, and the node CLI otherwise; when it is not, the wrapper SHALL be byte for byte the one written when no Rust binary existed. The installer never builds or downloads that binary.

#### Scenario: Two Claude config directories
- **WHEN** `install.sh --hooks-dir ~/.claude/hooks --hooks-dir ~/.claude-work/hooks` runs
- **THEN** both directories hold a wrapper for every hook script

#### Scenario: A file of somebody else's
- **WHEN** `~/.local/bin/tusage` exists and was not written by the installer
- **THEN** it is left as it was, a warning names it, and the exit code is 1

#### Scenario: A hook the project dropped
- **WHEN** an update brings a copy that no longer ships `hooks/old.sh`, and `~/.claude/hooks/old.sh` is a wrapper of the installer
- **THEN** that wrapper is removed

#### Scenario: No Rust binary
- **WHEN** the installer runs and `$TAGENTS_HOME/target/release/tagents-core` does not exist
- **THEN** every wrapper it writes is byte for byte what the installer wrote before the Rust binary existed

#### Scenario: A Rust binary built before the install
- **WHEN** `$TAGENTS_HOME/target/release/tagents-core` is executable when the installer runs, and `tagents-core sessions recent` is run
- **THEN** the wrapper runs that binary with the whole argument list, its exit code is the result, and `TAGENTS_NODE` holds the node the installer pinned

#### Scenario: The Rust binary is gone
- **WHEN** the binary the wrapper names has been removed or is no longer executable
- **THEN** the wrapper runs the node CLI exactly as the wrapper of an install with no Rust binary does
