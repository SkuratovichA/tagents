# lib/tagents/refresh.sh — keeping a list current
#
# Everything that reacts to time or to tmux: the refresher loop (it sleeps on the tmux channel tagents-ev and wakes when the agent-state hook, a tmux hook or tagents itself rings it, posts a reload to the picker only when something it draws changed, checks the port claim only when tmux changed, and on a slow pass — every TA_REFRESH_SLOW seconds of wakes, and always at the idle timeout — reloads regardless, repairs the usage figure, window names and notes, re-reads a changed config, and takes the resurrect snapshot; five failed posts end it), and keeps the status bar's text, in the tmux option @tagents_counts and in a cache file, from the tally the list writes, claim_port's re-assertion, and install_event_hooks, which wires the tmux lifecycle and focus events to the channel and puts the follow hooks of follow.sh beside them.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# WHAT ONE TICK ASKS TMUX, in a single question. Every pane, with every attribute
# and option that list() and the window helpers read, joined with a printable
# separator: a literal tab does not survive tmux outside a UTF-8 locale (see
# collect). The snapshot is only ever compared with the one before it, so the
# fields are never parsed back — except the last, which is global and so the same
# on every line, and snap_has_editor, which reads the last field of each pane line.
# What each one serves:
#   pane_id, session:window.pane, pane_current_path   collect's P lines and dir_roots, the rows and their groups
#   pane_current_command, pane_pid                    live_panes' fallback and the process walk's pane map
#   window_id                                         dash_window: which window the list is in
#   pane_active, pane_last                            which pane of a window is the one on screen
#   @tagents_list, @tagents_dash                      dash_pane and list_in_pane: which pane is the list
#   @tagents_joined                                   a chat joined into a window that is not its home: the session it came from
#   @tagents_port                                     claim_port: whose port the list pane carries
#   @ta_notes_for                                     whether a pane is a notes editor, so tnotes sync has something to look after (1 or 0)
# THE PANE TITLE IS LEFT OUT ON PURPOSE. Claude's spinner retitles a working pane
# several times a second, so a title in the snapshot would make every tick of a
# busy session a reload — the very thing this exists to stop. A title-only change
# waits for the forced reload of the 5th tick.
REFRESH_SNAP_FMT='#{pane_id}|@|#{session_name}:#{window_index}.#{pane_index}|@|#{window_id}|@|#{pane_current_path}|@|#{pane_current_command}|@|#{pane_pid}|@|#{pane_active}|@|#{pane_last}|@|#{@tagents_list}|@|#{@tagents_dash}|@|#{@tagents_joined}|@|#{@tagents_port}|@|#{?@ta_notes_for,1,0}'

# Does any pane of the snapshot ($snap of the caller) carry @ta_notes_for: the last field of a pane line is 1. The snapshot's own last line is
# the count of rings, which has no |@| in it.
snap_has_editor() {
  case "$snap" in *"|@|1"$'\n'*|*"|@|1") return 0 ;; esac
  return 1
}

