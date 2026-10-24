## MODIFIED Requirements

### Requirement: The sidebar is filed by its window
When the sidebar is up the snapshot SHALL hold one `D` row of three columns: `D`, the session name and the window index of the window the sidebar is in, or, in the cockpit, of the window the viewport shows.

#### Scenario: Sidebar window
- **WHEN** the sidebar is in window 3 of session `work`
- **THEN** the snapshot has the row `D`, `work`, `3`

#### Scenario: The cockpit
- **WHEN** the cockpit is up and the viewport shows window 2 of session `work`
- **THEN** the snapshot has the row `D`, `work`, `2`, and no row names the session `tagents`

### Requirement: The sidebar comes back
When the snapshot holds a `D` row, the restore SHALL bring the sidebar back once the chats are placed and report `✓ dashboard`, in the recorded window if it exists after the restore, else in the first restored chat's window: the list is started as that window's leftmost full-height pane, or, in the cockpit, the dashboard is made if it is not up and its viewport shows that window. A window tmux-resurrect left from an older snapshot's dashboard SHALL be an ordinary window and keep what it runs.

#### Scenario: Dashboard row
- **WHEN** the snapshot holds a `D` row whose window is restored
- **THEN** the report says `✓ dashboard` and the list runs as the leftmost pane of that window and claims the sidebar

#### Scenario: The window is gone
- **WHEN** the `D` row names a window that does not exist after the restore
- **THEN** the sidebar is in the window of the first chat restored

#### Scenario: The cockpit
- **WHEN** the layout is `cockpit`, the snapshot's `D` row names `work:2`, which is restored, and a terminal is attached to the session `work`
- **THEN** the report says `✓ dashboard`, the session `tagents` exists with its viewport showing `work:2`, and that terminal still shows the session `work`

### Requirement: The restore closes the sidebar's leftover panes
After the chats and the sidebar are up, the restore SHALL close every idle shell titled `tagents-sidebar` that is not the live list and every idle shell titled `tagents-viewport` that is not the live viewport, as the `window-rows` capability says, and SHALL touch no other pane; a leftover dashboard is rebuilt or closed as the `cockpit` capability says. A dry run SHALL close nothing.

#### Scenario: Shells where the sidebar was
- **WHEN** the snapshot's windows were restored with an idle shell titled `tagents-sidebar` in each
- **THEN** after `tagents --resurrect` those shells are gone and the chats are untouched

#### Scenario: Dry run
- **WHEN** `tagents --resurrect --dry-run` runs
- **THEN** no pane is closed

#### Scenario: A leftover dashboard in the follow layout
- **WHEN** the layout is `follow` and tmux-resurrect restored a session `tagents` holding two idle shells titled `tagents-sidebar` and `tagents-viewport`
- **THEN** after `tagents --resurrect` no session `tagents` exists and the chats are untouched
