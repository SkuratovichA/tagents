## Why

A headless session started from a labelled session inherits `TA_LABEL`. The hook blanks an inherited label in the child's record, but the events stream still wrote the raw environment value in field 13, so notify named the child's notices after its parent.

## What Changes

- Field 13 of an `s-` line is the label the session's record keeps, blank when inherited. A pane's line still carries `TA_LABEL` of the hook's environment.
- The notify title falls back to the label its events carry.

## Impact

- Affected specs: `event-stream`, `notify`.
- Affected code: `hooks/tmux-agent-state.sh`, `tests/events.sh`, comments in `packages/core/src/agent-state.ts` and `packages/core/src/agent-events.ts`.
