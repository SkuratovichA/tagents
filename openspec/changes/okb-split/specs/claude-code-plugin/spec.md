## MODIFIED Requirements

### Requirement: The plugin registers the knowledge MCP server
The plugin manifest SHALL register an MCP server `knowledge`, started as the command `sh` with the argument `${CLAUDE_PLUGIN_ROOT}/bin/knowledge-mcp`. The tools it offers are those of the `knowledge` capability. A server of the same kind registered by hand with `claude mcp add` SHALL be removed, or the tools appear twice. The manifest registers one more server, `tagents`, which another requirement specifies.

#### Scenario: Registered by the manifest
- **WHEN** the plugin is installed and a session starts
- **THEN** a `knowledge` MCP server is started with `sh ${CLAUDE_PLUGIN_ROOT}/bin/knowledge-mcp`

#### Scenario: Registered twice
- **WHEN** a hand-made registration of the same server exists as well
- **THEN** its tools appear twice

### Requirement: The server entry falls back to a server of its own
The script `bin/knowledge-mcp` SHALL join the session to the shared server of the `knowledge` capability. When `tagents-knowledge join` exits 0 on empty input it SHALL replace itself with `tagents-knowledge join`. After any other code it SHALL go on to `tagents-knowledge serve` and, when that prints an existing socket and `nc` is available, replace itself with `nc -U` on it, and else run `tagents-knowledge mcp`. With no binary both give the needs-binary line and exit 69.

#### Scenario: The native program is installed
- **WHEN** `tagents-knowledge join` exits 0 on empty input
- **THEN** the process the session started is `tagents-knowledge join`, nothing is written to standard error, and no node program and no `nc` runs

#### Scenario: A plugin older than the install
- **WHEN** the wrapper is called with `serve` or `mcp` by a plugin that predates `join`
- **THEN** the wrapper accepts both words and hands them to the binary (`tests/install.sh`)

#### Scenario: No binary
- **WHEN** `join` exits 69 or 2 and the machine has no binary
- **THEN** `serve` and `mcp` answer one line that names `tagents update` and `cargo build --release -p okb`, with exit 69, and no daemon is started (`tests/knowledge-launcher.sh`)

#### Scenario: Shared server available
- **WHEN** `join` exits 69 or 2, `tagents-knowledge serve` prints an existing socket and `nc` is on `PATH`
- **THEN** the process the session started is `nc -U` on that socket, and nothing is written to standard error

#### Scenario: No shared server
- **WHEN** `join` exits 69 or 2 and `serve` fails or there is no `nc`
- **THEN** the session gets `tagents-knowledge mcp`, which is the binary's when one is installed, and nothing is written to standard error

### Requirement: The server entry names the failure of the native program
After `tagents-knowledge join` exits with a code other than 0, 69 and 2, the script `bin/knowledge-mcp` SHALL write one line naming the code to its standard error before it goes on to `serve` and `mcp`. After 0, 69 and 2 it SHALL write nothing.

#### Scenario: The native program failed
- **WHEN** `join` exits 1, 3 or 127
- **THEN** exactly one line naming that code is written to standard error, and the script goes on to the binary's `serve` and `mcp` (`tests/knowledge-launcher.sh`)

### Requirement: The node commands run with the node that installed them
`install.sh` SHALL write into `tagents-core`, `tagents-notify` and `tagents-mcp`, the three commands it installs that run a node program, the absolute path of the `node` the installing shell finds on its `PATH`, and SHALL write it again on every install and every `tagents update`. Each of the three SHALL run that node while it is an executable file, and otherwise the `node` on the caller's `PATH`.

#### Scenario: A caller whose PATH holds no node
- **WHEN** tagents was installed from a shell that finds node at `/opt/node/bin/node`, and a process whose `PATH` is `/usr/bin:/bin` runs `tagents-core plugin list`
- **THEN** the command runs on `/opt/node/bin/node`

#### Scenario: The pinned node is gone
- **WHEN** the node the commands were installed with has been removed, and a process whose `PATH` finds another node runs `tagents-core`
- **THEN** the command runs on the node found on that `PATH`

#### Scenario: Installed from a shell that finds no node
- **WHEN** the installing shell finds no node on its `PATH`, or finds it by a path that is not absolute
- **THEN** all four commands look node up on the caller's `PATH`

#### Scenario: An update from a shell with another node
- **WHEN** `tagents update` runs from a shell whose `PATH` finds node somewhere else
- **THEN** all four commands run on that node from then on

#### Scenario: The notifier and the tool server
- **WHEN** tagents was installed from a shell that finds node at `/opt/node/bin/node`
- **THEN** `tagents-notify` and `tagents-mcp` each pin that node

### Requirement: The installer writes wrappers, not symlinks
`install.sh` SHALL write a real-file wrapper into `~/.local/bin` for each of `tagents`, `tusage`, `tnotes`, `tagents-core`, `okb`, `tagents-knowledge`, `tagents-notify` and `tagents-mcp`, and one per `hooks/*.sh` into `~/.claude/hooks` or each repeatable `--hooks-dir DIR`; a wrapper runs the same file of the managed copy.

#### Scenario: Two Claude config directories
- **WHEN** `install.sh --hooks-dir ~/.claude/hooks --hooks-dir ~/.claude-work/hooks` runs
- **THEN** both directories hold a wrapper for every hook script

#### Scenario: A file of somebody else's
- **WHEN** `~/.local/bin/tusage` exists and was not written by the installer
- **THEN** it is left as it was, a warning names it, and the exit code is 1

#### Scenario: A hook the project dropped
- **WHEN** an update brings a copy that no longer ships `hooks/old.sh`, and `~/.claude/hooks/old.sh` is a wrapper of the installer
- **THEN** that wrapper is removed

