## 1. The node commands pin the node that installed them

- [x] 1.1 In `install.sh`, make `write_wrapper` write, when its interpreter is an absolute path, a wrapper that sets `n` to that path, sets it to the path's file name when `[ -x "$n" ]` fails, and runs `exec "$n" "<file>" "$@"`, and keep the one-line form for every other wrapper (the hooks' `sh`, the bash commands); make `install_commands` pass the path `command -v node` prints, or `node` when that is empty or not absolute; rewrite the comment above `write_wrapper` and the header lines that show `exec node`. Proved by `tests/install.sh`, whose hook-wrapper checks stay green.
- [x] 1.2 In `tests/install.sh`, make the check "the node CLIs go through node" independent of the node on the test machine, and add a section proving that a stub `node` first on the installing `PATH` is written into both node commands, that the installed `tagents-core` runs it when called with `PATH=/usr/bin:/bin`, that `tagents-knowledge` runs a second stub found on the caller's `PATH` once the first is removed, that an install from a shell finding the second stub pins that one, and that an install from a shell finding no node writes wrappers that look node up on the caller's `PATH`. Proved by `tests/install.sh`.
- [x] 1.3 Add a `LEARNING.md` entry: `exec node` in the wrappers failed in a chat whose `PATH` had no node, and the wrappers now pin the node that installed them. Proved by the diff of `LEARNING.md`.

## 2. A list started as the sidebar runs in the home directory

- [x] 2.1 In `start_sidebar` (`lib/tagents/sidebar.sh`), pass `-c "$HOME"` to the `split-window` that creates the list's pane. Proved by `tests/window-rows.sh`.
- [x] 2.2 In `tests/window-rows.sh`, run the first `--ensure-dash` of R33 from `$REPO` and check that the new list's `#{pane_current_path}` is the physical home directory, and check the same for the list the follow hook brings back in F22. Proved by `tests/window-rows.sh`.
- [x] 2.3 Add a `LEARNING.md` entry: a list started with `split-window` and no `-c` kept the caller's directory, a worktree, in use, and the list's pane now starts in `$HOME`. Proved by the diff of `LEARNING.md`.

## 3. The whole tree

- [x] 3.1 Add a `LEARNING.md` entry for the suite count: `tests/scratch-guard.sh` is a helper the tmux suites source, so `tests/` holds 21 suites, not 22. Proved by the diff of `LEARNING.md`.
- [x] 3.2 Run every suite under `tests/` on its own scratch tmux server with the live server's global hook count the same before and after, and run `pnpm spec:check` and `pnpm plugin:check`. Proved by the run's summary and the two exit codes.

## Workflow follow-up

- Archive the change inside the branch before the pull request is merged.
- After the merge: `tagents update`, the plugin update in both Claude config stores, and a sidebar restart.
