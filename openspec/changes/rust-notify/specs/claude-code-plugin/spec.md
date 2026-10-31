## ADDED Requirements

### Requirement: The tagents-notify command runs the native service for run when the binary is installed
When `$TAGENTS_HOME/target/release/tagents-core` is an executable file of the checkout's version at install time, the `tagents-notify` wrapper SHALL run it as `tagents-core notify run` when its arguments are exactly `run`, and in every other case, or when the binary is gone or not executable at run time, SHALL run the node program with the wrapper's arguments. The pinned node SHALL be handed over as for `tagents-core`.

#### Scenario: The binary is installed
- **WHEN** the binary is installed and `tagents-notify run` runs
- **THEN** the binary receives `notify run` (`tests/install.sh`)

#### Scenario: Any other arguments
- **WHEN** `tagents-notify status`, `tagents-notify run extra` or `tagents-notify` runs over an installed binary
- **THEN** the node program receives the arguments whole (`tests/install.sh`)

#### Scenario: The binary vanishes after the install
- **WHEN** the file is removed or loses its executable bit
- **THEN** the same wrapper runs the node program for `run` as well (`tests/install.sh`)

#### Scenario: A binary of another version
- **WHEN** the binary in the tree says a version other than the checkout's, or cannot say
- **THEN** the wrapper is written without it and `tagents-notify run` runs the node program (`tests/install.sh`)

### Requirement: The tagents-notify wrapper without a binary is the node wrapper
With no executable binary of the checkout's version at install time the installer SHALL write the `tagents-notify` wrapper with no line that names a binary, so that its one command is the `exec` of the node program with the wrapper's arguments, and every verb of `tagents-notify` other than `run` SHALL reach the node program in both cases.

#### Scenario: No binary
- **WHEN** the installer runs on a machine without the binary
- **THEN** `tagents-notify` is the node wrapper and `tagents-notify run` runs `packages/notify/dist/main.js` (`tests/install.sh`)

### Requirement: A machine with no release keeps the node service
`TAGENTS_NO_NATIVE=1`, a failed or refused fetch and a version without a release SHALL leave the `tagents-notify` wrapper as the node wrapper, so no machine is without a service and a LaunchAgent that names the wrapper starts the node service.

#### Scenario: No release for the version
- **WHEN** the installer runs on a copy whose version has no release
- **THEN** the old binary is removed and `tagents-notify run` runs the node program (`tests/install.sh`)

#### Scenario: Native disabled
- **WHEN** the installer runs with `TAGENTS_NO_NATIVE=1` over an installed binary
- **THEN** the binary is removed and `tagents-notify run` runs the node program (`tests/install.sh`)
