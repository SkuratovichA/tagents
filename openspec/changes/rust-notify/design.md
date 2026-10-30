## Context

The notification service is one node process per machine, `node packages/notify/dist/main.js run`, started by a LaunchAgent and alive for days. It follows the events file the hooks append to (`<state dir>/events.tsv`), decides which events deserve a notice, keeps one prompt-cache deadline per idle session, runs a helper app once per notice, and re-reads its options when the file changes. On 30.10.2026 it held 31 MB by `footprint` (peak 40 MB) after two days and four hours. The code that does this is about 2,000 lines of TypeScript, split between `packages/notify/src` (`engine.ts`, `service.ts`, `deadlines.ts`, `compose.ts`, `kinds.ts`, `screen.ts`, `options.ts`, `phrases.ts`, `exec.ts`, the helper and log notifiers) and `packages/core/src` (`agent-events.ts`, `agent-state.ts`, `plugin-options.ts`, `zod-issues.ts`), with about 4,300 lines of tests.

After `rust-mcp` the crate has what a long-lived server needs first: a front door that forwards every word it does not serve to the node CLI, a call that runs a program in a process group with a deadline and a cap on its output (`mcp/run.rs`), a cancellation token and an ending on SIGTERM, SIGINT and SIGHUP through `signal-hook` (`mcp/server.rs`, `mcp/mod.rs`), `rustix` for signals and `poll`, and the helpers that repeat node's behaviour (`transcripts.rs` `last_assistant_text`, `node.rs`, `date.rs`, `js.rs`). It has no TOML reader, no file watch, no code for the state rows, event lines, labels and history the daemon reads, and no engine.

This change makes the daemon a verb of the binary that already ships, keeps the node daemon as the fallback and as the oracle the new one is tested against, and leaves a watch and a child-with-input module for the next port (the knowledge server). It follows `rust-mcp` in form and in how a machine switches: through the installer's wrapper, only when a binary of the checkout's version is installed.

## Goals / Non-Goals

**Goals:**

- On a machine with the prebuilt binary, the LaunchAgent starts `tagents-core notify run`, and nothing the person sees changes: the same notices for the same events, the same log lines, the same exit codes, the same lock, the same files left behind, the same reaction to a bad options file.
- On a machine without the binary, or with one of another version, nothing changes.
- Nothing polls, and a node daemon and a Rust daemon on one state directory exclude each other.
- The two daemons cannot drift unnoticed: one suite starts both on the same state, feeds them the same events and compares what they post, log and leave behind, and the helpers that exist twice are pinned by vectors that node generates.
- The watch, the child with input and a deadline, and the signal ending are modules the next port reuses, not code of this daemon.

**Non-Goals:**

- Retiring `packages/notify`, changing what a notice says or when one is posted, or changing the options.
- The verbs `install`, `uninstall`, `status`, `test` and `send`, the Swift helper, `launchctl`, and a notification backend for Linux.
- A YAML reader, a Windows build, an async runtime, the `notify` crate.
- Cutting a release: the tag needs Sasha's word, and until it exists the installer keeps node for the version this ships in.
- Restarting the running service when a binary is installed: `launchctl` is not in `install.sh`.

## Decisions

### One binary, one more verb: `tagents-core notify run`

Decision: the daemon is the verb `["notify", "run"]` of `spec/cli/tagents-core.json` with `impl: rust` and `effect: serve`, so it is not a tool (`isTool`) and the generated contract and references gain one entry. Its summary goes in `packages/core/src/i18n/{en,ru}.ts`. `front_door.rs` serves exactly the arguments `notify run`: any other argument list that starts with `notify` (`notify install`, `notify status`, `notify run extra`) is forwarded to the node CLI, which hands it to the plugin host, as every unserved word is today. `served_spec` lists the verb because `STREAMING` holds it.

Reason: the binary is built, checksummed, released and installed already, and `mcp` is the precedent for a verb that owns stdin, stdout and the process until it ends. The data file's rule that a first word is served by one program holds, because the word `notify` has no `impl: node` entry in it: the plugin's other verbs are the host's, not the data file's (`packages/core/test/cli-spec.test.ts`, "a verb word is served by one program").

What `tagents notify run` does through the node plugin host: it runs the node daemon, as today, because the `tagents` command is the node CLI and no wrapper routes it to the binary. Two implementations stay reachable, and one of them is the reference: `packages/notify` is to `tagents-core notify run` what `packages/mcp` is to `tagents-core mcp`, the oracle that `tests/rust-notify-parity.sh` runs the port against, and the fallback a machine without the binary runs. That is not a second implementation in the repository's sense because a suite that fails on any difference stands between the two, and the wrapper, not a person, chooses.

Rejected: a second binary `tagents-notify` in Rust (a new archive member, `release.yml`, the installer's member check and `tests/release.sh` for one more executable of the same kind); the verb as the top-level word `notify-run` (a first word of its own for what is one verb of the plugin's group).

```rust
// front_door.rs: run()
match args.iter().map(|a| a.to_str()).collect::<Vec<_>>().as_slice() {
    [Some("mcp"), ..] => mcp::run(&args[1..]),
    [Some("notify"), Some("run")] => notify::run(),     // blocks until a signal or a deliberate exit
    _ => /* the group lookup, else forward() */,
}
```

### The wrapper chooses, and launchd names the wrapper

