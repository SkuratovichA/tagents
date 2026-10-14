# lib/tagents/state.sh — the raw data every view reads
#
# Where the dashboard's facts come from: live_panes (the ps ancestry walk that proves a Claude is really running; live_pane_pids is the walk with the pid kept), rec_row/live_sids (a record's resume fields, and the session ids running right now), repo_root/dir_roots (grouping by the nearest .git), state_files (why a naive *.tsv glob once produced panes called %history), headless_alive/headless_log (a `claude -p` run has no pane, only a pid and a $TA_LOG), origin_of (the transcript's first cwd, cached in ORIGINS, because the live cwd drifts), and collect() — the single pass that emits the P/L/R/N/S/H/B/M/U stream list(), counts() and the pickers all read. The 'rows' banner heads the file.
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
  live_pane_pids | cut -f1

  # Secondary signal, in case the process walk comes up empty.
  tmux list-panes -a -F '#{pane_id} #{pane_current_command}' 2>/dev/null |
    awk '$2 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ || $2 == "claude" { print $1 }'
}

# The walk itself, with the pid of the Claude it found beside each pane: the
# snapshot taken before a reboot needs that process's argv, and the pane alone
# cannot give it. live_panes is this without the pid, plus its fallback.
live_pane_pids() {  # pane TAB claude pid, one line per Claude process
  {
    # The pane map goes through stdin, not -v: BWK awk (the macOS one) rejects
    # a -v value containing newlines, and fails silently enough to look like
    # "no Claude is running anywhere".
    tmux list-panes -a -F 'MAP #{pane_pid} #{pane_id}' 2>/dev/null
    ps -eo pid=,ppid=,comm= 2>/dev/null
  } | awk -v OFS="$TAB" '
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
            if (q in pane) { print pane[q], p; break }
            q = up[q]
          }
        }
      }'
}

# The first line of a pane's record, the fields a restart needs, in one place:
# the session id to resume and the account it ran on. hascfg is 1 when the
# record has the account field at all — a record written before accounts
# existed has six fields, and "no field" is not the same answer as "the
# default login" (see resume_profile).
rec_row() {  # <pane key> -> sid US cwd US transcript US cfgd US hascfg (hascfg: the record has the account field at all)
  awk -F"$TAB" -v OFS="$US" 'NR == 1 { print $3, $4, $5, $7, (NF >= 7 ? 1 : 0); exit }' "$STATE_DIR/${1#%}.tsv" 2>/dev/null
}

# Running right now, by session id: resuming re-registers a conversation under
# a new pane and the old record lingers, so the id is what settles whether a
# conversation is already up — never the pane.
live_sids() {  # the session id of every pane a Claude is running in, one per line
  local p sid rest
  for p in $(live_panes | sort -u); do
    IFS="$US" read -r sid rest < <(rec_row "$p"); [ -n "$sid" ] && printf '%s\n' "$sid"
  done
  return 0   # a last pane with no record is not a failure of the list
}

