## ADDED Requirements

### Requirement: The installer installs the tagents-core of its version
After the build, and never under `--check`, `install.sh` SHALL install the prebuilt `tagents-core` of the version in `$TAGENTS_HOME/Cargo.toml` from the GitHub release `v<version>` into `target/release/`, with a marker `tagents-core.release` holding `<version> <target> <sha256 of the binary>`. A binary that matches its marker, that version and this target SHALL cause no request.

#### Scenario: A first install
- **WHEN** the installer runs on a copy whose release exists
- **THEN** the binary and the marker are installed, the `tagents-core` wrapper names the binary, and `tagents-core a b` runs it (`tests/install.sh` section 14)

#### Scenario: The same version again
- **WHEN** the installer runs again and the release directory cannot be reached
- **THEN** it exits 0 without a request and the binary and the marker are the same files (`tests/install.sh` section 14)

#### Scenario: The version moves
- **WHEN** the copy moves to a version whose release exists
- **THEN** the binary and the marker are those of the new version (`tests/install.sh` section 14)

#### Scenario: A check
- **WHEN** the installer runs with `--check`
- **THEN** it makes no request and leaves the binary and the marker as they are (`tests/install.sh` section 14)

### Requirement: A downloaded tagents-core is checked before it is installed
A download SHALL be installed only when the first field of its `.sha256` file is 64 lowercase hex digits equal to the archive's SHA-256, the archive lists exactly `tagents-core` and `LICENSE`, and the extracted `tagents-core` is a regular file whose `--version` prints exactly `tagents-core <version>`. Any other outcome SHALL install nothing, warn, write the wrappers and end the run with status 1.

#### Scenario: A checksum that is not the archive's
- **WHEN** the archive was changed after its checksum was written, or the checksum file names another hash
- **THEN** nothing is installed, any older binary is gone, the warning names the hashes, the wrappers are written and the run exits 1 (`tests/install.sh` section 14)

#### Scenario: A checksum file that is not a SHA-256
- **WHEN** its first field is not 64 lowercase hex digits
- **THEN** nothing is installed and the run exits 1 (`tests/install.sh` section 14)

#### Scenario: An archive that holds more or less than two files
- **WHEN** the archive has a third member, lacks `LICENSE`, has a member outside its directory, or its `tagents-core` is a symbolic link
- **THEN** nothing is installed and the run exits 1 (`tests/install.sh` section 14)

#### Scenario: A binary of another version
- **WHEN** the extracted binary's `--version` is not `tagents-core <version>`
- **THEN** nothing is installed and the run exits 1 (`tests/install.sh` section 14)

### Requirement: A release is fetched only over https or from a file
When a prebuilt tagents-core has to be fetched, `TAGENTS_CORE_BASE_URL`, if set, SHALL start with `https://` or `file://`. Any other value SHALL make no request, install nothing, warn naming the variable and end the run with status 1.

#### Scenario: A base that is not https or file is refused
- **WHEN** a fetch is due and `TAGENTS_CORE_BASE_URL` does not start with `https://` or `file://` (`http://`, `ftp://`, a path, `/`)
- **THEN** no request is made, nothing is installed, the warning names the variable and the run exits 1 (`tests/install.sh` section 14)

### Requirement: A tagents-core that cannot be had never blocks the install
When the release of the version does not exist, the network or `curl` is missing, no SHA-256 tool exists or the machine has no prebuilt target, `install.sh` SHALL say so in one line, leave the node CLI in use and exit as it would without the binary. A marked binary of another version, target or hash SHALL be deleted before any request, so a failed request leaves none of another version.

#### Scenario: The version has no release
- **WHEN** the copy moves to a version with no release, with a marked binary of the old version in place
- **THEN** the binary and its marker are gone, one line names the version, the target and the URL, the run exits 0 and the wrapper runs the node CLI (`tests/install.sh` section 14)

#### Scenario: A machine with no prebuilt target
- **WHEN** the target is not one of the three (a `TAGENTS_CORE_TARGET` or the output of `uname`)
- **THEN** one line says so, no request is made and the run exits 0 (`tests/install.sh` section 14)

#### Scenario: No curl
- **WHEN** `curl` is not on `PATH`
- **THEN** one line says so, the run exits 0, and a binary that already matches its marker is kept (`tests/install.sh` section 14)

### Requirement: A tagents-core built by hand is never touched
A `target/release/tagents-core` with no marker SHALL be neither replaced, deleted nor shadowed by a download, whatever the version, and `TAGENTS_NO_NATIVE=1` SHALL remove only a binary that has a marker.

#### Scenario: A hand-built binary
- **WHEN** the installer runs over an executable `target/release/tagents-core` that has no marker
- **THEN** it makes no request, leaves the file as it is, and the wrapper names it (`tests/install.sh` section 14)

#### Scenario: Turning the prebuilt binary off
- **WHEN** the installer runs with `TAGENTS_NO_NATIVE=1`
- **THEN** a marked binary and its marker are removed and the node CLI runs, and a binary with no marker stays (`tests/install.sh` section 14)
