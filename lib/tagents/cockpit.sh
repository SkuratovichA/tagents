# lib/tagents/cockpit.sh — the cockpit layout: the dashboard as a session of its own, with the viewport beside the list
#
# With dashboard.layout: cockpit the sidebar does not travel. The list lives in the session `tagents` (marked @tagents_cockpit), and beside it the viewport, `tagents --viewport`, runs a second client of the same tmux server in a pane and shows whichever session is selected. cockpit_up asks the server whether that session is up, and everything but a start goes by that answer (the config is read only when a list or --ensure-dash starts). This file holds the session's start and reuse (cockpit_ensure), the viewport verb and its loop, and the lookups both need; the design is in openspec/changes/cockpit/design.md.
#
# Part of ./tagents; `tagents --help` is the model this implements. Sourced before dash.

# The exact-match target needs its colon: `=tagents` alone is not an exact session match for every command (LEARNING.md, 22.10.2026).
cockpit_up() { [ "$(tmux show -qv -t '=tagents:' @tagents_cockpit 2>/dev/null)" = 1 ]; }

# Is this pane in the cockpit's session? True for the dashboard's own panes, false for every other pane.
pane_in_cockpit() {  # <pane-id>
  [ -n "${1:-}" ] && [ "$(tmux display -p -t "$1" '#{@tagents_cockpit}' 2>/dev/null)" = 1 ]
}

# The one reader of dashboard.layout: only a start asks. Anything but `cockpit` is the follow layout.
cockpit_layout() { [ "$(cfg_get dashboard.layout 2>/dev/null)" = cockpit ]; }

# The guard that keeps the viewport's client off `tagents`: a global client-session-changed hook that runs inside the server, with no shell between the switch and the step. `if -F` does not format-expand its action and `run-shell -C` does, so the command is expanded where it runs. LS is the hook client's own last session (a bare #{client_last_session} in a hook names another client's as soon as a second one is attached). The direction of the step off `tagents` follows the table in the design: the session left sorts before `tagents` and none sorts between, or it sorts after and some sort between, steps -n; the other two step -p; no last session (it was closed) steps -n; with `tagents` the only session the viewport's client is detached and marked idle for the loop.
GUARD_HOOK_INDEX=44
cockpit_guard_cmd() {
  local ls cond before after dir
  ls='#{L:#{?#{==:#{client_name},#{hook_client}},#{client_last_session},}}'
  cond='#{&&:#{==:#{hook_client},#{@tagents_viewport_tty}},#{@tagents_cockpit}}'
  before="#{?#{S:#{?#{&&:#{>:#{session_name},$ls},#{<:#{session_name},tagents}},1,}},p,n}"
  after="#{?#{S:#{?#{&&:#{>:#{session_name},tagents},#{<:#{session_name},$ls}},1,}},n,p}"
  dir="#{?$ls,#{?#{<:$ls,tagents},$before,$after},n}"
  printf '%s' "if -F \"$cond\" \"run-shell -C \\\"#{?#{==:#{server_sessions},1},set -g @tagents_viewport_idle 1 ; detach-client -t #{hook_client},switch-client -c #{hook_client} -$dir}\\\"\""
}
cockpit_guard_install() {
  tmux set-hook -g "client-session-changed[$GUARD_HOOK_INDEX]" "$(cockpit_guard_cmd)" 2>/dev/null
}

# Does a start act in the cockpit: it is up already, or the config asks for it.
cockpit_want() { cockpit_up || cockpit_layout; }

# A value of what a client shows, like client_attr (follow.sh) but never answering with the viewport's own client when none is named: its tty is nobody's terminal. This is the lookup that never substitutes, for the questions that need the real terminal.
client_raw() {  # <format> [client name]
  local vtty
  vtty=$(tmux show -gqv @tagents_viewport_tty 2>/dev/null)
  tmux list-clients -F "#{client_activity} #{client_name} $1" 2>/dev/null |
    LC_ALL=C awk -v c="${2:-}" -v v="$vtty" '
      { x = $0; sub(/^[^ ]+ [^ ]+ /, "", x) }
      c != "" { if ($2 == c) { print x; exit } next }
      v != "" && $2 == v { next }
      $1 + 0 >= m { m = $1 + 0; best = x }
      END { if (c == "" && best != "") print best }'
}