#### Scenario: The commands the tools run
- **WHEN** `install.sh` finishes a build
- **THEN** `tagents-notify` and `tagents-mcp` exist in `~/.local/bin` beside `tagents-core`

### Requirement: Node answers a retired verb with the needs-binary line
The node CLI SHALL answer `session`, `sessions` (any word after it), `doctor`, `plugin add`, `plugin remove`, `plugin new` and `mcp`, which the file `spec/cli/tagents-core.json` marks `impl: "rust"`, with one line on standard error that names `tagents update` and `cargo build --release -p tagents-core`, nothing on standard output and exit 69. The set SHALL be read from the file, so it cannot drift from it. `tagents-notify run` SHALL answer the same way.

#### Scenario: A machine with no binary
- **WHEN** `node packages/core/dist/cli/main.js session list` runs
- **THEN** one line names `tagents update` and `cargo build --release -p tagents-core`, and the exit code is 69 (`packages/core/test`)

#### Scenario: A verb node still hosts
- **WHEN** `plugin list` or an unknown word runs
- **THEN** node answers it as before

## REMOVED Requirements

### Requirement: The tagents-knowledge command runs the native server for join, mcp and serve when the binary is installed
**Reason**: `tagents-knowledge` is no longer a node program that picks between the binary and node; it is the `okb` command under its old name.
**Migration**: The `okb` command and the `tagents-knowledge` wrapper requirements below.

### Requirement: The tagents-knowledge wrapper without a binary answers join with 69
**Reason**: With the node knowledge package gone there is no node program for the wrapper to fall back on.
**Migration**: The `okb` command without a binary answers every call with the needs-binary line and exit 69.

## ADDED Requirements

### Requirement: The okb command runs the native binary
When `$TAGENTS_HOME/target/release/okb` is an executable file at install time, the installer SHALL write an `okb` wrapper into `~/.local/bin` that runs it with the wrapper's arguments, whole. With no executable binary the wrapper SHALL print one line on standard error that names `tagents update` and `cargo build --release -p okb`, nothing on standard output, and exit 69. The wrapper SHALL NOT read `TAGENTS_NO_NATIVE` when it runs.

#### Scenario: The binary is installed
- **WHEN** the binary is installed and `okb search x`, `okb join` or `okb serve --idle 30` runs
- **THEN** the binary receives those arguments whole (`tests/install.sh`)

#### Scenario: No binary
- **WHEN** the installer runs on a machine without the binary and `okb join` runs
- **THEN** it exits 69, writes the needs-binary line and starts no other program (`tests/install.sh`)

#### Scenario: The binary vanishes after the install
- **WHEN** the file is removed or loses its executable bit
- **THEN** every call of the wrapper gives the needs-binary line and exit 69 (`tests/install.sh`)

### Requirement: The installer provides the okb binary
The installer SHALL fetch the `okb` binary from the release of the checkout's version in the way it fetches `tagents-core`, from the archive `okb-<version>-<triple>.tar.gz` of that release. The installer SHALL NOT run cargo: with no release for the version, or with an archive that fails its checksum, it keeps the `okb` it already has, warns, and still installs the other binary; building it is `cargo build --release -p okb` by hand.

#### Scenario: A release exists
- **WHEN** the installer runs on a copy whose version has a release
- **THEN** `target/release/okb` is the binary of that release and `okb --version` says the version (`tests/install.sh`)

### Requirement: The tagents-knowledge command is okb
The `tagents-knowledge` wrapper SHALL run `okb` with the wrapper's arguments, whole, and its exit code and output SHALL be okb's, so that a plugin installed before the split, a script and a person who types the old name keep working.

#### Scenario: The old name
- **WHEN** `tagents-knowledge serve --idle 30` or `tagents-knowledge search x` runs over an installed binary
- **THEN** `okb` receives `serve --idle 30` or `search x`, whole (`tests/install.sh`)

#### Scenario: A plugin that predates the split
- **WHEN** the plugin's launcher calls `tagents-knowledge join`, `serve` or `mcp`
- **THEN** the call is okb's and the launcher's fallbacks behave as before (`tests/knowledge-launcher.sh`)

### Requirement: The launcher lives at the root of the plugin
The launcher the manifest starts SHALL be the script `bin/knowledge-mcp` at the root of the checkout, so that it is shipped with the plugin when the package that held it is gone. The digest of the plugin SHALL cover it.

#### Scenario: The manifest names the launcher
- **WHEN** `.claude-plugin/plugin.json` is read
- **THEN** the `knowledge` server runs `sh ${CLAUDE_PLUGIN_ROOT}/bin/knowledge-mcp` and the file exists (`packages/contract` tests)

### Requirement: okb is a plugin of its own and tagents depends on it
The marketplace SHALL list a second plugin `okb`, whose manifest is `plugins/okb/.claude-plugin/plugin.json` and which registers the MCP server `knowledge` through `plugins/okb/bin/okb-mcp`. The `tagents` plugin SHALL declare `"dependencies": ["okb"]` with no version range and register the MCP server `tagents` only. `claude plugin validate --strict` SHALL accept both manifests. This is the second pull request of the change.

#### Scenario: One install brings both
- **WHEN** `claude plugin install tagents@tagents` runs
- **THEN** the `okb` plugin is installed as well and the tools `mcp__plugin_okb_knowledge__knowledge_search`, `knowledge_get`, `knowledge_list` and `knowledge_usage` exist (CI `claude plugin validate`, `tests/knowledge-launcher.sh`)

#### Scenario: The okb plugin alone
- **WHEN** only `okb@tagents` is installed
- **THEN** the knowledge tools work and no tagents tool exists
