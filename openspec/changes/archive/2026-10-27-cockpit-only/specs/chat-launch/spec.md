## MODIFIED Requirements

### Requirement: A new agent is opened like any other
After its window is created the new agent SHALL be selected as `enter` on its row would do (the `window-rows` capability): the viewport shows its window and the cursor is on its row. With no dashboard up the client SHALL be taken to the new window. `tagents` SHALL show `tagents: new agent in <project> (<session>:<window>) as <profile>` (the last words only when a profile was used) and take a fresh snapshot for the `resurrect` capability.

#### Scenario: Cursor lands in the agent
- **WHEN** the user presses `ctrl-n` in the dashboard's list
- **THEN** the viewport shows the new agent's window with the agent's pane active
