## Why

`tagents-core plugin add`, `plugin remove`, `plugin new` and `doctor` are file work: they read a `package.json`, edit or write a few files and print a line. They still start node through the front door, which is the cost this port exists to remove from the commands a person types. `plugin list` is different: it prints what each plugin offers, and only JavaScript knows that, so it stays with node until the plugin host is decided (stage S4).

The part that needs care is not the printing. `plugin add` and `plugin remove` edit the owner's hand-written `config.toml` by a text splice, and `plugin add` resolves a package the way node's `require.resolve` does. A port that is almost the same corrupts a config or adds a plugin node would have refused. So the rule of this change is that Rust answers only what it can prove is byte for byte what node answers, and hands every other input to node before anything is written.

## What Changes

- `plugin add`, `plugin remove`, `plugin new` and `doctor` become verbs of the Rust binary (`impl: rust` in `spec/cli/tagents-core.json`), with node's texts, exit codes and file effects, in both locales. `plugin list` and `plugin list --json` stay `impl: node`.
- `plugin` becomes a front-door group whose `run` may decline: a `plugin` call that is not one of the three served verbs, or that falls in a documented hand-over class, is run by the node CLI before any file is written. The rule "a verb word is served by one program" becomes "a word shared by two programs is decided by its second word", and its test in `packages/core/test/cli-spec.test.ts` says so.
- The config is edited by the same text splice node performs, using the `toml` crate that already reads `notify.toml`. `toml_edit` is not added. A document the two parsers could read differently (a syntax error, an integer beyond 2^53, text that is not UTF-8) goes to node.
- `plugin add <name>` resolves a bare package name by walking `node_modules` directories upward from the working directory, for a package whose manifest has no `exports`. Everything else about resolving by name (`exports`, `NODE_PATH`, `NODE_OPTIONS`, the global pnpm store, a package that is not found) goes to node. A directory path is resolved in Rust completely.
- The texts every verb prints come from one source: `packages/core/src/i18n/{en,ru}.ts` is exported to `spec/cli/messages.json` by `pnpm messages:gen`, and Rust reads that file. No string is copied by hand. A key for the one line only Rust prints (`node: missing` when `doctor` finds no node) is added to both catalogues.
- `plugin new` renders its five files from one template file, `spec/cli/scaffold/plugin.txt`, read at run time by node and compiled into the binary by Rust. The TypeScript that builds the files today is deleted.
- `doctor` runs one `node -p` for the version and the executable path, and prints `node: missing` and exits 0 when node cannot be started.
- `tests/rust-plugin-parity.sh` (new) runs each call against node and against Rust from the same pristine scratch tree and compares stdout, stderr, the exit code and every file left behind. Generated vectors pin the helpers that exist twice.
- The workspace version is raised by each pull request that changes an input of the binary. No dependency is added.

## Capabilities

### New Capabilities

- `rust-plugin-verbs`: `plugin add`, `plugin remove`, `plugin new` and `doctor` as verbs of the Rust binary: what they must print and write exactly as node does, which inputs they hand to node, the subset of package resolution they implement, the single sources of their texts and their scaffold, and how they are kept equal to node.

### Modified Capabilities

- `core-front-door`: the binary serves `plugin add`, `plugin remove`, `plugin new` and `doctor` besides `sessions`, a `plugin` call outside them is the node CLI's, and the example of a forwarded call names a verb the node CLI serves.

## Impact

- Code: `crates/tagents-core/src/plugin/` (new: the verbs, the config splice, the resolution, the scaffold), `crates/tagents-core/src/doctor.rs` (new), `crates/tagents-core/src/front_door.rs` (`Group::run` returns `Option<Output>`, two groups), `crates/tagents-core/src/sessions.rs` (the `exit` table gains `REFUSED`; `run` wraps its answer in `Some`), `crates/tagents-core/src/node.rs` (`resolve`, `relative`, `interpreter`), `crates/tagents-core/src/notify/options.rs` (the lossy-integer check moves to a shared module, behaviour unchanged), `crates/tagents-spec/src/lib.rs` (the messages), `spec/cli/tagents-core.json` (four flags), `spec/cli/messages.json` (generated), `spec/cli/scaffold/plugin.txt` (new), `packages/core/src/cli/scaffold.ts`, `packages/core/src/i18n/{en,ru}.ts`, `packages/core/test/cli-spec.test.ts`, `crates/tagents-core/tests/front_door.rs` (the forwarded word), `Cargo.toml` and `Cargo.lock` (the version), `.github/workflows/ci.yml` and `rust.yml`, `package.json` (`messages:gen`, `messages:check`).
- Documents: `docs/architecture/rust-core.md`, the sentences elsewhere in `docs/` that say node runs these verbs, `CHANGELOG.md`.
- The generated plugin contract and the skill references do not change: the flags move verbs between programs and leave the contract alone, which `pnpm plugin:gen` and `pnpm plugin:check` show.
- A machine with no Rust binary runs the node CLI for every verb, as before.
- Not done: `plugin list` (it needs the plugin host, S4), the knowledge server, `session` verbs (S3), retiring the node verbs, `toml_edit`, a JSON Schema derived from Rust types.
- The change ships in three pull requests. (a) This proposal. (b) Groups 1 to 6: the shared pins, the front-door group, the config splice, the resolution, the generated messages, and `plugin add` and `plugin remove` with their suite, the verbs last among the code. (c) Groups 7 to 12: the scaffold source, `plugin new`, `doctor`, the parity completion, the documents, and the archive. Each of (b) and (c) raises the workspace version one step above its merge base, and each leaves the node verbs in place as the fallback: a verb whose flag is `node` is the node CLI's.
