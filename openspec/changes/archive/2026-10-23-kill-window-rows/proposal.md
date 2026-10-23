## Why

`ctrl-x` kills a chat from the sidebar, but a window that runs no chat (a shell, a dev server, an editor) is a dimmed row, and `ctrl-x` on it only says `tagents: that window runs no chat`. Closing such a window means leaving the list, going to the window and pressing `prefix+&`, and when the sidebar sits in that window tmux's own kill takes the sidebar with it. The owner wants to close plain tmux windows from the sidebar the same way chats are closed: after a question that says what will be lost.

## What Changes

- `ctrl-x` on a dimmed window row asks `kill this window?` in the same popup a chat's kill asks in (inline where there is no popup). The question names the window, by its name and its `session:index`, and lists every pane in it except the sidebar, each with the command running in it and its directory, so a wrong press costs a glance and a keystroke. When the window is the last of its session and the sidebar is not in it, the question also says that the session ends with it.
- `y`, `yes` or their capitals close the window with every pane in it, ring the refresher's channel and retake the resurrect snapshot; anything else, or no answer within 60 seconds, cancels.
- The sidebar never goes with a window killed from the list. When it is in that window it moves first, with the client, to the window the client lands on, or to a new shell window of the same session when the window was the session's last: the same move `ctrl-x` already makes for the only chat of a window.
- Whether the window still exists is checked when the question is asked. A window closed since its row was drawn asks nothing and shows `tagents: that window is gone`. A window that holds nothing but the sidebar is never a dimmed row; `tagents --act kill` on one shows `tagents: that is the dashboard itself` and kills nothing.
- `ctrl-s`, `ctrl-u`, `ctrl-e`, `ctrl-r` and the `ctrl-v` modal on a dimmed row keep refusing with `tagents: that window runs no chat`.
- A group header keeps standing in for the row it stands in for today: an open chat first, then a dimmed window, then a closed row. On a group with no open chat, `ctrl-x` on the header therefore asks about its first dimmed window, by name, before anything is killed.
- The help text, the `?` window, the README and the generated plugin references describe the new `ctrl-x`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `window-rows`: `ctrl-x` on a dimmed row kills the window after asking, and the sidebar is moved out of a window that is killed with it inside.
- `dashboard-keys`: `ctrl-x` is no longer refused on a dimmed row.

## Impact

- Affected code: `lib/tagents/actions.sh` (`kill_agent`, `ask_kill`, a new `end_window`, `act`), `lib/tagents/rows.sh` (`leave_window_for_kill`), `lib/tagents/keys.sh` (the `?` line), the help in `tagents`, `README.md`, and the plugin references, contract and version that `pnpm plugin:gen` regenerates from the help.
- Affected tests: `tests/window-rows.sh`.
- No new flag, option or hook: `--ask-kill` and `--act kill` take a window id where they took a pane id.
