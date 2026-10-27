## RENAMED Requirements

- FROM: `### Requirement: The sidebar is filed by its window`
- TO: `### Requirement: The dashboard is filed by the window the viewport shows`

- FROM: `### Requirement: The sidebar comes back`
- TO: `### Requirement: The dashboard comes back`

- FROM: `### Requirement: The restore closes the sidebar's leftover panes`
- TO: `### Requirement: The restore closes the panes left where the list was`

## MODIFIED Requirements

### Requirement: A snapshot holds one row per live chat
A capture SHALL write one `A` row per live chat that has a state record with a session id, whether tagents started the chat or it was typed by hand. A pane that has a record but no Claude process, and the list, SHALL get no row. A row is a tab-separated line of 14 columns, listed in the next requirement.

#### Scenario: Two chats and a pane that only has a record
- **WHEN** two panes run Claude with state records and a third pane runs `sleep` with a record left behind
- **THEN** the snapshot has exactly two `A` rows, each of 14 columns
- **AND** the `sleep` pane has no row

#### Scenario: The default account is recorded as present but empty
- **WHEN** a chat ran on the default login
- **THEN** its config directory column is empty and its account-recorded column is `1`

#### Scenario: Model and effort are carried
- **WHEN** a chat's status line recorded a model and it was started with `--effort high`
- **THEN** its row carries the model in column 13 and a command line containing `--effort high` in column 14

### Requirement: The columns of a row
The 14 columns of an `A` row SHALL be, in order: `A`, the session id, the Claude config directory the chat ran on, `1` when that account was recorded, the tmux session name, the window index, the pane's place in its window, the window name, tagents' own name for it, the working directory, `p` when the place skips the list pane (older snapshots: empty or `1`), `1` when the notes editor was beside the chat, the model, and the command line it started with, tabs and newlines turned into spaces.

#### Scenario: Column positions
- **WHEN** a chat in session `proj`, window 1, pane 1 named `Alpha` runs in a directory `~/projects/app`
- **THEN** column 5 is `proj`, column 6 is `1`, column 7 is `0`, column 8 is `Alpha`, column 10 is the directory and column 11 is `p`

#### Scenario: An old snapshot
- **WHEN** a snapshot written before this change holds `1` in column 11 of a row
- **THEN** the restore reads column 7 as a tmux pane index and the chat comes back undocked, as every chat does

### Requirement: Where a chat goes back
A chat SHALL be placed at its recorded place in the window `session:window` when that pane is an idle shell with no tagents or tnotes marker on it and is not titled `tagents-sidebar`: the pane is replaced in place by the resumed command, and nothing is typed into the shell. Otherwise (the pane is busy, a list's pane, an editor, gone, or the row has no window and pane) the chat SHALL get a new window in its session, and when the session is gone, a new session of that name.

#### Scenario: Idle shell
- **WHEN** tmux-resurrect left an idle shell at the recorded pane
- **THEN** the chat runs in that pane and no window is added

#### Scenario: Busy pane
- **WHEN** the recorded pane runs `sleep`
- **THEN** the chat gets a new window in the same session and the `sleep` pane keeps running

#### Scenario: A joined chat
- **WHEN** a row has a session and empty window and pane columns
- **THEN** the chat gets a new window in that session

#### Scenario: Bare server
- **WHEN** tmux-resurrect has not run and the server has none of the recorded sessions
- **THEN** the restore creates the missing sessions

#### Scenario: Session gone
- **WHEN** the recorded session does not exist
- **THEN** a new session of that name is created holding the chat

### Requirement: Chats are filed where their panes are
A capture SHALL record each chat at the session name and window index that tmux reports for its pane, and at its place among the panes of that window that are not the list (the pane titled `tagents-sidebar`, or the live list): the number of such panes before it, from 0, with the user's panes counted. A list pane that an earlier version left in a window is not counted, because an index that counted it would name another pane after a restore.

#### Scenario: A chat beside a shell
- **WHEN** a chat is pane 1 of window 2 of session `proj`, with a list pane of an earlier version as pane 0 and a shell as pane 2
- **THEN** its row says session `proj`, window 2, place 0, and `p` in column 11

### Requirement: A restore finds a chat's pane by its place
A restore SHALL find the pane at the recorded place among the panes of the window that are not titled `tagents-sidebar`. A row without `p` in column 11 (an older snapshot) holds a tmux pane index, which SHALL be used as it stands, except that a pane titled `tagents-sidebar` is never used.

#### Scenario: The list pane was elsewhere at the restore
- **WHEN** the snapshot was taken with a list pane left of the chat, and tmux-resurrect brought the window back as two idle shells without it
- **THEN** the chat runs in the first shell, the second shell is untouched and no window is added

#### Scenario: An old snapshot points at the list's shell
- **WHEN** a row of an older snapshot names a tmux pane index at which an idle shell titled `tagents-sidebar` stands
- **THEN** that pane is not used and the chat gets a new window in its session

### Requirement: The dashboard is filed by the window the viewport shows
When the cockpit is up and its viewport shows a window, the snapshot SHALL hold one `D` row of three columns: `D`, and the session name and the window index of that window. The session `tagents` is never filed.

#### Scenario: The cockpit
- **WHEN** the cockpit is up and the viewport shows window 2 of session `work`
- **THEN** the snapshot has the row `D`, `work`, `2`, and no row names the session `tagents`

### Requirement: The dashboard comes back
When the snapshot holds a `D` row, the restore SHALL bring the dashboard back once the chats are placed and report `✓ dashboard`: the cockpit is made if it is not up and its viewport shows the recorded window if it exists after the restore, else the first restored chat's window. A window tmux-resurrect left from an older snapshot's dashboard SHALL be an ordinary window and keep what it runs.

#### Scenario: Dashboard row
- **WHEN** the snapshot's `D` row names `work:2`, which is restored, and a terminal is attached to the session `work`
- **THEN** the report says `✓ dashboard`, the session `tagents` exists with its viewport showing `work:2`, and that terminal still shows the session `work`

#### Scenario: The window is gone
- **WHEN** the `D` row names a window that does not exist after the restore
- **THEN** the viewport shows the window of the first chat restored

#### Scenario: A leftover cockpit
- **WHEN** tmux-resurrect restored a session `tagents` holding two idle shells titled `tagents-sidebar` and `tagents-viewport`
- **THEN** after `tagents --resurrect` those panes run the list and the viewport, as the `cockpit` capability describes, before the dashboard step reports

### Requirement: The restore closes the panes left where the list was
After the chats and the dashboard are up, the restore SHALL close every idle shell titled `tagents-sidebar` that is not the live list and every idle shell titled `tagents-viewport` that is not the live viewport, as the `window-rows` capability says, and SHALL touch no other pane; a leftover dashboard is rebuilt as the `cockpit` capability says. A dry run SHALL close nothing.

#### Scenario: Shells where the list was
- **WHEN** the snapshot's windows, saved by an earlier version, were restored with an idle shell titled `tagents-sidebar` in each
- **THEN** after `tagents --resurrect` those shells are gone and the chats are untouched

#### Scenario: Dry run
- **WHEN** `tagents --resurrect --dry-run` runs
- **THEN** no pane is closed
