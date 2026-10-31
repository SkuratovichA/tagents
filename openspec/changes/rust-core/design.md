## Context

`tagents-core` is a node CLI (`packages/core/src/cli/main.ts`) over the `@tagents/core` package: headless Claude sessions, the plugin host, the history reader and `doctor`. The bash dashboard `tagents` forwards every verb it does not know to it (`forward_core`), and `install.sh` writes a wrapper that runs it on the node that installed it. Three other packages import from `@tagents/core`: `@tagents/knowledge` takes `realClock, TurnClock, renderRecent, renderSearch, configDir, configFile, CliContract, CommandSpec`, and `@tagents/notify` takes `runPluginBin, realClock, TurnClock, AgentEvent, AgentFeed, AgentStateRow, findOnPath, DEFAULT_LOCALE, isLocale, Locale, lastAssistantText, writeAtomic` and more. The contract generator reads the CLI's command specs, and the generated plugin (`contract.json`, `.claude-plugin/`, `skills/`) must not move when a verb changes language.

The road to a Rust core is long and each stone has to be walkable on its own. This change lays the first two: S0 (a workspace, a language-neutral CLI spec and the seam where a Rust program sits in front of the node one) and S1 (`sessions`, the smallest verb group that reads files and prints text). See `proposal.md` for the motivation; this file records how, and what the later slices are going to be, so that S0 and S1 do not close a door that S2 to S5 need.

## Goals / Non-Goals

**Goals:**

- A Rust `tagents-core` that is the front door: it serves what it implements and runs the node CLI for everything else, with the exit code untouched.
- One description of the CLI that node, the contract generator and Rust read, so a verb moving between languages is a one-word edit of a data file.
- A parity suite strong enough that "the Rust output equals the node output" is a tested statement, not a hope.
- With no Rust binary anywhere, behaviour and the files `install.sh` writes are byte for byte what they were.

**Non-Goals:**

- No binary is built, downloaded or installed on a user's machine by anything in this change. How a binary reaches a user (release assets with checksums) is the next slice, `openspec/changes/rust-release/`, and needs Sasha's word before the first tag.
- No plugin protocol, no service, no JavaScript engine: option (ii) below is described and not built.
- No config is read from Rust yet. S0 and S1 read the environment and the transcripts, nothing else.
- No change to the text of any verb, any exit code, any MCP tool, `openspec/specs/` or the generated contract.

## Decisions

### The CLI spec is a language-neutral JSON file with a JSON Schema

Decision: `spec/cli/tagents-core.json` holds the verbs, flags, positionals, required flags, summary keys, exit codes and, per command, `"impl": "rust" | "node"`; `spec/cli/cli-spec.schema.json` (draft 2020-12, `additionalProperties: false`) describes it and accepts, per command, an optional `effect` (one of `read`, `write`, `spawn`, `destructive`, `serve`) and `"tool": false`. The node CLI, the contract generator and Rust read the same file.

Reason: three programs need one list, and JSON with a schema is the only form all of them read without a build step between.

Rejected: generating the spec from Rust, because the node CLI and the contract generator would then wait on a cargo build to start and `pnpm plugin:gen` would need a toolchain; keeping the spec in TypeScript, because Rust would have to parse TypeScript or keep a second copy that drifts.

```jsonc
// spec/cli/tagents-core.json
{ "path": ["sessions", "search"], "positionals": ["<words…>"], "options": {}, "required": [],
  "summary": "summarySessionsSearch", "impl": "rust" }
```

```ts
// packages/core/src/cli/spec.ts: one relative URL finds the file from src/, dist/, a checkout and the managed copy
export const SPEC_FILE = new URL('../../../../spec/cli/tagents-core.json', import.meta.url);
```

`CommandSpec` and `CliContract` keep their shape, so `@tagents/knowledge` and the generator are unchanged; the generator still calls `coreCliContract()`, which now reads the file, and `contract-stable` (`pnpm plugin:gen` leaves no diff) is the proof that the contract did not move.

The summary text stays in the i18n catalogue (`i18n/en.ts` and the other locales), keyed by `summary`, so there is one source of it. Rust prints no summary in S0 and S1: `--spec` prints the key, and the usage lines of `sessions` are fixed text that the fixtures pin. When a Rust verb has to print help (S2), the English catalogue reaches Rust as a file generated from `i18n/en.ts` by the contract generator, so `contract-stable` pins it. Rejected: the text inside the data file, because it would fix one language in a file that is read by a localized CLI; parsing `en.ts` from Rust, because it is TypeScript.

### Rust is the front door, node the fallback

