## Context

Each Claude Code session starts the plugin's `tagents` MCP server as its own node process, `tagents-mcp --contract contract.json`. That is `packages/mcp` (about 550 lines of source on `@modelcontextprotocol/sdk` and `zod`): it reads the `cli` section of `contract.json`, offers one tool per verb that is a tool, and answers a call by running the verb's program as a child and telling, in one JSON document, how it ended. Measured with `footprint` on 30.10.2026 a session's server is about 38 MB, so eight sessions keep about 300 MB busy for processes that wait on stdin.

`rust-core` put a Rust `tagents-core` next to the node CLI, `rust-release` made it reach users as a checksummed prebuilt binary, and the installer's wrapper already prefers it when it is installed. The server needs very little of a runtime: newline-delimited JSON-RPC in, three kinds of request, a child process with a bounded output and a process group, one line out. This change makes it a verb of the binary that already ships, keeps the node server as the fallback and as the oracle the new one is tested against, and leaves behind a stdio layer that the knowledge server can reuse.

## Goals / Non-Goals

**Goals:**

- On a machine with the prebuilt binary, a session's server is `tagents-core mcp`, and the client cannot tell it from the node server: the same tools in the same order, the same hints and input schemas, the same argument rules, the same result bodies, the same output cap, timeout and shutdown.
- On a machine without the binary nothing changes.
- Nothing a call starts outlives the call, and nothing but protocol JSON reaches stdout.
- The two servers cannot drift unnoticed: one suite feeds both the same requests and compares what they answer.
- The protocol layer does not know a verb, so a second server (knowledge) can sit on it.

**Non-Goals:**

- Retiring `packages/mcp`, adding or changing a tool, or changing the contract's shape.
- Cutting a release. The tag for the version this ships in needs Sasha's word; until it exists the installer falls back to node for that version, as it does for every version without a release.
- The knowledge and notify servers, an async runtime, a general MCP SDK, a Windows build.
- Streaming, progress, resources, prompts, logging or pagination: the node server offers none of them.
- Stopping a call's process group when the server itself is killed with SIGKILL: the node server cannot either.

## Decisions

### One binary, one more verb: `tagents-core mcp`

Decision: the server is the verb `mcp` of `tagents-core`, in `spec/cli/tagents-core.json` with `impl: rust` and `effect: serve`. A `serve` verb is not a tool (`isTool`), so the server never offers itself, and the generated contract and references gain exactly one entry. `--spec` lists the verb because the binary implements it. The front door gives `mcp` an arm of its own: every other group returns an `Output` that the front door prints, and this is the one verb that owns stdin and stdout for as long as it lives.

Reason: the binary is already built, checksummed, released and installed. A second binary would change the archive's members, `release.yml`, the installer's member check and `tests/release.sh` to ship one more executable of the same kind.

Rejected: a second binary `tagents-mcp` (all of the above); a library crate in the workspace with a thin binary (a crate boundary with a single user).

```rust
// front_door.rs: run()
match args.first().and_then(|first| first.to_str()) {
    Some("mcp") => mcp::run(&args[1..]),      // blocks until the client leaves; returns its exit code
    _ => /* the existing group lookup, else forward() to the node CLI */,
}
```

### The seam is the installer's wrapper, and `plugin.json` does not change

Decision: `plugin.json` keeps `tagents-mcp --contract ${CLAUDE_PLUGIN_ROOT}/contract.json`. The installer's `tagents-mcp` wrapper names the native binary and the fixed word that goes before the arguments, so with the binary installed it runs `tagents-core mcp --contract …`, and with none it is today's wrapper byte for byte. `write_wrapper` takes the word as an optional fifth parameter.

Reason: the wrapper is where `tagents-core` already chooses between the binary and node, so the choice is made in one place, by the same test (an executable file at `$TAGENTS_HOME/target/release/tagents-core`), and a machine without the binary needs no new rule.

Rejected: `plugin.json` calling `tagents-core mcp` directly (a machine without the binary would have no server at all); a verb in the node CLI that hands over to the binary (the node process the change exists to remove would stay, and a missing binary would recurse); asking the binary for `--version` or `--spec` in the wrapper before using it (a process per start to guard against a binary the installer only ever installs at the version of its checkout).

