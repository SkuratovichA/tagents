# cockpit Specification

## Purpose
An opt-in dashboard layout, `dashboard.layout: cockpit`, in which the list never moves: it lives in one session `tagents` beside a viewport, a second client of the same tmux server that shows whichever window a row names. Selecting a row points the viewport and puts the keyboard there, moving inside the viewport moves only the list's cursor, and the layout comes down in order on `ctrl-q`, so the sidebar no longer blinks on a window or session switch.
## Requirements
### Requirement: The layout is chosen by dashboard.layout
The dashboard SHALL use the cockpit layout when the config key `dashboard.layout` is `cockpit`, and the `follow` layout the `window-rows` capability describes when the key is `follow`, absent or unreadable. The key SHALL be read each time a sidebar list is to be started, and a running list keeps its layout until it exits. While the cockpit is up, a popup list and every flag that selects a row SHALL act in the cockpit whatever the config says.

#### Scenario: Cockpit chosen
- **WHEN** the config sets `dashboard.layout` to `cockpit` and `tagents --ensure-dash` runs for a client in window `work:2`
- **THEN** a session `tagents` exists with the list on its left and the viewport on its right

#### Scenario: No dashboard section
- **WHEN** the config has no `dashboard` section and `tagents --ensure-dash` runs for a client in window `work:2`
- **THEN** the sidebar is the leftmost pane of `work:2` and no session `tagents` exists

#### Scenario: Changed while the cockpit is up
- **WHEN** the cockpit is up and `dashboard.layout` is changed to `follow`
- **THEN** the cockpit stays as it is until `ctrl-q`, and the next list started uses the `follow` layout

### Requirement: The dashboard is a session of its own
In the cockpit the dashboard SHALL be a tmux session named `tagents`, with the session option `@tagents_cockpit` set to `1`, the status line off and `detach-on-destroy` off, holding one window of two full-height panes: the list on the left at `TA_WIDTH` percent of the window's width (default 45), and the viewport on the right. The cockpit is up while that session exists, and its list claims the sidebar as the `window-rows` capability describes.

#### Scenario: A new dashboard
- **WHEN** the cockpit starts in a terminal 200 columns wide with `TA_WIDTH` unset
- **THEN** the session `tagents` has one window whose left pane is the list, 90 columns wide within one column, and whose right pane is the viewport
- **AND** the session `tagents` has `@tagents_cockpit` set to `1` and `status` set to `off`

#### Scenario: Its terminals outlive it
- **WHEN** the session `tagents` is killed while a terminal is attached to it and the session `work` exists
- **THEN** that terminal shows the session `work` and is not detached

### Requirement: A taken name stops the cockpit
When a session named `tagents` exists that neither carries `@tagents_cockpit` nor is a leftover dashboard, the cockpit SHALL NOT start: `tagents --ensure-dash`, a list started for the cockpit and the restore SHALL print `tagents: session tagents is taken — rename it or set dashboard.layout: follow` on standard error, create nothing and change nothing in that session, and `tagents --ensure-dash` SHALL exit 1.

#### Scenario: Someone else's session
- **WHEN** the layout is `cockpit` and a session named `tagents` runs `vim` in its only pane
- **THEN** `tagents --ensure-dash` prints `tagents: session tagents is taken — rename it or set dashboard.layout: follow` on standard error and exits 1
- **AND** that session still runs `vim` and no session was created

### Requirement: The viewport is a client of the same server in a pane
The dashboard's right pane SHALL be the viewport: titled `tagents-viewport`, with the pane options `@tagents_viewport` set to `1` and `allow-set-title` off, and running `tagents --viewport`, which keeps a client of the same tmux server attached to the session being shown. While that client runs, the global option `@tagents_viewport_tty` SHALL hold its tty. `tagents --viewport` started anywhere else SHALL print an error and exit 1.

#### Scenario: The pane and its client
- **WHEN** the cockpit is up and the viewport shows the session `work`
- **THEN** the dashboard's right pane is titled `tagents-viewport` and has `@tagents_viewport` set to `1`
- **AND** `tmux list-clients` lists a client attached to `work` whose tty is the value of `@tagents_viewport_tty`

