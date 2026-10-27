# lib/tagents/rows.sh — what a key does to a row, now that a row is a tmux window
#
# enter selects: the viewport shows the row's window and the cursor lands on its row; ctrl-g takes the terminal itself there. ctrl-s joins a chat's pane into the window on screen beside its chat and remembers where it came from (@tagents_joined, a pane option holding the home session name); ctrl-u breaks it out again. Nothing here moves, resizes, kills or marks a pane that is not a chat it was asked about: the other panes of a window belong to the user.
#
# Part of ./tagents; `tagents --help` is the model this implements. Sourced after follow.sh and migrate.sh.

row_session() {  # <pane or window key> -> its session name, empty when the key has no window
  case "${1:-}" in ''|-|%s-*) return 0 ;; esac
  tmux display -p -t "$1" '#{session_name}' 2>/dev/null
}

# The window's chat: the first pane, in pane order, that a Claude is running in. A user who split a shell before the chat (`split -b`) still has the chat found; a window with no live chat gets its first pane that is not a list; one with only a list, nothing.
first_chat_pane() {  # <window-id>
  local live p first=""
  live=$(live_set)
  for p in $(tmux list-panes -t "$1" -F '#{pane_id}' 2>/dev/null); do
    list_in_pane "$p" && continue
    [ -n "$first" ] || first=$p
    case "$live" in *" $p "*) printf '%s' "$p"; return 0 ;; esac
  done
  printf '%s' "$first"
}

# The window shown: in the cockpit the viewport shows it (cockpit_select); with no dashboard up (a popup whose cockpit could not start, a --goto from a notification) the terminal itself goes there.
show_window() {  # <window-id> [pane]
  local win=${1:-} pane=${2:-} sess
  if ! win_alive "$win"; then
    notice "tagents: that window is gone"
    echo "tagents: window $win is gone — nothing moved" >&2
    return 1
  fi
  if cockpit_up; then cockpit_select "$win" "$pane"; return $?; fi
  sess=$(tmux display -p -t "$win" '#{session_name}' 2>/dev/null)
  tmux select-window -t "$win" 2>/dev/null
  [ -n "$sess" ] && tmux switch-client -t "=$sess" 2>/dev/null
  [ -n "$pane" ] && tmux select-pane -t "$pane" 2>/dev/null
  return 0
}

open_agent() {  # <pane or @window key> [goto] — enter on a row; ctrl-g with goto
  local key=${1:-} win pane=""
  case "$key" in
    -) return 0 ;;
    @*) win=$key ;;
    %*) win=$(tmux display -p -t "$key" '#{window_id}' 2>/dev/null); pane=$key ;;
    *)  return 1 ;;
  esac
  if [ -z "$win" ]; then
    notice "tagents: that window is gone"
    return 1
  fi
  if [ "${2:-}" = goto ]; then goto_window "$win" "$pane"; return $?; fi
  # A popup has no viewport of its own: with no dashboard up, the cockpit comes up first and shows the chat.
  [ "${TA_MODE:-}" = popup ] && ! cockpit_up && ensure_dash >/dev/null 2>&1
  show_window "$win" "$pane"
}
goto() { open_agent "${1:-}"; }   # --goto, a notification's click: the selection enter makes, so the chat shows in the viewport and the dashboard stays on screen

open_session() {  # <key of the header's stand-in> [goto] — enter on a session header, or ctrl-g with goto: its last-used window
  local sess win
  sess=$(row_session "${1:-}")
  [ -n "$sess" ] || return 1
  win=$(tmux display -p -t "=$sess:" '#{window_id}' 2>/dev/null)   # the session's own selected window; selecting it again changes nothing
  [ -n "$win" ] || return 1
  if [ "${2:-}" = goto ]; then goto_window "$win" ""; else show_window "$win" ""; fi
}

# ctrl-s: into the window the client shows, to the right of that window's chat. The window on screen is the client's; the list's own window answers only when no client does (a call from a script).
open_beside() {  # <chat pane>
  local pane=${1:-} here win chat home
  [ -n "$pane" ] || return 1
  [ "$pane" = "-" ] && return 0
  win=$(tmux display -p -t "$pane" '#{window_id}' 2>/dev/null)
  if [ -z "$win" ]; then
    notice "tagents: that window is gone"
    return 1
  fi
  here=$(client_window "")
  [ -n "$here" ] || here=$(dash_window)
  [ -n "$here" ] || return 1
  if [ "$(tmux display -p -t "$here" '#{@tagents_cockpit}' 2>/dev/null)" = 1 ]; then
    notice "tagents: no window to put it beside"
    return 1
  fi
  # Already in the window on screen: only focus it.
  if [ "$win" = "$here" ]; then tmux select-pane -t "$pane" 2>/dev/null; return 0; fi
  # A chat alone in the only window of its session cannot be joined: tmux closes a session when its last window empties, and the session with it.
  if [ "$(tmux display -p -t "$pane" '#{window_panes} #{session_windows}' 2>/dev/null)" = "1 1" ]; then
    notice "tagents: that chat is alone in its session — joining it would close the session"
    return 0
  fi
  # The first home is kept when a chat is joined again.
  home=$(tmux show -pv -t "$pane" @tagents_joined 2>/dev/null)
  [ -n "$home" ] || home=$(tmux display -p -t "$pane" '#{session_name}' 2>/dev/null)
  chat=$(first_chat_pane "$here")
  if [ -n "$chat" ]; then
    tmux join-pane -h -d -s "$pane" -t "$chat" 2>/dev/null || return 1
  else   # a window with no chat in it (a shell, or a list alone): the chat goes to the right of the window, full height
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
    notice "tagents: that chat is not joined to another window"
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

