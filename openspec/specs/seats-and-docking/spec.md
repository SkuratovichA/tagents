# seats-and-docking Specification

## Purpose
The sidebar window holds the dashboard list and a column of seats. A seat is either an empty placeholder or a live chat swapped into it. This capability covers docking a chat into a seat, sending it home, the placeholders that keep seats and homes warm, the repair that keeps at least one seat in the window, and which pane counts as the sidebar.

## Requirements

### Requirement: Seats are the panes the dashboard marks, never a position
The dashboard SHALL treat a pane of the sidebar window as a seat only when the pane carries the pane option `@tagents_docked` (a chat, whose value is the id of the sidebar window it is docked into) or `@tagents_slot` set to `1` (a placeholder), and the list pane itself is never a seat. Every other pane of that window, such as a terminal the user split off beside the list, SHALL NOT be swapped, split, broken out or killed by docking, undocking or seat repair, whatever its position is.

#### Scenario: A terminal below the list survives docking
- **WHEN** the user has a terminal pane split below the list and docks one chat, then another, with enter
- **THEN** the terminal is still in the sidebar window and still the same pane
- **AND** no window is created for it and no third column appears
- **AND** the only seat is the second chat

#### Scenario: A placeholder is a free seat
- **WHEN** the sidebar window holds the list, a terminal and one placeholder
- **THEN** `tagents --seats` prints the placeholder as free and does not print the terminal

### Requirement: The seat listing verb
`tagents --seats [PANE]` SHALL print one line for each seat of the window that holds the list pane PANE (default: the current sidebar list), in pane-index order, as the seat's pane id, a TAB, and the word `docked` or `free`. It SHALL print nothing when there is no list or no seat.

#### Scenario: Two chats and no free seat
- **WHEN** chats A and B are docked side by side
- **THEN** `tagents --seats` prints `A<TAB>docked` and `B<TAB>docked` in pane order and nothing else

### Requirement: Enter docks a chat into the current seat by swapping
Opening a chat from the dashboard (enter) SHALL swap the chat's pane with the current seat's placeholder, so both windows keep their pane count and layout, and SHALL leave the cursor in the chat in the sidebar window. The placeholder goes to the chat's former window as the chat's way home. When no sidebar exists, enter SHALL first bring the dedicated dashboard session up.

#### Scenario: Enter on a free seat
- **WHEN** the current seat is a free placeholder and the user presses enter on a live chat
- **THEN** the chat is now in the sidebar window and its pane option `@tagents_docked` holds the sidebar window id
- **AND** the placeholder is in the chat's old window with `@tagents_parked` set to the chat's pane id
- **AND** the number of panes in both windows is unchanged

#### Scenario: Popup mode docks into the sidebar
- **WHEN** the user presses enter from the popup list opened over some other window
- **THEN** the chat is docked into the sidebar's current seat and not into the window the popup was opened over

#### Scenario: The sidebar is in another session
- **WHEN** the sidebar is in a different tmux session than the client and a chat is docked
- **THEN** the client is switched to the sidebar's session

### Requirement: Enter replaces the seat the cursor was last in
When the current seat already holds another chat, enter SHALL send that chat home first, which brings its own placeholder back into the seat, and then swap the new chat into that placeholder. The other seats of the window SHALL NOT be touched. If the repair after a failed send-home would leave a second chat in the seat, the dock SHALL fail and change nothing further, so one key press never evicts two chats.

#### Scenario: Two seats, enter replaces the current one
- **WHEN** chats A and B are docked side by side, the cursor is in A's seat, and the user presses enter on chat C
- **THEN** C is docked in A's seat and A is back in its own window
- **AND** B is still docked in its seat and there are still two seats

### Requirement: Enter on a chat already docked goes to it
Opening a chat that is already docked in this sidebar window, by enter or by ctrl-s, SHALL NOT move it. It SHALL focus the chat's seat, make that seat the current one, and select the sidebar window.

#### Scenario: Enter on a docked chat
- **WHEN** chat A is docked and the user presses enter on A's row
- **THEN** the cursor moves into A's pane and A stays where it was

