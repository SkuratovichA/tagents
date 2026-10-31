## Why

A managed install follows `origin/main` and updates itself every day, and the Rust `tagents-core` that `rust-core` added is only used when somebody built it by hand. Making it reach users needs a release path with four properties: an install never ends up without a working `tagents-core`, it never runs a file nobody checked, it does not touch the network when nothing changed, and it never keeps a binary built from a different version of the source than its checkout holds.

## What Changes

- The version in `[workspace.package]` of `Cargo.toml` becomes the identity of the binary (0.0.0 to 0.1.0). A release is the tag `v<version>`, and `tagents-core --version` prints `tagents-core <version>`.
- A gate in CI (`core-release.sh gate`) fails a pull request that changes an input of the binary unless the workspace version is strictly above the one at the merge base, with a message for a version that stayed and one for a version that went down.
- `.github/workflows/release.yml` verifies a tag, builds three targets (`aarch64-apple-darwin`, `x86_64-apple-darwin`, `x86_64-unknown-linux-musl`) and publishes one archive and one `.sha256` file for each. A pull request that changes the workflow, the scripts or an input of the binary runs the builds as a dry run.
- `.github/scripts/core-release.sh` holds the logic (`version`, `package`, `gate`, `verify`); the workflows only call it.
- `install.sh` fetches the archive of the checkout's version after the build, checks it (SHA-256, members, `--version`), and installs it with a marker file. Every failure that is the network's or the machine's leaves the node CLI in use and the run successful; a download that fails its checks installs nothing and ends the run with status 1.
- `tests/release.sh` (new) and an extended `tests/install.sh` prove the script and the installer without GitHub; `docs/architecture/rust-core.md` describes the path.

## Capabilities

### New Capabilities

- `core-release`: how a release of the Rust `tagents-core` is made and what it holds, the rule that a change to the binary changes the version, and the version the binary reports.

### Modified Capabilities

- `claude-code-plugin`: the installer fetches the binary of its checkout's version, checks it, never lets a missing one block the install, and never touches one built by hand.

## Impact

- Code: `Cargo.toml`, `Cargo.lock` (the version only), `crates/tagents-core/src/front_door.rs` (`--version`), `install.sh`, `.github/workflows/release.yml` (new), `.github/workflows/rust.yml`, `.github/scripts/core-release.sh` (new), `tests/release.sh` (new), `tests/install.sh`, `tests/rust-parity.sh`.
- Documents: `docs/architecture/rust-core.md`, `docs/development.md`, `docs/guide/getting-started.md`, and the sentences of `openspec/changes/archive/2026-10-31-rust-core/` that said nothing downloads a binary.
- The generated plugin contract does not change: `--version` is not in `spec/cli/tagents-core.json`, and `pnpm plugin:gen` leaves no diff.
- A machine with no release for its version, or with a binary of its own, behaves as before this change.
- No new dependency: the installer uses `curl`, `tar` and `sha256sum` or `shasum`, which a machine that runs it has.
- Not done: the first tag and release (that needs Sasha's word), signing the archives, a Windows build.
