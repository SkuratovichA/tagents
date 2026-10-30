Archive this change after `rust-mcp`: the tasks lift `child.rs` and `ending.rs` out of code that exists only there, and the requirement "The program with a deadline and the ending are shared with mcp" (`specs/rust-notify/spec.md`) names the verb `mcp`, which reaches `openspec/specs/` only when that change is archived. Each group below is one pull request, in this order; groups 2, 3 and 4 do not depend on one another and may be prepared in parallel after group 1. Groups 1 to 5 change what the binary is built from, so each raises the workspace version above its merge base (`bash tests/release.sh`), and none cuts a tag.

## 1. The shared modules

- [ ] 1.1 `child.rs` holds the spawn of a program in a process group with an optional stdin, a deadline, a cap per stream cut at a character and a drain, lifted from `mcp/run.rs` (`Capture`, `read_stream`, `complete_end`, `launch`, `wait_for_exit`, `supervise`, `signal_group`, `Event`, `Stream`, `Reason`); `mcp/run.rs` calls it and keeps `call_tool`, `Runner` and the result body (`cargo test -p tagents-core --test mcp_run`, `cargo test -p tagents-core --lib mcp::run`, every test unchanged)
- [ ] 1.2 `ending.rs` holds `Stop` and `on_signals`, lifted from `mcp/server.rs` and `mcp/mod.rs`; `mcp` uses them and a second signal still does not cut the ending short (`cargo test -p tagents-core --test mcp_server`)
- [ ] 1.3 `Policy::input` writes the bytes to the child's stdin and closes it, and `kill_grace: None` sends SIGKILL at the deadline; both have tests of their own, including a child that never reads its stdin and a child that exits before the write ends (`cargo test -p tagents-core --lib child`)
- [ ] 1.4 `node_cli` of `front_door.rs` becomes `exec_node(relative, args)` for the node program next to the binary, and the node CLI is its first caller; the root, `TAGENTS_NODE` and the exit code of a failed `exec` are unchanged (`cargo test -p tagents-core --test front_door`)
- [ ] 1.5 What `mcp` does has not moved: the differential suite of the MCP server passes (`bash tests/rust-mcp-parity.sh`), `cargo clippy --workspace --all-targets --locked -- -D warnings` is clean, and no `unsafe` or `unwrap` is added

## 2. The watch

- [ ] 2.1 `watch/` on Linux over `rustix::fs::inotify` and `rustix::event::poll`: `dir` and `file` watches, a thread of its own, keys sent to a channel, a wake pipe so that adding or dropping a watch never waits for an event (`cargo test -p tagents-core --lib watch`)
- [ ] 2.2 `watch/` on macOS over the `kqueue` crate, which is a target dependency of `cfg(target_os = "macos")` only, with no `unsafe` in the workspace (`cargo test -p tagents-core --lib watch` in the macOS job; `cargo clippy --workspace --all-targets --locked -- -D warnings` on both)
- [ ] 2.3 `file` opens with `O_NOFOLLOW` and treats `ELOOP` as no watch: a symlink's target edited is not seen, the link replaced is, a file written in place is seen on both systems, and a file replaced by rename is seen through the directory (`cargo test -p tagents-core --lib watch`)
- [ ] 2.4 Every arming is followed by a read, and a write that lands between the last read and the arming is read after it (a test arms a watch over a file written from a second thread in a loop and checks that no byte is missed, 200 rounds)
- [ ] 2.5 Dropping the `Watch` ends its thread and closes every descriptor (a test counts the descriptors of the process before and after, on Linux through `/proc/self/fd` and on macOS through `/dev/fd`)
- [ ] 2.6 The dependency rows `kqueue` and the three `rustix` features are in `docs/architecture/rust-core.md` with release size, crates added and clean build time (`pnpm docs:build`)

## 3. The options reader and the vectors

