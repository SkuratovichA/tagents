# The Rust front door of tagents-core

`tagents-core` is moving from node to Rust one verb group at a time. This page explains the seam that makes that safe: a Rust program that answers the verbs it has and runs the node CLI for everything else, the file that lists which program serves which verb, and the suite that proves the two print the same bytes. A machine with no Rust binary runs the node CLI it always did, and a managed install fetches the prebuilt binary only when a GitHub release exists for the version it holds ("How a release is made" and "How the installer fetches it" below).

## What is served in Rust today

`tagents-core sessions` (`recent [N]`, `search <words…>`, `show <id-prefix>`, and the bare `sessions` that means `recent`) is a port of `packages/core/src/transcripts.ts`. Every other word is the node CLI's: `session`, `plugin`, `doctor`, a plugin's own verbs, help and a word nobody knows.

The decision is made by the first word, so a group of verbs belongs wholly to one program: `sessions rescent` is answered by Rust with the node CLI's usage line and exit code.

## The front door

The binary is `target/release/tagents-core`. A contributor builds it with `cargo build --release`; a managed install gets the prebuilt, checksummed one of its own version from the GitHub release `v<version>` (`pnpm build` builds nothing of it, and `install.sh` never compiles it).

```sh
target/release/tagents-core sessions recent 3   # answered in Rust
target/release/tagents-core plugin list         # exec node packages/core/dist/cli/main.js plugin list
target/release/tagents-core --spec              # the verbs this binary serves, as JSON
target/release/tagents-core --version           # tagents-core 0.1.0: the workspace version it was built from
```

For a word it does not serve, the binary replaces itself with `node packages/core/dist/cli/main.js` of the checkout it sits in, with the same arguments, environment, working directory and stdio. There is no wrapper process left: the exit code, and a signal the call ends with, are the node CLI's own. The node is `$TAGENTS_NODE` when that is set (the wrappers `install.sh` writes set it to the node they pinned), and `node` on `PATH` otherwise.

When it cannot find the node CLI it prints the path it looked at, says the binary has to stay in `<root>/target/<profile>/` next to a built `packages/core/dist/cli/main.js`, and exits 2. A binary copied anywhere else does not find the node CLI. When the node cannot be started it exits 127 if there is no such file and 126 if there is one that cannot run.

## Which program a command goes to

The verbs live in `spec/cli/tagents-core.json`, described by `spec/cli/cli-spec.schema.json`. Each command says `"impl": "rust"` or `"impl": "node"`, and may carry an `effect` (`read`, `write`, `spawn`, `destructive` or `serve`) and `"tool": false`, which the plugin contract generator reads. The node CLI reads the file (`packages/core/src/cli/spec.ts`), the contract generator reads it through the node CLI, and the Rust crate `tagents-spec` embeds it, so moving a verb between languages is a one-word edit that leaves the generated plugin contract untouched. `pnpm plugin:gen` then shows no diff, and a test in `crates/tagents-core/tests/front_door.rs` checks that `tagents-core --spec` prints exactly the `rust` entries of the file.

Both loaders refuse the structural mistakes the schema forbids: a key the schema does not name, an empty `program` or `summary`, an empty `path`, an empty word in `path`, `positionals` or `required`, and a `null` where the schema says string or boolean. Both add the one rule a schema cannot state, that two commands never share a `path` (dispatch is by path, so the second would never run). The Rust loader is the stricter one: no input is known that it loads and the node loader refuses. It refuses three inputs the node loader accepts: an `exit` value written `1.0` (the number 1 to JavaScript, a non-integer to the `u8` the model holds), a key written twice in one object (`JSON.parse` keeps the last), and a lone surrogate escape in a string (`JSON.parse` accepts it); a unit test in `crates/tagents-spec/src/lib.rs` pins each. The path to the data file in `packages/core/src/cli/spec.ts` (`SPEC_FILE`) leads out of `packages/core`, so the package works from a checkout and from `$TAGENTS_HOME`, which is one, and would not work from a packed tarball (`files` is `dist`, which does not hold the data file). Nothing publishes or packs the package, and the repository installs from a clone; the package is not marked `private` because the plugin contract lists the public API of every package that is not.

