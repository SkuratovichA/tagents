## Context

The sidebar today is one pane, the `tagents --list` process titled `tagents-sidebar` and marked `@tagents_list`/`@tagents_dash`, which `tagents --ensure-dash` starts in the client's window and the `tagents --follow` hooks at index 43 (`lib/tagents/follow.sh`) move into whatever window a client switches to; `show_window` (`lib/tagents/rows.sh`) switches the client first and moves the sidebar after it, and tmux 3.7b has no hook for a pane changing window (`LEARNING.md`, 18.10.2026). Eight places ask which client acts and which window is on screen — in `closed.sh`, `follow.sh`, `launch.sh` (three), `preview.sh`, `rows.sh` and `sidebar.sh` — and every one of them goes through `client_attr` in `follow.sh`, which takes the named client, else the most active one. Groups are the sessions `list-sessions` reports (`state.sh`), a new chat goes to the session `session_for_dir` picks (`launch.sh`), the refresher waits on a counted ring (`@tagents_evgen` and the channel `tagents-ev`) that the hooks at index 42 signal (`refresh.sh`), status messages are bare `display-message` calls spread over `tagents`, `lib/tagents` and `tnotes`, and the resurrect save files the sidebar's window as the `D` row. Why the cockpit is wanted is in `proposal.md` and what it must do is in this change's specs; this document says how it fits into the code above.

## Goals / Non-Goals

**Goals:**
- One switch, `dashboard.layout`, and with any value but `cockpit` every code path runs as it does today.
- In the cockpit no pane ever changes window: the only thing that changes what is on screen is `switch-client -c` on the viewport's client.
- The question "which window is on screen" keeps one answer in one place, which learns the cockpit once.
- `ctrl-q` takes off the server everything the cockpit put there: the session, the hook, the key table and the options.

**Non-Goals:**
- Making the cockpit the default.
- Changing how the follow layout moves the sidebar, including the flash a switch shows there; that is separate work.
- tmux older than 3.7b, or any promise about it.
- A second tmux server, or more than one viewport.
- Changing any of the user's own key bindings or options.

## Decisions

**The right side is a client of the same tmux server, running in a pane.** The viewport's pane runs `tmux attach` on the socket its own `TMUX` names, with `TMUX` unset, which tmux allows, so it is one more client of the one server, whatever `-L` or `-S` that server was started with: sessions, hooks, options and the refresher's state stay single, and the shown session's own status line is the row of tabs. A second server was rejected because every tmux call in tagents would have to choose a socket and the hooks and state would split between the two; linking the shown window into the dashboard (`link-window`) because a linked window has one size and one active pane for every session it is in, and its own session's tabs would not show; closing and reopening the sidebar on each switch because that is the flash this layout removes; and tuning the follow layout's move because the move itself is what reads as the flash.

**`tagents --viewport` is a bash loop whose child is the attach.** The pane keeps one tty for its whole life, so `@tagents_viewport_tty` and the client's name stay valid across attaches, and attaching again on the same pty takes about 280 ms (measured on 3.7b). The pane marks itself: `--viewport` accepts only a pane of the dashboard's window that is not the list, then sets its own title, `@tagents_viewport` and `allow-set-title off` before it attaches, so a pane started again needs no second call that could lose a race with that check.

```sh
tty=$(tty); sock=${TMUX%%,*}; tmux set -g @tagents_viewport_tty "$tty"
while :; do
  target=$(viewport_target)   # newest live entry of @tagents_viewport_shown, else the other session used last
  if [ -z "$target" ]; then echo "tagents: no session to show"; ring_wait; continue; fi
  env -u TMUX tmux -S "$sock" attach -f no-detach-on-destroy -t "$target"
  [ "$(tmux show -gqv @tagents_viewport_tty)" = "$tty" ] || break   # ctrl-q cleared it
  idle=$(tmux show -gqv @tagents_viewport_idle); tmux set -gu @tagents_viewport_idle
  [ -n "$idle" ] || tmux detach-client -t "$(dash_terminal)"        # no mark: it was prefix d
done
```

