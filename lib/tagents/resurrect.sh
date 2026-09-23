# lib/tagents/resurrect.sh — what comes back after a reboot
#
# The snapshot a restore works from: resurrect_rows (one A row per live chat, a D row when the sidebar is up — a docked chat filed at its home seat, never at the sidebar), resurrect_save (a full replacement, never twice the same, the newest RESURRECT_KEEP kept), resurrect_latest/resurrect_pick (the newest snapshot, and the newest one written before this tmux server started — the one a restore wants), resurrect_rows_cmd (the raw rows, for the tests and for a curious person), and the two triggers: resurrect_soon after a launch or a kill, resurrect_due for the status bar. The section banner heads the file.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# ---------------------------------------------------------------------------
# resurrect: every chat back where it was after the tmux server is gone
#
# tmux-resurrect already brings back the sessions, the windows, the splits, the
# cwds and the window names — and a Claude as an idle shell in the right place,
# because it cannot know what to start there. What it lacks is the one fact that
# makes a chat a chat: which conversation, on which login, with which model.
# The state records know that, but only while the chat runs — SessionEnd deletes
# them — and they are keyed by pane id, which starts again from %0 after a
# reboot. So a snapshot is taken here, KEYED BY SESSION ID and saying WHERE each
# chat lived, and it is a full replacement every time: one list-panes joined with
# the records, cheap enough to run every few minutes and after every launch or
# kill, so there is never a merge to get wrong.
#
# WHICH SNAPSHOT A RESTORE USES is the newest written BEFORE this tmux server
# started (#{start_time}, the same signal continuum judges by). The captures that
# run after the boot — nothing at first, then the first new chats — are newer
# and can never shadow the set that was running before it, and nothing has to be
# marked as used. A file is named after the second it was written; one that says
# exactly what the newest already says is not written at all (tmux-resurrect's
# own rule), and only the newest RESURRECT_KEEP stay.
# ---------------------------------------------------------------------------
RESURRECT_DIR="$STATE_DIR/resurrect"
RESURRECT_LOG="$STATE_DIR/resurrect.log"
RESURRECT_KEEP=${TA_RESURRECT_KEEP:-50}
RESURRECT_STAMP="$STATE_DIR/.resurrect.ts"
RESURRECT_LOCK="$STATE_DIR/.resurrect.lock"

# One A row per live chat and a D row when the sidebar is up. A docked chat is
# recorded at its HOME (the placeholder's seat), never at the sidebar it sits in.
# The window's own name travels with @tagents_name only when the two still agree:
# that is how the naming sweep tells its name from one a person typed, and a
# restore must not hand a typed name back to the sweep.
resurrect_rows() {
  local map p pid f sid cwd tr cfgd hascfg home model argv
  local sess widx pidx cur slot docked notes tname dir wname
  # |@| not tab (collect() in state.sh says why); the window name goes last
  # and is rejoined the way collect() rejoins the pane title.
  # #{@tagents} is the sidebar WINDOW's marker (ensure_dash sets it); a pane
  # format expands window options, so every pane of that window carries it.
  map=$(tmux list-panes -a -F "#{pane_id}|@|#{session_name}|@|#{window_index}|@|#{pane_index}|@|#{pane_current_command}|@|#{@tagents}|@|#{@tagents_slot}|@|#{@tagents_docked}|@|#{@ta_notes}|@|#{@tagents_name}|@|#{pane_current_path}|@|#{window_name}" 2>/dev/null)
  # A flag, not `exit`: the awks below read to the end of what printf writes,
  # so no producer here is ever cut off under pipefail.
  printf '%s\n' "$map" | awk -F'\\|@\\|' -v OFS="$TAB" '!d && $6 == "1" { print "D", $2, $3; d = 1 }'
  # Every pane the ps walk vouches for (with the claude pid) first, then the
  # ones only the command name vouches for (no pid, so no argv); awk keeps the
  # first line per pane, so a pane known both ways keeps its pid.
  { live_pane_pids; live_panes | sed "s/\$/$TAB/"; } | awk -F"$TAB" '!s[$1]++' |
    while IFS="$TAB" read -r p pid; do
      IFS="$US" read -r sid cwd tr cfgd hascfg < <(rec_row "${p#%}")
      [ -n "$sid" ] || continue                     # no record yet: nothing to resume by
      f=$(printf '%s\n' "$map" | awk -F'\\|@\\|' -v OFS="$US" -v p="$p" \
            '!d && $1 == p { w = $12; for (i = 13; i <= NF; i++) w = w "|@|" $i; print $2, $3, $4, $5, $7, $8, $9, $10, $11, w; d = 1 }')
      IFS="$US" read -r sess widx pidx cur slot docked notes tname dir wname <<EOF
$f
EOF
      [ -n "$sess" ] && [ "$slot" != 1 ] || continue
      if [ -n "$docked" ]; then
        home=$(parked_slot "$p"); [ -n "$home" ] || continue
        IFS="$US" read -r sess widx pidx tname wname < <(printf '%s\n' "$map" |
          awk -F'\\|@\\|' -v OFS="$US" -v p="$home" \
            '!d && $1 == p { w = $12; for (i = 13; i <= NF; i++) w = w "|@|" $i; print $2, $3, $4, $10, w; d = 1 }')
      fi
      [ "$tname" = "$wname" ] || tname=""
      model=$(awk -F"$TAB" 'NR == 1 { print $2; exit }' "$STATE_DIR/model/$sid.tsv" 2>/dev/null)
      argv=""; [ -n "$pid" ] && argv=$(ps -o args= -p "$pid" 2>/dev/null | tr '\t\n' '  ')
      printf 'A\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$sid" "$cfgd" "$hascfg" "$sess" "$widx" "$pidx" \
        "$(printf '%s' "$wname" | tr '\t' ' ')" "$(printf '%s' "$tname" | tr '\t' ' ')" \
        "$dir" "${docked:+1}" "${notes:+1}" "$model" "$argv"
    done
}

