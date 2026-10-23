## ADDED Requirements

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

## MODIFIED Requirements

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
