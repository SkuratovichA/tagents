## MODIFIED Requirements

### Requirement: The list cursor follows the window the viewport shows
When the viewport comes to show a window, by a selection or a switch made in the viewport, the list SHALL put its cursor on that window's row: the chat row when the window's first pane is a chat, the window row otherwise. It SHALL repaint from the rows the dashboard kept, with the mark and the cursor on that window's row, without waiting for a load; with no kept rows the cursor is placed from a list of its own. A start of the cockpit marks the row and leaves the cursor where the list began.

#### Scenario: Switching with tmux's own keys
- **WHEN** the user presses `prefix+n` in the viewport from the window of the chat "release notes" to the window of the chat "billing"
- **THEN** the viewport shows the "billing" window and the list's cursor is on the "billing" row

#### Scenario: A window outside the groups
- **WHEN** the user switches the viewport with `prefix s` to session `scratch`, whose only window `shell` runs no chat and which tagents never created
- **THEN** the viewport shows `shell` and the cursor is on the dimmed row `shell`, because every session is a group and no window is outside them

#### Scenario: A repaint before the next load
- **WHEN** the viewport changes window and the dashboard has kept rows
- **THEN** the mark and the cursor are on the new window's row before any load of the list has run
