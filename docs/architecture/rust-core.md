# The Rust front door of tagents-core

`tagents-core` is moving from node to Rust one verb group at a time. This page explains the seam that makes that safe: a Rust program that answers the verbs it has and runs the node CLI for everything else, the file that lists which program serves which verb, and the suite that proves the two print the same bytes. A machine with no Rust binary runs the node CLI it always did, and a managed install fetches the prebuilt binary only when a GitHub release exists for the version it holds ("How a release is made" and "How the installer fetches it" below).

## What is served in Rust today

`tagents-core sessions` (`recent [N]`, `search <words…>`, `show <id-prefix>`, and the bare `sessions` that means `recent`) is a port of `packages/core/src/transcripts.ts`, and `tagents-core mcp --contract <file>` is the plugin's MCP server, a port of `packages/mcp` ("The MCP server"). Every other word is the node CLI's: `session`, `plugin`, `doctor`, a plugin's own verbs, help and a word nobody knows. The node CLI itself does not know `mcp` (`unknown command: mcp`), so on a machine with no Rust binary the plugin's server is `packages/mcp/dist/main.js`, as before.

The decision is made by the first word, so a group of verbs belongs wholly to one program: `sessions rescent` is answered by Rust with the node CLI's usage line and exit code.

## The front door

The binary is `target/release/tagents-core`. A contributor builds it with `cargo build --release`; a managed install gets the prebuilt, checksummed one of its own version from the GitHub release `v<version>` (`pnpm build` builds nothing of it, and `install.sh` never compiles it).

```sh
target/release/tagents-core sessions recent 3   # answered in Rust
target/release/tagents-core plugin list         # exec node packages/core/dist/cli/main.js plugin list
target/release/tagents-core --spec              # the verbs this binary serves, as JSON
target/release/tagents-core --version           # tagents-core 0.2.0: the workspace version it was built from
```

For a word it does not serve, the binary replaces itself with `node packages/core/dist/cli/main.js` of the checkout it sits in, with the same arguments, environment, working directory and stdio. There is no wrapper process left: the exit code, and a signal the call ends with, are the node CLI's own. The node is `$TAGENTS_NODE` when that is set (the wrappers `install.sh` writes set it to the node they pinned), and `node` on `PATH` otherwise.

When it cannot find the node CLI it prints the path it looked at, says the binary has to stay in `<root>/target/<profile>/` next to a built `packages/core/dist/cli/main.js`, and exits 2. A binary copied anywhere else does not find the node CLI. When the node cannot be started it exits 127 if there is no such file and 126 if there is one that cannot run.

## Which program a command goes to

The verbs live in `spec/cli/tagents-core.json`, described by `spec/cli/cli-spec.schema.json`. Each command says `"impl": "rust"` or `"impl": "node"`, and may carry an `effect` (`read`, `write`, `spawn`, `destructive` or `serve`) and `"tool": false`, which the plugin contract generator reads. The node CLI reads the file (`packages/core/src/cli/spec.ts`), the contract generator reads it through the node CLI, and the Rust crate `tagents-spec` embeds it, so moving a verb between languages is a one-word edit that leaves the generated plugin contract untouched. `pnpm plugin:gen` then shows no diff, and a test in `crates/tagents-core/tests/front_door.rs` checks that `tagents-core --spec` prints exactly the `rust` entries of the file.

Both loaders refuse the structural mistakes the schema forbids: a key the schema does not name, an empty `program` or `summary`, an empty `path`, an empty word in `path`, `positionals` or `required`, and a `null` where the schema says string or boolean. Both add the one rule a schema cannot state, that two commands never share a `path` (dispatch is by path, so the second would never run). The Rust loader is the stricter one: no input is known that it loads and the node loader refuses. It refuses three inputs the node loader accepts: an `exit` value written `1.0` (the number 1 to JavaScript, a non-integer to the `u8` the model holds), a key written twice in one object (`JSON.parse` keeps the last), and a lone surrogate escape in a string (`JSON.parse` accepts it); a unit test in `crates/tagents-spec/src/lib.rs` pins each. The path to the data file in `packages/core/src/cli/spec.ts` (`SPEC_FILE`) leads out of `packages/core`, so the package works from a checkout and from `$TAGENTS_HOME`, which is one, and would not work from a packed tarball (`files` is `dist`, which does not hold the data file). Nothing publishes or packs the package, and the repository installs from a clone; the package is not marked `private` because the plugin contract lists the public API of every package that is not.

