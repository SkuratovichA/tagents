## ADDED Requirements

### Requirement: The build trusts the system CA store
Before the build, `install.sh` SHALL add `--use-system-ca` to `NODE_OPTIONS` when the `node` on `PATH` accepts that flag, so a TLS proxy whose CA is in the operating system's store does not fail the registry fetches. It SHALL leave `NODE_OPTIONS` as it was when `node` refuses the flag or is not on `PATH`, and SHALL NOT add the flag to a `NODE_OPTIONS` that already holds it.

#### Scenario: A node that accepts the flag
- **WHEN** the build runs and `node --use-system-ca -e 0` exits 0
- **THEN** the build sees `--use-system-ca` in `NODE_OPTIONS`, after any options the caller had set

#### Scenario: The flag is already there
- **WHEN** the build runs and `NODE_OPTIONS` already holds `--use-system-ca`
- **THEN** the build sees `--use-system-ca` once

#### Scenario: A node that refuses the flag
- **WHEN** the build runs and `node --use-system-ca -e 0` exits non-zero
- **THEN** the build sees `NODE_OPTIONS` as the caller left it
