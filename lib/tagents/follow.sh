# lib/tagents/follow.sh — moving the sidebar, and following the user
#
# THE SIDEBAR IS ONE PANE AND IT TRAVELS. tmux cannot show a pane in two windows, so a row that is a window gets the sidebar by the sidebar
# joining that window (`join-pane -h -b -f -d -l <TA_WIDTH>%`: leftmost, full height, not focused), never by the window's panes travelling.
# join-pane fires window-layout-changed and neither session-window-changed nor client-session-changed (checked on tmux 3.7b), so a move
# made here starts no further follow. A plain re-join does not give the other panes their old widths back (a 21/21 split came back as
# 31/11), so the widths are written on the window when the sidebar leaves and applied again when it returns.
#
# Part of ./tagents; `tagents --help` is the model this implements.

FOLLOW_HOOK_INDEX=43   # beside the ring at EV_HOOK_INDEX (42): set twice is set once, and the owner's hooks keep their own indexes
FOLLOW_EVENTS='session-window-changed client-session-changed'
FOLLOW_LOCK="$STATE_DIR/.follow.lock"
FOLLOW_LOCKED=""   # 1 while this process holds the lock: the lock is not re-entrant, and a follow calls sidebar_move, which takes it for its other callers

# ONE MOVE OR START OF THE SIDEBAR AT A TIME. A follow from a hook, a selection (show_window), ensure-dash and a list claiming its pane can all reach for the sidebar together; the lock is what makes the second one read where the sidebar is after the first has put it there. 0 when THIS call took the lock and its caller releases it with follow_unlock; 1 when this process holds it already or the wait ran out (the work goes on unlocked then: a click that does nothing is worse than a race).
follow_lock() {
  [ -n "$FOLLOW_LOCKED" ] && return 1
  lock_dir "$FOLLOW_LOCK" 10 100 3 || return 1
  FOLLOW_LOCKED=1
  return 0
}
follow_unlock() {
  FOLLOW_LOCKED=""
  unlock_dir "$FOLLOW_LOCK"
}

# Is a sidebar wanted: a list has claimed a pane on this server (claim_dash) and nobody has quit it since (ctrl-q, or a list that gave up). Only then does a follow start a new sidebar when none runs; a server that has only ever shown the popup, or whose sidebar was quit on purpose, gets none from a window switch.
sidebar_wanted() { [ "$(tmux show -gv @tagents_sidebar_on 2>/dev/null)" = 1 ]; }

win_alive() {  # <window-id> — one display: a window that is gone prints nothing, and a pane id prints its window's, which is not the id asked about
  [ -n "${1:-}" ] || return 1
  [ "$(tmux display -p -t "$1" '#{window_id}' 2>/dev/null)" = "$1" ]
}

# One value of what a client shows: <format> for the named client, or, with none named, for the most recently active one. The value is the last thing on the line, so a session name with spaces comes through whole.
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

# Placeholders and docked chats of the previous version. While any is left the sidebar must not leave the window that holds them
# (migrate.sh sends them home first), so a follow stands down until it has.
legacy_seats_present() {
  [ -n "$(tmux list-panes -a -F '#{@tagents_slot}#{@tagents_docked}' 2>/dev/null | tr -d '\n ')" ]
}

win_widths() {  # <window-id> <sidebar pane> -> "%id:width " of the other panes, left to right
  tmux list-panes -t "$1" -F '#{pane_left} #{pane_id} #{pane_width}' 2>/dev/null |
    LC_ALL=C sort -n | LC_ALL=C awk -v sb="$2" '$2 != sb { printf "%s:%s ", $2, $3 }'
}
win_restore_widths() {  # <window-id> <"%id:width …"> — left to right, only panes still in the window; the last pane takes what is left
  local pair id w here
  here=" $(tmux list-panes -t "$1" -F '#{pane_id}' 2>/dev/null | tr '\n' ' ') "
  for pair in $2; do
    id=${pair%%:*}; w=${pair#*:}
    case "$here" in *" $id "*) tmux resize-pane -t "$id" -x "$w" 2>/dev/null ;; esac
  done
}