Decision: `target/release/tagents-core` is the program users run. A first word it serves (`sessions`) is answered in-process; every other argument list replaces the process with `node packages/core/dist/cli/main.js <args>` (same argv, environment, working directory, stdin, stdout, stderr; `exec`, so the exit code and any signal are the node CLI's own). `tagents-core --spec` prints the data-file entries it serves, and a test pins that list to `impl: "rust"` in both directions.

Reason: the front door has to own the whole name for the day the last verb moves, and `exec` makes the seam invisible to exit codes, signals and stdio.

Rejected: dispatch in each shell wrapper (`tagents`, `install.sh`'s wrapper, a hook) by a list of ported verbs, because the list would then live in three places and a verb moving would be three edits; a big-bang rewrite, because nothing could be released until all of it existed and nothing could be compared to the old program verb by verb.

```rust
// crates/tagents-core/src/front_door.rs
pub fn run(args: Vec<OsString>) -> ExitCode {
    if args.len() == 1 && args[0] == OsStr::new("--spec") { return print_served_spec(); }
    match args.first().and_then(|a| a.to_str()).and_then(|w| GROUPS.iter().find(|g| g.word == w)) {
        Some(group) => emit(&(group.run)(&rest(&args), &context())),
        None => forward(&args), // Command::new(node).arg(cli).args(args).exec()
    }
}
```

The dispatch is by the first word, so `sessions` is served wholly by one program, misspelled subcommands and usage lines included. Where the node CLI is: the binary lives at `<root>/target/{release,debug}/tagents-core`, so its node CLI is `<root>/packages/core/dist/cli/main.js` with symbolic links resolved. A checkout that has not been built says `pnpm install && pnpm build` and exits 2; a missing node exits 127 and an unrunnable one 126, the codes a shell uses. `exec` does not leave SIGPIPE ignored for the node CLI (measured with a probe child that writes to a closed pipe: it died quietly, as it does from a shell; `the_node_cli_starts_with_sigpipe_at_its_default` pins it).

### Where the Rust binary is looked for, and what an unrunnable one does

Decision: `forward_core` in `tagents` looks, in order, at `tagents-core` on `PATH`, `${SELF%/*}/target/release/tagents-core` when it is an executable file, then the built node CLI as before. `install.sh` names the Rust binary in the `tagents-core` wrapper only when `$TAGENTS_HOME/target/release/tagents-core` is an executable file at install time, and the wrapper falls through to the node CLI if the binary stops being one later; the pinned node travels with the call as `TAGENTS_NODE`. A binary that exists and cannot be run is an error that the shell reports (`exec` fails and the script exits), not a silent fallback.

Reason: a user with no binary must get the very same wrapper bytes as before, and a user with a broken binary must hear about it instead of getting the slow path forever.

Rejected: always naming the binary in the wrapper, because it changes every wrapper file on every machine; falling back to node when `exec` of the binary fails, because that hides a corrupt download behind a working program.

```sh
# the tagents-core wrapper, written only when an executable file is there at install time
n="/opt/node/bin/node"
[ -x "$n" ] || n=node
r="/home/u/.local/share/tagents/target/release/tagents-core"
[ ! -f "$r" ] || [ ! -x "$r" ] || { TAGENTS_NODE="$n"; export TAGENTS_NODE; exec "$r" "$@"; }
exec "$n" "/home/u/.local/share/tagents/packages/core/dist/cli/main.js" "$@"
```

### The plugin host stays in node

Decision: plugins are JavaScript packages that `host.ts` loads with `import()`, and the host stays a node program for now: option (i) below, with option (ii) as the later step. Nothing of (ii) is built by this change.

Reason: a plugin is code written against the TypeScript SDK, and only a JavaScript runtime can load it without a protocol between the two.

Rejected: option (iii), embedding a JavaScript engine in the Rust binary, because it would carry an engine, a module loader and a re-implementation of the node APIs the plugins use (`node:fs`, `node:child_process`, `fetch`) into every release for the sake of one feature; the three options are compared under "The plugin host" below.

### `@tagents/core` stays as the plugin SDK and the fallback

Decision: the TypeScript package keeps every export other packages import, with the same names and signatures, and the node CLI keeps working when no Rust binary exists. S0 changes `cli/spec.ts` internally and nothing in `index.ts`; later slices may add exports and delete none.

Reason: `@tagents/knowledge` and `@tagents/notify` compile against these names, and plugin authors write against the SDK.

Rejected: moving the exports to a new package at the same time, because it would be a breaking change for packages in this repository and outside it for no gain in S0 and S1.

```ts
// packages/knowledge/src/..., packages/notify/src/...: unchanged
import { realClock, renderRecent, renderSearch, configDir, type CliContract } from '@tagents/core';
```

### Config is read in Rust only against project B's JSON Schema

Decision: when a Rust verb first needs the config (S2), it reads the TOML file with `serde` and `toml`, derives the schema with `schemars`, and a pin test compares the derived schema to the JSON Schema project B ships, so the TypeScript and the Rust readers cannot drift. S0 and S1 read no config and add none of these crates.

Reason: the config format is project B's and the schema is its contract; Rust must be a second reader of it, not a second definition.

Rejected: a hand-written Rust model with no pin, because a field added to the schema would silently be ignored by one of the two programs; reading the YAML file of today, because B replaces it.

```rust
// S2, sketch: the pin
#[test]
fn the_rust_model_is_the_published_schema() {
    let derived = serde_json::to_value(schemars::schema_for!(Config)).unwrap();
    assert_eq!(derived, serde_json::from_str::<Value>(include_str!("../../../spec/config/config.schema.json")).unwrap());
}
```

### Lints, no async runtime, and every dependency named

Decision: `unsafe_code = "forbid"` and clippy `unwrap_used` and `expect_used` set to `deny` for the whole workspace, allowed in tests only (`crates/clippy.toml`); no async runtime; every dependency is listed here with its reason and its cost, and a new one is a line in this file.

Reason: a CLI that reads untrusted transcripts must not panic on a line it does not like, and nothing in these slices waits on two things at once.

Rejected: `anyhow`-style error aggregation and `tokio`, because the verbs are straight-line file reads and a failure is one message and an exit code.

| dependency | used by | reason | cost |
|---|---|---|---|
| `serde` (derive) | `tagents-spec` | reads the data file into a typed model that refuses unknown fields | the derive macro pulls `serde_derive`, `syn`, `quote`, `proc-macro2`, `unicode-ident`, `serde_core` at build time |
| `serde_json` | `tagents-spec`, `tagents-core` | parses the data file, prints `--spec` and, for `mcp`, speaks JSON-RPC and reads the contract | `itoa`, `memchr`, `zmij`; its parser is not used for transcripts |
| `serde_json` features `preserve_order`, `arbitrary_precision` | `mcp` | a program's JSON keeps the order of its keys and the digits of its numbers, and the contract's maps keep the file's order | `indexmap`, `equivalent`, `foldhash`, `hashbrown`; additive, so they apply to every crate of the workspace |
| `rustix` (feature `process`) | `mcp::run` | signal a process group and wait for a child without reaping it, in safe code | `bitflags`, `errno`, `libc` |
| `signal-hook` | `mcp::server` | end on SIGTERM, SIGINT or SIGHUP from a thread, in safe code | `signal-hook-registry` |

The transcripts are parsed by `json.rs`, a small parser of its own, because `serde_json` differs from `JSON.parse` in three ways that change which transcript lines are read: it refuses a lone surrogate escape, it refuses a number that overflows a float, and it stops at 128 levels of nesting. A line that one program skips and the other reads would list different prompts, so the parser takes exactly the grammar of ECMA-404, keeps its open containers on the heap and drops a deep value iteratively. It is the one deliberate second copy of logic in the change; the parity suite pins it to node.

### The parity suite compares bytes and is itself tested

Decision: `tests/rust-parity.sh` seeds homes with `tests/rust-parity-seed.mts` (the two sessions of the checked-in fixtures and about 600 more built so that JavaScript and a naive port disagree), runs the node CLI and the Rust binary under the same `env -i` environment and passes a case only when stdout, stderr and the exit code are identical. `cargo test` has the five fixture files (`packages/core/test/fixtures/sessions/*.txt`) as a second, node-free oracle. A few "tripwire" cases assert on the node output alone, so a seed that stopped provoking a divergence fails instead of passing for nothing.

Reason: a port is only as good as the cases that can tell it from the original.

Rejected: fixtures alone, because five files cannot tell UTF-16 lengths from characters; a property test against a node oracle in Rust, because it needs node inside `cargo test` and the shell suite already does that job.

```sh
parity() {  # <label> <home> <args…>: node and Rust, same environment, every byte
  use "$2"; shift 2
  env -i "${ENVV[@]}" "$NODE" "$CORE_JS" "$@" >"$TMP/n.out" 2>"$TMP/n.err"; n=$?
  env -i "${ENVV[@]}" "$RUST" "$@" >"$TMP/r.out" 2>"$TMP/r.err"; r=$?
  cmp -s "$TMP/n.out" "$TMP/r.out" && cmp -s "$TMP/n.err" "$TMP/r.err" && [ "$n" = "$r" ] && ok || bad "$label"
}
```

The suite was checked by mutation: 22 single edits to the Rust port, one at a time (a rounding that goes away from zero, Unicode white space, characters in place of UTF-16 units, a search window of 401 or 399, a thirteenth hit, a tail window that keeps its fragment, ASCII-only lower casing, followed symbolic links, an infinity accepted as a number, reversed project order, and so on), each built and run against the suite. Every one makes the suite fail. One of them, a `CLAUDE_HOMES` entry trimmed with Rust's white space instead of JavaScript's, first passed all 384 cases, because the only entry it changes is a relative directory named U+0085; that is why the suite has a `rel` home, run from a working directory that holds such a directory.

## The slice plan

The road, with what each slice proves. Only S0 and S1 are in this change; the rest are plans, and each one is its own change.

| slice | what moves | why it is next | gate |
|---|---|---|---|
| S0 | workspace, spec file, front door, fallback, installer and dispatcher lookup, CI | nothing can move before a seam exists | `contract-stable`, byte-identical wrappers, `--spec` equals the data file |
| S1 | `sessions recent`, `search`, `show` | read-only, text only, an oracle on disk | the parity suite and the five fixtures |
| S2 | `plugin list`, `plugin add`, `plugin remove`, `plugin new`, `doctor` | they edit one file and print; no plugin code runs | the same parity method on a seeded config, plus a pin of the derived schema |
| S3 | `session open`, `prompt`, `last`, `list`, `abort` | the session driver (tmux, `claude`, the state dir) has no plugin in it | a stub `claude` that records its argv and environment |
| S4 | the plugin protocol and the services | the first slice that must decide the host | a protocol test with a node shim and a stub plugin |
| S5 | retirement of the node CLI for the verbs ported | only after a release has shipped a binary for a while | the fallback is deleted, the SDK stays |

S2 uses `toml_edit` to change the `plugins` table of the config file while keeping the owner's comments and key order, which is what the splice in `plugin-config.ts` does for YAML today. Resolving a plugin package (`plugin add ./x`) uses node's resolution through `createRequire`; Rust needs a subset of it (walk `node_modules`, read `package.json` `exports` and `main`), and the parity method applies to it as well: the oracle is `createRequire` itself. `doctor` checks tools on `PATH` (the Rust counterpart of `findOnPath`), the config and the state directory.

S3 needs no plugin, but it spawns `claude` with an environment the node driver builds (`CLAUDE_CONFIG_DIR`, `TA_STATE_DIR`, `TA_LABEL`, `TA_LOG`) and waits on the state records the hook writes; the stub `claude` makes that comparable byte for byte.

S4 is the slice that needs the decision below. S5 deletes nothing that other packages import: `@tagents/core` stays as the SDK.

## The plugin host

Plugins are JavaScript. Three ways to host them from a Rust binary:

### (i) Node stays the host

The Rust binary serves everything that needs no plugin and starts the node CLI for everything that does (`plugin run`, a plugin's own verbs, a plugin's services). This is what the front door already does for every unported word.

```rust
// the plugin verbs stay `impl: "node"` in the data file; the front door needs no new code
None => forward(&args), // exec node packages/core/dist/cli/main.js plugin run …
```

Cost: node remains a prerequisite for plugins. Benefit: no protocol, no second plugin runtime, nothing to keep in step.

### (ii) A JSON-lines protocol over stdio, with a small node shim

Rust owns the process and the services (scheduling, the state dir, the event feed); a node shim loads the plugin and talks to Rust in newline-delimited JSON on stdin and stdout, one request or event per line. The SDK stays the plugin author's API; the shim adapts it.

```jsonc
// Rust -> shim                                  // shim -> Rust
{"id":1,"method":"init","params":{"config":{}}}  {"id":1,"result":{"commands":["notify"]}}
{"id":2,"method":"event","params":{"AgentEvent":{}}} {"id":2,"result":null}
```

Cost: a versioned protocol, a shim to ship, two processes per plugin. Benefit: a plugin that does not need node stops depending on it, and the services run in Rust. This is the step after (i), when S4 starts. Nothing of it is built here.

### (iii) An embedded JavaScript engine

Rust loads the plugin into an engine it links in.

Cost: the engine, a module loader and the node APIs that plugins use today (`node:fs`, `node:child_process`, `fetch`, `createRequire`) would all have to be provided; every release carries the engine. Rejected.

Recommendation: (i) now, because it is free and it is what S0 builds, and (ii) later, when S4 starts and a plugin needs a service that must live in Rust. The decision for (ii) is Sasha's, not this change's.

## What the two runtimes share on disk

Anything both runtimes read or write is a format, and a format is a contract. These are the files that exist today; Rust must read and write them byte for byte as the TypeScript does, and each gets a parity or round-trip test in the slice that touches it.

| file | writer | readers | format |
|---|---|---|---|
| `~/.claude*/projects/<slug>/<id>.jsonl` | Claude | `sessions` (node and Rust), `tusage` | JSON lines; the reader looks at the first 64 KiB and the last 48 KiB only |
| `$TA_STATE_DIR/<key>.tsv`, `history.tsv`, `labels.tsv`, `sub/<key>.<agent_id>` | `hooks/tmux-agent-state.sh`, the dashboard | the dashboard, `@tagents/core` (`agent-state.ts`) | tab separated, one record per line, written by atomic rename |
| `$TA_STATE_DIR/events.tsv` (+ `events.tsv.1`) and `events.on` | the hook while `events.on` exists | `@tagents/core` (`agent-events.ts`), notify | 13 tab-separated fields, appended, rotated at 5 MiB |
| the config file and `config.<hostname>.*` | the owner | `tagents`, `@tagents/core` | project B's TOML and its JSON Schema; the editor must keep comments and key order |
| `spec/cli/tagents-core.json` | the repository | node, the contract generator, Rust | this change |
| `contract.json`, `skills/tagents/references/` | `pnpm plugin:gen` | Claude Code | generated; Rust never writes them |

The atomic write (`writeAtomic` in `atomic.ts`: a temp file in the same directory, then `rename`) has to be the same in both runtimes, since a reader in the other one must see the old file or the new one and never half of it. The temp names differ (`<file>.<pid>.tmp` there, `.<key>.<pid>` in the hook), which readers already ignore.

## Risks / Trade-offs

- [Two implementations of `sessions` can drift] → the parity suite runs in CI on every change to `crates/`, `spec/` or `packages/core/`, and its mutation check says which kinds of drift it sees; a third copy of the text anywhere is a defect.
- [The platforms the suite ran on are macOS and Linux CI; readdir order, negative mtimes and file modes differ between filesystems] → the seed sets exact times with `python3`, the suite lists names the way libuv does (sorted by byte), and the first Linux run is CI itself; a failure there is a finding, not noise.
- [A Rust binary that exists and cannot run is loud] → intended; the alternative hides a corrupt download. The wrapper does fall through when the file is gone.
- [`exec` in the front door replaces the process, so nothing of Rust runs after the node CLI starts] → nothing needs to; the only guarantee wanted is the exit code and the signal, which `exec` gives for free.
- [Non-UTF-8 directory entries are dropped by the Rust listing, where node would hand back a name with U+FFFD in it and the next `stat` on it fails] → documented in `transcripts.rs`; a transcript under such a name could not be read by node either.
- [A needle that contains U+FFFD can match a lone surrogate in a transcript for node and not for Rust, and Unicode versions of `toLowerCase` differ between node releases] → accepted and documented in `js.rs`; no recorded transcript has either.
- [A stdin that the front door had read would be lost to the node CLI] → the front door reads nothing before it decides: a served verb reads no stdin, and an unserved one is exec'd with stdin untouched.
- [Adding Rust to a TypeScript repository adds a toolchain for contributors] → `rust-toolchain.toml` pins it, only `crates/` needs it, and nothing in `pnpm build` or the installer touches cargo.

## Migration Plan

1. Merge this change. Every user and every CI job behaves as before, since no binary exists on any machine.
2. A contributor who wants the front door runs `cargo build --release`; `tagents` and, after the next install, the `tagents-core` wrapper then use it. Deleting `target/` returns to the old behaviour with no other step until a release exists for the version the checkout holds: from then on the next install fetches the prebuilt binary again, and `TAGENTS_NO_NATIVE=1` keeps it away (`openspec/changes/rust-release/`).
3. Rollback is reverting the commit: the wrappers an install wrote without a binary are the old ones byte for byte, and one written with a binary falls through to node when the binary is gone.

## Open Questions

- Where do release binaries come from (GitHub Releases with a sha256, per the plan Sasha approved), and which target triples: settled by `openspec/changes/rust-release/` (three targets, one archive and one checksum each).
- Whether S3 keeps the tmux and `claude` driver in one crate with the front door or in its own: it can wait until S3 starts, since the verbs are unchanged either way.
