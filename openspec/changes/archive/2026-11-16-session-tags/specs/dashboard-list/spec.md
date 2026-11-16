## MODIFIED Requirements

### Requirement: The list is produced by `tagents --list`
`tagents --list` SHALL print one line per row of the list for fzf to read, each line made of five TAB-separated fields: the row key (the pane id of a chat, the window id of a dimmed window row), the text of the row with its colours, the row's state, the session id and the directory. The second field of a tagged session ends with its tags, hidden past the edge (see `session-tags`). `tagents --flat` SHALL print the same list ungrouped whatever mode is saved.

#### Scenario: Row fields
- **WHEN** a session in `~/projects/app` is running in pane `%12` with session id `a1b2c3d4-…`
- **THEN** its line starts with `%12`, the fourth and fifth fields are its session id and its absolute directory, and the third field is its state word (`working`, `done`, `blocked`, `new`, `?` or `dead`)

#### Scenario: Nothing is running
- **WHEN** the dashboard has no row to show
- **THEN** the list it hands to fzf is one dim line reading `no claude sessions running` with the key `-` and the state `none`

#### Scenario: A dimmed window row
- **WHEN** a window of a group runs no chat
- **THEN** its line starts with the window id, for example `@7`, and its third and fourth fields are `none` and empty

#### Scenario: A tagged session
- **WHEN** a session has tags
- **THEN** its line still has five fields and its second field ends with the tags after as many spaces as the list is wide, at least 300

### Requirement: The preview shows a row up close
`tagents --preview PANE [STATE]` SHALL print, for a pane with a record: the directory the session started in in bold, `cwd now:` when known, `<state> · <detail>`, `session <id>`, `tags:` when the session has some, `parent: <name>` for a child, `account: <profile> (<config dir>)` when the record names one, the cost table per subagent and model from `tusage` when usage tracking is on, and a separator line. For the pane key `-` it SHALL print nothing.

#### Scenario: Header block
- **WHEN** the preview is asked for a session with an account recorded
- **THEN** it shows the session id and `account: personal (<its config dir>)`

#### Scenario: Child session
- **WHEN** the preview is asked for a child session
- **THEN** it names the parent by name and pane key

#### Scenario: Tags
- **WHEN** the preview is asked for a session with tags
- **THEN** it shows `tags:` and the tags after the session id
