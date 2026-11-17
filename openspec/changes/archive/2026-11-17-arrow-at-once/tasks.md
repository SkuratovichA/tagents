## 1. The mark and the cursor follow a window switch at once

- [x] 1.1 Write failing checks first: a full `--list` that starts before `--follow` marks the new window (`tests/ui.sh`), `.rows.kept` is written by every dashboard load and by nothing else, `--follow` repaints from it with no start of tagents and no second `--list` (`tests/window-rows.sh`, `tests/forks.sh`), the start's record skips the dashboard's own session and the option holds the viewport's window after a leftover rebuild and a resurrect (`tests/cockpit.sh`, `tests/resurrect.sh`). Proof: each seen red with the fix undone.
- [x] 1.2 Read the viewport client's window in the list's own tmux call (`lib/tagents/state.sh`), keep the rows in `list()` and route every dashboard load through `list_reload` (`lib/tagents/list.sh`, `dash.sh`, `keys.sh`, `closed.sh`, `columns.sh`, `refresh.sh`), repaint in `--follow` (`lib/tagents/follow.sh`) and fold `cockpit_record_window` into `cockpit_await_viewport` with the session guard (`lib/tagents/cockpit.sh`). Proof: `pnpm test`.
- [x] 1.3 Say what is now true in `lib/tagents/README.md`, `docs/` and the comments of `follow.sh` and `list.sh`, and add the `CHANGELOG.md` line. Proof: `pnpm spec:check`, `pnpm plugin:check`, `pnpm messages:check`.

## 2. Fixes after the review

- [x] 2.1 The keep checks of `tests/forks.sh` run with marks on and differ in `TA_KEEP_ROWS` alone; a list without marks keeps nothing, pinned apart.
- [x] 2.2 The cursor is put right after the load that follows a repaint (`cursor_confirm` in `lib/tagents/follow.sh`), and a refused post is no repaint; both pinned in `tests/window-rows.sh`.
- [x] 2.3 The first load goes through `list_kept` (`lib/tagents/list.sh`, `dash.sh`), pinned in `tests/window-rows.sh`.
- [x] 2.4 The restore into a cockpit that is up is checked in `tests/resurrect.sh`.
- [x] 2.5 `refresher_sweep` removes `.rows.kept.<pid>` of a dead process (`lib/tagents/refresh.sh`, `tests/refresh.sh`, the `refresher` spec and `docs/architecture/refresh.md`).
- [x] 2.6 The specs of `cockpit`, `dashboard-list` and `window-rows`, the proposal, the comments and `docs/` say what is built.
- [x] 2.7 The suites wait on the processes of their own program, not on a time or on the whole machine (`tests/ui.sh`, `tests/cockpit.sh`).
- [x] 2.8 One check in `tests/cockpit.sh` sends the repaint to a real fzf and reads the mark off the list's pane.
