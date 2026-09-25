# lib/tagents/refresh.sh — keeping a list current
#
# Everything that reacts to time or to focus: the refresher loop (2 s reload post, 10 s usage/names/notes/seat repair, the five-failed-posts exit), claim_port's per-tick re-assertion, follow_cursor, poke with its (pane, seat) debounce — one pane switch can fire three hooks — and install_focus_hooks, which wires the four tmux events lazily on the first dock.
#
# Part of ./tagents; `tagents --help` is the model this implements.

refresher() {
  local port=${TA_PORT:-} tick=0 dp seat last="" fails=0 fl pub=""
  [ -z "$port" ] && return 0
  # THE PORT IS ONLY KNOWN IN HERE. fzf hands $FZF_PORT to the start: bind and
  # to nothing else, so --poke — fired from a tmux hook in a window that has
  # never heard of this list — has no way to ask for it. It is published on the
  # list pane instead, and taken down again when this loop ends: the refresher
  # is the one process that knows when the list has really gone, which makes the
  # option a live claim rather than a leftover pointing at a dead port.
  dp=$(dash_pane)
  # No claim before the first post has been answered: a port is only worth
  # publishing once the list behind it is known to be listening — see below.
  # THE ACCOUNTS TRAVEL WITH THE UPDATE TOO. usage_env is what hands tusage the
  # profile names and the directory rules; every reader in usage.sh calls it,
  # but the writer here did not — so each 5th tick rebuilt the account map under
  # config-dir labels (`default`, `d`), the next read rebuilt it back, and the
  # meter was fetched a second time under a name nothing reads.
  usage_on && usage_env
  while sleep 2; do
    # Advance the token index out here, not in list(): parsing the tail of every
    # transcript costs a few hundred milliseconds, and a keystroke must never
    # wait on it. Every 5th tick is ~10s of lag on a number that moves slowly.
    tick=$(( (tick + 1) % 5 ))
    if [ "$tick" = 0 ]; then
      usage_on && tusage --update >/dev/null 2>&1
      # The footer is one of fzf's own frames, not a row, so reload-sync leaves
      # it alone — it has to be pushed. On this tick and no other: the figure it
      # carries only moves when the index it is read from does.
      fl=$(usage_line footer) && [ -n "$fl" ] &&
        post_fzf "$port" "change-footer($fl)"
      # Windows named after their agents. Unthrottled here — this is already the
      # every-5th-tick branch, and there is one refresher per list — while the
      # status bar path throttles itself, since it has no tick of its own.
      sync_window_names >/dev/null 2>&1
      # Self-heal the sidebar. When a docked agent's Claude exits, its pane dies
      # inside the dashboard window and that seat is simply gone until something
      # docks again. Put it back rather than making the user notice and work out
      # what happened. "Is the window down to one pane" was the old test and it
      # stopped firing the moment somebody opened a terminal in there; no seat at
      # all is the condition, however many panes the window has.
      dp=$(dash_pane)
      if [ -n "$dp" ] && [ -z "$(seats "$dp")" ]; then
        ensure_seat "$dp" >/dev/null 2>&1
      fi
      # The notes editors, for the same reason the seats are repaired here: the
      # focus hooks all fire on ARRIVAL, so nothing at all notices a chat pane
      # that simply died with its editor still parked beside it.
      [ -x "${SELF%/*}/tnotes" ] && "${SELF%/*}/tnotes" sync >/dev/null 2>&1 &
    fi
    # ONE FAILED POST IS NOT A DEAD LIST. curl comes back non-zero for a refused
    # connection, and fzf refuses one whenever it is between reloads or busy with
    # a child of its own — so breaking on the first failure left a live dashboard
    # with no refresher behind it and nothing to say why. Five in a row is ten
    # seconds of a list that never answers, which is a list that has really gone;
    # anything short of that resets the count.
    if ! curl -s -XPOST "http://127.0.0.1:$port" -d "reload-sync($SELF --list)" \
           >/dev/null 2>&1; then
      fails=$((fails + 1))
      # A LIST THAT DOES NOT ANSWER HAS NO CLAIM TO MAKE. The five-strike grace
      # keeps the loop alive through a busy fzf, but a refresher whose fzf is
      # already gone was re-publishing its dead port on the pane the NEXT list
      # had claimed, every tick until it quit — the two fought over the option
      # and the poke posted into a closed port. So a refused post gives the claim
      # up at once (if it is still ours) and the claim is only ever re-made below,
      # after a post that was answered.
      if [ -n "$pub" ] &&
         [ "$(tmux show -pv -t "$pub" @tagents_port 2>/dev/null)" = "$port" ]; then
        tmux set -up -t "$pub" @tagents_port 2>/dev/null
      fi
      pub=""
      [ "$fails" -ge 5 ] && break
      continue
    fi
    fails=0

    # THE CURSOR FOLLOWS THE SEAT. With two chats side by side, clicking into the
    # other one leaves the list still pointing at the row you left — and that row
    # is what enter and ctrl-x act on. Only when it CHANGES: moving the cursor
    # under somebody who is scrolling the list is an interruption, and once is a
    # very different thing from twice a second.
    dp=$(dash_pane)
    seat_border "$dp"   # the backstop for the paths that move seats without asking
    seat=""
    [ -n "$dp" ] && seat=$(current_seat "$dp")
    is_docked "$seat" || seat=""
    if [ "$seat" != "$last" ]; then
      last=$seat
      [ -n "$seat" ] && follow_cursor "$port" "$dp"
    fi
    # Re-made every tick, not only when the pane moves: see claim_port.
    claim_port
  done
  # Only ever taken down by its owner. A refresher outlived by its fzf — the
  # list respawned, five posts refused — must not wipe the claim the NEXT
  # refresher has already made on the same pane: that is how a live dashboard
  # ended up with no port and a marker that waited for the tick again.
  [ -n "$pub" ] && [ "$(tmux show -pv -t "$pub" @tagents_port 2>/dev/null)" = "$port" ] &&
    tmux set -up -t "$pub" @tagents_port 2>/dev/null
  return 0
}

