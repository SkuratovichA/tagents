## ADDED Requirements

### Requirement: A row is a tmux window
The dashboard SHALL show every chat as a row that stands for the tmux window its pane is in. The chat is the window's first pane, not counting the sidebar. A chat joined into another window by `ctrl-s` has a row of its own that stands for the window it is in now. Selecting a row acts on the window, not on the pane alone.

#### Scenario: One chat per window
- **WHEN** a session holds two windows, each running one chat
- **THEN** the list has two chat rows, one for each window, and selecting either one shows its window

#### Scenario: A joined chat points at the window it is in
- **WHEN** chat B is joined into the window of chat A
- **THEN** B has its own row and A keeps its own, and selecting either one shows that one window

### Requirement: A chat row is keyed on its pane and a window row on its window
The list line of a chat row SHALL be keyed on the chat's pane id, so that `tagents --act` and notices keep taking a pane, and the list line of a dimmed window row SHALL be keyed on its window id.

#### Scenario: Keys
- **WHEN** the list holds a chat in pane `%12` and a window `@7` that runs no chat
- **THEN** the line of the chat starts with `%12` and the line of the window starts with `@7`
### Requirement: Panes beside a chat belong to the user
Every pane of a window other than the chat and the sidebar SHALL belong to the user. tagents SHALL NOT move, resize, kill or mark such a pane by selecting rows, following the user, joining or breaking out chats, or killing a chat, and they leave the screen and come back with the window they are in.

#### Scenario: A terminal beside the chat
- **WHEN** the user splits a shell beside chat A, selects chat B's row and then A's row again
- **THEN** the shell is still the same pane of A's window and carries no `@tagents_*` option
- **AND** it was not on screen while B's window was

### Requirement: A group is a tmux session
The list SHALL group rows by the tmux session of their window, and a group header SHALL name the session. A session SHALL be a group when it holds at least one chat or was created by tagents, and a session that is neither (a scratch session in which no chat has run) SHALL stay out of the list. Every window of a group is listed (see the dimmed rows below), whichever directory its panes are in.

#### Scenario: Two sessions
- **WHEN** session `work` holds two chats and session `personal` holds one
- **THEN** the list has a header `work` over two rows and a header `personal` over one

#### Scenario: Directory no longer groups
- **WHEN** two chats of session `work` run in two unrelated directories
- **THEN** both rows are under the header `work`

#### Scenario: A scratch session
- **WHEN** session `scratch` holds one shell and tagents never created it
- **THEN** the list has no header and no row for it

#### Scenario: A session tagents created
- **WHEN** tagents created session `release notes` for a chat and the chat has since exited
- **THEN** the session is still a group and its windows are still listed

### Requirement: A new chat opens in the group the cursor is in
A chat started from the dashboard (`ctrl-n`, `ctrl-p`) SHALL open as a new window, created detached, in the session of the group the cursor is in, and then be selected like any row. When the cursor is on the group `no window`, the chat SHALL open as `chat-launch` says for a chat started with no group.

#### Scenario: Cursor in another group
- **WHEN** the client is in session `work`, the cursor is on a row of session `personal` and the user presses `ctrl-n`
- **THEN** the new chat's window is in `personal` and the sidebar and the client are in it
### Requirement: Selecting a row puts the sidebar and the client in its window
`enter` on a row SHALL move the one sidebar pane into the row's window as its leftmost full-height pane, switch the client to that window, and leave the cursor in the row's chat. The window the sidebar leaves SHALL have none. When the sidebar already is in the row's window, nothing SHALL move and the cursor SHALL only go to the chat.

#### Scenario: A row in the same session
- **WHEN** the sidebar is in window 1 of session `work` and the user presses `enter` on the chat of window 2
- **THEN** the sidebar is the leftmost full-height pane of window 2 and window 1 has none
- **AND** the client shows window 2 and the active pane is the chat

#### Scenario: A row in another session
- **WHEN** the row's window is in session `personal` and the client is in `work`
- **THEN** the client is switched to `personal` and the sidebar is in the row's window

#### Scenario: Already there
- **WHEN** the user presses `enter` on the chat of the window the sidebar is in
- **THEN** no pane moves and the cursor is in the chat

### Requirement: Selecting a row whose window is gone changes nothing
When the window of the row selected no longer exists, the sidebar and the client SHALL stay where they are and one line SHALL say that the window is gone.

#### Scenario: The window closed after the row was drawn
- **WHEN** the user presses `enter` on a row whose window has been closed
- **THEN** the sidebar and the client stay where they were and a line says the window is gone

