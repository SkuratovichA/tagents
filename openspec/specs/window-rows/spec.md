# window-rows Specification

## Purpose
Every row of the dashboard is a tmux window and every group is a tmux session. Selecting a row shows its window in the cockpit's viewport (the `cockpit` capability) and no pane ever changes window, so there are no seats, no docking and no placeholder panes.
## Requirements
### Requirement: A row is a tmux window
The dashboard SHALL show every chat as a row that stands for the tmux window its pane is in. The chat is the window's first pane. A chat joined into another window by `ctrl-s` has a row of its own that stands for the window it is in now. Selecting a row acts on the window, not on the pane alone.

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
Every pane of a window other than the chat SHALL belong to the user. tagents SHALL NOT move, resize, kill or mark such a pane by selecting rows, joining or breaking out chats, or killing a chat, and they leave the screen and come back with the window they are in.

#### Scenario: A terminal beside the chat
- **WHEN** the user splits a shell beside chat A, selects chat B's row and then A's row again
- **THEN** the shell is still the same pane of A's window and carries no `@tagents_*` option
- **AND** it was not on screen while B's window was

### Requirement: A group is a tmux session
The list SHALL group rows by the tmux session of their window, and a group header SHALL name the session. Every tmux session but the cockpit's dashboard SHALL be a group, whether or not a chat has ever run in it, and every window of a group is listed (see the dimmed rows below), whichever directory its panes are in.

#### Scenario: Two sessions
- **WHEN** session `work` holds two chats and session `personal` holds one
- **THEN** the list has a header `work` over two rows and a header `personal` over one

#### Scenario: Directory no longer groups
- **WHEN** two chats of session `work` run in two unrelated directories
- **THEN** both rows are under the header `work`

#### Scenario: A scratch session
- **WHEN** session `scratch` holds one window `shell`, running a shell, no chat has ever run in it and tagents never created it
- **THEN** the list has a header `scratch` over one dimmed row `shell`

#### Scenario: A session tagents created
- **WHEN** tagents created session `release notes` for a chat and the chat has since exited
- **THEN** the session is still a group and its windows are still listed

#### Scenario: The cockpit's dashboard
- **WHEN** the cockpit is up and the sessions `work`, `personal` and `tagents` exist
- **THEN** the list has the headers `work` and `personal` and none named `tagents`

### Requirement: A new chat opens in the group the cursor is in
A chat started from the dashboard (`ctrl-n`, `ctrl-p`) SHALL open as a new window, created detached, in the session of the group the cursor is in, whether the cursor is on a chat row, a dimmed row or a header, and then be selected like any row. When the cursor is on the group `no window`, the chat SHALL open as `chat-launch` says for a chat started with no group.

#### Scenario: Cursor in another group
- **WHEN** the client is in session `work`, the cursor is on a row of session `personal` and the user presses `ctrl-n`
- **THEN** the new chat's window is in `personal` and the viewport shows it

#### Scenario: A session without a chat
- **WHEN** the cursor is on the dimmed row `shell` of session `scratch`, where no chat runs, and the user presses `ctrl-n`
- **THEN** the new chat's window is in `scratch` and the viewport shows it

### Requirement: Selecting a row shows its window
`enter` on a row SHALL show the row's window with the chat's pane active and leave the cursor on the row: in the cockpit the viewport shows it and the terminal stays on the dashboard (the `cockpit` capability), and with no cockpit up the window is selected and the client switched to it.

#### Scenario: A row in the same session
- **WHEN** the cockpit is up, the viewport shows window 1 of session `work` and the user presses `enter` on the chat of window 2
- **THEN** the viewport shows window 2 with the chat's pane active and no pane has changed window

#### Scenario: A row in another session
- **WHEN** the row's window is in session `personal` and the viewport shows `work`
- **THEN** the viewport shows the row's window

#### Scenario: No cockpit
- **WHEN** no cockpit is up, the client shows `work:1` and `tagents --goto` is run for the chat of `personal:2`
- **THEN** the client shows `personal:2` with the chat's pane active

### Requirement: Selecting a row whose window is gone changes nothing
When the window of the row selected no longer exists, the viewport and the client SHALL stay where they are and one line SHALL say that the window is gone.

#### Scenario: The window closed after the row was drawn
- **WHEN** the user presses `enter` on a row whose window has been closed
- **THEN** the viewport and the client stay where they were and a line says the window is gone