The one-line summary of a command stays in the language catalogue (`packages/core/src/i18n/`), keyed by the `summary` field, so there is one source of the text.

## Where the binary is looked for

| who | looks at, in this order |
|-----|-------------------------|
| `tagents` (for a verb it does not know) | `tagents-core` on `PATH`, then `target/release/tagents-core` beside the script when it is executable, then the built `packages/core/dist/cli/main.js` |
| the `tagents-core` wrapper from `install.sh` | `$TAGENTS_HOME/target/release/tagents-core` while it is executable, then the node CLI |

`install.sh` names the Rust binary in the wrapper only if the binary is executable when the installer runs. With none, the wrapper is byte for byte what the installer wrote before a Rust binary existed. A binary that is there and cannot run is an error that is reported, not a reason to fall back silently; a binary that has been removed is not an error, and the wrapper runs the node CLI. A directory at the binary's path is not a binary either.

A binary built by hand goes stale. `target/` is ignored by git and nothing rebuilds it, so after `tagents update` or a `git pull` an older `cargo build --release` keeps answering `sessions` until the next `cargo build --release`; the installer leaves a binary with no marker alone and compares nothing. Rebuild after every update. The prebuilt binary cannot go stale that way: on every run the installer compares its marker with the version of the checkout ("How the installer fetches it").

## How a release is made

**The version is the identity of the binary.** `version` in `[workspace.package]` of `Cargo.toml` is the only place it is written, `tagents-core --version` prints it, and a release is the tag `v<version>`. A binary of version V must come from the source of version V, so the version has to move whenever the source does.

