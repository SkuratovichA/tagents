# lib/tagents/refresh.sh — keeping a list current
#
# Everything that reacts to time or to focus: the refresher loop (a 2 s tick that posts a reload to the picker only when something it draws changed, and a bare ignore otherwise, looks at the seats only when tmux changed, and every 5th tick reloads regardless, repairs the usage figure, window names, seats and notes, re-reads a changed config, and takes the resurrect snapshot; five failed posts end it), and keeps the status bar's cache from the tally the list writes, claim_port's re-assertion, follow_cursor, poke with its (pane, seat) debounce — one pane switch can fire three hooks — and install_focus_hooks, which wires the four tmux events lazily on the first dock.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# WHAT ONE TICK ASKS TMUX, in a single question. Every pane, with every attribute
# and option that list() and the seat helpers read, joined with a printable
# separator: a literal tab does not survive tmux outside a UTF-8 locale (see
# collect). The snapshot is only ever compared with the one before it, so the
# fields are never parsed back — except the last, which is global and so the same
# on every line. What each one serves:
#   pane_id, session:window.pane, pane_current_path   collect's P lines and dir_roots, the rows and their groups
#   pane_current_command, pane_pid                    live_panes' fallback and the process walk's pane map
#   window_id                                         dash_window, seat_border and seats: which window the list is in
#   pane_active, pane_last                            current_seat's answer when no hook stamped one
#   @tagents_list, @tagents_dash                      dash_pane and list_in_pane: which pane is the list
#   @tagents_docked, @tagents_slot, @tagents_parked   seats, is_docked, seat_border: who sits where
#   @tagents_cur                                      current_seat: the seat the cursor was last in
#   @tagents_port                                     claim_port: whose port the list pane carries
#   pane-border-status                                seat_border: the title bar it keeps
#   @ta_notes_any                                     whether there are notes editors for tnotes sync to look after
# THE PANE TITLE IS LEFT OUT ON PURPOSE. Claude's spinner retitles a working pane
# several times a second, so a title in the snapshot would make every tick of a
# busy session a reload — the very thing this exists to stop. A title-only change
# waits for the forced reload of the 5th tick.
REFRESH_SNAP_FMT='#{pane_id}|@|#{session_name}:#{window_index}.#{pane_index}|@|#{window_id}|@|#{pane_current_path}|@|#{pane_current_command}|@|#{pane_pid}|@|#{pane_active}|@|#{pane_last}|@|#{@tagents_list}|@|#{@tagents_dash}|@|#{@tagents_docked}|@|#{@tagents_slot}|@|#{@tagents_cur}|@|#{@tagents_parked}|@|#{@tagents_port}|@|#{pane-border-status}|@|#{@ta_notes_any}'

