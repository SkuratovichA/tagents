## RENAMED Requirements

- FROM: `### Requirement: The layout is chosen by dashboard.layout`
- TO: `### Requirement: The cockpit is the only layout`

- FROM: `### Requirement: The cockpit stands in for the follow layout's moves`
- TO: `### Requirement: A selection from anywhere points the viewport`

## MODIFIED Requirements

### Requirement: The cockpit is the only layout
The dashboard SHALL be the cockpit and nothing else: no list SHALL run in or move into a user's window, and `tagents` or `tagents --ensure-dash` run in any pane SHALL make or reuse the cockpit and switch that client to it. The config key `dashboard.layout` SHALL NOT be read, and a file that still carries it SHALL be accepted without a word.

#### Scenario: From a user window
- **WHEN** `tagents --ensure-dash` runs for a client in window `work:2`
- **THEN** a session `tagents` exists with the list on its left and the viewport on its right, and that client shows it
- **AND** `work:2` holds only the panes it held before

#### Scenario: A config from before
- **WHEN** the config sets `dashboard.layout` to `follow` and `tagents --ensure-dash` runs for a client in window `work:2`
- **THEN** the session `tagents` exists as above and `tagents --check` has nothing to say about the key

#### Scenario: A popup with no cockpit
- **WHEN** no cockpit is up and the user presses `enter` on a chat in a popup list
- **THEN** the cockpit is made, its viewport shows the chat's window and the popup's terminal shows the session `tagents`

### Requirement: The dashboard is a session of its own
The dashboard SHALL be a tmux session named `tagents`, with the session option `@tagents_cockpit` set to `1`, the status line off and `detach-on-destroy` off, holding one window of two full-height panes: the list on the left at `TA_WIDTH` percent of the window's width (default 45), and the viewport on the right. The cockpit is up while that session exists, and its list claims its pane as the `window-rows` capability describes.

#### Scenario: A new dashboard
- **WHEN** the cockpit starts in a terminal 200 columns wide with `TA_WIDTH` unset
- **THEN** the session `tagents` has one window whose left pane is the list, 90 columns wide within one column, and whose right pane is the viewport
- **AND** the session `tagents` has `@tagents_cockpit` set to `1` and `status` set to `off`

#### Scenario: Its terminals outlive it
- **WHEN** the session `tagents` is killed while a terminal is attached to it and the session `work` exists
- **THEN** that terminal shows the session `work` and is not detached

### Requirement: A taken name stops the cockpit
When a session named `tagents` exists that neither carries `@tagents_cockpit` nor is a leftover dashboard, the cockpit SHALL NOT start: `tagents --ensure-dash`, a list started for the cockpit and the restore SHALL print `tagents: session tagents is taken — rename it, and the dashboard can start` on standard error, create nothing and change nothing in that session, and `tagents --ensure-dash` SHALL exit 1.

#### Scenario: Someone else's session
- **WHEN** a session named `tagents` runs `vim` in its only pane
- **THEN** `tagents --ensure-dash` prints `tagents: session tagents is taken — rename it, and the dashboard can start` on standard error and exits 1
- **AND** that session still runs `vim` and no session was created

### Requirement: Selecting a row points the viewport
In the cockpit, selecting a row as the `window-rows` capability describes it — `enter`, a double-click, a header, `tagents --goto`, `tagents --act open`, a new chat or shell — SHALL switch the viewport's client to that window, or to the session's current window for a header, and make the viewport the dashboard's active pane. No pane SHALL change window, and a terminal attached to the dashboard SHALL stay on it.

#### Scenario: Enter on a chat
- **WHEN** the viewport shows `work:1` and the user presses `enter` on the row of a chat in `personal:2`
- **THEN** the viewport shows `personal:2` with the chat's pane active, and the viewport is the dashboard's active pane
- **AND** the user's terminal still shows the session `tagents`

#### Scenario: A header
- **WHEN** the user presses `enter` on the header `scratch`
- **THEN** the viewport shows the current window of the session `scratch`

#### Scenario: Nothing moves
- **WHEN** a row is selected
- **THEN** every pane is in the window it was in before, and the list is still the dashboard's left pane

### Requirement: A selection from anywhere points the viewport
Wherever another capability says that a client is switched or taken to a window — `window-rows`, `dashboard-popup`, `chat-launch`, `notify` and `tnotes toggle` — the cockpit SHALL point the viewport at that window as a selection does. Nothing SHALL move the list: no pane changes window.

#### Scenario: A popup's enter
- **WHEN** the cockpit is up and the user presses `enter` on a chat in a popup list
- **THEN** the viewport shows the chat's window, the list is still the dashboard's left pane, and the popup closes

