## Context

`packages/knowledge` is the node program behind `tagents-knowledge`. Its server (`mcp/server.ts`) offers six tools (`knowledge_search`, `knowledge_get`, `knowledge_list`, `knowledge_usage`, `sessions_recent`, `sessions_search`) on the official SDK, over stdio. Each call opens the index (`db.ts`, `node:sqlite`), brings it in line with the folder, runs one query and closes it. A second SQLite file, the usage store (`usage.ts`), receives one row per read, best effort. The plugin starts none of this directly: `packages/knowledge/bin/knowledge-mcp` runs `tagents-knowledge serve`, which prints the socket of one shared node daemon per environment (`mcp/daemon.ts`, `mcp/socket.ts`) and starts it when nothing answers, and then replaces itself with `nc -U` on that socket. Without `nc` or without a daemon it runs `tagents-knowledge mcp`.

`tagents-core` is the Rust binary of the port described in `docs/architecture/rust-core.md`. It serves `sessions`, the plugin's `tagents` MCP server (`mcp`) and the notification service (`notify run`), through a front door that execs the node CLI for every other word. Its MCP loop (`mcp/server.rs`) already speaks JSON-RPC over any reader and writer, runs each call on a thread of its own and ends cleanly on EOF or a signal. `sessions.rs` already reads the transcripts that `sessions_recent` and `sessions_search` need. What is missing is SQLite, a reader of the front matter, the knowledge rules themselves, and the code that finds, starts and serves a unix socket.

This change moves the server, the daemon and the proxy that joins a session to it. It builds the pieces the read verbs of the knowledge CLI need and does not move those verbs.

## Goals / Non-Goals

**Goals:**

- A session's server is the Rust binary: one small process that joins the shared daemon of its environment, or starts it, with no node and no `nc`, where the binary of the checkout's version is installed.
- The same six tools with the same answers: for one corpus, one index state and one usage store, every `tools/call` result is the same bytes from both programs.
- One index file and one usage store for both programs, so a machine can switch from one to the other at any moment and back, with no rebuild and no loss of what was read.
- The shared server of the Rust binary is a Rust daemon on its own socket, so the two programs never serve one socket.
- The node server, the node daemon and the node launcher arrangement stay in the tree and work after every merge; the node server is the oracle of the differential suite.
- The SQLite engine, the front-matter reader, the document rules and the socket code are built once, in modules the later ports reuse.

**Non-Goals:**

