## MODIFIED Requirements

### Requirement: The server entry falls back to a server of its own
The script `packages/knowledge/bin/knowledge-mcp` SHALL join the session to the shared server of the `knowledge` capability. When `tagents-knowledge join` exits 0 on empty input it SHALL replace itself with `tagents-knowledge join`. After any other code it SHALL go on to `tagents-knowledge serve` and, when that prints an existing socket and `nc` is available, replace itself with `nc -U` on it, and else run `tagents-knowledge mcp`. Node answers neither `serve` nor `mcp` any more: on a machine with no binary both give the needs-binary line and exit 69, and the session has no knowledge server.

#### Scenario: The native program is installed
- **WHEN** `tagents-knowledge join` exits 0 on empty input
- **THEN** the process the session started is `tagents-knowledge join`, nothing is written to standard error, and no node program and no `nc` runs

#### Scenario: A plugin older than the install
- **WHEN** the wrapper is called with `serve` or `mcp` by a plugin that predates `join`
- **THEN** the wrapper accepts both words and hands them to the binary (`tests/install.sh`)

#### Scenario: No binary
- **WHEN** `join` exits 69 or 2 and the machine has no binary
- **THEN** `serve` and `mcp` answer one line that names `tagents update` and `cargo build --release -p tagents-core`, with exit 69, and no daemon is started (`tests/knowledge-launcher.sh`)

#### Scenario: Shared server available
- **WHEN** `join` exits 69 or 2, `tagents-knowledge serve` prints an existing socket and `nc` is on `PATH`
- **THEN** the process the session started is `nc -U` on that socket, and nothing is written to standard error

#### Scenario: No shared server
- **WHEN** `join` exits 69 or 2 and `serve` fails or there is no `nc`
- **THEN** the session gets `tagents-knowledge mcp`, which is the binary's when one is installed, and nothing is written to standard error

### Requirement: The tagents-mcp command runs the native server when the binary is installed
When `$TAGENTS_HOME/target/release/tagents-core` is an executable file at install time, the `tagents-mcp` wrapper SHALL run it as `tagents-core mcp` with the wrapper's arguments after the word, whatever version it says, and otherwise, or when the binary is gone or not executable at run time, SHALL run the node CLI with the word `mcp` before the arguments, which answers the needs-binary line and exit 69. The pinned node SHALL be handed over as for `tagents-core`.

#### Scenario: The binary is installed
- **WHEN** the binary is installed and `tagents-mcp a b` runs
- **THEN** the binary receives `mcp a b` (`tests/install.sh` section 14)

#### Scenario: Arguments with a space or empty
- **WHEN** `tagents-mcp "a b" ""` runs over an installed binary
- **THEN** the binary receives the word and each argument whole (`tests/install.sh` section 13)

#### Scenario: The binary vanishes after the install
- **WHEN** the file is removed or loses its executable bit
- **THEN** the same wrapper runs `node packages/core/dist/cli/main.js mcp`, which exits 69 with the needs-binary line (`tests/install.sh` section 13)

### Requirement: The tagents-mcp wrapper without a binary is the node wrapper
With no executable binary at install time the installer SHALL write the `tagents-mcp` wrapper so that its last line runs the node CLI with `mcp`, and `plugin.json` SHALL register the same command, `tagents-mcp --contract ${CLAUDE_PLUGIN_ROOT}/contract.json`, in both cases.

#### Scenario: No binary
- **WHEN** the installer runs on a machine without the binary
- **THEN** `tagents-mcp a b` runs `packages/core/dist/cli/main.js mcp a b` (`tests/install.sh` section 13)

### Requirement: A machine with no release keeps the node server
A failed or refused fetch and a version without a release SHALL leave the installed binary in place and say so; with no binary at all the installer SHALL warn which verbs will not work. No path of the fetch removes a binary unless `TAGENTS_NO_NATIVE=1` asks for it, and that variable SHALL remove only a prebuilt binary, the one the installer fetched with its release marker: a binary built on the machine is left in place. The name of the requirement is kept for the archive; the node server is gone, and what the machine keeps is the binary.

#### Scenario: No release for the version
- **WHEN** the installer runs on a copy whose version has no release, over an installed binary
- **THEN** the binary stays, the wrappers name it, and one line says the old binary is kept (`tests/install.sh` section 14)

#### Scenario: No release and no binary
- **WHEN** the installer runs on a copy whose version has no release and the machine has no binary
- **THEN** one warning names the verbs that will not work and the two ways to get a binary (`tests/install.sh`)