### Requirement: Selecting a group header shows the session
`enter` on the header of a group that is a tmux session SHALL show that session's last-used window, the window the session itself had selected, as a row's window is shown. It SHALL NOT change which window the session has selected.

#### Scenario: A header
- **WHEN** session `work` has windows 1 and 2, window 2 is the one it had selected, and the user presses `enter` on the header `work`
- **THEN** the viewport shows window 2 of `work`

### Requirement: The follow hooks keep the cursor with the viewport
tagents SHALL install a hook running `tagents --follow` on `session-window-changed` and on `client-session-changed`, exactly one for each event however often they are installed, so that `prefix n`, `prefix s` and a click on the status bar in the viewport bring the list's cursor to the row of the window now shown. With no cockpit up the verb SHALL do nothing and exit 0.

#### Scenario: Next window
- **WHEN** the cockpit is up and the user presses `prefix n` in the viewport
- **THEN** the list's cursor is on the row of the window now shown

#### Scenario: Another session
- **WHEN** the user switches the viewport to another session with `prefix s`, whether or not a chat runs in it
- **THEN** the cursor is on the row of the window now shown

#### Scenario: Hooks installed twice
- **WHEN** tagents installs its hooks twice
- **THEN** each of the two events carries exactly one `tagents --follow` command

#### Scenario: No cockpit
- **WHEN** no cockpit is up and a window switch runs the hook
- **THEN** `tagents --follow` changes nothing and exits 0

### Requirement: The list's pane is titled tagents-sidebar
The pane a list claims SHALL carry the pane title `tagents-sidebar` for as long as the claim holds, so that tmux-resurrect saves and restores the title with the layout.

#### Scenario: Titled
- **WHEN** a list claims its pane
- **THEN** the pane's title is `tagents-sidebar`

#### Scenario: The list exits
- **WHEN** a list exits, whether or not a newer list has taken the shared marker since
- **THEN** its pane no longer carries the title `tagents-sidebar`, and a title that someone else set is left as it is

### Requirement: A restore closes the panes left where the list was
After a restore (`tagents --resurrect`, and `tagents --resurrect --auto` from the tmux-resurrect hook), every pane titled `tagents-sidebar` that is not the live list, and every pane titled `tagents-viewport` that is not the live viewport, SHALL be closed when it is an idle shell; a leftover dashboard is rebuilt as the `cockpit` capability describes. A pane running anything but a shell SHALL never be touched, and a dry run SHALL close nothing.

#### Scenario: Leftover shells
- **WHEN** tmux-resurrect restored three windows saved by an earlier version, each with an idle shell titled `tagents-sidebar` where the list was, and the restore has brought the dashboard up
- **THEN** the three shells are closed and the live list is still there

#### Scenario: A busy pane with that title
- **WHEN** a pane titled `tagents-sidebar` runs `sleep`
- **THEN** it is left running

#### Scenario: A leftover viewport shell
- **WHEN** a restore finds an idle shell titled `tagents-viewport` in the window `work:2`, outside the session `tagents`
- **THEN** that shell is closed and the other panes of `work:2` are untouched

### Requirement: Windows without a chat are dimmed rows
Every window of a group whose first pane carries no agent state SHALL get a dimmed row showing the window's name and nothing else: no state, age, context, cost, model or account. The line of such a row for fzf SHALL start with the window id (`@7`), carry the state `none` and an empty session id, and end with the directory of the window's first pane. `enter` on it SHALL select the window like any row, and `ctrl-x` on it SHALL kill the window after asking.

#### Scenario: An editor window
- **WHEN** session `work` has a window `server` running a dev server and no chat
- **THEN** the list has a dim row `server` under `work`, with no state glyph, age, context or cost
- **AND** `enter` on it shows that window in the viewport

#### Scenario: A chat window is not dimmed
- **WHEN** the first pane of a window carries an agent state
- **THEN** its row is an ordinary chat row

### Requirement: Ctrl-s joins a chat into the window on screen
`ctrl-s` on a chat row SHALL join the chat's pane into the window the client shows, as a split to the right of that window's chat, and leave the cursor where it was. A chat already in the window on screen SHALL only be focused. A window left with no pane by the join SHALL be closed and one that still has panes SHALL stay. A chat that is the only pane of the only window of its session SHALL NOT be joined, because the session would close with it: a notice is shown and nothing moves.

#### Scenario: Two chats in one window
- **WHEN** chat A is on screen and the user presses `ctrl-s` on chat B, whose window held only B
- **THEN** B is a pane beside A, B's former window is gone and the cursor is still where it was
- **AND** B's row stands for the window on screen

