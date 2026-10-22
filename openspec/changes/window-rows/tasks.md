## 1. Remove the seat model

- [ ] 1.1 Delete `lib/tagents/dock.sh` and `lib/tagents/seats.sh` and every `source` of them, and stop dispatching `--seats`, `--current-seat`, `--ensure-seat`, `--collapse`, `--unpark`, `--poke`, `--focus-hooks`, `--slot`, `--undock-pane` and `--undock-window`, keep `--ensure-dash` and `--goto`, and dispatch the new `--follow`. Proved by `tests/dispatch.sh` (the verb table has none of the removed ones and has `--follow`) and `tests/modules.sh` (every module still sources).
- [ ] 1.2 Stop writing `@tagents_slot`, `@tagents_parked`, `@tagents_docked`, `@tagents_seat` and `@tagents_cur`, the `tagents-panes` ring, `@tagents_gen` and the sidebar window's `pane-border-status`. Proved by `tests/window-rows.sh`: after selecting, joining and breaking out chats no pane or window carries any of these options.
- [ ] 1.3 Retire `tests/panes.sh` (the existing seats suite; there is no `tests/dock.sh` in the tree) and the seat sections of `tests/ui.sh`, moving the case of a user's pane that tagents never touches and the sidebar-marker cases into `tests/window-rows.sh`. Proved by `tests/window-rows.sh` passing on its own and `tests/ui.sh` passing without the seat sections.

## 2. Rows, groups and dimmed rows in the list

- [ ] 2.1 Group rows by the `#{session_name}` of their window, name the header after the session, show the session path in it, order session groups by name and keep `dir_roots` only for the subdirectory shown in front of the detail text, and put every row with no window (closed with the pane gone, headless) in the trailing group `no window`, always last. Proved by `tests/ui.sh` (grouping, header, ordering, Cyrillic names) and `tests/window-rows.sh` (two directories in one session).
- [ ] 2.2 Count a session as a group when it holds a chat or tagents created it, marking the sessions tagents creates, and leave scratch sessions out. Proved by `tests/window-rows.sh` ("A scratch session", "A session tagents created").
- [ ] 2.3 List a dimmed row for every window of a group whose first pane besides the sidebar has no agent state: key `@<id>`, state `none`, window name only, ordered after the chats and before the closed rows, absent from the flat list. Proved by `tests/ui.sh` (row line, order, flat list) and `tests/window-rows.sh` ("An editor window").
- [ ] 2.4 Make the group header stand in for its first printed row (open chats, then dimmed rows, then closed rows), draw its bold or dim state from the rows including dimmed ones, and give the flat list a column with the group's name. Proved by `tests/ui.sh`.
- [ ] 2.5 Stop drawing the `▶` and `▹` marks. Proved by `tests/ui.sh` (no row carries either mark with chats in several windows).

## 3. Selecting, following and the sidebar's place

- [ ] 3.1 `enter` on a chat row or a dimmed row moves the sidebar into the row's window with `join-pane -h -b -f -d -l <cols>`, switches the client and puts the cursor in the chat; nothing moves when the sidebar is already there; a window that is gone leaves everything in place with one line. Proved by `tests/window-rows.sh` ("Selecting a row" scenarios).
- [ ] 3.2 `enter` and `ctrl-g` on a session header switch to that session's last-used window and move the sidebar there without changing which window the session had selected. Proved by `tests/window-rows.sh` ("A header").
- [ ] 3.3 Add `tagents --follow [CLIENT]` and install its hooks on `session-window-changed` and `client-session-changed`, one command per event however often they are installed, doing nothing for a window outside a group, with no sidebar, or when the sidebar is already there. Proved by `tests/window-rows.sh` ("Next window", "Another session", "A scratch session", "Hooks installed twice").
- [ ] 3.4 Make `--follow` loop-free and race-safe: no further hook run after its own move, and a window that closed in between leaves the sidebar in place with one line on standard error and exit 0. Proved by `tests/window-rows.sh` ("No second run", "The window closes first").
- [ ] 3.5 Join and start the sidebar with `-l "${TA_WIDTH}%"` (`DASH_WIDTH` in `lib/tagents/core.sh`, default 45), and restore the other panes' widths when it leaves and returns. Proved by `tests/window-rows.sh` ("A split window", "Another width", "Out and back").
- [ ] 3.6 Carry over "Which pane is the sidebar" and "A list claims the sidebar and gives it up on exit" without window marking. Proved by `tests/window-rows.sh` (dead marker, moved sidebar, second list, list exit).
- [ ] 3.7 Never close the sidebar: killing the only chat of a window moves the sidebar to the window the client lands on first, a chat that exits leaves the sidebar in place, moving the sidebar out of a window it was alone in closes that window, and `ctrl-x` on the list's own pane only shows its notice. Proved by `tests/window-rows.sh` ("The sidebar is never closed", "ctrl-x never kills the sidebar").

