# claude-statusline Specification

## Purpose
The Claude Code status line hook prints a one-line context gauge under the prompt and, as a side effect, records the model each session is set to and Claude Code's own running cost for it, which is the only channel through which tagents can learn either.

## Requirements

### Requirement: Registration and input
The hook SHALL be usable as Claude Code's `statusLine` command: it reads the status line JSON payload on standard input, prints one line on standard output, and exits 0 whatever happens.

#### Scenario: A payload is read from standard input
- **WHEN** Claude Code runs the hook with a status line payload on standard input
- **THEN** the hook prints exactly one line of text ending in a newline
- **AND** the hook exits 0

#### Scenario: The hook cannot work
- **WHEN** `jq` is not installed, or the payload is empty, or the payload cannot be parsed
- **THEN** the hook prints nothing, writes nothing and exits 0

### Requirement: The printed line shows context used and nothing else
The printed line SHALL be the percentage of the context window used, floored to a whole number and defaulting to 0 when the payload carries none, followed by the word `ctx`. The model and the session cost SHALL NOT be printed, because the dashboard and the tmux status bar already show both.

#### Scenario: Context used is printed
- **WHEN** the payload says 10 percent of the context window is used and fast mode is off
- **THEN** the line is `10%` followed by ` ctx`, with the percentage sign and the word in the dim colour and the line closed by a colour reset

#### Scenario: Fast mode is marked
- **WHEN** the payload says fast mode is on
- **THEN** the line ends with a space and the lightning-bolt mark ⚡ after `ctx`, before the colour reset

### Requirement: The percentage is coloured by how full the context is
The percentage SHALL be dim below 60, yellow from 60 up to 84, and bold red from 85. The thresholds are pinned by byte-exact output checks.

#### Scenario: Below 60 percent
- **WHEN** the context is 10 or 59 percent used
- **THEN** the percentage is printed in the dim grey colour

#### Scenario: From 60 percent
- **WHEN** the context is 60 or 84 percent used
- **THEN** the percentage is printed in yellow

#### Scenario: From 85 percent
- **WHEN** the context is 85 or 99 percent used
- **THEN** the percentage is printed in bold red

### Requirement: The model file
When the payload carries a session id and a model id, the hook SHALL record them in `<state dir>/model/<session id>.tsv`, where the state dir is `TA_STATE_DIR` and defaults to `~/.claude/agent-state`. The file SHALL hold one line of four tab-separated fields: the time in epoch seconds, the model id, the model's display name and Claude Code's running total cost for the session in dollars.

#### Scenario: A model file is written
- **WHEN** the payload names session `sid-1`, model id `claude-opus-5[1m]`, display name `Opus` and a total cost of 1.25
- **THEN** `<state dir>/model/sid-1.tsv` exists
- **AND** everything after its first field is `claude-opus-5`, `Opus` and `1.25`, separated by tabs

#### Scenario: No session or no model
- **WHEN** the payload has no session id, or no model id
- **THEN** no model file is written
- **AND** the line is still printed

### Requirement: Missing and awkward fields
A cost missing from the payload SHALL be recorded as 0, and tabs and newlines inside a field SHALL be replaced by spaces so the line keeps its four fields.

#### Scenario: No cost in the payload
- **WHEN** the payload carries a session id and a model id but no cost
- **THEN** the fourth field of the model file is `0`

### Requirement: The context-window suffix is dropped from the model id
A bracketed suffix in the model id, such as `[1m]`, names a context window and not a different model, so the hook SHALL remove it before recording the id.

#### Scenario: A one-million-token variant
- **WHEN** the payload's model id is `claude-opus-5[1m]`
- **THEN** the model file holds `claude-opus-5`

### Requirement: An unchanged record is not rewritten
Because every open session runs the hook about every 30 seconds and a change under `model/` makes the dashboard reload, the hook SHALL rewrite a model file only when the file is missing or when the model id, the display name or the cost differs from what the file holds. The time field is read by nothing and SHALL NOT count as a difference. A rewrite SHALL be atomic, so a reader never sees a half-written file.

#### Scenario: The same payload twice
- **WHEN** the hook runs twice with the same payload
- **THEN** the model file's inode and modification time are the same after the second run as after the first

#### Scenario: The cost changed
- **WHEN** the hook runs again with a different total cost
- **THEN** the model file is rewritten and holds the new cost

#### Scenario: The file was removed
- **WHEN** the model file has been deleted and the hook runs
- **THEN** the model file is created again

### Requirement: Old model files are swept
The hook SHALL delete model files not modified for more than 30 days. The sweep SHALL run only when the hook creates the file of a session it has not recorded before, not on every run.

#### Scenario: A new session is recorded
- **WHEN** the hook records a session whose model file does not exist yet
- **THEN** model files in the same directory last modified more than 30 days ago are deleted

### Requirement: What the dashboard takes from the model file
The dashboard SHALL read the second field of the model file as the model the session is set to now, and the fourth as the session's cost. A cost of 0 SHALL count as no cost recorded. Both are consumed as the `usage-accounting` capability describes.

#### Scenario: A session is switched to another model
- **WHEN** a session's model is changed with `/model` and Claude Code next renders its status line
- **THEN** the model file holds the new model id, with no new request having been sent
