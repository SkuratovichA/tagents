# lib/tagents/follow.sh — the list's cursor following the viewport
#
# THE LIST STAYS WHERE IT IS AND ITS CURSOR FOLLOWS. The dashboard is the cockpit (cockpit.sh): no pane ever changes window, and a window switch made in the viewport, by a key or by tmux itself, moves the list's cursor onto that window's row. The hooks below fire on every client's switch and the follow reads the viewport's client, whichever client the hook names.
#
# Part of ./tagents; `tagents --help` is the model this implements.

FOLLOW_HOOK_INDEX=43   # beside the ring at EV_HOOK_INDEX (42): set twice is set once, and the owner's hooks keep their own indexes
FOLLOW_EVENTS='session-window-changed client-session-changed'

win_alive() {  # <window-id> — one display: a window that is gone prints nothing, and a pane id prints its window's, which is not the id asked about
  [ -n "${1:-}" ] || return 1
  [ "$(tmux display -p -t "$1" '#{window_id}' 2>/dev/null)" = "$1" ]
}

# One value of what a client shows (client_raw in cockpit.sh is the same rule; tests/cockpit.sh pins the two): <format> for the named client, or, with none named, for the most recently active one. The value is the last thing on the line, so a session name with spaces comes through whole.
# In the cockpit (the viewport's tty is stored in @tagents_viewport_tty) a client attached to the dashboard and the viewport's own client both answer with the viewport client's values, since the window on screen is the one the viewport shows; and with none named the viewport's tty is never the most active, because it is nobody's terminal. Without a viewport this is the plain lookup.
client_attr() {  # <format> [client name]
  local vtty
  vtty=$(tmux show -gqv @tagents_viewport_tty 2>/dev/null)
  tmux list-clients -F "#{client_activity} #{client_name} #{?#{@tagents_cockpit},1,0} $1" 2>/dev/null |
    LC_ALL=C awk -v c="${2:-}" -v v="$vtty" '
      { x = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ /, "", x); a[NR] = $1 + 0; n[NR] = $2; f[NR] = $3; val[NR] = x; if (v != "" && $2 == v) vv = x; if (v != "" && $2 == v) hasv = 1 }
      END {
        for (i = 1; i <= NR; i++) {
          if (c != "") { if (n[i] != c) continue; pick = i; break }
          if (v != "" && n[i] == v) continue
          if (a[i] >= m) { m = a[i]; pick = i }
        }
        if (!pick) exit
        if (hasv && (f[pick] == 1 || n[pick] == v)) print vv; else print val[pick]
      }'
}
client_window()  { client_attr '#{window_id}' "${1:-}"; }     # [client name]
client_session() { client_attr '#{session_name}' "${1:-}"; }  # [client name]

# The rows of the dashboard's last load as list lines (key, text, state, session id, directory), one per line of the list and in its order: the kept file holds each row twice, without the mark and with it, and the first copy is the line.
kept_rows() {
  [ -s "$ROWS_KEPT" ] || return 1
  LC_ALL=C awk -F"$US" '{ print $3 }' "$ROWS_KEPT"
}

# The number of the line of the list the cursor goes to for a window, read from list lines on stdin: the row of the first of the window's panes that has one (a chat), else the window's own row (@id), else the first group header that stands in for the window (a session that holds no chat has a header and no row). Nothing when none matches.
list_line_of_window() {  # <window-id>
  local panes
  panes=$(tmux list-panes -t "$1" -F '#{pane_id}' 2>/dev/null | tr '\n' ' ')
  # Rows first: a group header carries its stand-in's key too, and it is the line with the ▾ in it, so it is used only when no row matched.
  LC_ALL=C awk -F"$TAB" -v keys="$panes" -v w="$1" '
    BEGIN { nk = split(keys, K, " ") }
    index($2, "\342\226\276") == 0 && !($1 in line) { line[$1] = NR }
    index($2, "\342\226\276") > 0 && !($1 in hline) { hline[$1] = NR }
    END { for (i = 1; i <= nk; i++) if (K[i] in line) { print line[K[i]]; exit }
          if (w in line) print line[w]; else if (w in hline) print hline[w] }'
}

# The port of the dashboard's fzf, nothing when there is none.
dash_port() {
  local sb
  sb=$(dash_pane)
  [ -n "$sb" ] || return 0
  tmux show -pv -t "$sb" @tagents_port 2>/dev/null
}

# The list cursor onto the row of a window, from the rows the dashboard kept at its last load; with no kept file, or none of its rows in it, from a list of its own.
cursor_to_window() {  # <window-id>
  local port n
  port=$(dash_port)
  [ -n "$port" ] || return 0
  n=$(kept_rows | list_line_of_window "$1")
  [ -n "$n" ] || n=$("$SELF" --list 2>/dev/null | list_line_of_window "$1")
  [ -n "$n" ] && post_fzf "$port" "pos($n)"
  return 0
}

