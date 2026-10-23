## Why

The list shows a tmux session only when a chat runs in it or tagents created it. A session the owner made for a shell, a dev server or an editor therefore has no header, no rows and no sidebar: its windows cannot be seen, selected or closed from the list, and nothing can be started in it from there. The owner wants every session in the list, wants to open a window in a session that has no chat yet, and wants that window to be a plain shell as easily as a chat.

## What Changes

- Every tmux session is a group, whether or not a chat has ever run in it. A session without a chat lists each of its windows as a dimmed row under its header, as a chat's session already does. `enter`, `ctrl-g` and `ctrl-x` work on those rows as they do today, and so do `ctrl-n` and `ctrl-p`, which open the new chat in that session.
- A session whose only window holds nothing but the sidebar has a header with no row under it. This is a session the owner is looking at with every other pane closed. The header stands in for that window: `ctrl-n`, `ctrl-p` and `ctrl-a` on it open the session's first real window, `ctrl-x` on it kills nothing, and the list cursor goes to it while that window is on screen.
- The sidebar follows into every session. `prefix s`, `prefix n` and a click on the status bar bring it along whatever the session holds, a killed sidebar comes back in any session, and the list cursor follows to the row of the window on screen there.
- A closed row whose pane is still alive in a session is listed under that session instead of under `no window`, and a new chat or a resume started from it opens in that session.
- A new default key, `ctrl-a`, has the verb `shell`, the config key `keys.shell` and the command `tagents --act shell`. It opens a window running tmux's default command, as `prefix c` would, created detached in the session of the group the cursor is in and then selected like any row:
  - The window starts in the row's directory when that directory exists, otherwise in the session's working directory, otherwise in the home directory. It never starts in the directory the list runs in.
  - On the group `no window`, the window goes to the session a chat started with no group would get.
  - The message is `tagents: new shell in <name> (<session>:<index>)`.
  - In a popup, `ctrl-a` closes the list as `ctrl-n` does.
- tagents no longer sets or reads the session option `@tagents_made`. The value it left on a live session is ignored, so nothing has to be migrated.
- The home directory itself now reads `~` wherever tagents shows a directory to a person, as a directory under it already reads `~/…`. This covers a pane's line in the window question of `ctrl-x`, the directory line of the closed-session picker and the account question of `ctrl-n` and `ctrl-p`. It also fixes the closed-session picker's `… is gone — resuming in ~` notice, which the `closed-sessions` spec already requires and which today prints the full home path. A shell that `ctrl-a` starts in the home directory makes the case common.
- The help text, the `?` window, `tagents --keys`, the README, `config.example.yaml` and the generated plugin references describe `ctrl-a` and the new grouping.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `window-rows`:
  - every session is a group, and a session holding only the sidebar has a header alone;
  - the sidebar and the list cursor follow into every session;
  - `ctrl-a` opens a shell window in the group under the cursor.
- `dashboard-keys`:
  - `ctrl-a` is a default key with the verb `shell`, which the config can move and `--act` can run;
  - a dimmed row refuses only the verbs that need a chat.
- `dashboard-list`: a group header can stand alone, for a session whose only window holds the sidebar.
- `dashboard-popup`: `ctrl-a` closes the popup once its window is open.

## Impact

- Affected code:
  - `lib/tagents/follow.sh`: the group test and the made mark go, `follow` no longer stops at a session, and `cursor_to_window` can land on a header that stands alone.
  - `lib/tagents/rows.sh`: `row_group` goes, and its callers take `row_session`.
  - `lib/tagents/state.sh`: the `G` record loses its made field.
  - `lib/tagents/list.sh`: every session groups, every session gets dimmed rows, and a sidebar-only session gets a header alone.
  - `lib/tagents/resurrect.sh`: no longer marks sessions.
  - `lib/tagents/launch.sh`: one session chain is shared by `new_agent`, `new_agent_pick` and a new `new_shell`.
  - `lib/tagents/actions.sh`: `act` dispatches `shell`.
  - `lib/tagents/keys.sh`, `lib/tagents/dash.sh`.
  - `lib/tagents/core.sh`: `tilde_of` returns `~` for the home directory itself.
  - Docs and generated files: the help in `tagents`, `README.md`, `config.example.yaml`, and the plugin references, contract and version that `pnpm plugin:gen` regenerates.
- Affected tests:
  - `tests/window-rows.sh`: the cases for a session that is not a group flip, and there are new cases for `ctrl-a` and the header that stands alone.
  - `tests/ui.sh`: the key table.
  - `tests/closed.sh`: the `resuming in ~` notice.
- Risk:
  - A session that something else creates and hides is now listed too, for example one attached inside a `display-popup`. tagents creates none.
  - A server with many idle sessions gets a longer list. The flat list (`ctrl-t`) still has no groups.
