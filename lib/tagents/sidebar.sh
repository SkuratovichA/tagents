# lib/tagents/sidebar.sh — which pane is the dashboard right now
#
# The marker discipline, with the essay at 3328-3368 (two real incidents: a stray @tagents_dash sending every dock to a chat pane; several lists fighting over one marker) heading the file. list_in_pane's kill -0 on a stamped pid, dash_pane (own pane first, marker only as fallback, stale markers cleared), dash_window, claim_dash/release_dash (the claim also titles the pane tagents-sidebar and runs one follow), is_agent_pane, await_list, and start_sidebar and ensure_dash — a sidebar in the window the client is in.
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
  local pick
  if [ -n "${TMUX_PANE:-}" ] && list_in_pane "$TMUX_PANE"; then
    printf '%s\n' "$TMUX_PANE"
    return 0
  fi
  pick=$(tmux list-panes -a -F '#{pane_id} #{?@tagents_dash,#{@tagents_dash},-} #{?@tagents_list,#{@tagents_list},-}' 2>/dev/null |
    dash_pane_pick clear)
  [ -z "$pick" ] || printf '%s\n' "${pick%% *}"
  return 0
}
# THE RULE FOR "WHICH MARKED PANE IS THE LIST", in one place for dash_pane and for
# slot(), which reads it off the list-panes output it already has. Lines of
# "pane_id dash list [more...]" on stdin, an unset option written "-"; the first
# pane marked dash=1 whose list pid passes kill -0 is printed as "pane_id more...".
# With "clear", every dead marker met on the way is cleared (tmux set -up), as
# dash_pane always did; slot() leaves them for the callers that clear them.
dash_pane_pick() {  # [clear]
  local p d l rest
  while read -r p d l rest; do
    [ "$d" = 1 ] || continue
    if [ "$l" != - ] && [ -n "$l" ] && kill -0 "$l" 2>/dev/null; then
      printf '%s %s\n' "$p" "$rest"
      return 0
    fi
    [ -z "${1:-}" ] || tmux set -up -t "$p" @tagents_dash 2>/dev/null
  done
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


# A list claims the sidebar itself, a moment after it starts (claim_dash), so
# whoever has just started one waits for the claim instead of assuming it —
# about two seconds, then it gives up with a non-zero status.
await_list() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -n "$(dash_pane)" ] && return 0
    sleep 0.2
  done
  return 1
}


# Where the sidebar is right now: the window of the pane the list runs in, empty when no list runs.
dash_window() {
  local dp
  dp=$(dash_pane)
  [ -n "$dp" ] && tmux display -p -t "$dp" '#{window_id}' 2>/dev/null
  return 0
}

# The list claims the pane it is running in. Nothing else can know as reliably, and any older claim is dropped, so exactly one pane is
# ever the shared sidebar. Two different statements: @tagents_list says "a list with this pid runs in this pane" and belongs to this list
# alone (several lists can coexist, each its own sidebar; the pid tells a live claim from a marker left behind), @tagents_dash is the
# shared "which one do non-list callers mean", and that one is stolen, newest list wins.
claim_dash() {
  local me=${TMUX_PANE:-} old
  [ -n "$me" ] || return 1
  tmux list-panes -a -F '#{pane_id} #{@tagents_dash}' 2>/dev/null |
    LC_ALL=C awk -v me="$me" '$2 == "1" && $1 != me { print $1 }' |
    while IFS= read -r old; do tmux set -up -t "$old" @tagents_dash 2>/dev/null; done
  tmux set -p -t "$me" @tagents_list "$$" \; set -p -t "$me" @tagents_dash 1 \; set -up -t "$me" @tagents_starting 2>/dev/null
  # A sidebar is wanted from now until a ctrl-q: if its pane, window or session is killed, the next follow starts another (follow).
  tmux set -g @tagents_sidebar_on 1 2>/dev/null
  # tmux-resurrect saves the title with the layout; a restore sweeps the idle shells that come back with it (resurrect_sweep).
  tmux select-pane -T tagents-sidebar -t "$me" 2>/dev/null
  # A window switch made while this list was starting ran a follow that found no sidebar: catch up once.
  follow "" >/dev/null 2>&1
  return 0
}