#### Scenario: A title set from inside
- **WHEN** the user's tmux config has `set-titles on` and the viewport shows another window
- **THEN** the viewport's pane is still titled `tagents-viewport`

#### Scenario: Anywhere else
- **WHEN** `tagents --viewport` runs in a pane that is not the dashboard's right pane
- **THEN** it prints `tagents: --viewport runs only in the cockpit's viewport pane` on standard error and exits 1

### Requirement: Selecting a row points the viewport
In the cockpit, selecting a row as the `window-rows` capability describes it — `enter`, a double-click, `ctrl-g`, a header, `tagents --goto`, `tagents --act open`, a new chat or shell — SHALL switch the viewport's client to that window, or to the session's current window for a header, and make the viewport the dashboard's active pane. No pane SHALL change window, and a terminal attached to the dashboard SHALL stay on it.

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

### Requirement: The cockpit stands in for the follow layout's moves
Wherever another capability says that the sidebar is moved into a window, or that a client is switched or taken to a window — `window-rows`, `dashboard-popup`, `chat-launch`, `notify` and `tnotes toggle` — the cockpit SHALL instead point the viewport at that window as a selection does, and SHALL leave the sidebar in the dashboard.

#### Scenario: A popup's enter
- **WHEN** the cockpit is up and the user presses `enter` on a chat in a popup list
- **THEN** the viewport shows the chat's window, the list is still the dashboard's left pane, and the popup closes

#### Scenario: tnotes toggle
- **WHEN** the viewport shows `work:1` and `tnotes toggle` runs for a chat whose editor is in `work:3`
- **THEN** the viewport shows `work:3` with the editor's pane active, and the user's terminal still shows the session `tagents`

### Requirement: Selections for other terminals take them to the dashboard
A selection made for a terminal that is not attached to the dashboard — a popup opened from a terminal attached to another session, or `tagents --goto` or `tagents --act open` acting for the client used last — SHALL point the viewport as any selection does and switch that terminal to the session `tagents`. When the terminal it acts for is the viewport's client or a terminal on the dashboard, no client SHALL change session.

#### Scenario: A popup from another session
- **WHEN** the cockpit is up, a terminal attached to the session `work` opens the popup, and the user presses `enter` on a chat in `personal:1`
- **THEN** the viewport shows `personal:1` and that terminal shows the session `tagents`

#### Scenario: A notification clicked
- **WHEN** the user last typed in the viewport and `tagents --goto %12` runs outside tmux
- **THEN** the viewport shows the window of `%12` and no client has changed session

### Requirement: A terminal on the dashboard is in the viewport's window
While the cockpit is up, wherever another capability speaks of the window on screen, the window or session a client is in, or the session of the client, a terminal attached to the dashboard and the viewport's client SHALL count as being in the window the viewport shows. So `ctrl-s` joins a chat into that window, and a new chat or shell bound for the client's session goes to that window's session.

#### Scenario: ctrl-s
- **WHEN** the viewport shows `work:2` and the user presses `ctrl-s` on the row of a chat in `personal:1`
- **THEN** the chat's pane is in the window `work:2`

#### Scenario: A new chat from outside tmux
- **WHEN** the viewport shows `work:2`, the dashboard's terminal is the client used last, and `tagents --new` runs outside tmux in a directory where no chat runs
- **THEN** the new chat's window is created in the session `work`

### Requirement: The dashboard is never a group and never a destination
The session `tagents` SHALL never be a group of the list and its window SHALL never be a row, and tagents SHALL NOT create a window in it or move a pane into it, whichever key, flag or restore asks for one.

#### Scenario: Not listed
- **WHEN** the cockpit is up and the sessions `work` and `personal` exist
- **THEN** the list has the headers `work` and `personal` and no header `tagents`

#### Scenario: Still two panes
- **WHEN** chats and shells are created and joined with `ctrl-n`, `ctrl-a` and `ctrl-s` while the cockpit is up
- **THEN** the session `tagents` still has one window holding only the list and the viewport

