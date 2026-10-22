## Why

A row in the sidebar is a single chat pane today: enter swaps it into a seat beside the sidebar, and anything else the user wants beside that chat (a shell, a dev server, a log tail) has nowhere to live, because the seat window belongs to whichever chat is docked. The owner wants each row to be a place, as herdr's tabs are: a chat plus the terminals opened next to it, which disappear when another row is selected and come back with it. Herdr's model (workspace, tab, pane) maps onto tmux one to one (session, window, pane), so tagents can get it by letting each row be the chat's own tmux window and each group be a tmux session, and by moving the one sidebar pane into whichever window is on screen.

## What Changes

- **BREAKING** A row is a tmux window. A chat row is still keyed on its chat pane's id, which `--act` takes; a dimmed row is keyed on its window id. The chat is the window's first pane; every other pane in it belongs to the user, and tagents never moves, kills or marks it.
- Closed and headless rows, which have no window, are listed in a trailing group after the session groups.
- **BREAKING** A group is a tmux session. Rows are grouped by the session their window is in, not by working directory; a new chat opens as a new window in the session of the group the cursor is in.
- Selecting a row moves the sidebar pane into that row's window as its leftmost full-height pane and switches the client there. Selecting a group header switches to that session's last-used window the same way.
- The sidebar follows the user: tmux's own window and session switches (`prefix+n`, `prefix+s`, a mouse click on the status bar) move the sidebar into the window now on screen, through the `session-window-changed` and `client-session-changed` hooks running `tagents --follow`.
- Windows of a tagents session that run no chat (an editor, a plain shell) are listed as dimmed rows with no state, age or cost.
- ctrl-s joins the chosen row's chat pane into the current window as a split; ctrl-u sends a joined chat back to a new window of its own session.
- **BREAKING** Seats, placeholders and swap docking are removed: `dock.sh`, `seats.sh`, the `@tagents_slot`, `@tagents_parked`, `@tagents_docked` and `@tagents_seat` options, the seat listing verb and the `agents:1` dashboard window.
- tnotes no longer parks its editor in `ta-notes`: the editor is an ordinary split of the chat's window, hidden and shown by switching rows like every other pane.
- Resurrect drops the docked field: a chat's recorded session and window are its real home. Extra panes come back through tmux-resurrect as idle shells in their working directory.

## Capabilities

### New Capabilities
- `window-rows`: what a row and a group are, how selecting them moves the sidebar and the client, the follow hooks, joined chats, and the sidebar's width.

### Modified Capabilities
- `dashboard-list`: grouping by tmux session, rows keyed on windows, dimmed non-chat rows, no docked marks.
- `dashboard-keys`: enter, ctrl-s, ctrl-g and ctrl-u in terms of windows instead of seats; ctrl-o (borrow a window into the dashboard session) is removed, because a window in two sessions breaks "a group is a session".
- `notes-workspace`: the editor is a split of the chat's window; parking in `ta-notes` and sync on focus are removed.
- `resurrect`: no docked field, and the home session and window are where the chat is.
- `seats-and-docking`: removed in full; what survives (the sidebar is never closed, ctrl-x never kills it) moves to `window-rows`.
- `refresher`: the seat checks, the seat cursor and `--poke` are removed, because no seat is left to wake.
- `chat-launch`: a new chat opens as a window in the session of the group the cursor is in.
- `dashboard-popup`, `window-names`, `cli-dispatch`, `closed-sessions`: their seat and dashboard-window wording follows the window model.

## Impact

- Code: `lib/tagents/dock.sh` and `lib/tagents/seats.sh` are deleted; `sidebar.sh`, `actions.sh`, `list.sh`, `state.sh` (`dir_roots`), `resurrect.sh`, `tnotes` and the focus hooks change.
- Tests: `tests/panes.sh` (the seats suite) and the seat sections of `tests/ui.sh` are replaced by `tests/window-rows.sh`; `tests/notes.sh`, `tests/resurrect.sh` and the list sections of `tests/ui.sh` change.
- Users: the `agents` session stops being special; a user who kept chats in it keeps them as rows of an `agents` group. Snapshots written before the change still restore, with the docked field ignored.