### Requirement: Ctrl-s docks a chat into a new seat beside the current one
Opening a chat beside (ctrl-s) SHALL split a new placeholder horizontally off the current seat, so the new seat sits to the right of it and the list keeps its width, and SHALL swap the chat into the new seat. The window then reads as `columns(list, A, B)` with both chats live. If the chat is already docked here, ctrl-s SHALL only focus it.

#### Scenario: Two chats side by side
- **WHEN** chat A is docked and the user presses ctrl-s on chat B
- **THEN** both A and B are in the sidebar window, each in a seat of its own
- **AND** each has a placeholder parked for it in its own home window

### Requirement: Ctrl-s with nothing docked behaves like enter
When the current seat is a free placeholder, ctrl-s SHALL dock into that seat and SHALL NOT split a second placeholder, because there is nothing to sit beside.

#### Scenario: Ctrl-s on an empty sidebar
- **WHEN** the only seat is a free placeholder and the user presses ctrl-s on a chat
- **THEN** the chat is docked into that seat
- **AND** no second seat was created

### Requirement: A dock never leaves a marker or a pane behind when it fails
Docking SHALL check that the chat's pane still exists before writing any marker or creating any pane, and SHALL return non-zero for a pane that is gone. A row without a pane (`-`) and the list pane itself SHALL be a successful no-op. When the swap itself fails, the parked marker written for it SHALL be removed again, and a seat that this very call split off SHALL be closed, while a seat that was already there is left alone.

#### Scenario: The chat died after the row was drawn
- **WHEN** the user presses enter or ctrl-s on a row whose pane does not exist
- **THEN** the dock fails
- **AND** no placeholder is marked as parked for the missing pane and no pane is added to the sidebar

### Requirement: The current seat is the one the cursor was last in
The seat that enter replaces and ctrl-u sends home SHALL be chosen in this order, each answer being accepted only if it is a seat of this window: the seat named by the sidebar window's option `@tagents_cur`; then the window's active pane, then the pane that was active before it; then a free placeholder; then the leftmost seat. `tagents --current-seat [PANE]` SHALL print the choice followed by a newline (just a newline when the window has no seat).

#### Scenario: The seat survives a walk through a terminal and the list
- **WHEN** the user focuses chat A's seat, then a terminal in the same window, then the list
- **THEN** `tagents --current-seat` still prints A's pane id

#### Scenario: Focusing the other seat moves it
- **WHEN** the user focuses B's seat after A's
- **THEN** `tagents --current-seat` prints B's pane id

### Requirement: The current-seat marker is kept honest
`@tagents_cur` SHALL be written by every dock and by the focus hooks (see the `refresher` capability), SHALL be removed when the chat it names, or the placeholder that took that chat's place, leaves through an undock, SHALL be left alone when it names some other seat, and SHALL be removed from the sidebar window when the list that owned the window exits.

#### Scenario: Undocking the current chat
- **WHEN** the current seat's chat is sent home
- **THEN** the sidebar window does not carry `@tagents_cur`, so it does not name a chat that left

### Requirement: The list marks the docked chats
The list SHALL draw a `▶` in the marker column of the docked chat whose seat is the current one, a dim `▹` on every other docked chat, and neither on an undocked agent or on a group header. A list rendered for the status bar or for counting (`TA_MARKS=0`) SHALL draw none of these marks. The rest of the row belongs to the `dashboard-list` capability.

#### Scenario: Two docked chats
- **WHEN** A and B are docked and the cursor is in A's seat
- **THEN** A's row carries `▶`, B's row carries `▹` and an undocked agent's row carries neither

#### Scenario: The mark follows the seat
- **WHEN** the user then focuses B's seat
- **THEN** B's row carries `▶` and A's row does not

### Requirement: Ctrl-u sends the current seat's chat home
Undock (ctrl-u) SHALL send the chat in the current seat home. When the current seat is an empty placeholder, which is where the cursor is left after an undock, it SHALL use the first docked chat of the window instead, and it SHALL return non-zero when no chat is docked at all. Sending home swaps the chat back with the placeholder that holds its home, clears `@tagents_docked` on the chat and `@tagents_parked` on the placeholder, and closes the seat behind it unless it is the last one.