- [ ] 3.1 `toml` is a dependency with the smallest feature set that builds, and the policy sentences move with it: `Cargo.toml` above `[workspace.dependencies]` and "Rules for the Rust code" in `docs/architecture/rust-core.md` name `toml` and its reason (`cargo build --workspace --locked`, `pnpm docs:build`)
- [ ] 3.2 `notify/options.rs` reads `plugins/notify.toml` into `Options` with every default of the `notify` requirement "Plugin options and defaults", durations by the grammar of "Durations" with ASCII digits only, whole numbers, a safe-integer total, and `js::number_text` for a number in a message (`cargo test -p tagents-core --lib notify::options`)
- [ ] 3.3 The validator writes the node service's lines for every row of the message table in `design.md`: unknown keys in the order of a JavaScript object, enum and type texts, the type names `NaN`, `Infinity`, `-Infinity` and `TomlDate`, a date read as an empty table, the order of issues, and the `after`/`ttl` check skipped after a type problem inside `cache_expiring` (`cargo test -p tagents-core --lib notify::options`)
- [ ] 3.4 `tests/rust-notify-vectors.mts` writes `crates/tagents-core/tests/fixtures/notify-vectors.json` by calling `NotifyOptionsSchema`, `issueLines` and `loadPluginOptions` on about a hundred documents, and the Rust test reads it case by case (`node tests/rust-notify-vectors.mts && git diff --exit-code crates/tagents-core/tests/fixtures/notify-vectors.json`, `cargo test -p tagents-core --test notify_vectors`)
- [ ] 3.5 A file that is not TOML and an integer beyond 2^53 follow the requirement "A file that is not TOML is reported, not reproduced", and the corpus of edge cases (underscores, signs, `0b`, `0o`, exponents, local dates, `1e400`) is in the vectors with what node says (`cargo test -p tagents-core --test notify_vectors`)
- [ ] 3.6 The source rule of `pluginOptionsFile` is ported with its directory case: `notify.toml` as a regular file wins, a directory named `notify.toml` is not a file, `notify.yaml` alone is YAML, neither is missing (`cargo test -p tagents-core --lib notify::options`)
- [ ] 3.7 The vector file is regenerated and compared in CI (`.github/workflows/rust.yml`, `actionlint`)

## 4. The data and the words

- [ ] 4.1 `notify/state.rs` ports `readAgentState`, `labelsBySession` and `readLabels` of `agent-state.ts`, and `notify/events.rs` ports `parseEventLine` and the follower of `agent-events.ts` over the watch: start at the end, chunks of 64 KiB, partial lines, truncation, a replaced inode, rotation at 1 MiB with the 2 second grace, `events.on` with the first follower and removed with the last (`cargo test -p tagents-core --lib notify::events`)
- [ ] 4.2 Every case of `packages/core/test/agent-events.test.ts` (40) and `agent-state.test.ts` (12) has a Rust test or a stated reason it does not apply (`cargo test -p tagents-core --lib notify`)
- [ ] 4.3 `notify/kinds.rs` ports `classify` and `countsSession`, with the 14 cases of `kinds.test.ts` (`cargo test -p tagents-core --lib notify::kinds`)
- [ ] 4.4 `notify/compose.rs`, `notify/phrases.rs` and `notify/screen.rs` port `compose.ts`, `phrases.ts` and `parseScreen`, with the 21 cases of `compose.test.ts` and the 15 of `screen.test.ts`, and the phrases through the vectors; a title is also checked against `untitle_of` in `lib/tagents/names.sh` over the vector inputs, as `compose.test.ts` does (`cargo test -p tagents-core --lib notify`)
- [ ] 4.5 The turn-done body uses `transcripts::last_assistant_text`, the clip counts code points, and a cache notice rounds minutes with `js::round`, with nothing written beside those helpers (`cargo test -p tagents-core --lib notify::compose`)
- [ ] 4.6 The vector generator covers state rows, event lines, verdicts, the words of a notice, phrases in both locales and the tmux answers, and the Rust tests read each case (`cargo test -p tagents-core --test notify_vectors`)

## 5. The engine, the lock, the helper and the verb

- [ ] 5.1 `notify/deadlines.rs` over a fake clock, with deadlines as wall-clock times and the wait capped at five minutes, and the 14 cases of `deadlines.test.ts` (`cargo test -p tagents-core --lib notify::deadlines`)
- [ ] 5.2 `notify/engine.rs` over fakes of the feed, the notifier, the clock and the screen, one thread, events one at a time in arrival order, re-follow after 1 second doubling to 5 minutes, and the 85 cases of `engine.test.ts` (`cargo test -p tagents-core --lib notify::engine`)
- [ ] 5.3 `notify/lock.rs` ports `takeLock`, `holds`, `sweepTempLocks` and `releaseLock`: the format, the temp file and `link`, the sweep, three tries, `/bin/ps -o lstart= -p <pid>` through `child::run` with 2000 ms and `LC_ALL=C TZ=UTC` as the whole environment, the boot time, and the cases of `service.test.ts` for the lock (`cargo test -p tagents-core --lib notify::lock`)
- [ ] 5.4 `notify/helper.rs` and `notify/platform.rs` port `platform/macos/helper.ts`, `log.ts` and `unsupported.ts` with their error texts, the 9 cases of `helper.test.ts` and the cases of `log-notifier.test.ts` (`cargo test -p tagents-core --lib notify`)
- [ ] 5.5 `notify/service.rs` runs the start in the order of `service.ts`: signals first, state directory, lock, options, backend, engine, watchers, `started` last; and the stop in the order of "A signal ends the service as it ends the node service"; a start that fails or finds YAML options hands over to node with the lock released (`cargo test -p tagents-core --test notify_service`)
- [ ] 5.6 The verb: the entry `["notify", "run"]` with `impl: rust` and `effect: serve` in `spec/cli/tagents-core.json`, its summary in `packages/core/src/i18n/en.ts` and `ru.ts`, an arm of its own in `front_door.rs`, the generated contract and references gaining exactly that entry and no tool (`pnpm plugin:gen`, `pnpm plugin:check`, `cargo test -p tagents-core --test front_door`, `pnpm --filter @tagents/core test`)
- [ ] 5.7 The remaining cases of `service.test.ts`, `main.test.ts` and `options.test.ts` have a Rust test or become a scenario of the suite in group 7, each named in `docs/architecture/rust-core.md`

