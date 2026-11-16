## Why

The glyph of a row already says its state in colour, and the word beside it (`BLOCKED`, `IDLE`, `working`, `new`, `closed`) took seven columns that the name, the detail and the other columns could use. It was also the first column to be dropped on a narrow list, so a row looked different at different widths.

## What Changes

- A row of the list shows its state by the glyph and its colour alone, at every width.
- The width the word took goes to the name and the detail.
- The requirement that the state word yields to the name is removed.

## Impact

- Specs: `dashboard-list` gets MODIFIED requirements and one REMOVED.
- Code: `lib/tagents/list.sh`.
- Tests: `tests/ui.sh`, `tests/headless.sh`.
- Docs: `docs/guide/dashboard.md`, `docs/guide/states.md`, `docs/guide/cost.md`, `CHANGELOG.md`.
- Unchanged: field 3 of a list line stays the state word the pickers and tests read, and the preview, the timeline, the notifications and the status bar tally still name the state.