# HAS ANYTHING THE LIST DRAWS FROM DISK BEEN WRITTEN SINCE THE MARKER WAS TOUCHED?
# Answered with the shell's own file-time test and globs, nothing else: this runs
# on every idle tick and a process started for it is exactly what it is here to
# save. A path counts as changed when it is NOT OLDER than the marker, so a write
# in the same second as the touch counts — bash 3.2 compares whole seconds, and a
# spare reload costs a little where a missed one loses a change. A path that does
# not exist is never newer than anything, which is also why a file that was
# DELETED is not seen here: its directory is checked where it has one worth
# checking, a deleted state file is seen by the refresher's count of them, and
# the forced reload of the 5th tick catches the rest.
#
# THIS LIST IS A HAND COPY of what collect() (state.sh) and list() (list.sh) read:
# a path added there and not here is a change the picker only shows on the 5th
# tick. tests/refresh.sh section 11 writes one of each kind between two idle ticks
# and expects a reload on the next, so the two cannot drift silently.
#
# The paths are what collect() and list() open: the state files (history.tsv is
# not one), the origin cache, the labels, the hidden-columns file and the .flat
# marker; the sub/, model/ and prompt/ files and the directories that hold them,
# since an added or removed file changes only its directory; and the config with
# its per-host overlay. $STATE_DIR itself is NOT among them: the status bar
# renames .counts.out into it every few seconds, so its time moves whether or not
# a session did.
refresh_changed() {  # <marker> <overlay config path> [strict] — 0 when something changed
  local mark=${1:-} ovl=${2:-} strict=${3:-} f
  [ -e "$mark" ] || return 0
  # STRICT is the second look, a second after a reload (see the refresher): by then
  # a write in the second of the touch is the very change that reload drew, and
  # counting it again would post two reloads for every event. Only a file newer
  # than the marker is a change there.
  if [ -n "$strict" ]; then
    for f in "$STATE_DIR"/[0-9]*.tsv "$STATE_DIR"/s-*.tsv "$LABELS" "$ORIGINS" "$COLS_FILE" \
             "$STATE_DIR/.flat" "$STATE_DIR/sub" "$STATE_DIR"/sub/* \
             "$STATE_DIR/model" "$STATE_DIR"/model/*.tsv \
             "$STATE_DIR/prompt" "$STATE_DIR"/prompt/* "$CONFIG_FILE" "$ovl"; do
      [ "$f" -nt "$mark" ] && return 0
    done
    return 1
  fi
  for f in "$STATE_DIR"/[0-9]*.tsv "$STATE_DIR"/s-*.tsv "$LABELS" "$ORIGINS" "$COLS_FILE" \
           "$STATE_DIR/.flat" "$STATE_DIR/sub" "$STATE_DIR"/sub/* \
           "$STATE_DIR/model" "$STATE_DIR"/model/*.tsv \
           "$STATE_DIR/prompt" "$STATE_DIR"/prompt/* "$CONFIG_FILE" "$ovl"; do
    ! [ "$mark" -nt "$f" ] && return 0
  done
  return 1
}

# THE LOOP SLEEPS UNTIL IT IS WOKEN. It used to tick every 2 s, and a tick started
# three programs when nothing had happened and some two hundred every fifth time
# (a tusage --update per account among them), plus a forced reload: about 26
# programs a second while the dashboard was open, which the endpoint security
# agent inspects one by one. Now it waits on a tmux channel, tagents-ev, and
# something has to ring it:
#   the agent-state hook   every Claude event, in the tmux call that mirrors @agent
#   tmux itself            the hooks install_event_hooks sets: panes, windows and
#                          sessions made, killed, renamed, moved; the focus events
#   tagents                where it writes what the list draws (signal_ev): labels,
#                          origins, hidden columns, the flat marker, forgotten rows
#   release_dash           a list that closes rings it once more, so that its
#                          refresher notices at once and ends
# `tmux wait-for` attaches nothing, which is why it is not control mode: a control
# client would be listed by list-clients, where the notifier reads what is on
# screen, and counted in session_attached, which the slots read.
#
# A SIGNAL IS NOT A COUNTER. With nobody waiting, the first one sets the channel's
# woken flag and the next wait returns at once; the SECOND one, arriving before
# that wait, clears the flag again (measured on tmux 3.7b: two signals, then a
# wait, blocks). So a waiter that sleeps, or is busy, between two waits loses every
# other ring. Nothing here relies on being back in `wait-for` in time: EVERY RING IS
# ALSO A COUNT. It first adds one to the global option @tagents_evgen (EV_BUMP,
# core.sh), in the same tmux call as the signal, and the loop
#   reads the count in the call that takes its snapshot (one tmux, so the two
#   are the same moment), and
#   waits with `if-shell -F "#{==:#{?@tagents_evgen,..},<count it saw>}" 'wait-for
#   tagents-ev'`, which the server evaluates and then waits, as one step: a ring
#   that came in at any time since the snapshot has moved the count, the wait does
#   not happen, and the loop is woken at once. A ring is therefore never lost, and
#   nothing needs a second look in case one was.
# ONE WAITER IS OUTSTANDING AT MOST, and it is one `tmux` program per wait: a
# subshell started when the loop is about to wait runs the if-shell above and
# writes its exit status as a line into the FIFO the loop reads with a timeout
# (TA_REFRESH_IDLE, 60 s, the only clock there is). A wait that timed out is still
# outstanding and is not started again; the next read is of the same one. A rung
# channel costs one line in that FIFO and nothing per ring: a hundred rings in a
# second are one count that moved. A waiter that fails (tmux is gone) writes a
# status that is not 0, which ends the loop. The coalescing is done by the loop,
# after the pass, with a read that times out (see below).
# EACH WAKE RUNS:
#   the snapshot     one tmux; a reload is due when it moved, when a file the
#                    list reads is newer than the marker, when a reload was
#                    refused, or on the slow pass
#   the port claim   when the snapshot moved, or no claim is held
# and posts nothing at all when nothing is due: with no wake, no program runs.
# AT MOST ONE RELOAD IS POSTED EVERY TA_REFRESH_MIN SECONDS (2): a busy Claude
# changes something a second, and a reload is a whole list. A change after a quiet
# spell is posted at once; one that comes within the interval of a post is owed,
# and made when the interval is over, with no further ring needed.
# THE SECOND LOOK after a post, a second on, is not there for a lost ring. It is
# for the marker: bash 3.2 compares file times in whole seconds, so a write in the
# second of the reload's touch is a "change" at the next wake whether or not that
# reload drew it (see refresh_changed). The second look asks only about files
# strictly newer, and when it finds none it moves the marker on, and so no event
# is drawn twice.
# THE SLOW PASS is what every 5th tick used to carry, and runs on a wake when
# TA_REFRESH_SLOW seconds (10) have passed since it last did, and always at the
# idle timeout: the event and follow hooks put back (install_event_hooks), the config re-read, tusage --update and
# the footer, the window names, the resurrect snapshot, tnotes sync while there are editors, and the forced
# reload that keeps the age column, the pane titles and the dead processes right.
# A config edited by hand is seen at the next of those.
# A DEAD LIST ENDS THE LOOP WITHOUT POLLING: every wake and every timeout asks
# kill -0 about the list process, and release_dash rings the channel on the way
# out. The five refused posts are kept for a list that is alive and not answering;
# a reload that was refused is retried every 2 s, the one place left that polls.
# AND THE STATUS BAR IS FED FROM HERE while this loop is answered. tmux ran
# `tagents --counts` every few seconds, and each run that was due was a whole list
# (about 38 programs and 75 forks) to count rows the list this loop reloads has
# already counted: list() leaves its tally in .counts.tally, and every pass turns
# the last one into the text of .counts.out and of the global tmux option
# @tagents_counts, which the status bar prints in place of running anything (see
# refresher_counts). The option is set only when its text changes and taken down
# when the last refresher ends, and by the list that closes when a refresher died
# without doing it (release_dash). While one is alive the bar does not count for
# itself at all (see counts).
# WHAT A KILLED PROCESS LEFT IN THE STATE DIRECTORY: the refresher's markers
# (.refresher.<pid>, .cfg, .start) and the temp files the list and the bar write
# before a rename (.counts.tally.<pid>, .counts.out.<pid>). Each is removed when
# its pid fails kill -0, one rm per stale file, and only at a refresher's start.
refresher_sweep() {
  local f n pid
  for f in "$STATE_DIR"/.refresher.[0-9]* "$STATE_DIR"/.counts.tally.[0-9]* "$STATE_DIR"/.counts.out.[0-9]*; do
    [ -e "$f" ] || continue
    n=${f##*/}; n=${n#.refresher.}; n=${n#.counts.tally.}; n=${n#.counts.out.}
    pid=${n%%.*}
    case $pid in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || rm -f "$f" 2>/dev/null
  done
}