#### Scenario: Already here
- **WHEN** the user presses `ctrl-s` on the chat of the window on screen
- **THEN** nothing moves and the chat is focused

#### Scenario: Alone in its session
- **WHEN** the user presses `ctrl-s` on a chat that is the only pane of the only window of its session
- **THEN** the chat stays where it is, the session stays, and a notice says the chat is alone in its session

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

### Requirement: Closing a chat or a window never closes the list
No key or verb of tagents SHALL close the list pane except `ctrl-q`. The list is never in a window of a chat, so killing a chat or a window with `ctrl-x` closes nothing of the dashboard.

#### Scenario: Killing the only chat of a window
- **WHEN** the user confirms `ctrl-x` on the chat of a window that holds only that chat
- **THEN** the window is closed and the dashboard still holds the list and the viewport

#### Scenario: Killing a window from its dimmed row
- **WHEN** the user confirms `ctrl-x` on the dimmed row of the window the viewport shows
- **THEN** the window and its panes are gone and the list is still the dashboard's left pane

### Requirement: ctrl-x never kills the list
`ctrl-x` on the pane the list itself runs in, or on a window that holds nothing but that pane, SHALL do nothing but show `tagents: that is the dashboard itself`.

#### Scenario: Own pane
- **WHEN** a marker drifted so that the list's own pane is under the cursor and the user presses `ctrl-x`
- **THEN** the pane survives and the line is shown

#### Scenario: The list's own window
- **WHEN** `tagents --act kill` is run on a window that holds only the list
- **THEN** the window and the list survive and the line is shown

### Requirement: The first start after the upgrade sends docked chats home
The first start of tagents after the upgrade, and every start while old seat state remains, SHALL send every docked chat (a pane with `@tagents_docked`) home to the window of its placeholder as the previous version did, and close every placeholder (`@tagents_slot`). A docked chat whose placeholder is gone SHALL be broken out into a window of its own. A chat SHALL keep running as the same pane throughout.

#### Scenario: Two docked chats
- **WHEN** chats A and B are docked in `agents:1` with a placeholder each in their home windows, and the new version starts
- **THEN** A and B are in their home windows and no placeholder is left
- **AND** `agents:1` is an ordinary window

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

### Requirement: Which pane is the dashboard's list
The dashboard's list SHALL be the pane the list is running in. A list stamps its pane with `@tagents_list` set to its process id, which is a live claim only while that process exists. When a caller is itself a list, its own pane is the answer. Any other caller, such as a popup, a tmux hook or the status bar, SHALL use the pane marked `@tagents_dash` whose `@tagents_list` process is alive.

#### Scenario: A marker whose list is dead
- **WHEN** one pane carries `@tagents_dash` with a dead process id and another carries it with a live one
- **THEN** the list is the live one and the dead pane's `@tagents_dash` is cleared

#### Scenario: A second list
- **WHEN** a second list starts in another window
- **THEN** the first list's `@tagents_list` claim is not taken away and non-list callers mean the newer list

### Requirement: A list claims its pane and gives it up on exit
A running list SHALL set `@tagents_dash` to `1` on its pane, taking it from any older list so that the newest list is the one non-list callers mean. On exit it SHALL remove its own `@tagents_list` and, if it still held the shared marker, `@tagents_dash`.

#### Scenario: The list exits
- **WHEN** the list in a pane quits
- **THEN** the pane does not carry `@tagents_list` or the shared marker
- **AND** a Claude chat later started in that pane is never taken for the list

### Requirement: The list cursor follows the window the viewport shows
When the viewport comes to show a window, by a selection, a switch made in the viewport or `--ensure-dash`, the list SHALL put its cursor on that window's row: the chat row when the window's first pane is a chat, the window row otherwise.

#### Scenario: Switching with tmux's own keys
- **WHEN** the user presses `prefix+n` in the viewport from the window of the chat "release notes" to the window of the chat "billing"
- **THEN** the viewport shows the "billing" window and the list's cursor is on the "billing" row

#### Scenario: A window outside the groups
- **WHEN** the user switches the viewport with `prefix s` to session `scratch`, whose only window `shell` runs no chat and which tagents never created
- **THEN** the viewport shows `shell` and the cursor is on the dimmed row `shell`, because every session is a group and no window is outside them

