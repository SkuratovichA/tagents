## Why

On 23.10.2026 the knowledge MCP server failed to connect in a chat that tagents had started from tmux: the chat's `PATH` held no node, and `tagents-knowledge` runs `exec node …`, so it died with `exec: node: not found`. The same day a sidebar list restarted from inside a worktree kept that worktree in use, and it had to be restarted again from the home directory before the worktree could be removed. Both come from a process inheriting something from whoever started it: the node commands take node from the caller's `PATH`, and the list takes the caller's working directory.

## What Changes

- `install.sh` writes the absolute path of the node it found on the installing shell's `PATH` into `tagents-core` and `tagents-knowledge`. The two commands run that node, fall back to `node` on the caller's `PATH` when the file is gone, and are pinned again by every install and every `tagents update`.
- A list tagents starts as the sidebar runs in the home directory, whether `--ensure-dash` started it or a window switch brought the sidebar back, whatever directory the caller was in.
- `LEARNING.md` records both, and the miscount of the suites (`tests/scratch-guard.sh` is a helper the tmux suites source, so there are 21 suites, not 22).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `claude-code-plugin`: the node commands the installer writes run with the node that installed them, and fall back to the one on `PATH`.
- `window-rows`: a list started as the sidebar runs in the home directory.

## Impact

- `install.sh` (`write_wrapper`, `install_commands` and the header comment) and `tests/install.sh`.
- `lib/tagents/sidebar.sh` (`start_sidebar`) and `tests/window-rows.sh`.
- `LEARNING.md`.
- The live install: after the merge `tagents update` rewrites the two wrappers in `~/.local/bin`, and the sidebar runs in `$HOME` once it is restarted with the new code.
