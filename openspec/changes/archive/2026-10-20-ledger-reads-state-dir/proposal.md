## Why

The ticket-ledger hook read the agent-state directory from `TA_STATE`, while every other part of tagents reads `TA_STATE_DIR`. With only `TA_STATE_DIR` set, the hook read labels from and cached PRs in `~/.claude/agent-state`. Its test set the same wrong variable, so it could not catch this.

## What Changes

- The hook reads `$TA_STATE_DIR`, default `~/.claude/agent-state`. `TA_STATE` is no longer read.

## Impact

- Affected specs: `ticket-ledger`.
- Affected code: `hooks/ticket-ledger.sh`, `tests/ticket-ledger.sh`.