# The terminal attached to the dashboard that was used last: what `prefix d` in the viewport has to detach.
dash_terminal() {
  local vtty
  vtty=$(tmux show -gqv @tagents_viewport_tty 2>/dev/null)
  tmux list-clients -F '#{client_activity} #{client_name} #{session_name}' 2>/dev/null |
    LC_ALL=C awk -v v="$vtty" '$3 == "tagents" && $2 != v && $1 + 0 >= m { m = $1 + 0; best = $2 } END { if (best != "") print best }'
}

# @tagents_viewport_shown: the ids of the last 16 distinct sessions the viewport showed, newest first. Ids, not names, so that a renamed session does not read as a closed one.
viewport_shown_push() {  # <session id>
  local id=${1:-} cur kept="" n=1 s
  [ -n "$id" ] || return 0
  cur=$(tmux show -gqv @tagents_viewport_shown 2>/dev/null)
  for s in $cur; do
    [ "$s" = "$id" ] && continue
    [ "$n" -ge 16 ] && break
    kept="$kept $s"; n=$((n + 1))
  done
  tmux set -g @tagents_viewport_shown "$id$kept" 2>/dev/null
}

# What the viewport attaches to: the newest live entry of @tagents_viewport_shown, else the other session used last. The dashboard's own session is never a target. Prints the session's name, nothing when there is none.
viewport_target() {
  local rows id name line
  rows=$(tmux list-sessions -F "#{session_id}${TAB}#{session_last_attached}${TAB}#{?#{@tagents_cockpit},1,0}${TAB}#{session_name}" 2>/dev/null)
  for id in $(tmux show -gqv @tagents_viewport_shown 2>/dev/null); do
    name=$(printf '%s\n' "$rows" | LC_ALL=C awk -F"$TAB" -v id="$id" '$1 == id && $3 == 0 { print $4; exit }')
    if [ -n "$name" ]; then printf '%s' "$name"; return 0; fi
  done
  line=$(printf '%s\n' "$rows" | LC_ALL=C awk -F"$TAB" '$3 == 0 { print $2 "\t" $4 }' | LC_ALL=C sort -t"$TAB" -k1,1nr)
  line=${line%%$'\n'*}
  printf '%s' "${line#*$TAB}"
}

# Nothing to show: wait on the refresher's ring (a session is made, a pane dies), and look at the sessions once every half second as well, because a server whose refresher is not running rings nobody. Ends when there is a session to show or the quit cleared the tty.
viewport_wait() {  # <tty>
  local seen w
  seen=$(tmux show -gqv @tagents_evgen 2>/dev/null)
  ring_wait "${seen:-0}" &
  w=$!
  while kill -0 "$w" 2>/dev/null; do
    [ -n "$(viewport_target)" ] && break
    [ "$(tmux show -gqv @tagents_viewport_tty 2>/dev/null)" = "$1" ] || break
    sleep 0.5
  done
  kill "$w" 2>/dev/null
  wait "$w" 2>/dev/null
  return 0
}

# tagents --viewport: the right pane of the dashboard. It marks its own pane (title, @tagents_viewport, allow-set-title off) and then keeps a client of this same server attached: TMUX unset and the socket by path, which tmux allows, makes it one more client of the one server. The loop is bash with the attach as its child, so the pane keeps one tty for its whole life and @tagents_viewport_tty stays true across attaches.
viewport() {
  local pane=${TMUX_PANE:-} sock tty target idle term watcher=
  if [ -z "$pane" ] || [ "$(tmux display -p -t "$pane" '#{?#{&&:#{==:#{@tagents_cockpit},1},#{==:#{pane_at_left},0}},1,0}' 2>/dev/null)" != 1 ]; then
    echo "tagents: --viewport runs only in the cockpit's viewport pane" >&2
    return 1
  fi
  tmux set -p -t "$pane" allow-set-title off \; select-pane -T tagents-viewport -t "$pane" \; set -p -t "$pane" @tagents_viewport 1 2>/dev/null
  tty=$(tty)
  sock=${TMUX%%,*}
  tmux set -g @tagents_viewport_tty "$tty"
  cockpit_list_watch "$tty" &
  watcher=$!
  trap 'cockpit_watch_stop "$watcher"' EXIT
  while :; do
    [ "$(tmux show -gqv @tagents_viewport_tty 2>/dev/null)" = "$tty" ] || break   # ctrl-q cleared it
    target=$(viewport_target)
    if [ -z "$target" ]; then
      echo "tagents: no session to show"
      viewport_wait "$tty"
      continue
    fi
    env -u TMUX tmux -S "$sock" attach -f no-detach-on-destroy -t "=$target:" || sleep 1
    [ "$(tmux show -gqv @tagents_viewport_tty 2>/dev/null)" = "$tty" ] || break
    idle=$(tmux show -gqv @tagents_viewport_idle 2>/dev/null)
    tmux set -gu @tagents_viewport_idle 2>/dev/null
    # The guard sets the mark when it detached the client because `tagents` was the only session; with neither mark the client ended by itself, which is prefix d.
    if [ -z "$idle" ]; then term=$(dash_terminal); [ -z "$term" ] || tmux detach-client -t "$term" 2>/dev/null; fi
  done
  cockpit_watch_stop "$watcher"; watcher=
  return 0
}

