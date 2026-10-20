## MODIFIED Requirements

### Requirement: Line format
Each line SHALL consist of thirteen tab-separated fields ended by a newline, appended in one write: 1 time (epoch seconds), 2 event name, 3 record key (a pane number without `%`, or `s-<session id>`), 4 session id, 5 `agent_id` (empty for the main agent), 6 pane (`%12`, empty for an `s-` key), 7 cwd, 8 transcript path, 9 `CLAUDE_CONFIG_DIR`, 10 tool name (`PreToolUse` and `PostToolUse` only), 11 sub-kind, 12 text, 13 the label.

#### Scenario: A Stop in a pane
- **WHEN** a `Stop` arrives for session `sid-1` in pane `%7` with `TA_LABEL=lbl` and `CLAUDE_CONFIG_DIR=/cfg`
- **THEN** the line has thirteen fields
- **AND** they are the time, `Stop`, `7`, `sid-1`, empty, `%7`, the cwd, the transcript, `/cfg`, empty, empty, empty and `lbl`

#### Scenario: A headless session
- **WHEN** an event arrives for a session with no pane
- **THEN** field 3 is `s-<session id>` and field 6 is empty

### Requirement: Children and background jobs in the stream
The line of a session keyed `s-<session id>` (a headless session, a background job or a child) SHALL carry that key in field 3 and an empty pane in field 6, even when the process inherited a pane through its environment, so that a reader acting on a pane never takes the line for the inherited pane's own. Field 13 of an `s-` line SHALL be the label the session's record keeps, which is blank when it is one inherited from an ancestor; a pane's line carries `TA_LABEL` of the hook's environment.

#### Scenario: A child inherits a pane
- **WHEN** a child sends `SessionStart` and `Stop` with its parent's pane in `TMUX_PANE`
- **THEN** both lines carry `s-<its session id>` in field 3 and nothing in field 6
- **AND** no line carries the parent's pane number as its key

#### Scenario: A child's inherited label is blank
- **WHEN** a child of a session labelled `lbl` sends `Stop` with `TA_LABEL=lbl` inherited
- **THEN** field 13 of its line is empty
- **AND WHEN** a child sends `Stop` with a label of its own, `TA_LABEL=own`, **THEN** field 13 is `own`

#### Scenario: A job re-keyed off its parent's pane
- **WHEN** a background job without `TMUX_PANE` runs below pane `%9` whose record belongs to another session
- **THEN** its line has key `s-<its session id>` and an empty pane
- **AND** the owner's lines still carry key `9` and pane `%9`
