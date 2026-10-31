# Changelog

All notable changes to tagents are listed here. The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).

A version here is a release of `tagents-core`: the tag `v<version>`, where the version is the workspace version in `Cargo.toml` ([How a release is made](docs/architecture/rust-core.md#how-a-release-is-made)). The plugin's version in `.claude-plugin/plugin.json` moves with the generated contract and is not a release. An installed copy follows `main`, so it can be ahead of the last release; `[Unreleased]` lists what `main` holds beyond it. What tagents does is specified in `openspec/specs/`, not here.

## [Unreleased]

### Added

- `tagents setup` registers the state hook and the status line in `settings.json`, and the installer runs it (#36).
- `tagents-core mcp`, the plugin's MCP server, runs in the prebuilt Rust binary when the installer has put one on the machine (#38).
- The site's icons and link preview draw the pixel sprite of its hero (#41).
- Groundwork in Rust for the notify daemon: the child, the ending and a file watch; nothing a user runs changes yet (#43).

### Removed

- YAML config files are no longer read, and the `config convert` verb is gone with them: `config.toml`, `config.<host>.toml` and `plugins/<name>.toml` are the only config files, so a machine that has only `config.yaml` has no configuration until it is converted by hand (#37).

## [0.1.0] - 2026-10-29

The first release. It ships the prebuilt `tagents-core` for `aarch64-apple-darwin`, `x86_64-apple-darwin` and `x86_64-unknown-linux-musl`, each with a SHA-256 sum that `install.sh` checks.

### Added

- `install.sh` keeps one managed copy on `main`, and `tagents update` moves it (#9).
- A cockpit layout for the dashboard: the list stays put and a viewport shows the selected window (#19).
- A row is a tmux window and a group is a tmux session; every session is a group, `ctrl-a` opens a shell in it and `ctrl-x` closes any window, plain ones included (#11, #13, #16).
- Reading and writing Open Knowledge Format (OKF v0.2) bundles, and a usage store that counts reads, reported by `usage` and `knowledge_usage` (#12, #15).
- Config in `config.toml`, with a converter from the older file and a JSON Schema (#31).
- A Rust front door for `tagents-core` that serves `sessions` and hands every other word to the node CLI (#32).
- Claude Code plugin tools for notifications, Claude sessions and tmux windows, generated from the CLI specs (#30).
- The prebuilt `tagents-core` reaches a managed install, with its checksum and archive checked before it is used (#34).
- A one-page site at `/` and the documentation under `/docs/`, published as one Pages deployment (#29, #33).
- The MIT license text (#26).

### Changed

- The cockpit is the only dashboard layout; `ctrl-g` goes to the agent, `$` says when usage is off, and the columns fit what is in them (#25).
- The README is shorter, with demos, and the documentation has a site of its own (#21).
- The README says what tagents is for and describes the Claude Code plugin (#20).
- Behaviour is specified in OpenSpec specs, which replace the dated changelog this repository kept before (#8, #10, #17).

### Fixed

- The per-machine config overlay is found under every name the machine has (#1).
- `tusage` reports the newest main-chain context, so it drops after a compaction (#3).
- The previous version's tmux verbs answer 0 instead of "returned 2" (#14).
- The timeline takes its width from the controlling terminal, and an unhooked session can be saved (#22).
- The cockpit's viewport client gets a terminal descriptor of its own, and suites clean up what they start (#23).
- An empty week in `tusage` is no division by zero, and a catch-up is fast, reports how far it got and never leaves its lock (#24).
- Node is pinned in the node commands, the sidebar list starts in the home directory, and an update is handed over to the new installer (#18).

[Unreleased]: https://github.com/SkuratovichA/tagents/compare/v0.1.0...main
[0.1.0]: https://github.com/SkuratovichA/tagents/releases/tag/v0.1.0
