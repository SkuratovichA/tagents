## MODIFIED Requirements

### Requirement: Subagent files
Events that carry an `agent_id` belong to a subagent. For each the hook SHALL write `<state dir>/sub/<key>.<agent id>` holding the time and the detail, tab-separated, and leave the session's record, pane option, prompt-time file and history untouched, except that the event of the last subagent a warning was waiting for puts the row back (see "A row stops warning once the subagent that asked goes on"). A `SubagentStop` with an `agent_id` SHALL delete that file; without one it changes nothing. A turn that ends (`Stop`, or an idle `Notification`) SHALL delete every subagent file of the session's key.

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

### Requirement: SessionEnd of a session
On `SessionEnd` of the main agent the hook SHALL delete the session's record, its subagent files (`sub/<key>.*`), its prompt-time file and anything remembered for a subagent's warning (`perm/<key>`), and unset `@agent` on its pane when it has one, but only when field 3 of the record in its key is empty or the session id; a record naming another conversation is left alone with its subagent files and pane option. A `SessionEnd` carrying an `agent_id` removes only that subagent's file.

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
A permission prompt does not say who asked. When it blocks a row while the main conversation has no call waiting and a subagent has one in flight, the hook SHALL remember the state, detail and those subagents in `perm/<key>`; a second prompt adds its subagents. When the last of them sends an event and the row is still blocked under the same session id, the row SHALL go back. Any rewrite by the main conversation, and SessionEnd, SHALL forget it.

#### Scenario: A background subagent asks and the owner answers
- **WHEN** the row is `done`, subagent `a1` has a `PreToolUse` in flight, a permission notification arrives, and then `a1` sends a `PostToolUse`
- **THEN** the row is `done` again with its old detail and `perm/7` is gone

#### Scenario: Two subagents in flight
- **WHEN** `a1` and `a2` were both in flight at the notification and `a1` sends an event
- **THEN** the row stays `blocked` until `a2` sends one

#### Scenario: Two subagents ask
- **WHEN** `a1` asks, then `a2` asks, and each goes on in turn
- **THEN** the row stays `blocked` after the first and goes back after the second

#### Scenario: A subagent that was not in flight
- **WHEN** an event arrives from a subagent whose call had finished before the notification, or whose file is older than the subagent time-to-live
- **THEN** nothing changes

#### Scenario: A call of the main conversation is waiting
- **WHEN** the row was `working` on a `Bash` or `AskUserQuestion` call that is not finished and the notification arrives
- **THEN** nothing is remembered and a subagent's event leaves the row `blocked`

#### Scenario: The main conversation goes on or the session ends
- **WHEN** an event of the main conversation rewrites the row, or `SessionEnd` arrives
- **THEN** `perm/<key>` is removed

#### Scenario: The row is not the one that asked
- **WHEN** the last listed subagent sends an event and the row is no longer `blocked`, or names another session
- **THEN** the file is removed and the row is left as it is

#### Scenario: Nothing is remembered
- **WHEN** a subagent event arrives and `perm/<key>` does not exist
- **THEN** the hook starts no program it would not have started without this requirement
