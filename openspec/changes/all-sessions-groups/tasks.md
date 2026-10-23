## 1. Every session is a group

- [x] 1.1 Delete `chat_in_session`, `session_is_group` and `mark_session_made` from `lib/tagents/follow.sh`, and the block of `follow()` that stops at a session that is not a group, with the comments that describe that stop; rewrite F3 and F34 of `tests/window-rows.sh` as "the sidebar follows into a session without a chat" and "a sidebar that was killed comes back in a session without a chat", and verify with `tests/window-rows.sh`.
- [x] 1.2 Drop the made field from the `G` record (`state_snapshot` in `lib/tagents/state.sh`) and the `hasChat` loops from the list's awk (`lib/tagents/list.sh`), so a pane's group key is its session whenever it has one; remove the `@tagents_made` setups from `tests/window-rows.sh`, rewrite L3 as "a session without a chat has a header over its dimmed row" and R37's comment, and verify with `tests/window-rows.sh`.
- [x] 1.3 Delete `row_group` from `lib/tagents/rows.sh` and switch its five callers (`lib/tagents/actions.sh` act's header test, `new` and `pick`; `closed_window` in `lib/tagents/closed.sh`; `:closed` in `lib/tagents/keys.sh`) to `row_session`; add a test that `ctrl-n` on a dimmed row of a session where no chat ever ran opens the chat in that session, and verify with `tests/window-rows.sh` and `tests/closed.sh`.
- [x] 1.4 Remove `mark_session_made` from `resurrect_place` in `lib/tagents/resurrect.sh`; Z6's third check becomes "the created session has a header", and verify with `tests/window-rows.sh` and `tests/resurrect.sh`.
- [x] 1.5 Rewrite the group sentence of the help (`tagents`, the tree paragraph and "THE SIDEBAR FOLLOWS YOU") and of `README.md` (the sidebar paragraph) to say every session is a group and the sidebar follows into any session; verify that `grep -n 'row_group\|session_is_group\|mark_session_made\|chat_in_session\|tagents_made\|hasChat\|smade' lib/tagents/*.sh tagents` prints nothing and `tests/ui.sh` passes.

## 2. A session holding only the sidebar

- [x] 2.1 In the dimmed-row loop of `lib/tagents/list.sh` remember, per session, a window with no pane besides the sidebar, and after the loop give each such session that has nothing else listed a header whose stand-in is that window (its `@id`, state `none`, no session id, the session's path); add tests to `tests/window-rows.sh` for the header alone and its fields, for `ctrl-x` on it (shows `tagents: that is the dashboard itself`, kills nothing), and for `ctrl-n` on it (the session ends with one window, the chat, with the sidebar in it), and verify with `tests/window-rows.sh`.
- [x] 2.2 Let `cursor_to_window` in `lib/tagents/follow.sh` fall back to the first header line of the window's key when no row matches; add a test beside R34 that `pos(n)` is posted for the header of a session holding only the sidebar, and verify with `tests/window-rows.sh`.
- [x] 2.3 Say in the help (`tagents`, the tree paragraph) and in `README.md` that a session holding only the sidebar is a header with no row, which `ctrl-n`, `ctrl-p` and `ctrl-a` open a window in; verify with `tests/ui.sh`.

## 3. The home directory reads `~`

- [x] 3.1 Add the `"$HOME"` case to `tilde_of` in `lib/tagents/core.sh`; add a check that `modrun tilde_of "$HOME"` prints `~`, a test that the window question shows `~` for a pane in the home directory, and a check in `tests/closed.sh` case 4 that the notice reads `is gone — resuming in ~`, and verify with `tests/window-rows.sh` and `tests/closed.sh`.

## 4. `ctrl-a` opens a shell

- [x] 4.1 Add `launch_session <root>` and `new_pane_window <session> <dir> [cmd]` to `lib/tagents/launch.sh` and make `new_agent`, `new_agent_pick`, `start_agent` and the resume path's new window use them, with no change of behaviour; verify with `tests/launch.sh`, `tests/window-rows.sh` and `tests/closed.sh` unchanged.
- [x] 4.2 Add `new_shell <dir> [session]` to `lib/tagents/launch.sh` (directory chain: the row's absolute existing directory, else the session's path, else `$HOME`; message `tagents: new shell in <name> (<session>:<index>)`) and `shell)` to `act` in `lib/tagents/actions.sh`; add tests to `tests/window-rows.sh` for `ctrl-a` on a dimmed row, on a chat row, on a row of `no window`, on the header of a session holding only the sidebar, with the row's directory gone, with nothing left to start in, and for `tagents --act shell @<id> none '' <dir>`, and verify with `tests/window-rows.sh`.
- [x] 4.3 Add `shell ctrl-a K_SHELL` after `pick` to `KEY_DEFAULTS` and its line to `keys_table` in `lib/tagents/keys.sh`, and bind it in `lib/tagents/dash.sh` with `execute-silent` and the popup's `$after`; update the key table test and the drift check of `tests/ui.sh`, add a test that `keys: {shell: alt-s}` binds `alt-s` and not `ctrl-a`, and verify with `tests/ui.sh` and `tests/config.sh`.
- [x] 4.4 Document `ctrl-a` in the key list of the help (`tagents`), the key table of `README.md` and the `keys:` block of `config.example.yaml`, then run `pnpm plugin:gen` and keep what it regenerates; verify that a second `pnpm plugin:gen` leaves `git status --short` unchanged and `tests/ui.sh` passes.

## 5. Integration

- [ ] 5.1 Run every suite under `tests/` on a scratch server, one at a time, as `env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/<suite>.sh`, and verify that each exits 0.
- [ ] 5.2 Run `pnpm spec:check` and verify that it passes.
- [ ] 5.3 Check on the live server with the branch's `tagents`: a session without a chat has a header over its windows, `ctrl-a` on one of its rows opens a shell there with the sidebar in it, and `ctrl-x` on that row asks and closes it.

## Workflow follow-up

- Open the pull request and merge it once 5.1 to 5.3 hold.
- Archive the change with `openspec archive all-sessions-groups`, rerun `pnpm spec:check`, and split any merged requirement whose body is over 500 characters.
- Update the live install (`tagents update`, the plugin in both stores, the sidebar restarted) and remove the worktree.
