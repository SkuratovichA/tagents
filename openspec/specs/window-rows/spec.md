# window-rows Specification

## Purpose
Every row of the dashboard is a tmux window and every group is a tmux session. The one sidebar pane moves into whichever window is on screen, and selecting a row puts the sidebar and the client in its window, so there are no seats, no docking and no placeholder panes.

## Requirements

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
The list SHALL group rows by the tmux session of their window, and a group header SHALL name the session. Every tmux session SHALL be a group, whether or not a chat has ever run in it, and every window of a group is listed (see the dimmed rows below), whichever directory its panes are in. A session whose only window holds nothing but the sidebar SHALL be a group with a header and no row under it, as the `dashboard-list` capability describes.

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

#### Scenario: Only the sidebar
- **WHEN** the client is in session `empty`, whose only window holds nothing but the sidebar
- **THEN** the list has a header `empty` and no row under it

### Requirement: A new chat opens in the group the cursor is in
A chat started from the dashboard (`ctrl-n`, `ctrl-p`) SHALL open as a new window, created detached, in the session of the group the cursor is in, whether the cursor is on a chat row, a dimmed row or a header, and then be selected like any row. When the cursor is on the group `no window`, the chat SHALL open as `chat-launch` says for a chat started with no group.

#### Scenario: Cursor in another group
- **WHEN** the client is in session `work`, the cursor is on a row of session `personal` and the user presses `ctrl-n`
- **THEN** the new chat's window is in `personal` and the sidebar and the client are in it

#### Scenario: A session without a chat
- **WHEN** the cursor is on the dimmed row `shell` of session `scratch`, where no chat runs, and the user presses `ctrl-n`
- **THEN** the new chat's window is in `scratch` and the sidebar and the client are in it

#### Scenario: Only the sidebar
- **WHEN** the cursor is on the header of session `empty`, whose only window holds nothing but the sidebar, and the user presses `ctrl-n`
- **THEN** `empty` holds one window, running the new chat, with the sidebar in it

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
`tagents --follow [CLIENT]` SHALL move the sidebar into the window the client (default: the current one) shows now, as its leftmost full-height pane, in whichever session that window is. It SHALL do nothing and exit 0 when the sidebar already is there, or when there is no sidebar and none is wanted.

#### Scenario: Already there
- **WHEN** `tagents --follow` runs while the sidebar is in the window on screen
- **THEN** no pane moves and the exit status is 0

#### Scenario: A scratch session
- **WHEN** the client is in a window of session `scratch`, where no chat has ever run and which tagents never created, and `tagents --follow` runs
- **THEN** the sidebar is in that window

### Requirement: The follow hooks bring the sidebar along
tagents SHALL install a hook running `tagents --follow` on `session-window-changed` and on `client-session-changed`, exactly one for each event however often they are installed, so that `prefix n`, `prefix s` and a click on the status bar bring the sidebar to the window now on screen.

#### Scenario: Next window
- **WHEN** the user presses `prefix n`
- **THEN** the sidebar is in the window now on screen and the window left has none

#### Scenario: Another session
- **WHEN** the user switches to another session with `prefix s`, whether or not a chat runs in it
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

### Requirement: A sidebar that was killed comes back with the next follow
While a sidebar is wanted, `tagents --follow` SHALL start a new one in the window on screen, as `tagents --ensure-dash` does, when no list runs, and SHALL start exactly one however many follows run at once. A sidebar is wanted from the moment a list in a pane claims the sidebar until `ctrl-q` quits it; a list in a popup never makes it wanted, and a start that fails ends the want.

#### Scenario: The window on screen is killed
- **WHEN** the window that holds the sidebar is killed while the client shows it, and tmux lands the client in another window
- **THEN** the follow hook starts a list there as the leftmost full-height pane, which claims the sidebar, and no other list runs

#### Scenario: The session on screen is killed
- **WHEN** the session that holds the sidebar is killed and the client lands in a window of another session
- **THEN** a list runs in that window and no other list runs

#### Scenario: ctrl-q is final
- **WHEN** the user quits the list with `ctrl-q` and then switches windows
- **THEN** no sidebar is started, until `tagents --ensure-dash` or a list started by hand wants one again

#### Scenario: Only a popup was ever shown
- **WHEN** no list has ever claimed a pane on the server and the user switches windows
- **THEN** no sidebar is started

#### Scenario: A storm of hooks
- **WHEN** five follows run at once with a sidebar wanted and none running
- **THEN** exactly one list is started and no lock is left behind

#### Scenario: A window outside the groups
- **WHEN** the client lands in a window of session `scratch`, where no chat has ever run and which tagents never created, while a sidebar is wanted and none runs
- **THEN** a list is started in that window, because every session is a group and no window is outside them

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

