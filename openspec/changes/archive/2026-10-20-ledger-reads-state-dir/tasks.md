## 1. Implementation

- [x] 1.1 Read `TA_STATE_DIR` in `hooks/ticket-ledger.sh` and drop `TA_STATE`

## 2. Tests

- [x] 2.1 `tests/ticket-ledger.sh` exports `TA_STATE_DIR` and runs with a scratch `HOME`
- [x] 2.2 A check that with only `TA_STATE_DIR` set the PR cache lands under it and nothing appears under `$HOME/.claude/agent-state`
