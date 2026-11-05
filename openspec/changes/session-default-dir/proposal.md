## Why

`ctrl-n` and `ctrl-p` lift the directory of the row under the cursor to its repository root, so an agent for a package of a monorepo, or for a directory that is no repository at all, can never be started where the person works. Sessions are how people group their work, but nothing lets a session say where its agents belong.

## What Changes

- `ctrl-d` (verb `dir`, `keys.dir` in the config) asks for a directory and saves it for the tmux session of the row under the cursor. `.` takes the directory of the row, `-` forgets it, an empty line cancels.
- With a directory saved, `ctrl-n` and `ctrl-p` on any row of that session start the agent exactly there, with no lift to the repository root. With none saved, or when it is gone from disk, they work as before.
- The header of a session shows the saved path in the normal colour, where the path tmux reports stays dim.
- `tagents --new`, `--window`, the MCP tools, `ctrl-a` and a resumed chat do not read it.

## Impact

- Specs: `chat-launch` gets one ADDED requirement and one MODIFIED, `dashboard-keys` two MODIFIED, `dashboard-list` one MODIFIED.
- Code: `lib/tagents/launch.sh`, `actions.sh`, `state.sh`, `list.sh`, `refresh.sh`, `keys.sh`, `dash.sh`, `tagents`.
- Config: `keys.dir`, in the schema and in `config.example.toml`.
- State: `session-dirs.tsv` in the state directory.