The installer asks a hand-built `target/release/tagents-core` for `--version` once per install (`install.sh:295`) and names it for `tagents-mcp` only when it answers `tagents-core <version of the checkout>`; a stale binary that predates `mcp`, or one that cannot answer, is not named, so `tagents-mcp` runs the node server while `tagents-core` still names the binary, whose missing verbs go to the node CLI. A checkout with no `Cargo.toml` keeps naming it, and a `Cargo.toml` whose version cannot be read names none. Deleting `target/` (or running the installer, which owns the prebuilt one) returns to node.

```sh
# the tagents-mcp wrapper today
r="$TAGENTS_HOME/target/release/tagents-core"; [ ! -f "$r" ] || [ ! -x "$r" ] || { exec "$r" "$@"; }
# and with the word
r="$TAGENTS_HOME/target/release/tagents-core"; [ ! -f "$r" ] || [ ! -x "$r" ] || { exec "$r" mcp "$@"; }
```

### The protocol is written by hand on `serde_json`, with threads and no async runtime

Decision: `crates/tagents-core/src/mcp/` holds the server in layers that know nothing of each other's insides. `rpc` is the framing: one JSON value per line in, one line out through a single locked writer that writes each message with one `write_all`. `server` is the loop and the registry of calls in flight, generic over a `Tools` trait (`list`, `call`); the loop knows `initialize`, `ping`, `tools/list`, `tools/call` and `notifications/cancelled`, and nothing of verbs. `contract` and `tools` derive the tools from `contract.json`, and `run` runs one call. The main thread reads stdin; `initialize`, `ping` and `tools/list` are answered inline; every `tools/call` runs on a thread of its own, so a slow call never holds a fast one.

The dialogue is the node server's, which is the SDK's:

- `initialize` answers the requested `protocolVersion` when it is one the SDK supports (`2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`, `2024-10-07`) and the latest otherwise, with `capabilities: {"tools": {}}` and `serverInfo: {"name": "tagents", "version": <the workspace version>}`. The node server's version is a constant `0.1.0` that no release moves, so this is the one field the suite does not compare.
- `ping` answers `{}`. `tools/list` answers every tool, sorted by name, without a cursor. Requests are not refused before `initialize`, as in the SDK.
- An unknown method answers `-32601` `Method not found`; an unknown tool answers `-32602` with the SDK's text, `MCP error -32602: unknown tool <name>`.
- A line that is not a JSON-RPC message is ignored, and so is a notification this server does not know. Nothing is written to stderr after a successful start.
- The keys of a message come in the SDK's order, because the suite compares lines byte for byte and a diff of two lines is only readable when the order is the same: a success is `{"result":…,"jsonrpc":"2.0","id":…}`, an error is `{"jsonrpc":"2.0","id":…,"error":{"code":…,"message":…}}`, a tool result is `{"content":[…],"isError":…}`, and a tool is `{"name","description","inputSchema","annotations"}`. Typed structs with their fields in that order do it; nothing depends on the order but the suite.

Where the SDK answers a request whose params fail its validators (`initialize` without params, a `tools/call` without a name, `arguments` that is not an object) it answers `-32603` and the validator's JSON text as the message; this server answers `-32602` `Invalid params` with a short reason, as the protocol says. That is the one deliberate difference in the dialogue, and the suite does not send such requests.

Reason: the protocol surface is five methods and a framing rule; a library for it would carry an async runtime and its dependency tree into a process whose point is to be small. The `Tools` trait is also what lets the loop be tested with a fake that spawns nothing, and what the knowledge server will implement.

Rejected: `rmcp` or another SDK crate (a runtime and a tree of crates for five methods); `Mutex<Stdout>` with a `println!` per message (not atomic across threads, and a stray `println!` anywhere would corrupt the framing).

```rust
/// What the loop needs of a server's tools; the verbs behind them are none of its business.
pub trait Tools: Sync {
    fn list(&self) -> Vec<ToolEntry>;                       // name, description, inputSchema, annotations
    /// `None`: no tool of that name. `stop` says when the client cancels the request or the server closes.
    fn call(&self, name: &str, args: &Map<String, Value>, stop: &Stop) -> Option<CallResult>;
}

// mcp/mod.rs: nothing in this module may print to stdout; the writer is the only way out.
#![deny(clippy::print_stdout, clippy::dbg_macro)]
```