### Requirement: The viewport never shows the dashboard
The viewport's client SHALL never stay on the session `tagents`. A step onto it SHALL go on in the same direction of tmux's session order, a pick of it SHALL show a session next to it in that order, and when the shown session is closed the viewport SHALL show the last session it showed that still exists, else the other session used most recently. With no other session it SHALL read `tagents: no session to show` and attach once one exists.

#### Scenario: Next, past the dashboard
- **WHEN** the sessions are `personal`, `tagents` and `work`, the viewport shows `personal` and the user presses `prefix )`
- **THEN** the viewport shows `work`

#### Scenario: Previous, past the dashboard
- **WHEN** the same sessions exist, the viewport shows `work` and the user presses `prefix (`
- **THEN** the viewport shows `personal`

#### Scenario: Picked in the chooser
- **WHEN** the same sessions exist, the viewport shows `work` and the user picks `tagents` with `prefix s` in the viewport
- **THEN** the viewport shows `personal`

#### Scenario: Round the end of the order
- **WHEN** the sessions are `alpha`, `beta` and `tagents`, the viewport shows `beta` and the user presses `prefix )`
- **THEN** the viewport shows `alpha`
- **AND** a `prefix (` pressed next shows `beta` again

#### Scenario: The shown session is closed
- **WHEN** the viewport showed `personal`, then `work`, and the session `work` is killed
- **THEN** the viewport shows `personal`

#### Scenario: Nothing else to show
- **WHEN** every session but `tagents` is killed
- **THEN** the viewport reads `tagents: no session to show`
- **AND** once a session `scratch` is created the viewport shows it

### Requirement: Changes inside the viewport move only the cursor
A window or session change of the viewport's client SHALL move the list's cursor to the window the viewport then shows and SHALL move no pane. A change of any other client SHALL move no pane while the cockpit is up, and SHALL move the cursor only when it changes the window the viewport shows. The `tagents --follow` hooks of the `window-rows` capability SHALL stay as they are in both layouts.

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

### Requirement: ctrl-q leaves the cockpit
`ctrl-q` in the cockpit's list SHALL switch every terminal attached to the dashboard to the window the viewport shows, then close the session `tagents` with its viewport, and remove from the server the hook, the key table `tagents-cockpit` and the option `@tagents_viewport_tty` the cockpit added. With no window to show, those terminals SHALL be detached.

#### Scenario: Quit
- **WHEN** the viewport shows `work:2` and the user presses `ctrl-q` in the list
- **THEN** the user's terminal shows `work:2` with no sidebar, and no session `tagents` exists
- **AND** `tmux list-keys -T tagents-cockpit` lists nothing and the global option `@tagents_viewport_tty` is unset

### Requirement: ensure-dash makes or reuses the cockpit
In the cockpit `tagents --ensure-dash` SHALL make the dashboard when it is not up, start again any of its panes that is missing, point the viewport at the window its client was in and switch that client to `tagents`; for a terminal on the dashboard or the viewport's client it SHALL switch nothing and make the list the active pane, and with no client it SHALL make nothing and exit 1. A list started in a pane outside the dashboard SHALL do what `--ensure-dash` does for that pane's client and end.

#### Scenario: From another session
- **WHEN** the cockpit is not up and the key bound to `tagents --ensure-dash` is pressed in a terminal showing `work:2`
- **THEN** the session `tagents` exists, the viewport shows `work:2`, and that terminal shows the session `tagents`

#### Scenario: From the viewport
- **WHEN** the keyboard is in the viewport and the key bound to `tagents --ensure-dash` is pressed
- **THEN** the list is the dashboard's active pane and the viewport shows the window it showed

#### Scenario: tagents typed in a shell
- **WHEN** the layout is `cockpit` and the user runs `tagents` in a shell pane of `work:2`
- **THEN** the viewport shows `work:2`, the user's terminal shows the session `tagents`, and the shell pane is back at its prompt

#### Scenario: No client
- **WHEN** the layout is `cockpit`, no terminal is attached to the tmux server and `tagents --ensure-dash` runs
- **THEN** it exits 1 and no session `tagents` exists

### Requirement: prefix d in the viewport detaches the terminal
`prefix d` pressed in the viewport SHALL detach the dashboard's terminal used last, the one that typed it, as `prefix d` does without the cockpit. The viewport's client SHALL attach again to the session it showed, so that the dashboard is whole at the next `tmux attach -t tagents`.

