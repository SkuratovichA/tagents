## 1. One agent, one name

- [x] 1.1 Write failing checks in `tests/names.sh`: a name by pane id reaches the session, the row and the dialog, an older label is replaced, clearing takes both keys, and a label under the pane seeds the dialogs. Proof: `tests/names.sh`.
- [x] 1.2 Give a name through one function, `name_agent`, that files it under the session of the pane's record and removes the pane's line. Proof: `tests/names.sh`.
- [x] 1.3 Read an agent's label through `label_for` in the rename, kill and resume dialogs and in the preview heading. Proof: `tests/names.sh`, `tests/launch.sh`.
- [x] 1.4 Add the `CHANGELOG.md` line. Proof: `pnpm spec:check`.
