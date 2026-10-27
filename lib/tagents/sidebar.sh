# lib/tagents/sidebar.sh — which pane is the dashboard right now
#
# The marker discipline: list_in_pane's kill -0 on a stamped pid, dash_pane (own pane first, marker only as fallback, stale markers cleared), dash_window, claim_dash/release_dash (the claim also titles the pane tagents-sidebar), is_agent_pane, await_list, and ensure_dash, the cockpit for the client that asks.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# Markers, not names: tmux renames windows after whatever command is running, so the pane of the list needs a stable handle.
#
# THE LIST IS WHEREVER IT RUNS. A marker outlives the thing it describes: @tagents_dash once sat on a pane the list had long since left, a Claude chat was started in that pane, and a chat became the dashboard pane. So the pane answers first and the marker is only the fallback, and claim_dash keeps the marker honest for as long as a list is actually running.
# Is a list actually running in this pane? Every list stamps its own pane with
# its pid, so the answer is one kill -0 rather than a walk through ps.
list_in_pane() {  # <pane-id>
  local pid
  pid=$(tmux display -p -t "${1:-}" '#{@tagents_list}' 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# THE LIST IS THE ONE YOU ARE PRESSING THE KEY IN. A marker is only worth the process that set it: a marker whose list is gone (killed pane, killed process) is cleared here rather than ignored, so the next ensure_dash starts from a clean slate. And there can be more than one list, since running `tagents` in any pane is ordinary, and each of them used to claim the single marker. So the caller answers first, a list asking gets its own pane, and the marker is only for callers that are not a list themselves (a popup, which has no pane of its own; a tmux hook; the status bar).
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
# THE RULE FOR "WHICH MARKED PANE IS THE LIST", in one place, for dash_pane. Lines of
# "pane_id dash list [more...]" on stdin, an unset option written "-"; the first
# pane marked dash=1 whose list pid passes kill -0 is printed as "pane_id more...".
# With "clear", every dead marker met on the way is cleared (tmux set -up), as
# dash_pane does; without it they are left for a caller that clears them.
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



# Not `live_panes | grep -q` (see live_set): that inverted every guard built on it, a chat tested as "not an agent" kept the list marker.
is_agent_pane() {  # <pane-id> — is a Claude actually running in it?
  [ -n "${1:-}" ] || return 1
  case "$(live_set)" in *" $1 "*) return 0 ;; esac
  return 1
}


# A list claims its pane a moment after it starts (claim_dash), so whoever has just started one waits for the claim instead of assuming it, about two seconds, then it gives up with a non-zero status.
await_list() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -n "$(dash_pane)" ] && return 0
    sleep 0.2
  done
  return 1
}


# Where the list is right now: the window of the pane the list runs in, empty when no list runs.
dash_window() {
  local dp
  dp=$(dash_pane)
  [ -n "$dp" ] && tmux display -p -t "$dp" '#{window_id}' 2>/dev/null
  return 0
}

# The list claims the pane it is running in. Nothing else can know as reliably, and any older claim is dropped, so exactly one pane is
# ever the shared list. Two different statements: @tagents_list says "a list with this pid runs in this pane" and belongs to this list
# alone (several lists can coexist; the pid tells a live claim from a marker left behind), @tagents_dash is the
# shared "which one do non-list callers mean", and that one is stolen, newest list wins.
claim_dash() {
  local me=${TMUX_PANE:-} old
  [ -n "$me" ] || return 1
  tmux list-panes -a -F '#{pane_id} #{@tagents_dash}' 2>/dev/null |
    LC_ALL=C awk -v me="$me" '$2 == "1" && $1 != me { print $1 }' |
    while IFS= read -r old; do tmux set -up -t "$old" @tagents_dash 2>/dev/null; done
  tmux set -p -t "$me" @tagents_list "$$" \; set -p -t "$me" @tagents_dash 1 2>/dev/null
  # tmux-resurrect saves the title with the layout; a restore sweeps the idle shells that come back with it (resurrect_sweep).
  tmux select-pane -T tagents-sidebar -t "$me" 2>/dev/null
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

# --ensure-dash: the cockpit for the client that asks (cockpit_ensure), after the previous version's seats are sent home.
ensure_dash() {
  migrate_seats
  cockpit_ensure
}