# HAS ANYTHING THE LIST DRAWS FROM DISK BEEN WRITTEN SINCE THE MARKER WAS TOUCHED?
# Answered with the shell's own file-time test and globs, nothing else: this runs
# on every idle tick and a process started for it is exactly what it is here to
# save. A path counts as changed when it is NOT OLDER than the marker, so a write
# in the same second as the touch counts — bash 3.2 compares whole seconds, and a
# spare reload costs a little where a missed one loses a change. A path that does
# not exist is never newer than anything, which is also why a file that was
# DELETED is not seen here: its directory is checked where it has one worth
# checking, and the forced reload of the 5th tick catches the rest.
#
# The paths are what collect() and list() open: the state files (history.tsv is
# not one), the origin cache, the labels, the hidden-columns file and the .flat
# marker; the sub/, model/ and prompt/ files and the directories that hold them,
# since an added or removed file changes only its directory; and the config with
# its per-host overlay. $STATE_DIR itself is NOT among them: the status bar
# renames .counts.out into it every few seconds, so its time moves whether or not
# a session did.
refresh_changed() {  # <marker> <overlay config path> — 0 when something changed
  local mark=${1:-} ovl=${2:-} f
  [ -e "$mark" ] || return 0
  for f in "$STATE_DIR"/[0-9]*.tsv "$STATE_DIR"/s-*.tsv "$LABELS" "$ORIGINS" "$COLS_FILE" \
           "$STATE_DIR/.flat" "$STATE_DIR/sub" "$STATE_DIR"/sub/* \
           "$STATE_DIR/model" "$STATE_DIR"/model/*.tsv \
           "$STATE_DIR/prompt" "$STATE_DIR"/prompt/* "$CONFIG_FILE" "$ovl"; do
    ! [ "$mark" -nt "$f" ] && return 0
  done
  return 1
}

# THE LOOP IS QUIET WHEN NOTHING MOVED. Each tick used to post a reload and ask
# tmux about the seats, whatever had happened since the last one, and a reload is
# a few dozen programs the endpoint security agent inspects one by one — most of
# the churn this machine had left, for a picture that had not changed. Now a tick
# starts one tmux (the snapshot above) and one curl, and the rest only when the
# snapshot says tmux changed or a file the list reads is newer than the marker:
#   reload   the first tick; every 5th (the forced one — it carries what the
#            snapshot cannot see: the age column, the pane titles, a process that
#            died, the usage index tusage --update has just rebuilt); a changed
#            snapshot; a changed file; a reload that was refused last time
#   ignore   fzf's no-op action, posted otherwise, so that an idle tick still
#            proves the list is listening and a dead one still ends the loop
#   seats    the block at the foot of the loop, when the snapshot changed, when
#            no claim is held, and on every 5th tick as a backstop
# AND THE STATUS BAR IS FED FROM HERE while this loop is answered. tmux runs
# `tagents --counts` every few seconds, and each run that is due is a whole list
# (about 38 programs and 75 forks) to count rows the list this loop reloads has
# already counted: list() leaves its tally in .counts.tally, and every answered
# tick turns it into .counts.out and stamps .counts.ts, so the bar's own throttle
# never finds itself due and it serves the cache for the price of a date. The
# stamp stops with the answers (a refused post clears `live`), and the bar is then
# due again within COUNTS_EVERY seconds and computes for itself. See refresher_counts.
refresher() {
  local port=${TA_PORT:-} tick=0 dp seat last="" fails=0 fl pub=""
  local snap="" rsnap="" ssnap="" pending=1 due body first mark cfgmark ovl
  local startmark t0 live="" lasttl="" lasttext="" cdirty=1
  [ -z "$port" ] && return 0
  # One marker per refresher, in the state directory every writer already uses:
  # its time is "when the last reload was posted", and the second one is "when
  # the config was last read" (see below). A refresher that is killed leaves
  # them behind, and the next one on the same port overwrites them.
  mark="$STATE_DIR/.refresher.$port"; cfgmark="$mark.cfg"
  # "When this refresher started": a tally older than it belongs to some earlier
  # picker, hours ago perhaps, and is never served (see refresher_counts).
  startmark="$mark.start"
  : >"$startmark" 2>/dev/null
  # The per-host overlay is read by cfg_overlay from this same path.
  host_once
  ovl="${CONFIG_FILE%.yaml}.${TA_HOST:-$HOST_S}.yaml"
  # Touched before the first read of the config, so a write that lands while it
  # is being read is not older than the marker.
  : >"$cfgmark" 2>/dev/null
  # THE CONFIG IS LOADED IN THIS SHELL, not left to the first lookup. --refresher
  # is dispatched without a cfg_load, and cfg_get is almost always called inside
  # a $(...): the load it triggers there dies with the subshell, so every lookup
  # parsed the YAML again (an awk and a hostname each) while usage_on, which
  # memoises in THIS shell, answered once from whatever the file said at its first
  # call. A config edited under a running refresher then turned the footer on and
  # the tusage update off at the same time. Loaded here, both read the one copy,
  # and the re-read on the 5th tick below replaces it for both at once.
  cfg_load
  # THE CLOCK, READ ONCE. The stamp on the bar's cache is written on every tick
  # and a date per tick is a program per tick; SECONDS counts for free, so the
  # epoch of any later moment is t0 + SECONDS.
  t0=$(( $(date +%s) - SECONDS ))
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
  # The pieces of the bar's text that move slowly, read once here and again on
  # every 5th tick (see counts_parts). After usage_env: the month line needs it.
  counts_parts
  while sleep 2; do
    # Advance the token index out here, not in list(): parsing the tail of every
    # transcript costs a few hundred milliseconds, and a keystroke must never
    # wait on it. Every 5th tick is ~10s of lag on a number that moves slowly.
    tick=$(( (tick + 1) % 5 ))
    if [ "$tick" = 0 ]; then
      # THE STAMP IS RENEWED BEFORE THE SLOW WORK OF THIS TICK, not after it: a
      # tusage --update can take longer than COUNTS_EVERY, and a stamp that aged
      # past it in there would make the bar compute for itself in the middle of
      # a loop that is keeping it. Only while the stamp is being kept at all.
      [ -n "$live" ] && counts_stamp
      # A CONFIG CHANGED UNDER A RUNNING REFRESHER IS READ AGAIN. The config is
      # memoised for the life of a process, and a refresher lives as long as its
      # list — one started before usage was turned off went on running tusage
      # for a day. Not older than the marker is "changed", as above; the marker
      # is its own, because the one for the list is touched on every reload.
      # The memos are cleared with it: the usage switch is asked once per
      # process, and a config that has gone away must read as empty, not as the
      # last one that was there.
      if ! [ "$cfgmark" -nt "$CONFIG_FILE" ] || ! [ "$cfgmark" -nt "$ovl" ]; then
        : >"$cfgmark" 2>/dev/null
        CFG=""; CFG_LOADED=0; USAGE_ON=
        cfg_load
        usage_on && usage_env
      fi
      usage_on && tusage --update >/dev/null 2>&1
      # What the update moved is in the burn and the month line, and the config
      # that was just read again may have gained or lost its problem.
      counts_parts; cdirty=1
      # The footer is one of fzf's own frames, not a row, so reload-sync leaves
      # it alone — it has to be pushed. On this tick and no other: the figure it
      # carries only moves when the index it is read from does.
      fl=$(usage_line footer) && [ -n "$fl" ] &&
        post_fzf "$port" "change-footer($fl)"
      # Windows named after their agents. Unthrottled here — this is already the
      # every-5th-tick branch, and there is one refresher per list — while the
      # status bar path throttles itself, since it has no tick of its own.
      sync_window_names >/dev/null 2>&1
      # The resurrect snapshot, which the status bar used to take whenever it
      # computed the counts. While this loop keeps the stamp it does not compute
      # them, so the snapshot rides the tick that already sweeps the names; its own
      # throttle (resurrect.every) still decides whether it is due.
      if resurrect_due; then resurrect_save >/dev/null 2>&1 & fi
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
    fi
    # THE SNAPSHOT IS TAKEN AFTER THE REPAIRS ABOVE, so a seat they put back is
    # already in it and does not cost a reload on the next tick for something
    # the forced one below has just drawn.
    snap=$(tmux list-panes -a -F "$REFRESH_SNAP_FMT" 2>/dev/null)
    if [ "$tick" = 0 ]; then
      # The notes editors, for the same reason the seats are repaired here: the
      # focus hooks all fire on ARRIVAL, so nothing at all notices a chat pane
      # that simply died with its editor still parked beside it. Only while there
      # are editors: @ta_notes_any is set by tnotes when it makes the first one
      # and unset when the last goes (the focus hooks are guarded by the same
      # flag), and it is global, so any line of the snapshot carries it.
      first=${snap%%$'\n'*}
      if [ -x "${SELF%/*}/tnotes" ] && [ "${first##*|@|}" = 1 ]; then
        "${SELF%/*}/tnotes" sync >/dev/null 2>&1 &
      fi
    fi
    # WHETHER THERE IS ANYTHING TO DRAW. The marker is touched immediately BEFORE
    # the post, not after: a write that lands while the list is running is then
    # not older than it, and is seen on the next tick. A reload that was refused
    # has already touched the marker, so it is remembered in $pending instead.
    due=""
    if [ -n "$pending" ] || [ "$tick" = 0 ] || [ "$snap" != "$rsnap" ] ||
       refresh_changed "$mark" "$ovl"; then
      due=1
      : >"$mark" 2>/dev/null
      body="reload-sync($SELF --list)"
    else
      body=ignore
    fi
    # ONE FAILED POST IS NOT A DEAD LIST. curl comes back non-zero for a refused
    # connection, and fzf refuses one whenever it is between reloads or busy with
    # a child of its own — so breaking on the first failure left a live dashboard
    # with no refresher behind it and nothing to say why. Five in a row is ten
    # seconds of a list that never answers, which is a list that has really gone;
    # anything short of that resets the count. An idle tick counts the same: its
    # ignore is there to find out.
    if ! curl -s -XPOST "http://127.0.0.1:$port" -d "$body" >/dev/null 2>&1; then
      fails=$((fails + 1))
      # A list that does not answer is not one whose tally is current: the stamp
      # stops here, and the bar takes the counting back within COUNTS_EVERY.
      live=""
      [ -n "$due" ] && pending=1
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
    refresher_counts
    # What the reload saw is what the next snapshot is compared with.
    if [ -n "$due" ]; then rsnap=$snap; pending=""; fi

    # THE SEATS ARE ONLY LOOKED AT WHEN TMUX MOVED. Every pane, option and seat
    # stamp they read is in the snapshot, so an unchanged snapshot means the same
    # answers as last time — and each of these is a tmux round-trip or several.
    # The claim counts as tmux state: another refresher overwriting it changes
    # the snapshot, and claim_port makes it again within the tick. Run anyway when
    # no claim is held (it was never made, or was given up above), and on the 5th
    # tick for whatever a snapshot cannot show (a list process that has died).
    if [ "$snap" != "$ssnap" ] || [ -z "$pub" ] || [ "$tick" = 0 ]; then
      ssnap=$snap
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
      # Re-made whenever the pane moves or the option changes: see claim_port.
      claim_port
    fi
  done
  rm -f "$mark" "$cfgmark" "$startmark" 2>/dev/null
  # Only ever taken down by its owner. A refresher outlived by its fzf — the
  # list respawned, five posts refused — must not wipe the claim the NEXT
  # refresher has already made on the same pane: that is how a live dashboard
  # ended up with no port and a marker that waited for the tick again.
  [ -n "$pub" ] && [ "$(tmux show -pv -t "$pub" @tagents_port 2>/dev/null)" = "$port" ] &&
    tmux set -up -t "$pub" @tagents_port 2>/dev/null
  return 0
}

# THE STAMP ON THE BAR'S CACHE, in the epoch the refresher's own clock says. The
# braces are for a state directory that is gone: the error of a failed redirection
# is printed before a 2>/dev/null on the printf could apply. Uses t0.
counts_stamp() {
  { printf '%s\n' "$((t0 + SECONDS))" >"$COUNTS_STAMP"; } 2>/dev/null
}

# THE BAR'S CACHE FROM THE LIST'S TALLY, on every tick whose post was answered.
# The reload is asynchronous, so the tally read here is the one the previous
# reload left: at most one tick old, which is far inside COUNTS_EVERY. It is only
# served when it is not older than this refresher (a tally left by a picker that
# closed hours ago says nothing about now); until the first list has written one
# the stamp stays where it was and the bar counts for itself. Everything is the
# shell's own: on an idle tick nothing here starts a program, and the cache is
# rewritten, by a rename, only when its text is not the one already there. Uses
# the refresher's startmark, t0, live, lasttl, lasttext and cdirty.
refresher_counts() {
  local f="$STATE_DIR/.counts.tally" tl="" text
  [ -e "$f" ] && ! [ "$startmark" -nt "$f" ] || return 0
  { IFS= read -r -d '' tl <"$f"; } 2>/dev/null
  [ -n "$tl" ] || return 0
  if [ -n "$cdirty" ] || [ "$tl" != "$lasttl" ] || [ ! -e "$COUNTS_OUT" ]; then
    # The trailing newlines of the burn and the month line belong to the text,
    # and a command substitution would eat them: a character goes after, and off.
    text=$(counts_compose "$tl"; printf .); text=${text%.}
    if [ "$text" != "$lasttext" ] || [ ! -e "$COUNTS_OUT" ]; then
      if { printf '%s' "$text" >"$COUNTS_OUT.$$"; } 2>/dev/null &&
         mv -f "$COUNTS_OUT.$$" "$COUNTS_OUT" 2>/dev/null; then
        lasttext=$text
      else
        rm -f "$COUNTS_OUT.$$" 2>/dev/null
        return 0   # nothing was written, so nothing is vouched for
      fi
    fi
    lasttl=$tl; cdirty=""
  fi
  counts_stamp
  live=1
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