# The pane of the dashboard's window on the left (the list) or the right (the viewport).
cockpit_pane() {  # left|right
  local want=1
  [ "$1" = right ] && want=0
  tmux list-panes -t '=tagents:' -F "#{pane_at_left} #{pane_id}" 2>/dev/null |
    LC_ALL=C awk -v w="$want" '$1 == w { print $2; exit }'
}

# Make the session `tagents` forward the user's prefix to the viewport: the table `tagents-cockpit` binds each prefix key to make the viewport the active pane and send it the key, and holds the root table's mouse bindings that open no menu; the session options that select it are set last, so no key reaches a half-built table. Called again with the new viewport pane whenever a viewport is started again.
cockpit_keys_install() {
  local vp k tmp
  vp=$(cockpit_pane right)
  [ -n "$vp" ] || return 1
  tmux unbind-key -a -T tagents-cockpit 2>/dev/null
  for k in $(tmux show -gqv prefix 2>/dev/null) $(tmux show -gqv prefix2 2>/dev/null); do
    case $k in ''|None) continue ;; esac
    tmux bind-key -T tagents-cockpit "$k" select-pane -t "$vp" '\;' send-keys -t "$vp" "$k" 2>/dev/null
  done
  tmp=$(mktemp "${TMPDIR:-/tmp}/tagents-keys.XXXXXX") || return 1
  tmux list-keys -T root 2>/dev/null | LC_ALL=C awk '
    function flush() { if (blk != "" && key ~ /Mouse|Wheel|Click/ && blk !~ /display-menu/) printf "%s", blk; blk = "" }
    /^bind-key/ { flush(); key = $0; sub(/^.* -T root +/, "", key); sub(/ .*$/, "", key) }
    { blk = blk $0 "\n" }
    END { flush() }' |
    sed 's/ -T root / -T tagents-cockpit /' >"$tmp"
  [ ! -s "$tmp" ] || tmux source-file "$tmp" 2>/dev/null
  rm -f "$tmp"
  tmux set -t '=tagents:' prefix None \; set -t '=tagents:' prefix2 None \; set -t '=tagents:' key-table tagents-cockpit 2>/dev/null
}

