## Context

`tagents-core session open|prompt|last|list|abort` are served by `packages/core/src/cli/main.ts` (`session`, lines 52-196) over `ClaudeHeadlessDriver` (`claude-driver.ts`, 566 lines), `StreamReader` (`stream.ts`), `parseSessionRef` (`session-ref.ts`), the state reader (`agent-state.ts`) and `isAlive` (`pid.ts`). The front door already serves `sessions` and `plugin add|remove` from Rust, and hands everything else to node (`front_door.rs`, `GROUPS`). The slice plan of the archived `rust-core` change calls this stage S3 and leaves open whether the driver shares the crate of the front door (its design, line 250).

Three premises of the brief do not hold for these five verbs, each checked in the source. The verbs never read the tagents config: there are no accounts or profiles to resolve, the account is `--config-dir`, `--no-config-dir` or the inherited `CLAUDE_CONFIG_DIR` (`grep -n -i "profile\|accounts\|config.toml\|loadConfig" packages/core/src/claude-driver.ts packages/core/src/cli/main.ts` finds nothing). Nothing in them touches tmux: the word occurs only in comments about the hook that writes the state records. And `prompt` does not wait on the state records or the transcript: it waits on the child's stdout, its exit and a deadline, and the state records are written by the hook that `claude` itself runs (`hooks/tmux-agent-state.sh`), which the verbs only read afterwards (`list`, `abort`, and `last` through `transcriptOf`).

What a turn is, in node's words: spawn `claude -p …` with a computed environment and `stdio` of `ignore`, `pipe`, `pipe`; feed every stdout chunk to `StreamReader`; the turn is over at the first well-formed `result` event; a child that does not leave within 60 s after its result is killed and the turn still succeeded; a child that never produces a result is killed at the deadline (50 minutes of awake time by default); after the child exits the pipes get 5 s to drain. The outcome is one of five kinds and the exit code is 0, 4 or 1. Every constant and every decision of that machine is read from the source, and the vectors of D12 pin the parts that exist twice.

The constraint that shapes the design: `prompt` cannot hand the call to node once `claude` runs. Whatever node would refuse, rewrite or print differently has to be decided before the spawn (D2), and what happens after the spawn has to equal node's bytes with no way back (D6 to D8).

## Goals / Non-Goals

**Goals:**
- Serve the five verbs from the Rust binary with node's stdout, stderr, exit codes, key orders, number formats and texts, in both locales.
- Make every call outside the proved subset a hand-over to node, decided before anything is read or started.
- Keep node as the oracle: it stays in the tree, a vector file and a parity suite compare the two, and node's own defect (the chunk decoding) is fixed first.

**Non-Goals:**
- The plugin host (S4) and retiring the fallbacks (S5).
- The `--input-format stream-json` mode of the driver: the CLI never uses it, so the verbs never feed stdin.
- Serving `session` with a missing or unknown verb: node prints its usage.
- Any change to the state hook, the messages, or the generated plugin contract.

## Decisions

### D1. `session` is a group beside `sessions`, and `prompt` writes its own output

`front_door.rs` gains one `Group` with `word: "session"`, `lossy_args: false` (a call with an argument that is not UTF-8 goes to node whole, as for `plugin`, because a path must not be read as another file), and `run: session::run`, which returns `None` to hand the call to node.

```rust
Group {
    word: "session",
    verbs: session::VERBS,          // [["session","open"], …, ["session","abort"]]
    lossy_args: false,
    run: |argv, cx| session::run(argv, cx),
},
```

The `Group::run` signature stays as it is, so the change does not collide with `rust-plugin-verbs` and `rust-knowledge`, which edit the same table. A verb that has to write while it works, `prompt --events`, writes its lines itself and returns an `Output` that holds only the exit code. For that, `emit` of `front_door.rs` is split into `emit_stdout` and `emit_stderr`, each the best-effort write it already is (a reader that went away is ignored, which `headless-sessions` requires of every write), and `session` calls the two. `prompt` writes the outcome and the error line itself, in node's order, before it lingers (D6), so that `2>&1` shows the same order and the same time as node.

Options considered: a `Group` field for "streams" (a wider contract for one verb and a collision with the two builders), and a new arm beside `mcp` and `notify run` (those own their whole word; `session` shares its word with four verbs that return whole outputs). The group is the smaller change.

Rust serves `open`, `list` and `last` in the first pull request, `prompt` in the second and `abort` in the third, each flag flipped last in its pull request. The group answers a verb only when its `impl` is `rust` in `spec/cli/tagents-core.json` (`served_spec` reads the same file), so a pull request that has not flipped a verb leaves it with node. The rule "a first word served by both programs has only `rust` paths of two words or more" of `packages/core/test/cli-spec.test.ts` already holds for `session open` beside a node `session prompt`.

### D2. What is handed to node before anything is read or started

`session::run` returns `None`, with nothing read, written or started, for each of these:

