# lib/tagents/resurrect.sh — what comes back after a reboot
#
# The snapshot a restore works from: resurrect_rows (one A row per live chat, a D row when the sidebar is up — a docked chat filed at its home seat, never at the sidebar), resurrect_save (a full replacement, never twice the same, the newest RESURRECT_KEEP kept), resurrect_latest/resurrect_pick (the newest snapshot, and the newest one written before this tmux server started — the one a restore wants), resurrect_rows_cmd (the raw rows, for the tests and for a curious person), and the two triggers: resurrect_soon after a launch or a kill, resurrect_due for the status bar. Then the restore that reads it: resurrect_place (the pane a chat goes back into — its own idle shell, else a new window, else a new session), resurrect_restore (every row not already running, resumed on the login it ran on with its model and effort, and a report per row), with resurrect_auto_on and resurrect_has_transcript deciding whether to run at all and which rows are worth it. The section banner heads the file.
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
#
# THE RESTORE PUTS `claude --resume` BACK AT THE SAME COORDINATES, and never
# rebuilds what tmux-resurrect already did: the idle shell it left where a chat
# was is replaced (respawn-pane, so nothing is typed into a shell that may still
# be reading its rc files), and only a missing or busy seat gets a new window or
# a new session. The account is the one the chat ran on, never the rules, and
# never a dialog — a hook has no client to ask. Anything already running, by
# session id, is left alone, so running it twice is harmless.
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

# Whether the tmux-resurrect hook may restore on its own. On unless the config
# says one of the four words for off: a reboot that brings nothing back because
# a key was misspelt is the worse surprise, and --check names the misspelling.
resurrect_auto_on() {  # resurrect.auto: absent or anything but the four words for off = on
  local v; v=$(cfg_get resurrect.auto) || return 0
  case $v in false|no|0|off) return 1 ;; esac
}

