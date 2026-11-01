## MODIFIED Requirements

### Requirement: The server entry falls back to a server of its own
The script `packages/knowledge/bin/knowledge-mcp` SHALL join the session to the shared server of the `knowledge` capability. When `tagents-knowledge join` exits 0 on empty input it SHALL replace itself with `tagents-knowledge join`. After any other code it SHALL run `tagents-knowledge serve` and, when that prints an existing socket and `nc` is available, replace itself with `nc -U` on it, and else run `tagents-knowledge mcp`; after a code other than 69 and 2 it SHALL first write one line naming the code to its standard error.

#### Scenario: The native program is installed
- **WHEN** `tagents-knowledge join` exits 0 on empty input
- **THEN** the process the session started is `tagents-knowledge join`, nothing is written to standard error, and no node program and no `nc` runs

#### Scenario: Shared server available
- **WHEN** `join` exits 69 or 2, `tagents-knowledge serve` prints an existing socket and `nc` is on `PATH`
- **THEN** the process the session started is `nc -U` on that socket, and nothing is written to standard error

#### Scenario: No shared server
- **WHEN** `join` exits 69 or 2 and `serve` fails or is an unknown verb, or there is no `nc`
- **THEN** the session gets `tagents-knowledge mcp` with the same tools, and nothing is written to standard error

#### Scenario: The native program failed
- **WHEN** `join` exits 1, 3 or 127
- **THEN** exactly one line naming that code is written to standard error, and the session gets the server of the two scenarios above

## ADDED Requirements

### Requirement: The tagents-knowledge command runs the native server for join, mcp and serve when the binary is installed
When `$TAGENTS_HOME/target/release/tagents-core` is an executable file of the checkout's version at install time, the `tagents-knowledge` wrapper SHALL run it as `tagents-core knowledge <word>` for `join` or `mcp` alone and for `serve` with any arguments. Every other call, and every call once the binary is gone or not executable, SHALL run the node program, except that `join` alone then exits 69 and starts nothing. The pinned node is handed over as for `tagents-core`.

#### Scenario: The binary is installed
- **WHEN** the binary is installed and `tagents-knowledge join`, `mcp` or `serve` runs
- **THEN** the binary receives `knowledge` and that word (`tests/install.sh`)

#### Scenario: serve with options
- **WHEN** `tagents-knowledge serve --idle 30` or `serve --foreground --socket P` runs over an installed binary
- **THEN** the binary receives `knowledge serve` and the options, whole, and one daemon serves the environment whichever argument list started it (`tests/install.sh`)

#### Scenario: Any other arguments
- **WHEN** `tagents-knowledge mcp extra`, `join x`, `search x` or no arguments runs over an installed binary
- **THEN** the node program receives the arguments whole (`tests/install.sh`)

#### Scenario: The binary vanishes after the install
- **WHEN** the file is removed or loses its executable bit
- **THEN** `serve` and `mcp` run the node program, and `join` exits 69 and starts no program (`tests/install.sh`)

#### Scenario: A binary of another version
- **WHEN** the binary in the tree says a version other than the checkout's, or cannot say
- **THEN** the wrapper is written without it, as in the requirement below (`tests/install.sh`)

### Requirement: The tagents-knowledge wrapper without a binary answers join with 69
With no executable binary of the checkout's version at install time the installer SHALL write the `tagents-knowledge` wrapper with no line that names a binary: it exits 69 when its only argument is `join`, and otherwise `exec`s the node program with the wrapper's arguments. A failed or refused fetch, a version without a release and `TAGENTS_NO_NATIVE=1` SHALL each leave that wrapper, so no machine is without a knowledge server and a machine without the binary starts no node for the probe.

#### Scenario: No binary
- **WHEN** the installer runs on a machine without the binary and `tagents-knowledge join` runs with a stub `node` on `PATH`
- **THEN** it exits 69, the stub was not started, and `tagents-knowledge serve` runs the node program (`tests/install.sh`)

#### Scenario: No release for the version
- **WHEN** the installer runs on a copy whose version has no release
- **THEN** the prebuilt binary is removed and `tagents-knowledge serve` runs the node program (`tests/install.sh`)