### Requirement: ctrl-x on a dimmed row kills the window after asking
`ctrl-x` on a dimmed window row SHALL ask `kill this window?`, in the popup a chat's kill asks in or inline where there is no popup, and SHALL act only on `y`, `yes` or their capitals; anything else, or no answer within 60 seconds, cancels. Confirming SHALL close the window with every pane in it, ring the refresher's channel and retake the resurrect snapshot.

#### Scenario: Confirmed
- **WHEN** the user answers `y` for the dimmed row of window `server`, which runs a dev server and a shell
- **THEN** the window and both of its panes are gone, and every other window and the dashboard are where they were

#### Scenario: Anything else
- **WHEN** the user answers `n`, presses enter on an empty line or does not answer
- **THEN** the window and its panes are still there

### Requirement: The window question says what will be lost
The question SHALL name the window by its name and its `session:index` and list every pane of the window, one line each, with the command running in it and its directory, written with `~` for the home directory. When the window is the last of its session, the question SHALL also say that the session ends with it.

#### Scenario: The question lists the panes
- **WHEN** the window holds `node` running in `~/app` and `zsh` in `~/app/src`
- **THEN** the question names the window and its `session:index` and has one line for each of the two panes with its command and its directory

#### Scenario: The last window of its session
- **WHEN** the window is the only window of its session
- **THEN** the question says that the session ends with it, and confirming ends the session while the client stays attached where it was

#### Scenario: A pane in the home directory
- **WHEN** a pane of the window runs in the home directory itself
- **THEN** its line shows the directory as `~`

### Requirement: A window closed since its row was drawn is not asked about
Whether the window exists SHALL be checked when the question is about to be asked: a window closed since its row was drawn SHALL ask nothing, kill nothing and show `tagents: that window is gone`.

#### Scenario: Closed since the row was drawn
- **WHEN** the window was closed after its row was drawn and the user presses `ctrl-x` on the row
- **THEN** nothing is asked or killed and `tagents: that window is gone` is shown

### Requirement: ctrl-a opens a shell in the group the cursor is in
`ctrl-a` SHALL open a new window running tmux's default command in the session of the group the cursor is in, on a chat row, a dimmed row or a header alike, created detached and then selected like any row, and SHALL show `tagents: new shell in <name> (<session>:<index>)`, `<name>` being the last part of its directory or `~` for the home directory. On the group `no window` the window SHALL go to the session that owns the row's project, as `chat-launch` picks it.

#### Scenario: On a dimmed row
- **WHEN** the cursor is on the dimmed row `server` of session `scratch`, whose first pane runs in `~/app`, and the user presses `ctrl-a`
- **THEN** a new window of `scratch` runs a shell in `~/app`, the viewport shows it, and `tagents: new shell in app (scratch:N)` is shown, `N` being the new window's index

#### Scenario: On a chat row
- **WHEN** the cursor is on the row of a chat in session `work` and the user presses `ctrl-a`
- **THEN** a new window of `work` runs a shell and the chat's window still holds the chat

#### Scenario: On the group no window
- **WHEN** the cursor is on a closed row of the group `no window`, for a project whose live panes are all in session `work`, and the user presses `ctrl-a`
- **THEN** the new window is in `work`

### Requirement: The shell starts in the row's directory
The window `ctrl-a` opens SHALL start in the directory of the row under the cursor when that is an absolute path that exists, otherwise in the session's working directory when that exists, otherwise in the home directory. It SHALL NOT fall back to the directory the list itself runs in.

#### Scenario: The row's directory is gone
- **WHEN** the directory of the row under the cursor no longer exists and the user presses `ctrl-a`
- **THEN** the shell starts in the working directory of the row's session

#### Scenario: Nothing left to start in
- **WHEN** neither the row's directory nor the session's working directory exists and the user presses `ctrl-a`
- **THEN** the shell starts in the home directory and the message reads `tagents: new shell in ~ (<session>:<index>)`

### Requirement: The dashboard's panes run in the home directory
The list and the viewport that tagents starts for the cockpit SHALL run with the home directory (`$HOME`) as their working directory, whatever the working directory of the process that started them. The dashboard therefore never keeps a project directory or a worktree in use.

#### Scenario: ensure-dash from inside a worktree
- **WHEN** no cockpit is up and `tagents --ensure-dash` runs from a shell whose working directory is a git worktree
- **THEN** the panes of the new dashboard report `$HOME` as their working directory (`#{pane_current_path}`)

#### Scenario: A list brought back
- **WHEN** the list's pane of the dashboard is killed and a new one is started in its place
- **THEN** the new list's pane reports `$HOME` as its working directory