# A conversation --resume cannot find opens an empty chat that looks restored.
# Claude Code moves transcripts between project dirs, so the recorded path is
# not trusted: any project of the login that holds the session id will do.
resurrect_has_transcript() {  # <config dir root> <sid>
  set -- "$1"/projects/*/"$2".jsonl; [ -e "$1" ]
}

# Where a chat goes back: its own pane when tmux-resurrect put an idle shell
# there, a new window in its session when that pane is busy or gone, a new
# session when even that is gone. Prints the pane id. A pane with any tagents or
# tnotes marker is somebody's seat or editor, never an idle shell to replace.
resurrect_place() {  # <session> <window index> <pane index> <dir> <cmd>
  local sess=$1 widx=$2 pidx=$3 dir=$4 cmd=$5 t cur
  if ! tmux has-session -t "=$sess" 2>/dev/null; then
    tmux new-session -d -s "$sess" -x 200 -y 50 -c "$dir" -P -F '#{pane_id}' "$cmd" 2>/dev/null
    return
  fi
  t="=$sess:$widx.$pidx"
  cur=$(tmux display -p -t "$t" '#{pane_current_command}|@|#{@tagents}#{@tagents_slot}#{@tagents_docked}#{@ta_notes_for}' 2>/dev/null)
  if [ -n "$cur" ] && is_shell_cmd "${cur%%|@|*}" && [ -z "${cur#*|@|}" ]; then
    tmux respawn-pane -k -t "$t" -c "$dir" "$cmd" 2>/dev/null &&
      tmux display -p -t "$t" '#{pane_id}' 2>/dev/null
    return
  fi
  tmux new-window -d -t "=$sess:" -P -F '#{pane_id}' -c "$dir" "$cmd" 2>/dev/null
}

# The restore: every A row of the snapshot that is not running already, resumed
# through agent_cmd exactly as a launch from the list would be, then the
# dashboard when it was up. One line per row says what happened to it — the
# only account of a restore a hook ever gives, so it goes to RESURRECT_LOG then.
# The lock keeps a hook and a hand-typed run from resuming the same chat twice.
resurrect_restore() {  # [--dry-run] [--auto] [--from <file>|latest]
  local dry=0 auto=0 file="" live n=0 k=0 total notes_panes=""
  local t sid cfgd hascfg sess widx pidx wname tname dir docked notes model argv
  local prof cmd pane note eff wid
  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run) dry=1 ;;  --auto) auto=1 ;;  --from) shift; file=${1:-} ;;
      *) echo "tagents --resurrect: unknown option $1" >&2; return 2 ;;
    esac; shift
  done
  if [ "$auto" = 1 ]; then
    resurrect_auto_on || return 0
    exec >>"$RESURRECT_LOG" 2>&1          # a hook has no terminal; the log is the report
    printf '\n== %s ==\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  fi
  case $file in
    '')     file=$(resurrect_pick) || { echo "tagents: no snapshot from before this tmux server started — nothing to resurrect"; return 0; } ;;
    latest) file=$(resurrect_latest) || { echo "tagents: no snapshot yet"; return 0; } ;;
  esac
  [ -s "$file" ] || { echo "tagents: nothing recorded in $file"; return 0; }
  [ "$dry" = 1 ] || lock_dir "$RESURRECT_LOCK" 120 || { echo "tagents: another resurrect is running"; return 1; }
  live=$(live_sids | tr '\n' ' ')
  total=$(awk -F"$TAB" '$1 == "A"' "$file" | wc -l | tr -d ' ')
  # Not IFS=TAB on the raw line: an empty field would collapse (see collect()
  # in state.sh), so the rows are re-joined with US first.
  while IFS="$US" read -r t sid cfgd hascfg sess widx pidx wname tname dir docked notes model argv; do
    note=""
    case " $live " in *" $sid "*) echo "– $sess:$widx ${tname:-$wname}: already running"; k=$((k + 1)); continue ;; esac
    if [ "$hascfg" = 1 ] && ! resurrect_has_transcript "${cfgd:-$HOME/.claude}" "$sid"; then
      echo "– $sess:$widx ${tname:-$wname}: transcript gone — skipped"; k=$((k + 1)); continue
    fi
    [ -d "$dir" ] || { note="$note; $(tilde_of "$dir") is gone, resumed in ~"; dir=$HOME; }
    prof=$(resume_profile "$cfgd" "$hascfg" "$dir" "$sess")
    [ "$prof" = ask ] && { prof=""; note="$note; account not recorded, default login"; }
    cmd=$(agent_cmd "$prof" resume "$sid") || { echo "! $sess:$widx: no profile \"$prof\" — skipped"; k=$((k + 1)); continue; }
    # --resume brings back the permission mode but not a model picked with
    # --model or /model; the status line recorded that one. Effort only exists
    # on the command line it was started with.
    [ -n "$model" ] && cmd="$cmd --model $(cfg_quote "$model")"
    eff=$(printf '%s\n' "$argv" | awk '{ for (i = 1; i < NF; i++) if ($i == "--effort") { print $(i + 1); exit } }')
    [ -n "$eff" ] && cmd="$cmd --effort $(cfg_quote "$eff")"
    if [ "$dry" = 1 ]; then echo "✓ would resume $sess:$widx.$pidx ${tname:-$wname} [$sid]${note}"; n=$((n + 1)); continue; fi
    pane=$(resurrect_place "$sess" "$widx" "$pidx" "$dir" "$cmd") && [ -n "$pane" ] ||
      { echo "! $sess:$widx: could not open a pane — skipped"; k=$((k + 1)); continue; }
    # tagents' own name is stamped again so the naming sweep keeps it; a typed
    # one goes back plain, and only when the window had to be made anew.
    wid=$(tmux display -p -t "$pane" '#{window_id}' 2>/dev/null)
    if [ -n "$tname" ]; then rename_win "$wid" "$tname"
    elif [ -n "$wname" ] && [ "$(tmux display -p -t "$pane" '#{window_name}' 2>/dev/null)" != "$wname" ]; then rename_win "$wid" "$wname" plain; fi
    [ "$notes" = 1 ] && notes_panes="$notes_panes $pane"
    echo "✓ $sess:$widx.$pidx ${tname:-$wname} → $pane${prof:+ ($prof)}${model:+ $model}${note}"; n=$((n + 1))
  done < <(awk -F"$TAB" -v OFS="$US" '$1 == "A" { $1 = $1; print }' "$file" | sort -t"$US" -k5,5 -k6,6n -k7,7n)
  if [ "$dry" != 1 ]; then
    [ -n "$(awk -F"$TAB" '$1 == "D"' "$file")" ] && ensure_dash >/dev/null 2>&1 && echo "✓ dashboard"
    resurrect_notes $notes_panes
    unlock_dir "$RESURRECT_LOCK"
  fi
  echo "tagents: $n resumed, $k skipped, $total recorded ($(tilde_of "$file"))"
  [ "$auto" = 1 ] && tmux display-message "tagents: resurrected $n agents, $k skipped — $(tilde_of "$RESURRECT_LOG")" 2>/dev/null
  return 0
}

# Reopening the tnotes editor of every restored chat. A no-op for now: defined
# ahead of the restore that calls it, so that call never has to be guarded.
resurrect_notes() {  # <restored panes that had an editor…>
  return 0
}
