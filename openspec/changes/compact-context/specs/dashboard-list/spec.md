## MODIFIED Requirements

### Requirement: The context column warns about long contexts
The context column SHALL show the session's live context size as a token count (`150k`, `1.2M`), blank when unknown, in grey, in yellow from 200000 tokens and in bold red from 600000. The figure is supplied by the `usage-accounting` capability.

#### Scenario: Colours
- **WHEN** a session's context is 150000, 250000 and 700000 tokens
- **THEN** the figures are grey, yellow and bold red respectively

#### Scenario: Right after a compaction
- **WHEN** a session of 209k is compacted and no request has been answered since
- **THEN** the column shows what the compaction left, which is a lower bound because it leaves out the system prompt and the tool schemas, and the next answer replaces it with the size of its own request
