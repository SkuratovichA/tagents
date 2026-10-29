# The Rust front door of tagents-core

`tagents-core` is moving from node to Rust one verb group at a time. This page explains the seam that makes that safe: a Rust program that answers the verbs it has and runs the node CLI for everything else, the file that lists which program serves which verb, and the suite that proves the two print the same bytes. Nothing here is on by default: with no Rust binary on a machine, `tagents-core` is the node CLI it always was.

## What is served in Rust today

`tagents-core sessions` (`recent [N]`, `search <words…>`, `show <id-prefix>`, and the bare `sessions` that means `recent`) is a port of `packages/core/src/transcripts.ts`. Every other word is the node CLI's: `session`, `plugin`, `doctor`, a plugin's own verbs, help and a word nobody knows.

The decision is made by the first word, so a group of verbs belongs wholly to one program: `sessions rescent` is answered by Rust with the node CLI's usage line and exit code.

## The front door

The binary is `target/release/tagents-core`, built with `cargo build --release` (contributors only: nothing in `pnpm build` or `install.sh` builds or downloads it).

```sh
target/release/tagents-core sessions recent 3   # answered in Rust
target/release/tagents-core plugin list         # exec node packages/core/dist/cli/main.js plugin list
target/release/tagents-core --spec              # the verbs this binary serves, as JSON
```

For a word it does not serve, the binary replaces itself with `node packages/core/dist/cli/main.js` of the checkout it sits in, with the same arguments, environment, working directory and stdio. There is no wrapper process left: the exit code, and a signal the call ends with, are the node CLI's own. The node is `$TAGENTS_NODE` when that is set (the wrappers `install.sh` writes set it to the node they pinned), and `node` on `PATH` otherwise.

When the checkout has not been built it says so (`pnpm install && pnpm build`) and exits 2. When the node cannot be started it exits 127 if there is no such file and 126 if there is one that cannot run.

## Which program a command goes to

The verbs live in `spec/cli/tagents-core.json`, described by `spec/cli/cli-spec.schema.json`. Each command says `"impl": "rust"` or `"impl": "node"`, and may carry one optional string, `effect`. The node CLI reads the file (`packages/core/src/cli/spec.ts`), the contract generator reads it through the node CLI, and the Rust crate `tagents-spec` embeds it, so moving a verb between languages is a one-word edit that leaves the generated plugin contract untouched. `pnpm plugin:gen` then shows no diff, and a test in `crates/tagents-core/tests/front_door.rs` checks that `tagents-core --spec` prints exactly the `rust` entries of the file.

The one-line summary of a command stays in the language catalogue (`packages/core/src/i18n/`), keyed by the `summary` field, so there is one source of the text.

## Where the binary is looked for

| who | looks at, in this order |
|-----|-------------------------|
| `tagents` (for a verb it does not know) | `tagents-core` on `PATH`, then `target/release/tagents-core` beside the script when it is executable, then the built `packages/core/dist/cli/main.js` |
| the `tagents-core` wrapper from `install.sh` | `$TAGENTS_HOME/target/release/tagents-core` while it is executable, then the node CLI |

`install.sh` names the Rust binary in the wrapper only if the binary is executable when the installer runs. With none, the wrapper is byte for byte what the installer wrote before a Rust binary existed. A binary that is there and cannot run is an error that is reported, not a reason to fall back silently; a binary that has been removed is not an error, and the wrapper runs the node CLI.

## The parity suite

`tests/rust-parity.sh` builds a seeded home (`tests/rust-parity-seed.mts`: the two sessions of `packages/core/test/fixtures/sessions/` and several hundred more made so that JavaScript and a naive port disagree), runs `node packages/core/dist/cli/main.js` and the Rust binary on it under the same environment, and passes a case only when stdout, stderr and the exit code are identical.

```sh
pnpm install && pnpm build
env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/rust-parity.sh
```

It needs `python3` (the seed sets exact modification times, including ones before 1970) and builds the debug binary when `TAGENTS_CORE_BIN` does not name one. `cargo test` holds a second, node-free check: the five fixture files, `packages/core/test/fixtures/sessions/*.txt`, which the Rust output must reproduce byte for byte.

Where node's behaviour is an accident of its runtime, the port repeats it, because agents read this text out of a shell: lengths are counted in UTF-16 units, white space is ECMAScript's, a modification time rounds with `Math.round`, names come in the order libuv lists them, and a transcript line is parsed by `json.rs`, a parser that accepts exactly what `JSON.parse` accepts.

## Where the two are known to differ

These are the differences the port does not hide, and the suite does not cover them:

- A search word that holds U+FFFD can match a lone surrogate escape (`"\ud800"`) in a transcript, because Rust reads the escape as U+FFFD where a JavaScript string keeps the lone half.
- Lower casing uses the Unicode data of the Rust standard library, where node uses ICU's. Both gave the same result for every scalar value on node 22, and a newer node that knows a newer Unicode version can differ first.
- An I/O error is worded as node words it for `ENOENT`, `EIO`, `EACCES`, `ENOTDIR`, `EISDIR` and `EMFILE`; any other error number prints Rust's description.
- A directory entry whose name is not UTF-8 is not listed. Node lists it with U+FFFD in the name, and the next `stat` on that name fails there.
- A modification time that `Date` cannot represent, and a `HOME` that is unset (the suite always sets it, empty at times), are not covered.

## Rules for the Rust code

- `unsafe` is forbidden, and `unwrap` and `expect` are denied outside tests, for the whole workspace (`Cargo.toml`, `crates/clippy.toml`).
- No async runtime. The only dependencies are `serde` and `serde_json`, for reading the spec file.
- `cargo fmt --all --check`, `cargo clippy --workspace --all-targets -- -D warnings` and `cargo test --workspace` run in CI (`.github/workflows/rust.yml`), together with the parity suite.

## What is not decided yet

How a binary reaches a user's machine, how plugins (JavaScript) are hosted once more of the CLI is Rust, and which verbs move next are open. The change that introduced the front door, `openspec/changes/rust-core/`, lays out the slices and the three options for the plugin host.
