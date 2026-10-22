## MODIFIED Requirements

### Requirement: A snapshot holds one row per live chat
A capture SHALL write one `A` row per live chat that has a state record with a session id, whether tagents started the chat or it was typed by hand. A pane that has a record but no Claude process, and the sidebar, SHALL get no row. A row is a tab-separated line of 14 columns, listed in the next requirement.

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
The 14 columns of an `A` row SHALL be, in order: the letter `A`, the session id, the Claude config directory the chat ran on, a flag that is `1` when that account was recorded, the tmux session name, the window index, the pane index, the window name, tagents' own name for the window, the working directory, a column that is written empty (older snapshots held `1` in it for a docked chat, and a restore reads it and ignores it), `1` when its notes editor was beside the chat, the model, and the command line the chat was started with, with tabs and newlines turned into spaces.

#### Scenario: Column positions
- **WHEN** a chat in session `proj`, window 1, pane 1 named `Alpha` runs in a directory `~/projects/app`
- **THEN** column 5 is `proj`, column 6 is `1`, column 7 is `1`, column 8 is `Alpha`, column 10 is the directory and column 11 is empty

#### Scenario: An old snapshot
- **WHEN** a snapshot written before this change holds `1` in column 11 of a row
- **THEN** the restore reads the row like any other and the chat comes back undocked, as every chat does

### Requirement: Rows are ordered and a capture replaces the last one
A capture SHALL be a full replacement, never a merge. The `D` row, when there is one, SHALL come first, and the `A` rows SHALL be sorted by tmux session name, then window index, then pane index, so an unchanged set reads the same whatever order the process list returned its chats in. A capture that says exactly what the newest snapshot already says SHALL NOT be written. A capture that fails SHALL leave the newest good snapshot where it was.

#### Scenario: Same set twice
- **WHEN** `tagents --resurrect-save` runs twice with nothing changed in between
- **THEN** one snapshot file exists

#### Scenario: Changed set
- **WHEN** a chat is moved to another window between two captures
- **THEN** the second capture is written as a new file

### Requirement: Where a chat goes back
A chat SHALL be placed at its recorded `session:window.pane` when that pane is an idle shell with no tagents or tnotes marker on it: the pane is replaced in place by the resumed command, and nothing is typed into the shell. Otherwise (the pane is busy, the sidebar, an editor, gone, or the row has no window and pane) the chat SHALL get a new window in its session, and when the session is gone, a new session of that name. The other panes of the window, which tmux-resurrect brings back as idle shells in their working directories, SHALL be left as they are, and a pane running anything but a shell SHALL never be touched.

#### Scenario: Idle shell
- **WHEN** tmux-resurrect left an idle shell at the recorded pane
- **THEN** the chat runs in that pane and no window is added

#### Scenario: Busy pane
- **WHEN** the recorded pane runs `sleep`
- **THEN** the chat gets a new window in the same session and the `sleep` pane keeps running

#### Scenario: A shell beside the chat
- **WHEN** the recorded window also had a shell pane that tmux-resurrect brought back
- **THEN** the shell is untouched, an idle shell in its working directory, and the chat runs in its own pane

#### Scenario: A joined chat
- **WHEN** a row has a session and empty window and pane columns
- **THEN** the chat gets a new window in that session

#### Scenario: Bare server
- **WHEN** tmux-resurrect has not run and the server has none of the recorded sessions
- **THEN** the restore creates the missing sessions

#### Scenario: Session gone
- **WHEN** the recorded session does not exist
- **THEN** a new session of that name is created holding the chat

### Requirement: Notes editors
After the chats are up, the restore SHALL close the notes editors that tmux-resurrect brought back with nothing linking them to a chat: in each restored chat's window the pane in the notes directory that no chat links to, and the whole session `ta-notes` when a save of an older version brought it back. It SHALL then ask `tnotes toggle <pane>` once for each restored chat whose editor was beside it.

#### Scenario: Orphans closed and one editor reopened
- **WHEN** a restored chat's window holds an unlinked pane in the notes directory, two unlinked editors sit in a returned `ta-notes` session, and one restored chat had its editor beside it
- **THEN** the unlinked pane and the `ta-notes` session are closed, and tnotes is asked once for that chat's pane

#### Scenario: Report lines
- **WHEN** tnotes reopens the editor, or fails to
- **THEN** the report says `✓ notes beside <pane>`, or `! notes for <pane> did not reopen — prefix C-t`

#### Scenario: Off
- **WHEN** `resurrect.notes` is `off`
- **THEN** the chats are still restored, the orphans are left and tnotes is not asked
- **AND** any other value of `resurrect.notes`, or none, means `reopen`; a missing `tnotes` is not an error

#### Scenario: A window named for the holder plus a Cyrillic letter
- **WHEN** an unlinked editor in a returned `ta-notes` session sits in a window named `holdя`
- **THEN** it is closed with the rest of the session

