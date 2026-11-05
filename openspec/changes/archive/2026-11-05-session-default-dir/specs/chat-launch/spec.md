## ADDED Requirements

### Requirement: A session can have a default directory
`ctrl-d` SHALL ask for a directory and save it under the name of the tmux session of the row under the cursor; `.` takes the directory of the row, `-` forgets it, and an empty line cancels. A name that is no directory SHALL be refused and change nothing. A row whose pane is gone, and a headless row, belong to no tmux session and SHALL only say so. Only `ctrl-n` and `ctrl-p` read it.

#### Scenario: Saved and used
- **WHEN** `~/app/packages/client` is saved for session `work` and the user presses `ctrl-n` on a row of `work` whose directory is elsewhere
- **THEN** the new agent starts in `~/app/packages/client`, not in the repository root of `~/app`

#### Scenario: The account dialog gets it too
- **WHEN** a directory is saved for session `work` and the user presses `ctrl-p` on a row of `work`
- **THEN** the account dialog starts the agent in that directory exactly

#### Scenario: Nothing saved
- **WHEN** no directory is saved for the session of the row, or the saved one is gone from disk
- **THEN** `ctrl-n` and `ctrl-p` start the agent as they do without this requirement, in the repository root of the row's directory

#### Scenario: A group header
- **WHEN** the cursor is on the header of session `work`, which has a saved directory, and the user presses `ctrl-n`
- **THEN** the new agent starts in the saved directory

#### Scenario: Names are exact
- **WHEN** a directory is saved for session `work` and the user presses `ctrl-n` on a row of session `work2`
- **THEN** the saved directory is not used

#### Scenario: Not read elsewhere
- **WHEN** a directory is saved for session `work` and the user runs `tagents --new`, `tagents --window`, presses `ctrl-a`, resumes a closed row or starts an agent through an MCP tool
- **THEN** none of them starts in the saved directory

#### Scenario: A row without a session
- **WHEN** the user presses `ctrl-d` on a headless row or on a row whose pane is gone
- **THEN** `tagents: this row belongs to no tmux session` is shown and nothing is saved

## MODIFIED Requirements

### Requirement: ctrl-n starts a new agent for the project under the cursor
`ctrl-n` SHALL start a fresh Claude for the project of the row under the cursor, a group header and an agent row alike, on the account the rules of the configuration pick for that project and tmux session. The directory SHALL be normalised to its repository root, unless a default directory is saved for the session of the row, which is used as it is. A row with no known directory means the current working directory.

#### Scenario: Subdirectory
- **WHEN** the cursor is on a row whose directory is `~/projects/app/packages/client` inside the repository `~/projects/app`
- **THEN** the new agent starts in `~/projects/app`

#### Scenario: Account from the rules
- **WHEN** a rule maps the directory to the profile `personal`
- **THEN** the agent starts on that profile's config directory with the configured arguments
