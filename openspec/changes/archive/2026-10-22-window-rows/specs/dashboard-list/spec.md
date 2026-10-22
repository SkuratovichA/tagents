## RENAMED Requirements
- FROM: `### Requirement: A project header shows the project and what is going on in it`
- TO: `### Requirement: A group header shows the session and what is going on in it`
- FROM: `### Requirement: A project header stands in for the row directly under it`
- TO: `### Requirement: A group header stands in for the row directly under it`
- FROM: `### Requirement: Projects keep the place their path gives them`
- TO: `### Requirement: Groups keep the place their name gives them`
- FROM: `### Requirement: Inside a project rows follow the user's last message`
- TO: `### Requirement: Inside a group rows follow the user's last message`

## MODIFIED Requirements

### Requirement: The list is produced by `tagents --list`
`tagents --list` SHALL print one line per row of the list for fzf to read, each line made of five TAB-separated fields: the row key (the pane id of a chat, the window id of a dimmed window row), the text of the row with its colours, the row's state, the session id and the directory. `tagents --flat` SHALL print the same list ungrouped whatever mode is saved.

#### Scenario: Row fields
- **WHEN** a session in `~/projects/app` is running in pane `%12` with session id `a1b2c3d4-…`
- **THEN** its line starts with `%12`, the fourth and fifth fields are its session id and its absolute directory, and the third field is its state word (`working`, `done`, `blocked`, `new`, `?` or `dead`)

#### Scenario: Nothing is running
- **WHEN** the dashboard has no row to show
- **THEN** the list it hands to fzf is one dim line reading `no claude sessions running` with the key `-` and the state `none`

#### Scenario: A dimmed window row
- **WHEN** a window of a group runs no chat
- **THEN** its line starts with the window id, for example `@7`, and its third and fourth fields are `none` and empty

### Requirement: ctrl-t switches between the tree and a flat list
`ctrl-t` SHALL switch between the tree and a flat list without headers, and the choice SHALL persist across restarts in a marker file in the state directory; switching rings the refresher's channel. `TA_FLAT=1` SHALL force the flat list for one run. A flat list SHALL hold chats only, with no dimmed window rows. A flat row SHALL carry the name of its group, the session or `no window`, in a column of its own, which hiding the `loc` column does not remove.

#### Scenario: Toggling
- **WHEN** the user presses `ctrl-t` twice
- **THEN** the list is flat after the first press and a tree again after the second

#### Scenario: Flat rows name their project
- **WHEN** the list is flat and at least 98 columns are available
- **THEN** each row names its group, the session or `no window`, as well as the agent, also when `loc` is hidden

#### Scenario: No dimmed rows when flat
- **WHEN** a group has a window that runs no chat and the list is flat
- **THEN** that window has no line
### Requirement: A group header shows the session and what is going on in it
The header of a group SHALL read `▾ <group name>`, then the group's path with `~` for the home directory when the list is 92 columns wide or more, then one badge per state present, then the five-hour cost total. The path of a session group is the session's working directory as tmux reports it, and the group `no window` shows no path. It SHALL be bold when at least one row in the group is not closed, a dimmed window row counting as not closed, and dim when every row is closed.

#### Scenario: Badges
- **WHEN** a group has one blocked, one idle and one working agent
- **THEN** its header ends with `⚠1 ✓1 ●1` in the order blocked, idle, working, new, unknown, closed, each coloured as its state

#### Scenario: Narrow pane drops the path
- **WHEN** the list is built for fewer than 92 columns
- **THEN** the header shows the group name and badges but not the path

#### Scenario: Five-hour total
- **WHEN** a group has spent money in the last five hours, the list is 60 columns wide or more and `cost` is not hidden
- **THEN** its header ends with the total as `$x/5h`

#### Scenario: Session name
- **WHEN** the group is session `release notes`
- **THEN** its header reads `▾ release notes`
### Requirement: A group header stands in for the row directly under it
A group header line SHALL carry the key, state, session id and directory of the row printed directly beneath it, so a key that acts on an agent (send, rename, kill, pick) pressed on a header acts on that agent. `enter` and `ctrl-g` on the header of a session group SHALL instead show the session (the `window-rows` capability). That row is chosen among the rows of the group that are not child sessions: open chats before dimmed window rows before closed rows, and among chats the one typed into most recently. A child is chosen only when the group has nothing else.

#### Scenario: Header and first row agree
- **WHEN** a group has a closed and a live agent
- **THEN** the header's key equals the key of the first row beneath it, which is the live one

#### Scenario: A group of windows only
- **WHEN** a session tagents created holds one window `server` and no chat
- **THEN** the header carries the window id of `server`, the state `none` and no session id

### Requirement: Groups keep the place their name gives them
Session groups SHALL be ordered by session name, not by urgency. A group SHALL NOT climb the list when one of its agents blocks or drop back when the agent is answered. The only session group that moves is one in which every row is closed, which sorts to a dim section after every session group with a live row. The group `no window` SHALL always be the last group.

#### Scenario: Sessions by name
- **WHEN** sessions `work` and `personal` hold chats
- **THEN** the header `personal` comes before `work`

