# lib/tagents/dock.sh — docking: the pane swapped into a seat, and sent home again
#
# The swap-pane invariant (both windows keep their pane count and layout) with the section banner heading the file: dock/dock_beside in, send_home/break_home out, collapse_seat/collapse_locked closing the freed seat under the mkdir lock (two simultaneous undocks must not leave zero seats), the three teardown entry points a tmux binding calls (undock_pane, undock_window, undock), focus_seat, the pane-border toggle, and the two docking entry points open_agent/open_beside with follow_sidebar.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# THE ROW WAS RENDERED UP TO TWO SECONDS AGO. A claude that exits takes its pane
# with it, and until the next tick the row still says "working" — so every path
# that is about to create a pane or stamp a marker on that row's behalf asks tmux
# whether the pane is still there, which is what ask_kill has always done before
# offering to kill anything.
#
# NOT `grep -q`: this script runs under pipefail and -q closes the pipe on the
# first match, so list-panes dies of SIGPIPE and the pipeline fails on exactly
# the runs that FOUND the pane (see is_agent_pane).
pane_exists() {  # <pane-id>
  local found
  [ -n "${1:-}" ] || return 1
  found=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -x -- "$1")
  [ -n "$found" ]
}

# ---------------------------------------------------------------------------
# docking: the agent's pane is swapped into a seat of the dashboard window.
# swap-pane, not join-pane — a swap leaves both windows with the same number of
# panes and the same layout, so nothing anywhere gets rearranged or destroyed.
# ---------------------------------------------------------------------------

# Sending a chat home is a swap with the placeholder that has been keeping its
# seat warm — docking backwards, so both windows come out with the pane count and
# the layout they started with. Prints the placeholder, which is the seat here
# now.
send_home() {  # <docked chat> -> the placeholder that took its place
  local pane=${1:-} sp
  [ -n "$pane" ] || return 1
  sp=$(parked_slot "$pane")
  { [ -n "$sp" ] && [ "$sp" != "$pane" ]; } || return 1
  tmux swap-pane -d -s "$pane" -t "$sp" 2>/dev/null || return 1
  # Both markers are about a pane being away from its seat, and it no longer is.
  # Leaving them set points the placeholder at a chat that is already home.
  tmux set -up -t "$pane" @tagents_docked 2>/dev/null
  tmux set -up -t "$sp" @tagents_parked 2>/dev/null
  printf '%s' "$sp"
}

# ...and with no placeholder left to swap with, the chat still cannot be left in
# a window it does not belong to. break-pane -d gives it one of its own, out of
# the way and without moving anybody, which is the same repair ensure_seat does.
break_home() {  # <docked chat with nowhere to go back to>
  local pane=${1:-}
  [ -n "$pane" ] || return 1
  tmux set -up -t "$pane" @tagents_docked 2>/dev/null
  tmux break-pane -d -s "$pane" 2>/dev/null
}

# THE SEAT CLOSES BEHIND THE CHAT THAT LEAVES IT, so undocking one of two chats
# gives back columns(list, other) rather than leaving an empty placeholder taking
# up a chat's worth of width. The last seat stays whatever happens: the sidebar
# must always have somewhere to dock into, and that pane is what says "pick an
# agent on the left".
#
# AND ONE SEAT CLOSES AT A TIME. "Is there another seat left?" and the kill that
# follows it are one decision, and two of them taken at once both answer yes:
# focus one placeholder in each of two windows — one gesture per window, and a
# focus hook on each — and both unparks read two seats before either kills. Both
# then kill, and the sidebar is left with NO seat at all, which is the one thing
# the whole design rests on never happening; the refresher repairs it on its
# fifth tick, so it lasts up to ten seconds. Three attempts out of three.
#
# mkdir is the atomic primitive macOS has, there being no flock, and the
# staleness sweep is what stops a process killed between the mkdir and the rmdir
# from wedging every later collapse. Losing the race outright leaves an empty
# seat standing, which is a waste of width; closing one seat too many is a
# sidebar with nothing to dock into.
COLLAPSE_LOCK="$STATE_DIR/.collapse.lock"

# The decision itself, with the lock already held. Every question is asked in
# here and nowhere else: an answer read outside the lock is exactly what the
# loser of the race would be acting on.
collapse_locked() {  # <placeholder> — only ever called by collapse_seat
  local sp=$1 dp win
  [ "$(tmux display -p -t "$sp" '#{@tagents_slot}' 2>/dev/null)" = 1 ] || return 0
  # Parked means it is keeping somebody's seat in another window; that is not a
  # seat of ours to close.
  [ -z "$(tmux display -p -t "$sp" '#{@tagents_parked}' 2>/dev/null)" ] || return 0
  dp=$(dash_pane); [ -n "$dp" ] || return 0
  win=$(tmux display -p -t "$dp" '#{window_id}' 2>/dev/null)
  [ "$(tmux display -p -t "$sp" '#{window_id}' 2>/dev/null)" = "$win" ] || return 0
  [ "$(seats "$dp" | wc -l | tr -d ' ')" -gt 1 ] || return 0
  tmux kill-pane -t "$sp" 2>/dev/null
  return 0
}

