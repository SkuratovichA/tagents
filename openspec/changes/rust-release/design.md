## Context

`rust-core` added a Rust `tagents-core` that `tagents` and the installer's wrapper use when `target/release/tagents-core` is an executable file, and left open how a binary reaches a user. A managed install (`install.sh`) clones `origin/main`, updates itself daily through a LaunchAgent, and rewrites its own script when it moves. The Rust sources and the binary therefore move together only if the binary is tied to the source it was built from.

## Goals / Non-Goals

**Goals:**

- A managed install fetches a checksummed prebuilt `tagents-core` of the version its checkout holds, and runs it.
- An install never ends up without a working `tagents-core`: when the binary cannot be had, the node CLI runs and the run still succeeds.
- Nothing unchecked is installed or run, the network is not touched when nothing changed, and a binary of another version is never kept.
- Everything the CI does is a call to a script that a test runs on a laptop.

**Non-Goals:**

- Cutting the first release: the tag, the release and the first publish need Sasha's word.
- Signing or notarising the archives, a Windows build, a package manager.
- Building anything on a user's machine.

## Decisions

### The workspace version is the identity of the binary

Decision: `version` in `[workspace.package]` of `Cargo.toml` is the only place the version is written. A release is the tag `v<version>`, the assets carry it in their names, `tagents-core --version` prints it, and the installer asks for the release of the version its own `Cargo.toml` holds.

Reason: the installer already has the checkout, so the checkout's `Cargo.toml` tells it which binary matches without a request.

Rejected: a release per push to `main` with a commit-count version, because the checkout would need the count and every merge would publish three archives nobody asked for; a hash of the sources instead of a version, because a hash cannot be typed into a tag or read in a release list.

```toml
[workspace.package]
version = "0.1.0"   # tag v0.1.0, tagents-core --version, tagents-core-0.1.0-<target>.tar.gz
```

### A pull request that changes the binary must raise the version

