## Context

`write_wrapper` in `install.sh` writes each command in `~/.local/bin` as a small `sh` script that execs one file. The two node CLIs get `exec node "<cli>" "$@"`, so they find node on the caller's `PATH`. On the machine where this failed, node lives only under nvm (`~/.nvm/versions/node/<version>/bin`), which a process sees only when a shell that loaded nvm is among its ancestors; a chat that tagents starts from tmux gets the tmux server's global `PATH` instead. `start_sidebar` in `lib/tagents/sidebar.sh` creates the list's pane with `tmux split-window` and no `-c`, so the pane starts in the directory of the process that ran `--ensure-dash` or `--follow`.

## Goals / Non-Goals

**Goals:**

- The node commands work for a caller whose `PATH` holds no node, for as long as the node they were installed with exists.
- A list started as the sidebar keeps no directory in use but the home directory.

**Non-Goals:**

- Giving node to chats some other way, such as exporting nvm's directory into the tmux server's global environment.
- `tagents`, `tusage` and `tnotes`, which are bash scripts and need no node.
- The working directory of the popup list, or of a list the owner starts by hand in a pane of their own.

## Decisions

**Pin the path the installer found, as found.** `install_commands` takes `command -v node` from the installing shell, the node `need_toolchain` has just checked, and writes it into the wrapper. The path is not resolved through symlinks: nvm's path is a real file per version, and a Homebrew path such as `/opt/homebrew/bin/node` is a symlink that survives `brew upgrade` while its target does not. Rejected: exporting nvm's directory into the tmux server's environment, which fixes only chats tagents starts and only on servers started after the change; sourcing `nvm.sh` in the wrapper, which slows every call, ties the wrappers to nvm, and still fails when nvm's default alias names a version that is not installed, the cause on 23.10.2026.

**Fall back to `node` on `PATH` when the pinned file is gone.** The wrapper tests `[ -x "$n" ]` and otherwise runs `node`, so uninstalling the pinned version leaves the commands working wherever node is on `PATH`, as they did before this change, until the next update pins them again. When `command -v node` prints nothing or a path that is not absolute (no node on the installing shell's `PATH`, which only a `TAGENTS_BUILD_CMD` override lets an install get past), the wrapper is written as before, `exec node "<file>" "$@"`.

**Only an interpreter given by its absolute path is pinned.** `write_wrapper` also writes the hook wrappers, whose interpreter is `sh`, and the bash commands, which have none. The pinned form, with its fallback to the interpreter's file name on `PATH`, is written only when the interpreter is an absolute path, so those wrappers keep their one-line form and nothing in `write_wrapper` names node.

**Start the list's pane with `-c "$HOME"`.** One flag on the one `split-window` that creates a list. Every way a sidebar list is started (`--ensure-dash`, and `--follow` when a window switch brings the sidebar back) goes through `start_sidebar`, and a pane moved with `join-pane` keeps its process and therefore its directory, so moving needs nothing.

## Risks / Trade-offs

- [The pinned node is older than the one on `PATH`] → the commands run the node of the last install or update; `tagents update` from a shell with the newer node pins that one, and the daily LaunchAgent runs with the `PATH` of the shell that installed it.
- [The node wrappers now hold one line of logic, against the comment "Wrappers carry no logic"] → the comment says what that line does.

## Migration Plan

After the merge, `tagents update` rewrites the two wrappers, and the sidebar runs in `$HOME` from its next restart. Rolling back is a revert and another `tagents update`, which writes the old wrappers back.