**A pull request cannot forget to move it.** The `release-path` job of `.github/workflows/rust.yml` runs `.github/scripts/core-release.sh gate origin/<base>` on every pull request: when the diff against the merge base changes an input of the binary and the workspace version is not higher than the one at the merge base (the same, or lower: the three numbers are compared one by one, as numbers), the job fails, names the files and says whether the version stayed or went down. The inputs are `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, `crates/*/Cargo.toml`, `crates/*/build.rs`, `crates/*/src/*` and `spec/cli/*` (the CLI spec is compiled into the binary by `include_str!`, and the schema beside it counts too, because the rule is a prefix). Tests under `crates/*/tests/`, docs, workflows and the node side are not inputs. A rename out of an input path counts as a change to it.

**A tag makes the release.** Pushing `v<version>` on a commit of `main` starts `.github/workflows/release.yml`:

1. `verify` (read-only token, whole history): the tag is `v` plus the workspace version of that commit, the commit is an ancestor of `origin/main`, and no release of that tag exists yet. A release is never overwritten; a wrong one is superseded by a new version.
2. `build`, on three targets: `aarch64-apple-darwin` and `x86_64-apple-darwin` (cross-built on the arm64 macOS runner) and `x86_64-unknown-linux-musl`. Each runs `cargo build --locked --release --target <triple> --package tagents-core`, packages with `core-release.sh package`, and on the two targets the runner can run unpacks the archive elsewhere and checks `--version` and `--spec`.
3. `publish` (the only job with `contents: write`, and it checks out nothing): `gh release create` with exactly six files.

| file | content |
|------|---------|
| `tagents-core-<version>-<triple>.tar.gz` | exactly two members: `tagents-core` (mode 755) and `LICENSE` |
| `tagents-core-<version>-<triple>.tar.gz.sha256` | one line, `<64 lowercase hex>  <archive name>`, readable by `sha256sum -c` and `shasum -a 256 -c` |

A pull request that changes the workflow, the scripts or an input of the binary (the paths above, which `tests/release.sh` pins to the `pull_request.paths` of `release.yml`) runs the three builds as a dry run and publishes nothing, so a musl link failure or a failed cross-build shows on the pull request and not when the tag is pushed. The `build` job checks out the commit the `verify` job checked, not the tag by name, so a tag moved between the two jobs is not built unverified. A run that failed halfway is redone from the Actions tab with the tag as input (`workflow_dispatch`).

```sh
git switch main && git pull --ff-only          # the commit that holds the bump
sh .github/scripts/core-release.sh version     # 0.1.0
git tag v0.1.0 && git push origin v0.1.0       # starts the release workflow
```

**When `main` is ahead of the last release,** a managed copy that follows `main` holds a version with no release yet. Its installer finds nothing to download, says so, and the node CLI runs until the tag of that version is pushed; it never keeps the binary of an older version in the meantime. Nothing releases on a push to `main`: the person who merges the bump pushes the tag.

## How the installer fetches it

`install.sh` runs `fetch_native` after the build and before it writes the wrappers, never with `--check`. The rules, in the order the function applies them:

| rule | behaviour |
|------|-----------|
| nothing to do | no `$TAGENTS_HOME/Cargo.toml`, or `TAGENTS_NO_NATIVE=1` (which also removes a binary that has a marker), ends the function silently |
| what is wanted | the workspace version of `$TAGENTS_HOME/Cargo.toml`, read by `core_version` in `install.sh`, a second copy of `core-release.sh version` that `tests/release.sh` runs against it over the same `Cargo.toml` shapes |
| whose binary it is | `target/release/tagents-core.release` holds `<version> <target> <sha256 of the binary>` on one line. A binary with no marker was built by hand: it is not replaced, deleted or shadowed by a download |
| nothing changed | the binary is executable and the marker names the wanted version, this target and the hash of the binary: the function ends, and no request is made |
| any other state | a marked binary of another version, target or hash, or a marker without a binary, is deleted before anything is fetched, so a failed fetch leaves the node CLI in use and never a binary of another version |
| this machine | `x86_64-unknown-linux-musl`, `x86_64-apple-darwin` or `aarch64-apple-darwin` from `uname`, where an x86_64 process under Rosetta counts as arm64 (`sysctl -n sysctl.proc_translated` is 1). `TAGENTS_CORE_TARGET` replaces the guess |
| where | `https://github.com/SkuratovichA/tagents/releases/download/v<version>/`; `TAGENTS_CORE_BASE_URL` replaces it (a directory URL that starts with `https://` or `file://`; when a fetch is due and `curl` is there, any other scheme is refused with a warning, no request is made and the run ends with status 1) and is announced in one line. `curl` only, with a bounded wait; an `https://` URL is HTTPS only, TLS 1.2 or newer, two retries, and a `file://` URL is held to files. No `gh`, no login |
| downloaded to | a directory made under `target/` of the copy and removed when the run ends, not under `TMPDIR`: the downloaded binary is run once there for its `--version`, and `TMPDIR` may be mounted `noexec` |
| no release, no network, no `curl`, no `sha256sum` or `shasum`, an unsupported machine | one line on the way to the node CLI, and the run still exits 0 |
| a download that fails a check | `warn`, nothing installed, the wrappers are written, and the run ends with status 1. The checks, in order: the first field of the `.sha256` file is 64 lowercase hex and equals the archive's SHA-256; the archive lists exactly `tagents-core` and `LICENSE`; the extracted `tagents-core` is a regular file and `--version` prints exactly `tagents-core <version>` |
| installing | the marker first, then the binary, each written to a temporary name and renamed, so an interrupted run leaves a marker that does not match, which the next run removes |

The checksum is published beside the archive, so it proves the transfer and that the archive is the one that was packaged, and it does not prove who published it: whoever can write the release can write both files, and the binary is not signed. Trust rests on HTTPS to GitHub and on who may create releases of the repository.