resurrect_latest() {  # newest snapshot, or nothing (exit 1)
  # No `head -1` after sort: under pipefail an early close is a failure on
  # exactly the runs that found something (sidebar.sh:138-141).
  ls -1 "$RESURRECT_DIR" 2>/dev/null | grep -E '^[0-9]+\.tsv$' | sort -rn |
    awk -v d="$RESURRECT_DIR" 'NR == 1 { print d "/" $0 }' | grep .
}

# Strictly before: a capture in the server's own first second already saw the
# new server — nothing live yet — and must not stand in for the set it replaced.
resurrect_pick() {  # the newest snapshot written BEFORE this tmux server started
  local start
  start=$(tmux display -p '#{start_time}' 2>/dev/null)
  case ${start:-x} in ''|*[!0-9]*) return 1 ;; esac
  ls -1 "$RESURRECT_DIR" 2>/dev/null | grep -E '^[0-9]+\.tsv$' | sort -rn |
    awk -F. -v s="$start" -v d="$RESURRECT_DIR" '!hit && $1 + 0 < s + 0 { print d "/" $0; hit = 1 }' | grep .
}

# Written aside and moved into place, so a restore never reads half a capture;
# a capture that failed leaves the newest good one where it was.
resurrect_save() {  # [ignored args: post-save-layout passes the state-file path]
  local tmpf last now f
  mkdir -p "$RESURRECT_DIR" 2>/dev/null || return 1
  tmpf="$RESURRECT_DIR/.tmp.$$"
  resurrect_rows >"$tmpf" 2>/dev/null || { rm -f "$tmpf"; return 1; }
  if last=$(resurrect_latest) && cmp -s "$tmpf" "$last"; then rm -f "$tmpf"; return 0; fi
  now=$(date +%s)
  mv -f "$tmpf" "$RESURRECT_DIR/$now.tsv" 2>/dev/null || { rm -f "$tmpf"; return 1; }
  ls -1 "$RESURRECT_DIR" 2>/dev/null | grep -E '^[0-9]+\.tsv$' | sort -rn |
    awk -v k="$RESURRECT_KEEP" 'NR > k' | while IFS= read -r f; do rm -f "$RESURRECT_DIR/$f"; done
  return 0
}

# The rows as a restore would read them — the pre-start pick by default, the
# newest with `latest`, or any file by name. Machine-readable on purpose: rows on
# stdout, the reason there are none on stderr, so an empty answer stays empty.
resurrect_rows_cmd() {  # [file|latest]
  local f
  case ${1:-} in
    '')     f=$(resurrect_pick) || { echo "tagents: no snapshot from before this tmux server started" >&2; return 1; } ;;
    latest) f=$(resurrect_latest) || { echo "tagents: no snapshot yet" >&2; return 1; } ;;
    *)      f=$1 ;;
  esac
  [ -r "$f" ] || { echo "tagents: no snapshot at $f" >&2; return 1; }
  cat "$f"
}

resurrect_soon() { ( sleep 5; resurrect_save ) >/dev/null 2>&1 & }   # after a launch: the record needs SessionStart first

# How often the status bar captures: resurrect.every in the config, 300 s when
# it is not there, TA_RESURRECT_EVERY over both. 0 is off (see due_every).
resurrect_every() { local e; e=$(cfg_get resurrect.every) || e=300; printf '%s' "${TA_RESURRECT_EVERY:-$e}"; }
resurrect_due()   { due_every "$RESURRECT_STAMP" "$(resurrect_every)"; }

# Reopening the tnotes editor of every restored chat. A no-op for now: defined
# ahead of the restore that calls it, so that call never has to be guarded.
resurrect_notes() {  # <restored panes that had an editor…>
  return 0
}
