## Context

A group of the list is a tmux session, but only a session that passes `session_is_group` (`lib/tagents/follow.sh`): one that holds a live chat or carries `@tagents_made`, which tagents sets on a session it creates itself (`resurrect_place` in `lib/tagents/resurrect.sh`). The same test is made four more times in other shapes: the list's awk builds `hasChat` from the live panes and from the made field of the `G` record (`lib/tagents/list.sh`, `lib/tagents/state.sh`), `row_group` (`lib/tagents/rows.sh`) hands it to ctrl-n, ctrl-p and ctrl-y, and `follow()` stops at a session that fails it. A session that fails it has no header and no rows, so nothing in it can be selected, closed or given a window from the list, and the sidebar does not follow into it.

A window that holds nothing but the sidebar gets no dimmed row (the sidebar is not a row), so a session reduced to that window shows nothing even when it is a group.

A chat is started by `new_agent` and `new_agent_pick` (`lib/tagents/launch.sh`), which each spell out the same session chain (`session_for_dir`, `client_session`, the server's current session, `LAST_RESORT_SESSION`), and created by `start_agent`, which makes a session for the last resort and a detached window otherwise. The resume path makes its own window with the same `new-window` line.

See `proposal.md` for why.

## Goals / Non-Goals

**Goals:**

- One rule for what a group is, which the user can see on the status bar: a tmux session.
- Any session can be given a window from the list, a session holding only the sidebar included.
- A shell window is a key away, opened like a chat and selected like any row.

**Non-Goals:**

- A setting that hides a session from the list.
- A shell in a split, or a shell running a command: `ctrl-a` always opens a window with tmux's default command.
- Any change to what `enter` and `ctrl-g` do on a header (they show the session), to the columns, or to the closed rows whose pane is gone (they stay in `no window`).

## Decisions

**Every session is a group, and the test goes rather than being widened.** `session_is_group`, `chat_in_session` and `mark_session_made` are deleted, `row_group` goes and its five callers take `row_session`, the `G` record loses its made field, and the list's `hasChat` loops go. A pane's group key is then its session whenever it has one:

```awk
gk[p] = (sn != "") ? "s:" sn : "w:"
```

Widening the test (marking every session the client has ever shown, say) was rejected: it keeps a rule the user cannot see and still leaves a session started by hand out until something visits it. `@tagents_made` values already set on a live server are never read again, so nothing has to be cleared. A closed row whose pane is still alive now sits in its session's group even when no chat runs there, which is where the pane is.

**A session holding only the sidebar is a header with no row, built from the window the dimmed-row loop already finds.** That loop skips a window with no pane besides the sidebar; it now remembers it per session, and once the loop is done a session with nothing else listed gets a group whose stand-in is that window:

```awk
if (dmf == "") { sbonly[dms] = dmw; continue }
...
for (s in sbonly) {
  g = "s:" s
  if (g in gtotal) continue          # the session has rows after all
  gmin[g] = 4.5; gtotal[g] += 0      # not closed; a group with no rows
  standin(g, 0, 1, wix[sbonly[s]], sbonly[s], "none", "", spath[s])
}
```

The header loop prints every key of `gtotal`, so no new print is needed. Because the header carries the `@window` key, state `none` and the session's directory, every verb already does the right thing with it: `ctrl-n`, `ctrl-p` and `ctrl-a` find the session through `row_session`, `ctrl-x` reaches the existing "that is the dashboard itself" branch of `kill_agent`, and `enter` shows the session, which is the window on screen. A dimmed row for the sidebar's own window was rejected: `enter` and `ctrl-x` on a row that is the list itself make no sense. Leaving the session out (no header, no row) was rejected because then nothing could be opened in it, which is the request.

**The cursor falls back to the header.** `cursor_to_window` skips header lines on purpose: a header carries its stand-in's key and would take the cursor off the row. The awk now also keeps the first header line per key, and uses it only when no row matched:

```awk
index($2, "\342\226\276") > 0 && !($1 in hline) { hline[$1] = NR }
END { ...; if (w in line) print line[w]; else if (w in hline) print hline[w] }
```

The fallback finds the header of a header-only group, whose stand-in key is the window itself. A sidebar left alone in one window of a session that has others has neither a row nor a header of its own (the session's header stands in for another row), so the cursor stays where it was, as it does today for a window with no line.

**The sidebar follows into every session.** The block of `follow()` that stopped at a session that is not a group is deleted; the "already there" and "no sidebar wanted" stops stay.

**`ctrl-a` is a new verb `shell`, and it shares the launch path with `ctrl-n`.** The session chain becomes one helper, `launch_session <root>`, used by `new_agent`, `new_agent_pick` and `new_shell` (an empty root skips `session_for_dir`). The window becomes one helper, `new_pane_window <session> <dir> [cmd]`, used by `start_agent`, the resume path and `new_shell`: a session for the absent last resort, a detached `new-window -t "=$sess:"` otherwise, always with `-c`, because without it a window made from a command client starts in the caller's directory.

```sh
new_shell() {  # <dir> [session] — ctrl-a
  local dir=${1:-} sess=${2:-} pane idx
  case $dir in /*) [ -d "$dir" ] || dir="" ;; *) dir="" ;; esac
  [ -n "$sess" ] || sess=$(launch_session "$(repo_root "$dir" || printf '%s' "$dir")")
  [ -n "$dir" ] || dir=$(tmux display -p -t "=$sess:" '#{session_path}' 2>/dev/null)
  [ -n "$dir" ] && [ -d "$dir" ] || dir=$HOME
  pane=$(new_pane_window "$sess" "$dir") || {
    tmux display-message "tagents: could not open a window in $sess" 2>/dev/null; return 1; }
  idx=$(tmux display -p -t "$pane" '#{window_index}' 2>/dev/null)
  open_agent "$pane"
  tmux display-message "tagents: new shell in $(basename "$(tilde_of "$dir")") ($sess:$idx)" 2>/dev/null
}
```

The row's directory comes first, so a shell opened on a chat's row starts where that chat works; the list's own directory is never used, because the list runs wherever the sidebar was first started and that says nothing about the row. `act` gets `shell) new_shell "$dir" "$(row_session "$pane")" ;;`; like `new` and `pick` it is not in the `@*` refusal list, so a dimmed row and a header-only group reach it. The key binds with `execute-silent` in both modes, because nothing is asked, and closes the popup through the same `$after` as `ctrl-g`. Unlike `start_agent` it calls no `resurrect_soon`: there is no chat to record, and tmux-resurrect saves the window itself.

**`tilde_of` writes `~` for the home directory itself.** One case is added; every caller is a string a human reads (the window question, the closed picker's directory line and its "is gone" notice, the account question, the resurrect report). The closed-sessions spec already requires `resuming in ~`, which today prints the full path, and the `ctrl-a` message needs the same for a shell in the home directory: `basename "~"` is `~`.

**`shell` takes `ctrl-a`, placed after `pick` in `KEY_DEFAULTS`.** Table order is precedence, and `ctrl-a` collides with no default. It is fzf's beginning-of-line, which a list whose query is a filter can lose, as `ctrl-e` was lost to `send`.

## Risks / Trade-offs

- [A session kept for something else (a popup's session, a monitoring session) is now listed and draws the sidebar when the client visits it] → its windows are dimmed rows like any other; the user keeps no such session today, and a setting to hide one is a non-goal that can follow on its own.
- [Many idle sessions make a longer list] → each costs a header and one line per window, sorted by name among the other sessions as a made session is today; folding a group away is a separate change.
- [`ctrl-a` is the prefix of many tmux configurations, which would swallow it] → `keys: {shell: …}` moves it, and the `?` window runs the verb whatever key it has.
- [A header-only group lasts only while the sidebar is alone in the session's last window; any pane split there or any window opened there turns it into ordinary rows] → that is the intent: the header is the handle for a session that has nothing else to select.
- [Moving the sidebar out of the window it is alone in kills that window, and with the last window the session and the client] → `ctrl-n` and `ctrl-a` create the new window in the same session before the sidebar moves, so the session never loses its last window; `show_window` switches the client before the sidebar moves, as before.

## Migration Plan

Nothing is stored differently: the `G` record is rebuilt on every refresh, and `@tagents_made` is left where it is and ignored. The live install is updated as for every change (`tagents update`, the plugin updated in both stores, the sidebar restarted). Rolling back is reverting the merge and updating again; a session the new code created carries no mark, and the old code then treats it as it treats any session without one.