### Requirement: The sidebar is never hidden behind a zoomed pane
The sidebar SHALL be visible in the window it is moved or started in, so a pane the user zoomed in that window SHALL be unzoomed when the sidebar enters, and the zoom is not put back afterwards. A sidebar that is zoomed SHALL be unzoomed when it leaves, so that no window is left zoomed on nothing.

#### Scenario: The user's zoomed pane
- **WHEN** the user has zoomed a pane of a window and the sidebar is moved into that window
- **THEN** the window is not zoomed and the sidebar is visible beside the other panes

#### Scenario: A zoomed sidebar
- **WHEN** the sidebar is zoomed and is moved to another window
- **THEN** neither the window it left nor the window it entered is zoomed

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

#### Scenario: The list exits
- **WHEN** a list exits, whether or not a newer list has taken the shared marker since
- **THEN** its pane no longer carries the title `tagents-sidebar`, and a title that someone else set is left as it is

### Requirement: A restore closes the panes left where the sidebar was
After a restore (`tagents --resurrect`, and `tagents --resurrect --auto` from the tmux-resurrect hook), every pane titled `tagents-sidebar` that is not the live list SHALL be closed when it is an idle shell. A pane running anything but a shell SHALL never be touched, and a dry run SHALL close nothing.

#### Scenario: Leftover shells
- **WHEN** tmux-resurrect restored three windows, each with an idle shell titled `tagents-sidebar` where the sidebar was, and the restore has started a live list
- **THEN** the three shells are closed and the live list is still there

#### Scenario: A busy pane with that title
- **WHEN** a pane titled `tagents-sidebar` runs `sleep`
- **THEN** it is left running

### Requirement: Windows without a chat are dimmed rows
Every window of a group whose first pane, not counting the sidebar, carries no agent state SHALL get a dimmed row showing the window's name and nothing else: no state, age, context, cost, model or account. The line of such a row for fzf SHALL start with the window id (`@7`), carry the state `none` and an empty session id, and end with the directory of the window's first pane. `enter` on it SHALL select the window like any row, and `ctrl-x` on it SHALL kill the window after asking.

#### Scenario: An editor window
- **WHEN** session `work` has a window `server` running a dev server and no chat
- **THEN** the list has a dim row `server` under `work`, with no state glyph, age, context or cost
- **AND** `enter` on it shows that window with the sidebar in it

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

### Requirement: The sidebar is never closed
No key or verb of tagents SHALL close the sidebar pane except `ctrl-q`, and closing a chat or a window SHALL NOT take the sidebar with it. When the chat killed with `ctrl-x` is the only pane of its window besides the sidebar, or the window killed with `ctrl-x` on its dimmed row holds the sidebar, the sidebar SHALL be moved to the window the client lands on before the window is closed, or to a new shell window of the same session when the window is the last of its session.

#### Scenario: Killing the only chat of a window
- **WHEN** the user confirms `ctrl-x` on the chat of the window on screen, which holds only that chat and the sidebar
- **THEN** the window is closed, the client shows another window and the sidebar is in it

#### Scenario: Killing the window the sidebar is in
- **WHEN** the user confirms `ctrl-x` on the dimmed row of the window on screen, which holds a shell beside the sidebar
- **THEN** the window and the shell are gone, the client shows the window it lands on and the sidebar is in it

#### Scenario: Killing the last window of a session with the sidebar in it
- **WHEN** the window killed from its dimmed row is the only window of its session and holds the sidebar
- **THEN** the session stays, with a new shell window that holds the sidebar and is on screen

### Requirement: A chat that exits leaves the sidebar where it is
When a chat exits by itself in a window that holds only the chat and the sidebar, the sidebar SHALL stay in the window, and a move of the sidebar out of a window in which it was the last pane SHALL close that window.

#### Scenario: The chat exits by itself
- **WHEN** a chat exits in a window that holds only the chat and the sidebar
- **THEN** the sidebar is still there, and a follow to another window moves it out and the emptied window goes

### Requirement: ctrl-x never kills the sidebar
`ctrl-x` on the pane the list itself runs in, or on a window that holds nothing but that pane, SHALL do nothing but show `tagents: that is the dashboard itself`.

#### Scenario: Own pane
- **WHEN** a marker drifted so that the list's own pane is under the cursor and the user presses `ctrl-x`
- **THEN** the pane survives and the line is shown

#### Scenario: The sidebar's own window
- **WHEN** `tagents --act kill` is run on a window that holds only the sidebar
- **THEN** the window and the sidebar survive and the line is shown

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
When the sidebar is moved into a window, by a selection, `--follow` or `--ensure-dash`, the list SHALL put its cursor on that window's row: the chat row when the window's first pane is a chat, the window row otherwise. When that window is the only window of its session and holds nothing but the sidebar, the cursor SHALL go to that session's header.

