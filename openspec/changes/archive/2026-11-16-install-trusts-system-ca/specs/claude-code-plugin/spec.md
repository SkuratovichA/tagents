## ADDED Requirements

### Requirement: The default build trusts the system CA store
Before the default build, `install.sh` SHALL add `--use-system-ca` to `NODE_OPTIONS` when the `node` on `PATH` accepts that flag, so a TLS proxy whose CA is in the operating system's store does not fail the registry fetches. It SHALL NOT add the flag twice. An overridden build (`TAGENTS_BUILD_CMD`) SHALL run with the environment as before, and the installer SHALL start no node for it.

#### Scenario: A node that accepts the flag
- **WHEN** the default build runs and `node --use-system-ca -e 0` exits 0
- **THEN** the build sees `--use-system-ca` in `NODE_OPTIONS`, after any options the caller had set

#### Scenario: The flag is already there
- **WHEN** the default build runs and `NODE_OPTIONS` already holds `--use-system-ca`
- **THEN** the build sees `--use-system-ca` once

#### Scenario: A node that refuses the flag
- **WHEN** the default build runs and `node --use-system-ca -e 0` exits non-zero
- **THEN** the build sees `NODE_OPTIONS` as the caller left it

#### Scenario: An overridden build
- **WHEN** `TAGENTS_BUILD_CMD` is set
- **THEN** the installer starts no node for this
- **AND** the build sees `NODE_OPTIONS` as the caller left it
