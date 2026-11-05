# Design of `rust-retire-node`: node gives up the verbs the binary serves (stage S5 of the Rust port, issue #28)

Context: `openspec/changes/archive/2026-10-31-rust-core/design.md` plans S5 as "retirement of the node CLI for the verbs ported: the fallback is deleted, the SDK stays". Node stays the host of plugins, which is decided (`docs/architecture/rust-core.md`, "The plugin verbs").

## What stays in node, and is not touched

`plugin list`, a `plugin` word the binary does not know, the verbs of plugins and an unknown first word (the host decides), `tagents-knowledge index|search|show|list|lint|toc|usage`, the `tagents-notify` verbs other than `run`, and the SDK: everything `packages/core/src/index.ts` exports.

## Pull request 1: the binary answers every call of its verbs

No call of a verb with `impl: "rust"` reaches node. The type system says so: `session`, `sessions` and `doctor` return `Output`, not `Option<Output>`, and `plugin` returns `None` only for `list` and for a word it does not know.

What it prints when node's answer was the reason for handing over, in this order of preference:

1. Node's text is a line of the messages table or a fixed template, as `util.parseArgs` errors are: the same bytes. `crates/tagents-core/src/parse_args.rs` already has node's parser with its wording.
2. Node's text carries a third party's words (the TOML parser's message): the same frame and exit code as node, with the words of the Rust parser inside.
3. A reference the binary cannot hold or act on (a lone surrogate, a NUL, half an emoji in a prefix, an empty `bin`, a bad env name): `badRef`, with node's exit code for `badRef`. No `session open` writes such a reference, so this is reached only by a reference written by hand.

An argument or an environment entry that is not UTF-8 is decoded lossily, as node decodes it. A SIGCHLD that is ignored at the start of `session prompt` does not stop the verb: the no-op handler it already installs covers it.

`notify run` has no hand-over: a step before `started` that fails writes its line and exits with the code launchd retries. `tagents-core`, `help`, `--help` and `-h` print the `usage` line themselves, with node's exit codes.

Each scenario keeps comparing with node. A scenario whose words cannot match says what the binary prints instead (`OWN_ERR`, and `OWN_CODE` when the exit code differs too), and each such scenario is listed in "Where the two are known to differ" of `docs/architecture/rust-core.md`.

## Pull request 2: node's verbs go

**The oracle.** The parity suites compare with node, and that comparison is what keeps the binary honest, so they keep their node side: `tests/parity-oracle.sh` unpacks tag `v0.6.7` (`git archive`) under `target/parity-oracle/v0.6.7`, runs `pnpm install --frozen-lockfile` and `pnpm build` there once and prints the path. Every suite reads node's side from that path, and CI fetches the tag and runs the script in a step of its own. A change to the binary's behaviour after this point shows up as a difference and is either a bug or gets `OWN_ERR`. The vector generators stop running: the fixtures under `crates/tagents-core/tests/fixtures/` are frozen, and the generators and CI steps go.

**The deletion.** `packages/mcp` goes whole. From `packages/core/src/cli`: `session`, `sessions` and `doctor` in `main.ts`, `add`, `remove` and `new` in `plugin.ts`, and `scaffold.ts`. From `packages/knowledge`: `serve`, `mcp`, `src/mcp/*` and their exports. From `packages/notify`: the code only the `run` service reaches. Tests of what is deleted go with it.

**A machine with no binary.** Node's CLI answers a retired verb with one line that names `tagents update` and `cargo build --release -p tagents-core`, and exit 69, the code `tagents-knowledge join` already gives for no binary. The check reads `impl` from `spec/cli/tagents-core.json`, so it cannot drift from the file:

```ts
const served = SPEC.commands.filter((c) => c.impl === 'rust');
if (served.some((c) => c.path[0] === verb && (c.path.length === 1 || c.path[1] === rest[0]))) { io.err(`${t('needsBinary', { verb: [verb, rest[0]].join(' ').trim() })}\n`); return EXIT.noBinary; }
```

A group that is wholly the binary's (`session`, `sessions`) answers this way for any word after it. The `tagents-mcp` wrapper's last line runs node's CLI with `mcp`, so it gets the same line. The other wrappers keep their text, except that `tagents-knowledge` no longer tests `TAGENTS_NO_NATIVE` at run time.

**The installer.** No path of `fetch_native` removes a binary unless `TAGENTS_NO_NATIVE=1` asks for it. With no prebuilt for the new version (the window between a merge and its release, which a machine has already hit) the installed binary stays and a warning says so; with no binary at all the warning names what will not work. A stale binary is better than no binary, and the next `tagents update` replaces it.

**A LaunchAgent installed before the wrapper existed** still says `node packages/notify/dist/main.js run`. That `run` starts `target/release/tagents-core notify run` as a child with inherited stdio and passes SIGTERM and SIGINT on, or gives the needs-binary line and exit 69. `runSpecFor` always writes the wrapper from now on.

**The launcher** keeps its order (`join`, then `serve` with `nc`, then `mcp`), because a plugin newer than the install still reaches an older wrapper, and a plugin older than the install (0.7.6, on both accounts of one machine today) calls `serve` and `mcp`, which the wrappers must keep accepting. It stops setting `TAGENTS_NO_NATIVE`: after a failed probe it goes on to the binary's `serve` and `mcp`, a per-session server that needs no daemon.

## Not done

Moving the one-shot `tagents-knowledge` verbs to Rust, and a binary for a platform with no release, are not part of this change.
