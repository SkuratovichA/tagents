# Changelog

All notable changes to tagents are listed here. The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).

A version here is a release of `tagents-core`: the tag `v<version>`, where the version is the workspace version in `Cargo.toml` ([How a release is made](docs/architecture/rust-core.md#how-a-release-is-made)). The plugin's version in `.claude-plugin/plugin.json` moves with the generated contract and is not a release. An installed copy follows `main`, so it can be ahead of the last release; `[Unreleased]` lists what `main` holds beyond it. What tagents does is specified in `openspec/specs/`, not here.

## [Unreleased]

### Added

- `tagents --version` (and `-V`) prints the workspace version and the short commit of the copy ([#54](https://github.com/SkuratovichA/tagents/pull/54)).
- `tagents-core knowledge mcp`, `knowledge serve` and `knowledge join` are the knowledge MCP server, its shared daemon and the relay a session runs in front of it, in the Rust binary: the same six tools, index and usage store as the node server, with a session that costs a relay and not a node process; a differential suite compares every answer with the node server's, and the other `knowledge` verbs stay with the node CLI ([#60](https://github.com/SkuratovichA/tagents/pull/60)).
- A session's knowledge server is the Rust binary when it is installed: `knowledge-mcp` probes `tagents-knowledge join` and becomes it, so the session joins one shared daemon with no node and no `nc` (this needs the plugin updated to 0.16.1, which carries the new launcher), and the node server stays as the way out when there is no binary or it fails ([#62](https://github.com/SkuratovichA/tagents/pull/62)).
- `tusage` is a report in a terminal: `--by` tables of dollars nested by account, project, session, day, week, month, hour, agent, model and workflow, `--account` and `--project` filters, sessions shown by the name they have in tagents, one session by day with `--session <name> --by day,model`, tables that fit the terminal width, and a summary with dollars and the week by account ([#52](https://github.com/SkuratovichA/tagents/pull/52)).
- `tagents setup` registers the state hook and the status line in `settings.json`, and the installer runs it ([#36](https://github.com/SkuratovichA/tagents/pull/36)).
- `tagents-core mcp`, the plugin's MCP server, runs in the prebuilt Rust binary when the installer has put one on the machine ([#38](https://github.com/SkuratovichA/tagents/pull/38)).
- The site's icons and link preview draw the pixel sprite of its hero ([#41](https://github.com/SkuratovichA/tagents/pull/41)).
- The notification service runs in the prebuilt Rust binary under the LaunchAgent when the installer has put one on the machine, and node stays the fallback ([#49](https://github.com/SkuratovichA/tagents/pull/49)).
- `tagents-core plugin add` and `plugin remove` run in the prebuilt Rust binary when the installer has put one on the machine, and every call it cannot prove identical to node's goes to node ([#50](https://github.com/SkuratovichA/tagents/pull/50)).
- `tagents-core plugin new` and `doctor` run in the prebuilt Rust binary when the installer has put one on the machine, and node stays the fallback ([#53](https://github.com/SkuratovichA/tagents/pull/53)).
- `tagents-core session open`, `session list` and `session last` run in the prebuilt Rust binary when the installer has put one on the machine, and node stays the fallback ([#58](https://github.com/SkuratovichA/tagents/pull/58)).
- `tagents-core session prompt` runs in the prebuilt Rust binary when the installer has put one on the machine, and node stays the fallback ([#61](https://github.com/SkuratovichA/tagents/pull/61)).
- `tagents-core session abort` runs in the prebuilt Rust binary when the installer has put one on the machine, and node stays the fallback ([#63](https://github.com/SkuratovichA/tagents/pull/63)).
- `tagents-core` answers every call of `session`, `sessions`, `doctor`, `plugin add`, `plugin remove`, `plugin new` and `notify run` itself and starts the node CLI only for `plugin list`, a bare `plugin` and words it does not serve: a reference it cannot hold is `no session matches`, a TOML refusal keeps node's frame with the Rust parser's words, a failed notify start is logged and exits 1, and `tagents-core`, `help`, `--help` and `-h` print the usage line ([#67](https://github.com/SkuratovichA/tagents/pull/67)).

### Removed

- YAML config files are no longer read, and the `config convert` verb is gone with them: `config.toml`, `config.<host>.toml` and `plugins/<name>.toml` are the only config files, so a machine that has only `config.yaml` has no configuration until it is converted by hand ([#37](https://github.com/SkuratovichA/tagents/pull/37)).

### Fixed

- After `/compact` the dashboard's context column shows what the compaction left, and the next answer raises it.
- The installer no longer prints curl's `404` above its own `no prebuilt tagents-core` line; any other download failure still shows curl's message ([#54](https://github.com/SkuratovichA/tagents/pull/54)).
- On tmux below 3.8 the cursor no longer jumps around the cockpit's viewport at every frame of an agent; tmux 3.8 or newer keeps it steady ([#55](https://github.com/SkuratovichA/tagents/pull/55)).
- The Rust MCP server writes the integer keys of a program's JSON output first and in ascending order, as `JSON.stringify` and the node server do.
- A knowledge MCP server whose input ends exits with 0, where node ended it with exit 13 and a warning about an unsettled await. A shared daemon started with an `--idle` longer than a timer counts (2147484 seconds or more) no longer leaves after a millisecond: the node one clamps it to the longest timer, 2^31 - 1 ms (about 24.8 days), and the Rust one waits the whole time.
- An edit of the file a symlinked `plugins/notify.toml` points at takes effect at the next event in the options directory every time, where on macOS it sometimes took effect at once, and the node and Rust services follow the same rule ([#49](https://github.com/SkuratovichA/tagents/pull/49)).
- `plugin add` and `plugin remove` keep a symlinked `config.toml` a symlink and edit the file it points at, where they replaced the link with a regular file ([#50](https://github.com/SkuratovichA/tagents/pull/50)).
- `plugin add` and `plugin remove` stop with the error when `config.toml` cannot be read for any reason but being absent, where they treated it as empty and wrote a config over what could not be read ([#50](https://github.com/SkuratovichA/tagents/pull/50)).
- A knowledge document with CRLF line endings keeps its last front-matter value as written, where the carriage return of the line break stayed on it: the title of such a file no longer ends with `\r` in the index and in the search results ([#51](https://github.com/SkuratovichA/tagents/pull/51)).
- The output of the Claude child of a headless session is decoded as a stream, so a character whose bytes arrive in two reads is one character in the outcome's text and detail, where it was two replacement characters ([#58](https://github.com/SkuratovichA/tagents/pull/58)).
- A name given with `tagents --label <pane id>` lands on the agent's session, so the row and the `ctrl-r` dialog show it where they stayed on the older name or the pane title, and clearing a name goes back to the title where a label left under the pane came back ([#66](https://github.com/SkuratovichA/tagents/pull/66)).

## [0.1.0] - 2026-10-29

The first release. It ships the prebuilt `tagents-core` for `aarch64-apple-darwin`, `x86_64-apple-darwin` and `x86_64-unknown-linux-musl`, each with a SHA-256 sum that `install.sh` checks.

### Added

- `install.sh` keeps one managed copy on `main`, and `tagents update` moves it ([#9](https://github.com/SkuratovichA/tagents/pull/9)).
- A cockpit layout for the dashboard: the list stays put and a viewport shows the selected window ([#19](https://github.com/SkuratovichA/tagents/pull/19)).
- A row is a tmux window and a group is a tmux session; every session is a group, `ctrl-a` opens a shell in it and `ctrl-x` closes any window, plain ones included ([#11](https://github.com/SkuratovichA/tagents/pull/11), [#13](https://github.com/SkuratovichA/tagents/pull/13), [#16](https://github.com/SkuratovichA/tagents/pull/16)).
- Reading and writing Open Knowledge Format (OKF v0.2) bundles, and a usage store that counts reads, reported by `usage` and `knowledge_usage` ([#12](https://github.com/SkuratovichA/tagents/pull/12), [#15](https://github.com/SkuratovichA/tagents/pull/15)).
- Config in `config.toml`, with a converter from the older file and a JSON Schema ([#31](https://github.com/SkuratovichA/tagents/pull/31)).
- A Rust front door for `tagents-core` that serves `sessions` and hands every other word to the node CLI ([#32](https://github.com/SkuratovichA/tagents/pull/32)).
- Claude Code plugin tools for notifications, Claude sessions and tmux windows, generated from the CLI specs ([#30](https://github.com/SkuratovichA/tagents/pull/30)).
- The prebuilt `tagents-core` reaches a managed install, with its checksum and archive checked before it is used ([#34](https://github.com/SkuratovichA/tagents/pull/34)).
- A one-page site at `/` and the documentation under `/docs/`, published as one Pages deployment ([#29](https://github.com/SkuratovichA/tagents/pull/29), [#33](https://github.com/SkuratovichA/tagents/pull/33)).
- The MIT license text ([#26](https://github.com/SkuratovichA/tagents/pull/26)).

### Changed

- The cockpit is the only dashboard layout; `ctrl-g` goes to the agent, `$` says when usage is off, and the columns fit what is in them ([#25](https://github.com/SkuratovichA/tagents/pull/25)).
- The README is shorter, with demos, and the documentation has a site of its own ([#21](https://github.com/SkuratovichA/tagents/pull/21)).
- The README says what tagents is for and describes the Claude Code plugin ([#20](https://github.com/SkuratovichA/tagents/pull/20)).

### Fixed

- The per-machine config overlay is found under every name the machine has ([#1](https://github.com/SkuratovichA/tagents/pull/1)).
- `tusage` reports the newest main-chain context, so it drops after a compaction ([#3](https://github.com/SkuratovichA/tagents/pull/3)).
- The previous version's tmux verbs answer 0 instead of "returned 2" ([#14](https://github.com/SkuratovichA/tagents/pull/14)).
- The timeline takes its width from the controlling terminal, and an unhooked session can be saved ([#22](https://github.com/SkuratovichA/tagents/pull/22)).
- The cockpit's viewport client gets a terminal descriptor of its own ([#23](https://github.com/SkuratovichA/tagents/pull/23)).
- An empty week in `tusage` is no division by zero, and a catch-up is fast, reports how far it got and never leaves its lock ([#24](https://github.com/SkuratovichA/tagents/pull/24)).
- Node is pinned in the node commands, the sidebar list starts in the home directory, and an update is handed over to the new installer ([#18](https://github.com/SkuratovichA/tagents/pull/18)).

[Unreleased]: https://github.com/SkuratovichA/tagents/compare/v0.1.0...main
[0.1.0]: https://github.com/SkuratovichA/tagents/releases/tag/v0.1.0