refresher() {
  local port=${TA_PORT:-} dp fails=0 fl pub=""
  local snap="" rsnap="" ssnap="" pending=1 due body mark cfgmark ovl
  local startmark t0 live="" lasttl="" lasttext="" cdirty=1
  local cfgseen="" ovlseen="" cfgnow ovlnow nstate rstate="" sf
  local idle slow lastslow evq nap waiter="" outstanding="" seen="" gen ringed kind rc line
  local vtty lpid="" wt slowdue again="" strict claimed="" snap2 min lastpost owed=""
  [ -z "$port" ] && return 0
  idle=${TA_REFRESH_IDLE:-60}; slow=${TA_REFRESH_SLOW:-10}; min=${TA_REFRESH_MIN:-2}
  case $idle in ''|*[!0-9]*|0) idle=60 ;; esac
  # Two seconds at the least: the idle timeout is also the slow pass, and one a
  # second is the polling this loop replaced. (The loop that read its channel to
  # the end told that end from a timeout by the clock, which a one-second timeout
  # made impossible.)
  [ "$idle" -lt 2 ] && idle=2
  case $slow in ''|*[!0-9]*) slow=10 ;; esac
  # A reload at most every TA_REFRESH_MIN seconds, a whole number, one at the least:
  # the clock is the shell's SECONDS, which counts whole seconds.
  case $min in ''|*[!0-9]*|0) min=2 ;; esac
  lastpost=$((SECONDS - min))
  # One marker per refresher, in the state directory every writer already uses:
  # its time is "when the last reload was posted", and the second one is "when
  # the config was last read" (see below). They are named by the refresher's own
  # pid. One that is killed (kill -9, a reboot) leaves them behind, and so the
  # start sweeps what a dead pid left, before touching its own.
  refresher_sweep
  mark="$STATE_DIR/.refresher.$$"; cfgmark="$mark.cfg"
  # "When this refresher started": a tally older than it belongs to some earlier
  # picker, hours ago perhaps, and is never served (see refresher_counts).
  startmark="$mark.start"
  { : >"$startmark"; } 2>/dev/null
  # The per-host overlay is read by cfg_overlay from this same path.
  host_once
  cfg_overlay_for "${TA_HOST:-$HOST_S}"; ovl=$CFG_OVL
  # Touched before the first read of the config, so a write that lands while it
  # is being read is not older than the marker.
  { : >"$cfgmark"; } 2>/dev/null
  # Which file each of the two was at this read, empty when it was not there, for
  # the re-read on the slow pass: see the test there.
  [ -e "$CONFIG_FILE" ] && cfgseen=$CONFIG_FILE
  [ -e "$ovl" ] && ovlseen=$ovl
  # THE CONFIG IS LOADED IN THIS SHELL, not left to the first lookup. --refresher
  # is dispatched without a cfg_load, and cfg_get is almost always called inside
  # a $(...): the load it triggers there dies with the subshell, so every lookup
  # parsed the YAML again (an awk and a hostname each) while usage_on, which
  # memoises in THIS shell, answered once from whatever the file said at its first
  # call. A config edited under a running refresher then turned the footer on and
  # the tusage update off at the same time. Loaded here, both read the one copy,
  # and the re-read on the slow pass below replaces it for both at once.
  cfg_load
  # THE CLOCK, READ ONCE. The stamp on the bar's cache is written on every pass
  # and a date per pass is a program per pass; SECONDS counts for free, so the
  # epoch of any later moment is t0 + SECONDS.
  t0=$(( $(date +%s) - SECONDS ))
  # THE PORT IS ONLY KNOWN IN HERE. fzf hands $FZF_PORT to the start: bind and
  # to nothing else, so --follow — fired from a tmux hook in a window that has
  # never heard of this list — has no way to ask for it (it moves the cursor with it). It is published on the
  # list pane instead, and taken down again when this loop ends: the refresher
  # is the one process that knows when the list has really gone, which makes the
  # option a live claim rather than a leftover pointing at a dead port.
  dp=$(dash_pane)
  # No claim before the first post has been answered: a port is only worth
  # publishing once the list behind it is known to be listening — see below.
  # THE ACCOUNTS TRAVEL WITH THE UPDATE TOO. usage_env is what hands tusage the
  # profile names and the directory rules; every reader in usage.sh calls it,
  # but the writer here did not — so each slow pass rebuilt the account map under
  # config-dir labels (`default`, `d`), the next read rebuilt it back, and the
  # meter was fetched a second time under a name nothing reads.
  usage_on && usage_env
  # The pieces of the bar's text that move slowly, read once here and again on
  # every slow pass (see counts_parts). After usage_env: the month line needs it.
  counts_parts
  # THE LIST IS WATCHED BY ITS PROCESS, not by its answers. fzf's start bind hands
  # fzf's own pid in TA_LIST_PID (see dash; a popup has no pane to ask); started by
  # hand, the list pane's own claim is what names it.
  lpid=${TA_LIST_PID:-}
  case $lpid in ''|*[!0-9]*)
    lpid=""
    [ -n "${TMUX_PANE:-}" ] && lpid=$(tmux show -pv -t "$TMUX_PANE" @tagents_list 2>/dev/null) ;;
  esac
  case $lpid in *[!0-9]*) lpid="" ;; esac
  migrate_seats
  install_event_hooks
  # The FIFO the waiter answers through (evq), and one nobody ever writes to (nap),
  # which only a read with a timeout waits on: bash 3.2 has no builtin sleep, and a
  # sleep would be a program. Both are opened for reading AND writing here: a
  # waiter that opens evq for writing finds a reader, and so never blocks, and the
  # loop never reads an end of file.
  evq="$mark.evq"; nap="$mark.nap"
  if ! mkfifo "$evq" "$nap" 2>/dev/null; then
    rm -f "$mark" "$cfgmark" "$startmark" "$evq" "$nap" 2>/dev/null
    return 0
  fi
  exec 3<>"$evq" 4<>"$nap"
  lastslow=$SECONDS
  while :; do
    if [ -n "$again" ]; then
      # A pass that posted is looked at once more, a second on: see above.
      again=""; kind=verify
    else
      if [ -n "$pending" ]; then
        wt=2; kind=retry
      elif [ -n "$owed" ]; then
        # A change that came within TA_REFRESH_MIN of the last post: what is left of
        # the interval, a second at the least.
        wt=$((min - (SECONDS - lastpost))); [ "$wt" -lt 1 ] && wt=1; kind=retry
      else
        wt=$idle; kind=idle
      fi
      # Not before the first snapshot has said what to wait for. A wait that timed
      # out is still the one outstanding, and is read again, not started again.
      if [ -z "$outstanding" ] && [ -n "$seen" ]; then ev_wait; fi
      line=""
      read -r -t "$wt" -u 3 line; rc=$?
      if [ "$rc" = 0 ]; then
        outstanding=""
        # Anything but a clean end is tmux gone, which ends the loop as the end of
        # the channel always did.
        [ "$line" = 0 ] || break
        kind=wake
      fi
    fi
    # The list is gone: nothing left to keep current.
    if [ -n "$lpid" ] && ! kill -0 "$lpid" 2>/dev/null; then break; fi
    slowdue=""
    case $kind in
      idle) slowdue=1 ;;
      # Not the second look: slow work on it would be done twice for one wake.
      wake) [ $((SECONDS - lastslow)) -ge "$slow" ] && slowdue=1 ;;
    esac
    if [ -n "$slowdue" ]; then
      lastslow=$SECONDS
      # THE HOOKS ARE PUT BACK. One tmux call, and it heals a ring that was lost for
      # good: a .tmux.conf that sets a hook of ours without an index wipes the
      # event's whole list at the next re-source, [42] included, and nothing would
      # ring for that event again. See EV_EVENTS.
      install_event_hooks
      # THE STAMP IS RENEWED BEFORE THE SLOW WORK OF THIS PASS, not after it: a
      # tusage --update can take longer than COUNTS_EVERY, and a stamp that aged
      # past it in there would make the bar compute for itself in the middle of
      # a loop that is keeping it. Only while the stamp is being kept at all.
      [ -n "$live" ] && counts_stamp
      # A CONFIG CHANGED UNDER A RUNNING REFRESHER IS READ AGAIN. The config is
      # memoised for the life of a process, and a refresher lives as long as its
      # list — one started before usage was turned off went on running tusage
      # for a day. Not older than the marker is "changed", as above; the marker
      # is its own, because the one for the list is touched on every reload.
      # A file that is NOT THERE is never newer than anything, so a config or an
      # overlay that was deleted is not seen by the time test (`-nt` is true when
      # its right-hand file does not exist): whether each existed at the last read
      # is remembered, and a change of that is a change too. Deleting the overlay
      # that holds the usage: block is how usage gets turned off, and the update
      # went on running.
      # The memos are cleared with it: the usage switch is asked once per
      # process, and a config that has gone away must read as empty, not as the
      # last one that was there.
      # A config.toml that appeared beside the config.yaml being read, or an
      # overlay that changed format, is another file: which one is remembered,
      # not only whether there was one.
      cfgnow=""; ovlnow=""
      cfg_resolve; cfg_overlay_for "${TA_HOST:-$HOST_S}"; ovl=$CFG_OVL
      [ -e "$CONFIG_FILE" ] && cfgnow=$CONFIG_FILE
      [ -e "$ovl" ] && ovlnow=$ovl
      if ! [ "$cfgmark" -nt "$CONFIG_FILE" ] || ! [ "$cfgmark" -nt "$ovl" ] ||
         [ "$cfgnow" != "$cfgseen" ] || [ "$ovlnow" != "$ovlseen" ]; then
        { : >"$cfgmark"; } 2>/dev/null
        cfgseen=$cfgnow; ovlseen=$ovlnow
        cfg_reset; USAGE_ON=
        cfg_load
        usage_on && usage_env
      fi
      usage_on && tusage --update >/dev/null 2>&1
      # What the update moved is in the burn and the month line, and the config
      # that was just read again may have gained or lost its problem.
      counts_parts; cdirty=1
      # The footer is one of fzf's own frames, not a row, so reload-sync leaves
      # it alone — it has to be pushed. On this pass and no other: the figure it
      # carries only moves when the index it is read from does.
      [ -n "$CP_FOOTER" ] && post_fzf "$port" "change-footer($CP_FOOTER)" || :
      # Windows named after their agents. Unthrottled here — this is already the
      # slow pass, and there is one refresher per list — while the status bar path
      # throttles itself, since it has no pass of its own.
      sync_window_names >/dev/null 2>&1
      # The resurrect snapshot, which the status bar used to take whenever it
      # computed the counts. While this loop keeps the stamp it does not compute
      # them, so the snapshot rides the pass that already sweeps the names; its
      # own throttle (resurrect.every) still decides whether it is due.
      if resurrect_due; then resurrect_save >/dev/null 2>&1 & fi
    fi
    # THE SNAPSHOT IS TAKEN AFTER THE SLOW WORK ABOVE, so whatever it moved in tmux
    # is already in it and does not cost a reload on the next pass for something
    # the forced one below has just drawn.
    # THE COUNT OF RINGS IS READ IN THE SAME CALL, after the snapshot and as its last
    # line: the 'g' keeps it a line even when the option has never been set (a
    # command substitution would eat an empty one), and it stays OUT of the snapshot
    # the passes compare, or every ring would look like a change. What the wait asks
    # for is this number, so a ring from here on is not slept through (see above).
    snap=$(tmux list-panes -a -F "$REFRESH_SNAP_FMT" \; display -p 'g#{@tagents_evgen}:#{@tagents_viewport_tty}' 2>/dev/null)
    gen=${snap##*$'\n'}; vtty=""
    case $gen in
      g*) gen=${gen#g}; case $gen in *:*) vtty=${gen#*:}; gen=${gen%%:*} ;; esac
          case $snap in *$'\n'*) snap=${snap%$'\n'*} ;; *) snap="" ;; esac ;;
      *) gen=0 ;;
    esac
    case $gen in ''|*[!0-9]*) gen=0 ;; esac
    # In the cockpit (the viewport's tty is set) a viewport that was killed is started again, on each wake and each pass; the tty rides on the snapshot's call, so a popup's refresher, with no cockpit up, pays nothing.
    [ -z "$vtty" ] || cockpit_restore viewport
    ringed=""; [ "$gen" != "$seen" ] && ringed=1
    seen=$gen
    if [ -n "$slowdue" ]; then
      # Editors are looked after only while there are some: a pane carries @ta_notes_for, or an older tnotes left its parking session.
      if [ -x "${SELF%/*}/tnotes" ] && { snap_has_editor || tmux has-session -t =ta-notes 2>/dev/null; }; then
        "${SELF%/*}/tnotes" sync >/dev/null 2>&1 &
      fi
    fi
    # WHETHER THERE IS ANYTHING TO DRAW. The marker is touched immediately BEFORE
    # the post, not after: a write that lands while the list is running is then
    # not older than it, and is seen on the next pass. A reload that was refused
    # has already touched the marker, so it is remembered in $pending instead.
    # A DELETED STATE FILE is invisible to refresh_changed (and $STATE_DIR itself
    # is left out of it), and forget_agent removes <key>.tsv without a reload, so
    # the files are counted: a count other than the one at the last answered
    # reload is a change. A glob that matched nothing stays a literal and is not
    # counted.
    nstate=0
    for sf in "$STATE_DIR"/[0-9]*.tsv "$STATE_DIR"/s-*.tsv; do
      [ -e "$sf" ] && nstate=$((nstate + 1))
    done
    due=""
    # Only the second look is strict: see refresh_changed. Not when a ring has come
    # in since the pass before it: that ring's write may be in the second of the
    # marker, which only the plain look counts, and the pass is then the wake for it.
    strict=""; [ "$kind" = verify ] && [ -z "$ringed" ] && strict=1
    if [ -n "$pending" ] || [ -n "$owed" ] || [ -n "$slowdue" ] || [ "$snap" != "$rsnap" ] ||
       [ "$nstate" != "$rstate" ] || refresh_changed "$mark" "$ovl" "$strict"; then
      if [ -z "$pending" ] && [ $((SECONDS - lastpost)) -lt "$min" ]; then
        # A reload went out less than TA_REFRESH_MIN seconds ago: this one is owed,
        # and made by the wait above when the interval is over. Nothing is touched
        # and nothing remembered as drawn, so the next pass finds it all still due.
        # A refused post is not held back: it is retried on its own 2 s clock.
        owed=1
      else
        owed=""
        due=1
        again=1
        { : >"$mark"; } 2>/dev/null
        # ONE FAILED POST IS NOT A DEAD LIST. curl comes back non-zero for a refused
        # connection, and fzf refuses one whenever it is between reloads or busy with
        # a child of its own — so breaking on the first failure left a live dashboard
        # with no refresher behind it and nothing to say why. Five in a row, two
        # seconds apart, is a list that never answers, which is a list that has
        # really gone (or, when it has, kill -0 above has said so already). Nothing
        # is posted when nothing is due: a list that is not asked is not tested.
        if ! post_fzf "$port" "reload-sync($SELF --list)"; then
          fails=$((fails + 1))
          # A list that does not answer is not one whose tally is current: the stamp
          # stops here, and the bar takes the counting back within COUNTS_EVERY.
          live=""
          pending=1
          # A LIST THAT DOES NOT ANSWER HAS NO CLAIM TO MAKE. The five-strike grace
          # keeps the loop alive through a busy fzf, but a refresher whose fzf is
          # already gone was re-publishing its dead port on the pane the NEXT list
          # had claimed, every pass until it quit — the two fought over the option
          # and the cursor moves of --follow were posted into a closed port. So a refused post gives the claim
          # up at once (if it is still ours) and the claim is only ever re-made below,
          # after a post that was answered.
          if [ -n "$pub" ] &&
             [ "$(tmux show -pv -t "$pub" @tagents_port 2>/dev/null)" = "$port" ]; then
            tmux set -up -t "$pub" @tagents_port 2>/dev/null
          fi
          pub=""
          again=""
          [ "$fails" -ge 5 ] && break
          continue
        fi
        fails=0
        lastpost=$SECONDS
        # What the reload saw is what the next snapshot is compared with.
        rsnap=$snap; rstate=$nstate; pending=""
      fi
    fi

    # THE BAR'S TEXT IS TAKEN FROM THE TALLY ON EVERY PASS, not only after a post: the
    # reload is asynchronous, so the tally read right after the post is the previous
    # reload's, and the second look a second on is what finds the new one. Without
    # it the bar showed the state before the last change until the next change or
    # the idle pass, up to a minute. It is builtins and one tmux set when the text
    # moved, so a pass where nothing did costs nothing. A reload that takes longer
    # than the second look leaves the bar one pass behind, and the next pass (the
    # idle one at the latest) catches it. Not while a post is refused: a list that
    # does not answer is not one whose tally is current.
    if [ -z "$pending" ]; then refresher_counts; fi

    # THE SECOND LOOK THAT FOUND NOTHING MOVES THE MARKER ON. A write in the same
    # second as the reload's touch counts as a change at the next wake (bash 3.2
    # compares whole seconds, see refresh_changed), so without this every event
    # would be drawn twice, the second time on the wake after it. Not when a ring
    # has come in since the pass before: that pass was the plain look, with the old
    # marker (see strict), and a post that is owed keeps its marker too.
    if [ "$kind" = verify ] && [ -z "$due" ] && [ -z "$owed" ] && [ -z "$ringed" ]; then
      { : >"$mark"; } 2>/dev/null
    fi

    # THE PORT CLAIM IS ONLY CHECKED WHEN TMUX MOVED. Every pane and option it reads
    # is in the snapshot, so an unchanged snapshot means the same answers as last
    # time — and each of these is a tmux round-trip or several.
    # The claim counts as tmux state: another refresher overwriting it changes
    # the snapshot, and claim_port makes it again within the pass. Run anyway when
    # no claim is held (it was never made, or was given up above), and on the slow
    # pass for whatever a snapshot cannot show (a list process that has died).
    if [ "$snap" != "$ssnap" ] || [ -z "$pub" ] || [ -n "$slowdue" ]; then
      ssnap=$snap
      dp=$(dash_pane)
      # Re-made whenever the pane moves or the option changes: see claim_port.
      claim_port
      # THE CLAIM IS PART OF THE SNAPSHOT, and made here, after it was taken: left
      # at that, the next look would find the snapshot moved by this loop's own
      # write and draw the list again for it. So when the claim was written the
      # snapshot is taken afresh, and if what was drawn matched the one before it,
      # it matches this one too.
      if [ -n "$claimed" ]; then
        claimed=""
        snap2=$(tmux list-panes -a -F "$REFRESH_SNAP_FMT" 2>/dev/null)
        [ "$rsnap" = "$snap" ] && rsnap=$snap2
        snap=$snap2; ssnap=$snap2
      fi
    fi
    # THE DELAY THAT COALESCES. A burst of events (a pane switch fires three hooks,
    # a busy Claude a tool call every few hundred milliseconds) rings the channel
    # many times, and a pass for each would be the polling this replaced. The loop
    # lets a second go by after every wake, on a read nobody answers, and what rang
    # meanwhile is one count to compare.
    if [ -n "$again" ] || [ "$kind" = wake ]; then
      read -r -t 1 -u 4 line 2>/dev/null || :
      # Where a list that has just closed is found out: release_dash rang the
      # channel from inside its own exit, so the process was still there for the
      # pass and is gone by now.
      if [ -n "$lpid" ] && ! kill -0 "$lpid" 2>/dev/null; then break; fi
    fi
  done
  # The waiter first, then one ring: the `tmux` it is blocked in is a process of its
  # own and outlives it until the channel is signalled. The ring is plain, with no
  # count: the waiter that is freed is ours, and it has nobody left to answer.
  if [ -n "$waiter" ]; then
    kill "$waiter" 2>/dev/null
    wait "$waiter" 2>/dev/null
    [ -n "$outstanding" ] && tmux wait-for -S tagents-ev 2>/dev/null
  fi
  exec 3<&- 4<&-
  rm -f "$mark" "$cfgmark" "$startmark" "$evq" "$nap" 2>/dev/null
  # Only ever taken down by its owner. A refresher outlived by its fzf — the
  # list respawned, five posts refused — must not wipe the claim the NEXT
  # refresher has already made on the same pane: that is how a live dashboard
  # ended up with no port and a marker that waited for the tick again.
  [ -n "$pub" ] && [ "$(tmux show -pv -t "$pub" @tagents_port 2>/dev/null)" = "$port" ] &&
    tmux set -up -t "$pub" @tagents_port 2>/dev/null
  # The bar's text goes with the last refresher: while another one is alive it
  # is the one keeping the option, and a bar with no option runs tagents --counts.
  other_refresher || tmux set -gu @tagents_counts 2>/dev/null
  return 0
}