# The sidebar becomes the leftmost full-height pane of <window>. Returns 0 when it is there afterwards. The client is NOT switched here: a
# caller that also switches the client does that FIRST (show_window in rows.sh), because the sidebar leaving a window it was alone in
# destroys that window and, when it was the session's only one, the session — and a client attached to it is detached from the terminal.
# Under the follow lock, taken before anything is read: where the sidebar is, and its widths, are read after a move another caller was in the middle of has finished.
sidebar_move() {  # <window-id>
  local took="" rc
  follow_lock && took=1
  sidebar_move_now "$@"; rc=$?
  [ -n "$took" ] && follow_unlock
  return "$rc"
}
sidebar_move_now() {  # <window-id> — sidebar_move without the lock
  local win=${1:-} sb from saved err
  [ -n "$win" ] || return 1
  sb=$(dash_pane)
  [ -n "$sb" ] || return 1
  from=$(tmux display -p -t "$sb" '#{window_id}' 2>/dev/null)
  [ "$from" = "$win" ] && return 0
  if ! win_alive "$win"; then
    echo "tagents: window $win is gone — the sidebar stays where it is" >&2
    return 1
  fi
  # A zoomed pane hides every other: the sidebar leaves a zoomed window unzoomed, so that window is not left zoomed on nothing, and the
  # widths below are read from the unzoomed layout.
  [ "$(tmux display -p -t "$sb" '#{window_zoomed_flag}' 2>/dev/null)" = 1 ] && tmux resize-pane -Z -t "$sb" 2>/dev/null
  [ -n "$from" ] && tmux set -w -t "$from" @tagents_widths "$(win_widths "$from" "$sb")" 2>/dev/null
  saved=$(tmux show -wv -t "$win" @tagents_widths 2>/dev/null)
  if ! err=$(tmux join-pane -h -b -f -d -l "${DASH_WIDTH}%" -s "$sb" -t "$win" 2>&1); then
    # Lost a race to another follow, which is a success; the window closing in between is not.
    [ "$(tmux display -p -t "$sb" '#{window_id}' 2>/dev/null)" = "$win" ] && return 0
    echo "tagents: could not move the sidebar into $win — it stays where it is (${err:-no reason given})" >&2
    tmux display-message "tagents: could not move the sidebar — ${err:-no reason given}" 2>/dev/null
    return 1
  fi
  # A join into a window whose active pane is zoomed can leave the sidebar behind the zoomed pane: unzoom, then put the widths back.
  [ "$(tmux display -p -t "$win" '#{window_zoomed_flag}' 2>/dev/null)" = 1 ] && tmux resize-pane -Z -t "$win" 2>/dev/null
  [ -n "$saved" ] && win_restore_widths "$win" "$saved"
  tmux select-pane -T tagents-sidebar -t "$sb" 2>/dev/null
  signal_ev
  return 0
}