#### Scenario: Blocking does not reorder
- **WHEN** an agent in the second group blocks
- **THEN** the order of the groups is unchanged

#### Scenario: Closed-only project sinks
- **WHEN** a session group holds only closed rows
- **THEN** it is listed after every session group that has a live row, even when its name sorts first

#### Scenario: The trailing group is last
- **WHEN** the group `no window` holds a live headless session and a session group holds only closed rows
- **THEN** `no window` is listed after that session group
### Requirement: Inside a group rows follow the user's last message
Rows inside a group SHALL be ordered by when the user last typed into the session, newest first, then the dimmed window rows in window order, then the closed rows, and never by state or by anything that changes during a turn. A child SHALL be placed with its parent, parent first, then its own children. In a flat list the same rule applies to the whole list: open rows before closed, newest conversation first.

#### Scenario: State changes do not move rows
- **WHEN** an agent goes from working to blocked and back
- **THEN** its position among its siblings is unchanged

#### Scenario: Typing moves a row to the top
- **WHEN** the user sends a prompt to an agent that was second in its group
- **THEN** after the next refresh it is first

#### Scenario: Window rows follow the chats
- **WHEN** a group has a window that runs no chat and two chats
- **THEN** the dimmed row is listed after both chats and before any closed row

### Requirement: Sessions with no pane are listed as headless
A session started with `claude -p` by a daemon, a job or `nohup`, with no tmux pane in its ancestry, SHALL be listed in the group `no window`, with `headless` in the location column. It is live while the process id its record names is alive, and shows the ordinary states.

#### Scenario: Headless row location
- **WHEN** a headless session is running
- **THEN** its location column reads `headless` where other rows show a pane

#### Scenario: Ended headless session
- **WHEN** the process of a headless session has exited
- **THEN** its row is dimmed `✗ closed` and its detail reads `headless, ended — nothing to resume`

#### Scenario: Its name
- **WHEN** a headless session has no label of its own
- **THEN** its name is `$TA_LABEL` as announced at launch, else the title the session gave itself, else the directory name

### Requirement: Closed rows say whether they can be resumed
A row whose Claude process is gone but whose record is younger than `TA_DEAD_TTL` seconds (default 86400) SHALL be listed as closed and dimmed, below the live rows of its group. Its detail text SHALL be `closed — enter resumes it`, or `closed, no session id — cannot resume` when the record has no session id.

#### Scenario: Expired corpse
- **WHEN** a closed record is older than `TA_DEAD_TTL`
- **THEN** it has no row in the list, and the `closed-sessions` capability is how to reach it

#### Scenario: Resumed elsewhere
- **WHEN** a record is closed but another record with the same session id belongs to a running Claude
- **THEN** the closed record has no row

## ADDED Requirements

### Requirement: Rows are grouped into a tree by session
By default rows SHALL be grouped by session: one header line per group followed by that group's rows, drawn with `├` and `└` tees. A row whose chat has a window SHALL be in the group of that window's tmux session, and the header SHALL name the session (which sessions are groups is the `window-rows` capability's).

#### Scenario: Tree is the default
- **WHEN** two chats run in session `work` and nothing has been toggled to flat
- **THEN** the list has one header line for `work` and two rows under it

#### Scenario: Two directories, one session
- **WHEN** the two chats of session `work` run in `~/projects/app` and `~/projects/api`
- **THEN** both rows are under the header `work`

#### Scenario: Two sessions that differ only in a Cyrillic letter
- **WHEN** sessions `я` and `ю` hold chats, two of them in the first
- **THEN** the list has a header for each, the two rows of `я` sit together under its header, and the last row of each group is drawn with `└`

### Requirement: Rows with no window form the last group
Every row with no window, a closed session whose pane is gone and a headless session, SHALL be in one trailing group headed `no window`, which is always the last group.

#### Scenario: Rows with no window
- **WHEN** a closed session's pane is gone and a headless session runs, and a session called `app` holds chats
- **THEN** both are under one header `no window`, listed after the header `app`, even when a session called `no window` exists

### Requirement: A subdirectory is shown in front of the detail text
A session started in a subdirectory of its repository SHALL show the subdirectory, relative to the root of that repository, in front of its detail text, whichever group it is in.

#### Scenario: Subdirectory
- **WHEN** a session runs in `~/projects/app/packages/client`
- **THEN** its detail text starts with `packages/client`

#### Scenario: Subdirectory of a Cyrillic repository
- **WHEN** a session runs in `~/projects/я/src`, below its own repository
- **THEN** its detail text starts with `src`
## REMOVED Requirements

### Requirement: Rows are grouped into a tree by project
**Reason**: A group is a tmux session now, not the repository root of a directory, and the project names that the Cyrillic scenarios tested no longer head anything.
**Migration**: "Rows are grouped into a tree by session", "Rows with no window form the last group" and "A subdirectory is shown in front of the detail text" in this capability.

### Requirement: Docked chats are marked in the tree
**Reason**: No chat is docked any more, so there is no seat for `enter` to replace and nothing for the list to mark.
**Migration**: None. The list draws a dash before every row as before; which window is on screen is the tmux status bar's to show, and the `window-rows` capability covers selecting a row.