- The CLI verbs `index`, `search`, `show`, `list`, `usage`, `lint` and `toc` stay in node (see "Which CLI verbs move").
- Retiring `packages/knowledge`, its server, its daemon or its launcher arrangement.
- A change of the index schema, the tokenizer, the ranking or the usage format: this change reads and writes what exists.
- A knowledge server without a daemon, a Windows build, a replay of the handshake to a new daemon after one died.
- Tagging the version this ships in. A version without a release keeps the node server (the installer's rule).

## Decisions

### One binary, three verbs: `tagents-core knowledge mcp|serve|join`

Decision: three verbs of the binary, each `impl: rust` and `effect: serve` in `spec/cli/tagents-core.json`, so none is a tool of the plugin's `tagents` server. They are served by one arm of `front_door.rs`, beside the arms of `mcp` and `notify run`, because they stream or run until stopped and so cannot be a `Group` whose `run` answers with the whole output at once.

| verb | does | arguments |
|---|---|---|
| `knowledge mcp` | the knowledge server on stdin and stdout, in this process, until the client closes it | every word after `mcp` is ignored, as `tagents-knowledge mcp` ignores them |
| `knowledge serve` | prints the socket of the shared server of the caller's environment and starts that server when nothing answers; `--foreground` is the server itself | `--idle S`, `--foreground`, `--socket P`, parsed strictly (an unknown option, a positional or a missing value exits 2) |
| `knowledge join` | connects stdin and stdout to the shared server, starts it when absent, serves in this process when none can be started | none; any argument exits 2 |

```rust
// front_door.rs, beside the arms of `mcp` and `notify run`
const KNOWLEDGE: &str = "knowledge";
const KNOWLEDGE_VERBS: [&str; 3] = ["mcp", "serve", "join"];

if first == Some(KNOWLEDGE) && args.get(1).is_some_and(|v| KNOWLEDGE_VERBS.contains(&v.as_str())) {
    return knowledge::run(&args[1..]); // streams: never an `Output` built whole
}
```

Any other word after `knowledge` falls to the node CLI, which answers its own unknown-command line. `serve` accepts what `util.parseArgs` of the node CLI accepts (`--idle S`, `--idle=S`, a value that starts with `-` only in the `=` form, a repeated option, the last one winning); a table of argument lists that node generates, with its exit code and the option its message names, pins the Rust parser. `--idle` is read as `Number(value)` is and must be finite and positive, with `js::number` doing the conversion.

Rejected: a binary of its own, `tagents-knowledge-core` (a second artefact to fetch, checksum and version for no gain over a verb); `tagents-core mcp --knowledge` (the `mcp` verb is the plugin host's and takes `--contract`; a flag that switches the whole identity is two servers under one word).

### SQLite from Rust: `rusqlite` with `bundled`

Decision: `rusqlite` with the feature `bundled`, which compiles the C source of SQLite (3.54.1 at the version of the crate recorded in the probe) into the binary, FTS5 included.

| option | what it gives | what it costs |
|---|---|---|
| `rusqlite` `bundled` | one SQLite on all three release targets, FTS5 and `unicode61 remove_diacritics 2` in it, no system library | a C compiler in the build; `musl-tools` on the musl runner; about 1.76 MB more in a release binary (probe, 01.11.2026); a clean build of the probe takes 15.8 to 22.3 s |
| the system `libsqlite3` | no C source built | macOS has 3.51.0 with FTS5, but a static musl binary has no system library to link, a dynamic one ties the binary to the distribution's build options (FTS5 may be off), and every machine gets a different version |
| FTS written in Rust over a plain table | no C | the index file is node's FTS5 table: a hand-made index cannot be read by node's `MATCH` |

Why: the index file has to open in both programs, so the engine has to be SQLite with FTS5, and the only form that behaves the same on three targets and on every machine is the one built in. No form matches node's own version (3.51.3 inside Node 22.23.1), so parity cannot be bought by equal versions and is proven instead (next decision).

What was verified on 01.11.2026: the bundled probe opens FTS5 and the tokenizer; the macOS system library has FTS5; an aarch64 musl build in a container fails with `failed to find tool "aarch64-linux-musl-gcc"` without the `musl-tools` package and produces a 2,182,944-byte static ELF with it. Unverified: the x86_64 musl and the cross-built x86_64 macOS targets, until the dry run of the release workflow on the pull request. The workspace's own crates stay free of `unsafe`: the C is inside the dependency, and the `unsafe_code = "forbid"` lint reaches only the workspace's crates.

Rejected for the C compiler of the musl target: `cargo zigbuild`, because the release path builds with a plain `cargo build` and reports a link failure as a finding; the `musl-tools` package is the one step the finding asks for.

How the implementation measures the cost (task 16.2): release size with and without the dependency on each target, crates added to `Cargo.lock`, and clean build time on the three runners of `release.yml`, written into the dependency table of `docs/architecture/rust-core.md` as `rust-notify` did.

### One index file for both programs

Decision: the Rust program opens the `knowledge.sqlite` that node writes and writes the one node reads. It uses schema version 2 and the same tables (`meta`, `docs`, `chunks`, and `chunks_fts(doc_id unindexed, heading, body)` whose rowid equals the `chunks` rowid), the tokenizer `unicode61 remove_diacritics 2`, the expression `ftsQuery` builds (each word quoted, a trailing `*` kept as a prefix), `bm25(chunks_fts, 0.0, 10.0, 1.0)`, the snippet `'[', ']', '…', 14`, the order `(docs.status = 'deprecated') asc, rank asc, docs.id asc, chunks.ord asc`, the score `round(-rank * 1000) / 1000`, and an expression SQLite refuses as an empty result. It decides what to read again as node does: a file whose modification time (`Math.floor(mtimeMs)`) is unchanged is not read, one whose time changed is hashed (the first 32 hex digits of the SHA-256 of the text) and reindexed only when the hash differs, a file that vanished or stopped parsing is deleted from the index.

Two things are kept deliberately equal and are easy to get wrong:

- The modification time is node's double: `Stats` computes `sec * 1000 + nsec / 1e6` in a double, and `Math.floor` rounds that. The Rust value is the same arithmetic on the seconds and nanoseconds of the file, floored, and not an integer division of the nanoseconds, which differs for a time within a double's rounding of a millisecond. A mismatch would not give a wrong answer (the hash decides), but each program would rewrite the row at every call and the two would contend for the write lock. `node::mtime_ms` (`crates/tagents-core/src/node.rs:73`) rounds, which is what its other callers want, so a floor variant sits beside it.
- The hash is over the text node decodes: a byte-order mark stays in it, and an invalid byte becomes U+FFFD (`String::from_utf8_lossy` replaces as the WHATWG decoder does). Vectors hold a file with each.

How parity of `knowledge_search` is proven, in three layers:

1. Vectors. A generator on the node side (`tests/rust-knowledge-vectors.mts`) runs the node code over a corpus and writes `crates/tagents-core/tests/fixtures/knowledge-vectors.json`: the parsed documents and their sections, the expression for each query, the rows each query returns in order with their scores, the tie cases (two documents with equal sections, equal ids of a different case), and the argument batteries. The Rust tests read the file. Ties are decided by the full key above, which ends in a pair that is unique, so only a difference in `rank` itself can flip an order; the vectors hold sections whose ranks are equal, and the cross-engine suite compares them on the real engines.
2. A tokenizer sweep. Each program builds the same temporary `fts5` table with the tokenizer above, inserts one row per code point of the Basic Multilingual Plane, of U+10000 to U+3FFFF and of U+E0000 to U+E01FF except the surrogates (and a few readable samples beyond them) and reads the terms of each row back from an `fts5vocab` table of type `instance`. The vectors hold a digest per block of 256 code points, which the Rust tests compare, and the suite compares the two lists live and names the code point. The diacritics tables belong to the SQLite version, so a drift between 3.51.3 and 3.54.1 shows as a code point.
3. The suite (below): each program builds the index and the other reads it, the same queries run against both, the bytes are compared.

A probe test lists `pragma compile_options` in both programs: an option that changes results (`SQLITE_DQS`, the FTS5 switches) is either equal or one line of "Where the two are known to differ".

Concurrency: the two programs may open one index at once. The index is in the default journal mode and this change does not change it, because switching a database that another program holds open is the failure to avoid. Both programs run `pragma busy_timeout = 5000` right after they open the index, so a program that finds the other holding a write waits for it and does not answer `database is locked`. The node opener `openDb` in `db.ts` gains the pragma in this change (it works on every SQLite node ships, where the `timeout` option of `DatabaseSync` does not), and the usage store already waits 250 ms in both. A write happens only when a file changed, in one short transaction, and the redundant write of the `meta` rows that node does on every open is skipped in Rust when the values are equal, so a lock is held for milliseconds. The value is an exported constant of `db.ts` that the vectors carry, so the Rust test fails when the two differ.

Why 5000 ms: it is the lock wait of the daemon's own start (`ensure`), far longer than the transaction of one changed document and short enough that a call does not hang. A wait that ends is an error of that call alone, and the other program's write is never lost.

Rejected: WAL for the index (the journal mode of a file another program holds open is the thing not to change, and WAL adds two files next to an index that a session may move); a retry loop in Rust and none in node (the two programs would wait differently for the same lock).

Rejected: a private index for the Rust program (the machine would hold two indexes and two usage records that disagree, and every switch would rebuild); a shared schema file read at runtime (the schema is eight statements; the vectors carry node's text of it and `sqlite_master` of a file each program built is compared).

### The usage store is shared in the format node writes

Decision: `knowledge-usage.sqlite` keeps its table `usage_events(ts ms, doc_id, heading, kind get|hit, caller)`, the two indexes, WAL with a 250 ms busy timeout, `synchronous = normal`, the retention of 365 days applied in the same transaction that inserts, and recording that is best effort: one transaction per call, opened and closed per call, every error swallowed. The report keeps node's SQL (the dates are UTC through `date(ts / 1000, 'unixepoch')`) and its sort (`gets` desc, `hits` desc, then the id compared by UTF-16 code units, which the Rust comparison reproduces with `encode_utf16` and a vector with ids that differ there). The caller of an event is the name the client gave in the handshake and no environment variable: `TA_LABEL` belongs to the CLI. A read by either program is therefore counted by the report of both.

### The MCP loop is widened, not copied

Decision: `mcp/server.rs` serves the knowledge server too, with three parameters it lacks.

- Identity: `serverInfo.name` is `tagents-knowledge` and the capabilities are `{"tools":{"listChanged":true}}`, as the SDK of the node server answers. `Config` carries an identity instead of the constants. The version is the workspace version, not node's `0.1.0`: the field tells a client which build answered, which is what someone debugging a switch needs, and the suite drops that one field (a known difference).
- The client's name: `initialize` hands the name to the tools through a default method `connected(&self, client: &str)`, and each connection gets its own `Tools` value, so the caller recorded for an event is the connection's.
- Unknown tools and invalid arguments are results, not protocol errors: the SDK answers `isError` with `MCP error -32602: Tool nope not found`, so the knowledge `Tools` returns that result and `None` stays what it is for the plugin's server. `ToolEntry` (`mcp/rpc.rs:216`) has no `title` or `execution`, so the list becomes raw JSON entries.

```rust
pub trait Tools: Send + Sync + 'static {
    fn list(&self) -> Vec<serde_json::Value>;                 // raw entries, copied from node's tools/list
    fn connected(&self, _client: &str) {}                      // the name from `initialize`
    fn call(&self, name: &str, args: &serde_json::Value, stop: &Stop) -> Option<CallResult>;
}
```

A connection's end closes the connection and never the process: the loop already takes its reader, its writer and its exit as values, so the daemon passes a socket and a closing function, and `mcp` and `join` pass stdio.

Rejected: a second loop under `knowledge/` (framing, a thread per call, the ending, the stop on signals would exist twice, and the repository rule is to widen what exists); a trait object per verb with different traits (the plugin's server and the knowledge server differ in three parameters, not in kind).

### Tool listing and argument errors are pinned to the node server

`tools/list` of the node server carries, per tool, `title`, `description`, `inputSchema` (draft-07 `$schema`, `properties`, `required`, `additionalProperties: false` as zod writes them), `execution: {taskSupport: "forbidden"}`, in the order search, get, list, usage, sessions_recent, sessions_search. A generator reads that list from the node server through the in-memory client `packages/contract/src/sources.ts:64` already builds and writes `crates/tagents-core/src/knowledge/tools.json`; `serde_json` with `preserve_order` keeps the key order, so the Rust listing is the file. A stale-file check in CI fails when the node server's listing moves.

Arguments are checked before a tool runs, and the SDK answers a failure as an `isError` result `MCP error -32602: Input validation error: Invalid arguments for tool X: <zod message> at <key>`, issues joined by a newline, and for a call with no arguments object `Invalid input: expected object, received undefined` with no `at`. Samples: `Too small: expected string to have >=1 characters`, `Too big: expected number to be <=50`, `Too small: expected number to be >0`, `Invalid input: expected int, received number`, `Invalid input: expected string, received null`. Unknown keys are accepted. The Rust checker reads the `inputSchema` of `tools.json` (type, `minLength`, `exclusiveMinimum`, `maximum`) and writes zod's lines, so the listing and the checks come from one file; a battery of arguments run through the node SDK (null, wrong types, empty strings, fractions, negatives, too big, a non-object, a missing object) is in the vectors, and the Rust checker must reproduce each message and the order of the issues.

Rejected: `argv_for` of `mcp/tools.rs` (it checks against the contract's option types and words its messages for the plugin's server, which has its own node oracle; two dialects in one checker is the parameter a table avoids); reading zod at run time (node).

### The shared server of the Rust binary: its own key, its own socket

Decision: the Rust daemon uses the scheme of `mcp/socket.ts` and a key of its own, so a Rust daemon and a node daemon of one environment are two servers on two sockets and never meet on one.

- Directory: `tagents-<uid>` under `TMPDIR` trimmed, else the temporary directory node finds (`TMP`, `TEMP`, `/tmp`, one trailing slash removed), normalised as `path.join` does; under `/tmp` when the socket path would exceed 100 bytes. Mode 0700, owned by the caller: a looser mode is tightened, another owner or a non-directory is refused. `node::tmpdir` is added beside `node::join`, `node::resolve` is the one `origin/main` has, and a table of environments run through node pins the path.
- Socket `knowledge-<key>.sock`, pid file `<socket>.pid`, lock directory `<socket>.lock`.
- Key: the first 12 hex digits of the SHA-256 over `NAME=value\0` for `HOME`, `TAGENTS_CONFIG_DIR`, `XDG_CONFIG_HOME`, `TAGENTS_KNOWLEDGE_DIR`, `TAGENTS_KNOWLEDGE_DB`, `TAGENTS_KNOWLEDGE_USAGE_DB` and `CLAUDE_HOMES` (relative values resolved against the caller's directory, unset as empty, as the requirement "What makes a different environment" says), then `code=rust:<path of the running binary>:<its modification time in ms, floored>`. The `rust:` prefix means the key differs from every node key even when everything else is equal, and the binary's time means a replaced binary gets a new daemon, as a rebuilt node entry does.

```rust
fn key(env: &Env, exe: &Path) -> String {
    let mut h = Sha256::new();
    for name in KEY_VARS {
        h.update(format!("{name}={}\0", resolved(name, env)));
    }
    h.update(format!("code=rust:{}:{}", exe.display(), mtime_floor_ms(exe)));
    hex(&h.finalize())[..12].to_string()
}
```

The daemon does no work for two programs: during a switch a node daemon and a Rust daemon can both live, each serving its own sessions from the same files, and the node one leaves when it is idle. Nothing in either program looks for the other.

Rejected: one key for both programs (the first to start would serve the other's sessions with its own semantics, and a node session would meet a Rust daemon whose protocol flavour differs in the known ways below); a socket per program under different names in different directories (the same requirement of 0700 and ownership, twice).

### Starting, racing, stale sockets, idle exit

The lifecycle follows `mcp/daemon.ts`, with each rule restated for Rust:

- `ensure` connects first; an answer ends it. Otherwise it takes the lock `<socket>.lock` by creating the directory (atomic). A lock older than 3000 ms is stale and is removed; a fresh one is waited for, polling every 10 ms for up to 5000 ms and trying to connect on each poll. Under the lock it connects once more, removes a socket file nobody answers on, spawns the daemon, waits up to 8000 ms for an answer polling every 10 ms, and releases the lock. Two starters therefore end with one daemon: the loser waits and connects to the winner's.
- The daemon binds with up to five attempts; on `EADDRINUSE` it connects, and exits 0 at once when something answers (another server holds the socket) and removes the file and binds again when nothing does. It writes `<socket>.pid` once it listens and removes the socket and the pid file when it leaves, on idle, SIGTERM or SIGINT.
- The detached daemon is spawned as `tagents-core knowledge serve --foreground --socket P --idle S` with no stdio, in the directory `/`, in a process group of its own (`process_group(0)` at spawn, the form `child.rs` already uses). A new session would need `setsid` called inside the daemon after it starts, which leaves a window in which a signal to the starter's group reaches the daemon, and `pre_exec` is unsafe, which the workspace forbids; the group alone is enough for what matters (a `^C` or a kill of the group of the session's proxy never reaches the daemon) and costs only that the daemon stays in the session of the starter, with a terminal it never reads or writes. Task 10.6 shows the group, the descriptors and the survival of a kill of the starter's group.
- Idle exit: `--idle S` is a positive number of seconds, default 600, counted from the last disconnect or from the start when nobody connected; the daemon does not leave while a client is connected. The daemon is one accept loop on `poll` over the listener and a wake pipe (the pattern of `watch/`), and a thread per connection. Only the accept thread adds connections, and the thread of a connection only removes its own. The decision to leave follows a drain of the backlog: the loop accepts what is waiting and then reads the count, so a connection that reached the socket before the drain is counted and served, and one that comes after the drain is closed with no reply when the listener closes, which is what the retry of `join` handles. Leaving removes the socket first and closes the listener after it: while the listener is open a probe finds it live, so nobody else can have replaced the file.
- A connection whose client closes only its writing side is released at once: the loop ends at the end of the input, answers what is in flight and closes.
- One bad connection costs only itself: rubbish, a cut-off line, a failure while the connection is set up, and a panic of the thread of a connection (caught at the thread's end) are reported on stderr as `tagents-knowledge: <what>: <detail>`, and the daemon goes on. Node's detail is a stack; the Rust detail is the panic message and its location, and the requirement says "the stack where the program has one".

### `join`: a byte relay with one retry

Decision: `join` copies stdin to the socket and the socket to stdout on two threads, and adds exactly two behaviours to that.

- When stdin ends, it shuts the write half of the socket and goes on copying replies until the daemon closes the connection, then exits 0.
- When the connection ends before the first reply byte, it opens a new connection through `ensure` once and replays what it forwarded so far. This covers the daemon that decided to leave at the moment of the connection, and a socket whose daemon was killed between the `connect` and the answer. The replay buffer holds what stdin gave before the first reply byte, up to 64 KiB, and is dropped at the first reply byte; past the cap there is no retry.
- When it ends after a reply byte without stdin having ended, the shared server died in the middle of a session. `join` exits 1 with `tagents-knowledge: the shared server went away` on stderr, and the client sees its server die and reconnects. A daemon that cannot be started at all is not an error: `join` serves in its own process, as `mcp` does.

```rust
loop {
    match relay(&mut link, &mut forwarded) {
        Ended::StdinClosed => return ExitCode::SUCCESS,
        Ended::SocketClosed { replied: false } if !retried && forwarded.replayable() => {
            link = ensure(env)?; link.send(forwarded.bytes()); retried = true;
        }
        Ended::SocketClosed { .. } => return gone("the shared server went away"),
    }
}
```

Rejected: replaying the handshake to a new daemon after a mid-session death (the proxy would parse the stream, and a request that was half served cannot be told from one that was not: a crash is better seen than hidden); `nc`'s behaviour (a quiet exit 0 on a closed socket, which the client reads as a clean end).

### How a session reaches the binary: the wrapper chooses, the launcher probes

The installer's `write_wrapper` already names the native binary for an exact argument list of `tagents-notify` (`install.sh:76-102`) under the `--version` check of `tagents-mcp` (`install.sh:289-308`). `tagents-knowledge` joins that case with the word `knowledge`. The wrapper runs `tagents-core knowledge <word>` for `serve` with any arguments (`serve`, `serve --idle 30`, `serve --foreground --socket P`) and for `join` or `mcp` as the only argument, and the node program for everything else (`mcp extra`, `search`, `index`). The `tagents-notify` wrapper is generated as before, byte for byte (`tests/install.sh:386-392` pins it).

Why `serve` takes any arguments: a person or a script that starts the shared server with `--idle` must not end with a second daemon beside the one a session's `join` starts, and two argument lists reaching two programs would do that. No reason to keep them on node was found. The options of `serve` are parsed strictly by the binary and pinned by the table of argument lists that node generates (exit code and the option named), the one difference being the wording of `util.parseArgs`, which is a known difference already. `--socket P` and `--foreground` by hand run the Rust daemon, which is the point; a node daemon that is running is not touched. `mcp` and `join` stay exact: `mcp extra` is a spelling the plugin never uses and `join x` is the same usage error in both programs.

The wrapper also owns the answer to the launcher's probe. Whatever the binary's state, a call whose only argument is `join` that does not reach the binary exits 69 and starts nothing, so a machine without the binary does not pay a node start for a question whose answer is no. 69 is `EX_UNAVAILABLE` of `sysexits.h` ("a service is unavailable"), and differs from 0, from the node CLI's 1, 2 and 4 (`packages/knowledge/src/cli/exit.ts:2`) and from the shell's 126 and 127.

```sh
r="/home/u/.tagents/target/release/tagents-core"
if [ -f "$r" ] && [ -x "$r" ]; then
  if [ "${1-}" = serve ] || { [ "$#" -eq 1 ] && { [ "$1" = join ] || [ "$1" = mcp ]; }; }; then
    TAGENTS_NODE="$n"; export TAGENTS_NODE; exec "$r" knowledge "$@"
  fi
fi
[ "$#" -ne 1 ] || [ "$1" != join ] || exit 69
exec "$n" "/home/u/.tagents/packages/knowledge/dist/cli/main.js" "$@"
```

With no binary named (none at install time, another version, `TAGENTS_NO_NATIVE=1`, no release) the first block is absent and the last two lines remain. A binary that is gone by run time falls to the same two lines: `serve` and `mcp` run node, `join` exits 69.

Why only these words: the wrapper is where a wrong guess costs, the plugin and the launcher call these three, and every other call stays on the oracle until its own change. A binary of another version is not named, because an older binary hands `knowledge` to the node core CLI, which does not know it.

`packages/knowledge/bin/knowledge-mcp` probes before it commits, because `exec` cannot fall back, and says so when the native server was there and failed:

```sh
tagents-knowledge join </dev/null >/dev/null 2>&1; rc=$?
case $rc in
  0) exec tagents-knowledge join ;;
  69 | 2) ;;  # 69: the wrapper has no binary. 2: a wrapper from before this arrangement, whose node program does not know `join`
  *) printf 'knowledge-mcp: tagents-knowledge join exited %s, using the node server (tagents-knowledge join </dev/null shows why)\n' "$rc" >&2 ;;
esac
sock=$(tagents-knowledge serve 2>/dev/null) && [ -S "$sock" ] && command -v nc >/dev/null 2>&1 && exec nc -U "$sock"
exec tagents-knowledge mcp
```

With the native `join`, stdin at EOF connects, finds or starts the daemon, shuts the write half and exits 0, so the probe answers by exit code and leaves a daemon running that the real `join` finds. A node-only machine gets 69 from the wrapper at once and runs the old arrangement unchanged, silently; a wrapper from before this arrangement has node answer 2, also silently, at the price of one node start until the next `tagents update` rewrites it. Any other code means the native `join` was there and failed (a socket directory that cannot be made, a crash, a signal): the line goes to the session's stderr, which Claude Code keeps in the log of an MCP server, and the node arrangement runs. `plugin.json` is unchanged. The arrangement is safe against skew in both directions: a new launcher over a node-only machine falls through; an old launcher over a machine with the binary calls `tagents-knowledge serve`, which the wrapper sends to the Rust `serve`, and joins that daemon through `nc`.

Rejected: a launcher that names the binary's path (it would skip the version check the wrapper owns); `tagents-knowledge join || fallback` without `exec` (the shell would stay as a parent, and an exit 1 after a death mid-session would start a second server for a client that has already begun a session); an option of `join` that only checks (an interface that exists to be probed, when running the verb on empty input already says whether it exists); a probe that reads the wrapper's text or looks for the binary's path (the wrapper's rules for the version and the executable bit would exist twice).

### Which CLI verbs move

Only `mcp`, `serve` and `join`. The server is what costs a start and 29 MB per session; the read verbs run once per command a person types, and a node start there is a tenth of a second. Moving them needs the argument parsing of each, the English and Russian tables, and for `lint` and `toc` the whole link and index rules, each with a parity surface of its own. What this change builds (the index, the search, the usage store, the document reader, the dates) is what `index`, `search`, `show`, `list` and `usage` run on, so those later changes are the CLI and its texts. `lint` and `toc` need the document rules only and wait for the same reason.

### The front matter: `saphyr` and a converter

Decision: `saphyr` (YAML 1.2) parses the front matter, and a converter turns its tree into the values the `yaml` package gives `doc.ts`, which then applies its own rules unchanged: `type` or the legacy `kind` as a non-empty string; tolerant for the other fields; `tags` keep strings only; `status` exact in `draft|stable|deprecated`; `stale_after` and `generated.at` offset datetimes; `null` or an empty document is `{}` and a non-mapping is refused.

A differential of 41 front matters through `saphyr` and `yaml` on 01.11.2026 found these real differences, and the converter closes the first two and the last: an explicit core tag (`!!int '7'`) is applied; a custom tag (`!custom`) is dropped and its value used untagged; an integer above 2^53 is cast through `f64` and printed by `js::number_text`, as node prints a double. Complex mapping keys are the one the converter cannot close: node renders such a key as text, and the Rust key is the raw form, which is a known difference. The six malformed documents agree on refusal and differ only in the wording of the error, which the server never prints (the error text appears in `lint`, `toc` and `index`, which stay in node); in the server a document that stops parsing is dropped from the index.

Rejected: `serde_yaml` (archived), `yaml-rust2` (YAML 1.1 booleans, so `yes` and `no` become booleans where node keeps strings), a parser written for the three shapes of front matter (the rules `doc.ts` accepts are YAML's: anchors, flow forms, block scalars).

### Texts: one source, generated

The few texts the Rust program prints (`badIdle`, `serveFailed` in English and Russian, selected by the locale as `Locale::of` selects it for the notify service) come from the node catalogue `packages/knowledge/src/i18n/{en,ru}.ts` through a generator that writes `crates/tagents-core/src/knowledge/texts.json`, which the binary embeds, with a stale check in CI. The summaries of the three verbs live in `packages/core/src/i18n/{en,ru}.ts`, because the contract generator reads them there; the binary never prints them. The tool answers are English literals in both programs and are not translated. `serve` is the only verb that prints a sentence of its own, and a session never sees one. The lines a daemon or `join` writes to stderr about a fault are English, as node's are.

Rejected: the texts copied by hand into Rust (the catalogue would exist twice, and the Russian line drifts at the first edit).

### What is ported and how each copy is pinned

| piece | node | Rust | pinned by |
|---|---|---|---|
| splitting and parsing of a document, sections, legacy mapping | `doc.ts` | `knowledge/doc.rs`, `front_matter.rs` | vectors: parsed documents of the corpus and of generated edge cases |
| dates (offset datetime, real date, UTC date, stale) | `doc.ts:55-93` | `knowledge/doc.rs` | vectors with a clock |
| index schema and reindex rules | `db.ts` | `knowledge/index.rs` | vectors (DDL text, schema version) and the cross-engine suite |
| query expression, search, list, get | `search.ts` | `knowledge/search.rs` | vectors and the suite |
| usage store and report | `usage.ts` | `knowledge/usage.rs` | vectors and the suite |
| argument checks | zod 4 in the SDK | `knowledge/args.rs` | vectors from a battery run through the SDK |
| tool listing | `mcp/server.ts` | `knowledge/tools.json` | generator and stale check |
| texts | `i18n/*.ts` | `knowledge/texts.json` | generator and stale check |
| socket path, scheme, limits | `mcp/socket.ts` | `knowledge/socket.rs` | vectors over a table of environments; the key itself differs on purpose |
| the number a flag is read as | JS `Number` | `js::number` | exists (`crates/tagents-core/src/js.rs:119`) |
| lower-casing of types and headings | JS `toLowerCase` | `js::lower` | exists, plus vectors with the characters that differ |

The vectors are regenerated in `rust.yml` and followed by `git diff --exit-code`, so a change on the node side that the Rust side has not followed shows as a diff.

Reuse, found by search before writing: `js::{trim, collapse_space, split_space, lower, number, number_text, round}`, `node::{homedir, basename, join, mtime_ms, errno, io_message}`, `date::iso`, `config_dir` and `config_dir_from` of `host.rs`, `not_blank` of `host.rs` (private there, so (b) makes it `pub(crate)`), `Locale::of` of `messages.rs` (the notify service uses them on `origin/main`, and the knowledge code uses them from there, with no `config.rs` or `locale.rs`), `node::resolve` as `origin/main` has it, `child.rs` for process groups, `ending.rs` for signals, `watch/`'s wake-pipe pattern, `sessions.rs` (`recent`, `search`, `show`) and `transcripts.rs` for the two session tools. New and not duplicated anywhere: `node::tmpdir`, a floor variant of `node::mtime_ms`, and the SHA-256 (the tree has no hash).

### The node server is the oracle: a differential suite

`tests/rust-knowledge-parity.sh` with `tests/rust-knowledge-parity-driver.mts` runs each scenario against `tagents-knowledge` of node and the Rust binary on copies of one corpus in scratch directories (scratch `HOME`, `TMPDIR`, config, index and usage paths) and compares the bytes.

- Handshake and listing: `initialize` with several protocol versions, `tools/list`, `ping`, an unknown method, an unknown tool, a malformed line.
- Every tool over the five-document fixture `packages/knowledge/test/fixtures/knowledge` and the `okf` corpus: search (queries with diacritics and Cyrillic, prefix `*`, a refused expression, a tag, a type in another case, the legacy `kind`, a limit, ties, deprecated last), get (a document, a section, a missing document, a missing section with its list), list, usage (every argument), the two session tools over a fixture of transcripts.
- Argument errors: the battery of the vectors, through each program's real stdio.
- Cross-engine index: node builds and Rust reads, and the reverse, after an edit, a touch with the same text, a delete, a document that stops parsing and one restored.
- Cross-engine usage: a read through each program is counted by the report of the other, with the caller names of two clients.
- The daemon scenarios of `packages/knowledge/test/shared-server.test.ts` and `socket.test.ts`, run against both: two sessions and one daemon, two folders, two usage stores, a relative usage store, a different `TMPDIR`, a variable the server does not read, four proxies meeting a dead socket, a daemon killed and restarted, a held-open client against idle exit, nobody connecting, garbage and then a real client (`daemon-faulty.ts`), a clean exit that removes socket and pid file, mode 0700.
- `join`: stdin end releases the daemon at once, a daemon that leaves at the moment of the connection (the retry), a daemon killed mid-session (exit 1 and the stderr line), no daemon possible (served in process).

Tripwires assert on the node transcript alone, so a scenario that stops provoking what it exists for fails; the suite prints how many scenarios it skipped; a first check fails when the process it starts as the Rust side is the node CLI that the front door forwards to while the arm is missing. Mutations of the Rust side each fail the scenario named for them and leave the suite green when restored: the expression with the weights swapped, the order without the id tie-break, the modification time rounded, the hash over a different text, the `meta` rows written when equal, the usage retention left out, a validation message reworded, the idle decision taken from a copy of the count made before the backlog is drained, a daemon that does not remove its pid file.

### Where the two are known to differ

Each is a row of "Where the two are known to differ" in `docs/architecture/rust-core.md`:

- `serverInfo.version` is the workspace version in Rust and `0.1.0` in node; the suite drops that field.
- A YAML complex mapping key is rendered as raw text in Rust and as node's text in node.
- A front matter that the Rust parser refuses but `yaml` takes, or the reverse, is a vector, never a silent difference: each known case is listed there.
- The wording of the usage errors of `serve` for an unknown option comes from `util.parseArgs` of the node in use; the exit code and the option named are the same.
- The SQLite version (3.54.1 in Rust, the node's own in node) shows nowhere unless the tokenizer sweep or `compile_options` differ; any that does is listed with its code point or option.
- The detached daemon is in a group of its own and in the starter's session in Rust, in a session of its own in node.
- A daemon that dies mid-session ends `join` with exit 1 and a line, and `nc` with a quiet exit 0.
- The detail of a fault the daemon survives is a panic message in Rust and a stack in node.
- Memory and start time: the point of the change, measured, never compared for equality.

### Dependencies

Decision: the dependency table of `docs/architecture/rust-core.md` and the comments of the workspace `Cargo.toml` gain these rows, each with its reason and its measured cost, filled in by the change that adds them.

| dependency | used by | reason | cost |
|---|---|---|---|
| `rusqlite` (feature `bundled`) | `knowledge::index`, `usage` | the index and the usage store are SQLite files that node reads and writes | `libsqlite3-sys` and the C source of SQLite; about 1.76 MB in a release binary and 15.8 to 22.3 s of a clean build on the probe; `musl-tools` on the musl runner; clean build on aarch64-apple-darwin: the C compile 14.2 s and `rusqlite` 0.7 s of 33.3 s for the binary (task 16.2, `docs/architecture/rust-core.md`) |
| `saphyr` | `knowledge::front_matter` | the front matter is YAML 1.2, as in the `yaml` package | 7 crates and `autocfg` at build time; 0.9 s of the same clean build (task 16.2) |
| `sha2` | `knowledge::index`, `knowledge::socket` | the hash of a document and the key of a socket; the tree has no hash | 9 crates; 0.8 s of the same clean build (task 16.2) |
| `rustix` feature `process` (already enabled) | `knowledge::socket` | the uid, in safe code | none |

All are MIT or Apache-2.0 and the release workflow builds all three targets, so a failure on one shows in the dry run of the pull request that adds them.

### Version and release

Decision: three pull requests, each mergeable alone with the node arrangement intact.

- (a) Task groups 1 to 6: the document reader, the index, the search, the usage store, the vectors, the three dependencies, the `musl-tools` step and the busy timeout of the node opener of the index (its own commit). No verb calls the Rust code, so the node arrangement is untouched; the one change to node is that its index waits for a lock. It changes inputs of the binary and raises the workspace version above its merge base.
- (b) Groups 7 to 13: the generators, the widened loop, the argument checker, the tools, the socket and the daemon, `join`, the three verbs (the front-door arm and the contract entries are the last of the code, after everything they call, so no verb is forwarded to node while half built), the suite, CI and the documents. Nothing names the verbs yet, so the node arrangement is untouched. It raises the version one minor step above its merge base.
- (c) Groups 14 to 17: the installer's words and the `join` answer of the wrapper, the launcher, the measurements, the `CHANGELOG.md` line and the archive. It changes no input of the binary, raises nothing, and names the verbs only for a binary of the checkout's version, so a machine with a binary of another version, no release or `TAGENTS_NO_NATIVE=1` keeps the node arrangement.

Each pull request that changes an input runs `sh .github/scripts/core-release.sh gate origin/main` and follows what it prints: `Cargo.toml`, `Cargo.lock` and the version lines of `docs/architecture/rust-core.md`. When (a) merges first, (b) rebases and takes a version above the new base. Tagging the version is not part of this change; the installer falls back to node for a version without a release.

Reason: the release path is built so that an install never runs a binary of another version, and this change does not weaken it to get there sooner.

## Risks / Trade-offs

- SQLite version difference (3.54.1 against node's 3.51.3): a change of the diacritics tables or of float evaluation could reorder equal ranks or fold a letter differently. Mitigation: the tokenizer sweep, the tie vectors and the suite; a node upgrade that moves a result shows as a diff of the vectors. Residual: a result the corpus does not hold.
- The C compiler of the musl build: `musl-tools` is a new step of `release.yml`; x86_64 musl and the cross-built x86_64 macOS binary are built by the dry run of `release.yml` on a pull request, and a failure there stops the pull request, not a release; both pass (the open question below).
- Binary size (about 1.76 MB on the probe) and a clean build that takes a third to half a minute longer.
- `saphyr` against `yaml`: the known differences above are closed or listed, and anything the 41 cases did not find is found by the vectors' generated edge cases or not at all.
- zod 4 and `util.parseArgs` words depend on the SDK and node versions: the vectors are regenerated in CI, so an upgrade of either shows as a diff.
- A native `join` that fails makes the session run the node arrangement: the session works and the cost is the node start. The launcher writes one line naming the exit code to the session's stderr, which Claude Code keeps in the log of an MCP server, and `tagents-knowledge join </dev/null; echo $?` shows the reason.
- A machine without the binary pays a shell start for the probe, because the wrapper exits 69 without starting node. A wrapper written before this arrangement answers 2 through a node start until the next `tagents update` rewrites it.
- The two silent codes of the probe (69 and 2) could hide a native `join` that exits with one of them. The native `join` exits 2 only for an argument, which the probe never gives, and 69 is never used by the binary.
- `process_group(0)` leaves the daemon in the starter's session (see the lifecycle decision).
- Locking across programs: both wait 5000 ms for a lock, so a call fails with `database is locked` only when the other holder outlasts that, in either program (see "One index file").
- `serverInfo.version`, the capabilities flag and the SDK's own details are matched in the handshake and listed where they differ.

## Migration Plan

1. (a) merges: the binary carries the index, the search and the usage store, and no verb calls them.
2. (b) merges: the binary carries the three verbs, and nothing names them. `tagents-core knowledge join` can be tried by hand, and the node arrangement is what every session runs.
3. (c) merges and a version with a release is tagged by the person who tags: `tagents update` installs the binary and the wrapper's words; a session then starts `join`, a node daemon that is running is left alone and exits when idle, and the index and the usage store carry over untouched.
4. Back: `TAGENTS_NO_NATIVE=1` and a re-run of the installer remove the prebuilt binary and the wrapper falls through to node; a session started next uses the node arrangement; a running Rust daemon exits when idle. Deleting `knowledge.sqlite` is never needed in either direction.
5. A later change moves the read verbs and then retires `packages/knowledge`; neither is part of this one.

## Open Questions

- Does the x86_64 musl build of the bundled SQLite pass in the release workflow, and what does a clean build cost there? It passes. The `build (x86_64-unknown-linux-musl, ubuntu-latest, true)` job of the dry run on pull request #60 (run 41550044671, job 125635093480) took 1 m 58 s in all, and the `Build` step of run 41552652481 of `release.yml` for v0.6.5 took 70 s with a 4,365,880-byte binary. The cross-built x86_64 macOS binary passes the same way (job 125635093908 of the dry run, 1 m 56 s; `Build` step 64 s, 3,640,320 bytes). The choice of engine form stands.
- Do `compile_options` of the bundled SQLite and node's differ in an option that changes a result? Answered by the probe test of task 4.4; a difference becomes a row of the known differences or a reason to set the option in the build.
- What does a Rust server and a Rust daemon hold, by `footprint`, after the same search over the same five documents (node: 29 MB, probe: 80 KB)? A `join` holds 1024 KB and the Rust daemon 2128 KB; the node side holds 45 MB for the daemon, 44 to 45 MB for a `tagents-knowledge mcp` and 1296 KB for the `nc` of a session, on a scratch install over the five documents of `packages/knowledge/test/fixtures/knowledge` (task 16.1, measured on an Apple silicon laptop, `footprint <pid>` after one `knowledge_search`). The numbers and the commands are in the description of the pull request.