### Requirement: Selecting a group header shows the session
`enter` on the header of a group that is a tmux session SHALL switch the client to that session's last-used window, the window the session itself had selected, and move the sidebar into it as a row would. It SHALL NOT change which window the session has selected.

#### Scenario: A header
- **WHEN** session `work` has windows 1 and 2, window 2 is the one it had selected, and the user presses `enter` on the header `work`
- **THEN** the client shows window 2 of `work` and the sidebar is in it

### Requirement: The sidebar follows the window on screen
`tagents --follow [CLIENT]` SHALL move the sidebar into the window the client (default: the current one) shows now, as its leftmost full-height pane. It SHALL do nothing and exit 0 when the sidebar already is there, when there is no sidebar, or when the window belongs to a session that is not a group.

#### Scenario: Already there
- **WHEN** `tagents --follow` runs while the sidebar is in the window on screen
- **THEN** no pane moves and the exit status is 0

#### Scenario: A scratch session
- **WHEN** the client is in a window of a session that is not a group
- **THEN** the sidebar stays where it was

### Requirement: The follow hooks bring the sidebar along
tagents SHALL install a hook running `tagents --follow` on `session-window-changed` and on `client-session-changed`, exactly one for each event however often they are installed, so that `prefix n`, `prefix s` and a click on the status bar bring the sidebar to the window now on screen.

#### Scenario: Next window
- **WHEN** the user presses `prefix n` and the next window is in a group
- **THEN** the sidebar is in that window and the window left has none

#### Scenario: Another session
- **WHEN** the user switches to a session that is a group with `prefix s`
- **THEN** the sidebar is in the window now on screen

#### Scenario: Hooks installed twice
- **WHEN** tagents installs its hooks twice
- **THEN** each of the two events carries exactly one `tagents --follow` command

### Requirement: Following never loops and never fights a closing window
`tagents --follow` SHALL leave the window it moved the sidebar into with no further run of itself, because moving a pane fires neither hook. When the window it was asked about is gone by the time it moves the sidebar, it SHALL leave the sidebar where it was, write one line saying so on standard error and exit 0, and the next window switch SHALL move the sidebar as usual.

#### Scenario: No second run
- **WHEN** `tagents --follow` moves the sidebar into the window on screen
- **THEN** neither hook runs again because of that move

#### Scenario: The window closes first
- **WHEN** the window the client was switched to is closed before the sidebar is moved
- **THEN** the sidebar is where it was, one line is written on standard error and the exit status is 0
- **AND** after the client's next window switch the sidebar is in the window on screen

### Requirement: The sidebar sits at the left edge at the width TA_WIDTH gives
The sidebar SHALL be the leftmost pane of its window and as tall as the window, whatever the other panes of the window are. When it is moved or started in a window it SHALL be given `TA_WIDTH` percent of the window's width (default 45). A window the sidebar leaves SHALL give its width back to the pane that was beside it, and SHALL have the same split as before when the sidebar returns.

#### Scenario: A split window
- **WHEN** the window is 200 columns wide, holds a chat and a shell side by side, and the sidebar is moved into it
- **THEN** the sidebar is the leftmost pane, as tall as the window and 90 columns wide, within one column, and the chat and the shell are to its right

#### Scenario: Another width
- **WHEN** `TA_WIDTH` is `30` and the sidebar is moved into a 200-column window
- **THEN** the sidebar is 60 columns wide, within one column

#### Scenario: Out and back
- **WHEN** the sidebar leaves a window and later returns
- **THEN** the other panes have the widths they had before, within one column
### Requirement: ensure-dash puts a sidebar in the window the client is in
`tagents --ensure-dash` SHALL make the sidebar be in the window the client is in. When no list is running it SHALL start one as a new pane, leftmost and as tall as the window with `TA_WIDTH` percent of its width, and wait up to about two seconds for the list to claim the sidebar. When a list is running it SHALL move that list's pane into the window as `tagents --follow` does. With no client it SHALL start and move nothing and exit 1.

#### Scenario: No sidebar yet
- **WHEN** no list is running and `tagents --ensure-dash` runs for a client in window 2 of session `work`
- **THEN** a list runs as the leftmost full-height pane of that window and has claimed the sidebar

#### Scenario: A sidebar elsewhere
- **WHEN** the sidebar is in another window and `tagents --ensure-dash` runs
- **THEN** the same pane is now in the window the client is in and no second list runs

#### Scenario: No client
- **WHEN** no client is attached
- **THEN** nothing is started or moved and the exit status is 1