### The tools are derived from the contract by the node server's rules

Decision: `contract.rs` reads the `cli` section of `contract.json` the way `packages/mcp/src/contract-file.ts` does and `tools.rs` derives the tools the way `tools.ts` does. The rules to carry over, each pinned by a test ported from `packages/mcp/test/tools.test.ts` and `contract-file.test.ts`:

- A program is a key of `cli` in the file's order; its `exit` table and its `commands` keep the order of the file (a map that sorts its keys would reorder `properties` and change which outcome name wins for an exit code two names share). Unknown keys are ignored; an unknown `effect` is dropped, which leaves the verb unclassified.
- A verb is a tool unless `effect` is `serve` or `tool` is `false`. The name is the program without a `tagents-` prefix, then the path words, every run of characters other than letters and digits becoming `_` (`tagents-core session list` is `core_session_list`; the script `tagents` keeps its name). Two verbs with one name, a `toolDefaults` entry that names no option or a non-boolean option, a positional that is neither `<x>` nor `[x]`, and an option that shares its name with a positional stop the server at start with `tagents-core mcp: <reason>` and exit 1.
- The description is the summary with a capital letter and a full stop. The input schema lists the positionals first, then the options, in order; `required` lists required positionals, then `required`; `additionalProperties` is `false`. Annotations follow the effect (`read`, `write`, `spawn`, `destructive`; none: `{"readOnlyHint": false}`).
- A call is checked before anything starts, in this order: unknown argument, missing required argument, a NUL in any string, then each option and positional with the node server's messages. Options become `--name=value`, a boolean is `--name` only when true, `toolDefaults` fills a boolean the call left out, a positional that starts with `-` is refused, and a positional after a skipped one is refused. The program is the contract's, looked up on `PATH`; the model chooses neither a program nor an environment.

The contract reader is lenient on purpose (a plugin updated ahead of this binary may hold keys and effects it has not heard of), where `tagents-spec` reads `spec/cli/tagents-core.json` strictly (an unknown key there is a bug). Two readers of one vocabulary is the parallel copy the rules allow only when pinned, so `Effect` and `OptionKind` are reused from `tagents-spec`, and a test reads the bundled `contract.json`, takes its `tagents-core` program and compares it with `Spec::bundled()` (path, positionals, options with their kinds, required, effect, tool, requires, defaults), so a field that one reader learns and the other does not fails a test.

Reason: the tool list is the interface the model sees. A tool that moves, loses a hint or takes an argument differently changes what the model does with it, with nothing failing.

Rejected: reading the specs instead of the contract (the contract is the one list of tools the generator recorded, the node server reads it, and the references name it); making `tagents-spec` lenient (its strictness is how a typo in the data file is caught).

```rust
/// One program of the contract's `cli` section, in the file's order. Lenient: unknown keys are skipped.
#[derive(Deserialize)]
struct Command {
    path: Vec<String>, positionals: Vec<String>,
    options: IndexMap<String, OptionShape>, required: Vec<String>, summary: String,
    #[serde(default, deserialize_with = "known_effect")] effect: Option<Effect>,   // unknown name: None
    #[serde(default)] requires: Option<Requires>, #[serde(default)] tool: Option<bool>,
    #[serde(default, rename = "toolDefaults")] tool_defaults: IndexMap<String, bool>,
}
```

### A call: spawn, cap, wait, stop, drain

Decision: a call runs the program as a child with no stdin, the server's own environment, its stdout and stderr on pipes, and a process group of its own (`Command::process_group(0)`, which is safe; `Command::setsid` is unstable in rustc 1.99.1 (rust-lang/rust#105376, error E0658) and `pre_exec` needs `unsafe`, which the crate forbids, so the child leads a group and not a session and stays that way). The consequence: when the server has a controlling terminal, the call keeps it, and a program that opens `/dev/tty` and reads is stopped by SIGTTIN (a write by SIGTTOU when the terminal has `tostop`), where node's child, a session leader without a terminal, fails at once with ENXIO; the call still ends, because cancellation and the 5-minute limit send SIGTERM to the group and SIGKILL after the 2 s grace, and no verb of the contract opens the terminal (`plugin add` records configuration and spawns no git). The call thread owns one event channel and a deadline; a waiter thread blocks on the child and sends `Exited`, two reader threads send `Eof` when their pipe ends, the registry sends `Stop`. The thread loops on `recv_timeout` until the next deadline, so nothing polls and nothing sleeps until the program has exited; after the drain the call polls every 10 ms for as long as a pipe is readable:

