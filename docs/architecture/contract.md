# The generated contract

The Claude Code plugin tells a session exactly what every tagents command and package accepts. Nobody writes that description: `pnpm plugin:gen` reads it out of the code, so it cannot drift from what the code does. This page explains what is generated, how the plugin's version moves, and what keeps it honest.

## What is generated

`pnpm plugin:gen` reads four things out of the code and rewrites `contract.json` and `skills/tagents/references/`:

| what | read from | lands in |
|------|-----------|----------|
| every verb, flag and exit code of `tagents-core` and `tagents-knowledge` | the command specs `parseArgs` itself is handed, `packages/*/src/cli/spec.ts` | `contract.json`, `references/cli.md` |
| every MCP tool and its input schema | the server `createServer()` builds, asked for its tool list the way a client asks | `contract.json`, `references/mcp.md` |
| the public TypeScript API of each package | declarations emitted from the sources, through [API Extractor](https://api-extractor.com/) | `references/*.api.md`, and a hash of each in `contract.json` |
| the flags of `tagents`, `tusage` and `tnotes` | each script's own `--help` | `references/scripts.md` |

## The version moves by itself

`plugin.json` carries a digest of everything the plugin ships: the generated files, the skill and the manifests. When a regeneration changes that digest, the version moves with it:

| what changed | the bump |
|--------------|----------|
| the structure of the contract: a verb, a flag, a tool, a schema, an exported signature | minor |
| only text | patch |

Two details:

- The bash scripts have no spec to read, so a change in their help counts as text.
- Text that is part of an exported type is a signature. `@tagents/core` and `@tagents/knowledge` export their English string table with literal types, so an edited English message there is a minor bump too.

An installed plugin stays on its version until the version changes, which is why the bump is not left to memory.

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
