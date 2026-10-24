## 1. The suite and what the design measured

- [x] 1.1 Move `wait_eq` and the scratch-server helpers that `tests/window-rows.sh` and the new suite both need into a sourced `tests/wait.sh`, and make `tests/window-rows.sh` source it. Proved by `tests/window-rows.sh` passing unchanged on its own.
- [x] 1.2 Add `tests/cockpit.sh` with the tmux contract cases first: a client attached with `TMUX` unset to the socket `TMUX` names, `switch-client -c` moving only the named client, a key table forwarding a prefix key, the guard hook's `if -F` and `run-shell -C`, the client loop reading the hook client's own last session with two clients attached, a session-level hook shadowing the global one, `prefix d` against a killed session, and the `after-kill-pane` event. Proved by `tests/cockpit.sh` ("tmux contract" cases) passing on tmux 3.7b.
- [x] 1.3 Check that the new cases catch what they are for: with `-c` removed from the `switch-client` case the case for the single moved client fails, and with the client loop replaced by a bare `#{client_last_session}` the two-client case fails. Proved by `tests/cockpit.sh` failing on each mutation and passing once restored.

## 2. Configuration

- [x] 2.1 Read `dashboard.layout` with `cfg_get`, accept `follow` and `cockpit`, read any other value as `follow` and make `--check` report it as `dashboard.layout: "<value>" is not one of follow, cockpit — read as follow`, and list `dashboard` among the keys the file carries. Proved by `tests/config.sh` ("A dashboard layout that cannot be read", "Cockpit chosen", "No dashboard section").
- [x] 2.2 Describe the key in the README's `### The file` section. Proved by `tests/config.sh` (the keys listed in the README are the keys `--check` knows).

## 3. The module, the session and the viewport

