The tasks widen the MCP loop of `tagents-core` (`openspec/specs/rust-mcp/spec.md`) and the front door, and add the knowledge code beside them. Every shell suite runs as `env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/<suite>.sh`; the commands below name the suite only. Each group writes its tests first and watches them fail for the expected reason.

The change ships in three pull requests, merged in this order, each leaving the node arrangement working. (a) Groups 1 to 6: the vectors, the dependencies, the document reader, the index, the search and the usage store, which no verb calls, and the busy timeout of the node opener of the index (tasks 4.5 and 4.6). (b) Groups 7 to 13: the generated files, the widened loop, the argument checker and the tools, the socket and the daemon, `join`, `serve` and `mcp`, the three verbs (the entries of `spec/cli/tagents-core.json` and the arm of `front_door.rs`, task 12.3, are the last task of the code, after everything they call), the differential suite and the architecture document; nothing names the verbs, so the node arrangement runs. (c) Groups 14 to 17: the installer's word list, the launcher, the measurements and the archive; it changes no input of the binary and names the verbs only for a binary of the checkout's version. (a) and (b) change inputs of the binary and each raises the workspace version above its merge base (tasks 6.7 and 13.8). The archive of this change comes with (c).

## 1. The vectors

Pull request (a).

- [x] 1.1 `tests/rust-knowledge-vectors.mts` and `tests/rust-knowledge-vectors/*.mts` run the node code of `packages/knowledge` and its MCP SDK over the corpus and write `crates/tagents-core/tests/fixtures/knowledge-vectors.json` with: the parsed documents and sections of `packages/knowledge/test/fixtures/knowledge` and `okf` and of generated edge cases (a byte-order mark, CRLF, the legacy `kind`, tags that are not strings, each status, dates with offsets, a day that does not exist, code fences in sections, and the front matters of the YAML differential: explicit and custom tags, an empty document, complex mapping keys, integers above 2^53, anchors and aliases, flow and block scalars, six malformed documents), the match expression of each query, the rows each query returns with their scores, the usage reports under a fixed clock (`node tests/rust-knowledge-vectors.mts`, exit 0)
- [x] 1.2 The same file holds the cases that need no database: the DDL text and the schema version, a digest per block of 256 code points of the terms the index's tokenizer gives each code point of the Basic Multilingual Plane, of U+10000 to U+3FFFF and of U+E0000 to U+E01FF (read through an `fts5vocab` table of type `instance`), the document hash and the modification-time arithmetic for pairs of seconds and nanoseconds within a double's rounding of a millisecond (the generator fails when its formula differs from `statSync(file).mtimeMs` for files set with `utimesSync`), the table of environments with the socket directory each gives (`TMPDIR` unset, blank, padded, with a trailing slash, long enough for the fallback, `TMP` and `TEMP`) and the resolved `NAME=value` lines a key is made of (the key itself depends on the program's build and is not a vector), the table of argument lists of `serve` with the exit code and the option named, the battery of invalid arguments run through the SDK with each message, ids that differ in UTF-16 order, and the busy timeouts of the index and of the usage store as the node modules export them (`node tests/rust-knowledge-vectors.mts`, exit 0)
- [x] 1.3 Running the generator twice writes the same bytes, and the file carries the node and SDK versions that wrote it (`node tests/rust-knowledge-vectors.mts && git diff --exit-code crates/tagents-core/tests/fixtures/knowledge-vectors.json`)
- [x] 1.4 `rust.yml` lists the generator, its directory and the knowledge package's sources in both `paths` lists, regenerates the file and fails on a diff, as for the notify vectors (`actionlint`)

## 2. Dependencies, the musl step and the shared code

Pull request (a).

- [x] 2.1 `rusqlite` (feature `bundled`), `saphyr` and `sha2` are declared in the workspace `Cargo.toml` with a comment each, and the dependency table of `docs/architecture/rust-core.md` gains their rows with the reason and the crates they add (the measured cost is task 16.2) (`cargo build -p tagents-core --locked`, `cargo tree -p tagents-core --depth 1`)
- [x] 2.2 `release.yml` installs `musl-tools` before the musl build (`actionlint`; the `release` workflow of the pull request builds the three targets, `gh run list --branch <branch>`)
- [x] 2.3 Nothing is lifted into a new module: `config_dir` and `config_dir_from` of `host.rs` and `Locale` of `messages.rs` are already public on `origin/main` and the knowledge code uses them from there, `not_blank` of `host.rs` is private and (b) makes it `pub(crate)` where it first needs it, so there is no `config.rs` and no `locale.rs` (`git diff origin/main --stat -- crates/tagents-core/src/lib.rs`, `cargo test -p tagents-core --lib notify`)
- [x] 2.4 `node.rs` gains a floor variant of `mtime_ms` that uses the arithmetic of node's `Stats`, with a test against the vectors written first; `resolve` is the one `origin/main` has, and `tmpdir` (task 10.2) comes with its only caller in (b) (`cargo test -p tagents-core --lib node::`)
- [x] 2.5 No `unsafe`, `unwrap` or `expect` is added outside `#[cfg(test)]` (`cargo clippy --workspace --all-targets --locked -- -D warnings`, `git diff origin/main -- crates | grep -n 'unsafe\|unwrap\|expect'` shows only test code)

## 3. The document reader

Pull request (a).

- [x] 3.1 Tests first: every parsed document and section of the vectors, the legacy mapping, the refusals and the dates (`cargo test -p tagents-core --test knowledge_doc`, failing before 3.2)
- [x] 3.2 `knowledge/doc.rs` splits a file at its front matter (a byte-order mark stripped), applies the field rules of `doc.ts` (`type` or the legacy `kind`, tolerant fields, `tags` keeping strings, `status` exact, offset datetimes), cuts sections, and lists a folder (`.md` files sorted, no dotfile, `index.md`, `log.md` or directory, a stem that is a slug) (`cargo test -p tagents-core --test knowledge_doc`)
- [x] 3.3 `knowledge/front_matter.rs` reads YAML 1.2 with `saphyr` and converts it to the values `doc.ts` receives: an explicit core tag applied, a custom tag dropped, an integer above 2^53 cast through `f64` and printed by `js::number_text`, a null or empty document as no fields, a non-mapping refused (`cargo test -p tagents-core --lib knowledge::front_matter`)
- [x] 3.4 The known differences of the reader are listed in the design and in `docs/architecture/rust-core.md` ("Where the two are known to differ"): the wording of YAML errors, complex mapping keys, the explicit core tags the parser resolves itself, the `%YAML 1.1` directive, hexadecimal and octal integers beyond `i64`, `\u` surrogate pairs, a tab after `?`, control characters in scalars and a tagged empty scalar, each a case of a table that fails when a difference appears that is not listed or a listed one goes away; a tab after a mapping colon is closed by a retry in the parser and a CRLF document by the fix in `doc.ts` (`cargo test -p tagents-core --test knowledge_doc`, `cargo test -p tagents-core --lib knowledge::front_matter`)

## 4. The index

Pull request (a).

- [x] 4.1 Tests first: the DDL text of the vectors, the rows of `docs` and `chunks` for the corpus, the reindex cases (unchanged time unread, changed time with the same hash not reindexed, an edit reindexed, a vanished file deleted, a file that stops parsing deleted and restored), a schema of another version rebuilt, a current one not, and an open that waits for a write another connection holds for 400 ms (`cargo test -p tagents-core --test knowledge_index`, failing before 4.2)
- [x] 4.2 `knowledge/index.rs` opens the file without changing its journal mode, sets the busy timeout of the vectors, writes the `meta` rows only when they differ, and reindexes by the rules of `db.ts` (the hash is over the text node decodes, a byte-order mark kept and an invalid byte as U+FFFD) in one short transaction (`cargo test -p tagents-core --test knowledge_index`)
- [x] 4.3 The tokenizer sweep: the Rust program tokenizes every code point of the Basic Multilingual Plane, of U+10000 to U+3FFFF and of U+E0000 to U+E01FF, except the surrogates, through an `fts5vocab` table of type `instance` over a table with the index's tokenizer, and the digest of each block of 256 equals the one in the vectors, or each difference is listed (`cargo test -p tagents-core --test knowledge_index tokenizer`; the live comparison that names the code point is a scenario of 13.1)
- [x] 4.4 `pragma compile_options` of the bundled SQLite is compared with node's and each option that can change a result is equal or listed (`cargo test -p tagents-core --test knowledge_index compile_options`)
- [x] 4.5 Tests first: `packages/knowledge/test/index.test.ts` holds the index open for writing in a second process for 400 ms and opens the index in this one, which must wait and succeed and not throw `database is locked` (`pnpm --filter @tagents/knowledge test`, failing before 4.6)
- [x] 4.6 `db.ts` exports the constant `INDEX_BUSY_TIMEOUT_MS` (5000) and `openDb` runs `pragma busy_timeout` with it before its first write, in its own commit `fix(knowledge): wait for a lock on the index` (`pnpm --filter @tagents/knowledge test`)

## 5. Search, list and get

Pull request (a).

- [x] 5.1 Tests first: every expression and every result row of the vectors, with equal ranks, deprecated last, Cyrillic and Latin diacritics, a trailing `*`, a refused expression as an empty result, the filters `tag`, `type` in another case, the alias `kind` and `limit` (`cargo test -p tagents-core --test knowledge_search`, failing before 5.2)
- [x] 5.2 `knowledge/search.rs` builds the expression, ranks with `bm25(chunks_fts, 0.0, 10.0, 1.0)`, cuts the snippet with `'[', ']', '…', 14`, orders by `(docs.status = 'deprecated')`, rank, document id and section order, and rounds the score to three decimals (`cargo test -p tagents-core --test knowledge_search`)
- [x] 5.3 `list` and `get` return the documents with their computed fields (`stale`, `updated`, `headings`), a whole document or one section by a heading matched without case, the line for a missing document, the line for a missing section with the headings the document has, and the line for a file that is gone (`cargo test -p tagents-core --test knowledge_search`)

## 6. The usage store

Pull request (a).

- [x] 6.1 Tests first: the DDL, the retention applied in the transaction that inserts, recording that never fails (a read-only file, a directory in place of the file), the reports of the vectors with every argument, ids that differ in UTF-16 order, a store that is not there or has no table, and a store that is not a database (`cargo test -p tagents-core --test knowledge_usage`, failing before 6.2)
- [x] 6.2 `knowledge/usage.rs` opens and closes the store per call with WAL attempted and a failure to switch tolerated, a 250 ms busy timeout and `synchronous = normal`, records one transaction per call, and reports with the SQL of `usage.ts` through a read-only connection (`cargo test -p tagents-core --test knowledge_usage`)
- [x] 6.3 The caller of an event is the name the client gave in the handshake or nobody, and `TA_LABEL` is not read (`cargo test -p tagents-core --test knowledge_usage caller`)
- [x] 6.4 Nothing in (a) is reachable from a verb: `knowledge` is a library module that `front_door.rs` does not name, and the node arrangement is what runs (`cargo build -p tagents-core --locked --release`, `target/release/tagents-core knowledge join` is handed to the node CLI)
- [x] 6.5 `pnpm spec:check` accepts this change, and `pnpm exec openspec validate rust-knowledge --strict` does
- [x] 6.6 Everything of (a) passes on both systems (`cargo test --workspace --locked`, `cargo clippy --workspace --all-targets --locked -- -D warnings`, the `rust` workflow on macOS and Linux)
- [x] 6.7 The release gate: the version of `Cargo.toml`, `Cargo.lock` and the version lines of `docs/architecture/rust-core.md` take a higher version than the merge base's (`sh .github/scripts/core-release.sh gate origin/main`, exit 0)

## 7. The generated files

Pull request (b).

- [x] 7.1 Tests first: `packages/knowledge/test/embedded.test.ts` asserts that `crates/tagents-core/src/knowledge/tools.json` equals the `tools/list` of the node server and `texts.json` equals `badIdle` and `serveFailed` of the catalogue in both languages, so a changed tool description, a tool added or reordered and a changed text each fail it (`pnpm --filter @tagents/knowledge test`, failing before 7.2)
- [x] 7.2 `tests/rust-knowledge-embed.mts` reads `tools/list` from the node server through the in-memory client of `packages/contract/src/sources.ts:64` and writes `tools.json`, and writes `texts.json` from `packages/knowledge/src/i18n/{en,ru}.ts` (`node tests/rust-knowledge-embed.mts && git diff --exit-code crates/tagents-core/src/knowledge`, `pnpm --filter @tagents/knowledge test`)
- [x] 7.3 `rust.yml` runs the generator and fails on a diff, and lists the generator and the sources it reads in its `paths` (`actionlint`)

## 8. The widened loop

Pull request (b).

- [x] 8.1 Tests first: the identity and capabilities of the handshake as parameters, the client's name handed to the tools at `initialize`, raw list entries, a result for an unknown tool, and a connection's end that closes the connection and not the process (`cargo test -p tagents-core --test mcp_server`, failing before 8.2)
- [x] 8.2 `mcp/server.rs` takes its identity from `Config`, `Tools` gains `connected` with a default, `list` returns raw entries and each connection has a `Tools` value of its own; the `tagents` server passes its old identity and entries (`cargo test -p tagents-core --test mcp_server`, `bash tests/rust-mcp-parity.sh`, every existing test unchanged)
- [x] 8.3 `ToolEntry` of `mcp/rpc.rs` and its callers are replaced or widened without a second copy of the framing, the thread per call or the ending (`cargo test -p tagents-core --lib mcp::`, `bash tests/rust-parity.sh`)

## 9. The tools and the argument checker

Pull request (b).

- [x] 9.1 Tests first: the battery of the vectors, each message and the order of the issues, the missing arguments object without an `at`, unknown keys accepted (`cargo test -p tagents-core --test knowledge_args`, failing before 9.2)
- [x] 9.2 `knowledge/args.rs` checks arguments against the `inputSchema` of `tools.json` and writes the lines zod 4 writes, so the list and the checks come from one file (`cargo test -p tagents-core --test knowledge_args`)
- [x] 9.3 `knowledge/tools.rs` serves the six tools: the four knowledge tools over the index and the usage store, the two session tools over `sessions.rs` with the limit of 50 and the words split at white space, the text of a tool in English, the line for an unknown tool (`cargo test -p tagents-core --test knowledge_tools`)
- [x] 9.4 A call opens the index, reindexes, answers and closes, so a document edited between two calls is read at the second, and the folder, the index and the usage paths are resolved as `paths.ts` does (`path.resolve(expandHome(value))`: a value that starts with `file:` becomes an absolute path, so `TAGENTS_KNOWLEDGE_DB=file:rel.db` creates a file named `file:rel.db` in the working directory of both programs, and a vector pins it), with the lines for an unset or missing folder (`cargo test -p tagents-core --test knowledge_tools`)
- [x] 9.5 `reindex` takes `BEGIN IMMEDIATE` on every pass (`knowledge/index.rs`), which makes every search a writer: node's pass runs without a transaction and an unchanged folder only reads. Measure two sessions searching at once over the corpus (two processes, each call timed alone and together, the numbers go to the architecture document); if the pass serialises them, plan the pass first (list the files, compare the modification times and hashes with the rows) and take the immediate transaction only when something will be written, with a test that a holder of the write lock does not delay a search over an unchanged folder (`cargo test -p tagents-core --test knowledge_tools`)
- [x] 9.6 When the tools bind `limit` and `top`, vectors pin `1e300`, `0` and negative values against node: `knowledge/search.rs` saturates a limit above the range of `i64` (`limit.floor() as i64`) where node binds the double, and the usage `top` keeps every row for a negative value where `slice(0, top)` of `usage.ts` drops the last ones (`cargo test -p tagents-core --test knowledge_tools`, `--test knowledge_usage`)

## 10. The socket and the daemon

Pull request (b).

- [x] 10.1 Tests first: the socket directory and the resolved lines of every environment of the vectors, a key that changes with each variable and with the binary's modification time and differs from what node's formula gives for the same variables, path and time, the directory's mode and owner rules, the 100-byte fallback (`cargo test -p tagents-core --test knowledge_socket`, failing before 10.2)
- [x] 10.2 `knowledge/socket.rs` holds the directory (`node::tmpdir`: `TMPDIR` trimmed, then `TMP`, `TEMP`, `/tmp`, one trailing slash removed, added to `node.rs` here with this caller), the key (SHA-256 over the variables and `code=rust:<path>:<modification time>`), the lock directory, the pid file and `ensure` with the waits of the design (3000 ms stale lock, 5000 ms lock wait, 8000 ms start wait, 10 ms poll) (`cargo test -p tagents-core --test knowledge_socket`)
- [x] 10.3 Tests first: two starters and one daemon, a dead socket replaced under the lock, a bind on a path that something answers on exits 0, idle exit counted from the last disconnect and from the start, a held-open client, a half-closed client released at once, rubbish and a cut-off line, a panic of a connection thread reported and survived, SIGTERM and SIGINT (`cargo test -p tagents-core --test knowledge_daemon`, failing before 10.4)
- [x] 10.4 `knowledge/daemon.rs` is one accept loop on `poll` over the listener and a wake pipe, a thread per connection, the idle decision taken after a drain of the backlog with only the accept loop adding connections, the socket and the pid file written and removed as the requirement says, and the fault line `tagents-knowledge: <what>: <detail>` (`cargo test -p tagents-core --test knowledge_daemon`)
- [x] 10.5 The daemon is spawned as `knowledge serve --foreground --socket P --idle S` in a process group of its own, in `/`, with no stdio (`cargo test -p tagents-core --test knowledge_daemon detached`)
- [x] 10.6 What a detached daemon keeps: its group differs from the starter's, its descriptors 0 to 2 are `/dev/null`, and a kill of the starter's group leaves it running, read with `ps -o pid,pgid,sess` and `lsof -p <pid>` on macOS and `/proc/<pid>/fd` on Linux, in the pull request description

## 11. join, serve and mcp

Pull request (b).

- [x] 11.1 Tests first: the argument table of the vectors for `serve` (exit code and option named), `--idle` read as `Number` reads it, `join` with an argument exits 2, and the two texts in each locale (`cargo test -p tagents-core --test knowledge_serve`, failing before 11.2)
- [x] 11.2 `knowledge/serve.rs` parses `--idle`, `--foreground` and `--socket` strictly, prints the socket after `ensure`, runs the daemon for `--foreground`, and prints `badIdle` and `serveFailed` from `texts.json` in the locale of `Locale::of` (`cargo test -p tagents-core --test knowledge_serve`)
- [x] 11.3 Tests first: input that ends releases the daemon, a daemon that leaves between the connect and the first reply (the retry, with the replay buffer capped at 64 KiB), a daemon killed after a reply (exit 1 and the stderr line), no daemon possible (served in process) (`cargo test -p tagents-core --test knowledge_join`, failing before 11.4)
- [x] 11.4 `knowledge/join.rs` is the byte relay of the design on two threads, with the shutdown of the write half at the end of input, one retry before the first reply byte, and the fallback to the server of this process (`cargo test -p tagents-core --test knowledge_join`)
- [x] 11.5 `knowledge::run` dispatches `mcp` (every word after it ignored), `serve` and `join` (`cargo test -p tagents-core --test knowledge_serve`)

## 12. The three verbs

Pull request (b).

- [x] 12.1 `packages/core/src/i18n/en.ts` holds the summaries of the three verbs and `ru.ts` stays without them, because new strings go into the English table only and a key the Russian table lacks falls back to it (`pnpm --filter @tagents/core test`)
- [x] 12.2 `spec/cli/tagents-core.json` gains `["knowledge","mcp"]`, `["knowledge","serve"]` (options `idle`, `foreground`, `socket`, all strings but `foreground`) and `["knowledge","join"]`, each `impl: rust` and `effect: serve`; `pnpm plugin:gen` regenerates the contract and the skill references, which gain three entries and no tool (`pnpm plugin:check`, `git diff --exit-code`)
- [x] 12.3 `front_door.rs` serves the three words in one streaming arm beside `mcp` and `notify run`, hands every other word after `knowledge` to node, and `--spec` prints the three entries; this is the last task of the code of (b) (`cargo test -p tagents-core --test front_door`, `target/release/tagents-core --spec`)
- [x] 12.4 `tagents-core knowledge search x` still reaches the node CLI, and a Rust binary that serves the verbs does not start node for `mcp`, `serve` or `join` (`cargo test -p tagents-core --test front_door`: in a scratch checkout with no `packages/core/dist` the three verbs run and `knowledge search x` exits 2 with the front door's line)

## 13. The differential suite, CI and the architecture document

Pull request (b).

- [x] 13.1 `tests/rust-knowledge-parity.sh` and `tests/rust-knowledge-parity-driver.mts`: scratch `HOME`, `TMPDIR`, config, index and usage paths and a copy of one corpus per program; the scenarios "handshake and list", "search diacritics and ties", "search filters and limit", "get a document and a section", "list", "usage with every argument", "the two session tools", "argument errors", "unknown tool and malformed line", "tokenizer sweep, live, naming the code point" (`bash tests/rust-knowledge-parity.sh`)
- [x] 13.2 The cross-engine scenarios "node builds, Rust reads", "Rust builds, node reads", "edit, touch, delete and break a document" and "usage recorded by one and counted by the other, with two client names" (`bash tests/rust-knowledge-parity.sh`)
- [x] 13.3 The daemon scenarios of `packages/knowledge/test/shared-server.test.ts` and `socket.test.ts` against both programs: "two sessions, one daemon", "two folders", "two usage stores", "a relative usage store", "a different TMPDIR", "a variable the server does not read", "four proxies meet a dead socket", "a held-open client against idle exit", "nobody connects", "garbage, then a real client", "a clean exit", "mode 0700", and for `join` "input ends", "the daemon leaves as the session arrives", "the daemon dies mid-session", "no daemon can start" (`bash tests/rust-knowledge-parity.sh`)
- [x] 13.4 Tripwires assert on the node transcript alone, the suite prints how many scenarios it skipped, and a first check fails when the process started as the Rust side is the node CLI (`bash tests/rust-knowledge-parity.sh`, `PARITY_ONLY=<scenario>`)
- [x] 13.5 Mutations of the Rust side each fail the scenario named for them and leave the suite green once restored: the weights swapped, the id tie-break left out, the modification time rounded, the hash over another text, the `meta` rows written when equal, the retention left out, a validation message reworded, the idle decision taken from a copy of the count made before the backlog is drained (a lock released between the decision and the leaving is an equivalent mutant, because only the accept loop adds connections), the pid file left behind; a mutation of what many scenarios compare fails each of them in a run of the whole suite (`PARITY_ONLY=<scenario> bash tests/rust-knowledge-parity.sh`, one failing line each)
- [x] 13.6 `docs/architecture/rust-core.md`: the server, the daemon, the SQLite decision with its measured cost, the parser policy, the dependency rows, the section on the MCP loop and the suite, and under "Where the two are known to differ" each difference of the design with its reason (`pnpm docs:build`)
- [x] 13.7 `rust.yml` lists the suite, its driver, the generator and `packages/knowledge/**` in `paths`, installs the node dependencies before the Rust steps and runs the suite after the existing parity steps on ubuntu-latest and macos-latest (`actionlint`; the `rust`, `ci` and `release` workflows succeed on the last head, `gh run list --branch <branch>`)
- [x] 13.8 The release gate: the workspace version is higher than the merge base's (`sh .github/scripts/core-release.sh gate origin/main`, exit 0), and `pnpm spec:check` and `pnpm exec openspec validate rust-knowledge --strict` accept this change

## 14. The installer's words

Pull request (c).

- [ ] 14.1 Tests first: `tests/install.sh` pins the `tagents-notify` wrapper byte for byte as it is, the `tagents-knowledge` wrapper with the binary and without it (the texts of the design), `join` and `mcp` alone and `serve` with no, one and several arguments reaching the binary, `mcp extra`, `join x`, `search x` and no arguments reaching node, and `join` without a binary exiting 69 with a stub `node` on `PATH` that records any start and was not started (`bash tests/install.sh`, failing before 14.2)
- [ ] 14.2 `write_wrapper` takes the knowledge wrapper's own rule (`serve` with any arguments, `join` and `mcp` alone) beside the one-word rule of `tagents-notify`, which keeps its text, writes the line `[ "$#" -ne 1 ] || [ "$1" != join ] || exit 69` before the `exec` of the node program in every `tagents-knowledge` wrapper, and `install_commands` names the binary of `tagents-core` with the word `knowledge` under the `--version` check of `tagents-mcp` (`bash tests/install.sh`)
- [ ] 14.3 With no binary the wrapper is the node wrapper plus the `join` line, a binary that vanishes or loses its executable bit falls through to node for `serve` and `mcp` and to exit 69 for `join`, and a binary of another version, `TAGENTS_NO_NATIVE=1` and a version without a release leave the wrapper with no binary (`bash tests/install.sh`)
- [ ] 14.4 Mutations of the installer each make `tests/install.sh` fail: the guard `"$#" -ne 1` left out of the notify wrapper, a word left out of the knowledge rule, `serve` limited to one argument, the word `knowledge` left out, the binary named when none is installed, the version check dropped, the `join` line left out, the code changed (`bash tests/install.sh`, one failing check each)
- [ ] 14.5 `shellcheck -s sh install.sh` has no finding that `origin/main` does not have (`shellcheck -s sh install.sh`)

## 15. The launcher

Pull request (c).

- [ ] 15.1 Tests first: a shell test runs `packages/knowledge/bin/knowledge-mcp` with a stub `tagents-knowledge` on `PATH` in a scratch directory and checks which program replaces it and what reaches stderr: `join` when the stub's `join` exits 0 on empty input with nothing on stderr; the old arrangement with nothing on stderr when `join` exits 69 and when it exits 2 (`nc -U` on the socket when `serve` prints one, `mcp` when there is no `nc` or no socket); and after exit 1, 3 and 127 the old arrangement with exactly one line on stderr that names the code (`bash tests/knowledge-launcher.sh`, failing before 15.2)
- [ ] 15.2 `packages/knowledge/bin/knowledge-mcp` probes `tagents-knowledge join` with no input and output of its own, replaces itself with `tagents-knowledge join` on exit 0, runs the old arrangement unchanged on 69 and 2, and writes one line naming the code to stderr before it does after any other code; its comment says what each line and each code is for and what the probe costs (`bash tests/knowledge-launcher.sh`)
- [ ] 15.3 Over a scratch install with the binary, the process a session starts is `tagents-core knowledge join`, with no node process and no `nc`; over a scratch install without it, the probe starts no node (a stub `node` on `PATH` records a start and the probe leaves none) and the session gets `nc -U` on the node daemon's socket, as before (`bash tests/knowledge-launcher.sh`, `ps` of the scratch process tree)
- [ ] 15.4 `docs/guide/claude-code-plugin.md` and `packages/knowledge/README.md` say what a session starts with and without the binary, and how to see which program serves (`tagents-knowledge join </dev/null; echo $?`, `footprint <pid>`) (`pnpm docs:build`)

## 16. Measurements

Pull request (c).

- [ ] 16.1 `footprint` of a `join` and of the Rust daemon, and of a node `tagents-knowledge mcp` and the node daemon, after the same search over the same five documents, and the time from the launcher's start to the first reply, in the pull request description
- [ ] 16.2 Release size, crates added and clean build time for `rusqlite`, `saphyr` and `sha2` on each of the three targets, in the dependency table of `docs/architecture/rust-core.md` (`ls -l target/release/tagents-core`, `cargo build --release --timings`)
- [ ] 16.3 The x86_64 musl build and the cross-built x86_64 macOS build pass in the release workflow, and the open question about them in the design is answered (`gh run list --branch <branch>`)

## 17. The changelog and the archive

Pull request (c).

- [ ] 17.1 `CHANGELOG.md` has one line under `[Unreleased]`: a session's knowledge server is the Rust binary when it is installed, joining one shared daemon with no node and no `nc`, and the node server stays as the way out (`grep -n 'knowledge' CHANGELOG.md`)
- [ ] 17.2 `pnpm spec:check` accepts the specs after the change is archived (`pnpm spec:check`)
- [ ] 17.3 This change is archived, as the last task, with the delta specs applied to `openspec/specs/` (`/opsx:archive`, `pnpm spec:check`)
