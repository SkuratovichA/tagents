## MODIFIED Requirements

### Requirement: The rename dialog starts from the current name
The rename dialog behind ctrl-r SHALL open with the line already holding the agent's current label, the session's and else the pane's as on the row, or, when it has none, the name the row shows, so a rename is an edit rather than a retyping. Esc SHALL leave the label as it was, and an empty line SHALL clear it. Without a terminal the dialog SHALL read one line from stdin, waiting at most 300 seconds. The key binding itself belongs to the `dashboard-keys` capability.

#### Scenario: Seeded with the label
- **WHEN** an agent has the label `current name` and the dialog opens
- **THEN** the input line starts as `current name`

#### Scenario: Seeded with the label of the pane
- **WHEN** the agent's label is stored under its pane and its session has none
- **THEN** the input line starts as that label, not as the pane title

#### Scenario: The session's label wins
- **WHEN** the agent has a label under its session and another under its pane
- **THEN** the input line starts as the session's label, the one on its row

#### Scenario: Seeded with the displayed name
- **WHEN** the agent has no label
- **THEN** the input line starts as the name on its row, not empty

#### Scenario: Esc
- **WHEN** the dialog is cancelled with Esc
- **THEN** the label is unchanged
