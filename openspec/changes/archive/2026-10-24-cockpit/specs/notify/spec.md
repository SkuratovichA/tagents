## MODIFIED Requirements

### Requirement: Notices for a chat that is on screen
When `skip_visible` is on for a kind and the agent's tmux pane is in some client's current window, the notice SHALL be handed to the backend marked to be dropped if that client's terminal is the frontmost application; for the cockpit's viewport that is the terminal of a client on the dashboard. With `skip_visible` off, or when tmux cannot say which client shows the pane, or the terminal is not found, the notice is posted unmarked.

#### Scenario: the pane is in front
- **WHEN** a Stop arrives, `events.turn_done.skip_visible` is on, the pane is in a client's window and that terminal is frontmost
- **THEN** the notice is marked to skip if frontmost, and the backend does not show it

#### Scenario: skip_visible off
- **WHEN** `events.turn_done.skip_visible` is `false` and the pane is visible
- **THEN** the notice carries no skip mark, and still names the visible client's terminal for the click

#### Scenario: tmux does not answer
- **WHEN** the screen probe fails or finds nothing
- **THEN** the notice is posted without a terminal and without a skip mark

#### Scenario: Seen through the viewport
- **WHEN** a Stop arrives, `events.turn_done.skip_visible` is on, the pane is in the window the viewport shows and a terminal attached to the session `tagents` is frontmost
- **THEN** the notice is marked to skip if that terminal is frontmost, and names that terminal for the click

#### Scenario: The dashboard is not on screen
- **WHEN** `events.turn_done.skip_visible` is on, the pane is in the window the viewport shows, no other client shows it and no terminal is attached to the session `tagents`
- **THEN** the notice is posted without a skip mark
