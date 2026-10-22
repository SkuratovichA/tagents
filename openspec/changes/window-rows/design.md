## Context

The dashboard today is one window, `agents:1`, holding the sidebar (the `tagents --list` pane, marked `@tagents_list=<pid>` and `@tagents_dash=1`) and one or more seats. Enter swaps a chat's pane into a seat with `swap-pane` (`lib/tagents/dock.sh`), leaving a placeholder pane (`@tagents_slot=1`, `@tagents_parked=<chat>`) in the chat's home window, and ctrl-u swaps it back. tnotes keeps its editor beside a chat by parking it in the `ta-notes` session with `break-pane` and joining it back with `join-pane`, driven by focus hooks. Groups come from working directories (`dir_roots` in `lib/tagents/state.sh`), and their names merely coincide with the owner's tmux sessions. Herdr, which the owner points to, shows workspaces in its sidebar, tabs inside them, and panes inside a tab, where an agent is only a pane whose foreground process is a known agent.

## Goals / Non-Goals

**Goals:**
- A row is a place: the chat plus any panes the user splits beside it, all of which leave the screen when another row is selected and return with it.
- A group is a tmux session, and selecting it shows that session.
- One sidebar that is on screen in whatever window the user is in, however they got there.

**Non-Goals:**
- Rerunning the commands of extra panes after a reboot: they come back as idle shells.
- More than one sidebar process, or a sidebar per client.
- Any change to the list's columns, states, costs or the agent-state hook.

## Decisions

**A row is a window, and the sidebar moves to it.** tmux cannot show one pane in two windows, so either the sidebar travels to the chat's window or the chat's panes travel to the sidebar's window. Moving the one sidebar pane is one `join-pane` per switch, whatever the window holds. The other way (seats with parked companion panes, as tnotes does) moves every extra pane on every switch, and needs a saved layout string per chat. It was rejected for that cost and because a group could not be shown as a session.

```sh
follow() {  # the sidebar into the window on screen, once
  here=$(tmux display -p -t "$client" '#{window_id}')
  [ "$(tmux display -p -t "$LIST_PANE" '#{window_id}')" = "$here" ] && return 0
  tmux join-pane -h -b -f -d -l "$SIDEBAR_COLS" -s "$LIST_PANE" -t "$here"
}
```

`-b -f` makes the sidebar the leftmost full-height pane whatever the window's split. Its width is the existing `TA_WIDTH` setting (percent of the window, default 45), passed as `-l "${TA_WIDTH}%"`, so no new setting appears. The window it leaves gets the width back from tmux, which spreads it over the pane that was beside the sidebar.

**Starting the first sidebar.** `tagents --ensure-dash` stays. With no list running, it starts one as a new pane in the client's current window (`split-window -b -h -l "${TA_WIDTH}%"`, as `lib/tagents/sidebar.sh` does today) and that pane claims the sidebar. With a list running, it moves the list there, as `--follow` does.

**Rows keep their keys.** A chat row stays keyed on its chat pane's id, because `--act` and the key bindings take a pane and a joined chat shares its window with another row. A dimmed row is keyed on its window id. Closed and headless rows have no window, and they are listed in a trailing group after the session groups.

**A restore leaves no stale sidebars.** tmux-resurrect saves every window's split, the sidebar's included, and gives each window back an idle shell where the sidebar was. The sidebar pane carries the pane title `tagents-sidebar`, which tmux-resurrect saves and restores. After `tagents --resurrect`, every pane titled `tagents-sidebar` that is not the running list is closed.

**Following without a loop.** `session-window-changed` and `client-session-changed` run `tagents --follow`; a `join-pane` itself fires neither hook, and `follow` returns at once when the sidebar is already in the current window. A follow that loses a race (the window closed in between) leaves the sidebar where it was and logs one line; the next switch moves it.

**A group is a session.** The list groups rows by `#{session_name}` of their window. A session counts as a tagents group when it holds at least one chat or was created by tagents, so a scratch session the user never ran a chat in stays out of the sidebar. A new chat opens with `new-window -t <session>:` in the session of the group the cursor is in.

**Non-chat windows are dimmed rows.** Every window of a tagents group gets a row, so the sidebar is the whole map. A window counts as a chat window when its first pane carries an agent state. A dimmed row has a name (the window name) and no state, age, context or cost.

**Joined chats replace side-by-side seats.** ctrl-s runs `join-pane -h -d -s <chat pane> -t <current window>`, and the chat's row then points at the current window. ctrl-u on a joined chat runs `break-pane -d -s <pane> -t <its session>:`, which gives it a window of its own again. The joined pane carries `@tagents_joined=<home session>` so that ctrl-u and resurrect know where it belongs.

**tnotes stops parking.** The editor is opened with `split-window` beside the chat and is never moved: switching rows takes it off screen with the rest of the window. `@ta_notes` and `@ta_notes_for` stay, for toggling. The `ta-notes` session, `hide_editor`, `show_editor`, the focus-hook sync and `@ta_notes_any` go away.

**Resurrect keys stay; the docked field goes.** Rows keep keying on the Claude session id. The recorded session and window index are where the chat really is, because nothing swaps it any more. A snapshot written before the change still parses: the docked column is read and ignored.

## Risks / Trade-offs

- [The window being left reflows when the sidebar leaves it, and `-l` alone does not give it back the same split when the sidebar returns] → before the sidebar leaves a window, the widths of that window's panes are saved in the window option `@tagents_widths` and re-applied after the sidebar comes back.
- [Two clients in different windows share one sidebar] → the sidebar sits with the client that moved last, as today; a second client sees its window without it.
- [Groups by session regroup rows whose directory and session differ] → the first list run after the upgrade shows the new grouping; nothing is lost, and the owner's sessions already match its directory groups.
- [Hooks fire for every window switch on the server] → `follow` is one `display` and returns, and it only acts for windows of tagents groups.

## Migration Plan

1. On first run of the new version, every docked chat is sent home with the old swap logic (kept for that one pass), every placeholder is closed, and `agents:1` is left as an ordinary window holding the sidebar.
2. tnotes moves parked editors from `ta-notes` back beside their chats once, then kills the `ta-notes` session.
3. Rollback: the old version still finds each chat in its home window, with no placeholders, which is a state it already handles.