# The list cursor onto the row of a window: the row of the first of its panes that has one (a chat), else the window's own row (@id), else the
# first group header that stands in for the window (a session holding nothing but the sidebar has a header and no row).
cursor_to_window() {  # <window-id>
  local sb port panes n
  sb=$(dash_pane)
  [ -n "$sb" ] || return 0
  port=$(tmux show -pv -t "$sb" @tagents_port 2>/dev/null)
  [ -n "$port" ] || return 0
  panes=$(tmux list-panes -t "$1" -F '#{pane_id}' 2>/dev/null | tr '\n' ' ')
  # Rows first: a group header carries its stand-in's key too, and it is the line with the ▾ in it, so it is used only when no row matched.
  n=$("$SELF" --list 2>/dev/null |
        LC_ALL=C awk -F"$TAB" -v keys="$panes" -v w="$1" '
          BEGIN { nk = split(keys, K, " ") }
          index($2, "\342\226\276") == 0 && !($1 in line) { line[$1] = NR }
          index($2, "\342\226\276") > 0 && !($1 in hline) { hline[$1] = NR }
          END { for (i = 1; i <= nk; i++) if (K[i] in line) { print line[K[i]]; exit }
                if (w in line) print line[w]; else if (w in hline) print hline[w] }')
  [ -n "$n" ] && post_fzf "$port" "pos($n)"
  return 0
}

# --follow in the cockpit: no pane changes window, and the client it is given is no use (the hook's is whichever tmux finds best), so it reads the viewport's client. It keeps @tagents_viewport_shown, takes a viewport whose session was closed to the newest one that still exists, and moves the list's cursor only when the window the viewport shows is not the one it last moved the cursor to.
cockpit_follow() {
  local vtty info sid sess win newest target
  vtty=$(tmux show -gqv @tagents_viewport_tty 2>/dev/null)
  [ -n "$vtty" ] || return 0
  info=$(client_raw '#{session_id} #{session_name} #{window_id}' "$vtty")
  [ -n "$info" ] || return 0
  read -r sid sess win <<<"$info"
  [ "$sess" = tagents ] && return 0
  newest=$(tmux show -gqv @tagents_viewport_shown 2>/dev/null)
  newest=${newest%% *}
  if [ -n "$newest" ] && [ "$newest" != "$sid" ] && ! tmux list-sessions -F '#{session_id}' 2>/dev/null | grep -qxF "$newest"; then
    target=$(viewport_target)
    [ -n "$target" ] && tmux switch-client -c "$vtty" -t "=$target:" 2>/dev/null
    info=$(client_raw '#{session_id} #{session_name} #{window_id}' "$vtty")
    [ -n "$info" ] || return 0
    read -r sid sess win <<<"$info"
    [ "$sess" = tagents ] && return 0
  fi
  viewport_shown_push "$sid"
  if [ "$win" != "$(tmux show -gqv @tagents_viewport_window 2>/dev/null)" ]; then
    tmux set -g @tagents_viewport_window "$win" 2>/dev/null
    cursor_to_window "$win"
  fi
  return 0
}

# The sidebar into the window the client shows now. Does nothing, and says nothing, when there is no client, the sidebar is already there,
# or old seats are still standing. When no list runs but one is wanted (its pane, window or
# session was killed, which no key does), a new one is started in that window: a window or a session killed on screen takes the sidebar with
# it, since it follows the user, and tmux then lands the client elsewhere and fires the hook that got us here. Serialised by a lock, so a storm
# of hooks starts one list and not several, and repeated up to three times while the client's window keeps changing, so the storm settles on
# the window on screen whatever order the hooks finish in.
# TA_FOLLOW_WINDOW is for the tests: a window id used instead of the client's, so a window that closes between the hook and the move can
# be made to happen.
follow() {  # [client]
  local client=${1:-} win sb locked="" i=0
  cockpit_up && { cockpit_follow; return 0; }
  legacy_seats_present && return 0
  follow_lock && locked=1
  while [ "$i" -lt 3 ]; do
    i=$((i + 1))
    win=${TA_FOLLOW_WINDOW:-$(client_window "$client")}
    [ -n "$win" ] || break
    sb=$(dash_pane)
    if [ -n "$sb" ]; then
      [ "$(tmux display -p -t "$sb" '#{window_id}' 2>/dev/null)" = "$win" ] && break
    else
      sidebar_wanted || break
      win_alive "$win" || break
    fi
    if [ -z "$sb" ]; then
      # The new list claims the sidebar itself and runs one follow of its own. A start that fails (no fzf, a pane too small) ends the wish, or
      # every window switch would open another pane that dies: a later ensure-dash, or a list started by hand, wants it again.
      start_sidebar "$win" >/dev/null
      [ "$?" = 1 ] && tmux set -gu @tagents_sidebar_on 2>/dev/null
      break
    fi
    sidebar_move "$win" || break
    cursor_to_window "$win"
    [ -n "${TA_FOLLOW_WINDOW:-}" ] && break
  done
  [ "$locked" = 1 ] && follow_unlock
  return 0
}

# The hook command. `#{hook_client}` is set for client-session-changed, `#{client_name}` for session-window-changed (checked on tmux
# 3.7b, one client); run-shell -b so a switch never waits for bash to start.
follow_hook_cmd() {
  printf '%s' "run-shell -b \"'$SELF' --follow '#{?hook_client,#{hook_client},#{client_name}}'\""
}
install_follow_hooks() {
  local ev cmd
  cmd=$(follow_hook_cmd)
  for ev in $FOLLOW_EVENTS; do
    tmux set-hook -g "$ev[$FOLLOW_HOOK_INDEX]" "$cmd" 2>/dev/null
  done
  return 0
}
