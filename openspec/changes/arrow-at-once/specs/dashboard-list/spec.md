## ADDED Requirements

### Requirement: The dashboard keeps the rows of its last load
Every list the dashboard loads itself (its first load, the refresher's reload and the reload a key posts) SHALL leave `.rows.kept` in the state directory, replaced atomically: one line per drawn row, holding the row's window id (empty when it has none), whether the row can carry the mark, the row drawn without the mark and the row drawn with it. A `--list` run by a person, a test or the popup SHALL NOT write it.

#### Scenario: A load of the dashboard
- **WHEN** the dashboard's list loads
- **THEN** `.rows.kept` has one line for each line the list drew, and the two copies of a row differ only in the mark

#### Scenario: A list run by hand
- **WHEN** a person runs `tagents --list`
- **THEN** `.rows.kept` is not written or changed

## MODIFIED Requirements

### Requirement: The row on screen is marked
The row of the window the viewport shows SHALL carry a `▸` in the place of the tree's dash and be drawn bold, in the tree and in a flat list, on a chat row and a dimmed window row alike. A header and a child without a pane in that window SHALL NOT be marked. The mark SHALL not change the width of any row or the tally. It SHALL be taken from the window the viewport's client shows when the list is built (from `@tagents_viewport_window` when there is none).

#### Scenario: The window on screen
- **WHEN** the viewport shows a window that holds a chat
- **THEN** that chat's row starts with `▸` and is bold, and no other row is marked

#### Scenario: A window with two chats
- **WHEN** the viewport shows a window that holds two chats
- **THEN** both rows are marked

#### Scenario: The viewport moves
- **WHEN** the viewport changes to another window and a full `--list` starts before `--follow` has run
- **THEN** the mark is on the new window's row
