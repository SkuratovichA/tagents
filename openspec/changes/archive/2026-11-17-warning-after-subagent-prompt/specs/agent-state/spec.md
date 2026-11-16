## MODIFIED Requirements

### Requirement: Subagent files
Events that carry an `agent_id` belong to a subagent. For each the hook SHALL write `<state dir>/sub/<key>.<agent id>` holding the time and the detail, tab-separated, and leave the session's record, pane option, prompt-time file and history untouched, bar a warning's restore. A `SubagentStop` with an `agent_id` SHALL delete that file; without one it changes nothing. A turn that ends (`Stop`, or an idle `Notification`) SHALL delete every subagent file of the session's key.

#### Scenario: A subagent works
- **WHEN** a `PreToolUse` with `agent_id` `a1` arrives for the session in pane `%7`
- **THEN** `sub/7.a1` exists
- **AND** `7.tsv` is not rewritten

#### Scenario: A subagent of a headless session
- **WHEN** the same event arrives for a session keyed `s-sid-h1`
- **THEN** `sub/s-sid-h1.a1` exists
- **AND** the subagent's `SubagentStop` removes it and adds no history line

#### Scenario: The turn ends
- **WHEN** a `Stop` arrives while `sub/7.a1` and `sub/7.a2` exist
- **THEN** both files are deleted

### Requirement: A subagent file that appears or goes rings the dashboard
When the hook creates or removes a subagent file, it SHALL ring `tagents-ev` in a tmux call of its own (the count first, then the signal), because the list draws how many subagents a session has. A rewrite of a file that already exists SHALL ring nothing, and removing a file that was not there SHALL ring nothing. An event that restores a warned row rings once, in the restore's call.

#### Scenario: A subagent starts
- **WHEN** the first event with `agent_id` `a1` arrives for the session in pane `%7`
- **THEN** `sub/7.a1` exists and the channel was rung once

#### Scenario: A busy subagent
- **WHEN** a second event with the same `agent_id` arrives
- **THEN** the file is rewritten and nothing is rung

#### Scenario: A subagent stops
- **WHEN** `SubagentStop` arrives with `agent_id` `a1` while `sub/7.a1` exists
- **THEN** the file is removed and the channel is rung

#### Scenario: A subagent's event restores a warned row
- **WHEN** the last subagent a warning was waiting for sends `PostToolUse`, or `SubagentStop` while `sub/7.a1` exists
- **THEN** the channel is rung once, in the call that sets `@agent` to the restored state
- **AND** a stopped subagent's file is already gone when it rings

### Requirement: SessionEnd of a session
On `SessionEnd` of the main agent the hook SHALL delete the session's record, its subagent files (`sub/<key>.*`), its prompt-time file and what it remembered of a subagent's warning (`perm/<key>`), and unset `@agent` on its pane when it has one, but only when field 3 of the record in its key is empty or the session id; a record naming another conversation is left alone with its subagent files and pane option. A `SessionEnd` carrying an `agent_id` removes only that subagent's file.

#### Scenario: A normal end
- **WHEN** `SessionEnd` arrives for the session in pane `%7`
- **THEN** `7.tsv`, `sub/7.*`, `prompt/7` and `perm/7` are gone
- **AND** `@agent` is unset on `%7`

#### Scenario: Someone else's record
- **WHEN** the record in the hook's key names a different session
- **THEN** it and its subagent files are kept
- **AND** `@agent` is not unset

### Requirement: A parent takes its finished children with it
On `SessionEnd` the hook SHALL scan the pane-less records for children whose field 12 equals the ending session's id. A child whose pid in field 8 is not a running process (empty, zero, non-numeric, or no longer alive) SHALL have its record, subagent files, prompt-time file and remembered warning deleted. A child that is still running SHALL be kept; it is then shown at the top level.

#### Scenario: A dead and a live child
- **WHEN** a parent with session id `sid-par` ends while one child's recorded pid is dead and another's is alive
- **THEN** the dead child's record and its subagent files are removed
- **AND** the live child's record is kept
- **AND** the parent's own record is gone

## ADDED Requirements

### Requirement: A row stops warning once the subagent that asked goes on
A permission prompt does not say who asked. When it blocks a row while no call of the main conversation is waiting and a subagent has one in flight, the row SHALL go back to the state and detail it had as soon as the last such subagent sends an event, if it is still blocked under the same session id. A second prompt adds its subagents. An event of the main conversation that rewrites the row, and SessionEnd, end the wait.

#### Scenario: A background subagent asks and the owner answers
- **WHEN** the row is `done`, subagent `a1` has a call in flight, a permission prompt arrives, and then `a1` sends `PostToolUse`
- **THEN** the row is `done` again with its old detail

#### Scenario: Two subagents in flight
- **WHEN** `a1` and `a2` both had a call in flight at the prompt and `a1` sends an event
- **THEN** the row stays `blocked` until `a2` sends one

#### Scenario: Two subagents ask
- **WHEN** `a1` asks, then `a2` asks, and each goes on in turn
- **THEN** the row stays `blocked` after the first and goes back after the second

#### Scenario: A subagent that was not in flight
- **WHEN** a subagent whose call had finished before the prompt, or whose file is older than the subagent time-to-live, sends an event
- **THEN** nothing changes

#### Scenario: The main conversation goes on or the session ends
- **WHEN** an event of the main conversation rewrites the row, or `SessionEnd` arrives
- **THEN** what the hook remembered (`perm/<key>`) is removed

#### Scenario: The row is not the one that asked
- **WHEN** the last listed subagent sends an event and the row is no longer `blocked`, or names another session
- **THEN** the row is left as it is

#### Scenario: Nothing is remembered
- **WHEN** a subagent event arrives and no warning is waiting
- **THEN** the hook starts no program it would not have started without this requirement

### Requirement: A call waiting in the main conversation keeps the warning
A row that was `done`, or `working` on a finished call, on an `Agent` or `Task` call (with or without an argument), or on the user's prompt with no call recorded for the turn, has no call of the main conversation waiting; any other `working` row has one, and a subagent's event leaves it `blocked`. The restore SHALL set `@agent` and ring the dashboard in one tmux call. A memory that is unreadable or cut short SHALL be dropped and the row left as it is.

#### Scenario: A call of the main conversation is waiting
- **WHEN** the row was `working` on a `Bash` or `AskUserQuestion` call that is not finished and the prompt arrives
- **THEN** nothing is remembered and a subagent's event leaves the row `blocked`

#### Scenario: An Agent call with no argument
- **WHEN** the row was `working` on an `Agent` call whose detail is just `Agent`
- **THEN** the warning goes back to `working` with that detail when the subagent goes on

#### Scenario: The prompt is the detail
- **WHEN** the row was `working` with the user's prompt as detail and the turn has recorded no call
- **THEN** the prompt comes back as the detail

#### Scenario: A memory cut short
- **WHEN** the remembered state is empty and a subagent sends an event
- **THEN** the memory is dropped and the row stays `blocked`