### Requirement: The sidebar pane is titled tagents-sidebar
The pane a list claims as the sidebar SHALL carry the pane title `tagents-sidebar` for as long as the claim holds, wherever the pane is moved, so that tmux-resurrect saves and restores the title with the layout.

#### Scenario: Titled and moved
- **WHEN** a list claims the sidebar and the sidebar is then moved to another window
- **THEN** the pane's title is `tagents-sidebar` in both places

### Requirement: A restore closes the panes left where the sidebar was
After a restore (`tagents --resurrect`, and `tagents --resurrect --auto` from the tmux-resurrect hook), every pane titled `tagents-sidebar` that is not the live list SHALL be closed when it is an idle shell. A pane running anything but a shell SHALL never be touched, and a dry run SHALL close nothing.

#### Scenario: Leftover shells
- **WHEN** tmux-resurrect restored three windows, each with an idle shell titled `tagents-sidebar` where the sidebar was, and the restore has started a live list
- **THEN** the three shells are closed and the live list is still there

#### Scenario: A busy pane with that title
- **WHEN** a pane titled `tagents-sidebar` runs `sleep`
- **THEN** it is left running

### Requirement: Windows without a chat are dimmed rows
Every window of a group whose first pane, not counting the sidebar, carries no agent state SHALL get a dimmed row showing the window's name and nothing else: no state, age, context, cost, model or account. The line of such a row for fzf SHALL start with the window id (`@7`), carry the state `none` and an empty session id, and end with the directory of the window's first pane. `enter` on it SHALL select the window like any row.

#### Scenario: An editor window
- **WHEN** session `work` has a window `server` running a dev server and no chat
- **THEN** the list has a dim row `server` under `work`, with no state glyph, age, context or cost
- **AND** `enter` on it shows that window with the sidebar in it

#### Scenario: A chat window is not dimmed
- **WHEN** the first pane of a window carries an agent state
- **THEN** its row is an ordinary chat row

### Requirement: Ctrl-s joins a chat into the window on screen
`ctrl-s` on a chat row SHALL join the chat's pane into the window the client shows, as a split to the right of that window's chat, and leave the cursor where it was. A chat already in the window on screen SHALL only be focused. A window left with no pane by the join SHALL be closed and one that still has panes SHALL stay.

#### Scenario: Two chats in one window
- **WHEN** chat A is on screen and the user presses `ctrl-s` on chat B, whose window held only B
- **THEN** B is a pane beside A, B's former window is gone and the cursor is still where it was
- **AND** B's row stands for the window on screen

#### Scenario: Already here
- **WHEN** the user presses `ctrl-s` on the chat of the window on screen
- **THEN** nothing moves and the chat is focused

### Requirement: A joined chat remembers its home
A pane joined by `ctrl-s` SHALL carry the pane option `@tagents_joined` holding the name of the session its window was in. When it is joined again, it SHALL keep the first value.

#### Scenario: Marked
- **WHEN** chat B from session `personal` is joined into a window of session `work`
- **THEN** `@tagents_joined` on B holds `personal`

#### Scenario: Joined twice
- **WHEN** chat B, joined from session `personal`, is joined into another window of session `work`
- **THEN** `@tagents_joined` on B still holds `personal`

### Requirement: Ctrl-u breaks a joined chat out into a window of its own
`ctrl-u` on the row of a joined chat SHALL move its pane into a new window, created detached, of the session named by `@tagents_joined`, or of the session it is in when that session no longer exists, and SHALL remove `@tagents_joined` from it. The chat keeps running as the same pane. On a chat that is not joined it SHALL do nothing but show `tagents: that chat is not joined to another window`.

#### Scenario: Break out
- **WHEN** chat B, joined from session `personal`, is broken out with `ctrl-u`
- **THEN** B is the only pane of a new window of `personal`, with its process still running and no `@tagents_joined`
- **AND** A's window no longer holds B

#### Scenario: Not joined
- **WHEN** the user presses `ctrl-u` on a chat that was never joined
- **THEN** nothing moves and the line `tagents: that chat is not joined to another window` is shown

### Requirement: The sidebar is never closed
No key or verb of tagents SHALL close the sidebar pane except `ctrl-q`, and closing a chat SHALL NOT take the sidebar with it. When the chat killed with `ctrl-x` is the only pane of its window besides the sidebar, the sidebar SHALL be moved to the window the client lands on before the window is closed. When a chat exits by itself in such a window, the sidebar SHALL stay in the window, and a move of the sidebar out of a window in which it was the last pane SHALL close that window.

