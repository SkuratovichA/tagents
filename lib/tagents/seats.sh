# lib/tagents/seats.sh — seats: what they are and which one is current
#
# A seat is a marked pane of the sidebar window, never a position — the essay at 3494-3508 says why. seats/seat_here/is_docked/is_docked_in, current_seat's priority chain (@tagents_cur, then active/last, then a free placeholder, then leftmost), the placeholder machinery (parked_slot, slot_pane, list_windows, slot's own loop), unpark (focusing a placeholder IS the request to bring its chat back), and ensure_seat's repair — one seat must exist, not one particular pane.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# Which placeholder is holding a given chat's seat. There can be more than one
# placeholder about — the list can move to another window, leaving the one it used
# before still standing in for a chat that is docked — so "the" placeholder is not
# good enough when the question is "where does THIS chat go home to".
parked_slot() {  # <pane-id> -> the placeholder standing in for it
  tmux list-panes -a -F '#{pane_id} #{@tagents_slot} #{@tagents_parked}' 2>/dev/null |
    awk -v a="$1" '$2 == "1" && $3 == a { print $1; exit }'
}
# The windows a list is running in right now — the windows that have seats of
# their own. The pid in @tagents_list is what tells a live claim from one left
# behind by a list that is gone, the same test dash_pane makes.
list_windows() {
  local p w pid
  tmux list-panes -a -F '#{pane_id} #{window_id} #{@tagents_list}' 2>/dev/null |
    while read -r p w pid; do
      [ -n "${pid:-}" ] || continue
      kill -0 "$pid" 2>/dev/null && printf '%s\n' "$w"
    done
}

# A SPARE PLACEHOLDER, AND NEVER SOMEBODY ELSE'S SEAT. This is the pane
# ensure_seat joins into a sidebar that has lost its own — or kills outright when
# join-pane declines — so it may not be a placeholder another list is sitting on.
# Running a second list is a perfectly ordinary thing to do, and now that a
# sidebar keeps its empty seat rather than closing it, a free placeholder there
# is the normal state of affairs: taking it left that sidebar with no seat at all
# until its own refresher noticed, up to ten seconds later. Spare means a
# placeholder in a window no live list is in, which is exactly the stranded one
# this exists to reclaim.
slot_pane() {
  local ex
  ex=" $(list_windows | tr '\n' ' ')"
  tmux list-panes -a -F '#{pane_id} #{@tagents_slot} #{window_id}' 2>/dev/null |
    awk -v ex="$ex" '$2 == "1" && index(ex, " " $3 " ") == 0 { print $1; exit }'
}
# WHAT IS DOCKED IS ANSWERED BY MARKERS, NEVER BY POSITION. This used to be
# "the first pane in the sidebar window that is not the list", which is only true
# while that window has exactly two panes. Split a terminal in there because
# there is room for one and the terminal became the answer: undock swapped it
# into somebody else's window, and enter broke it out into a window of its own
# before docking into a third column beside it. So a pane belongs to this
# dashboard only when it says so itself — @tagents_docked (a chat, naming the
# sidebar window it is docked into) or @tagents_slot (a placeholder). Those two
# are the SEATS; everything else in the window is a pane somebody opened for
# their own reasons and is never swapped, split, broken out or killed here.
#
# In pane-index order, so "the first seat" means the leftmost, and never the list
# itself. The conditional formats are what keep the three fields non-empty: an
# unset user option renders as nothing, and awk then shifts every later field one
# place to the left.
seats() {  # <list pane> -> pane_id<TAB>docked|free for each seat in its window
  local dp=${1:-} win
  [ -n "$dp" ] || return 0
  win=$(tmux display -p -t "$dp" '#{window_id}' 2>/dev/null)
  [ -n "$win" ] || return 0
  tmux list-panes -t "$win" \
       -F '#{pane_id} #{?@tagents_docked,docked,-} #{?@tagents_slot,free,-}' 2>/dev/null |
    awk -v me="$dp" -v OFS="$TAB" '
      $1 == me { next }
      $2 == "docked" { print $1, "docked"; next }
      $3 == "free"   { print $1, "free" }'
}

