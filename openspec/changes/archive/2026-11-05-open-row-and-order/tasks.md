## 1. The row on screen is marked

- [x] 1.1 Write failing checks: the mark on the row of the window on screen in the tree and in flat mode, on both chats of a window, on a dimmed window, never on a header or on a child, the same width and tally with and without it, bold after every reset, the same chat after a reorder, the snapshot of the refresher, and the list fzf holds in a cockpit. Proof: `tests/ui.sh`, `tests/refresh.sh`, `tests/cockpit.sh`.
- [x] 1.2 Add the shown flag to the `W` record of `collect`, print it as a sixteenth field of the chat and dimmed rows, and draw the mark and the bold row. Proof: `tests/ui.sh`.
- [x] 1.3 Add the window on screen to the refresher's snapshot and ring the event channel after `follow()` sets it. Proof: `tests/refresh.sh`, `tests/cockpit.sh`, `tests/forks.sh`.

## 2. Rows can keep their window's place

- [x] 2.1 Write failing checks: the order of three windows with prompts at opposite ages, a dimmed window between two chats, a chat that exits, closed rows, two chats of a window, a child, rows with no window, flat mode, the marker removed, `--toggle-order`, the `?` line and `keys.order` in the config and the schema. Proof: `tests/ui.sh`, `tests/config.sh`, `pnpm --filter @tagents/core test`.
- [x] 2.2 Add `toggle_order`, the sort keys of the window order, and the marker in the refresher's list of files. Proof: `tests/ui.sh`, `tests/refresh.sh`.
- [x] 2.3 Add the `order` verb and `ctrl-o` to the key tables, the bindings, `--toggle-order`, the schema, the example config, and the guide; `site/src/demos/data/keys.ts` is a recorded frame of the dashboard and stays as it was. Proof: `tests/ui.sh`, `tests/config.sh`, `pnpm --filter @tagents/core test`, `pnpm docs:build`.
- [x] 2.4 Add the `CHANGELOG.md` line. Proof: `pnpm spec:check`.