# Sessions started from a subdirectory of a repo belong with the rest of that
# repo — grouping by raw cwd would file ~/repo/packages/client separately from
# ~/repo and make it look like an agent had gone missing. Walk up to the .git.
# repo_root_v sets REPO_ROOT and costs no process; repo_root prints it for the
# callers that want a command substitution.
repo_root_v() {
  local d=$1
  REPO_ROOT=
  # Absolute paths only, and bail out when there is no slash left to strip:
  # ${d%/*} on a slashless value returns it unchanged, i.e. an infinite loop.
  case $d in /*) ;; *) return 1 ;; esac
  while [ -n "$d" ] && [ "$d" != / ]; do
    [ -e "$d/.git" ] && { REPO_ROOT=$d; return 0; }
    case $d in */*) d=${d%/*} ;; *) return 1 ;; esac
  done
  return 1
}
repo_root() { repo_root_v "$@" && printf '%s' "$REPO_ROOT"; }

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
  pid_alive "$pid"
}

# The question above once the pid is in hand, for the caller that read the record
# some other way (collect brings it along with the rest of the record).
pid_alive() {  # <pid>
  local pid=${1:-}
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

# A record deleted between a glob and the awk that reads it must not take the
# rest of the directory down with it: macOS awk stops dead at an argument it
# cannot open. In front of a one-awk-per-directory program this drops every
# argument that cannot be read before the first record is. Each call also reads
# </dev/null, because an awk left with no argument at all reads stdin.
AWK_SKIP_GONE='BEGIN { for (i = 1; i < ARGC; i++) if ((getline junk < ARGV[i]) < 0) ARGV[i] = ""; else close(ARGV[i]) }'

dir_roots() {
  local d r
  {
    tmux list-panes -a -F '#{pane_current_path}' 2>/dev/null
    [ -e "$ORIGINS" ] && cut -f2 "$ORIGINS" 2>/dev/null
    # One awk for every state file rather than one per file: this runs on every
    # repaint, and a process started per record is what the endpoint security
    # agent inspects one by one. The braces are a pipeline stage, so the
    # positional parameters set here are this subshell's own.
    set --
    while IFS= read -r d; do set -- "$@" "$d"; done < <(state_files)
    [ $# -gt 0 ] && awk -F"$TAB" "$AWK_SKIP_GONE"' FNR == 1 { print $4 }' "$@" </dev/null 2>/dev/null
  } | sort -u | while IFS= read -r d; do
    [ -n "$d" ] || continue
    repo_root_v "$d" || continue; r=$REPO_ROOT
    [ "$r" = "$d" ] && continue
    printf 'R%s%s%s%s\n' "$TAB" "$d" "$TAB" "$r"
  done
}

# EVERY FILE READ BELOW (and in list()) HAS A TWIN in refresh_changed (refresh.sh),
# the refresher's list of the paths whose change reloads the picker: a new kind of
# path read here belongs there too, and tests/refresh.sh section 11 pins the two.
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

  local f key ts st sid cwd tr det cfgd hascfg orig hlbl hl pid
  # ONE AWK FOR ALL THE STATE FILES, and for the origin cache beside them: a
  # process per record — two, with the cache lookup — is what a repaint used to
  # cost per session, thrice a second, and the endpoint security agent inspects
  # every one. The cache is read first (its lines are <session id><TAB><dir>, the
  # first match wins as in origin_of) and each state file then yields one line:
  # its path, the cached origin (empty for a session not seen before, which is
  # the only case origin_of's slow path is still called for) and the fields below.
  # A file with no first line yields no record for awk to hook onto, so the files
  # are counted off the argument list and a skipped one gets its defaults in
  # turn, which is what an empty file always read as.
  # Not IFS=TAB: tab is IFS whitespace, so the (often empty) session id would
  # collapse and shift every later field one slot to the left.
  # The 7th field is the account. A record written by an older hook has six
  # fields and no opinion at all, which is a different answer from "unset, so
  # the default account" — hence the flag alongside it.
  set --
  while IFS= read -r f; do set -- "$@" "$f"; done < <(state_files)
  if [ $# -gt 0 ]; then
    [ -e "$ORIGINS" ] && set -- "$ORIGINS" "$@"
    while IFS="$US" read -r f orig ts st sid cwd tr det cfgd hascfg pid hlbl; do
      key=${f##*/}; key=${key%.tsv}
      [ -z "$orig" ] && [ -n "$sid" ] && orig=$(origin_of "$sid" "$tr")
      printf 'S\t%%%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$key" "${ts:-0}" "${st:-}" "${sid:-}" "${orig:-${cwd:-}}" "${tr:-}" "${det:-}" \
        "${cfgd:-}" "${hascfg:-0}"
      # A PANE-LESS SESSION NEEDS ITS OWN LINE, because the two things the renderer
      # reads off a pane it cannot read here: whether the agent is running (the
      # recorded pid, which only the shell can kill -0) and what to call it (there
      # is no pane title, so $TA_LABEL is the name). The log is not in it — only
      # the preview wants that, and it reads the record itself (headless_log). The
      # pid is field 8 of the record, brought along by the awk above, so asking
      # after it costs no process of its own.
      case $key in
        s-?*)
          hl=0; pid_alive "$pid" && hl=1
          printf 'H\t%%%s\t%s\t%s\n' "$key" "$hl" "${hlbl:-}" ;;
      esac
    done < <(awk -F"$TAB" -v OFS="$US" -v orig="$ORIGINS" '
      function blank(p) { print p, "", "", "", "", "", "", "", "", "0", "", "" }
      BEGIN {
        # A record deleted between the glob and here must not take the rest of
        # the list down with it: this awk stops dead at a file it cannot open,
        # where the old one-awk-per-file loop lost that one row. So every
        # argument is probed first and a vanished one is dropped from ARGV.
        for (i = 1; i < ARGC; i++) {
          if ((getline junk < ARGV[i]) < 0) { ARGV[i] = ""; continue }
          close(ARGV[i])
          if (ARGV[i] != orig) sf[++ns] = ARGV[i]
        }
        nx = 1
      }
      FILENAME == orig { if (!($1 in o)) o[$1] = $2; next }
      FNR == 1 {
        while (nx <= ns && sf[nx] != FILENAME) blank(sf[nx++])
        nx++
        print FILENAME, o[$3], $1, $2, $3, $4, $5, $6, $7, (NF >= 7 ? 1 : 0), $8, $10
      }
      END { while (nx <= ns) blank(sf[nx++]) }' "$@" </dev/null 2>/dev/null)
  fi

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

  # One awk for the whole directory, like the state files above: the key is
  # already taken from FILENAME, so nothing about a file is needed from outside.
  set -- "$STATE_DIR"/sub/*
  [ -e "$1" ] && awk -v OFS="$TAB" "$AWK_SKIP_GONE"'
    FNR==1 { n=split(FILENAME,a,"/"); k=a[n]; sub(/\..*$/,"",k) }
    { print "B", "%" k, $0 }' "$@" </dev/null 2>/dev/null

  # Which model each session is SET to, recorded by claude-statusline.sh. This
  # is not the same question tusage answers: tusage reports the model that
  # served the newest request, which is what the money is computed from and
  # which goes stale the moment you /model a session and do not talk to it.
  # One awk for every file: the session id is the file name, taken off FILENAME,
  # and only the first line of each is read (FNR, since NR runs on across files).
  set -- "$STATE_DIR"/model/*.tsv
  [ -e "$1" ] && awk -F"$TAB" -v OFS="$TAB" "$AWK_SKIP_GONE"'
    FNR == 1 { s = FILENAME; sub(/.*\//, "", s); sub(/\.tsv$/, "", s); print "M", s, $2, $4 }' "$@" </dev/null 2>/dev/null

  # Token accounting, joined on session id. --no-update keeps this to one awk
  # pass over the index; advancing the index is the refresher loop's job, so a
  # keystroke never waits on it.
  usage_on &&
    tusage --no-update --sessions 2>/dev/null | sed "s/^/U${TAB}/"
}
