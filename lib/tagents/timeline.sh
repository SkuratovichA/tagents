# lib/tagents/timeline.sh — which agent worked when
#
# --timeline: one bar per session over TA_TIMELINE_HOURS, merging live/headless liveness, labels, and the rotated history.tsv into a single awk pass. Nothing else calls it and it calls almost nothing — the cleanest module in the set.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# ---------------------------------------------------------------------------
# timeline: which agent worked when, from the hook's append-only history
# ---------------------------------------------------------------------------
timeline() {
  local hours=${TA_TIMELINE_HOURS:-24} now cols barw z zh zm offsec f

  if [ ! -e "$STATE_DIR/history.tsv" ] && [ ! -e "$STATE_DIR/history.tsv.1" ]; then
    echo "tagents: no history yet — it starts filling on the next session start" >&2
    echo "         or turn end (see claude/hooks/tmux-agent-state.sh)" >&2
    return 1
  fi

  now=$(date +%s)
  cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 100)}
  # Give the bar room on a narrow pane by shrinking, then dropping, the cwd
  # column — the name usually says which project it is anyway.
  if   [ "$cols" -ge 120 ]; then namew=26; cwdw=22
  elif [ "$cols" -ge 100 ]; then namew=22; cwdw=16
  else                           namew=18; cwdw=0
  fi
  barw=$(( cols - namew - cwdw - 24 )); [ "$barw" -lt 12 ] && barw=12

  # This awk has no strftime, so hand it the local UTC offset and do the
  # arithmetic there. A DST change inside the window would shift labels by an
  # hour; not worth carrying a full tz database for.
  z=$(date +%z); zh=${z:1:2}; zm=${z:3:2}
  offsec=$(( 10#$zh * 3600 + 10#$zm * 60 ))
  case "$z" in -*) offsec=$(( -offsec )) ;; esac

  {
    # Sessions alive right now, so a span with no end event reads as running
    # rather than as having stopped at its last turn.
    live_sids | sed "s/^/LIVE$TAB/"
    # A pane-less session is alive when the pid the hook recorded is: live_panes
    # walks panes and can never see one. Without this every headless bar stopped
    # at its last turn, which reads as "it finished" for an agent still working.
    for f in "$STATE_DIR"/s-*.tsv; do
      [ -e "$f" ] || continue
      headless_alive "$f" &&
        awk -F"$TAB" 'NR == 1 && $3 != "" { print "LIVE\t" $3 }' "$f"
    done
    [ -e "$LABELS" ] && awk -F"$TAB" -v OFS="$TAB" '{ print "NAME", $1, $2 }' "$LABELS"
    for f in "$STATE_DIR/history.tsv.1" "$STATE_DIR/history.tsv"; do
      [ -e "$f" ] || continue
      awk -F"$TAB" -v OFS="$TAB" '{ print "H", $1, $2, $3, $4, $5, $6 }' "$f"
    done
  } | awk -F"$TAB" -v now="$now" -v hours="$hours" -v offsec="$offsec" \
          -v barw="$barw" -v home="$HOME" -v namew="$namew" -v cwdw="$cwdw" '
      function base(p,   n, a) { n = split(p, a, "/"); return n ? a[n] : p }
      function hhmm(t,   lt) {
        lt = (t + offsec) % 86400; if (lt < 0) lt += 86400
        return sprintf("%02d:%02d", int(lt / 3600), int((lt % 3600) / 60))
      }
      function dur(d) {
        if (d < 60)   return sprintf("%ds", d)
        if (d < 3600) return sprintf("%dm", int(d / 60))
        return sprintf("%dh%02d", int(d / 3600), int((d % 3600) / 60))
      }
      function rep(c, n,   i, s) { s = ""; for (i = 0; i < n; i++) s = s c; return s }
      function uclen(s,   i, n, c) {
        n = 0
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (c >= "\200" && c <= "\277") continue
          n++
        }
        return n
      }
      function uclip(s, w,   i, n, out, c) {
        n = 0; out = ""
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (c >= "\200" && c <= "\277") { out = out c; continue }
          if (n >= w) return out
          n++; out = out c
        }
        return out
      }
      function ufit(s, w,   n) {
        n = uclen(s)
        if (n > w) return uclip(s, w - 1) "…"
        return (w > n) ? s sprintf("%" (w - n) "s", "") : s
      }
      BEGIN { cutoff = now - hours * 3600; span = now - cutoff
              if (span <= 0) span = 1
              R = "\033[0m"; DIM = "\033[90m"; BOLD = "\033[1m"; GRN = "\033[32m" }
      $1 == "LIVE" { livesid[$2] = 1; next }
      $1 == "NAME" { lab[$2] = $3; next }
      $1 == "H" {
        ts = $2 + 0; ev = $3; s = $4
        if (s == "") next
        if (!(s in first) || ts < first[s]) first[s] = ts
        if (!(s in last)  || ts > last[s])  last[s]  = ts
        if (ev == "start") started[s] = 1
        if (ev == "end") endts[s] = ts
        if ($5 != "") pane[s] = $5
        if ($6 != "") hlab[s] = $6
        if ($7 != "") cwd[s]  = $7
        next
      }
      END {
        # Relative axis labels: over a 24h window both absolute ends read as the
        # same HH:MM, which looks like a bug. Per-row times stay absolute.
        left = sprintf("-%dh", hours); rightl = "now"
        pad = barw - length(left) - length(rightl); if (pad < 1) pad = 1
        axis = left rep("─", pad) rightl

        # Sort key 0 so the header lands first whatever the spans are.
        printf "0\t%s%s%s%-11s  %5s  %s%s\n", DIM,
               ufit("agent", namew) "  ", (cwdw > 0 ? ufit("cwd", cwdw) "  " : ""),
               "start–end", "dur", axis, R

        n = 0
        for (s in first) {
          fin = (s in endts) ? endts[s] : ((s in livesid) ? now : last[s])
          if (fin < cutoff) continue                 # ended before the window
          running = (!(s in endts) && (s in livesid))

          # A name may be pinned to the pane rather than the session id, for an
          # agent that got named before it had ever emitted a session id.
          nm = (s in lab) ? lab[s] \
               : (((s in pane) && (pane[s] in lab)) ? lab[pane[s]] \
                  : ((s in hlab) ? hlab[s] : base(cwd[s])))
          if (nm == "") nm = substr(s, 1, 8)

          b0 = int(((first[s] > cutoff ? first[s] : cutoff) - cutoff) / span * barw)
          b1 = int(((fin < now ? fin : now) - cutoff) / span * barw)
          if (b1 <= b0) b1 = b0 + 1
          if (b1 > barw) b1 = barw
          bar = DIM rep("·", b0) R (running ? GRN : "") rep("█", b1 - b0) R \
                DIM rep("·", barw - b1) R

          # A session already running when logging began has no start event, so
          # its bar covers only what we can vouch for. Say so instead of drawing
          # a confident one-second span where a day of work actually was.
          startlbl = (s in started) ? hhmm(first[s]) : "  ?  "
          durlbl   = (s in started) ? dur(fin - first[s]) : "?"
          endlbl = running ? "now  " : hhmm(fin)
          cw = cwd[s] == "" ? "?" \
               : (index(cwd[s], home) == 1 ? "~" substr(cwd[s], length(home) + 1) : cwd[s])
          printf "%d\t%s%s%s  %s%s%s–%s%s  %s%5s%s  %s\n",
                 first[s],
                 (running ? GRN : ""), ufit(nm, namew), R,
                 (cwdw > 0 ? DIM ufit(cw, cwdw) R "  " : ""),
                 DIM, startlbl, endlbl, R,
                 DIM, durlbl, R,
                 bar
          n++
        }
        if (n == 0)
          printf "%s no sessions in the last %d hours%s\n", DIM, hours, R > "/dev/stderr"
      }' | sort -n | cut -f2-
}