# ...and gives the claim up on the way out, because what runs in this pane next is very often a Claude chat, and that is exactly how a
# chat once came to be mistaken for the list. A pane that is killed outright cannot run this, which is why dash_pane clears stale claims
# rather than trusting them to be gone.
release_dash() {
  local me=${TMUX_PANE:-} st
  [ -n "$me" ] || return 0
  # My own stamp goes unconditionally: a list that has since lost the shared marker to a newer one still has to say it is not running.
  tmux set -up -t "$me" @tagents_list 2>/dev/null
  # The refresher of this list has nothing to tick on, so it is told: it wakes and sees the list process gone.
  signal_ev
  # The bar's text does not outlive the refreshers; whoever sees that none is left takes it down.
  other_refresher || tmux set -gu @tagents_counts 2>/dev/null
  # The shared marker goes only when it is still this pane's (a newer list may hold it). The title is this pane's own: it goes with the list whether
  # or not the marker was lost, or the shell or chat that comes next in the pane is taken for the sidebar by a restore. A title somebody else set stays.
  st=$(tmux display -p -t "$me" '#{@tagents_dash}|#{pane_title}' 2>/dev/null)
  [ "${st%%|*}" = 1 ] && tmux set -up -t "$me" @tagents_dash 2>/dev/null
  [ "${st#*|}" = tagents-sidebar ] && tmux select-pane -T '' -t "$me" 2>/dev/null
  return 0
}

# Is a list on its way? start_sidebar stamps the pane it has just split with the time (@tagents_starting) and the list's claim_dash takes the stamp off; a stamp younger than 20 seconds on a pane that is still there is a list that has not claimed yet.
sidebar_starting() {
  tmux list-panes -a -F '#{@tagents_starting}' 2>/dev/null |
    LC_ALL=C awk -v now="$(date +%s)" '$1 ~ /^[0-9]+$/ && now - $1 < 20 { found = 1 } END { exit !found }'
}

# A list as a new pane, leftmost and as tall as <window>, TA_WIDTH percent wide. Prints its pane id once it has claimed the sidebar (a
# list claims itself a moment after it starts, so the caller waits instead of assuming); 1 when it did not within about two seconds. Under the
# follow lock, and a list that claimed while this waited for it is the answer instead of a second one: a storm of hooks and an ensure-dash
# started together start one list. 2 when the lock could not be had (somebody else is starting or moving the sidebar): a second list for
# the sake of not waiting is worse than none, so nothing is started. Neither is a second one started while the first is still coming up: on a
# loaded machine a list takes longer than await_list waits, and the next start would find no claim yet and split another pane.
start_sidebar() {  # <window-id>
  local win=${1:-} p took="" rc=1
  [ -n "$win" ] || return 1
  follow_lock && took=1
  if [ -z "$took" ] && [ -z "$FOLLOW_LOCKED" ]; then return 2; fi
  p=$(dash_pane)
  if [ -n "$p" ]; then
    printf '%s' "$p"; rc=0
  elif sidebar_starting; then
    if await_list; then printf '%s' "$(dash_pane)"; rc=0; fi
  elif p=$(tmux split-window -d -f -b -h -l "${DASH_WIDTH}%" -P -F '#{pane_id}' -t "$win" "exec '$SELF'" 2>/dev/null) && [ -n "$p" ]; then
    tmux set -p -t "$p" @tagents_starting "$(date +%s)" 2>/dev/null
    [ "$(tmux display -p -t "$win" '#{window_zoomed_flag}' 2>/dev/null)" = 1 ] && tmux resize-pane -Z -t "$win" 2>/dev/null
    if await_list; then printf '%s' "$p"; rc=0; fi
  fi
  [ -n "$took" ] && follow_unlock
  return "$rc"
}

# The sidebar in the window the client is in: a running list is moved there as --follow does, none running starts one there. With no
# client nothing is started or moved and the status is 1.
ensure_dash() {
  local win
  migrate_seats
  win=$(client_window "")
  [ -n "$win" ] || return 1
  [ -n "$(dash_pane)" ] || start_sidebar "$win" >/dev/null || return 1
  sidebar_move "$win" || return 1
  cursor_to_window "$win"
  return 0
}
