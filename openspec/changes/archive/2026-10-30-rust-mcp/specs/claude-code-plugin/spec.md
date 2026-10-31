## ADDED Requirements

### Requirement: The tagents-mcp command runs the native server when the binary is installed
When `$TAGENTS_HOME/target/release/tagents-core` is an executable file at install time, the `tagents-mcp` wrapper SHALL run it as `tagents-core mcp` with the wrapper's arguments after the word, and otherwise, or when the binary is gone or not executable at run time, SHALL run the node server. The word SHALL be the only difference from the `tagents-core` wrapper's line, and the pinned node SHALL be handed over as for `tagents-core`.

#### Scenario: The binary is installed
- **WHEN** the binary is installed and `tagents-mcp a b` runs
- **THEN** the binary receives `mcp a b` (`tests/install.sh` section 14)

#### Scenario: Arguments with a space or empty
- **WHEN** `tagents-mcp "a b" ""` runs over an installed binary
- **THEN** the binary receives the word and each argument whole (`tests/install.sh` section 13)

#### Scenario: The binary vanishes after the install
- **WHEN** the file is removed or loses its executable bit
- **THEN** the same wrapper runs the node server (`tests/install.sh` section 13)

### Requirement: The tagents-mcp wrapper without a binary is the node wrapper
With no executable binary at install time the installer SHALL write the `tagents-mcp` wrapper byte for byte as it wrote it before a native server existed, and `plugin.json` SHALL register the same command, `tagents-mcp --contract ${CLAUDE_PLUGIN_ROOT}/contract.json`, in both cases.

#### Scenario: No binary
- **WHEN** the installer runs on a machine without the binary
- **THEN** `tagents-mcp` is the node wrapper and `tagents-mcp a b` runs `packages/mcp/dist/main.js` (`tests/install.sh` section 13)

### Requirement: A machine with no release keeps the node server
`TAGENTS_NO_NATIVE=1`, a failed or refused fetch and a version without a release SHALL leave the `tagents-mcp` wrapper as the node wrapper, so no machine is without a server.

#### Scenario: No release for the version
- **WHEN** the installer runs on a copy whose version has no release
- **THEN** the old binary is removed and `tagents-mcp` runs the node server (`tests/install.sh` section 14)

#### Scenario: Native disabled
- **WHEN** the installer runs with `TAGENTS_NO_NATIVE=1` over an installed binary
- **THEN** the binary is removed and `tagents-mcp` runs the node server (`tests/install.sh` section 14)
