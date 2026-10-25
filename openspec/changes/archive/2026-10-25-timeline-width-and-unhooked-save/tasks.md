## 1. Timeline width

- [x] 1.1 `tty_cols` in `lib/tagents/core.sh` asks the controlling terminal; `timeline.sh` and the first frame of `dash.sh` call it
- [x] 1.2 `tests/headless.sh` runs the timeline without `COLUMNS` in a 160-column pane and wants a line wider than 100
- [x] 1.3 The list's last-resort width in `list.sh` calls `tty_cols` instead of `tput cols`

## 2. Resurrect hold-off

- [x] 2.1 `resurrect_hooked` in `lib/tagents/resurrect.sh`; `resurrect_save` holds a young server off only when it is true, and says so on a terminal's stderr
- [x] 2.2 The `--resurrect-save` manual in `tagents` and `skills/tagents/references/scripts.md` say so
- [x] 2.3 `tests/resurrect.sh` sets the hook where the hold-off is expected and adds the case without it

## 3. Specs

- [x] 3.1 `claude-code-plugin`: the install, the hooks scenario, the parts of the ecosystem, and the skill naming `@tagents/notify` (its description and its routing table)
- [x] 3.2 `LEARNING.md` has one entry per bug
