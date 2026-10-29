## ADDED Requirements

### Requirement: A release is made from a version tag on main and never overwritten
A release of `tagents-core` SHALL be made only from a tag `v<version>` on a commit of `main` whose workspace version is `<version>`, and a release that already exists SHALL NOT be replaced: a mistake is corrected by a new version.

#### Scenario: A tag that is not the version of its commit
- **WHEN** the tag `v0.2.0` is pushed on a commit whose workspace version is `0.1.0`
- **THEN** `core-release.sh verify` fails (`tests/release.sh`, the tag rules), the verify job fails and nothing is published

#### Scenario: A commit that is not on main
- **WHEN** the tag `v0.1.0` is pushed on a commit that is not an ancestor of `origin/main`
- **THEN** `core-release.sh verify` fails (`tests/release.sh`, the tag rules), the verify job fails and nothing is published

#### Scenario: A tag that has a release already
- **WHEN** the release workflow runs for a tag whose release exists
- **THEN** the verify job fails at the step "No release exists for the tag" and the release is left as it is

### Requirement: A release holds one archive and one checksum per target
For each of `aarch64-apple-darwin`, `x86_64-apple-darwin` and `x86_64-unknown-linux-musl` a release SHALL hold exactly two files: `tagents-core-<version>-<target>.tar.gz`, whose members are exactly `tagents-core` (mode 755) and `LICENSE`, and `<archive name>.sha256`, one line `<64 lowercase hex>  <archive name>` that `sha256sum -c` and `shasum -a 256 -c` accept.

#### Scenario: The packaged files
- **WHEN** `core-release.sh package 1.2.3 aarch64-apple-darwin <binary> <license> <dir>` runs
- **THEN** `<dir>` holds those two files and nothing else, the archive lists exactly `tagents-core` and `LICENSE` with the binary at mode 755, and `shasum -a 256 -c` accepts the checksum (`tests/release.sh`, the release archive)

#### Scenario: An archive changed after its checksum was written
- **WHEN** one byte is appended to the archive
- **THEN** `shasum -a 256 -c` and `sha256sum -c` reject it (`tests/release.sh`, the release archive)

### Requirement: A change to the binary needs a new version
A pull request that changes an input of the `tagents-core` binary (`Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, `crates/*/Cargo.toml`, `crates/*/build.rs`, `crates/*/src/*`, `spec/cli/*`) SHALL also change the workspace version, so that a binary of version V is always built from the source of version V.

#### Scenario: An input changed and the version did not
- **WHEN** `core-release.sh gate origin/main` runs on a branch that changes `crates/tagents-core/src/lib.rs` and leaves the workspace version of `origin/main`
- **THEN** it exits 1 and names the changed files (`tests/release.sh`, the gate)

#### Scenario: The CLI spec data file alone
- **WHEN** only `spec/cli/tagents-core.json` changes
- **THEN** the gate exits 1, because the file is compiled into the binary (`tests/release.sh`, the gate)

#### Scenario: The version moved, or nothing the binary is built from changed
- **WHEN** the version moves with an input, or only tests, docs, workflows or node files change
- **THEN** the gate exits 0 (`tests/release.sh`, the gate)

### Requirement: The binary states its version
`tagents-core --version`, as the only argument, SHALL print `tagents-core <workspace version>` and a newline on stdout and exit 0. With further arguments it SHALL be forwarded to the node CLI like any word the binary does not serve, and it SHALL NOT be in `spec/cli/tagents-core.json`, so the plugin contract does not move with a version.

#### Scenario: The flag alone
- **WHEN** `tagents-core --version` runs
- **THEN** stdout is `tagents-core ` followed by the workspace version and a newline, stderr is empty and the exit code is 0 (`cargo test -p tagents-core --test front_door`: `version_flag_prints_the_crate_version_and_nothing_else`)

#### Scenario: The flag with more words
- **WHEN** `tagents-core --version x` runs
- **THEN** the node CLI receives `--version x` unchanged (`cargo test -p tagents-core --test front_door`: `version_with_more_words_is_not_the_flag`)

#### Scenario: The contract does not move
- **WHEN** `pnpm plugin:gen` runs after the version moved
- **THEN** `contract.json`, `.claude-plugin/` and `skills/` show no diff (the `contract-stable` gate)
