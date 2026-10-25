## Why

The cockpit's viewport can freeze the whole tmux server it runs in. Its client is started in the viewport pane with the pane's own stdin, stdout and stderr, and the server writes to a client through a dup of that client's stdin, so the server's write end is the same open file description that every other process in the pane holds. Every tmux client sets its stdin, stdout and stderr back to blocking when it exits, and the viewport's watcher runs tmux there: the `split-window` that brings a killed list back has stdout on the pane. After it the server's write end is blocking, and the server is also the only reader of that pane, so its next write larger than the terminal's buffer never returns. Every other client of the server then spins at 100% CPU: four of them ran for close to an hour on 25.10.2026, and section 17b of `tests/resurrect.sh` froze its scratch server on every run.

A suite killed before its EXIT trap runs leaves its tmux server and clients behind, and that is how the frozen test servers stayed.

## What Changes

- `tagents --viewport` starts its client with stdin, stdout and stderr on one read-write open of the pane's terminal by path, so the descriptor the server writes through belongs to that client alone.
- `tests/scratch-guard.sh` tags every suite run with `TA_SUITE_RUN` and starts a reaper that kills whatever tmux process still carries the tag once the suite has ended, however it ended.

## Impact

- Affected specs: `cockpit`.
- Affected code: `lib/tagents/cockpit.sh` (`viewport`), `tests/scratch-guard.sh`, `tests/cockpit.sh`.
