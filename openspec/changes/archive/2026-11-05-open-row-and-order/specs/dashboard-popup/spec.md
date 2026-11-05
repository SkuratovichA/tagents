## MODIFIED Requirements

### Requirement: A completed action closes the popup
In popup mode these keys SHALL close the list once their action has been issued: `enter`, double-click, `ctrl-s`, `ctrl-g`, `ctrl-e`, `ctrl-n`, `ctrl-p`, `ctrl-a`, `ctrl-y` and `?`. The keys that change the list or a record instead — `ctrl-r`, `F2`, `ctrl-u`, `ctrl-x`, `ctrl-t`, `ctrl-o`, `ctrl-l`, `ctrl-w`, `$`, `ctrl-v` — SHALL leave the popup open.

#### Scenario: Go to an agent
- **WHEN** the user presses `ctrl-g` in a popup list
- **THEN** the terminal is taken to the agent's own session, window and pane and the popup closes

#### Scenario: Toggle columns
- **WHEN** the user presses `ctrl-w` and hides a column
- **THEN** the popup list is still open, redrawn without that column

#### Scenario: A shell from the popup
- **WHEN** the user presses `ctrl-a` in a popup list
- **THEN** the client is shown the new shell window and the popup closes

#### Scenario: Window order from the popup
- **WHEN** the user presses `ctrl-o` in a popup list
- **THEN** the popup list is still open, redrawn in the other order
