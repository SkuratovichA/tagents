# lib/tagents/closed.sh — the sessions that stopped running
#
# ctrl-y end to end: closed_hist_files (each account's history.jsonl), closed_rows (the capped, newest-first join of liveness, labels, history.tsv and prompt history — machine-readable on purpose, it is what the tests assert on), closed_preview, the picker, and resume_closed, which lands a session back in the tmux session that owns its project. The section banner at 4378-4394 heads the file.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# ---------------------------------------------------------------------------
# closed sessions: the ones that stopped running, however long ago
#
# A CLOSED ROW OUTLIVES ITS PANE BY A DAY (DEAD_TTL) AND NOT AN HOUR MORE, which
# is right for the list — a sidebar of week-old corpses is not a list of agents —
# and wrong for "what was that conversation I closed on Tuesday?". Nothing was
# actually lost, it simply had no surface: history.tsv keeps a line per session
# start and per turn for as long as the file lives, and each account's own
# history.jsonl keeps every prompt that was typed into it. These join the two by
# session id, so a conversation stays browsable — and resumable — for as long as
# either file remembers it.
#
# The names are the dashboard's own, in the order a name is worth trusting: the
# one you typed on ctrl-r, then the one $TA_LABEL announced at launch, then the
# first prompt of the session (which is what `claude --resume` own picker shows,
# and the reason that picker is legible at all), then the bare id.
# ---------------------------------------------------------------------------
CLOSED_MAX=${TA_CLOSED_MAX:-300}

# WHICH history.jsonl BELONGS TO WHICH ACCOUNT — the file a session's prompts
# are in IS the answer to which login can resume it, so the profile travels out
# of here with the path rather than being worked out again later. A profile with
# no config_dir is the default account, ~/.claude; with no profiles configured at
# all there is still exactly one account, and it is that same directory.
closed_hist_files() {  # [profile] -> profile<TAB>path, one per account to read
  local want=${1:-} p pd bd any=0
  while IFS="$US" read -r p pd bd; do
    [ -n "$p" ] || continue
    any=1
    [ -n "$pd" ] || pd=$HOME/.claude
    case $want in
      ''|'?'|"$p") [ -r "$pd/history.jsonl" ] && printf '%s\t%s\n' "$p" "$pd/history.jsonl" ;;
    esac
  done <<EOF
$(prof_pairs | tr "$RS" '\n')
EOF
  [ "$any" = 1 ] && return 0
  [ -r "$HOME/.claude/history.jsonl" ] && printf '\t%s\n' "$HOME/.claude/history.jsonl"
  return 0
}