# THE PORT IS A CLAIM THAT HAS TO BE KEPT, not a note left once. The list pane
# can be replaced under the refresher (a sidebar rebuilt, a list restarted), and
# the option itself can be overwritten or removed by another refresher on its way
# out — the one whose fzf just died and whose cleanup ran a beat after the new
# one published. So every tick asks whether the pane still says OUR port and
# writes it again when it does not; a `tmux show` is a cheap question. Uses the
# caller's dp, port and pub.
claim_port() {
  [ -n "$dp" ] || return 0
  if [ "$(tmux show -pv -t "$dp" @tagents_port 2>/dev/null)" = "$port" ]; then
    pub=$dp; return 0
  fi
  [ -n "$pub" ] && [ "$pub" != "$dp" ] &&
    [ "$(tmux show -pv -t "$pub" @tagents_port 2>/dev/null)" = "$port" ] &&
    tmux set -up -t "$pub" @tagents_port 2>/dev/null
  tmux set -p -t "$dp" @tagents_port "$port" 2>/dev/null && pub=$dp
  return 0
}

# THE CURSOR FOLLOWS THE SEAT. With two chats side by side, clicking into the
# other one leaves the list still pointing at the row you left — and that row is
# what enter and ctrl-x act on. Only ever called when the seat CHANGED, though:
# moving the cursor under somebody who is scrolling the list is an interruption,
# and once is a very different thing from twice a second. Both callers work that
# out for themselves — the refresher by comparing ticks, poke by the stamp it
# keeps — so this just does the move.
follow_cursor() {  # <port> <list pane> — put the cursor on the current seat's row
  local port=${1:-} dp=${2:-} seat n
  [ -n "$port" ] && [ -n "$dp" ] || return 0
  seat=$(current_seat "$dp")
  is_docked "$seat" || return 0
  # A group header carries its most urgent member's pane id too, so the row
  # has to be the agent's own — the header is the one with the ▾ in it.
  n=$("$SELF" --list 2>/dev/null |
    awk -F"$TAB" -v p="$seat" \
        '$1 == p && index($2, "\342\226\276") == 0 { print NR; exit }')
  [ -n "$n" ] && post_fzf "$port" "pos($n)"
  return 0
}