- the verb is missing or unknown (node prints `unknown command: session <verb>` and the usage, exit 2; Rust serves neither, so S5 decides the usage text);
- the arguments are outside the grammar of D3: node's `parseArgs` would throw (an unknown option, a missing option value, a value that starts with `-`, a positional where none is allowed, `--flag=value` on a boolean, a short option). The error texts of `parseArgs` are node's, they vary with its version, and the exit code 2 comes from the error's code, so they are not copied;
- a reference given as JSON (`prompt`, `last`, `abort`) that parses but holds a lone-surrogate escape in a key or in a string that reaches an argument or the environment (the argv would differ), or a `spec.env` entry that node's `spawn` rejects (an empty name, a name with `=`, a NUL in a name or a value), a NUL in `cwd`, `bin`, a label or any other value that becomes an argument, an empty `bin`, or a relative `bin` that contains a slash (its base directory is a platform detail of `spawn`);
- the environment of the CLI holds a name or a value that is not UTF-8 (the child's environment is built from it, entry for entry);
- `node` cannot be found: the first entry of the child's `PATH` is the directory of the running node binary (`process.execPath`), which Rust reproduces as the directory of the real path of `$TAGENTS_NODE`, else the `node` found on `PATH` (`node::interpreter`, `node::find_on_path`, `node::realpath`, the choice `exec_node` makes). With no node to name, the front door cannot run the fallback either, so there is nothing to compare with and no replacement is invented (S5 decides one);
- `open` cannot read 16 random bytes from the system (no `uuid` crate is added: the id is RFC 4122 version 4 from `/dev/urandom`);
- after the spawn has failed with an errno other than `ENOENT`, `EACCES` or `ENOTDIR` (D5): nothing has run, so node can run the call.

A reference that is not JSON, or that fails the schema, is not handed over: node prints `no session matches <ref>` with exit 1, Rust prints the same text from the catalogue, and the vectors of D12 hold the schema decisions (D8).

### D3. One grammar for the options of a verb group

`parseArgs` of node is what accepts or rejects a call, and `plugin.rs` has a 20-line hand-written reader of one option (`parse`, `plugin.rs:92`). `session` has four option sets (`open`: eight string options and two booleans; `prompt`: `--timeout`, `--warn-before` and the boolean `--events`; `list`: `--label` and a repeated `--state`) and two verbs that take a raw first word (`last`, `abort`).

Options considered: (a) copy `plugin::parse` four times, which is the parallel copy the repository forbids; (b) generalise `plugin::parse` in place, which collides with `rust-plugin-verbs` part b, the builder editing that file; (c) a table-driven grammar in a new module `args.rs`, and `plugin::parse` migrated onto it in the last pull request, after part b has merged. Chosen: (c), with a unit test that feeds a corpus of argument lists to both `args::parse` with the `plugin add` table and `plugin::parse` and requires the same answer, which is the pin the repository asks for while two readers exist (it is removed with the old one).

```rust
pub struct Grammar { strings: &'static [&'static str], flags: &'static [&'static str], multiple: &'static [&'static str], positionals: bool }

const OPEN: Grammar = Grammar {
    strings: &["cwd", "resume", "label", "model", "effort", "system-prompt-file", "mcp-config", "config-dir"],
    flags: &["no-config-dir", "skip-permissions"],
    multiple: &[], positionals: false,
};

// None: node's parseArgs throws, or means something this grammar does not model.
let parsed = OPEN.parse(args)?;
```

It reads `--name value` (the value must not start with `-`) and `--name=value` for a string option, a bare `--flag` for a boolean, a lone `-` and everything after `--` as positionals, and returns `None` for the rest. A repeated string option keeps its last value, and a repeated `multiple` option keeps all of them, as `parseArgs` does. `last` and `abort` do not parse: `rest[0]` is the reference, whatever it looks like (`session last --foo` asks for the session `--foo`), which the verbs repeat.

### D4. How `claude` is started and fed, and who owns the process

A session is a reference, a JSON value that `open` prints and starts nothing for. `prompt` owns the child for the length of the call and nothing longer: it spawns it, supervises it, and the call ends with it. A session that is attached to by reference, with a long-lived owner, is what `list` and the hook's state records already offer for observation and `abort` for stopping, and node does not have a second kind of owner. Rejected: a resident supervisor process (a new daemon, a new failure mode, and a different `open`).

The argv and the environment are a one-to-one port of `buildArgs` and `childEnv` (`claude-driver.ts:93-142`):

- argv, in order: `-p`; `--model M` and `--effort E` when set and non-empty; `--disallowedTools a,b` joined with commas when the list is non-empty; `--strict-mcp-config --mcp-config F` when `mcpConfig` is set; `--output-format stream-json --verbose`; `--dangerously-skip-permissions` when `skipPermissions` is true; `--append-system-prompt-file F`; `--resume ID` when the reference's `claudeSessionId` is non-empty; and the prompt text last, which is how a text that starts with `-` is never read as an option (`headless-sessions`, "The prompt is never swallowed by an option").
- environment: the CLI's own, minus every name that starts with `CLAUDE`; then `CLAUDE_CONFIG_DIR` set from the account choice (the inherited value when `spec.configDir` is absent, nothing for `null`, the string otherwise; set only when non-empty); `PATH` as the node directory, `~/.local/bin`, then the inherited entries split on `:` with empty ones dropped, de-duplicated by first occurrence; `TA_LABEL` from a non-empty label; `TA_LOG` from a non-empty `logFile`; then `spec.env` entries, which win. `TA_STATE_DIR` is not set by the driver: the child inherits it, as it inherits the rest.
- spawn: `claude` or `spec.bin`, in `spec.cwd` (an empty `cwd` means the working directory of the CLI), with `stdin` closed to `/dev/null`, `stdout` and `stderr` piped, in the process group of the CLI. There is no process group of its own: node starts none, and a terminal Ctrl-C reaches `claude` through the shared group.

A bare `claude` is looked for on the child's `PATH` by `Command`: the standard library documents that on Unix the `PATH` that is searched is the child's own when it is set there (`library/std/src/process.rs:621-625` of rustc 1.99.1). It does not follow that std's `execvp` and libuv's walk of `PATH` agree on a file that is not executable or a directory that carries the name, so two parity scenarios (D12) put each of them earlier on `PATH` than a good `claude`. If they differ on a target, the first match of `node::find_on_path` becomes a hand-over class decided before the spawn; a second walk is not written.

Rust has no `spawn` option list to copy, and node's quirks at this point are found by running it: `cwd: ''` inherits the working directory (a missing `cwd` is an asynchronous `spawn <bin> ENOENT`), a `cwd` that is a file makes `spawn` throw `spawn ENOTDIR` before any event (D5), an empty `bin` throws `ERR_INVALID_ARG_VALUE` whose wording is version-dependent (so it is a hand-over), and the `PATH` that finds a bare name is the child's.

### D5. Spawn errors

Node reports five errnos of `spawn` through the `error` event (`EACCES`, `EAGAIN`, `EMFILE`, `ENFILE`, `ENOENT`) and throws every other one before returning. The two shapes end differently: the event becomes the outcome `spawn-failed` with `detail` `spawn <bin> <CODE>`, the line `exit=null spawn: <detail>` and exit 1; the throw reaches `main()`'s `catch`, which prints the error's message (`spawn ENOTDIR`, no file name) on stderr, no outcome on stdout, exit 1.

Rust answers `ENOENT` and `EACCES` as the first (the file name is the `bin` as given, so a missing `cwd` and a missing program print the same words, as in node), `ENOTDIR` as the second, and hands every other errno to node, which is safe because nothing has run. A scenario of the parity suite pins each of the three. Which errno node reports for a given file is the part that varies with its version, which is why the classification is exercised by scenarios and is not recalled.

### D6. Waiting: one supervisor, one channel, no polling

Options considered: (a) a polling loop with a short sleep (what `child::run` avoids with its `DRAIN_STEP` poll, and a latency and a wake-up for nothing); (b) `child::run` itself (it captures output instead of streaming it, kills the whole process group at exit, uses SIGTERM before SIGKILL, has no result phase and starts the child in a process group of its own, so none of its policy is node's); (c) a single-threaded state machine fed by one thread per pipe and one waiting thread over a channel, sleeping in `recv_timeout` until the next deadline. Chosen: (c), built from the leaf helpers of `child.rs` that are policy-free (`wait_for_exit`, `duplicate`, `readable`, `spawn_thread`, made `pub(crate)`), which is the reuse the repository asks for.

```rust
enum Msg { Out(Vec<u8>), Err(Vec<u8>), OutEnd, ErrEnd, Exited }

let outcome = loop {
    let msg = match turn.next_timer() {          // the earliest of deadline, grace and drain
        Some(at) => rx.recv_timeout(at.saturating_duration_since(Instant::now())),
        None => rx.recv().map_err(|_| RecvTimeoutError::Disconnected),
    };
    match msg {
        Ok(Msg::Out(bytes)) => turn.feed(&bytes, &mut sink),   // lines out, events written as they come
        Ok(Msg::Err(bytes)) => turn.stderr.extend(bytes),
        Ok(Msg::Exited)     => turn.exited(child.wait()),      // reaps: the child is ours until this call
        Ok(Msg::OutEnd) | Ok(Msg::ErrEnd) => turn.end_of_pipe(),
        Err(RecvTimeoutError::Timeout) => turn.timer(Instant::now(), &child),
        Err(RecvTimeoutError::Disconnected) => break turn.finish(),
    }
    if let Some(done) = turn.done() { break done }
};
```

The machine is node's, with the same three phases and the same timers:

- **Running.** A deadline at `start + timeout` of awake time kills the child with SIGKILL (the lone pid, `rustix::process::kill_process`, no process group) and marks the turn `timedOut`. The deadline is an `Instant`: on macOS std reads `CLOCK_UPTIME_RAW` (`library/std/src/sys/time/unix.rs:67`, rustc 1.99.1), which does not advance while the machine sleeps (`man clock_gettime`), and on Linux `CLOCK_MONOTONIC` (same file, line 70), which the kernel documents as not counting suspend; that Linux claim is documented, not run here. Node counts awake time by ticks of 10 s that add at most two ticks of gap, so the one difference is an awake stall of the event loop longer than 20 s, which node discounts and an `Instant` does not. A timeout that cannot be added to an `Instant` (a huge `--timeout`) is no deadline, so `Duration::from_secs_f64` never panics.
- **Resulted.** The first well-formed `result` cancels the deadline and starts a 60 s grace; if the child has not exited by then it is killed. The turn already succeeded: a payload with `is_error` false ends as `ok`, or as `killed-after-result` when the child's code is not 0 (a signal counts, its code is null).
- **Exited.** The waiting thread's `Exited` message reaps the child, and 5 s start for the pipes to drain. The turn finishes when both pipes have reached their end or when the 5 s are over, whichever is first, and at the second the machine first takes what is already queued and what `child::readable` still reports, a bounded loop, so that a line the child wrote before it exited is not lost to the order in which a timer and a read happen to run. Node's event loop can lose such a line; the Rust port does not copy a race.

The decision of `finish` is node's order: a spawn error is `spawn-failed`; a payload whose `is_error` is `false` is `killed-after-result` or `ok`; otherwise a timeout is `timeout`; otherwise `exited`. A payload without `is_error` is not ok. The turn's `detail` is the payload's `result` when the payload has that field, even when it is the empty string, and the collected stderr only when it has not; it is white space collapsed and cut at 300 UTF-16 units. `limitMs` and every number print through `js::number_text`, and the `--timeout` and `--warn-before` values read through `js::number` (finite and above 0, else the default), so `--timeout 0.5` and `--timeout 1e3` do what node does. `--warn-before` is read and prints nothing, because the CLI gives the driver no warning callback.

After the outcome is printed the process does not exit at once. Node never destroys the child's pipes, so a grandchild that keeps one open keeps the node process alive until it lets go. Measured here with a stub `claude` that left a background `sleep 14` holding the pipe: the outcome's `durationMs` was 5185 (the drain) and the process ended after 15 s (`date` before and after the call). Exiting at the drain would also change what that grandchild sees on its next write (a closed pipe, SIGPIPE), which no caller asked for. So Rust lingers the same way: the reader threads keep reading and discard until both pipes end, and the process exits then. Ending at the drain instead is a decision for the stage that retires node.

### D7. Signals, a CLI that is stopped, and a `claude` that dies

The CLI installs no signal handler and leaves every disposition at its default. A SIGTERM or SIGINT that arrives during a turn ends the Rust process by that signal, and the child is left running, which is what node does (`headless-sessions` says nothing about signals to the CLI, and node's driver has no handler: the `abort` it offers is for a library caller). A turn that outlives its starter is found by `session list` and stopped by `session abort`, which is how the verbs are used today. Rejected: killing the child on a signal (it changes what a caller can observe), and a handler that re-raises the signal (`ending::on_signals` is for the MCP server and the notify daemon, which have an end of their own to run).

A `claude` that dies is the `exited` outcome: its code, or the name of the signal that ended it, and `detail` from the stderr it wrote. The names come from a table of the platform's signal names, pinned against `os.constants.signals` by a vector; a number that is not in the table is code 0 and signal `null`, because node's `signo_string` returns an empty string for it and the exit is read as a code. A last line with no newline is read at the end of the stream, as `StreamReader.end` does.

### D8. The stream, exact strings, and the bytes of `--events`

The reader is `StreamReader`'s decision tree: a line is trimmed (`js::trim`, which is ECMAScript's) and must start with `{` and parse; the `session_id` of an event that matches the envelope (`type` and `session_id` each absent or a string) is remembered when it is not empty; then, in order, a `result` event (the payload schema extended with `type: 'result'`), an `assistant` event whose content blocks are `tool_use` (a name, an optional `input` record) or non-empty `text`, a plain payload with no `type` that has an `is_error` key, and otherwise an `other` event naming the `type`. A `result` whose fields fail the schema (`is_error: null`, a `total_cost_usd` that reads as infinity, `result: 5`) falls through to `other` and does not end the turn. Each of these was found by running node's `StreamReader`, and the vectors feed a corpus of lines to it.

Lines are cut on the byte `0x0A` before they are decoded, and a line is decoded with `String::from_utf8_lossy`, so a character split between two reads is whole and invalid bytes read as U+FFFD, the maximal-subpart replacement that `StringDecoder` gives. Node does not do this today: it decodes each chunk with `toString()`, so a split character becomes two U+FFFD (Russian text makes it likely), and an oracle that is nondeterministic cannot be compared with. The first commit of the first pull request fixes node with a `StringDecoder` per pipe, a test, and the ADDED requirement of `headless-sessions`.

Strings need their UTF-16 meaning because the stream path cannot hand a call back to node. `claude` is node, and `JSON.stringify` writes a lone surrogate as the escape `\udXXX`, so `\ud83d` can arrive in a text, a tool input or a payload, and node prints it back as `\ud83d`; concatenation of two text blocks can join two halves into a character; a cut at 300 units can leave half of one. `json::parse` reads a lone surrogate as U+FFFD, which is right for a transcript read for a listing and wrong here. So:

- `json.rs` gains `parse_exact`, which keeps a string that holds a lone surrogate as `Value::Units(Vec<u16>)` and every other string as `Value::String`; `parse`, and every reader that calls it, is unchanged;
- the accumulators of a turn (`text`, `detail`) hold UTF-16 units, and the operations on them (append, trim, collapse white space, cut at n units, turn into text or an escape) are added to `js.rs` next to `len16`, `take16` and `split16`, which they extend;
- `json::stringify(&Value, indent)` prints a value as `JSON.stringify` does, with `json::quote` for a valid string, `js::number_text` for a number (infinity prints `null`), the escape for `Units`, object keys in JavaScript's order (keys that are array indices first and ascending, then insertion order, a key written twice keeping its first place and its last value) and the two-space layout when `indent` is set. `mcp/run.rs` keeps its `JsPretty`, a formatter over `serde_json` bodies, which cannot hold a lone surrogate: the two printers share `quote` and `number_text`, and both are pinned against `JSON.stringify` by the same vector file;
- `session last` reads the transcript through the loop of `transcripts::last_assistant_text` with the parser as a parameter, so `sessions show` keeps the lossy reading, which is what its stdout shows, and `session last` reads exactly, which is what `JSON.stringify` shows.

A key that holds a lone surrogate is the one thing the exact mode does not keep; the vectors name it and `docs/architecture/rust-core.md` lists it under "Where the two are known to differ", with the reason that nothing in the stream or a transcript is keyed by it.

The bytes of `--events` are `JSON.stringify` of the event with the keys in the order node builds them, one compact line each, written when its line has been read:

- `{"kind":"tool_use","name":…,"input":{…}}` with `input` as an object (`{}` when absent) from a record that drops a `__proto__` key, whatever its value;
- `{"kind":"text","text":…}`;
- `{"kind":"result","isError":bool,"payload":{…}}`, the payload being the schema's output: its known keys in the order `is_error, result, session_id, total_cost_usd, duration_ms, num_turns, type` when present, then the unknown keys in input order (a top-level `__proto__` is dropped, a nested one is kept and printed), printed in JavaScript's key order, so a key that is an array index comes first;
- `{"kind":"other","type":…}`;
- then the outcome as one compact line.

The outcome's key order is `kind, text, sessionId, toolUses, costUsd, numTurns, durationMs` for `ok`, the same then `code` for `killed-after-result`, `kind, sessionId, toolUses, limitMs, detail, sawText, sawResult` for `timeout`, `kind, sessionId, toolUses, code, signal, detail, sawText, sawResult` for `exited` and `kind, detail` for `spawn-failed`. Without `--events` the outcome prints in the two-space layout. `sessionId` is the payload's `session_id` when it has one, even empty, and the envelope's otherwise.

### D9. `last`, `list`, `abort` and their exit codes

All three read the state directory (`$TA_STATE_DIR`, else `~/.claude/agent-state`) with `notify::state::{state_dir, read_agent_state, labels_by_session}`, which node's reader is already pinned against. The row gains one field, `pid: Option<u32>` (column 8, read as `Number()` with an integer check and above 0), because the five verbs need nothing else of the columns the notify daemon does not already read.

- `last <ref>` prints `{"text": …, "at": …}` for the last assistant text in the tail window of the transcript (the reference's, else the one a state row names for its `claudeSessionId`), or `null` when there is no transcript, no file or no text. `at` is the file's `mtimeMs` as the exact double, through `js::number_text`; `node::mtime_double` is private today and gets a public wrapper beside `mtime_ms`. A transcript that exists and cannot be read prints the existing `Failure` message and exits 1, which is what `main()`'s `catch` does for node's throw. Exit 0 otherwise.
- `list` prints the references of the state rows that are not `subdone`, filtered by `--label` (exact, against the label of `history.tsv`) and by `--state` (any of `new`, `working`, `blocked`, `done`, `gone`), in the order the reader returns them; a spec holds `kind`, `cwd`, `skipPermissions: false`, the label when it is not empty, and `configDir` only when the row has the seventh column (`null` when it is empty). An unknown state is `unknown option --state a,b`, exit 2.
- `abort <ref>` matches the first row whose key equals the reference's `id` or whose `sessionId` equals its `claudeSessionId` (a `null` never matches, an empty string can match an empty column). A row whose key does not start with `s-` is a pane: `abortPaneAgent`, exit 3. No pid, or a pid that is not alive, is `nothingToAbort`, exit 3. Alive is `kill(pid, 0)` succeeding or failing with `EPERM`, and a pid beyond 32-bit signed integers is dead (node's `process.kill` throws for it, checked on 4294967297 and 2147483648; 2147483647 gives `ESRCH`); `is_alive` of `notify/lock.rs:117` is that check already, so it becomes `pub(crate)` and `abort` calls it instead of a second copy. A SIGKILL that fails is `nothingToAbort`; one that works prints `{"aborted": true, "id": …, "pid": …}`, exit 0. The pid-reuse window between the check and the signal is node's, and is listed rather than closed.
- A reference that is a string and not JSON is resolved against `list` (the id or the `claudeSessionId` first, then a unique-or-first prefix of a `claudeSessionId`), the way `resolveRef` of `main.ts` does; a reference that starts with `{` after trimming is read as JSON. No match is `no session matches <ref>`, exit 1.

The exit codes are the ones of `cli/exit.ts`: 0 ok, 1 error, 2 usage, 3 refused (`abort`), 4 timeout (`prompt`). `sessions::exit` already holds 0 to 3, and the unit test of `rust-plugin-verbs` that pins it to the `exit` table of the data file gains 4.

### D10. The texts

Every line the verbs print comes from `spec/cli/messages.json` through `messages::Texts::t`, in the locale `Locale::of` chooses: `missingOption`, `unknownOption`, `noPrompt`, `badRef`, `abortPaneAgent`, `nothingToAbort`. All exist in English and Russian, so no catalogue key is added and no string is copied by hand. The two lines that are not catalogue text are node's own words, `exit=…` (the error line, built from the outcome as `formatAttemptError` does) and `spawn ENOTDIR` (an `Error`'s message), and they are literal in both languages in node too.

### D11. Keeping the machine awake

On macOS, unless `TA_KEEP_AWAKE` is `0`, node runs `caffeinate -i -w <child pid>` with all three streams ignored, found on the CLI's own `PATH` (not the child's), and releases it at the end of the turn by a SIGTERM to that process, which does not hold node alive. Rust does the same with `Command` and `rustix::process::kill_process` with `Signal::TERM` (std's `Child::kill` is SIGKILL), and a failure is silent because the CLI keeps no log. `caffeinate` exists on macOS only, so the code is `cfg(target_os = "macos")`; the parity suite puts a stub `caffeinate` on `PATH` that records its argv, and compares the recorded line after normalising the pid to the stub `claude`'s recorded pid.

### D12. The stub, the vectors and the parity suite

**The stub `claude`** is `fakeClaude` of `packages/core/src/testkit.ts`, which already writes a real executable `claude` and covers what the scenarios need: a session id, noise lines, tool calls, text, a sleep, a result (or none, or a plain payload), a hang after the result, a hang, silence, an exit code, stderr, a count file, a chunked mode and an `argvFile` that records the argv, the whole environment and the kind of stdin. The suite drives it from `tests/rust-session-parity-driver.mts`, which imports it by relative path (node runs `.mts` files with their types stripped, as `tests/rust-plugin-vectors.mts` already relies on), and four options are added, each used by a scenario below: `rawWrites` (pieces written to stdout verbatim and in separate writes, for a character split between two writes, invalid UTF-8 and a lone-surrogate escape), `grandchildMs` (a background `sleep` that inherits stdout, for the lingering of D6), `killSelf` (a signal the stub sends itself after its script, for a child ended by a signal) and `pidFile` (the stub's pid, so a scenario can show that the child is still alive after the CLI was signalled). `chunked` cuts by UTF-16 units and so never splits a character.

**The suite**, `tests/rust-session-parity.sh`, follows `tests/rust-plugin-parity.sh` and `tests/rust-notify-parity.sh`: each scenario runs twice, `node packages/core/dist/cli/main.js <args>` and the binary (`$TAGENTS_CORE_BIN`, else `target/debug/tagents-core`), each on its own pristine copy of one tree at one path, with a scratch `HOME`, `TA_STATE_DIR` and `TMPDIR`, a `PATH` that holds the stub `claude`, a stub `caffeinate` and a symbolic link to the real `node`, and `TAGENTS_NODE` pointing at a shim that notes when the binary handed the call to node. A scenario passes when stdout, stderr and the exit code are the same bytes, the stub's recorded argv and environment (the environment as a sorted list) are the same, and the state directory is the same, once the volatile parts are normalised (the `id` of a new reference and `durationMs`). A scenario marked `rust` fails when the binary handed the call to node, so a binary that forwarded everything cannot pass. `PARITY_SELF_TEST=1` runs node on both sides, `PARITY_ONLY`, `PARITY_SHOW` and `TAGENTS_NODE` behave as in the other suites.

Scenarios, by verb:

- `open`: every option, in both account forms; a missing `--cwd`; `--config-dir` with `--no-config-dir`; a relative `--cwd` made absolute; `--resume` with and without a state row that names a transcript.
- `prompt`, the argv and the environment: each option of the reference in turn, `--resume`, an inherited `CLAUDE_CONFIG_DIR` kept and dropped, a `CLAUDE_X` variable dropped, `spec.env` winning, `TA_LABEL` and `TA_LOG`, the `PATH` entries and their order with the stub found in `~/.local/bin` and with the symbolic link to node, a prompt that starts with `-`.
- `prompt`, the outcomes: `ok`, a result then a hang (the 60 s grace is a Rust unit test with injected durations, not a parity scenario), a nonzero exit after the result, `exited` with a code, with a signal, with stderr only, `timeout` (`--timeout 300`), a result with `is_error` true, a result that fails the schema, a payload with no `type`, noise lines, tool calls and text with `--events`, a chunked stream, a character split between two writes, invalid UTF-8, a lone-surrogate escape in a text and in a tool input, two results, a last line with no newline.
- `prompt`, the negative paths: no `claude` on `PATH`, a session that does not exist, an empty prompt, a missing `<ref> <text>`, a missing `cwd`, a `cwd` that is a file, a directory and a non-executable file named `claude` earlier on `PATH`, a `bin` that is a directory, a `claude` that is a text file with no `#!`, a reference that is not JSON, a reference that fails the schema, a pipe held by a grandchild (the lingering of D6), a signal to the CLI during a turn (it ends by it and the stub's pid is still alive), and an aborted prompt (`session abort` kills the child of a running `session prompt`, which ends as `exited` with `SIGKILL`; it needs `abort` and so belongs to the third pull request).
- `list`, `last`, `abort`: a pane row, a headless row without a pid, a dead pid, a pid beyond 32 bits, a `subdone` row, a broken record, a six-column row, labels from `history.tsv`, both locales, the unknown state; and for `abort` a live stub child that the verb really kills.

**The vectors** are for the pieces that exist twice and need no process, written by node's own functions. `tests/rust-session-vectors.mts` runs `buildArgs`, `childEnv`, `parseSessionRef`, `StreamReader`, `formatAttemptError`, `clipDetail` and `JSON.stringify` on corpora and writes `crates/tagents-core/tests/fixtures/session-vectors.json`: the argv and environment for specs and parents, the reference schema's accept or reject for malformed references, the events and the final reader state for lines (including the cases of D8), the printing of numbers and strings and keys (`1e21`, `-0`, `12345678901234567890`, infinity as `null`, a lone surrogate, a duplicate key, a key that is an array index, `__proto__`), `os.constants.signals`, and the decoding of invalid UTF-8. `crates/tagents-core/tests/session_vectors.rs` requires Rust to equal node on each, or to be a hand-over where D2 lists the class. A step in `.github/workflows/rust.yml` regenerates the file and runs `git diff --exit-code`, as it does for the notify and plugin vectors.

### D13. The crate question

The driver lives in `tagents-core`, not in a crate of its own. It needs `child` (the four leaf helpers), `node` (`homedir`, `interpreter`, `find_on_path`, `realpath`, the errnos), `messages`, `json`, `js`, `transcripts` and `notify::state`, all inside `tagents-core`; a new crate would have to export them, which widens the surface of one binary's internals for no second consumer, or duplicate them, which the repository forbids. `tagents-spec` stays what it is, the loader of the data file, which the two programs share. The module is `crates/tagents-core/src/session/`. If the plugin host (S4) wants the supervisor, extracting it is that change's decision, with a consumer to design for.

### D14. The pull requests

Three, in this order, each leaving a machine that runs the node CLI for every verb that is not flipped. Each raises the workspace version in `Cargo.toml` and `Cargo.lock` (`.github/scripts/core-release.sh` treats `Cargo.toml`, `Cargo.lock`, `crates/*/src/*` and `spec/cli/*` as inputs of the binary), by one past the highest version on `dev` at the time it merges, because the two other builders raise it too.

1. **Foundations and the read verbs.** The decoder fix in node with its test and spec requirement; the vectors and their test; `args.rs`; `json::parse_exact` and `stringify`; the `pid` field and the exact `mtime`; the `session` group with `open`, `list` and `last`; the parity suite and its stub with the scenarios of those verbs; their flags flipped last.
2. **`prompt`.** The supervisor, the stream reader, the argv and environment builders, the spawn errors, the events, the keep-awake hold, the signal names and the lingering; the scenarios of a turn; its flag flipped last.
3. **`abort`, the migration and the archive.** `abort` and its scenarios and flag; `plugin::parse` migrated onto `args.rs` once `rust-plugin-verbs` part b has merged; the documents; the archive, the last task.

### D15. What the implementation rebases over

Two builders work on the same files. The conflicts are in these places, and the task that touches each says what to look at after a rebase:

- `crates/tagents-core/src/front_door.rs`: `GROUPS` (this change adds a group; `rust-plugin-verbs` b edits the `plugin` entry; `rust-knowledge` b adds a `knowledge` entry), the module comment, the split of `emit`, and the constant of forwarded words in `crates/tagents-core/tests/front_door.rs`.
- `spec/cli/tagents-core.json`: the `impl` flags of the five `session` entries (rust-plugin-verbs b adds `plugin new` and `doctor` entries beside them).
- `crates/tagents-core/src/plugin.rs`: only in the last pull request, by the migration of `parse`.
- `.github/workflows/rust.yml`: both `paths:` lists and the parity and regeneration steps; the list entries are added after the last one present.
- `docs/architecture/rust-core.md`: "What is served in Rust today", "Which program a command goes to", "The parity suite", "Where the two are known to differ", "What is not decided yet", the dependency table, and the lines that name the workspace version.
- `Cargo.toml` and `Cargo.lock`: the version, raised again after each rebase.
- `CHANGELOG.md` and `LEARNING.md`: each adds lines under the same headings.
- `openspec`: this change and `rust-plugin-verbs` both restate the two `core-front-door` requirements, "The Rust binary serves the verbs the file marks rust" and "Every other word reaches the node CLI untouched" (the example of a forwarded call that stays node's is `plugin list`, because `session prompt` is served after this change). Whichever change archives second restates them from the text the first left.

## Reuse

Each new piece names the helper it builds on, found by search before the design was written. Where a helper has to widen, the widening is a task, and a parallel copy exists nowhere except the one named in D3.

| New piece | Existing code it reuses or widens |
|---|---|
| the `session` group | `Group` and `GROUPS` of `front_door.rs:33-42`, the `None` hand-over of `plugin::run` |
| best-effort writers of `prompt` | `emit` of `front_door.rs:95`, split into two |
| the hand-over to node | `exec_node` of `front_door.rs:106`, `node::interpreter` (`node.rs:298`) |
| the option grammar | the model of `plugin::parse` (`plugin.rs:92`), which migrates onto it |
| every printed line | `messages::{Locale::of, Texts::load, Texts::t}` (`messages.rs:16-41`) |
| exit codes and output | `sessions::exit` and `Output` (`sessions.rs:22-40`), widened by `TIMEOUT` |
| numbers, white space, UTF-16 cuts | `js::{number, number_text, trim, collapse_space, len16, take16, split16}` (`js.rs`), widened by the exact-string operations |
| strings and JSON text | `json::{parse, quote, quote_prefix16, unicode_escape}` (`json.rs:83-298`), widened by `parse_exact` and `stringify` |
| the other layout printer | `JsPretty` of `mcp/run.rs:135`, which stays and shares `quote` and `number_text` |
| state records | `notify::state::{state_dir, read_agent_state, labels_by_session}` (`state.rs:56-135`), widened by `pid` |
| the transcript's last text | `transcripts::last_assistant_text` (`transcripts.rs:167`), widened by a parser parameter |
| paths and node's errors | `node::{homedir, resolve, realpath, find_on_path, errno, io_message}` and the modification time (`node.rs`) |
| the supervisor's leaves | `child::{wait_for_exit, duplicate, readable, spawn_thread, Stream}` (`child.rs:163-290`), made `pub(crate)` |
| liveness of a pid | `is_alive` of `notify/lock.rs:117` |
| the stub `claude` | `fakeClaude` of `packages/core/src/testkit.ts:186`, widened by four options |
| the parity suite | the harness of `tests/rust-plugin-parity.sh` and `tests/rust-notify-parity.sh` |
| the vectors | the shape of `tests/rust-plugin-vectors.mts` and its test |

## Risks / Trade-offs

- **After the spawn there is no way back.** Everything that decides the bytes of a turn is pinned by vectors and by scenarios, and the one class that cannot be matched is listed (a key with a lone surrogate).
- **Node's own nondeterminism.** The chunk decoding is fixed in node first. Two other timings differ from node by design and are listed under "Where the two are known to differ": the awake stall of more than 20 s that node discounts, and a line in the pipe at the drain that node's loop can lose and the supervisor takes.
- **The clock.** `Instant` is `CLOCK_UPTIME_RAW` on macOS (read in std's source) and `CLOCK_MONOTONIC` on Linux (documented, not run here).
- **The spawn lookup.** std's `execvp` and libuv's walk of `PATH` can differ on a non-executable file or a directory named `claude`, and on a file with no `#!` (glibc's `execvp` runs it with `/bin/sh`; node reports `ENOEXEC`). The scenarios of D12 find it, and the answer is a hand-over class, not a second walk.
- **Signal names.** The table is per platform and covers what `os.constants.signals` lists on the host; the two targets that are not the host are covered by the unit test that the table's numbers equal `libc`'s on that target, not by a run.
- **Lossy decoding.** Node's `StringDecoder`, `Buffer.toString()` and Rust's `String::from_utf8_lossy` gave the same code points for 11 sequences tried here (a truncated two-, three- and four-byte sequence, `C0 80`, `ED A0 80`, a value beyond U+10FFFF, a stray continuation byte, a valid character followed by a truncated one), and the vector corpus of invalid sequences is what proves the rest. A difference found there cannot be a hand-over, because the stream is read after the spawn, so the Rust decoder would be written to node's rule instead.
- **A process that stops reading.** A reader thread that blocks on a full channel would stall a pipe; the channel is unbounded, and the memory of a turn is bounded the way node's is (stderr and the text are kept whole, tool results are not).
- **Pid reuse in `abort`.** A pid that was alive when read can be another process when the signal arrives. It is node's window; the record carries no start time to check it against.
- **The two readers of options.** `args.rs` and `plugin::parse` exist side by side until the last pull request, pinned against each other by a test.
- **A concurrent version bump.** The three pull requests and the two other builders all raise the workspace version; each rebase raises it again, and `core-release.sh` fails a pull request that does not.
- **node must be found.** With no node, `session` hands over, and the fallback fails the same way. This is the state of every verb that is not Rust until S5.