# ONE WAIT FOR A RING, in the background, answering through the FIFO the loop reads.
# The condition and the wait are ring_wait (core.sh): the count of rings is compared with the one the
# last snapshot saw, and only if it has not moved does the wait begin. Moved already,
# the command ends at once and the loop is woken for a ring that came in since. The
# status is a line, 0 for either, and anything else when tmux is gone (see the
# open of the FIFO below, which is not allowed to wait). Uses the
# caller's seen, evq, waiter and outstanding. The descriptors of the loop are shut
# for it: a tmux that outlives the loop must not hold them open.
ev_wait() {
  (
    ring_wait "$seen"
    # Opened for reading AND writing: a plain write-only open of a FIFO blocks until
    # somebody reads it, and the loop that was to read this may be gone (killed with
    # -9, a TERM it has no trap for) and its tmux with it. This waiter would then sit
    # in the open for ever, a process for nobody. Opened this way it never waits, and
    # a line nobody reads goes with the FIFO.
    { printf '%s\n' "$?" 1<>"$evq"; } 2>/dev/null
  ) 3<&- 4<&- &
  waiter=$!; outstanding=1
}

# THE STAMP ON THE BAR'S CACHE, in the epoch the refresher's own clock says. The
# braces are for a state directory that is gone: the error of a failed redirection
# is printed before a 2>/dev/null on the printf could apply. Uses t0.
counts_stamp() {
  { printf '%s\n' "$((t0 + SECONDS))" >"$COUNTS_STAMP"; } 2>/dev/null
}