is_docked() {  # <pane> — is a chat docked into some sidebar in this pane?
  [ -n "${1:-}" ] || return 1
  [ -n "$(tmux display -p -t "$1" '#{@tagents_docked}' 2>/dev/null)" ]
}

# Docked HERE, in this very window — not merely docked somewhere. There can be
# several lists and so several sidebars, and a chat sitting in another one is not
# a pane to go to, it is a pane to swap in.
is_docked_in() {  # <pane> <window-id>
  local pane=${1:-} win=${2:-}
  [ -n "$pane" ] && [ -n "$win" ] || return 1
  [ "$(tmux display -p -t "$pane" '#{window_id} #{@tagents_docked}' 2>/dev/null)" \
    = "$win $win" ]
}

seat_here() {  # <the output of seats> <pane> — is that pane one of them?
  printf '%s\n' "${1:-}" | awk -F"$TAB" -v p="${2:-}" '$1 == p { f = 1 } END { exit !f }'
}

# THE SEAT ENTER USES IS THE ONE YOU WERE LAST IN, and @tagents_cur is what
# remembers it: a window option on the sidebar window, stamped by the focus hooks
# the moment you arrive in a seat and by every dock. It answers first because it
# is the only answer that survives you walking away. From a chat to a terminal in
# the same window and then back to the list to press enter, and both the active
# pane and the one before it are somebody else's — the seat you were reading is
# two moves back, and enter sent home a chat you had not been in.
#
# It used to be the third answer, on the grounds that a hook could not record it
# without spawning a shell on every pane switch. That was wrong: set-option takes
# -F and expands formats like any other command, so
# `set -Fw @tagents_cur "#{pane_id}"` writes the pane id inside tmux and costs
# nothing at all. See install_focus_hooks.
#
# Then the window's active pane, or the pane that was active before it, for the
# case where no hook ever fired — focus-events off, an older tmux, a hook
# somebody else overwrote. Then a free placeholder, so an empty seat is filled
# before a chat is evicted from one, and finally the leftmost chat. Every answer
# is checked against the seats of THIS window, so a marker that names a pane
# which has stopped being a seat is skipped rather than believed.
current_seat() {  # <list pane> -> the seat, nothing when the window has none
  local dp=${1:-} win ss cur
  win=$(tmux display -p -t "$dp" '#{window_id}' 2>/dev/null)
  [ -n "$win" ] || return 0
  ss=$(seats "$dp")
  [ -n "$ss" ] || return 0
  cur=$(tmux show -vw -t "$win" @tagents_cur 2>/dev/null)
  if [ -n "$cur" ] && seat_here "$ss" "$cur"; then printf '%s' "$cur"; return 0; fi
  # Sorted so the active pane is tried before the last one; a pane that is
  # neither is dropped rather than sorted to the end, where it would win by
  # default in a window whose active pane is the list.
  for cur in $(tmux list-panes -t "$win" \
                 -F '#{?pane_active,1,#{?pane_last,2,3}} #{pane_id}' 2>/dev/null |
               sort | awk '$1 != "3" { print $2 }'); do
    seat_here "$ss" "$cur" && { printf '%s' "$cur"; return 0; }
  done
  cur=$(printf '%s\n' "$ss" | awk -F"$TAB" '$2 == "free" { print $1; exit }')
  [ -n "$cur" ] || cur=$(printf '%s\n' "$ss" | awk -F"$TAB" 'NR == 1 { print $1; exit }')
  printf '%s' "$cur"
}