#### Scenario: Killing the only chat of a window
- **WHEN** the user confirms `ctrl-x` on the chat of the window on screen, which holds only that chat and the sidebar
- **THEN** the window is closed, the client shows another window and the sidebar is in it

#### Scenario: The chat exits by itself
- **WHEN** a chat exits in a window that holds only the chat and the sidebar
- **THEN** the sidebar is still there, and a follow to another window moves it out and the emptied window goes

### Requirement: ctrl-x never kills the sidebar
`ctrl-x` on the pane the list itself runs in SHALL do nothing but show `tagents: that is the dashboard itself`.

#### Scenario: Own pane
- **WHEN** a marker drifted so that the list's own pane is under the cursor and the user presses `ctrl-x`
- **THEN** the pane survives and the line is shown

### Requirement: The first start after the upgrade sends docked chats home
The first start of tagents after the upgrade, and every start while old seat state remains, SHALL send every docked chat (a pane with `@tagents_docked`) home to the window of its placeholder as the previous version did, and close every placeholder (`@tagents_slot`). A docked chat whose placeholder is gone SHALL be broken out into a window of its own. A chat SHALL keep running as the same pane throughout.

#### Scenario: Two docked chats
- **WHEN** chats A and B are docked in `agents:1` with a placeholder each in their home windows, and the new version starts
- **THEN** A and B are in their home windows and no placeholder is left
- **AND** `agents:1` still holds the sidebar as an ordinary window

#### Scenario: A placeholder that is gone
- **WHEN** a docked chat's placeholder was closed before the upgrade
- **THEN** the chat is in a window of its own and its process is the same

### Requirement: The first start after the upgrade removes the old state
The same start SHALL remove `@tagents_slot`, `@tagents_parked`, `@tagents_docked`, `@tagents_seat` and `@tagents_cur` from every pane and window, remove the focus hooks of the previous version, and ask `tnotes` to bring back the editors it parked (see the `notes-workspace` capability).

#### Scenario: Options and hooks
- **WHEN** the new version starts on a server that carries the old options and focus hooks
- **THEN** no pane or window carries any of the five options and none of the old focus hooks is left

### Requirement: The clean-up runs once and can be rolled back from
A second start with nothing left to clean SHALL change nothing. The state the clean-up leaves, every chat in its home window and no placeholder, SHALL be one the previous version handles.

#### Scenario: Started twice
- **WHEN** the new version starts a second time
- **THEN** no pane moves and no option changes

### Requirement: Which pane is the sidebar
The sidebar SHALL be the pane the list is running in. A list stamps its pane with `@tagents_list` set to its process id, which is a live claim only while that process exists. When a caller is itself a list, its own pane is the answer. Any other caller, such as a popup, a tmux hook or the status bar, SHALL use the pane marked `@tagents_dash` whose `@tagents_list` process is alive, and that pane stays the sidebar wherever it has been moved to.

#### Scenario: A marker whose list is dead
- **WHEN** one pane carries `@tagents_dash` with a dead process id and another carries it with a live one
- **THEN** the sidebar is the live one and the dead pane's `@tagents_dash` is cleared

#### Scenario: The sidebar has moved
- **WHEN** the sidebar was moved to another window by a follow
- **THEN** `tagents --follow` and the popup mean that pane, not a pane left in the window it came from

#### Scenario: A second list
- **WHEN** a second list starts in another window
- **THEN** the first list's `@tagents_list` claim is not taken away and non-list callers mean the newer list

### Requirement: A list claims the sidebar and gives it up on exit
A running list SHALL set `@tagents_dash` to `1` on its pane, taking it from any older list so that the newest list is the one non-list callers mean. On exit it SHALL remove its own `@tagents_list` and, if it still held the shared marker, `@tagents_dash`.

#### Scenario: The list exits
- **WHEN** the list in a pane quits
- **THEN** the pane does not carry `@tagents_list` or the shared marker
- **AND** a Claude chat later started in that pane is never taken for the sidebar

### Requirement: The list cursor follows the window on screen
When the sidebar is moved into a window, by a selection, `--follow` or `--ensure-dash`, the list SHALL put its cursor on that window's row: the chat row when the window's first pane is a chat, the window row otherwise. A window outside every group SHALL leave the sidebar and the cursor where they were.

#### Scenario: Switching with tmux's own keys
- **WHEN** the user presses `prefix+n` from the window of the chat "release notes" to the window of the chat "billing"
- **THEN** the sidebar is in the "billing" window and the list's cursor is on the "billing" row

#### Scenario: A window outside the groups
- **WHEN** the user switches to a window of a session that is not a group
- **THEN** the sidebar stays where it was and the cursor stays on the row it was on
