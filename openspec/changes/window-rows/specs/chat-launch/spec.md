## RENAMED Requirements
- FROM: `### Requirement: A new agent lives with its project`
- TO: `### Requirement: A new agent opens in the group the cursor is in`

## MODIFIED Requirements

### Requirement: A new agent opens in the group the cursor is in
The new agent's window SHALL be created, detached, in the tmux session of the group the dashboard cursor is in. When the cursor is on the group `no window`, or the agent is started without a dashboard (`tagents --new` from a shell), it SHALL be created in the session that owns the project: the session where most of the live panes sitting in that directory are, else the session of the client, else the session tmux treats as current.

#### Scenario: Owning session
- **WHEN** the cursor is on a row of the tmux session `proj`
- **THEN** the new agent's window is in `proj`

#### Scenario: No windows
- **WHEN** the cursor is on the group `no window` and every agent of the project is closed
- **THEN** the window is created in the session of the client

### Requirement: A new agent is opened like any other
After its window is created the new agent SHALL be selected exactly as `enter` on its row would do (the `window-rows` capability): the sidebar is moved into its window, the cursor is in the agent, and the client ends up looking at the agent just asked for. With no sidebar the client SHALL be taken to the new window. `tagents` SHALL show `tagents: new agent in <project> (<session>:<window>) as <profile>` (the last words only when a profile was used) and take a fresh snapshot for the `resurrect` capability.

#### Scenario: Cursor lands in the agent
- **WHEN** the user presses `ctrl-n` in the sidebar
- **THEN** the client's current pane is the new agent and the sidebar is in its window

### Requirement: Enter on a closed row resumes it
`enter` on a closed row SHALL restart the session with `claude --resume <id>` on the account it ran on and select it as `enter` on a live agent would. When the row's old pane still exists and sits at an idle shell the command SHALL be typed into it after a `cd` to the session's directory; otherwise it SHALL be started in a new window of the session of the row's group, or of the client's session for a row in the group `no window`.

#### Scenario: Idle shell
- **WHEN** the dead row's pane is at a shell prompt
- **THEN** the resume command is typed into that same pane

#### Scenario: Pane busy or gone
- **WHEN** the pane is gone or running something else
- **THEN** a new window is opened and nothing is typed into the old pane

#### Scenario: Directory gone
- **WHEN** the session's directory no longer exists
- **THEN** the home directory is used instead

#### Scenario: No session id
- **WHEN** the row's record has no session id
- **THEN** `tagents: no session id recorded — cannot resume` is shown and nothing is started