# GOING TO THE PANE IS THE UNDOCK. Docking physically moves the agent's pane
# into the dashboard and leaves this placeholder in its seat, so the pane in
# your own session stops showing the agent — it reads as if tmux had taken the
# pane hostage. The old text told you to press ctrl-x, which is an fzf binding
# that exists only inside the dashboard and does nothing whatsoever here.
#
# So there is no key any more: focusing the placeholder IS the request to have
# the agent back, and it is swapped home the instant you arrive.
#
# ONLY OUTSIDE THE SIDEBAR, though. A placeholder in a seat of the sidebar is not
# standing in for anybody — it is just the marker for "this seat is empty" — and
# the cursor sits there constantly, since that is where a docked chat is typed
# into. Without this guard ctrl-u could not work: it swaps the chat home, leaving
# the placeholder focused in the seat, and two seconds later this dragged the
# chat straight back in.
unpark() {  # <pane-id> — if this is a placeholder, bring its agent back here
  local sp=${1:-} agent
  [ -n "$sp" ] || return 0
  [ "$(tmux display -p -t "$sp" '#{@tagents_slot}' 2>/dev/null)" = 1 ] || return 0
  [ "$(tmux display -p -t "$sp" '#{window_id}' 2>/dev/null)" = "$(dash_window)" ] && return 0
  agent=$(tmux display -p -t "$sp" '#{@tagents_parked}' 2>/dev/null)
  [ -n "$agent" ] || return 0
  if ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx -- "$agent"; then
    tmux set -up -t "$sp" @tagents_parked 2>/dev/null    # agent is gone
    return 0
  fi
  # ONE KEYPRESS, SEVERAL HOOKS. Arriving at the placeholder can change the pane,
  # the window and the session at once, and there is a hook on each of those
  # events on top of the poll in slot(). Two unparks that both read
  # @tagents_parked before either clears it swap the same two panes twice —
  # straight back to where they started, with both markers wiped, so the chat
  # never comes home and the placeholder keeps the seat. The claim has to be
  # atomic, so the test, the markers and the swap go into one tmux command list:
  # the server runs a list to completion before the next one, and whoever loses
  # the race finds the marker already empty and does nothing. Pane ids are %<n>,
  # so there is nothing here to quote.
  # The collapse goes on the end of the same list, in the background: the swap
  # has just put this placeholder into the sidebar, where it is an empty seat
  # next to whatever else is docked there, and an empty seat left behind is the
  # width of a chat that is not there. `run-shell -b` is a child process, so it
  # is NOT covered by the atomicity above — two of them really do run at once,
  # one per window you walked through. collapse_seat takes a lock of its own for
  # precisely that, and the reason is written up there.
  tmux if-shell -F -t "$sp" '#{@tagents_parked}' \
    "set -up -t $sp @tagents_parked ; set -up -t $agent @tagents_docked ; \
     swap-pane -d -s $agent -t $sp ; select-pane -t $agent ; \
     run-shell -b \"'$SELF' --collapse $sp\"" 2>/dev/null
}

# The placeholder that holds a seat open while nothing is docked in it. It
# also stands in for an agent while that agent is docked, so it says where the
# agent went when it finds itself outside the dashboard window.
slot() {
  local dwin last="" win parked stray=0
  while :; do
    dwin=$(dash_window)
    win=$(tmux display -p -t "${TMUX_PANE:-}" '#{window_id}' 2>/dev/null)
    # NOBODY'S SEAT LEFT TO KEEP WARM. A placeholder outside the dashboard window
    # is standing in for one docked agent, and @tagents_parked names it. When that
    # agent is gone — its Claude exited, or the pane was killed while docked in the
    # sidebar — this pane is holding somebody else's window hostage for nothing,
    # over a grey note about a dashboard the agent is not in. That is the pane that
    # used to have to be hunted down and killed by hand. Exiting closes it, so the
    # window falls straight back to the layout it had before anything was docked.
    #
    # The marker is not enough on its own: unpark only clears it while the user is
    # actually looking at this pane, so a killed agent leaves it pointing at a pane
    # id that no longer exists. Ask tmux, not the marker.
    parked=$(tmux display -p -t "${TMUX_PANE:-}" '#{@tagents_parked}' 2>/dev/null)
    if [ -n "$parked" ] &&
       ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx -- "$parked"; then
      parked=""
    fi
    # Two ticks, not one: at birth the pane exists a moment before its markers do.
    if [ -n "$win" ] && [ "$win" != "${dwin:-}" ] && [ -z "$parked" ]; then
      stray=$((stray + 1))
      [ "$stray" -ge 2 ] && return 0
    else
      stray=0
    fi
    if [ "$win" != "$last" ]; then
      last=$win
      printf '\033[2J\033[H\033[90m\n'
      if [ -n "$dwin" ] && [ "$win" = "$dwin" ]; then
        printf '   pick an agent on the left and press enter —\n'
        printf '   it is swapped in here, live, ready to type into.\n'
      else
        printf '   this pane'\''s agent is being shown in the "%s" dashboard.\n' "$DASH_SESSION"
        printf '   it comes straight back the moment you focus this pane.\n'
      fi
      printf '\033[0m'
    fi
    # Belt and braces for the focus hooks: if this placeholder is the pane the
    # user is actually looking at, hand the agent back without waiting for an
    # event that may never arrive (focus-events off, an older tmux, a hook
    # someone else overwrote).
    if [ "$(tmux display -p -t "${TMUX_PANE:-}" \
              '#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}}' 2>/dev/null)" = 1 ]; then
      unpark "${TMUX_PANE:-}"
    fi
    sleep 2
  done
}