#### Scenario: One of two chats goes home
- **WHEN** chats A and B are docked, A's seat is current, and the user presses ctrl-u
- **THEN** A is back in its own window and its seat is closed
- **AND** B stays docked and the layout shrinks to `columns(list, B)`

#### Scenario: The plain two-pane sidebar
- **WHEN** a single chat is docked next to the list and ctrl-u is pressed
- **THEN** the chat is home, the sidebar is still two panes, and its seat is a free placeholder again

### Requirement: The last seat is never closed
The seat that a chat leaves SHALL be closed behind it only when the window has another seat. The last seat of a sidebar SHALL stay, as a placeholder that says to pick an agent on the left, whatever happens.

#### Scenario: The last chat goes home
- **WHEN** the only docked chat is sent home
- **THEN** its placeholder stays as the free seat and the sidebar still has exactly one seat

### Requirement: Collapsing seats takes a lock, one seat at a time
Closing a freed seat (`tagents --collapse PANE`) SHALL happen under an exclusive lock directory `.collapse.lock` in the state directory, and SHALL decide whether another seat exists only after the lock is held. Only a free placeholder that sits in the sidebar window and is not parked for a chat is ever closed, and only when the window has more than one seat. A lock older than 60 seconds is taken over as stale. A collapse that cannot take the lock within its tries SHALL close nothing and exit 0.

#### Scenario: Several free seats collapsed at once
- **WHEN** four free seats exist and `--collapse` is run for each of them at the same time
- **THEN** exactly one seat is left, never none

#### Scenario: The lock is held
- **WHEN** `.collapse.lock` is held by another process and `--collapse` is run on a free seat
- **THEN** the seat is not closed
- **AND** once the lock is released a second `--collapse` closes it and leaves no lock behind

### Requirement: Undock-pane sends one chat home and tells a binding whether it did
`tagents --undock-pane PANE` SHALL send the chat docked in PANE home as ctrl-u does, close its seat behind it unless it is the last one, and exit 0. For any pane that is not a docked chat, such as the list, a placeholder or a terminal, it SHALL do nothing and exit 1. This is what a `kill-pane` binding asks first, so closing a pane in the sidebar never hangs up a session.

#### Scenario: A docked chat
- **WHEN** `tagents --undock-pane` is run on a docked chat
- **THEN** it exits 0 and the seat the chat left is closed
- **AND** the chat is back in its own window as the same pane with its process still running

#### Scenario: A chat with no placeholder to go home to
- **WHEN** the docked chat's placeholder is gone
- **THEN** the chat is broken out into a window of its own instead

#### Scenario: Anything else
- **WHEN** it is run on the list, on a placeholder or on a user terminal
- **THEN** it exits 1 and nothing moves

### Requirement: Undock-window empties a sidebar for a kill-window binding
`tagents --undock-window WINDOW` SHALL send home every chat docked in WINDOW, leave one seat behind, and exit 0 even when nothing was docked or no window was given.

#### Scenario: Two chats docked
- **WHEN** chats A and B are docked and `tagents --undock-window` is run for the sidebar window
- **THEN** it exits 0, A and B are in their own windows, and one free seat is left

### Requirement: The window title bar shows undock only while a chat is docked
While any pane of the sidebar window carries `@tagents_docked`, the sidebar window's `pane-border-status` option SHALL be `top`, and when the last chat leaves it SHALL be unset again. Other windows SHALL never be changed.

#### Scenario: Docking and undocking
- **WHEN** a chat is docked in the sidebar window
- **THEN** that window's `pane-border-status` is `top`
- **AND** after the last chat is sent home it is unset

### Requirement: Focusing a placeholder outside the sidebar brings its chat home
Focusing a placeholder that stands in for a docked chat, in the chat's home window, SHALL swap the chat back (`tagents --unpark PANE [WINDOW]`), clear both markers, select the chat, and close the seat the chat left unless it is the last one. A placeholder inside the sidebar window is only an empty seat and SHALL NOT trigger this. The claim SHALL be atomic, so racing unparks perform exactly one swap.