#### Scenario: tnotes toggle
- **WHEN** the viewport shows `work:1` and `tnotes toggle` runs for a chat whose editor is in `work:3`
- **THEN** the viewport shows `work:3` with the editor's pane active, and the user's terminal still shows the session `tagents`

### Requirement: Changes inside the viewport move only the cursor
A window or session change of the viewport's client SHALL move the list's cursor to the window the viewport then shows and SHALL move no pane. A change of any other client SHALL move no pane while the cockpit is up, and SHALL move the cursor only when it changes the window the viewport shows. The `tagents --follow` hooks of the `window-rows` capability SHALL do this move and nothing else.

#### Scenario: A tab click
- **WHEN** the user clicks the tab of window 3 in the viewport's status line
- **THEN** the viewport shows window 3 of its session and the cursor is on its row
- **AND** every pane is in the window it was in before

#### Scenario: Another terminal
- **WHEN** the viewport shows `personal:1` and a second terminal attached to the session `work` switches to window 3
- **THEN** the cursor stays on the row of `personal:1` and no pane changes window

#### Scenario: The shown session changes window elsewhere
- **WHEN** the viewport shows `work:1` and a second terminal attached to the session `work` switches to window 3
- **THEN** the viewport shows `work:3` and the cursor is on its row

### Requirement: ensure-dash makes or reuses the cockpit
`tagents --ensure-dash` SHALL make the dashboard when it is not up, start again any of its panes that is missing, point the viewport at the window its client was in and switch that client to `tagents`; for a terminal on the dashboard or the viewport's client it SHALL switch nothing and make the list the active pane, and with no client it SHALL make nothing and exit 1. A list started in a pane outside the dashboard SHALL do what `--ensure-dash` does for that pane's client and end.

#### Scenario: From another session
- **WHEN** the cockpit is not up and the key bound to `tagents --ensure-dash` is pressed in a terminal showing `work:2`
- **THEN** the session `tagents` exists, the viewport shows `work:2`, and that terminal shows the session `tagents`

#### Scenario: From the viewport
- **WHEN** the keyboard is in the viewport and the key bound to `tagents --ensure-dash` is pressed
- **THEN** the list is the dashboard's active pane and the viewport shows the window it showed

#### Scenario: tagents typed in a shell
- **WHEN** the user runs `tagents` in a shell pane of `work:2`
- **THEN** the viewport shows `work:2`, the user's terminal shows the session `tagents`, and the shell pane is back at its prompt

#### Scenario: No client
- **WHEN** no terminal is attached to the tmux server and `tagents --ensure-dash` runs
- **THEN** it exits 1 and no session `tagents` exists

### Requirement: ctrl-q leaves the cockpit
`ctrl-q` in the cockpit's list SHALL switch every terminal attached to the dashboard to the window the viewport shows, then close the session `tagents` with its viewport, and remove from the server the hook, the key table `tagents-cockpit` and the option `@tagents_viewport_tty` the cockpit added. With no window to show, those terminals SHALL be detached.

#### Scenario: Quit
- **WHEN** the viewport shows `work:2` and the user presses `ctrl-q` in the list
- **THEN** the user's terminal shows `work:2` and no session `tagents` exists
- **AND** `tmux list-keys -T tagents-cockpit` lists nothing and the global option `@tagents_viewport_tty` is unset

### Requirement: A missing list or viewport comes back
While the cockpit is up, when the list's pane or the viewport's pane of the dashboard is gone — killed, or its program ended other than by `ctrl-q` — it SHALL be started again in its place and at its width within about a second. A viewport started again SHALL show the session the old one showed.

#### Scenario: The viewport is killed
- **WHEN** the viewport's pane is killed with `tmux kill-pane` while it shows `work:2`
- **THEN** within about a second a new viewport is the dashboard's right pane, showing `work:2`

#### Scenario: The list is killed
- **WHEN** the list's pane is killed
- **THEN** within about a second a new list is the dashboard's left pane at `TA_WIDTH` percent and has claimed its pane

### Requirement: A leftover dashboard is rebuilt in place
A session `tagents` without `@tagents_cockpit` whose only window holds two idle shells, titled `tagents-sidebar` and `tagents-viewport`, as tmux-resurrect restores a cockpit, is a leftover dashboard. `tagents --ensure-dash` and the restore SHALL start the list and the viewport in those panes and set the options the dashboard carries, detaching no client. The restore SHALL do so before it brings the dashboard back.

#### Scenario: Restored
- **WHEN** tmux-resurrect restored a session `tagents` holding two idle shells titled `tagents-sidebar` and `tagents-viewport`, and a terminal is attached to it
- **THEN** after `tagents --resurrect` those two panes run the list and the viewport, and the terminal was never detached
