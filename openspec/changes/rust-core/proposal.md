## Why

`tagents-core` is a node program, so every call pays for starting node, and the plugin host, the session driver and the history reader all live in one runtime that a user must have installed at a matching version. Porting the CLI to Rust is a long road; this change lays the first two stones of it and nothing more: the language-neutral description of the CLI that every implementation reads, and one verb group (`sessions`) served by a Rust front door that hands every other word to the node CLI untouched. The old behaviour stays the fallback, so no user is moved before a binary exists on their machine.

## What Changes

- The verbs and flags of `tagents-core` become data: `spec/cli/tagents-core.json`, described by `spec/cli/cli-spec.schema.json`, read by the node CLI, by the contract generator and by Rust. Each command says `"impl": "rust"` or `"impl": "node"`; a command may carry one optional string `effect`.
- A Cargo workspace at the repository root with `tagents-spec` (the data file's model) and `tagents-core` (a library and the `tagents-core` binary): the front door serves `sessions recent|search|show`, answers `--spec` with the table of verbs it serves, and replaces itself with the node CLI for every other word, so the exit code is the node CLI's own.
- `tagents` (`forward_core`) and the wrappers `install.sh` writes run `target/release/tagents-core` when it is an executable file, and the node CLI otherwise. Nothing in this change downloads or builds a binary on a user's machine; `openspec/changes/rust-release/` adds the download of a checksummed release binary.
- A parity suite, `tests/rust-parity.sh` with the Cargo tests beside it, runs the node CLI and the Rust binary on the same seeded home and compares stdout, stderr and exit code byte for byte.
- A CI workflow, `.github/workflows/rust.yml`, runs `cargo fmt --check`, `clippy -D warnings`, `cargo test` and the parity suite.
- `design.md` records the decisions of the whole road (slices S0 to S5, the three options for the plugin host, the on-disk formats the two runtimes share) and builds none of it beyond S0 and S1.

## Capabilities

### New Capabilities

- `core-front-door`: what the Rust `tagents-core` serves itself, how every other word reaches the node CLI, what `--spec` prints, and the data file all implementations read.

### Modified Capabilities

- `cli-dispatch`: `tagents` looks for a built Rust binary beside the script before the built node CLI.
- `plugin-contract`: the CLI part of the contract is read from the data file for `tagents-core`.
- `claude-code-plugin`: the `tagents-core` wrapper names the Rust binary when one is installed, and is byte for byte the old wrapper when none is.
- `session-history`: the history verbs print the same bytes whichever implementation serves them.

## Impact

- Code: `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, `crates/`, `spec/cli/`, `packages/core/src/cli/spec.ts`, `packages/contract/src/sources.ts` (a comment), `tagents` (`forward_core`), `install.sh`, `tests/dispatch.sh`, `tests/install.sh`, `tests/rust-parity.sh`, `tests/rust-parity-seed.mts`, `.github/workflows/rust.yml`, `.gitignore`.
- Exports of `@tagents/core` that other packages import keep their names and signatures; `CommandSpec` and `CliContract` are unchanged.
- The generated contract (`contract.json`, `.claude-plugin/`, `skills/`) does not change: `pnpm plugin:gen` leaves no diff.
- With no Rust binary anywhere, behaviour and the wrapper files `install.sh` writes are byte for byte what they were.
- New dependencies, each with its reason in `design.md`: the Rust toolchain for contributors and CI, and the crates `serde` and `serde_json`.
- Not touched: `openspec/specs/`, the config file format, MCP tools, any plugin package.