# THE BAR'S CACHE FROM THE LIST'S TALLY, on every reload whose post was answered.
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
  slurp tl "$f"
  [ -n "$tl" ] || return 0
  if [ -n "$cdirty" ] || [ "$tl" != "$lasttl" ] || [ ! -e "$COUNTS_OUT" ]; then
    # The trailing newlines of the burn and the month line belong to the text,
    # and a command substitution would eat them: a character goes after, and off.
    text=$(counts_compose "$tl"; printf .); text=${text%.}
    if [ "$text" != "$lasttext" ] || [ ! -e "$COUNTS_OUT" ]; then
      if { printf '%s' "$text" >"$COUNTS_OUT.$$"; } 2>/dev/null &&
         mv -f "$COUNTS_OUT.$$" "$COUNTS_OUT" 2>/dev/null; then
        lasttext=$text
        # The same text for the status bar to print without running anything, set
        # only now that it has changed: the bar does not ask tmux for it again.
        tmux set -g @tagents_counts "$text" 2>/dev/null
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
  tmux set -p -t "$dp" @tagents_port "$port" 2>/dev/null && pub=$dp && claimed=1
  return 0
}




# WHAT TMUX DOES TO ITS PANES, WINDOWS AND SESSIONS RINGS THE CHANNEL. The list
# draws them and nothing here polls: a hook runs `wait-for -S` for tagents-ev (the
# refresher), inside the tmux server, which starts no program at all. The four
# focus events carry only this ring; the one program a switch may start is
# `tagents --follow`, from the two follow hooks of follow.sh (install_follow_hooks)
# at index 43, beside the ring at 42.
#
# AT A FIXED INDEX, so that it neither takes the place of a hook of the owner's own
# (set-hook -g without an index REPLACES the event's whole list, and one at [0] is
# somebody's) nor piles up when this runs again: it runs at every refresher start
# and every slow pass, and setting [42] twice is setting it once. 42 is an arbitrary
# number nobody picks by accident; ./tagents --help does not need to know it.
#
# THE EVENTS are the ones that exist. tmux 3.7b has no after-swap-pane,
# after-join-pane, after-break-pane, after-move-window or after-respawn-pane (an
# after-<command> hook exists for some commands only, and these are not among
# them), so the layout is watched instead: window-layout-changed fires for a swap,
# a join or a break, for both windows when they differ. A respawned pane changes
# nothing the list draws until the slow pass.
EV_HOOK_INDEX=42
# EV_SIGNAL, the text every one of them runs, is in core.sh beside the count it
# bumps (@tagents_evgen).
#
# A `.tmux.conf` that says `set-hook -g <event> ...` with no index replaces the
# event's whole list at every re-source, and takes tagents' entries with it, the
# follow hooks too. install_event_hooks runs again on every slow pass of the
# refresher (see there) and puts both back, so a wiped [42] and a wiped [43] are
# back within the slow interval.
EV_EVENTS='after-new-window after-split-window after-new-session after-kill-pane pane-exited pane-died window-linked window-unlinked session-closed window-renamed session-renamed window-layout-changed client-attached client-detached pane-focus-in after-select-pane after-select-window client-session-changed'
install_event_hooks() {
  local ev i=0 args=()
  for ev in $EV_EVENTS; do
    [ "$i" -gt 0 ] && args[${#args[@]}]=';'
    args[${#args[@]}]=set-hook; args[${#args[@]}]=-g
    args[${#args[@]}]="$ev[$EV_HOOK_INDEX]"; args[${#args[@]}]="$EV_SIGNAL"
    i=$((i + 1))
  done
  # One call for all of them. A command list stops at the first that fails (an
  # event this tmux does not know), so the second try is one call each. The follow
  # hooks go in after either way: they are put back with the ring or not at all.
  if ! tmux "${args[@]}" 2>/dev/null; then
    for ev in $EV_EVENTS; do
      tmux set-hook -g "$ev[$EV_HOOK_INDEX]" "$EV_SIGNAL" 2>/dev/null
    done
  fi
  install_follow_hooks
  cockpit_up && cockpit_guard_install
  return 0
}

# IS ANOTHER REFRESHER ALIVE? By the start marker each one keeps, as the sweep
# finds the dead ones (refresher_alive, core.sh, which the status bar's --counts
# asks as well). The last to end takes @tagents_counts down.
other_refresher() {
  refresher_alive "$$"
}