Decision: launchd runs `~/.local/bin/tagents-notify run` when that wrapper is there, and the wrapper decides between the binary and node. Three edits make it so. `install.sh`: `write_wrapper` takes a sixth parameter, the one argument list the native binary is for, and the `tagents-notify` entry of `install_commands` names the binary of `tagents-core` with the word `notify` for the argument list `run` and nothing else, under the same `--version` check that `tagents-mcp` has, so a binary that predates the verb is never named. `runSpecFor` in `packages/notify/src/plugin.ts` writes `[<wrapper>, 'run']` into the plist when `findOnPath('tagents-notify', env.PATH)` names a file whose text holds this checkout's `dist/main.js` (`MAIN_JS` in `paths.ts`), and today's `[process.execPath, <dist/main.js>, 'run']` otherwise. The contract entry above is the third.

```sh
# the tagents-notify wrapper with a binary installed: the line of the tagents-mcp wrapper with one more test, so only the argument list `run` goes to the binary
r="$TAGENTS_HOME/target/release/tagents-core"
[ ! -f "$r" ] || [ ! -x "$r" ] || [ "$#" -ne 1 ] || [ "$1" != run ] || { TAGENTS_NODE="$n"; export TAGENTS_NODE; exec "$r" notify "$@"; }
exec "$n" "$TAGENTS_HOME/packages/notify/dist/main.js" "$@"
```

```ts
// runSpecFor: the program the plist names
const wrapper = findOnPath('tagents-notify', env['PATH']);
const viaWrapper = wrapper !== null && fs.readFileSync(wrapper, 'utf8').includes(mainJs);
return viaWrapper ? { program: wrapper, args: ['run'] } : { program: process.execPath, args: [mainJs, 'run'] };
```

Reason: the daily update removes the binary of a version that has no release, and the wrapper is rewritten on every update, so a plist that named the binary would be left pointing at nothing and `KeepAlive` would restart it every 300 seconds for good, while a plist that names the wrapper falls through to node at the next start. The wrapper `exec`s, so the process launchd supervises is the daemon and keeps its pid: `status` reads the lock file, `events.on`, `launchctl print` and `ps` by pid and never the program's name, so it works for either. A wrapper of another checkout is not used because its `dist/main.js` is not this checkout's. Every other verb of `tagents-notify` reaches node, so `install`, `uninstall`, `status`, `test` and `send` are untouched.