The one-line summary of a command stays in the language catalogue (`packages/core/src/i18n/`), keyed by the `summary` field, so there is one source of the text.

## The MCP server

`tagents-core mcp --contract <file>` is the plugin's MCP server: JSON-RPC, one message per line, on stdin and stdout, with one tool for every command of the `cli` section of the contract. It is a port of `packages/mcp`, which stays in the tree as the oracle of the parity suite and as the server a machine without the Rust binary runs. The contract is read once, at start (`crates/tagents-core/src/mcp/contract.rs`), so a plugin update brings a new file and the next session sees the new tools. `plugin.json` is unchanged: it registers the wrapper `tagents-mcp`, which `install.sh` writes to start `tagents-core mcp --contract <contract.json>` when the Rust binary exists at install time and `packages/mcp/dist/main.js` otherwise.

```sh
target/release/tagents-core mcp --contract contract.json                    # serves until stdin ends or SIGTERM, SIGINT or SIGHUP arrives
target/release/tagents-core mcp --contract contract.json < requests.jsonl   # a request a line, an answer a line
```

The code is in `crates/tagents-core/src/mcp/`: `contract.rs` reads the file, `tools.rs` makes the tool of each command (name, description, annotations, input schema) and the command line a call stands for, `run.rs` runs one call, `server.rs` is the loop and `rpc.rs` is the wire. Stdout carries JSON-RPC lines and nothing else: the module denies `print_stdout`, and `rpc::Out` is the only writer.

**What it answers.** `initialize` answers the protocol version the client asks for when the SDK of `packages/mcp` lists it (`2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`, `2024-10-07`; the suite reads the list from the SDK) and the newest otherwise, and tells `serverInfo.version` as the workspace version, where the node server's constant is `0.1.0`. Then `ping`, `tools/list`, `tools/call` and the notification `notifications/cancelled`. Any other method is -32601 `Method not found`, and a call of a tool nobody listed is -32602. A command is a tool unless its spec entry says `"tool": false` or its effect is `serve`, so `mcp` is not one. `contract.json` records the list the generator made from the specs, and a test (`crates/tagents-core/tests/mcp_server.rs`) pins the list `tools.rs` makes from the same file to it.

**Threads.** The main thread reads stdin and answers `initialize`, `ping` and `tools/list` itself. Each `tools/call` runs on a thread of its own, so a slow call does not hold up the next request, and the answers are written in the order the calls finish, not the order they came in. One writer behind a lock writes each message with a single `write_all`, so two answers never interleave. A thread of its own takes SIGTERM, SIGINT and SIGHUP from `signal-hook`'s iterator and starts the same ending as the end of stdin, so no signal handler runs arbitrary code.

**A call.** The program of the verb runs as a child with no stdin, the server's environment and a process group of its own. Each stream keeps its first 256 KiB: the rest is read and thrown away so that the program never blocks on a full pipe, and the cut falls before a character it would split, followed by `\n[output cut at 262144 bytes]`, with `"truncated": true` in the result. A call that has not ended in five minutes, a `notifications/cancelled` for its request, and the end of the server each stop the whole group: SIGTERM, then SIGKILL two seconds later. When the program exits by itself, whatever it left in its group is killed at once and the pipes get 250 ms to drain, because a process that left the group can hold them open for good. Nothing a call starts in that group outlives the call. A process that called `setsid` has left the group, is not the call's to stop and keeps running, as it does under the node server; `a_holder_of_the_pipes_that_left_the_group_cannot_be_killed_and_still_does_not_hold_the_call_longer_than_the_drain` in `crates/tagents-core/tests/mcp_run.rs` pins that such a holder of the pipes still does not hold the call longer than the drain. The constants are pinned to the TypeScript sources by `crates/tagents-core/tests/mcp_pins.rs`, which reads `packages/mcp/src/run.ts` and `main.ts`.