## The parity suite

`tests/rust-parity.sh` builds a seeded home (`tests/rust-parity-seed.mts`: the two sessions of `packages/core/test/fixtures/sessions/` and several hundred more made so that JavaScript and a naive port disagree), runs `node packages/core/dist/cli/main.js` and the Rust binary on it under the same environment, and passes a case only when stdout, stderr and the exit code are identical. Besides these node-against-Rust cases the suite packages the debug binary with `core-release.sh package`, serves it as a `file://` release in a sandbox and checks that the installer accepts its `--version` line.

```sh
pnpm install && pnpm build
env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/rust-parity.sh
```

It needs `python3` (the seed sets exact modification times, including ones before 1970) and builds the debug binary when it is missing and `TAGENTS_CORE_BIN` does not name one; after a Rust edit or a version bump run `cargo build` first, because the suite does not rebuild a binary that exists, and a binary whose version is not the workspace version fails the installer case with a warning that says `for --version`. `cargo test` holds a second, node-free check: the five fixture files, `packages/core/test/fixtures/sessions/*.txt`, which the Rust output must reproduce byte for byte.

Where node's behaviour is an accident of its runtime, the port repeats it, because agents read this text out of a shell: lengths are counted in UTF-16 units, white space is ECMAScript's, a modification time rounds with `Math.round`, names come in the order libuv lists them, and a transcript line is parsed by `json.rs`, a parser that follows `JSON.parse`. What the repository pins is the awkward lines of the seed (`tests/rust-parity-seed.mts`) and the unit tests of `json.rs`; a differential fuzz against `JSON.parse` was run during development and is not kept.

## Where the two are known to differ

These are the differences the port does not hide, and the suite does not cover them:

- `tagents-core --spec` prints the spec as JSON on the Rust binary and is a usage error on the node CLI, so which program the wrapper picks changes what that call does.
- `tagents-core --version`, as the only argument, prints `tagents-core <workspace version>` and exits 0 on the Rust binary; the node CLI has no such flag and reports a usage error. It is the one identity check the installer makes of a downloaded binary, so it is not in `spec/cli/tagents-core.json`, which would move the plugin contract. With more words after it the flag is the node CLI's.
- A search word that holds U+FFFD can match a lone surrogate escape (`"\ud800"`) in a transcript, because Rust reads the escape as U+FFFD where a JavaScript string keeps the lone half.
- Lower casing uses the Unicode data of the Rust standard library, where node uses ICU's. Both gave the same result for every scalar value on node 22, and a newer node that knows a newer Unicode version can differ first.
- An I/O error is worded as node words it for `ENOENT`, `EIO`, `EACCES`, `ENOTDIR`, `EISDIR` and `EMFILE`; any other error number prints Rust's description.
- A directory entry whose name is not UTF-8 is not listed. Node lists it with U+FFFD in the name, and the next `stat` on that name fails there.
- A modification time that `Date` cannot represent, and a `HOME` that is unset (the suite always sets it, empty at times), are not covered.

## Rules for the Rust code

- `unsafe` is forbidden, and `unwrap` and `expect` are denied outside tests, for the whole workspace (`Cargo.toml`, `crates/clippy.toml`).
- No async runtime. The only dependencies are `serde` and `serde_json`, for reading the spec file.
- `cargo fmt --all --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings` and `cargo test --workspace --locked` run in CI (`.github/workflows/rust.yml`), together with the parity suite, the version gate, and the shell suites `tests/release.sh` and `tests/install.sh`.

## What is not decided yet

How plugins (JavaScript) are hosted once more of the CLI is Rust, and which verbs move next, are open. The change that introduced the front door, `openspec/changes/rust-core/`, lays out the slices and the three options for the plugin host. Signing or notarising the archives is not done (see the last paragraph of "How the installer fetches it"), and a Windows build does not exist.