# Wait for the viewport pane to have attached its client: the tty it stored is its own pane's and a client of that name is listed.
cockpit_await_viewport() {
  local i=0 vp ptty vtty
  while [ "$i" -lt 100 ]; do
    vp=$(cockpit_pane right)
    if [ -n "$vp" ]; then
      ptty=$(tmux display -p -t "$vp" '#{pane_tty}' 2>/dev/null)
      vtty=$(tmux show -gqv @tagents_viewport_tty 2>/dev/null)
      [ -n "$vtty" ] && [ "$vtty" = "$ptty" ] && tmux list-clients -F '#{client_name}' 2>/dev/null | grep -qxF "$vtty" && return 0
    fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# Start whichever half of the dashboard is gone, when the window holds one pane and that pane is the other half; a pane that is not marked yet is a dashboard still starting and is left alone. With an argument only that half is started: `list` for the viewport's loop, `viewport` for the refresher.
cockpit_restart_half() {  # [list|viewport]
  local n p
  n=$(tmux list-panes -t '=tagents:' -F x 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = 1 ] || return 0
  p=$(tmux list-panes -t '=tagents:' -F '#{pane_id}' 2>/dev/null)
  if [ "$(tmux display -p -t "$p" '#{@tagents_viewport}' 2>/dev/null)" = 1 ]; then
    [ -z "${1:-}" ] || [ "$1" = list ] || return 0
    tmux split-window -d -b -h -l "${DASH_WIDTH}%" -c "$HOME" -t "$p" "exec '$SELF'" 2>/dev/null
    await_list
  elif list_in_pane "$p"; then
    [ -z "${1:-}" ] || [ "$1" = viewport ] || return 0
    tmux split-window -d -h -l "$((100 - DASH_WIDTH))%" -c "$HOME" -t "$p" "exec '$SELF' --viewport" 2>/dev/null && cockpit_keys_install
  fi
  return 0
}

# The restorers of a killed half (the refresher starts the viewport, the viewport's loop starts the list). Nothing while @tagents_viewport_tty is unset: it is unset before the first viewport has started and from the first step of a quit on, so a quit is never undone.
cockpit_restore() {  # <list|viewport>
  [ -n "$(tmux show -gqv @tagents_viewport_tty 2>/dev/null)" ] || return 0
  cockpit_up || return 0
  cockpit_restart_half "$1"
}

# The viewport loop's second waiter, in the background: on each ring of the refresher's channel it starts a missing list again. It reads the generation before it acts, so a ring that comes while it acts is not slept through. It ends when the loop does (cockpit_watch_stop), taking the tmux client it waits with.
cockpit_list_watch() {  # <tty>
  local seen c=""
  trap '[ -z "$c" ] || { pkill -P "$c" 2>/dev/null; kill "$c" 2>/dev/null; }; exit 0' TERM
  while [ "$(tmux show -gqv @tagents_viewport_tty 2>/dev/null)" = "$1" ]; do
    seen=$(tmux show -gqv @tagents_evgen 2>/dev/null)
    cockpit_restore list
    ring_wait "${seen:-0}" &
    c=$!
    wait "$c"
    c=""
  done
}
cockpit_watch_stop() {  # <pid>
  [ -z "${1:-}" ] || { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
  return 0
}

# ctrl-q in the cockpit's list, in the order of the design: the session is killed last because this runs in a pane that goes with it. The window the viewport shows is read first; the tty and the sidebar wish go in one call, so the guard, notice, the viewport's loop and both restorers stop matching; every other terminal on `tagents` is moved to that window, or detached when there is none; then the hook, the table and the other viewport options go.
cockpit_quit() {
  local vtty win c
  vtty=$(tmux show -gqv @tagents_viewport_tty 2>/dev/null)
  [ -z "$vtty" ] || win=$(client_raw '#{window_id}' "$vtty")
  tmux set -gu @tagents_sidebar_on \; set -gu @tagents_viewport_tty 2>/dev/null
  release_dash
  for c in $(tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null | LC_ALL=C awk -v v="$vtty" '$2 == "tagents" && $1 != v { print $1 }'); do
    if [ -n "${win:-}" ]; then tmux switch-client -c "$c" -t "$win" 2>/dev/null; else tmux detach-client -t "$c" 2>/dev/null; fi
  done
  tmux set-hook -gu "client-session-changed[$GUARD_HOOK_INDEX]" \; unbind-key -a -T tagents-cockpit \; \
       set -gu @tagents_viewport_shown \; set -gu @tagents_viewport_window \; set -gu @tagents_viewport_idle 2>/dev/null
  tmux kill-session -t '=tagents:' 2>/dev/null
  return 0
}

# A list started in a pane of its own (a shell's `tagents`) acts for the client that shows that pane's window, else for the one used last.
cockpit_client_of_pane() {  # <pane-id>
  local win vtty c
  win=$(tmux display -p -t "${1:-}" '#{window_id}' 2>/dev/null)
  vtty=$(tmux show -gqv @tagents_viewport_tty 2>/dev/null)
  c=$(tmux list-clients -F '#{client_activity} #{client_name} #{window_id}' 2>/dev/null |
        LC_ALL=C awk -v w="$win" -v v="$vtty" '$3 == w && $2 != v && $1 + 0 >= m { m = $1 + 0; best = $2 } END { if (best != "") print best }')
  [ -n "$c" ] || c=$(client_raw '#{client_name}')
  printf '%s' "$c"
}

# --ensure-dash in the cockpit: make the dashboard when it is not up, start again a half that is gone, point the viewport at the window the client was in and take that client to the dashboard. A client on the dashboard or the viewport's own switches nothing and the list becomes the active pane. 1 with no client, and 1 on a taken name.
cockpit_ensure() {  # [client name]
  local client=${1:-} info w h win sid sess vtty lp lw vw on_dash=""
  if ! cockpit_up && tmux has-session -t '=tagents:' 2>/dev/null; then
    echo "tagents: session tagents is taken — rename it or set dashboard.layout: follow" >&2
    return 1
  fi
  [ -n "$client" ] || client=$(client_raw '#{client_name}')
  [ -n "$client" ] || return 1
  info=$(client_raw '#{client_width} #{client_height} #{window_id} #{session_id} #{session_name}' "$client")
  [ -n "$info" ] || return 1
  read -r w h win sid sess <<<"$info"
  vtty=$(tmux show -gqv @tagents_viewport_tty 2>/dev/null)
  if [ "$sess" = tagents ] || [ "$client" = "$vtty" ]; then on_dash=1; fi
  if ! cockpit_up; then
    case $w in ''|*[!0-9]*|0) w=200 ;; esac
    case $h in ''|*[!0-9]*|0) h=50 ;; esac
    lw=$((w * DASH_WIDTH / 100)); vw=$((w - lw - 1))
    tmux set -gu @tagents_viewport_tty 2>/dev/null
    [ -n "$on_dash" ] || viewport_shown_push "$sid"
    # -x/-y: a detached session is 80x24 until a client attaches, and the list's width is a share of the window (LEARNING.md, 12.09.2026).
    tmux new-session -d -s tagents -x "$w" -y "$h" -n dashboard -c "$HOME" "exec '$SELF'" \; \
         set -t '=tagents:' @tagents_cockpit 1 \; set -t '=tagents:' status off \; set -t '=tagents:' detach-on-destroy off \; \
         set -gu @tagents_sidebar_on 2>/dev/null || return 1
    cockpit_guard_install
    tmux split-window -d -h -l "$vw" -c "$HOME" -t '=tagents:' "exec '$SELF' --viewport" 2>/dev/null || return 1
    cockpit_keys_install
    await_list >/dev/null
  else
    tmux set -gu @tagents_sidebar_on 2>/dev/null
    cockpit_guard_install
    cockpit_restart_half
  fi
  cockpit_await_viewport || true
  vtty=$(tmux show -gqv @tagents_viewport_tty 2>/dev/null)
  if [ -z "$on_dash" ] && [ -n "$vtty" ]; then
    tmux switch-client -c "$vtty" -t "=$sess:$win" 2>/dev/null
    tmux switch-client -c "$client" -t '=tagents:' 2>/dev/null
  fi
  lp=$(cockpit_pane left)
  [ -n "$lp" ] && tmux select-pane -t "$lp" 2>/dev/null
  return 0
}

