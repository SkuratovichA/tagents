# Proposal

## Why

The owner asked for only the cockpit layout to stay and the other layouts to go. The follow layout, in which one list pane travels into whichever window is on screen, needed a pane mover with a lock, a width memory, a zoom guard, a wish flag and a start-again path, and every selection, kill and restore had to know which layout it was in. Alongside it, `ctrl-g` only did what `enter` does, `$` with usage off returned without a word, and the list's columns came from a table of widths per breakpoint that dropped whole columns on a machine that had nothing to put in them.

## What Changes

- The cockpit is the only layout. The config key `dashboard.layout` is gone and its `--check` line with it; a file that still carries it is read like any key this version does not read. `tagents` and `tagents --ensure-dash` run in any pane make or reuse the cockpit and switch that client to it, and no list pane ever lives in or moves into a user's window.
- The follow layout and everything that existed only for it are deleted: moving the list between windows, `TA_WIDTH` as a left-edge width, restoring window widths, the zoom guard, the wish for a list, the start of a list in a user's window, and the move out of a window before `ctrl-x` kills it.
- `tagents --follow` and its two hooks stay with one job: they move the list's cursor onto the row of the window the viewport shows, and do nothing when no cockpit is up.
- The popup stays. `enter` in it brings the cockpit up when it is not, points the viewport at the agent's window and takes the popup's terminal to the session `tagents`.
- `ctrl-g` takes the terminal itself to where the agent lives: the most recently active terminal that is not the viewport's goes to the agent's own session, window and pane, and so leaves the dashboard. On a header it goes to the session's own selected window. A gone window and a missing terminal each have a message, and a closed row still only says that `enter` resumes it. `tagents --goto`, the notification click, is unchanged.
- The header's `enter` label reads `open in dashboard` instead of `open in sidebar`.
- `$` with `usage.watch` unset shows `tagents: usage is off — set usage.watch to the profile to track`.
- The list's columns are as wide as what is in them. They are let in one at a time (context, cost, state word, the project of a flat row, location, model, account), a column with nothing to say takes no room, the figure columns keep their width, and the state word yields to the longest name.
- The restore rebuilds a leftover cockpit session in place before it restores the dashboard. The dashboard's own window is never named, and the session `tagents` is never a group, so a session holding only the list no longer exists.

## Capabilities

### Modified Capabilities
- `cockpit`: the only layout; no layout key; the taken-name message; selections from anywhere point the viewport.
- `window-rows`: everything that moved the list is removed; selecting a row shows its window; the follow hooks move the cursor.
- `configuration`: `dashboard.layout` leaves the keys the file carries and its `--check` line is removed.
- `resurrect`: the `D` row and the restore speak of the dashboard; the sweep of leftover shells stays for layouts saved by an earlier version.
- `window-names`: the dashboard's own window is never named.
- `dashboard-list`: content-fit columns; no header-alone group.
- `dashboard-popup`, `dashboard-keys`, `usage-display`, `chat-launch`, `notes-workspace`, `status-bar-tally`, `refresher`: wording that named the travelling list, plus the `ctrl-g` and `$` behaviour.

## Impact

- Code: `tagents`, `lib/tagents/cockpit.sh`, `follow.sh`, `sidebar.sh`, `rows.sh`, `actions.sh`, `dash.sh`, `list.sh`, `usage.sh`, `config.sh`, `resurrect.sh`, `migrate.sh`, `launch.sh`.
- Config: `dashboard.layout` is no longer read.
- Docs: `docs/guide/dashboard.md`, `docs/guide/accounts.md` and the other guide pages that described the travelling list.