# The kept rows as they would be with the window's rows marked and every other row unmarked: a plain awk over the file, with no start of tagents, and no parenthesis in it, since fzf reads the action it is run in. The rows of the window that can carry the mark take the fourth field and every other row the third.
repaint_cmd() {  # <window-id>
  printf "LC_ALL=C awk -v w=%s 'BEGIN{FS=\"\\\\037\"} \$1==w&&\$2==1{print \$4;next} {print \$3}' '%s'" "$1" "$ROWS_KEPT"
}

# The dashboard's list redrawn at once for a window that has just come on screen: its rows from the kept file with the mark on the window's rows and none elsewhere, and the cursor on the window's row, in one action to the list. Fails, and posts nothing, when the dashboard kept no rows or none of them is the window's, which is a window the next load has to find.
# A KEPT ROW IS SAFE TO PAINT because only the mark is moved: the text of every row is what the last load drew, which is at most one refresher pass old, and the load that follows --follow's ring (the option it writes is in the refresher's snapshot) draws the list afresh. The load of a list that is running is not lost to this one, since the repaint is posted before the option is written (see follow).
repaint_to_window() {  # <window-id>
  local port n
  port=$(dash_port)
  [ -n "$port" ] || return 0
  n=$(kept_rows | list_line_of_window "$1")
  [ -n "$n" ] || return 1
  post_fzf "$port" "reload-sync($(repaint_cmd "$1"))+pos($n)"
  return 0
}

# --follow: the client it is given is no use (the hook's is whichever tmux finds best), so it reads the viewport's client. It keeps @tagents_viewport_shown, takes a viewport whose session was closed to the newest one that still exists, and acts only when the window the viewport shows is not the one the option holds. It then repaints the list at once from the rows the dashboard kept (the mark on the window's rows, the cursor on its row) and writes the option, which rings the refresher for the full load that follows; with no kept rows, or none for the window, the cursor is moved from a list of its own instead. Nothing without the cockpit.
follow() {  # [client, ignored]
  local vtty info sid sess win newest target kept
  cockpit_up || return 0
  vtty=$(tmux show -gqv @tagents_viewport_tty 2>/dev/null)
  [ -n "$vtty" ] || return 0
  info=$(client_raw '#{session_id} #{window_id} #{session_name}' "$vtty")
  [ -n "$info" ] || return 0
  read -r sid win sess <<<"$info"
  [ "$sess" = tagents ] && return 0
  newest=$(tmux show -gqv @tagents_viewport_shown 2>/dev/null)
  newest=${newest%% *}
  if [ -n "$newest" ] && [ "$newest" != "$sid" ] && ! tmux list-sessions -F '#{session_id}' 2>/dev/null | grep -qxF "$newest"; then
    target=$(viewport_target)
    [ -n "$target" ] && tmux switch-client -c "$vtty" -t "=$target:" 2>/dev/null
    info=$(client_raw '#{session_id} #{window_id} #{session_name}' "$vtty")
    [ -n "$info" ] || return 0
    read -r sid win sess <<<"$info"
    [ "$sess" = tagents ] && return 0
  fi
  viewport_shown_push "$sid"
  viewport_window_changed "$win" || return 0
  # THE REPAINT GOES OUT BEFORE THE OPTION IS WRITTEN. A reload that fzf is running is stopped by the next one, and the refresher counts a reload it posted as drawn: a load that started after the write, from a snapshot that holds the new window, would be cut by the repaint and nothing would draw it again. Written after the repaint, the option moves the snapshot, and the ring that follows finds a load to make. A list that runs between the two draws the window from the viewport's client (collect), so the mark is right in both. With no kept row for the window the cursor is placed after the write, from a list, as it always was.
  repaint_to_window "$win"; kept=$?
  viewport_window_record "$win" || return 0
  [ "$kept" = 0 ] || cursor_to_window "$win"
  return 0
}

# Writes the window the viewport shows into @tagents_viewport_window, which the list draws its mark from, and rings the refresher, which reloads only when its snapshot differs. Succeeds when the window is a new one and fails when the option already held it, so a caller moves the cursor only on a change.
viewport_window_changed() {  # <window id> — is it not the window the option holds
  [ -n "${1:-}" ] && [ "$1" != "$(tmux show -gqv @tagents_viewport_window 2>/dev/null)" ]
}

viewport_window_record() {  # <window id>
  viewport_window_changed "${1:-}" || return 1
  tmux set -g @tagents_viewport_window "$1" 2>/dev/null
  signal_ev
  return 0
}

# The hook command: run-shell -b, so a switch never waits for bash to start. It passes no client; hooks an earlier version installed still pass one, and --follow ignores it.
follow_hook_cmd() {
  printf '%s' "run-shell -b \"'$SELF' --follow\""
}
install_follow_hooks() {
  local ev cmd
  cmd=$(follow_hook_cmd)
  for ev in $FOLLOW_EVENTS; do
    tmux set-hook -g "$ev[$FOLLOW_HOOK_INDEX]" "$cmd" 2>/dev/null
  done
  return 0
}