**The result** is `{"content": [{"type": "text", "text": <body>}], "isError": <exit is not 0>}`. The body is the two-space pretty form of `exit`, `outcome` (the first name of the program's `exit` table that carries the code, else `exit <code>`), `stdout`, `stderr` and, when a stream was cut, `truncated`. A refusal has the same shape, with an empty stdout and the reason on stderr. When stdout, after leading JavaScript white space, starts with `{` or `[` and parses as JSON, the body holds the parsed value and not the escaped text; only JSON white space (space, tab, line feed, carriage return) may stand before the document, as in node, so a document behind a no-break space stays text. Node reads that document and writes it again, so the Rust server keeps the order of the keys (`preserve_order`) and tells every number as `JSON.stringify` tells the double it reads as: `1.0` is `1`, `1E2` is `100`, `-0` is `0`, `1e400` is `null` (`js::number_text`, `mcp/run.rs`).

**The ending.** The end of stdin, one of the three signals, or a write error on stdout (the client is gone) ends the server: every call in flight is stopped and answers with the outcome `cancelled`, the server waits until they have answered, for the two seconds of the grace plus two more at the most, and exits 0. A second signal during the ending is caught and ignored (`mcp/mod.rs`), so a program that ignores SIGTERM still gets its SIGKILL after the grace. A call stopped by `notifications/cancelled` gets no answer, as with the SDK, even if it had finished by then. The answer is written before the call leaves the registry the ending waits on (`Registry::settle` and `finish` in `server.rs`): a registry that empties first lets the process exit with the answer unwritten, which a test pins (`the_ending_returns_only_after_the_answers_of_the_calls_it_stopped_are_written`). A request line longer than 10 MiB, the SDK's `STDIO_DEFAULT_MAX_BUFFER_SIZE`, is treated as the end of the stream.

## Where the binary is looked for

| who | looks at, in this order |
|-----|-------------------------|
| `tagents` (for a verb it does not know) | `tagents-core` on `PATH`, then `target/release/tagents-core` beside the script when it is executable, then the built `packages/core/dist/cli/main.js` |
| the `tagents-core` wrapper from `install.sh` | `$TAGENTS_HOME/target/release/tagents-core` while it is executable, then the node CLI |

`install.sh` names the Rust binary in the wrapper only if the binary is executable when the installer runs. With none, the wrapper is byte for byte what the installer wrote before a Rust binary existed. A binary that is there and cannot run is an error that is reported, not a reason to fall back silently; a binary that has been removed is not an error, and the wrapper runs the node CLI. A directory at the binary's path is not a binary either.

A binary built by hand goes stale. `target/` is ignored by git and nothing rebuilds it, so after `tagents update` or a `git pull` an older `cargo build --release` keeps answering `sessions` until the next `cargo build --release`. For `tagents-mcp` the installer asks a hand-built binary `--version` once per install (`install.sh:295`) and names it only when it answers `tagents-core <version of the checkout>`; otherwise `tagents-mcp` runs the node server, while `tagents-core` still names the binary, because every verb it lacks goes to the node CLI. A checkout with no `Cargo.toml` keeps naming the binary; a `Cargo.toml` whose version cannot be read (a pre-release such as `0.2.0-rc.1`, an unreadable file) names none. Rebuild after every update. The prebuilt binary cannot go stale that way: on every run the installer compares its marker with the version of the checkout ("How the installer fetches it").

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
sh .github/scripts/core-release.sh version     # 0.2.0
git tag v0.2.0 && git push origin v0.2.0       # starts the release workflow
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

`tests/rust-mcp-parity.sh` does the same for the server. It feeds one script of requests to `node packages/mcp/dist/main.js --contract F` and to `target/debug/tagents-core mcp --contract F` (or `$TAGENTS_CORE_BIN`) under `env -i`, with stub programs on `PATH` and a scratch home, so no real tagents program runs, and passes a scenario only when the two transcripts are the same bytes once `serverInfo.version` is dropped. A transcript is every answer keyed by request id, the order the answers came in, how the server ended and which processes of the call were still alive after it; the typed client that writes it is `tests/rust-mcp-parity-driver.mts`. The scenarios are `initialize` with every protocol version the SDK lists and one it does not, `tools/list` on a fixture that has every feature of a spec, on an empty contract and on the bundled `contract.json`, the command line of every path of `argvFor` and about twenty refusals, every exit code, JSON and text output (white space before the document, numbers, key order, deep nesting), output cut at the cap, across a character and on both streams, a missing program, `requires: tmux`, cancellation, two calls in flight, the end of stdin and each signal with a call running, and a program that leaves a child holding its pipes. Tripwires assert on the node transcript alone, so a scenario that stops provoking what it exists for fails and does not pass for nothing. Timeouts and the grace are not in the suite, because both come from constants; `crates/tagents-core/tests/mcp_run.rs` takes them as arguments.

```sh
pnpm install && pnpm build
env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/rust-mcp-parity.sh
PARITY_ONLY="JSON numbers" PARITY_SHOW=300 bash tests/rust-mcp-parity.sh    # the scenarios whose label holds the text, with both transcripts cut at 300 characters a line
```

It needs a built node server and node 22.18 or newer (the driver is TypeScript run as it is), builds the debug binary when it is missing, and uses no real home, no tmux server and no network. `tests/rust-parity.sh` never runs `mcp`. `cargo test` carries the node server's own tests, ported: every case of `packages/mcp/test/*.test.ts` has a Rust test in `mcp/*.rs` or `crates/tagents-core/tests/mcp_{run,server,pins}.rs`, except the one named in the last item of the list below.

## Where the two are known to differ

These are the differences the port does not hide, and the suite does not cover them:

- `tagents-core --spec` prints the spec as JSON on the Rust binary and is a usage error on the node CLI, so which program the wrapper picks changes what that call does.
- `tagents-core --version`, as the only argument, prints `tagents-core <workspace version>` and exits 0 on the Rust binary; the node CLI has no such flag and reports a usage error. It is the one identity check the installer makes of a downloaded binary, so it is not in `spec/cli/tagents-core.json`, which would move the plugin contract. With more words after it the flag is the node CLI's.
- A search word that holds U+FFFD can match a lone surrogate escape (`"\ud800"`) in a transcript, because Rust reads the escape as U+FFFD where a JavaScript string keeps the lone half.
- Lower casing uses the Unicode data of the Rust standard library, where node uses ICU's. Both gave the same result for every scalar value on node 22, and a newer node that knows a newer Unicode version can differ first.
- An I/O error is worded as node words it for `ENOENT`, `EIO`, `EACCES`, `ENOTDIR`, `EISDIR` and `EMFILE`; any other error number prints Rust's description.
- A directory entry whose name is not UTF-8 is not listed. Node lists it with U+FFFD in the name, and the next `stat` on that name fails there.
- A modification time that `Date` cannot represent, and a `HOME` that is unset (the suite always sets it, empty at times), are not covered.

The MCP server differs from `packages/mcp` in these ways. The suite leaves them out, or pins the Rust side alone:

- A second signal during the ending: node dies by a repeat of the same signal (`process.once` in `packages/mcp/src/main.ts:18-33`), so a program that ignores SIGTERM outlives the call with no SIGKILL; the Rust server ignores the second signal and finishes the ending.
- A request whose `params` do not have the shape the method needs is -32602 `Invalid params: <reason>` on the Rust server; node answers -32603 with the text of its schema library. `initialize` checks fewer fields than the SDK's schema (only that `capabilities` is an object and `clientInfo` has string `name` and `version`), so a body such as `"capabilities":{"roots":5}` is answered where node refuses it.
- The calls an ending stopped (stdin closed, a signal) are always answered `cancelled` by the Rust server. Node races `process.exit` against writing those answers, so which of them arrive changes from run to run; the suite drops them from the comparison and pins the Rust ones (`rust_answers`).
- A lone surrogate escape in a *request* is read as U+FFFD, which is what node's spawn passes to the program, so the calls match (the parity scenario "a request with lone surrogate escapes" proves it). Where a server writes a request string back (the name in `unknown tool <name>`, the `id` of a request), Rust writes U+FFFD and node writes the escape. A request nested deeper than 128 levels is ignored by Rust (`serde_json`'s limit) where node answers it.
- Program JSON that `serde_json` does not read stays text where node parses it: a lone surrogate escape (`"\ud800"`) in a program's output and a document nested deeper than 128 levels. The keys of an object that are integers are not moved to the front, as JavaScript moves them.
- A call argument named like a member of `Object.prototype` (`constructor`, `toString`) is refused as unknown, where node lets it through and ignores it.
- A program that cannot be started for a reason other than a missing file reports the operating system's text as Rust words it, not as Node does, and the child leads a process group of its own, not a session, and stays that way: `Command::setsid` is unstable in rustc 1.99.1 (rust-lang/rust#105376, error E0658) and `pre_exec` needs `unsafe`, which the crate forbids. When the server has a controlling terminal, the call keeps it: a program that opens `/dev/tty` and reads is stopped by SIGTTIN (a write by SIGTTOU when the terminal has `tostop`), where node's child, a session leader without a terminal, fails at once with ENXIO. The call still ends, because cancellation and the 5-minute limit send SIGTERM to the group and SIGKILL after the 2 s grace, and no verb of the contract opens the terminal (`plugin add` records configuration and spawns no git).
- A `notifications/cancelled` that arrives in the same read as its request: node never starts the program, the Rust server may start it and stop it at once.
- A pipe that a process outside the group holds open costs one blocked reader thread until it lets go; node destroys the stream.
- A server started with SIGCHLD ignored gets ECHILD from `waitid` (`run.rs:361-373`) and reports a program that exited 0 as having no exit code; Claude Code starts its servers through libuv, which resets every signal disposition to the default in the child before exec.
- The usage line and the start-up failures say `tagents-core mcp` and not `tagents-mcp`, and a missing or invalid contract file is worded in Rust's words; the suite compares their exit codes only.
- The node CLI does not know `mcp`, and its list of reserved words (`reserved: session · sessions · plugin · config · doctor · help`, pinned by `packages/core/test/plugin-commands.test.ts`) is unchanged, so it still lets a plugin name a verb `mcp`; behind the front door that word is always the server's.
- `parseCliContract` has no Rust counterpart. The node server never calls it (only the generator in `packages/contract` does), so the one test of `contract-file.test.ts` that reads a spec with a program name of its own through it is not ported.