#### Scenario: Switching with tmux's own keys
- **WHEN** the user presses `prefix+n` from the window of the chat "release notes" to the window of the chat "billing"
- **THEN** the sidebar is in the "billing" window and the list's cursor is on the "billing" row

#### Scenario: A window outside the groups
- **WHEN** the user switches with `prefix s` to session `scratch`, whose only window `shell` runs no chat and which tagents never created
- **THEN** the sidebar is in `shell` and the cursor is on the dimmed row `shell`, because every session is a group and no window is outside them

#### Scenario: Only the sidebar
- **WHEN** `tagents --ensure-dash` runs while the client shows session `empty`, whose only window holds nothing but the sidebar
- **THEN** the cursor is on the header `empty`

### Requirement: ctrl-x on a dimmed row kills the window after asking
`ctrl-x` on a dimmed window row SHALL ask `kill this window?`, in the popup a chat's kill asks in or inline where there is no popup, and SHALL act only on `y`, `yes` or their capitals; anything else, or no answer within 60 seconds, cancels. Confirming SHALL close the window with every pane in it, ring the refresher's channel and retake the resurrect snapshot.

#### Scenario: Confirmed
- **WHEN** the user answers `y` for the dimmed row of window `server`, which runs a dev server and a shell
- **THEN** the window and both of its panes are gone, and every other window and the sidebar are where they were

#### Scenario: Anything else
- **WHEN** the user answers `n`, presses enter on an empty line or does not answer
- **THEN** the window and its panes are still there

### Requirement: The window question says what will be lost
The question SHALL name the window by its name and its `session:index` and list every pane of the window except the sidebar, one line each, with the command running in it and its directory, written with `~` for the home directory. When the window is the last of its session and the sidebar is not in it, the question SHALL also say that the session ends with it.

#### Scenario: The question lists the panes
- **WHEN** the window holds `node` running in `~/app` and `zsh` in `~/app/src`
- **THEN** the question names the window and its `session:index` and has one line for each of the two panes with its command and its directory

#### Scenario: The sidebar is not listed
- **WHEN** the sidebar is in the window under the cursor
- **THEN** the question lists the window's other panes and no line for the sidebar

#### Scenario: The last window of its session
- **WHEN** the window is the only window of its session and the sidebar is in another session
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
- **THEN** a new window of `scratch` runs a shell in `~/app`, the sidebar and the client are in it, and `tagents: new shell in app (scratch:N)` is shown, `N` being the new window's index

#### Scenario: On a chat row
- **WHEN** the cursor is on the row of a chat in session `work` and the user presses `ctrl-a`
- **THEN** a new window of `work` runs a shell and the chat's window still holds the chat

#### Scenario: On the group no window
- **WHEN** the cursor is on a closed row of the group `no window`, for a project whose live panes are all in session `work`, and the user presses `ctrl-a`
- **THEN** the new window is in `work`

#### Scenario: Only the sidebar
- **WHEN** the cursor is on the header of session `empty`, whose only window holds nothing but the sidebar, and the user presses `ctrl-a`
- **THEN** `empty` holds one window, running a shell in the session's working directory, with the sidebar in it

### Requirement: The shell starts in the row's directory
The window `ctrl-a` opens SHALL start in the directory of the row under the cursor when that is an absolute path that exists, otherwise in the session's working directory when that exists, otherwise in the home directory. It SHALL NOT fall back to the directory the list itself runs in.

#### Scenario: The row's directory is gone
- **WHEN** the directory of the row under the cursor no longer exists and the user presses `ctrl-a`
- **THEN** the shell starts in the working directory of the row's session

#### Scenario: Nothing left to start in
- **WHEN** neither the row's directory nor the session's working directory exists and the user presses `ctrl-a`
- **THEN** the shell starts in the home directory and the message reads `tagents: new shell in ~ (<session>:<index>)`

### Requirement: A list started as the sidebar runs in the home directory
A list that tagents starts as the sidebar, for `tagents --ensure-dash` or when a window switch brings the sidebar back, SHALL run with the home directory (`$HOME`) as its working directory, whatever the working directory of the process that started it. A sidebar therefore never keeps a project directory or a worktree in use.

#### Scenario: ensure-dash from inside a worktree
- **WHEN** no list is running and `tagents --ensure-dash` runs from a shell whose working directory is a git worktree
- **THEN** the new list's pane reports `$HOME` as its working directory (`#{pane_current_path}`)

#### Scenario: A sidebar brought back by a window switch
- **WHEN** the window holding the sidebar is killed and the follow hook starts a new list in the window the client lands in
- **THEN** the new list's pane reports `$HOME` as its working directory