closed_rows() {  # sid last first profile badge name dir source — newest first
  local p pd bd f b sid cfgd hascfg prof
  {
    # Running right now, and therefore not closed: resuming re-registers under a
    # new pane and the old record lingers, so the id is what settles it — the
    # same test --list makes before it offers a dead row.
    live_sids | sed "s/^/LIVE$TAB/"
    # A pane-less session is running when its recorded pid is, and live_panes
    # can never see one. Without this a headless agent working right now was
    # offered here as a closed session to resume — which would not resume it,
    # it would start a second conversation on the same transcript.
    for f in "$STATE_DIR"/s-*.tsv; do
      [ -e "$f" ] || continue
      # A headless record (the hook's ten-field layout) and only its session id; a pane record is read through rec_row (state.sh).
      headless_alive "$f" &&
        awk -F"$TAB" 'NR == 1 && $3 != "" { print "LIVE\t" $3 }' "$f"
    done
    [ -e "$LABELS" ] && awk -F"$TAB" -v OFS="$TAB" '{ print "NAME", $1, $2 }' "$LABELS"
    while IFS="$US" read -r p pd bd; do
      [ -n "$p" ] && printf 'B\t%s\t%s\n' "$p" "$bd"
    done <<EOF
$(prof_pairs | tr "$RS" '\n')
EOF
    for f in "$STATE_DIR/history.tsv.1" "$STATE_DIR/history.tsv"; do
      [ -e "$f" ] || continue
      awk -F"$TAB" -v OFS="$TAB" '{ print "H", $1, $2, $3, $4, $5, $6 }' "$f"
    done
    # ONE jq PER FILE, not one per session: history.jsonl is a line per prompt
    # ever typed on that account, and walking it once for everything is the
    # difference between a picker that opens and a picker that hangs. fromjson?
    # rather than a plain read so a half-written last line is skipped instead of
    # taking the whole account's history with it.
    while IFS="$TAB" read -r p f; do
      [ -n "$f" ] || continue
      jq -R -r --arg pr "$p" '
          fromjson? | select(.sessionId != null)
          | [ "P", .sessionId, ((.timestamp // 0) / 1000 | floor), (.project // ""),
              ((.display // "") | split("\n")[0] | .[0:60]), $pr ] | @tsv' \
        "$f" 2>/dev/null
    done <<EOF
$(closed_hist_files)
EOF
    # A session that never made it into any history.jsonl still has an account
    # if its state record survives. profile_claiming, never profile_of_cfg: the
    # latter answers "default" or a directory basename when nothing matches, and
    # nothing may be launched on a name that is not a profile.
    for f in "$STATE_DIR"/*.tsv; do
      [ -e "$f" ] || continue
      case ${f##*/} in *[!0-9].tsv) continue ;; esac
      b=${f##*/}
      IFS="$US" read -r sid _ _ cfgd hascfg < <(rec_row "${b%.tsv}")
      [ -n "${sid:-}" ] || continue
      [ "${hascfg:-0}" = 1 ] || continue
      prof=$(profile_claiming "$(cfg_expand_dir "${cfgd:-}")") || prof=""
      [ -n "$prof" ] && printf 'R\t%s\t%s\n' "$sid" "$prof"
    done
  } | awk -F"$TAB" -v OFS="$TAB" '
      $1 == "LIVE" { livesid[$2] = 1; next }
      $1 == "NAME" { lab[$2] = $3; next }
      $1 == "B"    { badge[$2] = $3; next }
      $1 == "R"    { rprof[$2] = $3; next }
      $1 == "H" {
        s = $4; if (s == "") next
        e = $2 + 0
        seen[s] = 1; hsrc[s] = 1
        if (!(s in last) || e > last[s]) last[s] = e
        if ($3 == "start" && (!(s in first) || e < first[s])) first[s] = e
        # The newest row that carries a cwd wins: a session that was resumed
        # somewhere else lives where it ran last, not where it was born.
        if ($7 != "" && (!(s in cwdts) || e >= cwdts[s])) { cwdts[s] = e; cwd[s] = $7 }
        if ($6 != "" && !(s in halbl)) halbl[s] = $6
        next
      }
      $1 == "P" {
        s = $2; if (s == "") next
        e = $3 + 0
        seen[s] = 1; jsrc[s] = 1
        if (!(s in last) || e > last[s]) last[s] = e
        if (!(s in pfirst) || e < pfirst[s]) { pfirst[s] = e; disp[s] = $5 }
        if ($4 != "" && !(s in proj)) proj[s] = $4
        if ($6 != "") pprof[s] = $6
        next
      }
      END {
        for (s in seen) {
          if (s in livesid) continue
          nm = (s in lab) ? lab[s] : ((s in halbl) ? halbl[s] : "")
          if (nm == "") nm = ((s in disp) && disp[s] != "") ? disp[s] : s
          pr = (s in pprof) ? pprof[s] : ((s in rprof) ? rprof[s] : "?")
          bd = (pr in badge) ? badge[pr] : ((pr == "?") ? "?" : substr(pr, 1, 1))
          d  = (s in cwd) ? cwd[s] : ((s in proj) ? proj[s] : "")
          fe = (s in first) ? first[s] : ((s in pfirst) ? pfirst[s] : last[s])
          src = ((s in hsrc) && (s in jsrc)) ? "both" : ((s in hsrc) ? "history" : "prompts")
          print s, last[s], fe, pr, bd, nm, d, src
        }
      }' | sort -t"$TAB" -k2,2nr | awk -v cap="$CLOSED_MAX" 'NR <= cap'
}

# The side of the picker: what that conversation actually was. The profile and
# the directory come in as arguments rather than being looked up again — the row
# already knows them, and re-deriving them would mean a second walk of every
# account's history on every cursor move. The prompts print oldest-of-the-last-
# ten first, which is the order a conversation reads in.
closed_preview() {  # <sid> [profile] [dir]
  local sid=${1:-} prof=${2:-} dir=${3:-} p f
  [ -n "$sid" ] || return 0
  printf '\033[1m%s\033[0m\n' "$sid"
  [ -n "$dir" ] && printf '\033[90m%s\033[0m\n' "$(tilde_of "$dir")"
  printf '\n'
  {
    while IFS="$TAB" read -r p f; do
      [ -n "$f" ] || continue
      jq -R -r --arg s "$sid" '
          fromjson? | select(.sessionId == $s)
          | [ ((.timestamp // 0) / 1000 | floor),
              ((.display // "") | split("\n")[0] | .[0:120]) ] | @tsv' "$f" 2>/dev/null
    done <<EOF
$(closed_hist_files "$prof")
EOF
  } | sort -n | awk -F"$TAB" '
      { p[++n] = $2 }
      END { s = (n > 10) ? n - 9 : 1; for (i = s; i <= n; i++) printf "  %s\n", p[i] }'
  # What it cost, when tusage is installed and the session is still inside its
  # 62-day index. Absent tusage this is simply not part of the preview.
  if command -v tusage >/dev/null 2>&1; then
    printf '\n'
    tusage --no-update --session "$sid" 2>/dev/null | head -12
  fi
  return 0
}

# WHERE A RESUMED SESSION LANDS is the project's own tmux session, the same
# answer start_agent gets from session_for_dir — a conversation about a project
# belongs beside that project's windows. The dead-row path in the list keeps its
# own behaviour: there the pane usually still exists and gets typed into.
resume_closed() {  # <sid> <dir> <profile>
  local sid=${1:-} dir=${2:-} prof=${3:-} sess
  [ -n "$sid" ] || return 1
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    tmux display-message \
      "tagents: $(tilde_of "${dir:-its directory}") is gone — resuming in $(tilde_of "$HOME")" 2>/dev/null
    dir=$HOME
  fi
  # An account nobody can name is not an account to launch on: fall through to
  # the default login rather than making agent_cmd refuse a profile called "?".
  profile_exists "$prof" || prof=""
  sess=$(session_for_dir "$dir")
  [ -n "$sess" ] || sess=$DASH_SESSION
  resume_with "" "$sid" "$dir" "$prof" "$sess"
}

ask_closed() {  # <port> — the picker itself, normally the body of the popup
  local port=${1:-} rows disp pick sid line prof dir nl
  nl='
'
  rows=$(closed_rows)
  if [ -z "$rows" ]; then
    tmux display-message "tagents: no closed sessions on record yet" 2>/dev/null
    return 0
  fi
  # Column 1 is the id and is never shown; column 2 is the line you read, built
  # here so the widths are decided over the whole set rather than per row.
  disp=$(printf '%s\n' "$rows" | awk -F"$TAB" -v OFS="$TAB" -v now="$(date +%s)" -v home="$HOME" '
      function agestr(t,   d) {
        d = now - t; if (d < 0) d = 0
        if (d < 3600)  return sprintf("%dm", int(d / 60))
        if (d < 86400) return sprintf("%dh", int(d / 3600))
        return sprintf("%dd", int(d / 86400))
      }
      function tilde(p) { return (index(p, home) == 1) ? "~" substr(p, length(home) + 1) : p }
      { r[NR] = $0; if (length($6) > w) w = length($6) }
      END {
        if (w > 34) w = 34
        for (i = 1; i <= NR; i++) {
          split(r[i], a, "\t")
          nm = a[6]; if (length(nm) > w) nm = substr(nm, 1, w - 1) "…"
          print a[1], sprintf("%4s  %s  %-*s  %s  %s", agestr(a[2]), a[5], w, nm,
                              tilde(a[7]), substr(a[1], 1, 8)), a[4], a[7]
        }
      }')
  # Not piped into `cut`: under pipefail an esc (fzf exits 130) would take the
  # whole pipeline down, and esc is the ordinary way out of here.
  pick=$(printf '%s' "$disp" | fzf --delimiter="$TAB" --with-nth=2 \
           --layout=reverse --height=100% --no-info --prompt='closed> ' \
           --preview="'$SELF' --closed-preview {1} {3} {4}" \
           --preview-window='right,50%,wrap' \
           --header="closed sessions · enter resumes · esc closes")
  # A --filter run prints every match rather than the one under a cursor; the
  # first is the one that was asked for.
  pick=${pick%%$nl*}
  sid=${pick%%$TAB*}
  [ -n "$sid" ] || return 0
  line=$(printf '%s\n' "$rows" | awk -F"$TAB" -v OFS="$TAB" -v s="$sid" '$1 == s { print $4, $7; exit }')
  prof=${line%%$TAB*}
  dir=${line#*$TAB}
  resume_closed "$sid" "$dir" "$prof"
  post_fzf "$port" "reload-sync($SELF --list)"
}

closed_window() {  # ctrl-y — the modal, or the same body inline where a popup cannot open
  local port=${FZF_PORT:-}
  prompt_at 90% 85% --ask-closed "$port" && return 0
  ask_closed "$port"
  return 0
}
