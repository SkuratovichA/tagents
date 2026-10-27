## 1. One layout

- [x] 1.1 Remove `dashboard.layout` and its validation case from `lib/tagents/config.sh`, and the layout reader and `cockpit_want` from `lib/tagents/cockpit.sh`.
- [x] 1.2 Make `tagents`, `tagents --ensure-dash` and a list started in a user's pane make or reuse the cockpit for that client.
- [x] 1.3 Delete the follow layout: the list mover, width memory, zoom guard, wish flag, start-in-window path, `leave_window_for_kill` and `landing_window`.
- [x] 1.4 Cut `tagents --follow` down to moving the list's cursor onto the row of the window the viewport shows, doing nothing with no cockpit up.

## 2. Keys and messages

- [x] 2.1 Make `enter` in the popup bring the cockpit up when it is not, and show the agent's window in the viewport.
- [x] 2.2 Add `goto_window` to `lib/tagents/cockpit.sh` and route `ctrl-g` and `--act goto` through it, with `tagents: that window is gone` and `tagents: no terminal to take there`.
- [x] 2.3 Change the header's enter label to `open in dashboard`.
- [x] 2.4 Show `tagents: usage is off — set usage.watch to the profile to track` when `$` is pressed with usage off.

## 3. Columns

- [x] 3.1 Replace the table of widths per breakpoint in `lib/tagents/list.sh` with columns measured from the rows and let in one at a time.
- [x] 3.2 Keep the figure columns and the state word at full width, let the state word in only while the longest name can still grow, and never let a hidden column in.

## 4. Resurrect and names

- [x] 4.1 Rebuild a leftover cockpit session in place before the dashboard is restored, and make the dashboard restore the cockpit only.
- [x] 4.2 Leave the dashboard's own window unnamed and keep the session `tagents` out of the groups.

## 5. Specs and docs

- [x] 5.1 Write the deltas in this change and bring the main specs to the same final state.
- [x] 5.2 Rewrite the dashboard guide so the cockpit is how the dashboard works, drop `layout:` from the account example, and describe `ctrl-g`, `$` and the columns where the guide names them.
- [x] 5.3 Run `pnpm spec:check` with no warnings.
