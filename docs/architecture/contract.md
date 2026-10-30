# The generated contract

The Claude Code plugin tells a session exactly what every tagents command and package accepts. Nobody writes that description: `pnpm plugin:gen` reads it out of the code, so it cannot drift from what the code does. This page explains what is generated, how the plugin's version moves, and what keeps it honest.

## What is generated

`pnpm plugin:gen` reads four things out of the code and rewrites `contract.json` and `skills/tagents/references/`:

| what | read from | lands in |
|------|-----------|----------|
| every verb, flag, exit code and effect of `tagents-core`, `tagents-knowledge` and `tagents-notify`, and of the flags of `tagents` that are not interactive | the command specs `parseArgs` itself is handed: `spec/cli/tagents-core.json` for `tagents-core` (read through `packages/core/src/cli/spec.ts`), `packages/knowledge/src/cli/spec.ts` for `tagents-knowledge`, `packages/notify/src/cli/spec.ts` for `tagents-notify`, and `tagents.cli.json` for the bash script | `contract.json`, `references/cli.md` |
| every MCP tool and its input schema | the knowledge server `createServer()` builds, asked for its tool list the way a client asks, and the tools of the `tagents` server, which `toolSpecs()` derives from the verbs above | `contract.json`, `references/mcp.md` |
| the public TypeScript API of each package | declarations emitted from the sources, through [API Extractor](https://api-extractor.com/) | `references/*.api.md`, and a hash of each in `contract.json` |
| the flags of `tagents`, `tusage` and `tnotes` | each script's own `--help` | `references/scripts.md` |

## The version moves by itself

`plugin.json` carries a digest of everything the plugin ships: the generated files, the skill and the manifests. When a regeneration changes that digest, the version moves with it:

| what changed | the bump |
|--------------|----------|
| the structure of the contract: a verb, a flag, a tool, a schema, an exported signature | minor |
| only text | patch |

Two details:

- The bash scripts have no spec to read, so a change in their help counts as text. The exception is `tagents.cli.json`, the hand-written description of the non-interactive flags of `tagents`: it is structural like any spec, and a test pins it against `tagents --help`, so a flag renamed in the help and not in the file fails the tests.
- Text that is part of an exported type is a signature. `@tagents/core` and `@tagents/knowledge` export their English string table with literal types, so an edited English message there is a minor bump too.

An installed plugin stays on its version until the version changes, which is why the bump is not left to memory.

## The tools follow the verbs

The `tagents` MCP server (`packages/mcp`, and `tagents-core mcp` in the Rust binary, which derives the same tools from `contract.json`) has one tool for each verb that is in a spec above, except the verbs that run until they are stopped and the verbs that say `tool: false`, and it knows no verb by name: `toolSpecs()` derives the tools from the specs, the generator records them in `contract.json` under `mcp.tagents.tools`, and the server derives them again from that file when it starts. A verb added to a spec is therefore a new tool, a new digest and a minor bump after `pnpm plugin:gen`, with no tool code written.

A verb may declare an `effect` (`read`, `write`, `spawn`, `destructive` or `serve`). The effect becomes the tool's annotations, which is what Claude Code's permission prompt shows. A verb that declares none is offered as a tool that is not read-only, and `pnpm plugin:gen` and `pnpm plugin:check` print a `notice:` line naming it, without failing. The verbs of `tagents-core` say it in the data file `spec/cli/tagents-core.json`, whose schema takes the five words and nothing else:

```json
{
  "path": ["session", "abort"],
  "positionals": ["<ref-json-or-id>"],
  "options": {},
  "required": [],
  "summary": "summarySessionAbort",
  "impl": "node",
  "effect": "destructive",
  "tool": false
}
```

The verbs of `tagents-knowledge` and `tagents-notify` say it in their TypeScript spec:

```ts
export const INDEX = { path: ['index'], summary: 'summaryIndex', effect: 'write', /* … */ } as const satisfies CommandSpec<KnowledgeKey>;
```

`requires: 'tmux'`, which makes a caller without a tmux server of its own refuse at once, and `toolDefaults` (below) are for the specs written in code, `tagents.cli.json` among them, because the schema of the data file refuses a key it does not know.

A verb that is not for a model, such as one that opens a session or sends a prompt into a window the caller cannot see, says `tool: false`: it stays in the `cli` section of `contract.json` and in the references, and has no tool. A verb may also name boolean options in `toolDefaults`, the value a tool call uses when the caller leaves them out; the generator stops when the map names an option the verb does not have or one that takes a string. `tagents.cli.json` uses it for `--detach` on `--new` and `--window`, so a window opened by a tool does not take the screen.

```json
{ "path": ["--window"], "options": { "detach": { "type": "boolean" } }, "toolDefaults": { "detach": true }, /* … */ }
```

Nineteen tools result today: `core_doctor`, `core_plugin_list`, `core_plugin_new`, `core_plugin_remove`, `core_session_last`, `core_session_list`, `core_sessions_show`, `knowledge_index`, `knowledge_lint`, `knowledge_toc`, `notify_send`, `notify_status`, `notify_test`, `tagents_check`, `tagents_config`, `tagents_label`, `tagents_new`, `tagents_profile_for` and `tagents_window`.

## Three things keep it honest

1. **A pre-commit hook.** `.githooks/pre-commit`, switched on for the clone by `pnpm install` unless the clone already has a `core.hooksPath` of its own, regenerates when a commit touches a source of the contract and adds the result to that same commit. When the regeneration itself fails, the commit is refused.
2. **The tests.** `pnpm test` fails when the files on disk are stale.
3. **CI.** It runs `pnpm plugin:check` and `claude plugin validate --strict`.

## When two branches both moved the version

They conflict on `version` and `digest` in `plugin.json`. Take either side and run `pnpm plugin:gen`.

```sh
pnpm plugin:gen      # regenerate contract.json and skills/tagents/references/
pnpm plugin:check    # fail if what is on disk is stale
```