Rejected: the plist naming `tagents-core notify run` (the crash loop above); a node `run` that execs the binary (the node process the change exists to remove would stay, and the execed one would not be the program of the plist); a second LaunchAgent label (two services, two locks and a migration of the person's allow-listing in System Settings).

Nothing restarts the running service when a binary is installed. A running node daemon stays node until `tagents notify install` (which boots the agent out and in) or the next login; the migration plan says so.

### The options file: the `toml` crate, and a validator that writes zod's lines

Decision: `notify.toml` is read by the `toml` crate (`default-features = false`, features `std`, `parse`, `preserve_order`; the dependency PR keeps the smallest set that builds), and a hand-written validator in `notify/options.rs` checks the table against the one schema of `packages/notify/src/options.ts` and writes the problem lines the node daemon writes, byte for byte. `preserve_order` is needed because the lines depend on the order of the keys in the file. The workspace's rule "no other parser is in the tree" (the comment above `[workspace.dependencies]` in `Cargo.toml` and `docs/architecture/rust-core.md`, the line "The only dependencies are `serde` and `serde_json`") is widened to name `toml`, with its reason: the options file is TOML and the daemon has to read it.

The problem lines come from `issueLines` (`packages/core/src/zod-issues.ts`): `<path>: <message>` for each issue in zod 4.6.2's order, or the bare message when the path is empty. Every message the schema can produce, with what produces it (checked by running zod 4.6.2 and `smol-toml` 1.9.1 on the cases below, 30.10.2026):

| When | The line |
|---|---|
| an unknown key at the top | `Unrecognized key: "<key>"`, with two or more `Unrecognized keys: "<a>", "<b>"` |
| an unknown key in `events`, `events.<kind>` | the same, after `events: ` or `events.<kind>: ` |
| `backend` or `click` not in its list, whatever its type | `backend: Invalid option: expected one of "auto"\|"macos"\|"log"\|"none"`, `click: Invalid option: expected one of "dock"\|"goto"\|"focus"` |
| `icon` is the empty string | `icon: Too small: expected string to have >=1 characters` |
| a value of the wrong type for a string, a boolean or a table | `<path>: Invalid input: expected <string, boolean or object>, received <type>` |
| a duration that the grammar refuses | `<path>: not a duration: <the value as JSON.stringify writes it> (use 90, 45s, 50m, 2h or 1h30m)` |
| a duration that is neither a string nor a number | `<path>: Invalid input` |
| `after` is not below `ttl` and both are well formed | `events.cache_expiring.after: after must be below ttl: a notice about a cache that already expired helps nobody` |
| a file that is not TOML | `<file>: Invalid TOML document: <reason>` (see the known differences) |

`<type>` is `string`, `number`, `boolean`, `array`, `object`, `TomlDate` (any TOML date or time), `NaN`, `Infinity` or `-Infinity`. A duration is a string or a number, so a boolean, an array, a table, a date and a non-finite float fall to the bare `Invalid input` of the union. The unknown keys are written raw (a quote inside a key is not escaped) in JavaScript's property order: keys that are canonical array indexes, in ascending order, then the rest in file order. The issues of an object come in the order of its shape (`backend`, `click`, `icon`, `events` with `question`, `permission`, `turn_done`, `cache_expiring` with `enabled`, `skip_visible`, `after`, `ttl`, `session_end`), each key's issues being its value's, then the object's unknown-keys issue, then its refine: a type problem anywhere inside `cache_expiring` stops the `after`/`ttl` check, and an unknown key does not. A date or time where a table is expected is read as an empty table, as zod does. A duration is read by `parseDuration`: a number or a string of ASCII digits is seconds, a safe non-negative integer; otherwise `^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$` with ASCII digits only, the empty string refused, the sum a safe integer; a float that is whole (`1.0e1`) is a number like any other, and the value in the message is written by `js::number_text`, so `5e-1` reads `0.5`.

```rust
// notify/options.rs
pub fn load(config_dir: &Path) -> Loaded;   // Loaded::{Found(Options), Missing(Options), Invalid(Vec<String>), HandOver}
fn check(root: &toml::Table, issues: &mut Vec<String>) -> Options;
```

Reason: `serde` with `deny_unknown_fields` writes serde's texts in serde's order, and a schema crate for one fixed schema is a dependency for forty lines. The vectors fixture (`tests/rust-notify-vectors.mts`) holds about a hundred documents, every row of the table, pairs of problems and the cases above, each with the lines node writes, and the differential suite feeds the same files to both daemons.

Rejected: a derive on the options struct (the texts, the order and the date rule are all different); copying only the custom messages (the unknown-key, type and enum lines are what a person sees first).

### A YAML-only options file and a failed start hand over to node, at start

Decision: the Rust daemon reads no YAML, and it hands over to the node daemon only at start, for one of two reasons: `<configDir>/plugins/notify.toml` is not a regular file and `notify.yaml` is (the rule of `pluginOptionsFile` in `packages/core/src/plugin-options.ts`), or a step of the start before the `started` line fails. `hand_over` lives in a module of its own, `notify/hand_over.rs`, because the options arm and the failed start both call it. It first looks at whether a stop was requested: if one was, the process ends as a stop ends it and nothing is exec'd. Otherwise it logs `options: <file> is YAML; handing over to the node service` (or the reason of the failed step), closes what the follower and the watches hold, removes `events.on`, keeps `notify.lock` held, and replaces its process with `node <root>/packages/notify/dist/main.js run` with the environment it had. The lock is kept across the exec because the exec keeps the pid and `holds` (`packages/notify/src/service.ts:164-171`) treats a lock held by its own pid as not held, so the node daemon takes it over with no window in which a manual `run` could take it and the exec'd daemon exit with `another notify service holds`. The lock is released only on the exit paths: a stop, a deliberate exit, a failure that is not handed over, and an `exec` that fails (the line says so and the exit code is 1).

The steps before `started` (`service.ts:378`), in node's order: create the state directory, take the lock (a held lock is the deliberate exit 0 and not a failure), read the options, pick the backend (`none` and a system without a backend are deliberate exits), start the follower (open or create `events.tsv`, arm its watch, create `events.on`) and arm the engine from the state rows. A failure of any of them hands over: the node daemon then either runs or fails by its own rules and its own `the notify service stopped:` line, and launchd does not restart a defect of the new code every 300 seconds. The options-directory watch is not one of them: a watch that cannot be armed logs `options watch failed <dir> <why>` and the service runs without a reload, as node does (`service.ts:233-247`). A failure after `started` is not handed over.

At a reload that finds the options YAML only, the daemon keeps the values in force, logs one line `options: <file> is YAML; a restart hands it to the node service` for as long as the file stays the only one, and goes on; a restart hands it over at start. This is a listed known difference. Reason: an exec at a reload drops the events queued in the engine, the follower of the new process starts at the end of the file (`packages/core/src/agent-events.ts:261`) so every event written before it is armed is lost, and `warnedAt` of the engine (`packages/notify/src/engine.ts:365` and `:385`) starts empty, so a cache notice could be sent a second time.

The finding that makes hand-over the choice for YAML on `main` without pull request #37: YAML options are not deprecated there. `formatNotice` in `packages/core/src/config-file.ts` deprecates the YAML format for the main config only, `loadPluginOptions` does not call it, `packages/core/src/plugin-options.ts` says in its header that `tagents config convert` is for the config and that an options file is translated by hand, and `["config", "convert"]` in `spec/cli/tagents-core.json` converts the config. So treating `notify.yaml` as an invalid file would turn a supported file into a silent fall to the defaults, a behaviour change nobody asked for. Pull request #37 (open, not part of this change) reads `<name>.toml` only and ignores YAML, changing `packages/core/src/plugin-options.ts`, `packages/notify/src/options.ts` and `packages/notify/src/service.ts`; when it merges first the finding no longer holds, and the YAML trigger is one arm (`Loaded::HandOver`) and one requirement ("A YAML-only options file is run by the node service" in `specs/rust-notify/spec.md`) with one test, so dropping it is removing those. The requirements about the options file that name `notify.yaml` in `openspec/specs/notify` are written as MODIFIED deltas (`specs/notify/spec.md`) that name only `notify.toml`, which is true whichever of the two changes merges first.

Reason: of the three ways to keep a YAML file working this is the least machinery: a function that finds the node program next to the binary and `exec`s it (the generalisation of `node_cli` in `front_door.rs` to `exec_node(relative, args)`, which finds the program with `node_program(relative)`; the node CLI is its first caller) and a four-way `match` on what `notify.toml` and `notify.yaml` are. The person's file keeps meaning what it meant, at the price of the node process for those people, who are few.

Rejected: a YAML dependency (`serde_yaml` is archived, the maintained forks differ from `yaml` 2.9.0 in what they accept and in every error text, and the problem lines could not be equal); the wrapper choosing node when the options are YAML (it would read the options file in `sh`, a third copy of `pluginOptionsFile`); the invalid-file rule above (the behaviour change); an exec at a reload (the queue and `warnedAt` above).

```rust
// notify/options.rs
enum Source { Toml(PathBuf), Yaml(PathBuf), Neither(PathBuf) }   // pluginOptionsFile: a directory is not a file
// Loaded::{Found(Options), Missing(Options), Invalid(Vec<String>), HandOver(PathBuf)}: HandOver at start is hand_over, at a reload one log line
// notify/hand_over.rs
pub fn hand_over(why: &str, stop: &Stop, lock: Lock) -> !;   // stop requested: end as a stop ends; else log, close, keep the lock, front_door::exec_node(NODE_NOTIFY, &["run"]); exec failed: release, log, exit 1
```

### The child with input and a deadline, and the ending, are lifted out of `mcp`

Decision: the program-with-a-deadline code of `mcp/run.rs` moves to `child.rs`, and the cancellation token and the signal thread of `mcp/server.rs` and `mcp/mod.rs` move to `ending.rs`. `mcp` calls them and nothing about what `mcp` does changes: the same constants, the same tests, the same `tests/rust-mcp-parity.sh` result. What moves: `Capture`, `read_stream`, `complete_end`, `spawn_thread`, `launch`, `wait_for_exit` (`waitid` with `NOWAIT`), `supervise`, `signal_group`, `group_of`, `duplicate`, `readable` and the `Event`, `Stream` and `Reason` types to `child.rs`; `Stop` to `ending.rs`, next to `on_signals(f)`, the thread that registers SIGTERM, SIGINT and SIGHUP with `signal-hook`, calls `f` once and ignores later signals. What stays in `mcp/run.rs`: `call_tool`, `Runner`, the JSON body of a result, the outcome names.

```rust
// child.rs
pub struct Policy {
    pub input: Option<Vec<u8>>,            // written to the child's stdin, which is then closed
    pub timeout: Duration,
    pub kill_grace: Option<Duration>,      // Some: SIGTERM at the timeout, SIGKILL after the grace (mcp); None: SIGKILL at the timeout (notify)
    pub drain: Duration,
    pub cap: usize,                        // bytes kept per stream, cut at a character
}
pub struct Finished { pub code: Option<i32>, pub stdout: String, pub stderr: String, pub stdout_cut: bool, pub stderr_cut: bool, pub reason: Option<Reason> }
pub fn run(command: Command, policy: &Policy, stop: &Stop) -> Result<Finished, io::Error>;   // Err: the program could not be started

// ending.rs
pub fn on_signals(f: impl FnOnce() + Send + 'static) -> io::Result<()>;
```

The notify calls are four: the helper's `post` and `withdraw` (stdin the notice JSON for `post`, five seconds, SIGKILL at the deadline, as `execText` in `packages/notify/src/exec.ts`), the tmux probe (two seconds), and `/bin/ps -o lstart= -p <pid>` for the lock (two seconds, with `LC_ALL=C TZ=UTC` as the whole environment). None passes a stop that trips: the node daemon lets the post in flight finish when it stops, so the Rust one does too, and the end of a daemon is bounded by the helper's five seconds. The notify calls use the process group as `mcp` does, so a SIGKILL at the deadline reaches a helper's own children, which `execFile` does not do (a known difference).

Reason: the repository's rule is one pattern per problem, and spawn-and-kill with a drain and a cap is the problem `mcp/run.rs` already solved, including the cases that took rounds of review there (the group, the holder outside it, the zombie, output left in a pipe at the exit). A copy for notify would have to be fixed twice.

Rejected: calling `mcp::run::call_tool` (it takes a contract tool and writes the MCP result body); a second spawn function in `notify` (the duplication above); `std::process::Child::wait_with_output` (no deadline, no group, no drain).

### The watch is one module over inotify and kqueue, and it never follows a symlink

Decision: `watch/` is a small module with two functions behind one type, `Watch::start(sink)`, `watch.dir(path, key)` and `watch.file(path, key)`, and a thread of its own that blocks until something happens and sends `key` to the sink, which is a channel of the engine. Linux is `rustix::fs::inotify` and `rustix::event::poll` (features `fs`, `event`). macOS is the `kqueue` crate (`Watcher::add_file`, `add_fd`, `remove_file`, `watch`, `poll_forever`, `poll`; `add_filename` opens the path itself and follows a symlink, so the file is opened here with `O_NOFOLLOW` and handed to `add_file`), because `rustix` declares `kevent` unsafe and the workspace forbids `unsafe` (the crate's own call sites are safe). A pipe whose read end is in the poll set or the kqueue wakes the thread when the engine adds or drops a watch (`pipe` feature of `rustix`).

What is watched, and why it is two things on macOS. A kqueue vnode watch on a directory fires when an entry is added, removed or renamed and not when a file in it is written, whereas node's `fs.watch(dir)` is backed by FSEvents on macOS and sees a write too (libuv uses FSEvents for directories and kqueue for files). So the options file is watched as a directory (the entry changes: an editor that saves through a rename, `ln -sf`, the first creation) and as a file opened with `O_NOFOLLOW` (an edit in place). The pinned behaviour of `packages/notify/test/service.test.ts` ("a symlinked notify.toml is noticed when the link is replaced, not when its target is edited") holds because a symlink is not opened: on macOS `O_NOFOLLOW` fails with `ELOOP`, and on Linux the path is looked at with `symlink_metadata` first, because inotify takes a path and `IN_DONT_FOLLOW` would put the watch on the link itself; either way there is no file watch for a link, and the directory watch sees the link replaced and never sees a write to a target in another directory. On Linux the directory watch of inotify reports a write to a file in it. A file watch sits on an inode, so a save through a rename leaves it on a file that is gone: the thread opens the path again, before it reports the key, whenever the directory reports anything and whenever the file's own watch reports a delete, a rename or a revoke. The options directory is `realpath(<configDir>/plugins)`, because `~/.config/tagents` is usually a symlink into a dotfiles repository and a watch on the link sees nothing; with no `plugins` directory the real config directory is watched for the name `plugins`, and when it appears the watch moves to it and the file is read once more; with no config directory the line `options reload is off: <dir> does not exist` is logged and the service runs on (`watchDir` and `adopt` in `packages/notify/src/service.ts`). A directory event carries no name on kqueue, so any event on the directory reloads, which is safe because a reload of an unchanged or equally invalid file logs nothing.

The events file is watched as a file. The follower is `followAgentEvents` (`packages/core/src/agent-events.ts`) ported function by function: it opens `events.tsv` (creating the directory and the file, mode 0600) and starts at the current end, reads to the end in 64 KiB chunks on every wake, keeps the bytes of a partial line, drops a line of fewer than 13 fields, or whose time is not a number or whose event is not one the hook writes, tolerating a trailing `\r` and ignoring fields beyond the 13th as `parseEventLine` does (`packages/core/src/agent-events.ts:91-97`, `openspec/specs/event-stream/spec.md:153`), restarts at 0 when the file is shorter than the offset, reopens from 0 when the path names another inode, and rotates at 1 MiB (rename to `events.tsv.1`, a fresh file, the old one kept open for 2 seconds to be read to its end). `events.on` is created with the first follower and removed with the last; the daemon has one. A dead follower is followed again after 1 second, doubling to 5 minutes, back to 1 second when the dead one heard an event or lived longer than the wait that preceded it (`REFOLLOW_MIN_MS`, `REFOLLOW_MAX_MS` in `packages/notify/src/engine.ts`).

The lost wake: an edge-triggered watch raises nothing for a write that lands between the last read and the arming. Every arming is therefore followed by a read to the end, and every wake by a read to the end; `agent-events.ts` documents the same race for libuv. The options watchers do the same (`apply(load())` right after arming, as `service.ts` does).

Reason: no Rust code in the tree watches a file, `std` has no API for it, and the spec says the service polls nothing. A polling fallback would be a second mechanism with its own timing, and the `notify` crate would bring its own thread, its FSEvents backend (which follows symlinks differently) and a larger tree.

Rejected: the `notify` crate (above); `rustix` for kqueue (`kevent` is unsafe to call, so every call site would need `unsafe`); `FSEvents` through a binding (a run loop and a C framework for a daemon that has one directory to watch); watching the resolved file (it fails the pinned symlink test).

```rust
// watch/mod.rs
pub enum Key { Events, Options }
pub struct Watch { /* thread, wake pipe, command channel */ }
impl Watch {
    pub fn start<T: From<Key> + Send + 'static>(sink: mpsc::Sender<T>) -> io::Result<Watch>;
    pub fn dir(&self, path: &Path, key: Key) -> io::Result<()>;
    pub fn file(&self, path: &Path, key: Key) -> io::Result<()>;   // a symlink is Ok(()) and no watch (macOS: O_NOFOLLOW and ELOOP; Linux: symlink_metadata and IN_DONT_FOLLOW)
}
```

### One engine thread, wall-clock deadlines, and what the log says

Decision: three threads and no runtime. The main thread is the engine: it owns the follower, the options, the deadlines and the notifier, and loops on `Receiver::recv_timeout` for a message (`Wake(Events)`, `Wake(Options)`, `Stop`) or for the next due time, whichever comes first, so events and due deadlines run one at a time as the promise chain of `engine.ts` runs them, and a post that takes five seconds holds the loop for five seconds while the other two threads keep queueing. The order is node's: one FIFO queue of jobs, and at each wake the follower's lines are ingested (each becomes a job at the back of the queue) and the deadlines swept (each due key becomes a job behind them) before the first due job runs, as `engine.ts:399-408` sweeps at every event, behind the event in the chain, "so a prompt that cancels a key is seen first". A prompt that arrives while a post is in flight therefore cancels the cache notice of its session before that notice's job runs, where a loop that ingested one line, ran its due jobs and then read the next would send it. The watch thread sends wakes. The signal thread (`ending::on_signals`) logs `stopping (<signal name>)` and then trips the stop, and it is started before anything else so that a signal during start is acted on once start settles. The line is written from the signal thread before the stop is tripped, so it precedes the `notice` line of a post in flight, as node writes it synchronously in its signal handler before it closes the watchers and lets the post finish (`service.ts:388-400`); an engine thread blocked in a post could not write it first. The deadline scheduler (`deadlines.ts`) is a map and a minimum: the next wake is the earliest due time read from the wall clock (`SystemTime`), capped at five minutes, and re-read on every wake. A monotonic clock stops during sleep on macOS, so a Mac that slept through a deadline wakes within one cap of it, as node's timer does. What the service holds when idle: three threads (the engine, the watch, the signals), plus the reader threads and the writer of a child call only while one runs (`child.rs`); no timer object, because the engine's one timed wait ends at the earliest of the cache deadline, the re-follow time (only while the follower is dead) and the end of the 2 second grace of a rotated events file; and the watch's descriptors, which are the inotify descriptor and the two of the wake pipe on Linux, and the kqueue descriptor, the two of the wake pipe and one open descriptor for each of the events file, the options directory and the options file (when it is a regular file) on macOS. The requirement "Resource use" of `notify-service` is modified to say so.

The log is the node daemon's: `<ISO time with milliseconds> <parts joined by a space>` on stderr (`date::iso`), and nothing on stdout. The vocabulary is the list of the requirement "The log is the node service's" (`specs/rust-notify/spec.md`, built on "The log lines of the service" of `notify-service`), which enumerates every line `service.ts`, `engine.ts`, the log backend and the `the notify service stopped:` line of `plugin.ts` write; the two hand-over lines are the only addition. The operating system's text inside a line (a failed lock release, a failed watch, a failed post, a feed error) is written by `node::io_message` (`crates/tagents-core/src/node.rs:69`) from the error and the syscall, and a text it cannot reproduce for an error number that differs between the two systems is a known difference below. `boot_ms`, for judging a lock that has no recorded start, is `now - uptime` read once at start (`/proc/uptime` on Linux, `sysctl -n kern.boottime` through `child::run` on macOS, zero when neither can tell, which counts every lock file as written after boot). `os` in `no notification backend for <os> yet` is node's name: `darwin` for macOS, `win32` for Windows, `std::env::consts::OS` otherwise. The host name is `rustix::system::uname().nodename()`.

Reason: the engine is a sequence by design, so one thread removes every question about two events touching one state, and the three threads only move wakes. Rejected: a thread per child (the child module has its own); `EVFILT_SIGNAL` in the watch (`signal-hook` is already the signal mechanism of the crate).

### What is ported and how each copy is pinned

Every helper the daemon uses that has no twin in the crate is ported once, and the node copy stays. The pin is a vector file that node generates (`tests/rust-notify-vectors.mts` writes `crates/tagents-core/tests/fixtures/notify-vectors.json` by calling the real functions; `rust.yml` regenerates it and runs `git diff --exit-code`) and that a Rust test reads and checks case by case. A node change that moves an output fails the Rust test; a Rust change that moves one fails the same test.

| Helper | Node copy | Rust home | Pinned by |
|---|---|---|---|
| options schema, durations, problem lines | `options.ts`, `plugin-options.ts`, `zod-issues.ts` | `notify/options.rs` | vectors (documents to lines), differential suite with the same bad files |
| state rows, history, labels | `agent-state.ts` (`readAgentState`, `labelsBySession`, `readLabels`) | `notify/state.rs` | vectors (files to rows) |
| event lines and the follower | `agent-events.ts` (`parseEventLine`, `followAgentEvents`) | `notify/events.rs` | vectors for lines (a line of 14 fields and a line ending in `\r` among them); the 40 cases of `agent-events.test.ts` ported; differential suite |
| verdicts | `kinds.ts` (`classify`, `countsSession`) | `notify/kinds.rs` | vectors (events to verdicts) |
| title, subtitle, body, `untitle`, `agentName`, clip | `compose.ts` | `notify/compose.rs` | vectors; `untitle` also against `untitle_of` in `lib/tagents/names.sh`, which a Rust test runs over the vector inputs as `compose.test.ts` does; `Path::file_name` and `str::trim` are not used (see below) |
| phrases (`en`, `ru`) and `cacheBody` | `phrases.ts` | `notify/phrases.rs` | vectors (locale and arguments to text) |
| the tmux probe parse | `screen.ts` (`parseScreen`) | `notify/screen.rs` | vectors (tmux output to screen) |
| deadlines | `deadlines.ts` | `notify/deadlines.rs` | the 14 cases of `deadlines.test.ts` ported over a fake clock |
| the engine | `engine.ts` | `notify/engine.rs` | the 85 cases of `engine.test.ts` ported over fakes (feed, notifier, clock, screen) |
| the lock | `service.ts` (`takeLock`, `holds`, `sweepTempLocks`, `releaseLock`) | `notify/lock.rs` | the cases of `service.test.ts` for the lock ported; one node and one Rust daemon on one state directory in the suite |
| the helper call and its error texts | `platform/macos/helper.ts` | `notify/helper.rs` | the 9 cases of `helper.test.ts` ported; the suite with a stub helper |
| the `log` and `unsupported` backends | `platform/log.ts`, `platform/unsupported.ts` | `notify/platform.rs` | the cases of `log-notifier.test.ts` ported; the suite |

Reused as they are, with nothing written beside them: `node::basename` (`node.rs:21`) for `path.basename` of `compose.ts:55` and `:133` (`std::path::Path::file_name` is `None` for `/`, for the empty path and for a path that ends in `..`, where `path.basename` gives `''`, `''` and `'..'`, checked by running both on 30.10.2026), `js::number` (`js.rs:112`) for `Number(rawAt)` of `agent-events.ts:95`, `js::trim` for the `trim` calls of `compose.ts:77-78` and `service.ts:73` and `:123` (`str::trim` leaves U+FEFF, which `String.prototype.trim` removes), `node::join` for `path.join`, `node::io_message` for the texts of a failed syscall, `transcripts::last_assistant_text` for a `turn_done` body without event text (an error is the empty body, as `compose.ts` makes it), `node::homedir` and `node::mtime_ms` (the lock's age), `date::iso`, `js::trim` (the blank test of `TAGENTS_CONFIG_DIR` and `XDG_CONFIG_HOME` in `configDir` of `packages/core/src/host.ts`), `js::number_text` (a number in a duration message), `js::round` (`Math.round` for the minutes of a cache notice) and the code-point counts of `compose.ts`, which are `str::chars().count()` on a `String` and equal to `[...s].length` on well-formed text. The std functions `Path::file_name` and `str::trim` (and `trim_start`, `trim_end`) must not be used for these: `str::trim` leaves U+FEFF where `trim` removes it, and `file_name` is `None` for `/`, the empty path and a path ending in `..` where `basename` has a string, and a vector with each of those inputs pins it.

The cases of `service.test.ts` that drive a real watch and the cases of `main.test.ts` (a real process, SIGTERM, a held lock, backend none, invalid options) become scenarios of the differential suite instead of Rust copies: a real process is what they test.

### The node daemon is the oracle: a differential suite

Decision: `tests/rust-notify-parity.sh` and its driver start the node daemon (`node packages/notify/dist/main.js run`) and the Rust daemon (`target/debug/tagents-core notify run`, or `$TAGENTS_CORE_BIN`) one after the other on identical scratch state and compare what they leave. The scratch has its own `HOME`, `TA_STATE_DIR`, `TAGENTS_CONFIG_DIR`, `TAGENTS_LOCALE`, `TMUX_TMPDIR`, a `PATH` of a `tmux` shim followed by `/usr/bin:/bin`, and `TA_NOTIFY_APP` pointing at a stub helper (a POSIX script at `<app>/Contents/MacOS/tagents-notify` that records its arguments and stdin and answers one JSON line). The driver waits for the `started` line, appends events to `events.tsv`, writes state rows, labels, history and a transcript, waits for the posts it expects, sends SIGTERM and prints the transcript. The script compares the two after replacing the timestamp and the pid. Short `after` and `ttl` (`1s`, `3s`) make a deadline fall due in seconds.

What the scenarios cover: every row of the verdict table; the question-then-permission window; kinds switched off; `skip_visible` with a tmux shim that shows the pane, hides it, fails, times out and says there is no such pane; a notice that is replaced and one that is withdrawn; the cache deadline, armed from an event and from state rows at start; the transcript body; both locales; a stub helper that answers `shown: false`, fails, prints garbage, exits slowly past five seconds and is not there (macOS only, because `pickPlatform` returns the helper only on darwin: the suite prints how many scenarios it skipped, and the macOS job of CI runs them); the `log` backend on both systems; each document of the bad-options set, at start and as a reload, with the line of each and `options reloaded`; a symlinked options file whose link is replaced (the edited target is #39, below); a late `plugins` directory; a missing config directory; the lock (a second daemon of the other kind exits 0 with its line; a stale lock, a lock of a reused pid and a lock with a bare pid are taken); backend `none`; a start that cannot take the state directory; SIGTERM, SIGINT and SIGHUP with a post in flight, with the exit code, the lock and `events.on` left behind; rotation at 1 MiB; a truncated and a replaced events file; two thousand events in a tight loop with none lost.

The case of a symlink whose target is edited is not compared until issue #39 is settled: the node daemon's own test of the rule (`packages/notify/test/service.test.ts:452`) sometimes sees a reload after the target is edited on macOS (https://github.com/SkuratovichA/tagents/issues/39), so a comparison would fail on node's side at random. The Rust daemon pins the case with its own test of the watch (`a_symlink_has_no_file_watch_so_its_target_edited_is_not_heard_and_the_link_replaced_is`, task 2.3), and the scenario "a symlinked options file edited and replaced" above compares the replaced link only.

Tripwires assert on the node transcript alone, so a scenario that stopped provoking what it exists for fails instead of passing for nothing. `PARITY_ONLY=<text>` runs the scenarios whose label holds the text. The mutation list is in `tasks.md`.

Reason: the node daemon is the specification of the behaviour and it is in the same checkout, so running both on one script says more than describing the behaviour twice. Rejected: recorded transcripts (they rot and do not say which side moved); comparing only the `log` backend (it does not reach the helper boundary).

### Where the two are known to differ

Each of these is listed in `docs/architecture/rust-core.md` under "Where the two are known to differ", and none is a scenario of the suite.

- A file that is not TOML: the line is `<file>: Invalid TOML document: <reason>` in both, but smol-toml's reason ends with a code excerpt (`1:  x = 1`, a pointer line) and its wording is its own, and the `toml` crate's is another. The prefix, the one-line count of problems being one, and the defaults that apply are equal; the rest is not. An integer beyond 2^53 is a TOML error in node (`integer value cannot be represented losslessly`) and is checked for in Rust, with that reason and no excerpt.
- A document that one TOML parser accepts and the other refuses. Both implement TOML 1.1.0; the vectors cover a corpus of edge cases (underscores, signs, `0b`, `0o`, exponents, local dates, `1e400`) and the rest is unverified.
- A YAML options file runs the node daemon: its log lines and its memory are node's, and the one hand-over line is the only line Rust adds.
- A reload that finds the options YAML only: node reads the file and reloads, Rust keeps the values in force and logs `options: <file> is YAML; a restart hands it to the node service`, because an exec at a reload would drop the queued events and the notice state. A restart hands it over.
- The operating system's text inside a log line (a failed lock release, a failed watch, a failed `ps`) for an error number that is not the same on Linux and macOS: `node::io_message` names the numbers that are, and any other error prints what Rust says.
- The spawn failure text of the helper: node's `spawn <file> ENOENT` is written for `ENOENT` and `EACCES`; any other error is the operating system's text.
- A SIGKILL at a deadline reaches the whole group of the child, not the child alone.
- A helper that writes more than 1 MiB: node kills it at the cap (the answer is unreadable); the Rust call reads it to its end at the cap and the answer is unreadable.
- The boot time is zero when it cannot be read, where node always has `os.uptime()`.
- A lone surrogate in the assistant text of a transcript: node sends it to the helper as the escape `\ud800`; a Rust `String` cannot hold it. Unverified how `json.rs` reads the escape; the vectors include one and say.
- Not a difference, found while checking the premise: `JSON.stringify` and `serde_json` both leave U+2028 and U+2029 unescaped, and both escape a control character in lower-case `\u00xx`, so a title and a duration message are written the same.

### Dependencies

Decision: the dependency table of `docs/architecture/rust-core.md` and of the `Cargo.toml` comments gains these rows, each with its reason and its measured cost (release size delta, crates added, clean build time), filled in by the change that adds them.

| dependency | used by | reason | cost |
|---|---|---|---|
| `toml` (`default-features = false`, `std`, `parse`, `preserve_order`) | `notify::options` | reads `notify.toml`; its tables keep the file's key order, which the problem lines need | `toml_parser`, `winnow`, `toml_datetime`, `serde_spanned`; `indexmap` is in the tree already |
| `kqueue` 1.2.1 (target `cfg(target_os = "macos")`) | `watch` | a safe binding of kqueue, because `rustix` declares `kevent` unsafe | `kqueue-sys` (`libc` and `bitflags` are in the tree already) |
| `rustix` features `fs`, `pipe`, `system` (added to `process`, `event`) | `watch`, `notify::service` | inotify, opening a path with `O_NOFOLLOW` on macOS, the wake pipe, the host name, in safe code | none: the crate is in the tree |

A fourth dependency is a new line and a reason. `kqueue` is MIT, `toml` is MIT or Apache-2.0, and `release.yml` builds all three targets, so a failure on one shows in the dry run of the dependency PR.

### Version and release

Decision: the change ships in three pull requests. (a) This proposal with task groups 1 and 2. (b) Groups 3, 4, 5, 7 and 8, where the `["notify","run"]` entry of `spec/cli/tagents-core.json` and the arm of `front_door.rs` (task 5.6) are the last task of group 5, after the engine, the lock and the service, because until the arm exists `notify run` is forwarded to node; the suite of group 7 runs against it before (b) is marked ready, and (b) is merged whole. (c) Groups 6 and 9 and the archive of this change, merged after (b) and after `rust-mcp` is archived (it is, on `main`: `openspec/specs/rust-mcp/spec.md`). Groups 1 to 5 change inputs of the binary (`is_input` in `.github/scripts/core-release.sh:18-23`: `Cargo.toml`, `Cargo.lock`, `crates/*/src/*`, `spec/cli/*`), so (a) and (b) each raise the workspace version one minor step above their merge base, as the gate requires, and a pull request that rebases onto a version another one raised raises it again, because two that bumped to the same step cannot both pass `core-release.sh gate`. Group 6 changes `install.sh`, `plugin.ts`, `tests/` and documents, none an input, so (c) raises nothing. None cuts a tag. A managed copy that updates to such a commit finds no release for the version, removes the older binary and says so, and keeps running node for the CLI, the MCP server and the daemon, exactly as after any bump before its tag. The version the last pull request that raises it carries is the one that is tagged, when Sasha says so; the versions between are never released. `pnpm plugin:gen` moves the plugin's version and digest where the contract or references change, and the generator, not a hand, writes them. The watch of (a) is not called by the binary until (b), so its `dead_code` lints are checked in (a) by clippy with `-D warnings`, and the kqueue dependency is built by the macOS job.

Reason: the release path is built so that an install never runs a binary of another version, and this change does not weaken it to get there sooner.

## Risks / Trade-offs

- [A defect in the daemon silences every notice] → the suite and the ported tests run on every change to either daemon; the wrapper falls back to node when the binary is gone and a start that fails before `started` hands over to node; `TAGENTS_NO_NATIVE=1` at the next install, or removing `target/release/tagents-core`, returns a machine to node.
- [A lost wake on kqueue or inotify drops an event] → every arming is followed by a read, every wake reads to the end, the suite appends two thousand events in a tight loop, and a mutation that drops the read after arming must fail it.
- [The kqueue directory watch misses what FSEvents reported] → the options file is watched as a file as well; the suite edits it in place, through a rename and as a symlink.
- [The node daemon's own symlink test is flaky on macOS, issue #39] → the differential suite does not compare the case of an edited target; the Rust watch has its own test for it, and the suite compares the replaced link.
- [Two TOML parsers disagree on a document] → the vectors cover a corpus and the rest is a known difference.
- [`recv_timeout` stops while the Mac sleeps] → deadlines are wall-clock times and the sleep is capped at five minutes, so a missed deadline fires within one cap.
- [A node and a Rust daemon run together while a machine switches] → they share the lock file and its format, and the suite starts one of each on one state directory.
- [Threads and process groups behave differently on Linux and macOS] → the suite and the tests run in CI on both, and the release job builds all three targets.
- [A reader thread stays blocked on a pipe a helper's child holds] → it holds a capture of at most the cap and ends with the holder; the drain keeps the call itself from waiting on it, as for `mcp`.

## Migration Plan

1. Merge the three pull requests of "Version and release" in order. No release exists for any of the new versions, so every machine keeps running node for the daemon.
2. When Sasha tags the last version, the next daily update of a managed copy installs the binary and rewrites the `tagents-notify` wrapper to name it for `run`, and `tagents notify install` writes the plist that names the wrapper. A daemon that is already running stays node until the agent is booted out and in (`tagents notify install` does) or the next login.
3. Check with `tagents notify status` (the service is running, the stream is on, the options are valid) and `footprint <pid>`.
4. Rollback is `TAGENTS_NO_NATIVE=1` on one machine (the binary goes at the next install), removing the release (the next install finds none and removes the binary), or editing nothing: the wrapper falls through to node at the next start.
5. The node daemon stays. A later change may retire it, with the suite, the vectors and the wrapper's native branch.

## Open Questions

- When the version this ships in is tagged (Sasha's word); until then the saving does not reach a managed install.
- Whether the daily update should boot the service out and in when the wrapper's choice changed, so a machine switches without a manual `install`. It needs `launchctl` in `install.sh`, which has none, and it restarts a service the person did not ask to restart.
- Whether `openspec/specs/notify/spec.md` ("Plugin options and defaults") should say `notify.toml` first and `notify.yaml` as the fallback: the code reads TOML first and the spec names only YAML. This change edits the two requirements that name the file (`specs/notify/spec.md`, MODIFIED) to name `notify.toml`, which holds whichever of this change and pull request #37 merges first, and states the YAML rule only in `rust-notify`.
- The smallest feature set of `toml` that builds with `Table` and `parse`; the dependency pull request settles it.