- Running, deadline `timeout` (5 minutes) from the spawn. On the deadline: SIGTERM the group, remember the reason `timeout`, new deadline `kill_grace` (2 s). On `Stop`: the same with the reason `cancelled`.
- Stopping, on the deadline: SIGKILL the group and wait for the exit.
- On `Exited`, in any state: SIGKILL the group at once (what the program left running dies with it), then wait for both `Eof` events for at most `drain` (250 ms), because a process that left the group can hold a pipe open for good. When the drain is over, each pipe whose reader has not sent its `Eof` (`Eof` names its stream) is asked through a duplicate of its read end whether it is readable (`poll` with a zero timeout, `POLLIN` or `POLLHUP`). A pipe that holds bytes or has lost its last writer has a reader the machine has not run yet, not a holder, so the call waits on in steps of 10 ms, up to `drain` plus `kill_grace` after the exit; a pipe that is empty and open is a holder's, and the call gives up at the drain, as it does for a call that was stopped (its answer is `cancelled`, or its output is partial already, and the server's ending waits only `kill_grace` plus a margin for the calls). A reader still blocked then is left to end when the holder lets go; it only fills a capture nobody reads, and the duplicates are dropped with the call so the holder gets EPIPE.
- The result is built from what the captures hold when the call settles. The reason wins over the exit status: a program that exits 0 on SIGTERM after a timeout is `timeout`.

Each stream keeps its first 256 KiB and the reader goes on reading and discarding, so the program never blocks on a full pipe. A cut stream ends before the UTF-8 character the cap fell in and carries `\n[output cut at 262144 bytes]`; a cut stdout stays text and `truncated: true` is added when either stream was cut. A child that cannot start answers `<program> is not on PATH` when the program is not found, and the operating system's reason otherwise. Where `rustix` offers `waitid` with `NOWAIT` on all three release targets, the waiter blocks on that and the group is signalled before the leader is reaped, so the group id cannot have been reused by another process; every target (Linux, macOS) has `waitid`, and there is no fallback.

Reason: this is the node server's `run.ts`, step for step, in the primitives Rust has. The group is what makes "nothing outlives a call" true for the helpers a program starts and leaves in its group (a helper that called `setsid` is out of reach of the group, here and in node alike), and the bounded drain is what keeps a call from hanging on a helper that escaped. The wait past the drain for a readable pipe exists because the two servers read differently: node's one thread reads whatever the pipes hold in the event loop's poll phase, long before its drain timer fires, while a reader thread of ours can be descheduled for longer than 250 ms on a loaded machine, and the bytes the program wrote before it exited were then discarded (a call returned an empty or cut stdout). The one behaviour this adds is that a holder outside the group that keeps writing holds a call for up to `drain` plus `kill_grace` (2.25 s), where node gives up at the drain.

Rejected: a poll loop over the pipes in place of the reader threads (more code for the same effect, and the reader threads are cheap; the poll is used once the drain is over, to tell a reader that has not run from a holder); a longer drain (it would hold every call whose helper writes nothing for longer, and drift from the pinned `DRAIN`); killing only the child (helpers would outlive the call); an async runtime for timers (a runtime for three deadlines).

