## Context

`ctrl-n` and `ctrl-p` end in `new_agent` and `new_agent_pick` (`lib/tagents/launch.sh`), which lift the directory of the row to its repository root. The tmux session a row belongs to is known to the action (`row_session`), and the list already reads one awk's worth of tmux sessions in `collect`.

## Decision: the directory is saved per session name, in a TSV beside the labels

`session-dirs.tsv` in the state directory holds one `session<TAB>dir` line per session, written through a temporary file and followed by a ring of the event channel, as `labels.tsv` is. `refresh_changed` watches the file, so a header redraws at once.

The `act` branches `new` and `pick` ask `session_dir` for the row's session. It prints the directory only when it is saved and still a directory on disk; then they call `new_agent` and `new_agent_pick` with a trailing `exact` argument, which skips the lift. Nothing saved, a directory that is gone, and a row with no session (a headless row, a closed row) take the old path, so with no file the behaviour is what it was.

Only the two list keys read it. `--new`, `--window`, the MCP tools and a resumed chat call the same launch functions without `exact` and without a lookup, and `ctrl-a` asks the row, not the session.

The dialog reads one line with `read -e`, so that `Tab` completes a path. The answer goes through `cfg_expand_dir` and `abs_dir`, so `~` and relative names work and a symlink is stored as its physical path. A name that is no directory is refused with a message and the file is left as it was.

The header path comes from the awk that already lists the sessions: it reads the file in a `BEGIN` block and prints the saved directory as a fourth field, which the list draws in place of tmux's path and in the normal colour. No process is added, and `tests/forks.sh` pins that the number of awk does not grow with the lines of the file.

Rejected: keying by session id (`$1`, `#{session_id}`) because a tmux server restart, or a session recreated by a script, hands out new ids while the name is what the person recognises. Rejected: a tmux session option (`@tagents_dir`), which dies with the server.

## Limits

- A renamed session loses its directory, since the key is the name.
- A closed row has no session, so `ctrl-d` on it only says so; so does a headless row.
- A window made by hand with `prefix c` does not go through tagents and does not read it.
- The awk cannot test a directory, so the header keeps showing a saved path that was removed from disk while `ctrl-n` falls back to the row's directory.
- A tab or a newline inside a saved path would corrupt the file; the dialog does not guard against it, since neither can be typed into it.
