# Proposal

## Why

The sidebar follows the client today: every window or session switch moves its pane into the window now on screen, which reads as the sidebar closing and opening again, and the session's window tabs run under the whole screen instead of beside the list. An IDE-shaped layout, with a sidebar that never moves and the chosen window on its right under its session's tabs, removes the blink by construction instead of tuning the move. A spike on tmux 3.7b showed that a pane running a second client of the same tmux server can be that right side, held out of its own session by one hook.

## What Changes

- A new config key `dashboard.layout`: `follow` (the default, today's behaviour, unchanged) or `cockpit`, read when the dashboard starts.
- In the cockpit the dashboard is a tmux session of its own, `tagents`, with one window: the sidebar on the left, `TA_WIDTH` percent wide, and the viewport on the right. The viewport is a pane running `tagents --viewport`, a client of the same tmux server attached to the session being shown, so that session's own status bar is the row of tabs.
- Selecting a row (`enter`, a click, a header, `ctrl-g`, `--goto`, `--act open`, and the keys that make a chat or a shell) points the viewport at the row's window and puts the keyboard there. No pane moves, and the user's terminal stays on the dashboard.
- Moving inside the viewport (`prefix n`, `prefix s`, a click on a tab) moves only the list's cursor. Other clients of the server move nothing.
- The viewport never shows the dashboard itself: `prefix (` and `prefix )` step past it in tmux's session order as if it were not there, and picking it in `prefix s` lands on a session next to it. When the session it shows is closed it goes back to the session it showed before, else to the most recently used other session, else it waits with `tagents: no session to show`.
- `tagents --ensure-dash` makes or reuses the cockpit, points the viewport at the window the caller was in and takes the caller to the dashboard. Run from inside the viewport, it puts the keyboard back in the list.
- `ctrl-q` leaves the cockpit: the dashboard's clients go to the session the viewport showed and the dashboard session is closed.
- `prefix d` in the viewport detaches the user's terminal as it would without the cockpit, and the cockpit is there at the next attach.
- The dashboard session is not a group: no header, no rows, no counts. `ctrl-s`, new chats and new shells land in the window the viewport shows, never in the dashboard.
- Resurrect files the viewport's window as the `D` row and builds the cockpit again after a restore; a dashboard that tmux-resurrect brought back as idle shells is rebuilt in place.
- notify counts a chat seen through the viewport as on screen only while a terminal shows the dashboard. tnotes, notify and the popup switch the viewport's client, never the user's terminal.

Nothing here is **BREAKING**: without `dashboard.layout: cockpit` every behaviour stays as it is.

## Capabilities

### New Capabilities
- `cockpit`: the opt-in layout where the sidebar stays put in a dashboard session of its own and the viewport, a nested client of the same server, shows the selected window under its session's tabs.

### Modified Capabilities
- `window-rows`: what it says about moving the sidebar and switching the client becomes the `follow` layout's; the dashboard session is not a group; the restore sweep also closes the viewport's idle leftovers.
- `configuration`: the `dashboard` section among the keys the file carries, and the `--check` line for a layout it cannot read.
- `resurrect`: in the cockpit, the `D` row files the window the viewport shows, the restore builds the cockpit again, and the sweep takes the viewport's leftovers too.
- `cli-dispatch`: `--viewport` joins the flags the script answers itself.
- `notify`: a chat seen through the viewport is on screen only while some terminal shows the dashboard.

## Impact

- Code: the `tagents` script (`--viewport`, `--ensure-dash`, `--follow`, `ctrl-q`); `lib/tagents/rows.sh`, `follow.sh`, `launch.sh`, `closed.sh` and `preview.sh`, which pick the client and the window on screen; the resurrect save and restore; `tnotes` (the toggle's client switch); `packages/notify` (`screen.ts`).
- tmux state other parts read: session `tagents` with the session option `@tagents_cockpit`, the pane title `tagents-viewport` and pane option `@tagents_viewport`, the global option `@tagents_viewport_tty`, and one more hook on `client-session-changed`.
- Config: `dashboard.layout`.
- Tests: a new suite `tests/cockpit.sh` and a shared helper `tests/wait.sh`; cases in `tests/window-rows.sh`, `tests/resurrect.sh`, `tests/config.sh`, `tests/dispatch.sh`, `tests/modules.sh`, `tests/notes.sh` and the notify package tests.
- Docs: `README.md` and `tagents --help`.
- tmux: `switch-client -c`, `attach -f no-detach-on-destroy`, `#{hook_client}` and the `key-table` session option; behaviour measured on 3.7b only.