The ctrl-q mark ends the loop; the idle mark means the guard below detached the client because `tagents` was the only session, so the loop prints the message and waits; an end with neither is `prefix d`, so the loop detaches the dashboard's terminal used last and attaches again, which leaves the dashboard whole at the next `tmux attach -t tagents`. `ring_wait` is the refresher's ring wait, the generation check and `wait-for tagents-ev` as one `if-shell -F`, taken out of `ev_wait` into one function both use. `respawn-pane` was rejected for attaching again because it gives the pane a new tty, which makes the stored one stale, and a failing attach under it restarts in a tight loop; an `exec`'d attach because the pane would die with its client, so a detach or a closed session would take the viewport with it.

**The layout is live state, and only a start reads the config.** Starting a list and `--ensure-dash` read `dashboard.layout` through `cfg_get`; everything else asks the server whether the cockpit is up, so a config edit never leaves the hooks, the key table and the selection code disagreeing about the layout of a running dashboard. Reading the config at every call was rejected for exactly that.

```sh
cockpit_up() { [ "$(tmux show -qv -t '=tagents:' @tagents_cockpit 2>/dev/null)" = 1 ]; }
```

The colon in `=tagents:` is what makes that target an exact session match (`LEARNING.md`, 22.10.2026). The cockpit's own code — making the session, `--viewport`, the guard, the key table, `ctrl-q` and the leftover check — lives in a new module, `lib/tagents/cockpit.sh`; the existing modules gain a `cockpit_up` branch at each site and nothing else.

**One resolver learns the cockpit.** `client_attr` is the one place the eight sites ask, so it is the one place that changes (`LEARNING.md`, 14.10.2026: a guard for one site belongs at every site). Its client list gains a flag for a client attached to the dashboard, and when the client it settles on is on the dashboard or is the viewport's client, it answers with the viewport client's values instead; when no client is named, the viewport's tty is never the most active one, because it is nobody's terminal. So `ctrl-s`, a new chat and every other site get the window the viewport shows with no change of their own.

```sh
tmux list-clients -F "#{client_activity} #{client_name} #{?#{@tagents_cockpit},1,0} $1"
```

The two questions that need the real terminal — which terminal a selection takes to the dashboard, and which one `prefix d` detaches — go through a raw lookup beside it that never substitutes.

**Selecting a row is one `switch-client -c` of the viewport's client.** In the cockpit `show_window` moves the viewport's client to the window, which also selects that window in its session (measured), makes the viewport the dashboard's active pane, puts the cursor on the row, and switches the acting terminal to `tagents` only when it is on neither the dashboard nor the viewport. No `join-pane` or `move-pane` runs in the cockpit, and `sidebar_move` is never called there.

```sh
tmux switch-client -c "$vtty" -t "=$sess:$win" \; select-pane -t "$vpane"
[ -n "$pane" ] && tmux select-pane -t "$pane"
cursor_to_window "$win"
[ "$client" = "$vtty" ] || on_dashboard "$client" || tmux switch-client -c "$client" -t '=tagents:'
```

**A synchronous hook keeps the viewport's client off the dashboard.** A closed session, a `prefix (` or `prefix )` step, a pick in `prefix s` and a script's `switch-client` without `-c` can all land the viewport's client on `tagents`, where it would draw the dashboard inside itself without end. The guard is a global `client-session-changed[44]` hook that runs inside the server right after the switch, with no shell started in between: `if -F` on `#{hook_client}` against `@tagents_viewport_tty`, then `run-shell -C`, whose command is format-expanded where an `if -F` action is not (measured). `run-shell -b` was rejected because it runs against a later state (`LEARNING.md`, 17.10.2026), and in that gap the viewport recurses. The direction comes from the session the client left, and from whether any session sorts between that one and `tagents`, since `switch-client -n` and `-p` follow name order and wrap at the ends. A hook runs with no client of its own, so a bare `#{client_last_session}` in it names the last session of the client tmux finds best, the most recently active one, which is another terminal as soon as a second client is attached (measured); the guard reads the hook client's own through a loop over the clients, `#{L:#{?#{==:#{client_name},#{hook_client}},#{client_last_session},}}`, which in this hook already names the session that client left (measured). The guard as it was measured, with `LS` standing for that loop:

```
if -F "#{&&:#{==:#{hook_client},#{@tagents_viewport_tty}},#{@tagents_cockpit}}" "run-shell -C \"#{?#{==:#{server_sessions},1},set -g @tagents_viewport_idle 1 ; detach-client -t #{hook_client},switch-client -c #{hook_client} -#{?LS,#{?#{<:LS,tagents},#{?#{S:#{?#{&&:#{>:#{session_name},LS},#{<:#{session_name},tagents}},1,}},p,n},#{?#{S:#{?#{&&:#{>:#{session_name},tagents},#{<:#{session_name},LS}},1,}},n,p}},n}}\""
```

Its direction follows this table:

| The session it left | No session between it and `tagents` | Some session between |
| --- | --- | --- |
| sorts before `tagents` | it came forward: step `-n` | it wrapped going back: step `-p` |
| sorts after `tagents` | it came back: step `-p` | it wrapped going forward: step `-n` |

An empty last session means the client's session was closed, and the hook steps `-n` at once; the asynchronous `--follow` then takes it to the last session it showed that still exists. With `tagents` the only session the hook sets `@tagents_viewport_idle` and detaches the viewport's client, and the loop waits. A session-level hook on `tagents` was rejected because a session's hook shadows the global hook of the same name for that session, which would silence the hooks at indexes 42 and 43 there (measured); `detach-on-destroy` set per session was rejected because it changes what happens to every client of that session, the user's terminals included.

**`--follow` in the cockpit reads the viewport's client, whatever client it is called for.** The `--follow` hooks at index 43 stay installed in both layouts. `session-window-changed` is a session's event with no client, so the client its hook passes to `--follow` is the one tmux finds best, as for the guard above, and in the cockpit that is as often the dashboard's terminal or another terminal on the shown session as it is the viewport's client. So in the cockpit `tagents --follow` ignores the client it is given, reads the viewport's client through the raw lookup, and does nothing while `@tagents_viewport_tty` is unset or that client is on `tagents`. It puts the shown session's id first in `@tagents_viewport_shown`, the last 16 distinct session ids the viewport showed, newest first, and it moves the list's cursor only when the window the viewport shows differs from `@tagents_viewport_window`, the window it last moved the cursor to, which it then records. Another client's change therefore moves the cursor only when it changes what the viewport shows, as a window change in the session the viewport shows does, and a cursor the user moved stays where it is. When the newest id in that list names a session that no longer exists, the change came from a close, and `--follow` switches the viewport's client to the newest id that still exists, else to the other session used most recently. `switch-client -l` cannot do this, because after a close the client has no last session (measured). The list holds ids rather than names so that a renamed session does not read as a closed one.

**Each half of the dashboard brings the other back.** The refresher already wakes on `after-kill-pane`, `pane-exited` and `pane-died` through the ring, and in the cockpit it starts a missing viewport again with `split-window` to the right of the list. The list cannot start itself again, so the viewport's loop keeps a second waiter on the same ring, in the background, which starts a missing list with `split-window -b` at `TA_WIDTH` percent. A half is missing when the dashboard's window holds one pane and that pane is the other half, never when a pane is merely not marked yet, so a dashboard still starting is never split twice. Both restorers do nothing while `@tagents_viewport_tty` is unset, which it is from `ctrl-q` on and before the first viewport has started, so a quit is never undone. `respawn-pane -k` on the list was rejected because the dying list's exit trap can run after the new list has claimed the sidebar and clear its options; polling was rejected because it costs a tmux call on every tick for something that happens rarely. A viewport started again attaches to the newest live entry of `@tagents_viewport_shown`, which outlives the pane.