```rust
pub struct RunDeps { pub env: Vec<(OsString, OsString)>, pub timeout: Duration, pub kill_grace: Duration, pub drain: Duration }

loop {
    match events.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
        Ok(Event::Eof(s)) => { open.retain(|(e, _)| *e != s); if open.is_empty() && exited.is_some() { break; } }
        Ok(Event::Exited(code)) => { kill_group(pgid, Signal::KILL); exited = Some(code); exited_at = Instant::now(); if open.is_empty() { break; } deadline = exited_at + deps.drain; }
        Ok(Event::Stop) if reason.is_none() && exited.is_none() => { reason = Some(Reason::Cancelled); kill_group(pgid, Signal::TERM); deadline = Instant::now() + deps.kill_grace; }
        Err(RecvTimeoutError::Timeout) if exited.is_some() => {
            // the drain, or a step after it, is over
            if reason.is_some() || now >= exited_at + deps.drain + deps.kill_grace || !readable(&open) { break; }
            deadline = now + DRAIN_STEP;
        }
        Err(RecvTimeoutError::Timeout) if reason.is_none() && exited.is_none() => { reason = Some(Reason::Timeout); kill_group(pgid, Signal::TERM); deadline = Instant::now() + deps.kill_grace; }
        Err(RecvTimeoutError::Timeout) => { kill_group(pgid, Signal::KILL); deadline = Instant::now() + LONG; }
        Err(RecvTimeoutError::Disconnected) => break,
    }
}
```

### Cancellation and shutdown

Decision: `notifications/cancelled` with the id of a request in flight stops that call (SIGTERM, then SIGKILL after the grace), and the request gets no response, even if the call had finished by then: that is what the SDK does with a request whose signal was aborted. The server ends when stdin ends or on SIGTERM, SIGINT or SIGHUP (`signal-hook`'s iterator on a thread of its own, so no handler runs arbitrary code). Ending stops every call in flight, lets each answer with the outcome `cancelled`, waits on the registry until it is empty or until `kill_grace` plus a margin of 2 s has passed, and exits 0. A write error on stdout means the client is gone and starts the same ending. Ending twice is one ending. A second signal during the ending is caught and ignored, so the ending always reaches the SIGKILL of the grace; rejected: ending the process at once by the second signal's default action, as node's `process.once` lets it, because the signal can arrive before the ending has sent SIGTERM to any group (each call's own thread sends it, in the `Event::Stop` arm of `supervise`, `run.rs:500-506`), and the calls' programs would then outlive the server with no limit.

Reason: the same as the node server's `endWith`: the client that asked for the work is gone and nobody else would stop it. Answering the calls that were stopped by the ending keeps a client that writes its requests and closes stdin (a script, the suite) getting its answers. The node server does that only when its write wins the race with `process.exit`, so the Rust server is stricter than its oracle here and the suite pins the Rust side alone.

```rust
fn end(calls: &Calls, ending: &AtomicBool) {
    if ending.swap(true, Ordering::SeqCst) { return; }
    calls.stop_all();                                              // every call: SIGTERM, grace, SIGKILL, then its answer
    calls.wait_empty(KILL_GRACE + SHUTDOWN_MARGIN);                // Condvar::wait_timeout, bounded
    std::process::exit(0);
}
```

### Results are told the way the node server tells them