#### Scenario: Native disabled
- **WHEN** the installer runs with `TAGENTS_NO_NATIVE=1` over an installed prebuilt binary
- **THEN** the binary is removed (`tests/install.sh` section 14)

#### Scenario: Native disabled over a binary built on the machine
- **WHEN** the installer runs with `TAGENTS_NO_NATIVE=1` over a binary built on the machine, with no release marker
- **THEN** the binary is not removed (`tests/install.sh`, "a binary built by hand is not ours")

### Requirement: The tagents-notify command runs the native service for run when the binary is installed
When `$TAGENTS_HOME/target/release/tagents-core` is an executable file at install time, the `tagents-notify` wrapper SHALL run it as `tagents-core notify run` when its arguments are exactly `run`, and in every other case, or when the binary is gone or not executable at run time, SHALL run the node program with the wrapper's arguments, which for `run` answers the needs-binary line and exit 69. The pinned node SHALL be handed over as for `tagents-core`.

#### Scenario: The binary is installed
- **WHEN** the binary is installed and `tagents-notify run` runs
- **THEN** the binary receives `notify run` (`tests/install.sh`)

#### Scenario: Any other arguments
- **WHEN** `tagents-notify status`, `tagents-notify run extra` or `tagents-notify` runs over an installed binary
- **THEN** the node program receives the arguments whole (`tests/install.sh`)

#### Scenario: The binary vanishes after the install
- **WHEN** the file is removed or loses its executable bit
- **THEN** the same wrapper runs the node program, and `run` ends with exit 69 (`tests/install.sh`)

#### Scenario: A binary of another version
- **WHEN** the binary in the tree says a version other than the checkout's
- **THEN** the wrapper still names it: a stale binary is better than none (`tests/install.sh`)

### Requirement: The tagents-notify wrapper without a binary is the node wrapper
With no executable binary at install time the installer SHALL write the `tagents-notify` wrapper with no line that names a binary, so that its one command is the `exec` of the node program with the wrapper's arguments, and every verb of `tagents-notify` other than `run` SHALL reach the node program in both cases.

#### Scenario: No binary
- **WHEN** the installer runs on a machine without the binary
- **THEN** `tagents-notify` is the node wrapper and `tagents-notify run` answers the needs-binary line with exit 69 (`tests/install.sh`)

### Requirement: A machine with no release keeps the node service
A failed or refused fetch and a version without a release SHALL leave the `tagents-notify` wrapper naming the binary the machine already has, and `TAGENTS_NO_NATIVE=1` SHALL remove only a prebuilt binary, as "A machine with no release keeps the node server" says. A LaunchAgent that names the wrapper starts the binary's service.

#### Scenario: No release for the version
- **WHEN** the installer runs on a copy whose version has no release, over an installed binary
- **THEN** `tagents-notify run` still runs the binary (`tests/install.sh`)

#### Scenario: Native disabled over a binary built on the machine
- **WHEN** the installer runs with `TAGENTS_NO_NATIVE=1` over a binary built on the machine, with no release marker
- **THEN** the binary is not removed (`tests/install.sh`, "a binary built by hand is not ours")

#### Scenario: Native disabled
- **WHEN** the installer runs with `TAGENTS_NO_NATIVE=1` over an installed prebuilt binary
- **THEN** the binary is removed and `tagents-notify run` gives the needs-binary line (`tests/install.sh` section 14)

### Requirement: The server entry names the failure of the native program
After `tagents-knowledge join` exits with a code other than 0, 69 and 2, the script `packages/knowledge/bin/knowledge-mcp` SHALL write one line naming the code to its standard error before it goes on to `serve` and `mcp`. After 0, 69 and 2 it SHALL write nothing.

#### Scenario: The native program failed
- **WHEN** `join` exits 1, 3 or 127
- **THEN** exactly one line naming that code is written to standard error, and the script goes on to the binary's `serve` and `mcp` (`tests/knowledge-launcher.sh`)

### Requirement: The tagents-knowledge command runs the native server for join, mcp and serve when the binary is installed
When `$TAGENTS_HOME/target/release/tagents-core` is an executable file at install time, the `tagents-knowledge` wrapper SHALL run it as `tagents-core knowledge <word>` for `join` or `mcp` alone and for `serve` with any arguments. Every other call, and every call once the binary is gone or not executable, SHALL run the node program, except that `join` alone then exits 69 and starts nothing. The wrapper SHALL NOT read `TAGENTS_NO_NATIVE` when it runs. The pinned node is handed over as for `tagents-core`.

