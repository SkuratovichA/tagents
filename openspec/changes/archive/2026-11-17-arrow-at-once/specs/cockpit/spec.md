## MODIFIED Requirements

### Requirement: Changes inside the viewport move only the cursor
A window or session change of the viewport's client SHALL move the list's cursor to the window the viewport then shows and SHALL move no pane. A change of any other client SHALL move no pane while the cockpit is up, and SHALL move the cursor only when it changes the window the viewport shows. The `tagents --follow` hooks of the `window-rows` capability SHALL do this move and redraw the mark from the rows the dashboard kept, and nothing else.

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