# show_window in the cockpit: the viewport's client to the window (which also selects it in its session), the viewport the dashboard's active pane, the cursor on the row, and the terminal that acts switched to `tagents` only when it is on neither the dashboard nor the viewport. No pane changes window.
cockpit_select() {  # <window-id> [pane]
  local win=${1:-} pane=${2:-} sess vtty vp client
  sess=$(tmux display -p -t "$win" '#{session_name}' 2>/dev/null)
  vtty=$(tmux show -gqv @tagents_viewport_tty 2>/dev/null)
  if [ -z "$sess" ] || [ -z "$vtty" ]; then
    notice "tagents: the viewport is not running"
    echo "tagents: the viewport is not running — nothing moved" >&2
    return 1
  fi
  client=$(client_raw '#{client_name}')
  vp=$(cockpit_pane right)
  tmux switch-client -c "$vtty" -t "=$sess:$win" 2>/dev/null
  [ -n "$vp" ] && tmux select-pane -t "$vp" 2>/dev/null
  [ -n "$pane" ] && tmux select-pane -t "$pane" 2>/dev/null
  cursor_to_window "$win"
  if [ -n "$client" ] && [ "$(client_raw '#{?#{@tagents_cockpit},1,0}' "$client")" != 1 ]; then
    tmux switch-client -c "$client" -t '=tagents:' 2>/dev/null
  fi
  return 0
}