- [x] 3.1 Add `lib/tagents/cockpit.sh` before `dash` in the modules loop, holding `cockpit_up` and the raw client lookup, and take the generation check and `wait-for tagents-ev` out of `ev_wait` (`lib/tagents/refresh.sh`) into one `ring_wait` that both the refresher and the viewport use. Proved by `tests/modules.sh` (the module is listed and sourced in order) and `tests/refresh.sh` (the refresher wakes on the ring as before).
- [x] 3.2 Dispatch `--viewport` in `tagents`, accepting only a pane of the dashboard's window that is not the list and printing `tagents: --viewport runs only in the cockpit's viewport pane` with exit 1 anywhere else, and set the pane's title, `@tagents_viewport` and `allow-set-title off` before it attaches. Proved by `tests/dispatch.sh` (the verb table has `--viewport`) and `tests/cockpit.sh` ("The pane and its client", "A title set from inside", "Anywhere else").
- [x] 3.3 Write the viewport loop: store its tty in `@tagents_viewport_tty`, attach to the newest live entry of `@tagents_viewport_shown` else the other session used last, print `tagents: no session to show` and wait on the ring when there is none, end on the cleared tty, wait on the idle mark, and on an end with neither mark detach the dashboard terminal used last and attach again. Proved by `tests/cockpit.sh` ("Detach and come back", "Nothing else to show").
- [x] 3.4 Describe `--viewport` in the help text of `tagents` and the cockpit keys in the `?` line of `lib/tagents/keys.sh`. Proved by `tests/dispatch.sh` (the help lists the verb) and `tests/ui.sh` (the `?` window shows the line).
- [ ] 3.5 Check that the new cases catch what they are for: with the idle mark never set the "Nothing else to show" case fails, and with the tty check removed from the loop `ctrl-q` in group 8 leaves the loop attaching. Proved by `tests/cockpit.sh` failing on each mutation.

## 4. Starting, reusing and refusing the dashboard

- [x] 4.1 Make `--ensure-dash` and a list start choose the layout from `dashboard.layout`, create the session `tagents` with `@tagents_cockpit` 1, status off and `detach-on-destroy` off at the calling client's size, give the list `TA_WIDTH` percent, never set `@tagents_sidebar_on` and unset it when the cockpit starts. Proved by `tests/cockpit.sh` ("A new dashboard", "Its terminals outlive it", "Changed while the cockpit is up") and `tests/refresh.sh`.
- [x] 4.2 Stop on a taken name: a session `tagents` that is not the cockpit's makes `--ensure-dash`, a list start and a restore print `tagents: session tagents is taken — rename it or set dashboard.layout: follow` and exit 1. Proved by `tests/cockpit.sh` ("Someone else's session").
- [x] 4.3 Reuse a running cockpit: restart a missing pane, point the viewport, switch the client, switch nothing from the dashboard or the viewport and activate the list, exit 1 with no client, and let `tagents` typed in a shell run `--ensure-dash` and return the shell to its prompt. Proved by `tests/cockpit.sh` ("From another session", "From the viewport", "tagents typed in a shell", "No client").
- [x] 4.4 Check that the new cases catch what they are for: with the taken-name check removed the "Someone else's session" case fails, and with the `-x`/`-y` size removed the width case fails (`LEARNING.md`, 12.09.2026). Proved by `tests/cockpit.sh` failing on each mutation.

## 5. Selecting a row

- [x] 5.1 Teach `client_attr` (`lib/tagents/follow.sh`) the cockpit: flag the clients attached to the dashboard, answer with the viewport client's values when the settled client is on the dashboard or is the viewport's, and never let the viewport's tty be the most active client. Proved by `tests/cockpit.sh` ("ctrl-s", "A new chat from outside tmux") and `tests/window-rows.sh` (the follow layout answers as before).
- [x] 5.2 Make `show_window` (`lib/tagents/rows.sh`) in the cockpit switch the viewport's client to the window, select the viewport pane, put the cursor on the row and switch the acting terminal to `tagents` only when it is on neither, without calling `sidebar_move` or moving a pane. Proved by `tests/cockpit.sh` ("Enter on a chat", "A header", "Nothing moves").
- [x] 5.3 Route `--goto`, `--act open`, a double click, `ctrl-g`, a new chat and a new shell through that selection, and make a popup's enter and `tnotes toggle` stand in for the follow layout's moves. Proved by `tests/cockpit.sh` ("A popup's enter", "A popup from another session", "A notification clicked") and `tests/launch.sh`.
- [x] 5.4 Skip a session carrying `@tagents_cockpit` in the groups (`lib/tagents/state.sh`) and in `session_for_dir` (`lib/tagents/launch.sh`), and keep the dashboard at two panes after `ctrl-n`, `ctrl-a` and `ctrl-s`. Proved by `tests/cockpit.sh` ("Not listed", "Still two panes").
- [x] 5.5 Check that the new cases catch what they are for: with the `@tagents_cockpit` skip removed from `state.sh` the "Not listed" case fails. Proved by `tests/cockpit.sh` failing on the mutation.

## 6. Keeping the viewport off the dashboard

- [ ] 6.1 Install the global `client-session-changed[44]` guard as the design measured it, with the direction table, the single-session detach with `@tagents_viewport_idle`, and the stepping `-n` on an empty last session, and install it again on the refresher's slow pass while the cockpit is up. Proved by `tests/cockpit.sh` ("Next, past the dashboard", "Previous, past the dashboard", "Picked in the chooser", "Round the end of the order", "Nothing else to show") and `tests/refresh.sh` (a removed guard comes back).
- [ ] 6.2 Make `--follow` in the cockpit ignore the client it is given, read the viewport's client through the raw lookup, keep `@tagents_viewport_shown` as the last 16 distinct session ids, move the cursor only when the viewport's window differs from `@tagents_viewport_window`, and switch to the newest id that still exists after a close. Proved by `tests/cockpit.sh` ("The shown session is closed", "A tab click", "Another terminal", "The shown session changes window elsewhere").
- [ ] 6.3 Check that the new cases catch what they are for: with the guard hook removed the "Next, past the dashboard" case fails, and with the client argument trusted in `--follow` the "Another terminal" case fails (`LEARNING.md`, 14.10.2026). Proved by `tests/cockpit.sh` failing on each mutation; rerun one red timing case before it counts (`LEARNING.md`, 14.09.2026).

## 7. Keys, popups and messages

- [ ] 7.1 Set `prefix` and `prefix2` to `None` and `key-table` to `tagents-cockpit` on the session, bind each prefix key the user has to select the viewport pane and send the key, and load the root table's mouse, wheel and click bindings into the table without the ones that run `display-menu`. Proved by `tests/cockpit.sh` ("Prefix from the list", "The list's own keys", "A click on the list", "A root binding").
- [ ] 7.2 Add the `notice` helper to `lib/tagents/core.sh`, use it at every `display-message` in `tagents` and `lib/tagents` that shows a message, and keep popups opening on the dashboard terminal. Proved by `tests/cockpit.sh` ("The keys window", "A new shell's message") and by `tests/modules.sh`, whose static check fails on a message site that does not call `notice`.
- [ ] 7.3 Check that the new cases catch what they are for: with one message site back on bare `display-message` the static check fails, and with the key table unset the "Prefix from the list" case fails. Proved by `tests/modules.sh` and `tests/cockpit.sh` failing on each mutation.

## 8. Leaving and coming back

- [ ] 8.1 Make `ctrl-q` take the cockpit down in the design's order: read the viewport's window, unset `@tagents_sidebar_on` and `@tagents_viewport_tty` in one call, `release_dash`, switch the dashboard's terminals to that window or detach them, remove the hook at index 44, the key table and the other `@tagents_viewport_*` options, and kill the session last. Proved by `tests/cockpit.sh` ("Quit") and `tests/refresh.sh` (no cockpit option or hook is left on the server).
- [ ] 8.2 Restore a killed viewport from the refresher with `split-window` to the right of the list, restore a killed list from the viewport's own ring waiter with `split-window -b` at `TA_WIDTH` percent, never split a dashboard that is still starting, and do nothing while `@tagents_viewport_tty` is unset. Proved by `tests/cockpit.sh` ("The viewport is killed", "The list is killed").
- [ ] 8.3 Check that the new cases catch what they are for: with the tty unset step removed from `ctrl-q` a restorer undoes the quit and the "Quit" case fails. Proved by `tests/cockpit.sh` failing on the mutation.

## 9. Resurrect

- [ ] 9.1 Save the cockpit's `D` row as `D/work/2` with no `tagents` row, restore the sidebar "where it was" (`lib/tagents/resurrect.sh`), and sweep idle shells titled `tagents-viewport` as well as `tagents-sidebar`. Proved by `tests/resurrect.sh` (the cockpit scenarios of "The sidebar comes back" and the sweep).
- [ ] 9.2 Detect a leftover dashboard, a session `tagents` without `@tagents_cockpit` holding two idle shells titled `tagents-sidebar` and `tagents-viewport`, before the taken-name check and the sweep, rebuild it in place with `respawn-pane -k` on the idle shells in the cockpit and switch its clients and close it in the follow layout. Proved by `tests/cockpit.sh` ("Restored in the cockpit", "Restored in the follow layout") and `tests/window-rows.sh` ("A leftover viewport shell").
- [ ] 9.3 Check that the new cases catch what they are for: with the leftover check after the taken-name check the "Restored in the cockpit" case fails. Proved by `tests/cockpit.sh` failing on the mutation.

## 10. tnotes and notify

- [ ] 10.1 Make `tnotes toggle` call `tagents --goto <editor pane>` behind its own one-line cockpit check in place of switching the client, and give its `die()` the same lines as `notice`, pinned against `core.sh` by a test. Proved by `tests/notes.sh` ("tnotes toggle") and `tests/modules.sh` (the copy matches).
- [x] 10.2 Make notify's probe (`packages/notify/src/screen.ts`) also read each client's tty and session and `@tagents_viewport_tty`, count a pane the viewport shows as on screen only through the most active terminal on `tagents`, and never use the viewport's pid as the client pid. Proved by `cd packages/notify && node --test "test/**/*.test.ts"` ("Seen through the viewport", "The dashboard is not on screen") and `tsc --noEmit`.
- [x] 10.3 Check that the new cases catch what they are for: with the viewport's pid taken as the client pid the "Seen through the viewport" case fails. Proved by the notify tests failing on the mutation.

## 11. The whole tree

- [ ] 11.1 Describe the cockpit, its keys and its limits in `README.md`, then regenerate the plugin references with `pnpm plugin:gen`. Proved by `pnpm plugin:check` exiting 0.
- [ ] 11.2 Add the lessons of this change to `LEARNING.md` by date. Proved by the entry being there.
- [ ] 11.3 Run every suite under `tests/` on its own scratch tmux server with the live server's global hook count the same before and after, and run `pnpm test`, `pnpm spec:check` and `pnpm plugin:check`. Proved by the run's summary and the exit codes.
- [ ] 11.4 Check the cockpit on the live server with `dashboard.layout: cockpit` once the change is merged and installed: start it, select rows in two sessions, press `prefix n` and `ctrl-q`. Proved by the observed behaviour, written down in the pull request.

## Workflow follow-up

- Archive the change inside the branch before the pull request is merged.
- After the merge: `tagents update`, the plugin update in both Claude config stores, and a sidebar restart.