## Rules for the Rust code

- `unsafe` is forbidden, and `unwrap` and `expect` are denied outside tests, for the whole workspace (`Cargo.toml`, `crates/clippy.toml`).
- No async runtime. Every dependency is a row of the table below with its reason and its cost, and a new one is a new row.

| dependency | used by | reason | cost |
|------------|---------|--------|------|
| `serde` (derive) | `tagents-spec` | reads the data file into a typed model that refuses unknown fields | `serde_derive`, `syn`, `quote`, `proc-macro2`, `unicode-ident`, `serde_core` at build time |
| `serde_json` | `tagents-spec`, `tagents-core` | parses the data file, prints `--spec`, speaks JSON-RPC and reads the contract | `itoa`, `memchr`, `zmij`; its parser is not used for transcripts (`json.rs`) |
| `serde_json` features `preserve_order`, `arbitrary_precision` | `mcp` | a program's JSON keeps the order of its keys and the digits of its numbers, and the contract's maps keep the file's order | `indexmap`, `equivalent`, `foldhash`, `hashbrown`; the features are additive, so they apply to every crate of the workspace |
| `rustix` (feature `process`) | `mcp::run` | signal a process group and wait for a child without reaping it, in safe code (`unsafe_code = "forbid"` stays) | `bitflags`, `errno`, `libc` |
| `signal-hook` | `mcp::server` | end on SIGTERM, SIGINT or SIGHUP from a thread, in safe code | `signal-hook-registry` |

