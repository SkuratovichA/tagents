# lib/tagents/rows.sh — what a key does to a row, now that a row is a tmux window
#
# enter selects: the client goes to the row's window, the sidebar follows it there, the cursor lands in the chat. ctrl-s joins a chat's pane into the window on screen beside its chat and remembers where it came from (@tagents_joined, a pane option holding the home session name); ctrl-u breaks it out again. ctrl-x moves the sidebar out of a window before the window closes with the chat. Nothing here moves, resizes, kills or marks a pane that is neither a chat it was asked about nor the sidebar: the other panes of a window belong to the user.
#
# Part of ./tagents; `tagents --help` is the model this implements. Sourced after follow.sh and migrate.sh.

row_session() {  # <pane or window key> -> its session name, empty when the key has no window
  case "${1:-}" in ''|-|%s-*) return 0 ;; esac
  tmux display -p -t "$1" '#{session_name}' 2>/dev/null
}

# The session of the group the key's row sits in: its session when that is a group, else empty — a closed row whose pane is still in a scratch session is listed under `no window`, and a new chat or a resume from it opens as for a chat started with no group.
row_group() {  # <pane or window key>
  local sess
  sess=$(row_session "${1:-}")
  [ -n "$sess" ] && session_is_group "$sess" && printf '%s' "$sess"
  return 0
}

# The window's chat: the first pane, in pane order, that a Claude is running in. A user who split a shell before the chat (`split -b`) still has the chat found; a window with no live chat gets its first pane that is not the sidebar; one with only the sidebar, nothing.
first_chat_pane() {  # <window-id>
  local live p first=""
  live=" $(live_panes 2>/dev/null | tr '\n' ' ') "
  for p in $(tmux list-panes -t "$1" -F '#{pane_id}' 2>/dev/null); do
    list_in_pane "$p" && continue
    [ -n "$first" ] || first=$p
    case "$live" in *" $p "*) printf '%s' "$p"; return 0 ;; esac
  done
  printf '%s' "$first"
}

# tmux's own choice when a window closes: the session's last window, else the previous index, else the next (tmux source; the last-window flag is what `list-windows` reports and was checked on 3.7b, the other two are not). The client is moved there by show_window before the window closes, so what tmux would pick afterwards does not matter.
landing_window() {  # <window-id>
  tmux list-windows -t "$(tmux display -p -t "$1" '#{session_id}' 2>/dev/null)" \
      -F '#{window_id} #{window_index} #{window_last_flag}' 2>/dev/null |
    LC_ALL=C awk -v w="$1" '
      $1 == w { cur = $2 + 0; next }
      { n++; id[n] = $1; ix[n] = $2 + 0; if ($3 == 1) last = $1 }
      END {
        if (last != "") { print last; exit }
        for (i = n; i >= 1; i--) if (ix[i] < cur) { print id[i]; exit }
        for (i = 1; i <= n; i++) if (ix[i] > cur) { print id[i]; exit }
      }'
}

# The client to the window, the sidebar into it, the cursor in <pane>. THE CLIENT GOES FIRST: the sidebar leaving a window it was alone in closes that window, and with it the session when it was the only window — and a client attached to a session that is destroyed under it is detached from the terminal (detach-on-destroy). The move itself starts no follow (see follow.sh).
show_window() {  # <window-id> [pane]
  local win=${1:-} pane=${2:-} sess
  if ! win_alive "$win"; then
    tmux display-message "tagents: that window is gone" 2>/dev/null
    echo "tagents: window $win is gone — nothing moved" >&2
    return 1
  fi
  sess=$(tmux display -p -t "$win" '#{session_name}' 2>/dev/null)
  tmux select-window -t "$win" 2>/dev/null
  [ -n "$sess" ] && tmux switch-client -t "=$sess" 2>/dev/null
  sidebar_move "$win" >/dev/null 2>&1
  [ -n "$pane" ] && tmux select-pane -t "$pane" 2>/dev/null
  cursor_to_window "$win"
  return 0
}

open_agent() {  # <pane or @window key> — enter on a row
  local key=${1:-} win pane=""
  case "$key" in
    -) return 0 ;;
    @*) win=$key ;;
    %*) win=$(tmux display -p -t "$key" '#{window_id}' 2>/dev/null); pane=$key ;;
    *)  return 1 ;;
  esac
  if [ -z "$win" ]; then
    tmux display-message "tagents: that window is gone" 2>/dev/null
    return 1
  fi
  # A popup claims no pane, so there may be no sidebar yet: bring one to the client's window first.
  [ "${TA_MODE:-}" = popup ] && [ -z "$(dash_pane)" ] && ensure_dash >/dev/null 2>&1
  show_window "$win" "$pane"
}
goto() { open_agent "${1:-}"; }   # ctrl-g and --goto: the same selection; only the closed-row notice differs, and act says that