Decision: a result is `{"content": [{"type": "text", "text": <body>}], "isError": <exit != 0>}` where the body is pretty-printed with two spaces and holds, in this order, `exit`, `outcome` (the first name of the program's `exit` table that carries the code, else `exit <code>`), `stdout`, `stderr` and, when a stream was cut, `truncated`. A refusal (`usage`, `refused`, `error`) has the same shape with an empty stdout and the reason on stderr. When stdout, after leading JavaScript white space, starts with `{` or `[` and parses as JSON, the body holds the parsed value and not the escaped string; anything else stays text. `serde_json` runs with `preserve_order`, so a program's keys come back in the order it wrote them, and with `arbitrary_precision`, so the parser hands over the digits of a number and not a rounded float. The printer (`JsPretty` in `mcp/run.rs`, over `js::number_text`) then writes each number the way `JSON.stringify` writes what `JSON.parse` made of it: `1.0` is `1`, `1e21` is `1e+21`, `0.000001` stays `0.000001`, and a number beyond the range of a double is `null`. The last digit is decided by the printer and not by the shortest-digit formatting of Rust, which rounds a tie up where JavaScript rounds it to even (`270348394056782.125` is `.12` in JavaScript), and the suite has a scenario for numbers that holds that case. The white space test is `js::is_space`.

Reason: byte equality of the body is what lets the suite compare the servers without a model of what "equivalent" means, and what the model reads is the text.

The differences that remain, all listed here and none pinned as equal: JSON nested deeper than 128 levels stays text (`serde_json`'s limit); a lone surrogate escape in a *request* is read as U+FFFD, which is what node's spawn passes to the program, so the calls match, while a lone surrogate in a program's JSON stays text where node parses it, and where a server writes a request string back (the name in `unknown tool <name>`, the `id` of a request) Rust writes U+FFFD and node writes the escape; a second signal during the ending is ignored by Rust, where node dies by a repeat of the same signal and a program that ignores SIGTERM outlives the call; a holder outside the group that keeps writing holds a Rust call for up to the drain plus the grace (a call that was stopped, by a timeout, a cancellation or the server's ending, is given up on at the drain whether or not a helper holds the pipes, so a reader thread descheduled for longer than the drain can cost it output that node's one thread, which reads in its poll phase whatever stopped the call, would have read: a second grace could overrun the server's ending, which waits `KILL_GRACE` plus `SHUTDOWN_MARGIN`), where node destroys the streams at the end of the drain, and a reader thread descheduled between reading a chunk and storing it loses the chunk when a holder keeps the emptied pipe open past the drain, which node's one thread cannot do; a request nested deeper than 128 levels is ignored by Rust (`serde_json`'s limit) where node answers it; the keys of an object whose names are integers are not moved to the front; a call argument named like a member of `Object.prototype` (`constructor`, `toString`) is refused as unknown, where node lets it through and ignores it; the operating system's reason for a spawn that fails for a cause other than a missing program is Rust's text, not Node's; the child leads a process group, not a session (a program that reads the controlling terminal is stopped by SIGTTIN where node's child gets ENXIO); a missing contract file reports Rust's text; the usage line and the start-up failure carry `tagents-core mcp` and not `tagents-mcp`. What building found beyond these is listed in the MCP part of `docs/architecture/rust-core.md`, the list that stays true after this change is archived.

### The node server is the oracle: a differential suite

Decision: `tests/rust-mcp-parity.sh` builds `target/debug/tagents-core` and `packages/mcp`, puts stub programs named like the contract's programs on `PATH` (small POSIX scripts that print JSON, text, nothing, more than the cap, a multi-byte character across the cap, exit with each code of the table, sleep, start a helper that holds the pipe), and runs one typed driver (`tests/rust-mcp-parity-driver.mts`) against each server. The driver sends a script of requests, waits for the answers it expects, closes stdin, and prints the transcript keyed by request id; the script compares the two transcripts byte for byte after dropping `serverInfo.version`. The script covers: `initialize` with every protocol version the SDK lists (read from the SDK, so the Rust list is pinned to it) and one it does not list; `ping`; `tools/list` on a fixture contract that has every effect, an unknown effect, `tool: false`, `serve`, `toolDefaults`, `requires`, a multiple option and word positionals, and on the bundled `contract.json`; a call for each path of `argvFor` and each way a call ends (every exit code, JSON and text output, cut output, a cut across a character, the program missing, `requires: tmux` without `TMUX`); an unknown tool and an unknown method; a cancelled request (neither server answers it, and nothing is left running); two calls in flight answering in either order; stdin closed with a call in flight (the group gone; node races `process.exit` against writing the answers to the calls an ending stopped, so which of them arrive changes from run to run, and the suite leaves those answers out of the comparison and pins the Rust ones, always `cancelled`, in a check of its own). Timeouts and the grace are not in the suite, because the servers take them from constants; the Rust tests for `run` take them as `RunDeps` and use milliseconds.

The Rust side also carries the node server's own tests, ported: every case of `packages/mcp/test/{tools,contract-file,run,process,server,smoke}.test.ts` has a Rust test or a stated reason it does not apply, and the constants (`MAX_STREAM`, the timeout, the grace, the drain, the margin) are pinned against the TypeScript sources by a test that reads them. The pin and the suite go when the node server does.

Reason: the node server is the specification of the behaviour and it is in the same checkout, so running both on one script is cheaper and says more than describing the behaviour twice.

Rejected: comparing the Rust server with recorded transcripts (they would rot, and nothing would say which side moved); golden files of `tools/list` alone (they would not cover the call path, which is where the process handling is).

### Dependencies

