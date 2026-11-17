## Why

After a window switch in the viewport the list's `▸` and cursor took seconds to move. The first full load after the switch drew the mark from `@tagents_viewport_window`, which `--follow` writes later, so it showed the old window; `--follow`'s own ring then waited behind the refresher's one-second read and the two-second throttle; and `cursor_to_window` ran a second full `--list` of its own (about half a second) before it posted the cursor.

## What Changes

- Every list the dashboard loads itself (the first load, the refresher's reload and a key's reload) is run with `TA_KEEP_ROWS=1` and leaves `.rows.kept` in the state directory, written atomically: one line per row with the row's window, whether it can carry the mark, the row without the mark and the row with it. A `--list` run by anything else writes nothing.
- `--follow` posts one action to the dashboard's list that reloads from the kept rows with the mark on the new window's rows and moves the cursor to the row `cursor_to_window` would choose, with no start of tagents and no second `--list`. With no kept rows, or none for the window, it moves the cursor as before. The post goes out before `@tagents_viewport_window` is written, so a load that starts after the write is not cut by the repaint.
- A full `--list` reads the window of the viewport's client in the same tmux call that lists the windows, so one that starts between the switch and `--follow` already marks the new window; the option is used when there is no viewport client.
- The start of a cockpit does not record a viewport that shows the dashboard's own session, and repaints the list onto the viewport's window when the dashboard has kept rows by then.
- The refresher's one-second second look and the throttle are unchanged.

## Impact

- Specs: `dashboard-list` (the mark is derived from the viewport's client; the rows the dashboard keeps), `refresher` (the reload it posts keeps the rows), `window-rows` (the cursor follows at once, from the kept rows).
- Code: `lib/tagents/list.sh`, `state.sh`, `follow.sh`, `cockpit.sh`, `dash.sh`, `keys.sh`, `closed.sh`, `columns.sh`, `refresh.sh`.
- Tests: `tests/ui.sh`, `tests/window-rows.sh`, `tests/cockpit.sh`, `tests/resurrect.sh`, `tests/refresh.sh`, `tests/forks.sh`.
- Docs: `CHANGELOG.md`, `lib/tagents/README.md`, `docs/`.
