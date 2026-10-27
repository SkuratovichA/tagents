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

# The list cursor onto the row of a window: the row of the first of its panes that has one (a chat), else the window's own row (@id), else the
# first group header that stands in for the window (a session that holds no chat has a header and no row).
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

# --follow: the client it is given is no use (the hook's is whichever tmux finds best), so it reads the viewport's client. It keeps @tagents_viewport_shown, takes a viewport whose session was closed to the newest one that still exists, and moves the list's cursor only when the window the viewport shows is not the one it last moved the cursor to. Nothing without the cockpit.
follow() {  # [client, ignored]
  local vtty info sid sess win newest target
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
  if [ "$win" != "$(tmux show -gqv @tagents_viewport_window 2>/dev/null)" ]; then
    tmux set -g @tagents_viewport_window "$win" 2>/dev/null
    cursor_to_window "$win"
  fi
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