#### Scenario: Detach and come back
- **WHEN** the keyboard is in the viewport, which shows `work:2`, and the user presses `prefix d`
- **THEN** the user's terminal is detached from tmux, and the session `tagents` still has a viewport attached to `work`
- **AND** after `tmux attach -t tagents` the user sees the list and `work:2`

### Requirement: The dashboard's keys go to the viewport's client
The session `tagents` SHALL set `prefix` and `prefix2` to `None` and `key-table` to `tagents-cockpit`. That table SHALL bind each prefix key the user has when the dashboard starts to make the viewport the active pane and send it that key, and SHALL hold the root table's mouse bindings that do not open a menu. Every other key SHALL go to the active pane, so the list gets its own keys.

#### Scenario: Prefix from the list
- **WHEN** the list is the active pane, the viewport shows `work:2`, and the user presses `prefix c`
- **THEN** a new window of the session `work` is shown in the viewport, and the viewport is the active pane

#### Scenario: The list's own keys
- **WHEN** the list is the active pane and the user presses `ctrl-n`
- **THEN** the list handles it as the `chat-launch` capability describes

#### Scenario: A click on the list
- **WHEN** the viewport is the active pane and the user clicks a row of the list
- **THEN** the list is the active pane and the cursor is on that row

#### Scenario: A root binding
- **WHEN** the user's tmux config binds `M-h` in the root table and the viewport is the active pane
- **THEN** pressing `M-h` runs that binding in the window the viewport shows

### Requirement: Popups and messages appear on the dashboard
A popup the list opens — the `?` window, a prompt, the preview modal — SHALL open on the dashboard's terminal used last, over the whole dashboard and never inside the viewport. A status message tagents shows for an action taken in the cockpit SHALL be shown on the viewport's client, whose status line is the one on screen.

#### Scenario: The keys window
- **WHEN** the user presses `?` in the cockpit's list
- **THEN** the keys window opens on the user's terminal over both the list and the viewport

#### Scenario: A new shell's message
- **WHEN** the cursor is on the dimmed row `server` of session `scratch`, whose first pane runs in `~/app`, and the user presses `ctrl-a` in the cockpit's list
- **THEN** the viewport shows the new window of `scratch`, and its status line shows `tagents: new shell in app (scratch:N)`, `N` being the new window's index

### Requirement: A missing list or viewport comes back
While the cockpit is up, when the list's pane or the viewport's pane of the dashboard is gone — killed, or its program ended other than by `ctrl-q` — it SHALL be started again in its place and at its width within about a second. A viewport started again SHALL show the session the old one showed.

#### Scenario: The viewport is killed
- **WHEN** the viewport's pane is killed with `tmux kill-pane` while it shows `work:2`
- **THEN** within about a second a new viewport is the dashboard's right pane, showing `work:2`

#### Scenario: The list is killed
- **WHEN** the list's pane is killed
- **THEN** within about a second a new list is the dashboard's left pane at `TA_WIDTH` percent and has claimed the sidebar

### Requirement: A leftover dashboard is rebuilt in place
A session `tagents` without `@tagents_cockpit` whose only window holds two idle shells, titled `tagents-sidebar` and `tagents-viewport`, as tmux-resurrect restores a cockpit, is a leftover dashboard. In the cockpit, `tagents --ensure-dash` and the restore SHALL start the list and the viewport in those panes and set the options the dashboard carries, detaching no client. In the follow layout they SHALL switch the leftover's clients to the window the sidebar is in and close the leftover.

#### Scenario: Restored in the cockpit
- **WHEN** tmux-resurrect restored a session `tagents` holding two idle shells titled `tagents-sidebar` and `tagents-viewport`, a terminal is attached to it, and the layout is `cockpit`
- **THEN** after `tagents --resurrect` those two panes run the list and the viewport, and the terminal was never detached

#### Scenario: Restored in the follow layout
- **WHEN** the same leftover exists, a terminal is attached to it, and the layout is `follow`
- **THEN** after `tagents --resurrect` the terminal shows the window the sidebar is in, and no session `tagents` exists

