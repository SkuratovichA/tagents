## MODIFIED Requirements

### Requirement: The list cursor follows the window the viewport shows
When the viewport comes to show a window, by a selection or a switch made in it, the list SHALL put its cursor on that window's row: the chat row when the window's first pane is a chat, the window row otherwise. It SHALL repaint from the rows the dashboard kept, with the mark and the cursor on that row, without waiting for a load; with no kept row for it the cursor is placed from a list of its own once the option is written. A start of the cockpit marks the row and leaves the cursor.

#### Scenario: Switching with tmux's own keys
- **WHEN** the user presses `prefix+n` in the viewport from the window of the chat "release notes" to the window of the chat "billing"
- **THEN** the viewport shows the "billing" window and the list's cursor is on the "billing" row

#### Scenario: A window outside the groups
- **WHEN** the user switches the viewport with `prefix s` to session `scratch`, whose only window `shell` runs no chat and which tagents never created
- **THEN** the viewport shows `shell` and the cursor is on the dimmed row `shell`, because every session is a group and no window is outside them

#### Scenario: A repaint before the next load
- **WHEN** the viewport changes window and the dashboard has kept rows
- **THEN** the mark and the cursor are on the new window's row before any load of the list has run

## ADDED Requirements

### Requirement: The cursor is put right after the load that follows a repaint
After a repaint from kept rows, `--follow` SHALL wait up to five seconds for the dashboard to keep a new set of rows, then put the cursor on the window's row in that set when it is another line, unless the option `@tagents_viewport_window` holds another window by then. It SHALL start no list for it and, with no new set, post nothing.

#### Scenario: A row above the window went away with the switch
- **WHEN** the viewport shows window B of the rows A, B, C, D and B is closed, so that it moves to C before the next load has drawn A, C, D
- **THEN** once that load has drawn, the cursor is on C and not on D

#### Scenario: Another switch came first
- **WHEN** the viewport shows a third window when the next set of rows arrives
- **THEN** the first follow moves the cursor no more
