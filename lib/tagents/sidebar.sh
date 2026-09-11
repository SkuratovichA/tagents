# lib/tagents/sidebar.sh — which pane is the dashboard right now
#
# The marker discipline, with the essay at 3328-3368 (two real incidents: a stray @tagents_dash sending every dock to a chat pane; several lists fighting over one marker) heading the file. list_in_pane's kill -0 on a stamped pid, dash_pane (own pane first, marker only as fallback, stale markers cleared), dash_window vs dash_session_window, claim_dash/release_dash, is_agent_pane, and ensure_dash — get-or-create the session, the window, the list pane, and a seat.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# Markers, not names: tmux renames windows after whatever command is running,
# and the placeholder pane travels between windows, so both need stable handles.
#
# THE SIDEBAR IS WHEREVER THE LIST IS. Both of these used to be answered by a
# marker and nothing else, and a marker outlives the thing it describes.
# ensure_dash can only guess which pane the list is in — the first pane of the
# window — and a guess made once drifts as panes are docked, swapped and killed
# around it. Observed: @tagents_dash sat on a pane the list had long since left,
# a Claude chat was started in that pane, and so a chat became "the dashboard
# pane". Enter then docked beside it, in a window the list was not even in, and
# switched the client there — the list left behind, the screen somewhere else.
# So the pane answers first and the marker is only the fallback, and claim_dash
# keeps the marker honest for as long as a list is actually running.
# Is a list actually running in this pane? Every list stamps its own pane with
# its pid, so the answer is one kill -0 rather than a walk through ps.
list_in_pane() {  # <pane-id>
  local pid
  pid=$(tmux display -p -t "${1:-}" '#{@tagents_list}' 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# THE SIDEBAR IS THE LIST YOU ARE PRESSING THE KEY IN. Two failures here, both
# of them the same mistake — trusting a global marker to say where the sidebar
# is.
#
# A MARKER IS ONLY WORTH THE PROCESS THAT SET IT. A marker whose list is gone —
# killed pane, killed process, or one ensure_dash used to leave on a pane that
# never ran a list at all — does not merely go unused, it actively sends every
# dock somewhere wrong. Observed live: the marker sat on a pane that was later
# given to a claude, so enter docked each chat NEXT TO THAT CHAT and switched the
# client into its window. It is cleared here rather than ignored, so the next
# ensure_dash starts from a clean slate.
#
# AND THERE CAN BE MORE THAN ONE LIST. Running `tagents` in any pane is a
# perfectly ordinary thing to do, and every one of them used to claim the single
# marker, so the newest list silently became "the sidebar" for all of them: enter
# in the one you were looking at docked the chat into some other window and took
# the client with it. Which is the report. So the caller answers first — a list
# asking where to dock gets its own pane — and the marker is only for callers
# that are not a list themselves (a popup, which has no pane of its own; a tmux
# hook; the status bar).
dash_pane() {
  local p pid
  if [ -n "${TMUX_PANE:-}" ] && list_in_pane "$TMUX_PANE"; then
    printf '%s\n' "$TMUX_PANE"
    return 0
  fi
  while read -r p pid; do
    [ -n "$p" ] || continue
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      printf '%s\n' "$p"
      return 0
    fi
    tmux set -up -t "$p" @tagents_dash 2>/dev/null
  done <<EOF
$(tmux list-panes -a -F '#{pane_id} #{@tagents_dash} #{@tagents_list}' 2>/dev/null |
    awk '$2 == "1" { print $1, $3 }')
EOF
  return 0
}
dash_window() {   # the window the list sits in — the sidebar, wherever that is
  local dp
  dp=$(dash_pane)
  if [ -n "$dp" ]; then
    tmux display -p -t "$dp" '#{window_id}' 2>/dev/null
    return 0
  fi
  dash_session_window   # no list running: the window kept for one
}
# TWO DIFFERENT QUESTIONS. "Where is the sidebar right now" is answered by the
# pane the list is in (dash_window, above). "Which window does the dedicated
# session keep for a list" is answered by the marker alone, and ensure_dash needs
# that one: it re-homes a marker that has drifted, so it cannot take the drifted
# pane's own window as the answer it is checking against.
dash_session_window() {
  tmux list-windows -t "=$DASH_SESSION" -F '#{window_id} #{@tagents}' 2>/dev/null |
    awk '$2 == "1" { print $1; exit }'
}

# The list claims the pane it is running in. Nothing else can know as reliably,
# and any older claim is dropped, so exactly one pane and one window are ever the
# sidebar however many lists have come and gone.
claim_dash() {
  local me=${TMUX_PANE:-} win old
  [ -n "$me" ] || return 1
  win=$(tmux display -p -t "$me" '#{window_id}' 2>/dev/null)
  [ -n "$win" ] || return 1
  tmux list-panes -a -F '#{pane_id} #{@tagents_dash}' 2>/dev/null |
    awk -v me="$me" '$2 == "1" && $1 != me { print $1 }' |
    while IFS= read -r old; do tmux set -up -t "$old" @tagents_dash 2>/dev/null; done
  tmux list-windows -a -F '#{window_id} #{@tagents}' 2>/dev/null |
    awk -v w="$win" '$2 == "1" && $1 != w { print $1 }' |
    while IFS= read -r old; do tmux set -uw -t "$old" @tagents 2>/dev/null; done
  # Two different statements. @tagents_list says "a list with this pid is running
  # in this pane" and belongs to this list alone — it is never taken away, which
  # is what lets several lists coexist, each its own sidebar. @tagents_dash is the
  # shared "which one do non-list callers mean", and that one is stolen, newest
  # list wins. The pid is what tells a live claim from a marker left behind,
  # without asking ps about the pane every time.
  tmux set -p -t "$me" @tagents_list "$$" 2>/dev/null
  tmux set -p -t "$me" @tagents_dash 1 2>/dev/null
  tmux set -w -t "$win" @tagents 1 \; set -w -t "$win" automatic-rename off 2>/dev/null
  return 0
}

# ...and gives the claim up on the way out, because what runs in this pane next is
# very often a Claude chat, and that is exactly how a chat came to be mistaken for
# the list. A pane that is killed outright cannot run this, which is why
# claim_dash clears stale claims rather than trusting them to be gone.
release_dash() {
  local me=${TMUX_PANE:-} win sess
  [ -n "$me" ] || return 0
  # My own stamp goes unconditionally: a list that has since lost the shared
  # marker to a newer one still has to say it is not running any more.
  tmux set -up -t "$me" @tagents_list 2>/dev/null
  # And so does the seat this list was last in. Nothing else clears it, and
  # "which seat is current" is a question only a list has any business asking:
  # with the list gone it describes a cursor position in a window that no longer
  # has a sidebar in it.
  win=$(tmux display -p -t "$me" '#{window_id}' 2>/dev/null)
  [ -n "$win" ] && tmux set -uw -t "$win" @tagents_cur 2>/dev/null
  [ "$(tmux display -p -t "$me" '#{@tagents_dash}' 2>/dev/null)" = 1 ] || return 0
  tmux set -up -t "$me" @tagents_dash 2>/dev/null
  sess=$(tmux display -p -t "$me" '#{session_name}' 2>/dev/null)
  # The dedicated session keeps its window marked — ensure_dash runs the list
  # there again. A window anywhere else was only the sidebar while the list was
  # in it, and should not be remembered as one.
  [ "$sess" = "$DASH_SESSION" ] || tmux set -uw -t "$win" @tagents 2>/dev/null
  return 0
}

# NOT `live_panes | grep -q`: this script runs under pipefail, and grep -q closes
# the pipe the moment it matches, so live_panes dies of SIGPIPE and the pipeline
# reports failure on exactly the runs that FOUND something. That inverted every
# guard built on it — a chat tested as "not an agent" and kept the list marker.
is_agent_pane() {  # <pane-id> — is a Claude actually running in it?
  local p list
  [ -n "${1:-}" ] || return 1
  list=$(live_panes 2>/dev/null)
  for p in $list; do
    [ "$p" = "$1" ] && return 0
  done
  return 1
}

ensure_dash() {
  local win="" dp
  if tmux has-session -t "=$DASH_SESSION" 2>/dev/null; then
    win=$(dash_session_window)
    # The session can outlive the dashboard window — a docked or borrowed window
    # keeps it alive on its own — so re-create it rather than assuming it.
    [ -z "$win" ] && win=$(tmux new-window -d -t "$DASH_SESSION:" -n dash -P \
                             -F '#{window_id}' "exec '$SELF'" 2>/dev/null)
  else
    tmux new-session -d -s "$DASH_SESSION" -n dash -x 200 -y 50 "exec '$SELF'" 2>/dev/null || return 1
    win=$(tmux list-windows -t "=$DASH_SESSION" -F '#{window_id}' 2>/dev/null | head -1)
  fi
  [ -z "$win" ] && return 1
  tmux set -w -t "$win" @tagents 1 \; set -w -t "$win" automatic-rename off 2>/dev/null

  # THE DASHBOARD PANE IS THE ONE RUNNING THE LIST, and taking "the first pane in
  # the window" for it is how the marker ended up on a chat: docking swaps an
  # agent INTO this window, where it is frequently the first pane, so a lost
  # marker was handed straight to somebody's Claude session. Everything then
  # docked around that chat and ctrl-n switched the client to a sidebar with no
  # list in it. Re-home the marker instead of trusting it, and never give it to a
  # pane that is running an agent.
  dp=$(dash_pane)
  if [ -n "$dp" ]; then
    if [ "$(tmux display -p -t "$dp" '#{window_id}' 2>/dev/null)" != "$win" ] || is_agent_pane "$dp"; then
      tmux set -up -t "$dp" @tagents_dash 2>/dev/null
      dp=
    fi
  fi
  if [ -z "$dp" ]; then
    # A PANE THAT COULD HOLD THE LIST IS NOT A PANE THAT DOES. This used to adopt
    # any spare pane in the window and mark it as the dashboard without starting
    # anything in it, which is the bug behind "enter shows nothing and throws me
    # into another window": the marker sat on a pane that would never claim or
    # release it, and the moment a claude was started there — which is what a
    # spare pane in this window is usually for — every dock went to that chat
    # instead of to a sidebar, client and all.
    #
    # So a list is grown, never adopted. Typing `exec tagents` into somebody's
    # shell would take the shell with it, and there is no way to tell a pane
    # being kept for the list from a pane being kept for something else. One
    # extra pane is the cheaper mistake. Nothing here marks anything either —
    # only a list that is actually running claims, in claim_dash.
    dp=$(tmux split-window -d -t "$win" -P -F '#{pane_id}' \
           -b -h -l "$DASH_WIDTH%" "exec '$SELF'" 2>/dev/null)
    # The list claims the marker itself, a moment after it starts. Wait for it:
    # the caller's next move is dock(), and dock with no sidebar to dock into
    # does nothing at all — one keypress silently lost.
    if [ -n "$dp" ]; then
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -n "$(dash_pane)" ] && break
        sleep 0.2
      done
    fi
  fi
  [ -n "$dp" ] && ensure_seat "$dp" >/dev/null
  tmux select-window -t "$win" 2>/dev/null
  [ -n "$dp" ] && tmux select-pane -t "$dp" 2>/dev/null
  return 0
}