Decision: `core-release.sh gate <base-ref>` lists the files changed since the merge base, and when one is an input of the binary and the workspace version is not strictly above the one at the merge base (the three numbers are compared one by one, as numbers), it fails, names the files and says whether the version stayed or went down. The inputs are `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, `crates/*/Cargo.toml`, `crates/*/build.rs`, `crates/*/src/*` and `spec/cli/*`. It runs in the `release-path` job of `rust.yml`, on pull requests only.

Reason: without the gate a merge could change the binary and keep its version, and the installer would keep a binary that no longer matches its source.

Rejected: a check that compares the built binary, because it needs a build per pull request for a question the file list answers; leaving it to review, because the whole design depends on this one rule.

```sh
is_input() {
  case $1 in
    Cargo.toml | Cargo.lock | rust-toolchain.toml | crates/*/Cargo.toml | crates/*/build.rs | crates/*/src/* | spec/cli/*) return 0 ;;
    *) return 1 ;;
  esac
}

fork=$(git merge-base "$base" HEAD)
before=$(git show "$fork:Cargo.toml" | version -)
newer "$(version Cargo.toml)" "$before" || fail "the version has to go up from $before"
```

### `tagents-core --version` is answered before anything else, and is not in the spec file

Decision: as the only argument, `--version` prints `tagents-core <CARGO_PKG_VERSION>` and exits 0; with more words it goes to the node CLI like any other. It is not a command in `spec/cli/tagents-core.json`.

Reason: the installer needs one cheap way to ask a downloaded binary which version it is, and the spec file feeds the generated plugin contract, which would then change with every release.

Rejected: a `version` command in the data file, because it moves the contract and the plugin version with each bump.

```rust
const VERSION_LINE: &str = concat!("tagents-core ", env!("CARGO_PKG_VERSION"), "\n");

if args.len() == 1 && args[0] == OsStr::new(VERSION_FLAG) {
    return emit(&Output { stdout: VERSION_LINE.to_owned(), stderr: String::new(), code: sessions::exit::OK });
}
```

### One workflow, a verify job, three builds and a publish job that runs no repository code

Decision: `release.yml` runs on a pushed tag `v[0-9]*`, by hand with the tag as input, and on a pull request that changes it, the scripts or any input of the binary (a dry run; the `pull_request.paths` list, which `tests/release.sh` pins to the inputs the gate knows). `verify` checks the tag against the version, that the commit is on `main`, and that no release of the tag exists. `build` runs on `aarch64-apple-darwin` and `x86_64-apple-darwin` (on the arm64 runner) and `x86_64-unknown-linux-musl`. `publish` is the only job with `contents: write`, checks out nothing and runs `gh release create` on exactly six files. Actions are pinned by commit, `persist-credentials` is off, a pull request run has its own concurrency group so that it cannot displace a release waiting for its turn.

Reason: a token that can write releases must never be in the same job as code from the repository or from a build.

Rejected: `cargo zigbuild` for the Linux target, because a plain `cargo build --target x86_64-unknown-linux-musl` is the smaller change and a link failure is a finding to report, not to paper over; a Rust `xtask` for packaging, because the packaging is `tar` and a hash and a shell test runs it without a Rust build.

```yaml
publish:
  needs: [verify, build]
  if: github.event_name != 'pull_request'
  permissions:
    contents: write
  steps:
    - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
      with: { pattern: 'package-*', merge-multiple: true, path: dist }
    - run: gh release create "$TAG" "$@" --title "$TAG" --generate-notes --verify-tag
```

### Two files per target, and nothing else in them

Decision: `tagents-core-<version>-<target>.tar.gz` holds exactly `tagents-core` (mode 755) and `LICENSE`, and `tagents-core-<version>-<target>.tar.gz.sha256` holds one line `<64 lowercase hex>  <archive name>`. Packaging uses POSIX `tar` options and `COPYFILE_DISABLE=1` so that macOS does not add `._tagents-core` members.

Reason: the installer can accept exactly this shape and refuse everything else, and the checksum file works with `sha256sum -c` and `shasum -a 256 -c` as it is.

Rejected: one `SHA256SUMS` for the whole release, because the installer would have to parse a list it does not control and a single missing line looks like a missing release.

```sh
COPYFILE_DISABLE=1 tar -czf "$out/$name" -C "$stage" tagents-core LICENSE
printf '%s  %s\n' "$(sha256_of "$out/$name")" "$name" > "$out/$name.sha256"
```

### The logic is `core-release.sh`, the workflows only call it

Decision: `.github/scripts/core-release.sh` (POSIX sh) has `version`, `package`, `gate` and `verify`; `tests/release.sh` runs it on throwaway repositories and many shapes of `Cargo.toml`. The installer keeps a second copy of the version reader (`core_version`), because `install.sh` must stay one standalone file that rewrites itself, and `tests/release.sh` runs both readers over the same `Cargo.toml` shapes and compares them.

Reason: a shell script that a test runs is checked on every change, and a step in a YAML file is checked once a release goes wrong.

Rejected: one shared file sourced by both, because the installer cannot rely on a second file being at the revision it is.

```sh
core-release.sh version                        # 0.1.0
core-release.sh gate origin/main               # exit 1 and the files, or 0
core-release.sh verify v0.1.0 origin/main      # the tag rules
```

### The installer fetches after the build, with its own marker

Decision: `fetch_native` runs between the build and the wrappers, never under `--check`. The marker `target/release/tagents-core.release` holds `<version> <target> <sha256 of the binary>`. A binary with no marker was built by hand and is never touched. The fast path (executable file, marker matching version, target and hash) does nothing and makes no request. Any other state of a marked binary is deleted before a request, so a failed request leaves the node CLI in use. A download is checked in this order: the `.sha256` file, the member list, `--version`; then the marker is written first and the binary renamed into place second.

Reason: the marker is the only way to tell a file the installer owns from one a contributor built, and deleting before downloading is what keeps a binary of another version from surviving a bad night.

Rejected: `gh release download`, because it needs a login a managed install does not have; the version in the file name of the binary, because the wrapper names one fixed path.

```sh
if [ -f "$NATIVE_BIN" ] && [ -x "$NATIVE_BIN" ] && [ -f "$marker" ]; then
  read -r v t s rest < "$marker" || true
  [ "$v" = "$version" ] && [ "$t" = "$triple" ] && [ -z "$rest" ] && [ "$s" = "$(sha256_of "$NATIVE_BIN")" ] && return 0
fi
drop_native   # before any request
```

### One page says it all

Decision: `docs/architecture/rust-core.md` holds the release path (identity, gate, workflow, assets, how a release is cut, what happens when `main` is ahead of the last release, and the installer's rules as a table), and the three sentences elsewhere that said nothing downloads a binary are corrected.

Reason: the rules the installer follows are expensive to rediscover from a shell function.

```md
| nothing changed | the binary is executable and the marker names the wanted version, this target and the hash of the binary: no request |
```

## Risks / Trade-offs

- [The checksum proves the transfer, not who published] → the archives are not signed; trust rests on HTTPS to GitHub and on who may create releases. Signing is a later decision.
- [The Linux musl build is not tried until the workflow runs] → the dry run on a pull request builds all three; a link failure is reported, not worked around.
- [A tag pushed by hand can be forgotten after a version bump merges] → a managed copy then has no release for its version and runs the node CLI, which is slower and correct.
- [The installer runs `--version` of a binary whose hash it has only compared with a file from the same release] → the same trust as the line above; the check catches a wrong version, not a hostile one.
- [`x86_64-apple-darwin` is built on an arm64 runner and not run] → it is checked for its checksum and shape only; the first Intel Mac to install it is the test.

## Migration Plan

1. Merge this change. No release exists, so every installer finds nothing to fetch and says so; behaviour is unchanged.
2. A version bump lands on `main` and its tag `v0.1.0` is pushed; the next daily update of each managed copy at that commit installs the binary.
3. Rollback is `TAGENTS_NO_NATIVE=1` on one machine (the binary and its marker go at the next install), or deleting the release (the next install finds none and removes the binary).

## Open Questions

- Who pushes the tag after a bump merges, and whether a later change should do it from the merge itself.
- Whether the archives should be signed or attested, and with what.
