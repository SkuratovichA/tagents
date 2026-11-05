## Context

A `compact_boundary` record of a transcript has the keys `type: "system"`, `subtype`, `uuid`, `sessionId`, `timestamp`, `isSidechain`, `parentUuid`, `logicalParentUuid` and `compactMetadata` with `trigger` (`manual` or `auto`), `preTokens`, `postTokens`, `cumulativeDroppedTokens` and `durationMs`. It has no `requestId`, `message` or `agentId`. Of 88 boundaries measured in real transcripts all had an integer `postTokens` and sat on the main chain. The request after a boundary was larger than its `postTokens` by 55591 to 123008 tokens, median 69639, because `postTokens` leaves out the system prompt and the tool schemas. The figure shown right after a compaction is therefore a lower bound until the next turn, and that is accepted.

## Decisions

- The extractor emits the boundary as a row of the same shape as a request, with a 13th column that holds `postTokens` (0 for a request) and the model `<synthetic>`. Every reader of the index already treats that zero-token placeholder as spending nothing, so no reader needs a new case beyond one: a report skips a row of no requests, so that its model lists stay as they were. A subagent has its own transcript and its compaction is not read, because only the main chain has a figure on the dashboard, and an agent's boundary would add an empty row to the reports by agent.
- `fold_rows` counts no request for such a row, does not let it set the session's model, does not raise the peak, and lets it be the newest size of its chat by timestamp, a later request replacing it.
- `sessions()` is unchanged: the later bucket wins, and inside one bucket the later row of the append-only file wins.
- A boundary is read only when `postTokens` is a number above zero and the record has a `uuid`; anything else is ignored, as it was.
- A boundary of a subagent transcript lands on that agent's chain, and the main chain's figure comes from agent `-` only.
- No schema bump. A compaction already passed by a stored offset is not read again; the session shows the right size at its next turn anyway, and `tusage --rebuild` reads the old ones for anyone who wants them.

## Rejected

- Reading `compactMetadata.preTokens` or estimating the system prompt to add to `postTokens`: it is a guess, and the column would claim a precision it has not got.
- Hiding the figure until the next turn: the person wants to see that the compaction worked.
- A separate file for compactions: a second index to keep in step, for one number.