# THE PANE THAT DISAPPEARED. Docking is a swap: the agent comes into the
# dashboard window and the placeholder goes out to the agent's own window. When
# that agent's Claude then exits, its pane dies *inside the dashboard window*,
# so the seat is gone — and the placeholder is left stranded in whatever window
# it was swapped into. slot_pane() searches every window, so it still finds it,
# concludes there is nothing to repair, and the next dock swaps the next agent
# into that stranded window instead of the dashboard. From the outside: the
# right-hand pane with Claude in it vanishes.
#
# So the two questions have to be asked separately: "has this window a seat
# left?" is about THIS window, while "where does a docked agent go home to?" is
# about the placeholder wherever it currently lives.
#
# THE INVARIANT IS ONE SEAT, NOT ONE PLACEHOLDER. The window may hold several
# chats side by side and may hold a terminal that is none of our business; what
# it may never hold is nothing at all to dock into.
ensure_seat() {  # <list pane> — repair this window's seats, print the current one
  local dp=$1 sp c win
  win=$(tmux display -p -t "$dp" '#{window_id}' 2>/dev/null)

  # A chat docked here whose placeholder has gone has no way home at all: give it
  # one of its own, which is what its window looked like before it was docked
  # anyway. Only ever a chat — the terminal somebody split off beside the list
  # carries no marker, so it is not a seat and is not considered here. Breaking
  # THAT out is precisely what this used to do.
  seats "$dp" | awk -F"$TAB" '$2 == "docked" { print $1 }' |
    while IFS= read -r c; do
      [ -n "$(parked_slot "$c")" ] || break_home "$c"
    done

  # No seat at all: the placeholder died with the chat that was docked in it, or
  # this window has never had one. Bring one back if there is a spare going —
  # moving it, not copying, so no third pane appears anywhere. Spare is the word:
  # a placeholder with @tagents_parked set is keeping a seat for a chat that is
  # docked right now, and taking it away leaves that chat no way home. If it is
  # also the only pane in its window, moving it would destroy that window
  # outright. In either case split a fresh one instead and let the stranded-
  # placeholder check in slot() clear up whatever was left behind.
  if [ -z "$(seats "$dp")" ]; then
    sp=$(slot_pane)
    if [ -n "$sp" ] && [ -n "$win" ] &&
       [ -z "$(tmux display -p -t "$sp" '#{@tagents_parked}' 2>/dev/null)" ] &&
       [ "$(tmux display -p -t "$sp" '#{window_panes}' 2>/dev/null)" != 1 ]; then
      # join-pane refuses when that placeholder is its window's only pane and the
      # window would vanish; killing it and splitting a fresh one is equivalent.
      tmux join-pane -h -d -s "$sp" -t "$dp" -l "$((100 - DASH_WIDTH))%" 2>/dev/null ||
        tmux kill-pane -t "$sp" 2>/dev/null
    fi
    if [ -z "$(seats "$dp")" ]; then
      sp=$(tmux split-window -h -d -P -F '#{pane_id}' -l "$((100 - DASH_WIDTH))%" \
             -t "$dp" "exec '$SELF' --slot" 2>/dev/null) || return 1
      tmux set -p -t "$sp" @tagents_slot 1 2>/dev/null
    fi
  fi
  current_seat "$dp"
}