#### Scenario: Going to the placeholder
- **WHEN** the user focuses chat A's placeholder in A's home window
- **THEN** A is back in that window and its seat in the sidebar is closed
- **AND** the other docked chat is untouched

#### Scenario: Two placeholders unparked at once
- **WHEN** the placeholders of two docked chats are unparked at the same time
- **THEN** both chats come home and exactly one seat is left in the sidebar

#### Scenario: The parked chat is gone
- **WHEN** a placeholder is unparked and the chat it names does not exist
- **THEN** only its parked marker is cleared

### Requirement: A late focus trigger does not undo a fresh dock
When `--unpark` is given the window id the focus event happened in, it SHALL do nothing unless the placeholder is still in that window, checked again inside the atomic command, so a trigger scheduled while the placeholder was an empty seat cannot send a chat that was just docked straight back. Without a window argument it SHALL behave as an arrival at wherever the placeholder is.

#### Scenario: A stale trigger
- **WHEN** a chat has just been docked and `--unpark` for its placeholder is run with the sidebar window id
- **THEN** nothing moves and the placeholder keeps its parked marker

#### Scenario: A trigger from the placeholder's own window
- **WHEN** `--unpark` is run with the placeholder's own window id
- **THEN** the chat comes home

### Requirement: A placeholder tells where it stands and watches for its chat
A placeholder pane (the process `tagents --slot`) SHALL print a grey note: in the sidebar window, that the user should pick an agent on the left and press enter; elsewhere, that the pane's agent is being shown in the dashboard session and comes back as soon as the pane is focused. Every lap it SHALL also bring its chat home if it is the pane the user is looking at, as a fallback for the focus hooks.

#### Scenario: Active placeholder with a parked chat
- **WHEN** a placeholder with a parked chat is the active pane of the attached client and a lap runs
- **THEN** the chat is brought home

### Requirement: A placeholder waits for tmux to say something moved
Between laps a placeholder SHALL wait on the tmux channel `tagents-panes` and make its next lap only when it is rung. Every ring of the channel SHALL also add one to the global option `@tagents_gen`, which the lap reads in its one tmux question, and the wait SHALL happen only while the option still holds that number, so a ring during a lap, or two that cancel each other, is never slept through. A placeholder SHALL end when the wait fails because the tmux server is gone.

#### Scenario: A ring during a lap
- **WHEN** `@tagents_gen` has moved since the lap's question
- **THEN** the wait does not happen and the next lap follows at once

#### Scenario: The wait asks for the count
- **WHEN** a lap read the count 7
- **THEN** the wait on `tagents-panes` happens only while `@tagents_gen` still holds 7

### Requirement: A stranded placeholder looks again after one second
A placeholder that has found itself stranded SHALL make its next lap one second later, whether or not the channel is rung.

#### Scenario: A stranded lap
- **WHEN** a placeholder finds that its parked chat does not exist
- **THEN** it looks again after one second

### Requirement: What rings the placeholders
`tagents-panes` SHALL be rung, with the count first, by the hooks at index 42 of the events listed in the `refresher` capability, and by tagents in the same tmux call as the swap whenever it docks a chat, docks beside, sends a chat home or breaks one out, and by `tagents --unpark`, inside its one atomic command list. A placeholder SHALL put those hooks in when it starts, in case its server has none.

#### Scenario: A dock
- **WHEN** a chat is docked into a seat
- **THEN** the swap and the rings of `tagents-ev` and `tagents-panes` go to tmux in one call, and `@tagents_gen` has gone up by at least one

#### Scenario: A placeholder in a restored server
- **WHEN** a placeholder starts in a tmux server that has none of the hooks
- **THEN** it installs them before its first lap

### Requirement: A stranded placeholder closes itself
A placeholder outside the sidebar window whose parked chat does not exist, or which parks nobody, SHALL end its process, and so close its pane, after being in that state on two laps in a row, the second a second after the first and not on the next ring. The window then falls back to the layout it had before anything was docked.

#### Scenario: The docked chat exits
- **WHEN** a chat's Claude exits while it is docked and its placeholder is in another window
- **THEN** that placeholder pane closes itself within a few laps