#### Scenario: The binary is installed
- **WHEN** the binary is installed and `tagents-knowledge join`, `mcp` or `serve` runs
- **THEN** the binary receives `knowledge` and that word (`tests/install.sh`)

#### Scenario: serve with options
- **WHEN** `tagents-knowledge serve --idle 30` or `serve --foreground --socket P` runs over an installed binary
- **THEN** the binary receives `knowledge serve` and the options, whole (`tests/install.sh`)

#### Scenario: Any other arguments
- **WHEN** `tagents-knowledge mcp extra`, `join x`, `search x` or no arguments runs over an installed binary
- **THEN** the node program receives the arguments whole (`tests/install.sh`)

#### Scenario: The binary vanishes after the install
- **WHEN** the file is removed or loses its executable bit
- **THEN** `join` exits 69 and starts no program, and `serve` and `mcp` run the node program, which answers the needs-binary line and exit 69 (`tests/install.sh`)

#### Scenario: A binary of another version
- **WHEN** the binary in the tree says a version other than the checkout's, or cannot say
- **THEN** the wrapper still names it (`tests/install.sh`)

### Requirement: The tagents-knowledge wrapper without a binary answers join with 69
With no executable binary at install time the installer SHALL write the `tagents-knowledge` wrapper with no line that names a binary: it exits 69 when its only argument is `join`, and otherwise `exec`s the node program with the wrapper's arguments, so a machine without the binary starts no node for the probe. A failed or refused fetch and a version without a release leave an installed binary named, and the wrapper without one only when the machine has none.

#### Scenario: No binary
- **WHEN** the installer runs on a machine without the binary and `tagents-knowledge join` runs with a stub `node` on `PATH`
- **THEN** it exits 69, the stub was not started, and `tagents-knowledge serve` runs the node program, which exits 69 with the needs-binary line (`tests/install.sh`)

#### Scenario: No release for the version
- **WHEN** the installer runs on a copy whose version has no release, over an installed binary
- **THEN** the binary is kept and `tagents-knowledge serve` runs it (`tests/install.sh`)

## REMOVED Requirements

### Requirement: A failed probe turns the Rust server off for the rest of the run
**Reason**: Node no longer has a server for the launcher to fall back to; after a failed probe the launcher goes on to the binary's own `serve` and `mcp`.
**Migration**: The script sets nothing; the failed program is told apart by the line "The server entry names the failure of the native program" requires.

### Requirement: TAGENTS_NO_NATIVE=1 leaves the knowledge wrapper without the binary
**Reason**: With no node server, turning the binary off for a session leaves the session with nothing; `TAGENTS_NO_NATIVE=1` now acts at install time only.
**Migration**: `TAGENTS_NO_NATIVE=1 tagents update` removes a prebuilt binary; a wrapper never reads the variable when it runs.

## ADDED Requirements

### Requirement: Node answers a retired verb with the needs-binary line
The node CLI SHALL answer `session`, `sessions` (any word after it), `doctor`, `plugin add`, `plugin remove`, `plugin new` and `mcp`, which the file `spec/cli/tagents-core.json` marks `impl: "rust"`, with one line on standard error that names `tagents update` and `cargo build --release -p tagents-core`, nothing on standard output and exit 69. The set SHALL be read from the file, so it cannot drift from it. `tagents-knowledge serve` and `mcp` and `tagents-notify run` SHALL answer the same way.

#### Scenario: A machine with no binary
- **WHEN** `node packages/core/dist/cli/main.js session list` runs
- **THEN** one line names `tagents update` and `cargo build --release -p tagents-core`, and the exit code is 69 (`packages/core/test`)

#### Scenario: A verb node still hosts
- **WHEN** `plugin list` or an unknown word runs
- **THEN** node answers it as before

### Requirement: A LaunchAgent written before the wrapper existed still starts the service
`node packages/notify/dist/main.js run` SHALL start `target/release/tagents-core notify run` as a child with inherited standard streams and pass SIGTERM and SIGINT on, or print the needs-binary line and exit 69 when the binary is missing. `tagents notify install` SHALL always write the `tagents-notify` wrapper into the plist, and `run` SHALL not be a node service any more.

#### Scenario: The binary is there
- **WHEN** the old command runs and the binary exists
- **THEN** the child runs with the same standard streams and its exit code is the command's (`packages/notify/test/run-binary.test.ts`)

#### Scenario: No binary
- **WHEN** the old command runs and the binary is missing
- **THEN** the needs-binary line is written and the exit code is 69 (`packages/notify/test/commands.test.ts`)