# THE MARKER MOVES WITH YOU, NOT WITH THE NEXT TICK. ▶ is drawn by --list from
# the seat in @tagents_cur, which the focus hooks stamp the instant you arrive;
# the list itself, though, is only ever re-rendered by whatever posts a reload to
# fzf's listen port, and until this existed that was the refresher alone — so a
# click into the other chat left the triangle behind for up to two seconds. This
# is the same reload, posted by the hook that did the stamping.
#
# THE SEAT IS THE STAMP, on purpose. One select-pane fires after-select-pane and
# pane-focus-in, and arriving from another window adds after-select-window on top:
# three hooks, one thing that happened. Debouncing on a clock would need a
# sub-second one, which bash 3.2 has not got and a hook on every pane switch is
# the wrong place to fork for — and it would swallow a real second switch (into
# the other seat and back) along with the duplicates. What the list draws depends
# on the seat and nothing else, so the seat is what is compared: the first hook
# of a switch repaints, its twins find their own answer already written down.
poke() {  # [pane] — repaint every live list now, rather than on the next tick
  # The pane the hook fired for is taken and not read: which pane you arrived in
  # is already in @tagents_cur by the time this runs, and every list gets the
  # same reload whichever window it was. It is in the hook so that `show-hooks`
  # says what fired, and so `--poke %5` by hand reads the same as the rest.
  local stamp="$STATE_DIR/.poke" was now dp p pid port hit=""
  dp=$(dash_pane)
  [ -n "$dp" ] || return 0
  now="$dp $(current_seat "$dp")"
  was=$(cat "$stamp" 2>/dev/null)
  [ "$now" = "$was" ] && return 0
  while read -r p pid port; do
    kill -0 "$pid" 2>/dev/null || continue
    hit=1
    post_fzf "$port" "reload-sync($SELF --list)"
    follow_cursor "$port" "$p"
  done <<EOF
$(tmux list-panes -a -F '#{pane_id} #{@tagents_list} #{@tagents_port}' 2>/dev/null |
    awk 'NF == 3')
EOF
  # Written only when a list actually took it. A poke that found no port has
  # repainted nothing, and must not tell the next one the work is done.
  [ -n "$hit" ] && printf '%s\n' "$now" >"$stamp" 2>/dev/null
  return 0
}

# Installed the first time anything is docked, so a user who never docks gets no
# hooks at all. Several events because pane-focus-in alone misses arriving from
# another window or another session.
install_focus_hooks() {
  # if-shell -F evaluates a tmux format WITHOUT spawning anything, so the script
  # only ever runs when the pane you just focused really is a placeholder.
  # These hooks fire on every pane switch; a bash start-up on each one would be
  # a tax on simply moving around tmux.
  #
  # The second hook is what remembers which seat you are in, and it spawns
  # nothing either: set-option takes -F, so tmux expands #{pane_id} itself and
  # writes it into the window option. (This used to say a hook could not do that
  # at all, and current_seat was built around tmux's own active/last pane
  # instead. Those two say nothing once you have walked from the seat to a
  # terminal and on to the list, which is the ordinary way to reach enter.)
  # Appended with -ga rather than replacing: the unpark hook above has to stay.
  # Four commands per event and no more however often this runs — the first
  # set-hook resets the event, the other three append to it.
  local ev cmd cur pk nts
  cmd="if-shell -F '#{@tagents_slot}' \"run-shell -b \\\"'$SELF' --unpark '#{pane_id}'\\\"\""
  # Single quotes around the inner command so tmux stores it rather than
  # expanding it now; the "#{pane_id}" inside is expanded when the hook fires,
  # against the pane it fired for.
  cur="if-shell -F '#{||:#{@tagents_docked},#{@tagents_slot}}'"
  cur="$cur 'set -Fw @tagents_cur \"#{pane_id}\"'"
  # AFTER the stamp above and never before it: this is what makes the list
  # redraw, and it has to find the seat it is about to draw already written
  # down. Behind the same format guard, so walking through panes that are
  # neither a seat nor a placeholder still costs no shell at all.
  pk="if-shell -F '#{||:#{@tagents_docked},#{@tagents_slot}}'"
  pk="$pk \"run-shell -b \\\"'$SELF' --poke '#{pane_id}'\\\"\""
  # And the notes editors, behind their own format guard for the same reason
  # the unpark hook has one: a pane switch must not cost a bash start-up just
  # because tnotes is installed. @ta_notes_any is set only while an editor pane
  # exists anywhere, and unset again by `tnotes sync` when the last one goes.
  nts="if-shell -F '#{@ta_notes_any}' \"run-shell -b \\\"'${SELF%/*}/tnotes' sync '#{pane_id}'\\\"\""
  for ev in pane-focus-in after-select-pane after-select-window client-session-changed; do
    tmux set-hook -g "$ev" "$cmd" 2>/dev/null
    tmux set-hook -ga "$ev" "$cur" 2>/dev/null
    tmux set-hook -ga "$ev" "$pk" 2>/dev/null
    tmux set-hook -ga "$ev" "$nts" 2>/dev/null
  done
}