# Split in two so the release is one statement on one path, rather than a
# `trap ... RETURN`: in bash 3.2 that trap fires again when the CALLER returns
# (undock_pane, or each turn of undock_window's loop), and the second firing
# would remove a lock some other process had just taken.
collapse_seat() {  # <placeholder now sitting in the sidebar window>
  local sp=${1:-} tries=40
  [ -n "$sp" ] || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null
  while :; do
    mkdir "$COLLAPSE_LOCK" 2>/dev/null && break
    if [ -n "$(find "$COLLAPSE_LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rm -rf "$COLLAPSE_LOCK" 2>/dev/null
      mkdir "$COLLAPSE_LOCK" 2>/dev/null && break
    fi
    tries=$((tries - 1))
    [ "$tries" -gt 0 ] || return 0
    sleep 0.05
  done
  collapse_locked "$sp"
  rm -rf "$COLLAPSE_LOCK" 2>/dev/null
  return 0
}

# ONE PANE, HOME AGAIN. Undocking is per pane now, because the window can hold
# several chats and because a kill-pane binding asks about one pane. Anything
# that is not a docked chat — the list, a placeholder, somebody's terminal — is
# left alone and answered with a non-zero exit, which is what makes it safe to
# put in front of kill-pane in a .tmux.conf.
undock_pane() {  # <pane>
  local pane=${1:-} sp win cur
  is_docked "$pane" || return 1
  # Read while the chat is still in it: this is the sidebar window, and a moment
  # from now the pane will be somewhere else entirely.
  win=$(tmux display -p -t "$pane" '#{window_id}' 2>/dev/null)
  sp=$(send_home "$pane") || { break_home "$pane"; sp=""; }
  [ -n "$sp" ] && collapse_seat "$sp"
  seat_border_win "$win"
  # @tagents_cur is the one docking marker nothing else ever clears, and a marker
  # that outlives the thing it describes is how every earlier bug in here began.
  # The chat has gone home and the placeholder that took its place may have been
  # closed behind it, so if it named either of those it names nothing now. It is
  # left alone when it names some OTHER seat: that one is still where the cursor
  # was, and this window may well hold two more chats.
  if [ -n "$win" ]; then
    cur=$(tmux show -vw -t "$win" @tagents_cur 2>/dev/null)
    if [ -n "$cur" ] && { [ "$cur" = "$pane" ] || [ "$cur" = "$sp" ]; }; then
      tmux set -uw -t "$win" @tagents_cur 2>/dev/null
    fi
  fi
  return 0
}

# For the kill-window binding: closing the sidebar window must never take the
# chats in it with it. Exit 0 either way — a window with nothing docked is not a
# failure, it is the ordinary case.
undock_window() {  # <window-id>
  local win=${1:-} p
  [ -n "$win" ] || return 0
  tmux list-panes -t "$win" -F '#{pane_id} #{?@tagents_docked,docked,-}' 2>/dev/null |
    awk '$2 == "docked" { print $1 }' |
    while IFS= read -r p; do undock_pane "$p"; done
  return 0
}

undock() {  # ctrl-u — returns 1 when there was nothing docked to send home
  local dp seat
  dp=$(dash_pane); [ -n "$dp" ] || return 1
  seat=$(current_seat "$dp")
  # The cursor may well be sitting in the empty placeholder — that is where it is
  # left after an undock — so fall back to whichever chat is docked here.
  if ! is_docked "$seat"; then
    seat=$(seats "$dp" | awk -F"$TAB" '$2 == "docked" { print $1; exit }')
  fi
  [ -n "$seat" ] || return 1
  undock_pane "$seat"
}

# The seat you are put in is the seat you are in, and the next enter uses it.
# The focus hook would stamp @tagents_cur here anyway, a moment later; it is
# written directly as well so that a dock is right the instant it returns,
# whatever the hooks are doing. See current_seat.
focus_seat() {  # <seat pane>
  local pane=${1:-} win
  [ -n "$pane" ] || return 0
  win=$(tmux display -p -t "$pane" '#{window_id}' 2>/dev/null)
  [ -n "$win" ] || return 0
  tmux set -w -t "$win" @tagents_cur "$pane" 2>/dev/null
  tmux select-window -t "$win" 2>/dev/null
  tmux select-pane -t "$pane" 2>/dev/null
  return 0
}

# A TITLE BAR ONLY WHERE THERE IS SOMETHING TO CLOSE. tmux draws a per-pane
# title bar with clickable controls at its right edge when pane-border-status is
# on, and the .tmux.conf format puts "✕ undock" there for a docked chat — the one
# pane a person cannot otherwise close without killing. It is a window option,
# so it is switched on for the sidebar window while any chat is docked in it and
# taken off again when the last one leaves; every other window stays as it was.
seat_border_win() {  # <sidebar window id>
  local win=${1:-} want have
  [ -n "$win" ] || return 0
  if [ -n "$(tmux list-panes -t "$win" -F '#{@tagents_docked}' 2>/dev/null | grep -v '^$')" ]
  then want=top; else want=off; fi
  have=$(tmux show -wv -t "$win" pane-border-status 2>/dev/null)
  if [ "$want" = top ]; then
    [ "$have" = top ] || tmux setw -t "$win" pane-border-status top 2>/dev/null
  else
    [ -z "$have" ] || tmux setw -t "$win" -u pane-border-status 2>/dev/null
  fi
  return 0
}
seat_border() {  # <list pane>
  local dp=${1:-} win
  [ -n "$dp" ] || return 0
  win=$(tmux display -p -t "$dp" '#{window_id}' 2>/dev/null)
  seat_border_win "$win"
}

dock() {  # <pane> — into the current seat, replacing whatever is in it
  local pane=$1 dp win seat sp
  [ "$pane" = "-" ] && return 0
  dp=$(dash_pane)
  [ -z "$dp" ] && return 1
  [ "$pane" = "$dp" ] && return 0
  # Asked before a single marker is written or a single pane created: the swap
  # below is what fails when the chat has died since the row was drawn, and by
  # then a placeholder has been stamped as standing in for a pane that is not
  # there — a seat nothing can ever collapse. See pane_exists.
  pane_exists "$pane" || return 1
  win=$(tmux display -p -t "$dp" '#{window_id}' 2>/dev/null)
  [ -n "$win" ] || return 1
  # Already in a seat here: enter on it means "go to it", not "move it".
  if is_docked_in "$pane" "$win"; then
    focus_seat "$pane"
    return 0
  fi
  seat=$(ensure_seat "$dp") || return 1
  [ -n "$seat" ] || return 1
  sp=$seat
  if is_docked "$seat"; then
    # The seat holds somebody else's chat: send that one home first, which brings
    # ITS placeholder back into this seat, and the placeholder is what the new
    # chat is swapped into. One chat out, one in — exactly what enter always did,
    # except that it happens to the seat you were last in rather than to whatever
    # pane happened to come first in the window.
    sp=$(send_home "$seat") || { break_home "$seat"; sp=$(ensure_seat "$dp"); }
    # Whatever is in the seat now has to be a free placeholder. Anything else
    # means the repair above landed on a second chat, and evicting two chats for
    # one keypress is worse than doing nothing at all.
    { [ -n "$sp" ] && ! is_docked "$sp"; } || return 1
  fi
  # Whose seat the placeholder is about to sit in, recorded BEFORE the swap that
  # puts it there, so focusing it can hand the agent straight back. Before, not
  # after: between the swap and the marker the placeholder is a pane outside the
  # sidebar with nothing to say it is standing in for anybody, which is exactly
  # what slot() treats as stranded and closes.
  tmux set -p -t "$sp" @tagents_parked "$pane" 2>/dev/null
  tmux swap-pane -d -s "$pane" -t "$sp" 2>/dev/null || {
    # The marker says this placeholder is standing in for a chat, and the swap
    # that would have made that true did not happen. Left set, it is a seat
    # collapse_seat refuses for ever — parked means somebody's way home — over a
    # pane that is very likely gone.
    tmux set -up -t "$sp" @tagents_parked 2>/dev/null
    return 1
  }
  tmux set -p -t "$pane" @tagents_docked "$win" 2>/dev/null
  seat_border_win "$win"
  install_focus_hooks
  focus_seat "$pane"
}

# ctrl-s: A SEAT OF ITS OWN, so the chat you are reading stays where it is. This
# is how two chats end up side by side — enter on A, ctrl-s on B — and closing
# either of them afterwards is one undock, not the end of a session. The split
# comes off the current seat rather than off the list, so the list keeps its
# width and the chats share what is left of the window between them.
#
# Unless the current seat is empty, in which case there is nothing to sit beside
# and the empty seat is the seat: splitting regardless left a grey "pick an
# agent" pane a whole chat wide standing between the list and the chat, and
# nothing ever closed it — collapse_seat runs when a chat LEAVES a seat, and no
# chat had left this one. ctrl-s with nothing docked therefore behaves like
# enter, which is the only reading of "beside" there is when the sidebar is
# empty.
dock_beside() {  # <pane>
  local pane=$1 dp win seat sp split=0
  [ "$pane" = "-" ] && return 0
  dp=$(dash_pane)
  [ -z "$dp" ] && return 1
  [ "$pane" = "$dp" ] && return 0
  # Before the split, not after it: a chat that died between the last render and
  # this keypress fails the swap below, and every failure after the split leaks a
  # pane — one marked as a seat, marked as parked for a pane that no longer
  # exists, and so uncollapsible. One leaked pane per keypress, and the sidebar
  # squeezed a little narrower each time. See pane_exists.
  pane_exists "$pane" || return 1
  win=$(tmux display -p -t "$dp" '#{window_id}' 2>/dev/null)
  [ -n "$win" ] || return 1
  # One chat cannot sit in two seats, so ctrl-s on something already here is
  # simply "go to it".
  if is_docked_in "$pane" "$win"; then
    focus_seat "$pane"
    return 0
  fi
  seat=$(ensure_seat "$dp") || return 1
  [ -n "$seat" ] || return 1
  if is_docked "$seat"; then
    sp=$(tmux split-window -h -d -P -F '#{pane_id}' -t "$seat" \
           "exec '$SELF' --slot" 2>/dev/null) || return 1
    tmux set -p -t "$sp" @tagents_slot 1 2>/dev/null
    split=1
  else
    sp=$seat
  fi
  # The parked marker before the swap, for the reason dock() gives: a placeholder
  # that reaches the agent's window before it can say whose seat it is keeping is
  # what slot() reads as stranded and closes.
  tmux set -p -t "$sp" @tagents_parked "$pane" 2>/dev/null
  tmux swap-pane -d -s "$pane" -t "$sp" 2>/dev/null || {
    tmux set -up -t "$sp" @tagents_parked 2>/dev/null
    # Only what this call created. A seat that was already there is somebody
    # else's empty seat and closing it would break the invariant.
    [ "$split" = 1 ] && tmux kill-pane -t "$sp" 2>/dev/null
    return 1
  }
  tmux set -p -t "$pane" @tagents_docked "$win" 2>/dev/null
  seat_border_win "$win"
  install_focus_hooks
  focus_seat "$pane"
}

# ONE PLACE A CHAT IS EVER DOCKED, and this is the way in. Enter used to mean
# something different depending on where the list happened to be running: the
# sidebar docked into its own right half, while the popup docked into the right
# half of whatever window it had been opened over (dock_here, now gone). That
# second behaviour was the bug. The window you open the popup over is nearly
# always the one you are already reading a chat in, so choosing an agent squeezed
# your own chat to 45% and stood a second one next to it — no list in sight,
# since the popup closes the moment it has acted — and choosing an agent that
# already lived in that window wedged a third, blank placeholder pane between the
# two.
#
# What it left behind was worse than the layout. Every dock parks a placeholder
# in the agent's vacated seat, and a placeholder is a real pane running this
# script. Kill the docked chat and that placeholder is stranded: it holds a
# window hostage behind a grey note about a dashboard the agent is not in, and
# slot_pane() — which matches @tagents_slot in any window — later hands it to the
# sidebar as if it were the sidebar's own, flinging the next agent into it.
#
# So there is one docking site, the sidebar, and enter always means the same
# thing: put this chat in the current seat and leave the cursor in it, ready to
# type. From the popup that means coming up the sidebar first and switching to
# it. Nothing is ever docked into a window you were using for something else, so
# no placeholder can ever be created outside the one window that knows how to
# repair itself. (Going to an agent where it lives is still ctrl-g, and borrowing
# its whole window is still ctrl-o — both untouched, neither is what enter does.)
open_agent() {  # <pane> — dock into the current seat and put the cursor in it
  local pane=$1
  [ "$pane" = "-" ] && return 0
  # Bring the dedicated session up only when there is no sidebar at all. A list
  # running in a pane already is one, and starting the other would be a second.
  [ -n "$(dash_pane)" ] || ensure_dash >/dev/null 2>&1 || return 1
  dock "$pane" || return 1
  follow_sidebar
}

# ctrl-s, the same but into a new seat beside the current one.
open_beside() {  # <pane>
  local pane=$1
  [ "$pane" = "-" ] && return 0
  [ -n "$(dash_pane)" ] || ensure_dash >/dev/null 2>&1 || return 1
  dock_beside "$pane" || return 1
  follow_sidebar
}

# dock has already selected the sidebar window and the chat inside it. Switching
# sessions on top of that is right only when the sidebar is in a different one;
# doing it unconditionally WAS the redirect — from the window holding the list to
# the dedicated session, for no reason, every single time.
follow_sidebar() {
  local sess here
  sess=$(tmux display -p -t "$(dash_pane)" '#{session_name}' 2>/dev/null)
  here=$(tmux display-message -p '#{session_name}' 2>/dev/null)
  if [ -n "$sess" ] && [ "$sess" != "$here" ]; then
    tmux switch-client -t "=$sess" 2>/dev/null
  fi
  return 0
}
