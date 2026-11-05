## 1. The saved directory is read by ctrl-n and ctrl-p

- [x] 1.1 Write failing checks: nothing saved, a saved subdirectory, the account dialog, a removed directory, `--new` and `--window`, two sessions with similar names, a restart of the server, the dialog's answers, a group header, headless and closed rows, the header path and `ctrl-a`. Proof: `tests/window-rows.sh`.
- [x] 1.2 Add the store, `session_dir`, `session_dir_set`, the dialog and the `exact` argument of `new_agent` and `new_agent_pick`, and read it in the `new` and `pick` branches of `act`. Proof: `tests/window-rows.sh`.
- [x] 1.3 Print the saved path in the header, and watch the file in the refresher. Proof: `tests/window-rows.sh`, `tests/refresh.sh`, `tests/forks.sh`.

## 2. The key

- [x] 2.1 Add the `dir` verb and `ctrl-d` to the key tables, the bindings, `--ask-dir`, the schema, the example config, the help text, the guide and the skill's reference. Proof: `tests/ui.sh`, `tests/config.sh`, `pnpm --filter @tagents/core test`, `pnpm docs:build`.
- [x] 2.2 Add the `CHANGELOG.md` line. Proof: `pnpm spec:check`.