The three rows of the server add 10 crates (24 names in the build of `tagents-core` instead of 14, 22 of them external instead of 12), raise the release binary (`lto`, one codegen unit, `strip`) from 518,992 to 802,752 bytes, 283,760 of them, and a clean `cargo build --release -p tagents-core` from 8.8 s to 12.5 s on an Apple silicon laptop. The bytes include the server's own code, and the dependencies cannot be measured apart from it, because the server does not build without them. `rustix` has what `mcp::run` calls, `waitid` with `NOWAIT` and `kill_process_group`, on the three targets of the release, `aarch64-apple-darwin`, `x86_64-apple-darwin` and `x86_64-unknown-linux-musl` (`rustix` 1.1.6, the `cfg` of `src/process/wait.rs` and `src/process/kill.rs`); the dry run of `release.yml` on a pull request builds all three, and if one of them ever fails, `nix` is the substitute. Against it the server saves memory and start-up time: an idle `tagents-core mcp` has a footprint (`footprint <pid>`) of 1.6 MB and the node server 38 MB, and the time from spawn to the answer of `initialize` is 3.2 ms against 99.7 ms (median of ten runs each).
- `cargo fmt --all --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings` and `cargo test --workspace --locked` run in CI (`.github/workflows/rust.yml`) after `pnpm install`, because the smoke test of the MCP server calls the node CLI from its sources (it skips that half where `node_modules` is missing), together with the parity suite, the version gate, and the shell suites `tests/release.sh` and `tests/install.sh`.

## What is not decided yet

How plugins (JavaScript) are hosted once more of the CLI is Rust, and which verbs move next, are open. The change that introduced the front door, `openspec/changes/rust-core/`, lays out the slices and the three options for the plugin host. Signing or notarising the archives is not done (see the last paragraph of "How the installer fetches it"), and a Windows build does not exist.
