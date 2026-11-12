---
name: okb
description: Use when searching or reading the owner's knowledge documents (OKF v0.2 markdown with front matter) — through the `knowledge` MCP tools this plugin registers or the `okb` CLI — or when indexing, listing, linting or tabling the folder of those documents, or reading which documents were opened.
---

# okb

## Overview

okb is the knowledge base of the owner's markdown documents: a folder of OKF v0.2 files with front matter, an SQLite full-text index over them, and one binary, `okb`, that serves both the CLI and an MCP server. This skill is its contract: every verb, flag and MCP tool, generated from the code at this plugin's version. Read the reference for the surface you need before calling it.

## Which reference

| You need to | Use | Read |
|---|---|---|
| search, read or list the knowledge documents from a session | the `knowledge` MCP tools this plugin registers (`knowledge_search`, `knowledge_get`, `knowledge_list`, `knowledge_usage`) | `references/mcp.md` |
| index, lint or build the table of contents of the folder, or search it from a shell | `okb` | `references/cli.md` |

## What holds everywhere

- The folder comes from the `--dir` option, `OKB_DIR`, or `dir` in `~/.config/okb/config.toml` (`OKB_CONFIG_DIR` moves that directory), and `okb` says so when none is set. The index and the usage record live in the same directory and are rebuilt or created on demand.
- `okb` must be on `PATH`; the tagents installer writes it. A machine without it has no knowledge server until `tagents update`.
- A verb that prints JSON prints one pretty-printed document on stdout. Exit codes carry the outcome, and the table is in the `okb` section of `references/cli.md`. Check the exit code before parsing the output.
- The MCP server named `knowledge` is one shared process per environment, which every session joins, so a session costs about a megabyte.

## Common mistakes

- **Trusting a remembered flag.** The references are regenerated whenever the code changes, and a flag from memory is a flag from an older version.
- **Searching before indexing.** `knowledge_search` reads the index; `okb index` brings it up to date with the folder, and a changed document is reindexed on the next call.
- **Editing a file under `references/`.** They are generated; the change belongs in the code, and `pnpm plugin:gen` in the tagents repo rewrites them.