**The dashboard's prefix keys are forwarded to the viewport through a key table.** With the user's prefix on the dashboard session, the outer terminal would take `prefix n` and `prefix (` for itself and the viewport's client would never see them. So the session `tagents` sets `prefix` and `prefix2` to `None` and `key-table` to `tagents-cockpit`, and that table binds each prefix key the user has when the dashboard starts:

```sh
tmux bind -T tagents-cockpit C-a select-pane -t "$vpane" \; send-keys -t "$vpane" C-a
tmux bind -T tagents-cockpit MouseDown1Pane select-pane -t = \; send-keys -M
```

The prefix reaches the viewport's client, which reads the next key in the user's own prefix table. Every key the table does not bind goes to the active pane, root bindings included, and the root table is never consulted (measured): the list gets its own keys, and the viewport's client acts on the user's tmux keys as they configured them. The table also holds the root table's bindings for clicking, dragging and scrolling, copied when the dashboard starts from `list-keys -T root` (the lines whose key has `Mouse`, `Wheel` or `Click` in it, with `-T root` rewritten and loaded back with `source-file`), so they are tmux's defaults or the user's own as the server has them; the ones that run `display-menu` are left out, because a menu would open with the dashboard's context instead of the viewport's; one click in the viewport selects the viewport's pane and, passed on, the pane inside it (measured). A double prefix was rejected because it changes every habit; rewriting the user's root bindings with an `if -F` on the session because tagents never edits the user's bindings.

**Messages go through one helper that knows which status line is on screen.** The dashboard's status line is off, so a message for an action taken in the cockpit belongs on the viewport's client. A `notice` helper in `lib/tagents/core.sh` adds `-c` with the viewport's tty while `@tagents_viewport_tty` is set and falls back to a plain message when that client is gone; every `display-message` in `tagents` and `lib/tagents` that shows a message rather than printing a format calls it, and a static check in the tests fails on one that does not, so a new site cannot forget it. `tnotes` sources nothing from `lib/`, so its `die()` carries a copy of the same lines, and a test pins the copy against `core.sh`.

```sh
notice() {  # <message>: on the viewport's client while the cockpit is up, where tmux puts it otherwise
  local vtty; vtty=$(tmux show -gqv @tagents_viewport_tty 2>/dev/null)
  { [ -n "$vtty" ] && tmux display-message -c "$vtty" "$1" 2>/dev/null; } || tmux display-message "$1" 2>/dev/null
}
```

Popups stay as they are: `prompt_at` and the `?` window open `display-popup` against the list's pane (`core.sh`), which tmux shows on the dashboard's terminal over the whole dashboard, and a test pins that.

**`ctrl-q` takes the cockpit down in an order that leaves nothing half-done.** The handler runs inside the list, whose pane goes with the session, so the session is killed last:

1. Read the window the viewport shows.
2. Unset `@tagents_sidebar_on` and `@tagents_viewport_tty` in one tmux call, so the guard and `notice` stop matching the viewport's client and its loop reads the cleared tty as the end.
3. `release_dash`.
4. Switch every terminal attached to `tagents` to that window, or detach them when there is none.
5. Remove the hook at index 44, unbind the table `tagents-cockpit`, and unset the other global `@tagents_viewport_*` options.
6. Kill the session `tagents`.

The cockpit never sets `@tagents_sidebar_on`, the flag the follow hooks read before they move the sidebar, and `--ensure-dash` in the cockpit unsets it, so no follow move can start while the cockpit is up.

