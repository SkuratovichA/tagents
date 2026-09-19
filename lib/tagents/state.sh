# lib/tagents/state.sh — the raw data every view reads
#
# Where the dashboard's facts come from: live_panes (the ps ancestry walk that proves a Claude is really running), repo_root/dir_roots (grouping by the nearest .git), state_files (why a naive *.tsv glob once produced panes called %history), headless_alive/headless_log (a `claude -p` run has no pane, only a pid and a $TA_LOG), origin_of (the transcript's first cwd, cached in ORIGINS, because the live cwd drifts), and collect() — the single pass that emits the P/L/R/N/S/H/B/M/U stream list(), counts() and the pickers all read. The 'rows' banner heads the file.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# ---------------------------------------------------------------------------
# rows
# ---------------------------------------------------------------------------

# Which panes actually have a running Claude. The CLI lives at
# ~/.local/share/claude/versions/<version>, which is why pane_current_command
# shows a bare version number; matching the path is version-proof. A state file
# alone proves nothing — Claude may have exited and left the shell behind.
live_panes() {
  {
    # The pane map goes through stdin, not -v: BWK awk (the macOS one) rejects
    # a -v value containing newlines, and fails silently enough to look like
    # "no Claude is running anywhere".
    tmux list-panes -a -F 'MAP #{pane_pid} #{pane_id}' 2>/dev/null
    ps -eo pid=,ppid=,comm= 2>/dev/null
  } | awk '
      $1 == "MAP" { pane[$2] = $3; next }
      {
        pid = $1; c = $0
        sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", c)
        up[pid] = $2
        if (index(c, "/claude/versions/") > 0 || c ~ /\/claude$/ || c == "claude") cl[pid] = 1
      }
      END {
        for (p in cl) {
          q = p
          for (i = 0; i < 50 && q != "" && q != "0" && q != "1"; i++) {
            if (q in pane) { print pane[q]; break }
            q = up[q]
          }
        }
      }'

  # Secondary signal, in case the process walk comes up empty.
  tmux list-panes -a -F '#{pane_id} #{pane_current_command}' 2>/dev/null |
    awk '$2 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ || $2 == "claude" { print $1 }'
}

# Sessions started from a subdirectory of a repo belong with the rest of that
# repo — grouping by raw cwd would file ~/repo/packages/client separately from
# ~/repo and make it look like an agent had gone missing. Walk up to the .git.
repo_root() {
  local d=$1
  # Absolute paths only, and bail out when there is no slash left to strip:
  # ${d%/*} on a slashless value returns it unchanged, i.e. an infinite loop.
  case $d in /*) ;; *) return 1 ;; esac
  while [ -n "$d" ] && [ "$d" != / ]; do
    [ -e "$d/.git" ] && { printf '%s' "$d"; return 0; }
    case $d in */*) d=${d%/*} ;; *) return 1 ;; esac
  done
  return 1
}

# Only <pane number>.tsv holds a pane's state. history.tsv and labels.tsv sit in
# the same directory, and globbing *.tsv swept them up as panes called
# "%history" and "%labels" — complete with a bogus row in the dashboard.
state_files() {
  local f b
  for f in "$STATE_DIR"/*.tsv; do
    [ -e "$f" ] || continue
    b=${f##*/}; b=${b%.tsv}
    # <pane number>.tsv, or s-<session id>.tsv for a session with no pane of its
    # own (a background job, which would otherwise overwrite the record of the
    # pane it happens to descend from).
    case $b in
      s-?*) ;;
      ''|*[!0-9]*) continue ;;
    esac
    printf '%s\n' "$f"
  done
}