Decision: three lines in the dependency table of `rust-core`'s design and of `docs/architecture/rust-core.md`, each with its reason and its measured cost (release size delta, crates added, clean build time), filled in by the change that adds them:

| dependency | used by | reason | cost |
|---|---|---|---|
| `serde_json` features `preserve_order`, `arbitrary_precision` | `mcp` | a program's JSON keeps its order and its numbers; the contract's maps keep the file's order | `indexmap`, `equivalent`, `foldhash`, `hashbrown`; the features are additive, so they apply to every crate of the workspace |
| `rustix` (features `process`, `event`) | `mcp::run` | signal a process group, wait without reaping and ask a pipe whether it is readable, in safe code (`unsafe_code = "forbid"` stays) | `bitflags`, `errno`, `libc` |
| `signal-hook` | `mcp::server` | end on SIGTERM, SIGINT, SIGHUP from a thread, in safe code | `signal-hook-registry` |

In total the three rows add 10 crates (23 in the build of `tagents-core` instead of 13) and 300,320 bytes to the release binary (518,992 to 819,312), and take a clean release build from 8.8 s to 12.5 s; the server does not build without them, so no row can be measured apart. `rustix` has `waitid` with `NOWAIT`, `kill_process_group` and `poll` on the three release targets, and the dry run of `release.yml` on the pull request builds all three; if one of them fails, `nix` is the substitute and the line says so. A fourth dependency is a new line and a reason.

### Version and release

Decision: the change raises the workspace version to the next minor above the one on `main` when it merges (`core-release.sh gate` requires it: `Cargo.toml`, `Cargo.lock` and `crates/*/src/*` change). It cuts no tag. A managed copy that updates to that commit finds no release for the version, removes the older binary and says so, and keeps running node for the CLI and the server, exactly as after any version bump before its tag; the footprint saving reaches installs when Sasha tags the version. `pnpm plugin:gen` moves the plugin's own version one minor step and rewrites its digest, because the new verb is in the generated skill references; both come from the generator and are not edited by hand.

Reason: the release path is built so that an install never runs a binary of another version, and this change does not weaken it for the sake of getting there sooner.

## Risks / Trade-offs

- [A bug in the server takes the plugin's tools away in every session] → the parity suite and the ported tests run on every change to the crate or to `packages/mcp`; the node server stays installed as the fallback; `TAGENTS_NO_NATIVE=1` at the next install, or removing `target/release/tagents-core`, returns a machine to node.
- [The SDK moves on and the node server is no longer the specification] → the suite reads the SDK's protocol versions from the SDK, and the node server is pinned by `pnpm-lock.yaml`; a client that asks for a newer version gets the latest this server knows, as it does from node.
- [Threads and process groups behave differently on Linux and macOS] → the suite and the tests run in CI on Linux and on macOS; the release job builds all three targets.
- [Stub programs written during a test and spawned from another thread hit ETXTBSY] → the tests share the fork gate that `tests/front_door.rs` already has (moved into a common test module and reused, not copied).
- [A reader thread stays blocked on a pipe an escaped helper holds] → it holds a capture of at most 256 KiB and ends with the holder or with the server; the drain keeps the call itself from waiting on it.
- [Moving the server shifts the sessions' memory to the binary's first call] → measured on the same contract: the `footprint` of an idle `tagents-core mcp` is 1600 KB where the node server's is 38 MB, and the time from spawn to the answer of `initialize` is a median of 3.2 ms over ten runs where node's is 99.7 ms.

## Migration Plan

1. Merge this change. No release exists for the new version, so the installer's behaviour is unchanged on every machine: node serves the tools.
2. When Sasha tags the version, the next daily update of each managed copy installs the binary, and the wrapper starts `tagents-core mcp` for new sessions; sessions already running keep their node process until they end.
3. Rollback is `TAGENTS_NO_NATIVE=1` on one machine (the binary goes at the next install), or deleting the release (the next install finds none and removes the binary).
4. After a release has run on the managed copies for a while, a later change retires `packages/mcp`, the suite and the constants pin.

## Open Questions

- When the version this ships in is tagged (Sasha's word); until then the saving does not reach a managed install.
- Whether to remove the seven hand-made `tagents-knowledge mcp` registrations on the author's machine now: about 200 MB, no code, independent of this change.