open_session() {  # <key of the header's stand-in> — enter or ctrl-g on a session header: its last-used window
  local sess win
  sess=$(row_session "${1:-}")
  [ -n "$sess" ] || return 1
  win=$(tmux display -p -t "=$sess:" '#{window_id}' 2>/dev/null)   # the session's own selected window; selecting it again changes nothing
  [ -n "$win" ] || return 1
  show_window "$win" ""
}

# ctrl-s: into the window the client shows, to the right of that window's chat. The window on screen is the client's; the sidebar's own window answers only when no client does (a call from a script).
open_beside() {  # <chat pane>
  local pane=${1:-} here win chat home
  [ -n "$pane" ] || return 1
  [ "$pane" = "-" ] && return 0
  win=$(tmux display -p -t "$pane" '#{window_id}' 2>/dev/null)
  if [ -z "$win" ]; then
    tmux display-message "tagents: that window is gone" 2>/dev/null
    return 1
  fi
  here=$(client_window "")
  [ -n "$here" ] || here=$(dash_window)
  [ -n "$here" ] || return 1
  # Already in the window on screen: only focus it.
  if [ "$win" = "$here" ]; then tmux select-pane -t "$pane" 2>/dev/null; return 0; fi
  # The first home is kept when a chat is joined again.
  home=$(tmux show -pv -t "$pane" @tagents_joined 2>/dev/null)
  [ -n "$home" ] || home=$(tmux display -p -t "$pane" '#{session_name}' 2>/dev/null)
  chat=$(first_chat_pane "$here")
  if [ -n "$chat" ]; then
    tmux join-pane -h -d -s "$pane" -t "$chat" 2>/dev/null || return 1
  else   # a window of the sidebar alone: the chat goes to the right of it, full height
    tmux join-pane -h -d -f -s "$pane" -t "$here" 2>/dev/null || return 1
  fi
  tmux set -p -t "$pane" @tagents_joined "$home" 2>/dev/null
  signal_ev
  return 0
}

undock() {  # <chat pane> — ctrl-u: a joined chat gets a window of its own in its home session again
  local pane=${1:-} home cur win
  home=$(tmux show -pv -t "$pane" @tagents_joined 2>/dev/null)
  if [ -z "$home" ]; then
    tmux display-message "tagents: that chat is not joined to another window" 2>/dev/null
    return 0
  fi
  cur=$(tmux display -p -t "$pane" '#{session_name}' 2>/dev/null)
  tmux has-session -t "=$home" 2>/dev/null || home=$cur   # the home session was killed: the session it is in
  win=$(tmux display -p -t "$pane" '#{window_id}' 2>/dev/null)
  if [ "$(tmux list-panes -t "$win" -F x 2>/dev/null | wc -l | tr -d ' ')" = 1 ]; then
    # Already alone in its window: in its home session there is nothing to move, elsewhere the window itself goes home.
    if [ "$home" != "$cur" ]; then tmux move-window -d -s "$win" -t "=$home:" 2>/dev/null || return 1; fi
  else
    tmux break-pane -d -s "$pane" -t "=$home:" 2>/dev/null || return 1
  fi
  tmux set -up -t "$pane" @tagents_joined 2>/dev/null
  signal_ev
  resurrect_soon
  return 0
}

# Before a chat is killed: when the sidebar sits in the chat's window and nothing but the sidebar and the chat would be left, the window is about to close, so the sidebar goes first to the window the client lands on. With a pane of the user's in the window it stays. When the chat is the last window of its session a shell window is made first, so neither the session nor the sidebar goes with it.
leave_window_for_kill() {  # <chat pane>
  local pane=${1:-} win sb others dest sess
  sb=$(dash_pane)
  [ -n "$sb" ] || return 0
  win=$(tmux display -p -t "$pane" '#{window_id}' 2>/dev/null)
  [ "$(tmux display -p -t "$sb" '#{window_id}' 2>/dev/null)" = "$win" ] || return 0
  others=$(tmux list-panes -t "$win" -F '#{pane_id}' 2>/dev/null | LC_ALL=C awk -v a="$pane" -v b="$sb" '$1 != a && $1 != b')
  [ -z "$others" ] || return 0
  dest=$(landing_window "$win")
  if [ -z "$dest" ]; then
    sess=$(tmux display -p -t "$win" '#{session_name}' 2>/dev/null)
    dest=$(tmux new-window -d -t "=$sess:" -P -F '#{window_id}' 2>/dev/null)
  fi
  [ -n "$dest" ] || return 0
  show_window "$dest" ""
}