- [ ] 3.8 Keep `tagents --ensure-dash` but make it put the sidebar in the window the client is in: start a list there as a new leftmost pane when none runs (`split-window -b -h -l "${TA_WIDTH}%"`) and wait for its claim, move the running one like `--follow` otherwise, and exit 1 with no client; stop reading `TA_SESSION`. Proved by `tests/window-rows.sh` ("No sidebar yet", "A sidebar elsewhere", "No client").
- [ ] 3.9 Title the sidebar pane `tagents-sidebar` while a list claims it, wherever it moves. Proved by `tests/window-rows.sh` ("Titled and moved").

## 4. Keys

- [ ] 4.1 `ctrl-s` joins the chosen chat's pane into the window on screen beside its chat with `@tagents_joined=<home session>`, keeps the first home on a second join, only focuses a chat already there, resumes a closed row first, and closes the window it emptied. Proved by `tests/window-rows.sh` ("Ctrl-s joins a chat into the window on screen").
- [ ] 4.2 `ctrl-u` breaks a joined chat out into a new detached window of its home session (its own session when the home is gone), clears `@tagents_joined`, and shows `tagents: that chat is not joined to another window` otherwise. Proved by `tests/window-rows.sh` ("Ctrl-u breaks a joined chat out into a window of its own") and `tests/ui.sh` (the `?` window picking `undock`).
- [ ] 4.3 Remove the `borrow` verb: its `ctrl-o` default, its row in `tagents --keys`, the `?` window and the `--act` verbs, and make a `borrow:` entry in `keys:` ignored. Proved by `tests/ui.sh` (key table, moved key, retired verb) and `tests/config.sh` (`--check` on a config with `borrow`).
- [ ] 4.4 `ctrl-g` goes to the window and never resumes (`tagents: that chat is closed — enter resumes it`); pane verbs on a dimmed row show `tagents: that window runs no chat`; the headless and child notices say `open` instead of `dock`. Proved by `tests/ui.sh`.
- [ ] 4.5 `ctrl-x` closes a chat's window together with the chat when nothing but the sidebar is left, and no longer sends anything home. Proved by `tests/window-rows.sh` ("Killing the only chat of a window") and `tests/ui.sh` (confirm, cancel).
- [ ] 4.6 A chat started with `ctrl-n` or `ctrl-p` opens as a new detached window in the session of the group the cursor is in and is then selected like any row. Proved by `tests/window-rows.sh` ("Cursor in another group") and `tests/launch.sh`.

## 5. tnotes

- [ ] 5.1 Remove `hide_editor`, `show_editor`, the `ta-notes` session, the focus-hook sync, `@ta_notes_any`, `@ta_notes_open` and `@ta_notes_pct`, and the call to `tagents --focus-hooks`; make `toggle` on a chat with an editor move the cursor between the two; make `sync` take no pane. Proved by `tests/notes.sh`.
- [ ] 5.2 Keep `sync` as a clean-up that closes editors whose chat is gone and never moves an editor of a living chat. Proved by `tests/notes.sh` ("The backstop changes nothing", "Chat killed").
- [ ] 5.3 Bring editors parked in `ta-notes` back beside their chats once, close those whose chat is gone and end the session. Proved by `tests/notes.sh` ("A parked editor", "The chat is gone", "Nothing parked").
- [ ] 5.4 An editor leaves the screen with its window and returns unchanged when the row is selected again. Proved by `tests/window-rows.sh` ("Panes beside a chat belong to the user") and `tests/notes.sh` ("Another row selected").

## 6. Resurrect

