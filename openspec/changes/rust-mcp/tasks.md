Archive this change after `mcp-tools-from-contract`: the requirement "The tools follow the rules of the node server" (`specs/rust-mcp/spec.md`) cites seven requirement names that reach `openspec/specs/claude-code-plugin/spec.md` only when that change is archived, since they exist today only in `openspec/changes/mcp-tools-from-contract/specs/claude-code-plugin/spec.md`.

## 1. The verb and the contract

- [x] 1.1 `mcp` in `spec/cli/tagents-core.json` with `impl: rust`, `effect: serve`, its summary in `en.ts` and `ru.ts`; the generated contract and references gain exactly that entry (`pnpm plugin:check`, `contract-stable`)
- [x] 1.2 The front door gives `mcp` an arm of its own; usage line and exit 2, start-up failure line and exit 1, `--contract file` and `--contract=file` (`cargo test -p tagents-core --test front_door`)
- [x] 1.3 The contract reader is lenient and the bundled `contract.json` agrees with `Spec::bundled()` (`cargo test -p tagents-core --lib mcp::contract`, `cargo test -p tagents-core --test mcp_pins`)

## 2. The protocol layer

- [x] 2.1 `rpc`: one JSON value per line in, one line out through a single locked writer, keys in the SDK's order (`cargo test -p tagents-core --lib mcp::rpc`)
- [x] 2.2 `server`: `initialize` with every protocol version the SDK lists and the latest otherwise, `ping`, `tools/list`, `-32601`, `-32602`, noise ignored, over a fake `Tools` that spawns nothing (`cargo test -p tagents-core --lib mcp::server`)
- [x] 2.3 Nothing in the module prints to stdout (`cargo clippy --workspace --all-targets --locked -- -D warnings` with `print_stdout` and `dbg_macro` denied in `mcp/mod.rs`)

## 3. The tools and the call

- [x] 3.1 Tool derivation, names, descriptions, input schemas and annotations by the rules of `packages/mcp/src/tools.ts` (`cargo test -p tagents-core --lib mcp::tools`)
- [x] 3.2 Argument checks in the node server's order and with its messages (`cargo test -p tagents-core --lib mcp::tools`)
- [x] 3.3 `run`: spawn in a process group, 256 KiB per stream cut at a character, JSON stdout told as a value, outcome names, `timeout` winning over the exit status (`cargo test -p tagents-core --lib mcp::run`, `cargo test -p tagents-core --test mcp_run`)

## 4. Cancellation and shutdown

- [x] 4.1 `notifications/cancelled` stops the call and suppresses its answer (`cargo test -p tagents-core --test mcp_server`)
- [x] 4.2 Stdin end, SIGTERM, SIGINT and SIGHUP stop every call, answer each `cancelled` and exit 0 within the bound; a write error ends the same way; a second signal does not cut the ending short (`a_second_signal_during_the_ending_does_not_cut_it_short` in `tests/mcp_server.rs`) (`cargo test -p tagents-core --test mcp_server`, `cargo test -p tagents-core --lib mcp::server`)
- [x] 4.3 What a program leaves behind dies with it, and a helper holding the pipes holds the call no longer than the drain (`cargo test -p tagents-core --test mcp_run`)

## 5. The tests ported from the node server

- [x] 5.1 Every case of `packages/mcp/test/{tools,contract-file,run,process,server,smoke}.test.ts` has a Rust test or a stated reason it does not apply (`cargo test --workspace --locked`; the one case that does not apply is stated in `docs/architecture/rust-core.md`)
- [x] 5.2 The constants (cap, timeout, grace, drain, margin) are pinned against the TypeScript sources (`cargo test -p tagents-core --test mcp_pins`)

## 6. The differential suite and its mutations

- [x] 6.1 `tests/rust-mcp-parity.sh` and its driver: handshake, both tool lists, every way a call ends, unknown tool and method, cancellation, two calls in flight, stdin closed in flight (`bash tests/rust-mcp-parity.sh`)
- [x] 6.2 Mutations of the Rust server each make the suite fail on one scenario and leave it green once restored: the cap on stderr, the process group of a call whose program leaves a child holding the pipes, the order of properties in `tools/list`, an answer written for a cancelled request (`PARITY_ONLY=<scenario> bash tests/rust-mcp-parity.sh`, one failing line each)

## 7. The installer seam

- [x] 7.1 `write_wrapper` takes the word, and the `tagents-mcp` entry of `install_commands` names the binary of `tagents-core` with `mcp` (`bash tests/install.sh`, sections 13 and 14)
- [x] 7.2 With no binary the wrapper is byte for byte the old one; a binary that vanishes or loses its executable bit falls through to node; `TAGENTS_NO_NATIVE=1` and a version without a release leave node (`bash tests/install.sh`)
- [x] 7.3 Mutations of the installer each make `tests/install.sh` fail: the word left out, the binary named when none is installed, the version check dropped (`bash tests/install.sh`)
- [x] 7.4 `shellcheck -s sh install.sh` has no finding that `origin/main` does not have (four SC2016 on both)

## 8. CI

- [x] 8.1 `rust.yml` installs the node dependencies before the Rust steps, lists `packages/mcp/**`, `tests/rust-mcp-parity.sh` and its driver in both `paths` and runs the suite after the existing parity step (`actionlint`)
- [x] 8.2 The workflow run of the pull request passes the new step (`rust-mcp-parity: 219 passed, 0 failed` in the `rust` job)
- [x] 8.3 The `rust` job runs on ubuntu-latest and macos-latest (proved by the workflow run of the pull request: both legs pass, each with `rust-parity: 391 passed` and `rust-mcp-parity: 219 passed`)

## 9. Documents

- [x] 9.1 `docs/architecture/rust-core.md` (the server, its dependencies and limits), one row in `docs/development.md`, the sentences of `getting-started.md`, `claude-code-plugin.md` and `contract.md` that said node runs the server (`pnpm docs:build`)
- [x] 9.2 `pnpm spec:check` accepts this change, and `openspec validate rust-mcp --strict --no-interactive` does

## 10. Measurements

- [x] 10.1 `footprint` of an idle `tagents-core mcp` and of the node server on the same contract, and the time from spawn to the answer of `initialize`, in the pull request description
- [x] 10.2 Release size, crates added and clean build time for `serde_json` features, `rustix` and `signal-hook`, in the dependency table
