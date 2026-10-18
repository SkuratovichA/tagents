# lib/tagents/state.sh — the raw data every view reads
#
# Where the dashboard's facts come from: live_panes (the ps ancestry walk that proves a Claude is really running; live_pane_pids is the walk with the pid kept), rec_row/live_sids (a record's resume fields, and the session ids running right now), repo_root/dir_roots (grouping by the nearest .git), state_files (why a naive *.tsv glob once produced panes called %history), headless_alive/headless_log (a `claude -p` run has no pane, only a pid and a $TA_LOG), transcript_tail/title_of (what a session with neither shows and calls itself, cached in TITLES), origin_of (the transcript's first cwd, cached in ORIGINS, because the live cwd drifts), and collect() — the single pass that emits the P/L/R/N/S/H/T/B/M/U stream list(), counts() and the pickers all read. The 'rows' banner heads the file.
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

# THE LAST FEW TURNS OF A TRANSCRIPT, for a session with neither a pane to
# capture nor a readable $TA_LOG — which is every child session, since whatever
# started it kept its output to itself. Data, not view: the preview prints it,
# ctrl-v pages it, and both want the same lines.
#
# Tail-bounded on purpose. A transcript reaches tens of megabytes and this is
# re-run on every cursor move, so only the last few records are ever read — four
# lines per wanted line, since tool results and meta records outnumber the turns.
# `fromjson?` rather than a plain parse: a half-written last line is the normal
# state of a file being appended to, and it must skip that line rather than take
# the whole output with it (the lesson closed.sh already learned).
transcript_tail() {  # <transcript file> [lines]
  local f=${1:-} n=${2:-20}
  [ -n "$f" ] && [ -r "$f" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  tail -n $(( n * 4 )) -- "$f" 2>/dev/null |
    jq -R -r '
      fromjson? | select(.type == "user" or .type == "assistant")
      | .message.content
      | if type == "array" then .[] else empty end
      | if .type == "tool_use"
        then "▸ " + .name + " " + ((.input | tostring) | gsub("\\s+"; " ") | .[0:120])
        elif .type == "text" then (.text | gsub("\\s+"; " ") | .[0:300])
        else empty end' 2>/dev/null |
    tail -n "$n"
}

# WHAT A SESSION CALLS ITSELF. Claude Code writes one {"type":"ai-title"} record
# near the top of a transcript — the name it gave the conversation — and for a
# session with no pane and no $TA_LABEL that is the only name there is: the
# alternative is the basename of a directory, which every agent in a repo shares.
#
# Resolved once per session and cached beside the origins, three columns:
# session id, the title or "-" for "there is none", and how big the transcript
# was when we looked. A MISS IS CACHED TOO, or every repaint would re-read 200
# lines of every transcript that has no title yet.
#
# A LIVE transcript is bigger on every repaint, so "re-check once it grew" would
# re-check a titleless session every two seconds — and, appending, would grow the
# cache by a line each time. So: one row per session id, rewritten in place, and
# a miss is re-checked only when the growth could plausibly have brought a title
# with it. The record sits near the top of the file, within the 200 lines we
# read: a transcript that was already 64 KiB without one never gains one, and
# below that we wait for a full 8 KiB of new text before looking again.
TITLES="$STATE_DIR/title.tsv"
TITLE_MAXSZ=65536   # past this the first 200 lines are long behind us
TITLE_STEP=8192     # and below it, re-read only after this much new text
# A caller that has read the cache already passes the row it found (an empty
# title for "no row"), and no awk is started to look it up again: collect()
# does that for every pane-less record in its one awk.
title_of() {  # <session-id> <transcript-path> [<cached title> <cached size>]
  local sid=${1:-} tr=${2:-} sz=0 hit= hsz= t= tmp= have=0
  [ $# -ge 3 ] && { have=1; hit=${3:-}; hsz=${4:-}; }
  [ -n "$sid" ] || return 1
  if [ -n "$tr" ] && [ -e "$tr" ]; then
    # wc -c, as the hook's history rotation does it; it pads, so strip the pad.
    sz=$(wc -c <"$tr" 2>/dev/null) || sz=0
    sz=${sz// /}
  fi
  case ${sz:-0} in ''|*[!0-9]*) sz=0 ;; esac
  if [ "$have" = 1 ] || [ -e "$TITLES" ]; then
    # The LAST line for the id, not the first: a cache written before the rows
    # were rewritten in place may still hold several, and the newest one counts.
    [ "$have" = 1 ] || IFS="$US" read -r hit hsz < <(
      awk -F"$TAB" -v OFS="$US" -v k="$sid" \
          '$1 == k { t = $2; s = $3 } END { if (t != "") print t, s }' \
          "$TITLES" 2>/dev/null)
    if [ -n "${hit:-}" ]; then
      [ "$hit" != - ] && { printf '%s' "$hit"; return 0; }
      case ${hsz:-0} in ''|*[!0-9]*) hsz=0 ;; esac
      [ "$hsz" -ge "$TITLE_MAXSZ" ] && return 1
      [ "$sz" -lt $(( hsz + TITLE_STEP )) ] && return 1
    fi
  fi
  if [ -n "$tr" ] && [ -e "$tr" ] && command -v jq >/dev/null 2>&1; then
    # Clipped and scrubbed by jq rather than by cut: .[0:60] counts characters,
    # and a title cut by bytes ends in half a glyph.
    t=$(head -200 -- "$tr" 2>/dev/null |
          jq -R -r 'fromjson? | select(.type == "ai-title")
                    | ((.aiTitle // "") | tostring
                       | gsub("[\\t\\r\\n]+"; " ") | .[0:60])' 2>/dev/null | head -1)
  fi
  # Rewrite the row rather than append one: the file holds one line per session
  # and is small by construction, so a copy beside it and a mv are cheap.
  tmp="$TITLES.$$"
  if [ -e "$TITLES" ]; then
    awk -F"$TAB" -v k="$sid" '$1 != k' "$TITLES" >"$tmp" 2>/dev/null || :
  else
    : >"$tmp" 2>/dev/null || :
  fi
  if [ -e "$tmp" ]; then
    printf '%s\t%s\t%s\n' "$sid" "${t:--}" "$sz" >>"$tmp" 2>/dev/null
    mv -f "$tmp" "$TITLES" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  fi
  [ -n "${t:-}" ] || return 1
  printf '%s' "$t"
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
  signal_ev   # the origin is drawn, and the file is not a tmux event
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

  local f key ts st sid cwd tr det cfgd hascfg orig hlbl hpar hpsid hl pid ttl th tz
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
    [ -e "$TITLES" ] && set -- "$TITLES" "$@"
    while IFS="$US" read -r f orig ts st sid cwd tr det cfgd hascfg pid hpar hpsid th tz hlbl; do
      key=${f##*/}; key=${key%.tsv}
      [ -z "$orig" ] && [ -n "$sid" ] && orig=$(origin_of "$sid" "$tr")
      printf 'S\t%%%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$key" "${ts:-0}" "${st:-}" "${sid:-}" "${orig:-${cwd:-}}" "${tr:-}" "${det:-}" \
        "${cfgd:-}" "${hascfg:-0}"
      # A PANE-LESS SESSION NEEDS ITS OWN LINE, because the two things the renderer
      # reads off a pane it cannot read here: whether the agent is running (the
      # recorded pid, which only the shell can kill -0) and what to call it (there
      # is no pane title, so $TA_LABEL is the name). Plus, for a child, whose it
      # is — the parent's record key and session id, which is what the row is
      # nested under. Those two come BEFORE the label for the reason the pane
      # format above gives: the label is the one field carrying arbitrary text, so
      # it goes last. The log is not in it — only the preview wants that, and it
      # reads the record itself (headless_log). The pid is field 8 of the record,
      # brought along by the awk above, so asking after it costs no process of its
      # own.
      case $key in
        s-?*)
          hl=0; pid_alive "$pid" && hl=1
          printf 'H\t%%%s\t%s\t%s\t%s\t%s\n' \
            "$key" "$hl" "${hpar:-}" "${hpsid:-}" "${hlbl:-}"
          # ...and the name the session gave itself, for the rows that have no
          # other. Emitted for pane-less rows only: everybody else has a pane
          # title, which is the same answer without reading a file. Tagged A and
          # not T: T is the prompt clock below, one line per file in prompt/, and
          # two kinds of record sharing a tag is two readers quietly reading the
          # wrong one.
          ttl=$(title_of "${sid:-}" "${tr:-}" "${th:-}" "${tz:-}") &&
            printf 'A\t%s\t%s\n' "${sid:-}" "$ttl" ;;
      esac
    done < <(awk -F"$TAB" -v OFS="$US" -v orig="$ORIGINS" -v titles="$TITLES" '
      function blank(p) { print p, "", "", "", "", "", "", "", "", "0", "", "", "", "", "", "" }
      BEGIN {
        # A record deleted between the glob and here must not take the rest of
        # the list down with it: this awk stops dead at a file it cannot open,
        # where the old one-awk-per-file loop lost that one row. So every
        # argument is probed first and a vanished one is dropped from ARGV.
        for (i = 1; i < ARGC; i++) {
          if ((getline junk < ARGV[i]) < 0) { ARGV[i] = ""; continue }
          close(ARGV[i])
          if (ARGV[i] != orig && ARGV[i] != titles) sf[++ns] = ARGV[i]
        }
        nx = 1
      }
      FILENAME == orig { if (!($1 in o)) o[$1] = $2; next }
      # The title cache: the LAST row for an id counts, as in title_of.
      FILENAME == titles { th[$1] = $2; tz[$1] = $3; next }
      FNR == 1 {
        while (nx <= ns && sf[nx] != FILENAME) blank(sf[nx++])
        nx++
        t = th[$3]; gsub(OFS, " ", t)
        print FILENAME, o[$3], $1, $2, $3, $4, $5, $6, $7, (NF >= 7 ? 1 : 0), $8, $11, $12, t, tz[$3], $10
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