- [ ] 6.1 Write the docked column empty, keep 14 columns, read and ignore it in old snapshots, record each chat at its pane's session, window and pane, record a joined chat under its home session with empty window and pane columns, and write the `D` row from the window the sidebar is in. Proved by `tests/resurrect.sh` (column positions, joined chat, sidebar window, old snapshot).
- [ ] 6.2 Place a chat at its recorded pane when that is an idle shell and otherwise in a new window of its session; leave the other panes tmux-resurrect brought back alone; start the sidebar in the `D` row's window or the first restored chat's window; close unlinked editors and a returned `ta-notes` session; stop special-casing a `dash` window. Proved by `tests/resurrect.sh` ("A shell beside the chat", "A joined chat", "The window is gone", "Orphans closed and one editor reopened").
- [ ] 6.3 After a restore (`tagents --resurrect` and `--resurrect --auto`) close every idle shell titled `tagents-sidebar` that is not the live list, touch no other pane, and close nothing on `--dry-run`. Proved by `tests/resurrect.sh` ("Shells where the sidebar was", "Dry run") and `tests/window-rows.sh` ("Leftover shells", "A busy pane with that title").

## 7. Migration

- [ ] 7.1 On the first start after the upgrade, send every docked chat home with the old swap logic kept for that one pass (in a file of its own, not `dock.sh`), break out a chat whose placeholder is gone, and close every placeholder. Proved by `tests/window-rows.sh` ("Two docked chats", "A placeholder that is gone") on a server built with the old markers.
- [ ] 7.2 Remove `@tagents_slot`, `@tagents_parked`, `@tagents_docked`, `@tagents_seat` and `@tagents_cur` and the old focus hooks from the server, leave `agents:1` as an ordinary window holding the sidebar, and ask `tnotes sync` to bring parked editors back. Proved by `tests/window-rows.sh` ("Two docked chats").
- [ ] 7.3 Make the clean-up idempotent and leave the server in a state the previous version handles (every chat in its home window, no placeholder), which is the rollback path. Proved by `tests/window-rows.sh` ("Started twice") and an assertion in the same suite on the end state.

## 8. Docs and generated files

- [ ] 8.1 Regenerate `contract.json` and `skills/tagents/references/` with `pnpm plugin:gen` after the verbs and keys change, and update the README sections on docking, `ctrl-o`, `TA_WIDTH` (now the sidebar's share of any window it is in), `TA_SESSION` (no longer read), `ta-notes` and the focus hooks. Proved by `tests/dispatch.sh` and a clean `pnpm plugin:gen` diff in the pre-commit hook.
- [ ] 8.2 After the change is archived, edit the `## Purpose` lines of `dashboard-list`, `notes-workspace` and `window-rows` (deltas cannot change them) and decide the fate of the emptied `seats-and-docking` spec. Proved by `pnpm dlx @fission-ai/openspec@1.14.3 validate --specs --strict`.

## 9. Refresher, launch, popup, names, dispatch and closed sessions

- [ ] 9.1 Refresher: ring the 18 hooks at `[42]` without `tagents-panes` or `@tagents_gen`, install and put back the follow hooks with them, drop the focus hook commands (unpark, stamp, poke, `tnotes sync` on focus), the seat checks, the seat cursor, the slow pass that repairs a seat and `--poke`, compare a snapshot of `@tagents_list`, `@tagents_dash`, `@tagents_joined`, `@tagents_port` and `@ta_notes_for`, and start `tnotes sync` on the slow pass only while a pane carries `@ta_notes_for` or `ta-notes` exists. Proved by `tests/refresh.sh`.
- [ ] 9.2 `chat-launch`: open a new agent in the session of the group the cursor is in (the owning session or the client's for `no window` and for `tagents --new` from a shell), select it like any row, and select a resumed closed row the same way, in a new window of its group's session when its pane is busy or gone. Proved by `tests/launch.sh` and `tests/window-rows.sh` ("Cursor in another group").
- [ ] 9.3 `dashboard-popup`: `enter` in a popup brings the sidebar to the chat's window, starting it with `--ensure-dash` when there is none. Proved by `tests/ui.sh`.
- [ ] 9.4 `window-names`: name a window from its chat when the sidebar is in it, leave a sidebar-only window alone, and rename on `--label` for an agent beside the sidebar. Proved by `tests/names.sh`.
- [ ] 9.5 `cli-dispatch`: the removed flags are no longer the script's own and `--follow` is. Proved by `tests/dispatch.sh`.
- [ ] 9.6 `closed-sessions`: the picker's `enter` resumes in the session of the group the cursor was in and selects the chat. Proved by `tests/closed.sh`.
- [ ] 9.7 Wording only, no delta: `notify` keeps the `click: dock` value and `tagents --act open`, and `status-bar-tally` keeps `TA_MARKS=0` although no seat marks are drawn any more. Proved by `tests/dispatch.sh` (the `--act open` call) and `tests/ui.sh` (`TA_MARKS=0` prints rows).