## 6. The installer seam and the plist

- [ ] 6.1 `write_wrapper` takes a sixth parameter, the one argument list the native binary is for, and the `tagents-notify` entry of `install_commands` names the binary of `tagents-core` with the word `notify` for the argument `run`, under the `--version` check of `tagents-mcp` (`bash tests/install.sh`)
- [ ] 6.2 With no binary the wrapper is byte for byte the old one; a binary that vanishes or loses its executable bit falls through to node; `tagents-notify status`, `run extra` and no arguments reach node over an installed binary; a binary of another version, `TAGENTS_NO_NATIVE=1` and a version without a release leave node (`bash tests/install.sh`)
- [ ] 6.3 `runSpecFor` writes `[<wrapper>, 'run']` when `tagents-notify` is on the installing shell's `PATH` and its text names this checkout's `dist/main.js`, and `[node, dist/main.js, 'run']` otherwise, and the tests of `commands.test.ts` and `launchd.test.ts` pin both (`pnpm --filter @tagents/notify test`)
- [ ] 6.4 Mutations of the installer each make `tests/install.sh` fail: the guard `"$#" -ne 1` left out, the word `notify` left out, the binary named when none is installed, the version check dropped (`bash tests/install.sh`, one failing check each)
- [ ] 6.5 `shellcheck -s sh install.sh` has no finding that `origin/main` does not have, and the plist passes `plutil -lint` on macOS (`shellcheck -s sh install.sh`, `plutil -lint`)

## 7. The differential suite and CI

- [ ] 7.1 `tests/rust-notify-parity.sh` and its driver: scratch `HOME`, state, config, locale and `TMUX_TMPDIR`, a `tmux` shim, a stub helper that records its arguments and stdin; the scenarios of the design (verdicts, question then permission, kinds off, `skip_visible`, replace and withdraw, cache deadlines from events and from state rows, the transcript body, both locales, every helper failure, the `log` backend, every bad-options document at start and at reload, symlinked and replaced options files, a late `plugins` directory, a missing config directory, the lock in both directions, backend `none`, signals with a post in flight, rotation, truncation, two thousand events in a tight loop) (`bash tests/rust-notify-parity.sh`)
- [ ] 7.2 Tripwires assert on the node transcript alone, so a scenario that stopped provoking what it exists for fails; the suite prints how many scenarios it skipped, and the macOS job runs the helper scenarios (`bash tests/rust-notify-parity.sh`, `PARITY_ONLY=<text>`)
- [ ] 7.3 Mutations of the Rust service each make the suite fail on one scenario and leave it green once restored: `O_NOFOLLOW` dropped, unknown keys in file order, the lock released although another process holds it, a stop that cuts the post in flight, the offset not reset on truncation, a field of the helper's input renamed (`PARITY_ONLY=<scenario> bash tests/rust-notify-parity.sh`, one failing line each)
- [ ] 7.4 An idle service's CPU time grows by no more than one clock tick in ten seconds, read through `ps -o cputime` and `/proc/<pid>/stat` (`bash tests/rust-notify-parity.sh`)
- [ ] 7.5 `rust.yml` lists `packages/notify/**`, `packages/core/src/agent-*.ts`, `tests/rust-notify-parity.sh`, its driver and the vector generator in `paths`, installs the node dependencies before the Rust steps and runs the suite after the existing parity steps on ubuntu-latest and macos-latest (`actionlint`)
- [ ] 7.6 The workflow run of the pull request passes the new step on both systems (`gh run list --branch <branch>` shows the `rust`, `ci` and `release` workflows succeeded on the last head)

## 8. Documents

- [ ] 8.1 `docs/architecture/rust-core.md`: the daemon, the watch, the parser policy, the dependencies, the lock shared with node, the YAML hand-over, and under "Where the two are known to differ" each difference of `design.md` with its reason (`pnpm docs:build`)
- [ ] 8.2 `docs/guide/notifications.md`, `docs/guide/claude-code-plugin.md` and `docs/architecture/overview.md`: the sentences that say node runs the service, and how to see which program does (`tagents notify status`, `footprint <pid>`) (`pnpm docs:build`)
- [ ] 8.3 `pnpm spec:check` accepts this change, and `openspec validate rust-notify --strict --no-interactive` does

## 9. Measurements

- [ ] 9.1 `footprint` of an idle `tagents-core notify run` and of the node service on the same state after ten minutes, and the time from spawn to the `started` line, in the pull request description
- [ ] 9.2 Release size, crates added and clean build time for `toml`, `kqueue` and the new `rustix` features, in the dependency table