**The rest follows from the dashboard not being a place.**
- Groups (`state.sh`) and `session_for_dir` (`launch.sh`) skip a session carrying `@tagents_cockpit`, so the dashboard is never a group and never a chat's destination.
- `--ensure-dash` makes the session with `new-session -d -x <width> -y <height>` at the calling client's size, because a detached session is 80x24 until a client attaches and the list's width is a share of it (`LEARNING.md`, 12.09.2026).
- A session `tagents` without `@tagents_cockpit` whose one window holds two idle shells titled `tagents-sidebar` and `tagents-viewport` is a leftover from tmux-resurrect. That check runs before the taken-name check and before the restore's sweep, which would otherwise call it taken or close its shells. In the cockpit the leftover is rebuilt where it is, with `respawn-pane -k` on its two idle shells, which run no list whose exit trap could race, and no client is switched; in the follow layout its clients go to the sidebar's window and it is closed.
- In the cockpit `tnotes toggle` hands the switch to `tagents --goto <editor pane>` instead of switching the client itself, behind its own one-line cockpit check, since it sources nothing.
- notify's probe (`packages/notify/src/screen.ts`) also reads each client's tty and session and `@tagents_viewport_tty`. A pane the viewport's client shows counts as on screen only through the most active terminal attached to `tagents`, whose activity and pid stand in for it, and the viewport's own pid is never the client pid notify uses.
- `dashboard.layout` is read with `cfg_get`, and `--check` reports a value other than `follow` or `cockpit`.
- The refresher's slow pass already sets the hooks at indexes 42 and 43 again (`install_event_hooks` in `refresh.sh`); while the cockpit is up it sets the guard at index 44 again as well, so a guard that something outside removed comes back within one slow pass.

## Risks / Trade-offs

- [A script that runs `switch-client` without `-c`, tmux-resurrect's restore among them, can move the viewport's client] → the guard keeps it off the dashboard, and `--follow` moves the cursor to wherever it lands.
- [A leftover dashboard would look like a taken name] → the leftover check runs first and accepts only two idle shells with the two titles.
- [Root bindings (`bind -n`) do not fire while the list is the active pane, and act in the viewport's session while the viewport is] → measured on 3.7b, and the README's cockpit section says so.
- [Everything here is measured on tmux 3.7b only] → the tmux cases at the top of `tests/cockpit.sh` fail first on a tmux that behaves differently.
- [The viewport's client is a real client: `list-clients` lists it, it sizes the windows it shows, and it marks their sessions attached] → every client count and every choice of the most active client skips its tty, and a window shown in the viewport and in another terminal at once is sized by the user's `window-size`, as for any two terminals.
- [Any `#{client_*}` in a hook's format reads the client tmux finds best, not the hook's client] → the guard reads its client's last session through the client loop, and `--follow` in the cockpit reads the viewport's client by its tty; the follow layout's own `#{client_name}` fallback is left as it is, outside this change.
- [A copy in the viewport can reach tmux twice, from the session and back through the viewport's pane, leaving two equal paste buffers] → accepted.
- [Detaching the viewport's client by hand reads as `prefix d` and detaches the dashboard's terminal too] → the README says so; `ctrl-q` is the way out of the cockpit.
- [When the shown session is closed, the viewport shows the next session in order for a moment before it goes back to the last one it showed] → accepted: the guard has to step at once, and only the asynchronous `--follow` reads the history.
- [A `@tagents_viewport_tty` left behind by a viewport killed by hand names no client] → the guard and `notice` do nothing with it until the viewport starts again and sets it.
- [The user changes the prefix while the cockpit is up] → the table keeps the keys it was made with until the dashboard starts again.
- [The guard is synchronous but the cursor and the history follow asynchronously, so the suite races them] → the cases wait with `wait_eq`, which moves out of `tests/window-rows.sh` into a sourced `tests/wait.sh` that both suites source, and one red timing case is rerun before it counts (`LEARNING.md`, 14.09.2026).

## Migration Plan

1. Nothing changes for a config without `dashboard.layout`, which is every config today.
2. To use the cockpit: quit the sidebar with `ctrl-q`, set `dashboard.layout: cockpit`, and run `tagents --ensure-dash` or the key bound to it.

Rollback: set `dashboard.layout: follow` or remove the key, then press `ctrl-q` in the cockpit; the next list starts in the follow layout, and the cockpit leaves nothing on the server.
