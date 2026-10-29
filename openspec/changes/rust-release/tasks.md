## 1. The binary and its version

- [x] 1.1 Bump `[workspace.package]` to 0.1.0 and let cargo update `Cargo.lock` (`cargo build --locked`)
- [x] 1.2 `tagents-core --version` as the only argument prints `tagents-core <version>`, exit 0; with more words it is forwarded (`cargo test -p tagents-core --test front_door`: the two `version_` tests)
- [x] 1.3 The plugin contract does not move (`contract-stable`)

## 2. The release script and its tests

- [x] 2.1 `.github/scripts/core-release.sh`: `version`, `package`, `gate`, `verify` (`shellcheck -s sh`, runs under `dash`)
- [x] 2.2 `tests/release.sh`: the version over many shapes of `Cargo.toml` and against the copy in `install.sh`, the archive and its checksum, the gate, the tag rules
- [x] 2.3 Mutations of the script each make `tests/release.sh` fail: package mode 644, `spec/cli/*` dropped from the inputs, `COPYFILE_DISABLE` removed

## 3. The workflows

- [x] 3.1 `.github/workflows/release.yml`: verify, three builds, publish, dry run on a pull request (`actionlint`)
- [x] 3.2 `release-path` job in `rust.yml`: the gate on pull requests, `tests/release.sh`, `tests/install.sh`
- [ ] 3.3 The workflow run of the pull request builds the three targets (musl included)

## 4. The installer

- [x] 4.1 `fetch_native` between the build and the wrappers, with `core_version`, `core_triple`, the marker, the checks and the install order (`tests/install.sh`: section 14)
- [x] 4.2 Mutations of the installer each make `tests/install.sh` fail: no checksum comparison, no deletion of a stale marked binary, no `--version` self-test
- [x] 4.3 A real build packaged by the script and installed by the real installer into a scratch home with a `file://` base runs `tagents-core --version` and `tagents-core sessions recent` (in the pull request)

- [x] 4.4 Pins and refusals (`tests/install.sh` section 14: refused schemes, https override, download under `target/`, 0-byte, garbage and newline-less checksum files, a file that is not an archive; `tests/release.sh`: merge-base case, lowered version, `pull_request.paths` against `is_input`, matrix against publish loop against `core_triple`, the two `sha256_of`; `tests/rust-parity.sh`: the whole installer accepts the real `--version`)

## 5. Documents

- [x] 5.1 `docs/architecture/rust-core.md`, one row in `docs/development.md`, one clause in `docs/guide/getting-started.md`, and the sentences of `rust-core` that said nothing downloads a binary (`pnpm docs:build`)
- [x] 5.2 `pnpm spec:check` accepts this change
- [ ] 5.3 When the change is archived, replace the placeholder Purpose that `openspec archive` writes into the new `core-release` spec by hand (the delta format has no place for a Purpose), then run `pnpm spec:check`
