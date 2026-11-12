## Why

The knowledge base is agent memory that works without tmux, yet it ships inside tagents: a node package for seven verbs, a Rust module for the three servers, one MCP server in the tagents plugin. The owner decided to give it its own name, binary and plugin, and to finish the Rust port, because the seven node verbs are the last part of the knowledge base that node still serves. Two pull requests do it: the first makes the binary and removes node from the knowledge base, the second makes the plugin.

## What Changes

Pull request A (this branch):

- New crate `crates/okb` (library and binary `okb`). The Rust knowledge module and its tests move there from `tagents-core`, which depends on nothing of it and no longer links SQLite, YAML or SHA-256.
- `okb` serves `index`, `search`, `show`, `list`, `lint`, `toc` and `usage`, ported from the node package at byte parity, and `mcp`, `serve` and `join`. `okb --spec` prints `spec/cli/okb.json`; `okb --version` prints the workspace version.
- `packages/knowledge` is deleted. **BREAKING** for the library `@tagents/knowledge`: it was never published and has no importer outside this repository, and its API report goes with it. The contract package reads `spec/cli/okb.json` and a JSON of okb's texts instead of the package source.
- `tagents-core knowledge <args>` runs `okb <args>`, or prints a line naming `okb` and `tagents update` and exits 69.
- The installer installs `okb` beside `tagents-core`; `tagents-knowledge` becomes a wrapper that runs `okb`. The plugin's launcher moves to `bin/knowledge-mcp`.
- The release carries separate `okb` archives. The workspace version is 0.8.0.

Pull request B (described here, not built here):

- A second plugin `okb` with the MCP server `knowledge` (tool names unchanged, full names `mcp__plugin_okb_knowledge__knowledge_*`) and a skill of its own; the `tagents` plugin depends on it.
- `sessions_recent` and `sessions_search` move to the `tagents` MCP server under the same names.
- `okb` gets its own config directory, `OKB_DIR` and `OKB_CONFIG_DIR`; the usage store is copied once. `tagents-knowledge` stays one release as a shim that names `okb`. The workspace version is 0.9.0.

## Capabilities

### Modified Capabilities

- `knowledge`: the program is `okb`; the files it finds are the same in A and move to its own directory in B.
- `rust-knowledge`: `okb` serves every verb; the parity suite compares the command line verbs too.
- `core-front-door`: `knowledge` words are okb's.
- `claude-code-plugin`: the launcher path, the `okb` and `tagents-knowledge` wrappers, the second plugin and the dependency.
- `plugin-contract`: the okb description is a checked file; the generator knows two plugins.
- `configuration`: okb's config directory.
