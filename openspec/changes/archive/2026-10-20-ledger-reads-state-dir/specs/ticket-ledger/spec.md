## MODIFIED Requirements

### Requirement: The agent-state directory
The agent-state directory the hook reads `labels.tsv` from and keeps its PR cache in SHALL be `$TA_STATE_DIR`, default `~/.claude/agent-state`.

#### Scenario: Redirected state
- **WHEN** `TA_STATE_DIR` points at another directory and no other variable is set
- **THEN** labels and the PR cache are read from and written to that directory
- **AND** nothing is created under `~/.claude/agent-state`
