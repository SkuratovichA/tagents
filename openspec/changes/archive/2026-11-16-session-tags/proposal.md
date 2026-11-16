## Why

A session's name often does not hold the ticket key, the repository or the topic of its work, and the dashboard's search matches only the text a row draws. Someone who runs several sessions on different tickets cannot type a ticket key and find the session.

## What Changes

- `tagents --tags`, `--tags-add` and `--tags-set` read and write up to 10 short tags per session, kept in `tags.tsv` in the state directory and keyed by session id.
- The list appends a session's tags, and an upper-case copy of them, to its row behind as many spaces as the list is wide (at least 300), so nothing is drawn and fzf still matches them; the dashboard's fzf gets `--no-hscroll` so a match off screen does not scroll the row sideways.
- The refresher redraws when `tags.tsv` changes, and the preview shows a `tags:` line.
- The state hook drops a session's tags on `SessionEnd` with the reason `clear`, and on no other ending.
- The plugin gets its first hook, `SessionStart`, which tells a session started by hand in a tmux pane its own id and that it can tag itself; the three verbs become the tools `tagents_tags`, `tagents_tags_add` and `tagents_tags_set`.
- The plugin's hook files are added to the shipped files of the digest, so a change to them moves the plugin version.

## Impact

- Specs: new capability `session-tags`; `claude-code-plugin` and `dashboard-list` get MODIFIED requirements.
- Code: `lib/tagents/tags.sh` (new), `lib/tagents/state.sh`, `lib/tagents/list.sh`, `lib/tagents/preview.sh`, `lib/tagents/refresh.sh`, `lib/tagents/dash.sh`, `tagents`, `tagents.cli.json`, `hooks/tmux-agent-state.sh`, `hooks/hooks.json`, `hooks/plugin/session-start.sh`, `packages/contract/src/plugins.ts`.
- Generated: `contract.json`, `skills/tagents/references/`, the version and digest of `.claude-plugin/plugin.json`.
- Tests: `tests/tags.sh` (new), `packages/contract/test/tools.test.ts`.
- Docs: `skills/tagents/SKILL.md`, `docs/guide/dashboard.md`, `docs/guide/states.md`, `docs/guide/claude-code-plugin.md`, `docs/architecture/contract.md`, `lib/tagents/README.md`, `CHANGELOG.md`.
