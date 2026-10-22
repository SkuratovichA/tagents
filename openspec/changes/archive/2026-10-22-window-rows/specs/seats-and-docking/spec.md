## REMOVED Requirements

### Requirement: Seats are the panes the dashboard marks, never a position
**Reason**: The sidebar window no longer holds seats: the sidebar is one pane that travels to the window of the row selected.
**Migration**: The `window-rows` capability: "Panes beside a chat belong to the user" keeps every pane that is not a chat or the sidebar untouched.

### Requirement: The seat listing verb
**Reason**: There are no seats to list.
**Migration**: None. `tagents --seats` is removed; the list shows where every chat is.

### Requirement: Enter docks a chat into the current seat by swapping
**Reason**: A chat is never swapped out of its window any more.
**Migration**: The `window-rows` capability: "Selecting a row puts the sidebar and the client in its window".

### Requirement: Enter replaces the seat the cursor was last in
**Reason**: There is no seat to replace and nothing is sent home.
**Migration**: The `window-rows` capability: "Selecting a row puts the sidebar and the client in its window".

### Requirement: Enter on a chat already docked goes to it
**Reason**: Nothing is docked.
**Migration**: The `window-rows` capability: the "Already there" scenario of "Selecting a row puts the sidebar and the client in its window".

### Requirement: Ctrl-s docks a chat into a new seat beside the current one
**Reason**: A second chat beside the current one is a joined pane now, not a seat.
**Migration**: The `window-rows` capability: "Ctrl-s joins a chat into the window on screen".

### Requirement: Ctrl-s with nothing docked behaves like enter
**Reason**: There is no free seat to dock into.
**Migration**: The `window-rows` capability: "Ctrl-s joins a chat into the window on screen"; `enter` selects a row.

### Requirement: A dock never leaves a marker or a pane behind when it fails
**Reason**: There is no dock and no parked marker.
**Migration**: The `window-rows` capability: the "The window closed after the row was drawn" scenario of "Selecting a row puts the sidebar and the client in its window".

### Requirement: The current seat is the one the cursor was last in
**Reason**: `@tagents_cur` and `tagents --current-seat` are removed with the seats.
**Migration**: None. The window on screen is the current place.

### Requirement: The current-seat marker is kept honest
**Reason**: `@tagents_cur` is removed with the seats.
**Migration**: The `window-rows` capability: "The first start after the upgrade cleans up the seats" removes the leftover option.

### Requirement: The list marks the docked chats
**Reason**: No chat is docked, so the list has nothing to mark.
**Migration**: The `dashboard-list` capability no longer draws `▶` and `▹`.

### Requirement: Ctrl-u sends the current seat's chat home
**Reason**: A chat is never docked, so there is nothing to send home.
**Migration**: The `window-rows` capability: "Ctrl-u breaks a joined chat out into a window of its own".

### Requirement: The last seat is never closed
**Reason**: There are no seats.
**Migration**: The `window-rows` capability: "The sidebar is never closed".

### Requirement: Collapsing seats takes a lock, one seat at a time
**Reason**: Seats are never collapsed, so `tagents --collapse` and `.collapse.lock` are removed.
**Migration**: None.

### Requirement: Undock-pane sends one chat home and tells a binding whether it did
**Reason**: A chat lives in a window of its own, so closing a pane in the sidebar window cannot hang up a docked session; `tagents --undock-pane` is removed.
**Migration**: None. A `kill-pane` binding that called it has nothing to ask first.

### Requirement: Undock-window empties a sidebar for a kill-window binding
**Reason**: No chat is docked in a sidebar window; `tagents --undock-window` is removed.
**Migration**: None. A `kill-window` binding that called it has nothing to ask first.

### Requirement: The window title bar shows undock only while a chat is docked
**Reason**: No chat is docked, so the sidebar window's `pane-border-status` is no longer touched.
**Migration**: None.

### Requirement: Focusing a placeholder outside the sidebar brings its chat home
**Reason**: There are no placeholders; `tagents --unpark` is removed.
**Migration**: The `window-rows` capability: "The first start after the upgrade cleans up the seats" closes the placeholders left behind.

### Requirement: A late focus trigger does not undo a fresh dock
**Reason**: There is no unpark and no dock.
**Migration**: The `window-rows` capability: "Following never loops and never fights a closing window" covers a late trigger of the new hooks.

### Requirement: A placeholder tells where it stands and watches for its chat
**Reason**: There are no placeholders; `tagents --slot` is removed.
**Migration**: None.

### Requirement: A placeholder waits for tmux to say something moved
**Reason**: There are no placeholders to wait.
**Migration**: None.

### Requirement: A stranded placeholder looks again after one second
**Reason**: There are no placeholders.
**Migration**: None.

### Requirement: What rings the placeholders
**Reason**: There are no placeholders to ring; the channel `tagents-panes` is no longer rung.
**Migration**: None.

### Requirement: A stranded placeholder closes itself
**Reason**: There are no placeholders.
**Migration**: None.

### Requirement: The sidebar always has a seat
**Reason**: There are no seats to repair; `tagents --ensure-seat` and `tagents --current-seat` are removed.
**Migration**: None.

### Requirement: A chat that exits while docked leaves the sidebar a seat
**Reason**: Nothing is docked.
**Migration**: The `window-rows` capability: "The sidebar is never closed".

### Requirement: Which pane is the sidebar
**Reason**: The capability is removed in full, but this rule survives unchanged in what it says about the markers.
**Migration**: The `window-rows` capability: "Which pane is the sidebar".

### Requirement: A list claims the sidebar and gives it up on exit
**Reason**: The capability is removed in full, but a list still claims the sidebar and gives it up on exit.
**Migration**: The `window-rows` capability: "A list claims the sidebar and gives it up on exit".

### Requirement: The dedicated dashboard session
**Reason**: The `agents` session and its window `agents:1` stop being special.
**Migration**: The `window-rows` capability: the sidebar is started where `tagents` is run and "The sidebar follows the window on screen" brings it to every window on screen.

