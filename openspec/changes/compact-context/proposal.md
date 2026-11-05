## Why

After `/compact` the context column kept the size from before the compaction until the model answered again, so a session that had just been compacted looked as if the compaction had done nothing. The column is how a session is judged to need compacting. The index reads only `assistant` records, and a compaction writes a `system` record named `compact_boundary` and no `assistant` record until the next turn.

## What Changes

- `tusage` reads a `compact_boundary` record that carries a numeric `postTokens` above zero as the newest size of its chat. It is no request, no peak and no change of the session's model, and it costs nothing.
- The context figure right after a compaction is what the compacted messages take. The next request replaces it.

## Impact

- Specs: `usage-accounting` and `dashboard-list` each get one MODIFIED requirement with new scenarios.
- Code: `tusage` (`EXTRACT` and `fold_rows`).
- Tests: `tests/tusage.sh`.
- Docs: `docs/guide/dashboard.md`.