### Requirement: The sidebar always has a seat
When a window with a list has no seat, seat repair (`tagents --ensure-seat [PANE]`, and the refresher on its slow pass) SHALL put one back. `--ensure-seat` SHALL print the current seat and a newline, or exit 1 when no seat could be made. A chat docked here with no placeholder left to go home to SHALL first be broken out into a window of its own.

#### Scenario: The seat dies
- **WHEN** the only seat of a sidebar that also holds a terminal is killed
- **THEN** within the refresher's next slow pass exactly one free seat is back

#### Scenario: A spare placeholder is moved in
- **WHEN** a free placeholder exists in a window that no live list is in, is not parked for a chat, and is not the only pane of its window
- **THEN** repair moves it into the sidebar instead of creating a pane

#### Scenario: A fresh placeholder
- **WHEN** no such spare exists
- **THEN** a new placeholder is split to the right of the list and takes `100 - TA_WIDTH` percent of the window, which is 55 percent by default

#### Scenario: Two sidebars
- **WHEN** a second list runs in another window with its own free seat, and the first sidebar loses its seat
- **THEN** `--ensure-seat` on the first list grows a seat of its own
- **AND** the second sidebar keeps its seat in its own window

### Requirement: A chat that exits while docked leaves the sidebar a seat
When the process in a docked chat's pane exits, the pane disappears from the sidebar, and the sidebar SHALL keep its other chats and at least one seat, with the dead chat's stranded placeholder cleaning itself up.

#### Scenario: One of two docked chats is killed
- **WHEN** chat B is killed while A and B are docked
- **THEN** A stays docked and remains the only seat, and the sidebar is still list, terminal and A

### Requirement: Which pane is the sidebar
The sidebar SHALL be the pane the list is running in. A list stamps its pane with `@tagents_list` set to its process id, which is a live claim only while that process exists. When a caller is itself a list, its own pane is the answer. Any other caller, such as a popup, a tmux hook or the status bar, SHALL use the pane marked `@tagents_dash` whose `@tagents_list` process is alive.

#### Scenario: A marker whose list is dead
- **WHEN** one pane carries `@tagents_dash` with a dead process id and another carries it with a live one
- **THEN** the sidebar is the live one and the dead pane's `@tagents_dash` is cleared

#### Scenario: A second list
- **WHEN** a second list starts in another window
- **THEN** each list's key presses dock into the seats of its own window
- **AND** the first list's `@tagents_list` claim is not taken away

### Requirement: A list claims the sidebar and gives it up on exit
A running list SHALL set `@tagents_dash` to `1` on its pane, taking it from any older list so that the newest list is the one non-list callers mean, and SHALL set `@tagents` to `1` on its window with `automatic-rename` off. On exit it SHALL remove its own `@tagents_list` and, if it still held the shared marker, `@tagents_dash`. A window outside the dedicated session SHALL stop being marked when its list leaves it.

#### Scenario: The list exits
- **WHEN** the list in a pane quits
- **THEN** the pane does not carry `@tagents_list` or the shared marker
- **AND** a Claude chat later started in that pane is never taken for the dashboard

### Requirement: The dedicated dashboard session
`tagents --ensure-dash` SHALL make sure a tmux session named `agents` (`TA_SESSION` overrides it) exists with a marked window running the list, repair that window's seats, and select the window. Apart from an idle restored `dash` window, a list SHALL NOT be started by taking over an existing pane. The command waits up to about two seconds for the list to claim the sidebar.

#### Scenario: No session yet
- **WHEN** `tagents --ensure-dash` runs and the `agents` session does not exist
- **THEN** the session is created, a list runs in it and claims the sidebar, and the window has a free seat

#### Scenario: A restored dash window
- **WHEN** the `agents` session has a window named `dash` whose panes are all idle unmarked shells
- **THEN** the list is started in its first pane and the other panes are closed

#### Scenario: The window exists without a list
- **WHEN** the marked window exists but no list pane runs in it
- **THEN** a new pane running the list is split off at the window's left with `TA_WIDTH` percent of the window, 45 by default
