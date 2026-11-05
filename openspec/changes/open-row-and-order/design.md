## Context

The list is two awks and a `sort` (`list()` in `lib/tagents/list.sh`). A row record has fifteen tab-separated fields, the sort keys are its first fields, and the second awk draws the tree and counts the states. The cockpit keeps the window on screen in the global tmux option `@tagents_viewport_window`, which `follow()` sets and the cockpit unsets when it ends. The refresher reloads the list only when a snapshot of tmux or a watched file differs from the last one.

## Decision: the open session is marked in the row

The row of the window on screen gets a `▸` in the slot the tree already gives each row, and turns bold. `collect` adds a flag to its `W` record (tmux works it out inside the `list-windows` call that already runs), the two row kinds that can be on screen print a sixteenth field, and the second awk reads it. A header prints fifteen fields, reads as not shown, and is never marked, though it stands in for a row that may be.

The `▸` (U+25B8) has the width of the dash it replaces, no emoji form (unlike `▶`), and is not the `▾` of a header, which the tally looks for, so no column moves and the count of the status bar is the same with and without the mark. A window that holds two chats marks both, because both are on screen. A child is marked only when it has a pane of its own in that window.

To move with the viewport, `REFRESH_SNAP_FMT` carries `@tagents_viewport_window`, and `follow()` rings the event channel after it sets the option, so that the refresher wakes and sees the difference. The refresher's limit of one reload per `TA_REFRESH_MIN` stands. On a fresh cockpit the option is already set by the first `follow()`, which a check pins, so nothing is set where the viewport starts.

Rejected: making fzf's pointer stick (`--track --id-nth`). It needs a recent fzf, a header and its stand-in row share a key, and the pointer still moves when the person browses, so it could never say which session is open.

## Decision: the stable order is the window number, as a toggle

`ctrl-o` flips the marker file `.order-window` in the state directory, like `.flat`, and rings the event channel. With the marker present the sort keys stay as they are and two of the fields change for rows that are not closed. Field 4 is 0 for a chat and a dimmed window alike, so a dimmed window sits at its number among the chats and a chat that exits keeps the place of the rest. Field 5 is the window number times 1000 plus the pane index, and a child takes the key of its parent so that the family stays one block. A row with no window ties at the end of its group and the row key keeps it where it was. In a flat list the session is added to the key, since the groups are not there to keep the sessions apart. Closed rows keep their own field 4 and their age, and the order of the groups does not change.

The window number is what the tabs of the viewport's status line show, so it can be learned, and it needs no state beyond the marker. The default stays the last message, as the spec has it.

Rejected: the window id (it is not visible anywhere, so it cannot be learned) and a manual order (a persisted order file, two more keys, rules for new rows). A manual order can follow if the number proves not enough. tmux has no window creation time.
