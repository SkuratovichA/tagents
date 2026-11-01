## MODIFIED Requirements

### Requirement: The server entry falls back to a server of its own
The script `packages/knowledge/bin/knowledge-mcp` SHALL join the session to the shared server of the `knowledge` capability. When `tagents-knowledge join` exits 0 on empty input it SHALL replace itself with `tagents-knowledge join`. Otherwise it SHALL run `tagents-knowledge serve`, and when that prints a socket that exists and `nc` is available, replace itself with `nc -U` on that socket, and else run `tagents-knowledge mcp`. `tagents-knowledge` must be on `PATH`.

#### Scenario: The native program is installed
- **WHEN** `tagents-knowledge join` exits 0 on empty input
- **THEN** the process the session started is `tagents-knowledge join`, and no node program and no `nc` runs

#### Scenario: Shared server available
- **WHEN** `join` is an unknown command, `tagents-knowledge serve` prints an existing socket and `nc` is on `PATH`
- **THEN** the process the session started is `nc -U` on that socket

#### Scenario: No shared server
- **WHEN** `join` is an unknown command and `serve` fails or is an unknown verb, or there is no `nc`
- **THEN** the session gets `tagents-knowledge mcp` with the same tools

## ADDED Requirements

### Requirement: The tagents-knowledge command runs the native server for join, mcp and serve when the binary is installed
When `$TAGENTS_HOME/target/release/tagents-core` is an executable file of the checkout's version at install time, the `tagents-knowledge` wrapper SHALL run it as `tagents-core knowledge <word>` when its arguments are exactly `join`, `mcp` or `serve`, and in every other case, or when the binary is gone or not executable at run time, SHALL run the node program with the wrapper's arguments. The pinned node SHALL be handed over as for `tagents-core`.

#### Scenario: The binary is installed
- **WHEN** the binary is installed and `tagents-knowledge join`, `mcp` or `serve` runs
- **THEN** the binary receives `knowledge` and that word (`tests/install.sh`)

#### Scenario: Any other arguments
- **WHEN** `tagents-knowledge serve --idle 30`, `mcp extra`, `search x` or no arguments runs over an installed binary
- **THEN** the node program receives the arguments whole (`tests/install.sh`)

#### Scenario: The binary vanishes after the install
- **WHEN** the file is removed or loses its executable bit
- **THEN** the same wrapper runs the node program for the three words as well (`tests/install.sh`)

#### Scenario: A binary of another version
- **WHEN** the binary in the tree says a version other than the checkout's, or cannot say
- **THEN** the wrapper is written without it and the three words run the node program (`tests/install.sh`)

### Requirement: The tagents-knowledge wrapper without a binary is the node wrapper
With no executable binary of the checkout's version at install time the installer SHALL write the `tagents-knowledge` wrapper with no line that names a binary, so that its one command is the `exec` of the node program with the wrapper's arguments. A failed or refused fetch, a version without a release and `TAGENTS_NO_NATIVE=1` SHALL each leave that wrapper, so no machine is without a knowledge server.

#### Scenario: No binary
- **WHEN** the installer runs on a machine without the binary
- **THEN** `tagents-knowledge` is the node wrapper and `join` is an unknown command (`tests/install.sh`)

#### Scenario: No release for the version
- **WHEN** the installer runs on a copy whose version has no release
- **THEN** the prebuilt binary is removed and `tagents-knowledge serve` runs the node program (`tests/install.sh`)