### Requirement: What does not come back
A restore SHALL NOT bring back scrollback, an `/effort` set inside a session, a chat on a login without the state hook (it has no record), headless sessions (`s-*`), the commands of the user's other panes (they come back as idle shells in their working directories through tmux-resurrect), a chat's joined position (it comes back in a window of its own), or a shell under the resumed chat: the pane runs `claude --resume` itself, so `/exit` closes the pane. A chat hung up on purpose through tagents SHALL be out of the next snapshot and so not come back.

#### Scenario: Headless session
- **WHEN** a headless session was running before the reboot
- **THEN** it has no row and is not resurrected

#### Scenario: A dev server beside the chat
- **WHEN** a window held a chat and a pane running a dev server
- **THEN** the dev server pane comes back as an idle shell and its command is not run

## ADDED Requirements

### Requirement: Snapshots from the seat-based version still restore
A snapshot written before windows became rows SHALL restore: its docked column is read and ignored, a chat that was docked comes back at the session, window and pane recorded for its home seat, and its `D` row is handled like any other.

#### Scenario: A docked chat in an old snapshot
- **WHEN** a snapshot holds a row with `1` in the docked column for a chat whose home seat was pane 1 of window 1 of session `proj`
- **THEN** the restore places the chat at `proj:1.1` as it would any other chat

### Requirement: Chats are filed where their panes are
A capture SHALL record each chat at the session name, window index and pane index that tmux reports for its pane, the index counting every pane of the window including the sidebar and the user's panes.

#### Scenario: A chat beside a shell
- **WHEN** a chat is pane 1 of window 2 of session `proj`, with the sidebar as pane 0 and a shell as pane 2
- **THEN** its row says session `proj`, window 2, pane 1

### Requirement: A joined chat is filed under its home session
A chat joined into another window with `ctrl-s` SHALL be recorded under the session its `@tagents_joined` names, with the window index and the pane index empty, so that a restore gives it a window of its own there.

#### Scenario: A joined chat
- **WHEN** a chat joined from session `personal` is a pane of a window of session `work`
- **THEN** its row says session `personal` and has empty window and pane columns

### Requirement: The sidebar is filed by its window
When the sidebar is up the snapshot SHALL hold one `D` row of three columns: `D`, the session name and the window index of the window the sidebar is in.

#### Scenario: Sidebar window
- **WHEN** the sidebar is in window 3 of session `work`
- **THEN** the snapshot has the row `D`, `work`, `3`

### Requirement: The notes column says whether the chat has its editor beside it
The notes column SHALL be `1` when the chat's notes editor is a pane of the chat's own window, and empty when the chat has none.

#### Scenario: No editor
- **WHEN** a chat has no notes editor
- **THEN** the notes column of that chat's row is empty

#### Scenario: Editor beside its chat
- **WHEN** the editor is a pane of the chat's window
- **THEN** the notes column is `1`

### Requirement: The sidebar comes back
When the snapshot holds a `D` row, the restore SHALL bring the sidebar back once the chats are placed and report `✓ dashboard`: the list is started as the leftmost full-height pane of the recorded window when that window exists after the restore, and of the window of the first chat restored otherwise. A window that tmux-resurrect left from an older snapshot's dashboard SHALL be an ordinary window and keep what it runs.

#### Scenario: Dashboard row
- **WHEN** the snapshot holds a `D` row whose window is restored
- **THEN** the report says `✓ dashboard` and the list runs as the leftmost pane of that window and claims the sidebar

#### Scenario: The window is gone
- **WHEN** the `D` row names a window that does not exist after the restore
- **THEN** the sidebar is in the window of the first chat restored

### Requirement: The restore closes the sidebar's leftover panes
After the chats and the sidebar are up, the restore SHALL close every idle shell titled `tagents-sidebar` that is not the live list, as the `window-rows` capability says, and SHALL touch no other pane. A dry run SHALL close nothing.

#### Scenario: Shells where the sidebar was
- **WHEN** the snapshot's windows were restored with an idle shell titled `tagents-sidebar` in each
- **THEN** after `tagents --resurrect` those shells are gone and the chats are untouched

#### Scenario: Dry run
- **WHEN** `tagents --resurrect --dry-run` runs
- **THEN** no pane is closed

## REMOVED Requirements

### Requirement: A docked chat is filed at its home seat
**Reason**: Nothing is docked, so no chat is filed at a home seat; every chat is filed where its pane is.
**Migration**: "Chats are filed where their panes are", "A joined chat is filed under its home session" and "The sidebar is filed by its window" in this capability.

### Requirement: The notes editor counts only while it is on screen
**Reason**: Editors are never parked, so there is no time when an editor is off screen but still beside its chat.
**Migration**: "The notes column says whether the chat has its editor beside it" in this capability.

### Requirement: The dashboard comes back
**Reason**: There is no dedicated dashboard window to bring back, and docked chats no longer exist to come back undocked.
**Migration**: "The sidebar comes back" in this capability.
