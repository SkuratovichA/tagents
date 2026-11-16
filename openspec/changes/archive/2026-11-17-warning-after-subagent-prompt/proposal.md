## Why

A background subagent that asks for a permission raises a notification with no agent id, so the session's record goes to `blocked`. Every later event of that subagent carries its `agent_id` and is kept off the session's record, so nothing put the record back after the owner answered: the row kept its warning sign until the main conversation produced its next event, which could be minutes later.

## What Changes

- When a notification that is not the idle ping blocks the record and the main conversation has no call of its own waiting, the hook writes `perm/<key>`: the state and detail to go back to, and the subagents with a call in flight.
- An event of a listed subagent takes it off the list. When the list is empty and the record is still the blocked one of the same session, the remembered state and detail are written back, `@agent` is set and the dashboard is rung in one tmux call.
- Any event of the main conversation that rewrites the record, and the end of the session, remove the file. An event of a subagent that is not on the list changes nothing.
- A second prompt while one is remembered keeps the state and detail and adds its subagents, so two subagents that both ask clear the row only when both have gone on.
- A subagent event with no `perm/<key>` starts no program it did not start before.

## Impact

- Specs: `agent-state` gets two ADDED requirements (the row stops warning, a waiting call of the main conversation keeps it) and four MODIFIED ones (subagent files, the ring of a subagent file, SessionEnd, a parent taking its children).
- Code: `hooks/tmux-agent-state.sh` (`perm_remember`, `perm_agent_went`, the shared ring helpers, the session end), `lib/tagents/actions.sh` (`forget_agent`, `end_agent`).
- Tests: `tests/events.sh`, sections s to s16, and `tests/window-rows.sh`, R23 and R26.
- Docs: `CHANGELOG.md`, `docs/guide/states.md`, `lib/tagents/README.md`, the header of the hook, the comment of `packages/core/src/agent-state.ts`.
