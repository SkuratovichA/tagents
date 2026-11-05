## MODIFIED Requirements

### Requirement: Machine-readable sessions
`tusage --sessions` SHALL print one tab-separated row per session in the window with 14 fields: session id, cost units, requests, context size, last-request time, project slug, subagent cost units, live subagents, cost units in the last five hours, current model, dollars, dollars in the last five hours, subagent dollars and unpriced-request count. Dollars SHALL be at list price, not scaled by any calibration. The model SHALL be the one that served the newest request that spent anything.

#### Scenario: A session row
- **WHEN** a session holds a $5.00 and a $25.00 request on opus-5, and a calibration factor is stored for its account
- **THEN** its row has 14 fields and its dollars field is `30.000000`

#### Scenario: A compaction sets the context at once
- **WHEN** a session's newest request had a context of 200000 tokens and a `compact_boundary` record with `postTokens` 20000 follows it on the main chain
- **THEN** the context size field is `20000`, the request count, the model, the cost units and the dollars are those of the session without the record, and the next request replaces the figure with its own context

#### Scenario: A record that is no compaction of the chat
- **WHEN** a `compact_boundary` record has no `compactMetadata`, a `postTokens` of 0 or not a number, or belongs to a subagent
- **THEN** the main chain's context size is the one of its newest request