# THE ONLY LIVENESS SIGNAL A PANE-LESS SESSION HAS. A headless `claude -p` — one
# started by a daemon or a launchd job — sits in no pane at all, so live_panes
# can say nothing whatever about it. The hook writes down the pid of its claude
# process as field 8 of the s-*.tsv record, and this asks the kernel whether that
# process is still there. kill -0 rather than `ps -p`: no fork, no pipeline, and
# this is asked once per headless row on every repaint.
headless_alive() {  # <state file>
  local pid
  pid=$(awk -F"$TAB" 'NR==1 { print $8; exit }' "${1:-}" 2>/dev/null)
  # 0 is rejected with the rest: `kill -0 0` asks about this whole process
  # group, which is always alive, and a record that could not name a pid must
  # not be the one row that can never go closed.
  case ${pid:-} in ''|0|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

# WHERE THE OUTPUT OF A PANE-LESS SESSION WENT — $TA_LOG as the hook saw it
# and only while the file is still readable. With no pane there is nothing to
# capture-pane, so this log is the whole of what a preview can show.
headless_log() {  # <pane key %s-<sid>>
  local log
  log=$(awk -F"$TAB" 'NR==1 { print $9; exit }' \
          "$STATE_DIR/${1#%}.tsv" 2>/dev/null)
  [ -n "$log" ] && [ -r "$log" ] || return 1
  printf '%s' "$log"
}

# WHERE AN AGENT LIVES is where it was launched — and the hook cannot tell us
# that. Its payload carries the *live* cwd, which follows the Bash tool's `cd`:
# one session was observed under five different directories inside a single turn
# (~, the repo, ~/.claude/agent-state, ~/.claude/projects, the dotfiles repo).
# That is why agents hopped between groups while you watched, and why a session
# started in ~ was filed under whatever repo it had last poked at.
#
# The first cwd written into the transcript IS the launch directory and never
# changes. Resolve it once per session id and cache it; the cache also survives
# the session being resumed, since the id does.
ORIGINS="$STATE_DIR/origin.tsv"
origin_of() {  # <session-id> <transcript-path>
  local sid=${1:-} tr=${2:-} d=
  [ -n "$sid" ] || return 1
  if [ -e "$ORIGINS" ]; then
    d=$(awk -F"$TAB" -v k="$sid" '$1 == k { print $2; exit }' "$ORIGINS" 2>/dev/null)
    [ -n "$d" ] && { printf '%s' "$d"; return 0; }
  fi
  if [ -n "$tr" ] && [ -e "$tr" ] && command -v jq >/dev/null 2>&1; then
    d=$(head -200 -- "$tr" 2>/dev/null | jq -rc 'select(.cwd) | .cwd' 2>/dev/null | head -1)
  fi
  [ -n "$d" ] || return 1
  printf '%s\t%s\n' "$sid" "$d" >>"$ORIGINS" 2>/dev/null
  printf '%s' "$d"
}

dir_roots() {
  local d r
  {
    tmux list-panes -a -F '#{pane_current_path}' 2>/dev/null
    [ -e "$ORIGINS" ] && cut -f2 "$ORIGINS" 2>/dev/null
    state_files | while IFS= read -r d; do
      awk -F"$TAB" 'FNR == 1 { print $4 }' "$d"
    done
  } | sort -u | while IFS= read -r d; do
    [ -n "$d" ] || continue
    r=$(repo_root "$d") || continue
    [ "$r" = "$d" ] && continue
    printf 'R%s%s%s%s\n' "$TAB" "$d" "$TAB" "$r"
  done
}

collect() {
  # A literal tab must not go into a tmux format string. Outside a UTF-8 locale
  # tmux renders it as "_", so all five fields merge into one, no pane is ever
  # recognised as alive and the whole dashboard reads "everything is closed".
  # Printable ASCII survives either way; the title goes last because it is the
  # one field that carries arbitrary text.
  tmux list-panes -a -F "P|@|#{pane_id}|@|#{session_name}:#{window_index}.#{pane_index}|@|#{pane_current_path}|@|#{pane_title}" 2>/dev/null |
    awk -v OFS="$TAB" '
      { n = split($0, a, "\\|@\\|")
        t = a[5]; for (i = 6; i <= n; i++) t = t "|@|" a[i]
        print a[1], a[2], a[3], t, a[4] }'
  live_panes | sed "s/^/L${TAB}/"
  dir_roots
  [ -e "$LABELS" ] && awk -F"$TAB" -v OFS="$TAB" '{ print "N", $1, $2 }' "$LABELS"

  local f key ts st sid cwd tr det cfgd hascfg orig hlbl hl
  state_files | while IFS= read -r f; do
    key=${f##*/}; key=${key%.tsv}
    # Not IFS=TAB: tab is IFS whitespace, so the (often empty) session id would
    # collapse and shift every later field one slot to the left.
    # The 7th field is the account. A record written by an older hook has six
    # fields and no opinion at all, which is a different answer from "unset, so
    # the default account" — hence the flag alongside it.
    IFS="$US" read -r ts st sid cwd tr det cfgd hascfg hlbl < <(
      awk -F"$TAB" -v OFS="$US" \
          'NR==1 { print $1, $2, $3, $4, $5, $6, $7, (NF >= 7 ? 1 : 0), $10; exit }' "$f" 2>/dev/null)
    orig=$(origin_of "${sid:-}" "${tr:-}")
    printf 'S\t%%%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$key" "${ts:-0}" "${st:-}" "${sid:-}" "${orig:-${cwd:-}}" "${tr:-}" "${det:-}" \
      "${cfgd:-}" "${hascfg:-0}"
    # A PANE-LESS SESSION NEEDS ITS OWN LINE, because the two things the renderer
    # reads off a pane it cannot read here: whether the agent is running (the
    # recorded pid, which only the shell can kill -0) and what to call it (there
    # is no pane title, so $TA_LABEL is the name). The log is not in it — only
    # the preview wants that, and it reads the record itself (headless_log).
    case $key in
      s-?*)
        hl=0; headless_alive "$f" && hl=1
        printf 'H\t%%%s\t%s\t%s\n' "$key" "$hl" "${hlbl:-}" ;;
    esac
  done

  # WHEN THE OWNER LAST TYPED INTO EACH SESSION, one epoch second per file,
  # written by the hook on UserPromptSubmit and on nothing else. The age column
  # and the row order are both taken from it: the record's own timestamp moves on
  # every tool call, so an age taken from that reads 0:00 for every working agent
  # and a list ordered on it reshuffles under the cursor. Read with the shell's
  # own redirect — one line, no fork, and this runs once per file per repaint.
  for f in "$STATE_DIR"/prompt/*; do
    [ -e "$f" ] || continue
    key=${f##*/}
    ts=; IFS= read -r ts <"$f" 2>/dev/null
    printf 'T\t%%%s\t%s\n' "$key" "${ts:-0}"
  done

  for f in "$STATE_DIR"/sub/*; do
    [ -e "$f" ] || continue
    awk -v OFS="$TAB" '
      FNR==1 { n=split(FILENAME,a,"/"); k=a[n]; sub(/\..*$/,"",k) }
      { print "B", "%" k, $0 }' "$f"
  done

  # Which model each session is SET to, recorded by claude-statusline.sh. This
  # is not the same question tusage answers: tusage reports the model that
  # served the newest request, which is what the money is computed from and
  # which goes stale the moment you /model a session and do not talk to it.
  for f in "$STATE_DIR"/model/*.tsv; do
    [ -e "$f" ] || continue
    key=${f##*/}; key=${key%.tsv}
    awk -F"$TAB" -v OFS="$TAB" -v s="$key" 'NR==1 { print "M", s, $2, $4; exit }' "$f"
  done

  # Token accounting, joined on session id. --no-update keeps this to one awk
  # pass over the index; advancing the index is the refresher loop's job, so a
  # keystroke never waits on it.
  command -v tusage >/dev/null 2>&1 &&
    tusage --no-update --sessions 2>/dev/null | sed "s/^/U${TAB}/"
}
