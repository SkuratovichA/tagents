## MODIFIED Requirements

### Requirement: ctrl-r names an agent
`ctrl-r` and `F2` SHALL open a one-line dialog seeded with the agent's current name. The answer is stored as the label of the session id, or of the pane when it has none, in `labels.tsv` in the state directory (one `key<TAB>name` line per label), and the agent's tmux window is renamed with it. An answer replaces the label of both keys. An empty answer removes the label; `esc` leaves it as it was.

#### Scenario: Name stored
- **WHEN** the user answers `newname` to the dialog of session `sid-rename`
- **THEN** `labels.tsv` holds `sid-rename<TAB>newname`

#### Scenario: Empty clears
- **WHEN** the user answers with an empty line
- **THEN** the label is removed and the row shows the pane title again

#### Scenario: Empty clears a label left under the pane
- **WHEN** an agent has a label under its session and another under its pane, and an empty name is given
- **THEN** both lines are gone from `labels.tsv` and the row shows the pane title

#### Scenario: From outside
- **WHEN** `tagents --label <session id> NAME` is run
- **THEN** the same label is stored, and with an empty id the command prints a message and exits 2

## ADDED Requirements

### Requirement: tagents --label names an agent from outside
`tagents --label` SHALL take a session id or a pane id and name the agent as `ctrl-r` does. A name given for a pane whose record names a session SHALL be stored under that session.

#### Scenario: By a pane with a session
- **WHEN** `tagents --label %12 NAME` is run, the record of `%12` names session `sid-a`, and `sid-a` already has a label
- **THEN** `labels.tsv` holds `sid-a<TAB>NAME` and no line for `%12`, and the row and the window show `NAME`

#### Scenario: By a pane with no session
- **WHEN** `tagents --label %12 NAME` is run and `%12` has no record naming a session
- **THEN** `labels.tsv` holds `%12<TAB>NAME`
