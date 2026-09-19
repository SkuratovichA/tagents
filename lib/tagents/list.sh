# lib/tagents/list.sh — the rows — and the tally the status bar shows
#
# list() stays one unit (619 lines): the responsive column fit, the UTF-8-safe width helpers macOS awk forces it to carry, the row format, the group headers, and the seat markers. grouped/toggle_group (the .flat marker list() reads) and counts() (the same renderer with TA_MARKS=0, plus the burn rate and the usage line) sit with it because nothing else calls them and both are meaningless without it.
#
# Part of ./tagents; `tagents --help` is the model this implements.

grouped() {  # tree by directory unless explicitly turned off
  [ "${TA_FLAT:-0}" = 1 ] && return 1
  [ -e "$STATE_DIR/.flat" ] && return 1
  return 0
}

toggle_group() {
  if [ -e "$STATE_DIR/.flat" ]; then rm -f "$STATE_DIR/.flat"; else : >"$STATE_DIR/.flat"; fi
}

list() {
  # Nothing is excluded. There used to be a "skip my own pane" rule that fell
  # back to #{pane_id} when $TMUX_PANE was unset — which resolves through the
  # *attached client*, so it silently hid whichever agent you happened to be
  # looking at. The dashboard pane runs fzf, never Claude, so it can never show
  # up here anyway and needs no special case.
  local grp=1 cols dp seat curseat="" dockedset="" hidecols
  grouped || grp=0
  # Joined with $RS, never newlines: awk -v refuses a value with a newline in it
  # (BWK awk, and silently enough to look like "nothing is hidden").
  hidecols=$(hidden_cols | awk -v rs="$RS" '{ printf "%s%s", $1, rs }')

  # HOW WIDE IS THE ROW. fzf exports FZF_COLUMNS to the children of its execute
  # and reload bindings, which is exactly how --list is re-run, so that is the
  # honest number whether the dashboard is a 45% sidebar or a 92% popup. Falling
  # back to `tput cols` would measure the terminal, not the pane, and every row
  # would overflow the sidebar by more than half its width.
  # FZF_COLUMNS first: it is set per reload, so it is the only value that keeps
  # up with the pane being resized. TA_COLS is the bootstrap for the very first
  # frame (and the hook for testing a width by hand), never an override.
  cols=${FZF_COLUMNS:-${TA_COLS:-}}
  if [ -z "$cols" ] && [ -n "${TMUX_PANE:-}" ]; then
    cols=$(tmux display -p -t "$TMUX_PANE" '#{pane_width}' 2>/dev/null)
  fi
  [ -z "$cols" ] && cols=$(tput cols 2>/dev/null)
  case ${cols:-x} in ''|*[!0-9]*) cols=100 ;; esac
  # A POPUP LIST IS NOT AS WIDE AS THE POPUP. FZF_COLUMNS is the whole window,
  # but in popup mode the preview sits beside the list and takes 55% of it, so
  # the rows have the other 45% to live in and every one of them was being built
  # for more than twice the width it got. Measured anywhere else the number
  # already is the list's own width and stands as it is.
  [ "${TA_MODE:-}" = popup ] && cols=$(( cols * 45 / 100 ))
  [ "$cols" -lt 34 ] && cols=34

  # WHICH CHATS ARE IN THE SIDEBAR, and which of them the cursor is in. With two
  # chats docked side by side the row enter is about to replace is not guessable
  # from the list, so it is marked: the current seat's chat gets a ▶ where the
  # tree draws its dash, every other docked one a dim ▹.
  #
  # TA_MARKS=0 skips the lot, and counts() sets it: working the seats out costs
  # eight round-trips to the tmux server — and dash_pane WRITES on the way, since
  # it clears the markers of lists that are gone — while the status bar reads one
  # field of this and throws every mark away. That is a bill paid on every status
  # interval by every attached client for nothing.
  if [ "${TA_MARKS:-1}" = 1 ]; then
    dp=$(dash_pane)
    if [ -n "$dp" ]; then
      seat=$(current_seat "$dp")
      is_docked "$seat" && curseat=$seat
      dockedset=$(seats "$dp" |
        awk -F"$TAB" -v rs="$RS" '$2 == "docked" { printf "%s%s", $1, rs }')
    fi
  fi

  collect | awk -F"$TAB" -v now="$(date +%s)" -v ttl="$SUB_TTL" \
                -v grp="$grp" -v home="$HOME" -v deadttl="$DEAD_TTL" -v cols="$cols" \
                -v host="$(hostname -s 2>/dev/null)" \
                -v profs="$(prof_pairs)" -v USC="$US" -v RSC="$RS" \
                -v hidecols="$hidecols" '
    # macOS awk counts bytes, so substr and %-Ns cut Cyrillic mid-character and
    # pad it to half width. Count characters instead, and never split one.
    function uclen(s,   i, n, c) {
      n = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c >= "\200" && c <= "\277") continue   # UTF-8 continuation byte
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
    function agestr(t,   d) {
      d = now - t; if (d < 0) d = 0
      if (d < 3600) return sprintf("%d:%02d", int(d/60), d%60)
      return sprintf("%dh%02d", int(d/3600), int((d%3600)/60))
    }
    function base(p,   n, a) { n = split(p, a, "/"); return n ? a[n] : p }
    # keep the tail of a location: "…iana-cms_git:2.1" beats "git@github_com_A"
    function tailfit(s, w) { return (length(s) <= w) ? s : "…" substr(s, length(s)-w+2) }
    function tilde(p) { return (index(p, home) == 1) ? "~" substr(p, length(home)+1) : p }
    function dirname(p) { return (p == home) ? "~" : base(p) }
    # Claude prefixes the terminal title with a spinner glyph; the rest is the
    # session title it maintains itself, which makes a good default name. The
    # twin of the one in sync_window_names, and of untitle_of in shell: one
    # character that is neither letter nor digit is a glyph, anything longer is a
    # word. Counting "not alphanumeric" BYTES instead — which is what this was —
    # ate the first word of every Cyrillic and CJK title, macOS awk having no
    # opinion about characters at all.
    function untitle(t,   utp, uti, utn, utf) {
      utp = index(t, " ")
      if (utp < 2) return t
      utf = substr(t, 1, utp - 1)
      utn = 0
      for (uti = 1; uti <= length(utf); uti++)
        if (substr(utf, uti, 1) < "\200" || substr(utf, uti, 1) > "\277") utn++
      if (utn != 1 || utf ~ /^[0-9A-Za-z]$/) return t
      sub(/^[^ ]+ +/, "", t)
      return t
    }
    function tok(v) {
      if (v <= 0)   return ""
      if (v >= 1e6) return sprintf("%.1fM", v/1e6)
      if (v >= 1e3) return sprintf("%.0fk", v/1e3)
      return sprintf("%d", v)
    }
    # Money, narrow enough for a sidebar column. A session that has spent
    # something must never render as blank, hence the <$.01 floor.
    function money(d) {
      if (d <= 0)     return ""
      if (d >= 1000)  return sprintf("$%.1fk", d/1000)
      if (d >= 100)   return sprintf("$%.0f", d)
      if (d >= 10)    return sprintf("$%.1f", d)
      if (d >= 0.01)  return sprintf("$%.2f", d)
      return "<$.01"
    }
    # claude-opus-4-8 -> opus4.8, claude-haiku-4-5-20251001 -> haiku4.5. The
    # vendor prefix and the dated snapshot suffix carry no information in a
    # column this narrow.
    function shortmodel(m,   s, a, n) {
      if (m == "" || m == "-") return ""
      s = m
      sub(/^claude-/, "", s)
      sub(/-2[0-9][0-9][0-9][0-9][0-9][0-9][0-9]$/, "", s)
      n = split(s, a, "-")
      if (n >= 3) return a[1] a[2] "." a[3]
      if (n == 2) return a[1] a[2]
      return s
    }
    # What the session is on NOW. The status line knows this first-hand and is
    # the only thing that does; tusage can only report the model that answered
    # last, which lags a /model switch by however long you take to type the next
    # prompt — long enough that the column read as simply wrong.
    function curmodel(sq) {
      if (sq != "" && (sq in smdl) && smdl[sq] != "") return shortmodel(smdl[sq])
      return shortmodel(umdl[sq])
    }
    # WHICH LOGIN A SESSION IS ON, named rather than pathed: the profile whose
    # config_dir the hook recorded, or the one profile that has none for a
    # session running with CLAUDE_CONFIG_DIR unset. A dir no profile claims is
    # named after itself, which at least identifies the account. An empty answer
    # means the record predates the column — and "we do not know" must not be
    # rendered as "the default account", which is exactly the thing this column
    # exists to stop being assumed.
    function acctname(cv, hv,   ai, an, ac) {
      if (hv != 1) return ""
      # cfg_expand_dir has already taken any trailing slash off the profile
      # side, so it has to come off here too: without it nothing matched AND the
      # basename fallback below ate the whole string, leaving the column blank —
      # which in this column means "the record predates it", a different answer.
      while (length(cv) > 1 && substr(cv, length(cv), 1) == "/")
        cv = substr(cv, 1, length(cv) - 1)
      an = ""; ac = 0
      for (ai = 1; ai <= npf; ai++) {
        if (pdir[ai] == "") { an = pnm[ai]; ac++; continue }
        if (cv != "" && pdir[ai] == cv) return pnm[ai]
      }
      if (cv == "") return (ac == 1) ? an : "default"
      ai = cv
      sub(/^.*\//, "", ai)
      sub(/^\./, "", ai)
      return ai
    }
    # THE SAME ANSWER IN ONE CHARACTER, and that is the entire point of it: the
    # acct column is 8 wide and only exists on the two widest lists, while "which
    # login is this" is a question worth answering on every row of a 45% sidebar.
    # Resolved the way acctname resolves, spelled differently: the badge of the
    # profile that claims the dir, "·" for the
    # default account when no single profile claims it, "?" for a config dir no
    # profile knows about, and a SPACE for a record written before the account
    # was recorded — saying nothing, in the column width, rather than guessing.
    # Scratch names prefixed rather than trusted to be free: bn is a live global
    # a few lines further down, and in a program this long the next collision is
    # a matter of time (BWK awk kills the whole program over one).
    function badgeof(cv, hv,   bgi, bgn, bgc) {
      if (hv != 1) return " "
      # Trailing slash off, for the reason acctname gives: the hook records what
      # CLAUDE_CONFIG_DIR held and the profile side has already been stripped.
      while (length(cv) > 1 && substr(cv, length(cv), 1) == "/")
        cv = substr(cv, 1, length(cv) - 1)
      bgn = ""; bgc = 0
      for (bgi = 1; bgi <= npf; bgi++) {
        if (pdir[bgi] == "") { bgn = pbdg[bgi]; bgc++; continue }
        if (cv != "" && pdir[bgi] == cv) return pbdg[bgi]
      }
      if (cv == "") return (bgc == 1) ? bgn : "·"
      return "?"
    }
    # RESPONSIVE COLUMNS. A row that does not fit is not merely ugly: fzf hard
    # -truncates it, so in a narrow sidebar the detail, then the location, then
    # the cost silently vanished with nothing to say they had. Columns are now
    # dropped in a deliberate order instead — the ones that answer "which agent
    # and how urgent" survive to the very last, and the state word goes early
    # because its icon already carries the same information in colour.
    function fitcols(   avail, n) {
      # The tree prefix, or in flat mode the two columns the docked marker is
      # drawn in, are both added after this and both have to be paid for here.
      # The tree gets its mark for nothing — it is drawn where the tee was
      # drawing a dash anyway, so `  └` + mark + a space is the same five columns
      # `  └─ ` always cost. A flat row has no tee to borrow from, so it pays two
      # columns of body width for the marker slot, marked or not. Stated rather
      # than implied: it is a real, if small, loss against the flat rows of every
      # version before the marks, and the alternative — a mark only on the rows
      # that have one — would misalign the whole list.
      avail = cols - (grp ? 5 : 2)
      # mdlw goes early in the drop order: which model a session is on matters
      # less than what it is doing and what it has cost, and the cost column
      # already implies the tier.
      # acctw goes earlier still. Which account an agent is on is a thing you
      # check once and then trust, unlike the state and the money; and on all but
      # the widest lists it is answered by the project column beside it anyway.
      if      (avail >= 128) { lw=7; namew=24; ctxw=5; burnw=6; mdlw=9; acctw=8; locw=16 }
      else if (avail >= 112) { lw=7; namew=22; ctxw=5; burnw=6; mdlw=8; acctw=8; locw=12 }
      else if (avail >=  98) { lw=7; namew=24; ctxw=5; burnw=6; mdlw=0; acctw=0; locw=14 }
      else if (avail >=  80) { lw=7; namew=22; ctxw=5; burnw=6; mdlw=0; acctw=0; locw=0  }
      else if (avail >=  66) { lw=0; namew=20; ctxw=5; burnw=6; mdlw=0; acctw=0; locw=0  }
      else if (avail >=  50) { lw=0; namew=18; ctxw=5; burnw=0; mdlw=0; acctw=0; locw=0  }
      else if (avail >=  38) { lw=0; namew=14; ctxw=5; burnw=0; mdlw=0; acctw=0; locw=0  }
      else                   { lw=0; namew=12; ctxw=0; burnw=0; mdlw=0; acctw=0; locw=0  }
      # ROOM TO SPARE IS ROOM FOR THE NAME. The table stops at 128 because that
      # is where every column fits at its full width — but a 230-column pane was
      # then laid out exactly like a 133-column one, with the whole surplus going
      # to the detail and names still cut at 24. A third of the surplus goes to
      # the name and a ninth of it to the location, capped so a very wide pane
      # does not turn the list into a field of padding. It starts above 140
      # rather than 128 so every width the tests pin renders byte for byte what
      # it always did.
      if (avail > 140) {
        n = int((avail - 140) / 3)
        if (n > 24) n = 24
        namew += n
        locw += int(n / 3)
      }
      # The badge is at EVERY breakpoint — two columns for the answer the 8-wide
      # acct column gives only on the widest lists, which is what it is for. It
      # is zero when nothing is configured, so a user with no config file gets
      # byte for byte the rows this printed before it existed.
      bdgw = badgew
      # THE PROJECT COLUMN OF A FLAT ROW IS NOT THE LOCATION COLUMN. Flat mode
      # has no group headers, so this 14-wide column is the only thing on the
      # row that says which project the agent belongs to — and it was drawn
      # under locw, which meant hiding `loc` ("which pane the agent is in")
      # silently took the project away as well. Its own width, taken from the
      # breakpoint before anything is hidden, so it still goes when the pane is
      # genuinely too narrow for it and stays when a column is turned off.
      projw = (!grp && locw) ? 14 : 0
      # A hidden column is zeroed HERE, before the arithmetic below, so its width
      # goes to the detail column exactly as a narrow pane would give it there.
      # Nothing moves: the order the columns are drawn in never changes.
      if ("badge" in hid) bdgw = 0
      if ("ctx"   in hid) ctxw = 0
      if ("cost"  in hid) burnw = 0
      if ("model" in hid) mdlw = 0
      if ("acct"  in hid) acctw = 0
      if ("loc"   in hid) locw = 0
      # A COLUMN IS ONLY WORTH DROPPING IF THE DETAIL NEEDS THE ROOM. Between 80
      # and 112 columns the table drops the model and the account outright and
      # hands their width to a detail line that is usually far shorter than the
      # space it is handed. Put them back while the detail still has twelve
      # columns left to say something in, model first — the reverse of the order
      # they were dropped in, so the one that went last comes back first. A
      # column the user has hidden stays hidden: this restores widths, not
      # decisions.
      if (avail >= 80 && avail < 112) {
        if (!mdlw  && !("model" in hid) && avail - (fixedw() + 9) - 1 >= 12) mdlw  = 8
        if (!acctw && !("acct"  in hid) && avail - (fixedw() + 9) - 1 >= 12) acctw = 8
      }
      # THE NAME COLUMN FITS THE NAMES. The tiers above guess a width before a
      # single row is known, and every column hidden with ctrl-w hands its
      # width to the detail on the right — a list with everything hidden was
      # cutting names at 22 characters beside sixty columns of nothing. Once the
      # rows are in (END measures them and calls this again), the column grows
      # to the longest name present. The detail keeps ten columns and no more:
      # it is the last tool line, worth having, but somebody who hid the other
      # columns to see names on a 61-column sidebar wants the names — on that
      # pane a 24-column floor was exactly all the slack there was. The cap
      # keeps a pathological title from eating the row. maxnm is 0 on the first
      # call, so BEGIN is unchanged.
      if (maxnm > namew) {
        slack = avail - fixedw() - 1 - 10
        grow = maxnm - namew
        if (grow > slack) grow = slack
        if (namew + grow > 64) grow = 64 - namew
        if (grow > 0) namew += grow
      }
      fixed = fixedw()
      detw = avail - fixed - 1
      if (detw < 6) detw = 0
    }
    # What every column but the detail costs, at the widths fitcols has settled
    # on so far — asked while it is still deciding, and once more when it has.
    function fixedw() {
      # 2 icon, lw + its space, 6 age + 2, badge + 1, name + 1, then what is left
      return 2 + (lw ? lw + 1 : 0) + 8 + (bdgw ? bdgw + 1 : 0) + namew + 1 \
             + (projw ? projw + 1 : 0) \
             + (ctxw ? ctxw + 1 : 0) + (burnw ? burnw + 1 : 0) \
             + (mdlw ? mdlw + 1 : 0) + (acctw ? acctw + 1 : 0) \
             + (locw ? locw + 1 : 0)
    }
    # Context is the number that decides whether to keep going or /compact: at
    # 200k the long-context premium starts, and everything past it is re-read
    # from cache on every single request.
    function ctxcol(v) {
      if (v >= 600000) return "\033[1;31m"
      if (v >= 200000) return "\033[33m"
      return "\033[90m"
    }
    function nameof(p, s, dir,   n) {
      n = (s != "" && (s in lab)) ? lab[s] : ((p in lab) ? lab[p] : untitle(title[p]))
      # A headless session keeps no terminal title, so the title half above is
      # always empty for one. $TA_LABEL is what whatever started it called it —
      # "ticket-agent" says far more than the basename of a directory.
      if (n == "" && (p in hlbl)) n = hlbl[p]
      if (n == "" || n == host) n = base(dir)
      return n
    }
    BEGIN {
      # name<US>expanded config_dir<US>badge, joined with RS rather than
      # newlines: awk -v rejects a value containing one (see live_panes).
      npf = 0; badgew = 0
      npa = split(profs, pfa, RSC)
      for (pfi = 1; pfi <= npa; pfi++) {
        if (pfa[pfi] == "") continue
        pfk = index(pfa[pfi], USC)
        if (pfk == 0) continue
        npf++
        pnm[npf] = substr(pfa[pfi], 1, pfk - 1)
        pfrest = substr(pfa[pfi], pfk + 1)
        pfk = index(pfrest, USC)
        if (pfk == 0) { pdir[npf] = pfrest; pbdg[npf] = "" }
        else { pdir[npf] = substr(pfrest, 1, pfk - 1); pbdg[npf] = substr(pfrest, pfk + 1) }
        # Two characters is the whole promise of this column, and a badge that
        # ignores it is not merely ugly: badgew is applied at EVERY breakpoint,
        # so `badge: personal!` widened every row by eight columns and took the
        # detail column with it on a 45-column sidebar. Clipped rather than
        # refused — a config nobody reads an error from still names its account.
        # uclip, not substr: a badge may be one multi-byte glyph, and cutting it
        # by bytes would leave half a character in the column.
        if (uclen(pbdg[npf]) > 2) pbdg[npf] = uclip(pbdg[npf], 2)
        # The column is as wide as the widest badge anyone configured — 1 unless
        # somebody writes two characters — and it is measured in characters,
        # since a badge may perfectly well be one multi-byte glyph.
        if (uclen(pbdg[npf]) > badgew) badgew = uclen(pbdg[npf])
      }
      nhc = split(hidecols, hca, RSC)
      for (hci = 1; hci <= nhc; hci++) if (hca[hci] != "") hid[hca[hci]] = 1
      # After the two tables above, not before: it reads both of them.
      fitcols()
      R = "\033[0m"; DIM = "\033[90m"; BOLD = "\033[1m"
      # BLOCKED is reserved for an agent that has actually asked you something
      # and cannot go on until you answer. A turn that simply ended is IDLE —
      # nothing is stuck, it is just your move — and the hook folds Claude Code
      # idle ping into the same state, since it says nothing "done" did not.
      prio["blocked"]=0; icon["blocked"]="⚠"; lbl["blocked"]="BLOCKED"; col["blocked"]="\033[1;33m"
      prio["done"]   =1; icon["done"]   ="✓"; lbl["done"]   ="IDLE";    col["done"]   ="\033[36m"
      prio["working"]=2; icon["working"]="●"; lbl["working"]="working"; col["working"]="\033[32m"
      prio["new"]    =3; icon["new"]    ="○"; lbl["new"]    ="new";     col["new"]    ="\033[90m"
      prio["?"]      =4; icon["?"]      ="·"; lbl["?"]      ="?";       col["?"]      ="\033[90m"
      prio["dead"]   =5; icon["dead"]   ="✗"; lbl["dead"]   ="closed";  col["dead"]   ="\033[90m"
      norder = split("blocked done working new ? dead", ORD, " ")
    }
    $1=="P" { alive[$2]=1; loc[$2]=$3; title[$2]=$4; path[$2]=$5; next }
    $1=="L" { live[$2]=1; next }
    $1=="R" { root[$2]=$3; next }
    $1=="N" { lab[$2]=$3; next }
    # A SESSION WITH NO PANE. hlive is the kill -0 the shell made of the pid the
    # hook recorded (awk cannot ask) and hlbl is its $TA_LABEL — the two answers
    # a pane would have given for anybody else.
    $1=="H" { hless[$2]=1; hlive[$2]=$3+0; hlbl[$2]=$4; next }
    # WHEN YOU LAST TYPED INTO THAT SESSION — the file the hook writes on
    # UserPromptSubmit and on no other event, so it is the only clock in here
    # that does not move while a turn runs. Both the age column and the row
    # order are taken from it; ts[] below stays what it always was, the time of
    # the last event of any kind, because that is what DEAD_TTL measures.
    $1=="T" { pts[$2]=$3+0; next }
    # "idle" was what SessionStart used to write, before that state was renamed
    # to "new" and "idle" became the label of a finished turn. A session that
    # started under the old hook and has not fired an event since would show as
    # "?" forever without this.
    $1=="S" { ts[$2]=$3; st[$2]=($4 == "idle" ? "new" : $4); sid[$2]=$5; cwd[$2]=$6
              det[$2]=$8; cfgd[$2]=$9; hascfg[$2]=$10; next }
    $1=="B" { if (now - $3 < ttl) subs[$2]++; next }
    # tusage --sessions: sid, cost, reqs, ctx, last, slug, subagent cost, live
    # subagents, cost in the last 5h, model, $, $ in the last 5h, $ subagents,
    # unpriced-request count. The dollar figures are priced per request at the
    # model that produced it, so they stay right across a mid-session /model and
    # across subagents deliberately run on a cheaper tier; umdl is only what the
    # session is on NOW, and is never used to compute money.
    # claude-statusline.sh: the model the session is configured on right now, and
    # Claude Code own running cost for it. That figure is not an estimate — it is
    # what is actually being billed, including the requests that never reach the
    # transcript at all (retries, title and summary generation), which is why it
    # wins over the priced one wherever it exists.
    $1=="M" { smdl[$2]=$3; if ($4 + 0 > 0) scost[$2]=$4 + 0; next }
    $1=="U" { uctx[$2]=$5+0; u5h[$2]=$10+0; usub[$2]=$8+0; utot[$2]=$3+0
              umdl[$2]=$11; uusd[$2]=$12+0; uusd5h[$2]=$13+0; uusdsub[$2]=$14+0
              uunp[$2]=$15+0; next }
    END {
      # A session id that is running right now must not also be offered as a
      # closed one: resuming re-registers under a new pane, and the old record
      # lingers until its file is cleaned up.
      for (p in alive) if ((p in live) && (p in sid)) livesid[sid[p]] = 1
      # Same rule for a pane-less session: while its process is alive, an older
      # paned record of the same conversation must not also be offered as closed.
      for (p in hless) if (hlive[p] && (p in sid)) livesid[sid[p]] = 1

      for (p in alive) seen[p] = 1
      for (p in st)    seen[p] = 1

      # The row names, measured before any row is drawn — the same selection
      # the loop below makes, so a record it would skip cannot widen the column.
      maxnm = 0
      for (p in seen) {
        isalive = (p in alive); islive = isalive && (p in live)
        # A headless row has no pane to be alive IN: the recorded pid, checked
        # by collect(), is the whole of its liveness. Applied before anything is
        # measured or drawn, so such a row goes down both branches below exactly
        # as a paned one does.
        if (p in hless) { isalive = hlive[p]; islive = hlive[p] }
        if (islive) {
          dir = (p in st && cwd[p] != "") ? cwd[p] : path[p]
        } else {
          if (!(p in st)) continue
          if (now - ts[p] > deadttl) continue
          if (sid[p] != "" && (sid[p] in livesid)) continue
          dir = (cwd[p] != "") ? cwd[p] : path[p]
        }
        if (dir == "") dir = "(unknown)"
        l = uclen(nameof(p, (p in sid) ? sid[p] : "", dir))
        if (l > maxnm) maxnm = l
      }
      fitcols()

      n = 0
      for (p in seen) {
        isalive = (p in alive); islive = isalive && (p in live)
        if (p in hless) { isalive = hlive[p]; islive = hlive[p] }

        if (islive) {
          if (p in st) {
            s = st[p]; d = det[p]
            # Not ts[p]: the age column answers "how long since MY last message",
            # which is how much of the one-hour prompt cache is left — so an
            # agent that has been grinding for twenty minutes says 20:00, not the
            # 0:00 its last tool call would have said. Sessions recorded before
            # the hook wrote this file have nothing to fall back on but the event
            # time, which for a finished turn is within a turn of the right one.
            said = ((p in pts) && pts[p] > 0) ? pts[p] : ts[p]
            age = now - said; agetxt = agestr(said)
            dir = (cwd[p] != "") ? cwd[p] : path[p]
          } else {
            # Claude is running but no hook has fired yet. The name column
            # already carries its title, so leave the detail empty.
            s = "?"; d = ""; age = 0; agetxt = "  --"; dir = path[p]
          }
          if (!(s in prio) || s == "dead") s = "?"
        } else {
          # No Claude process in this pane. Worth showing only if we know what
          # it was, recently enough to be worth resuming.
          if (!(p in st)) continue
          if (now - ts[p] > deadttl) continue
          if (sid[p] != "" && (sid[p] in livesid)) continue
          s = "dead"
          said = ((p in pts) && pts[p] > 0) ? pts[p] : ts[p]
          age = now - said; agetxt = agestr(said)
          dir = (cwd[p] != "") ? cwd[p] : path[p]
          # A headless session is never offered for resume: there is no pane to
          # bring it back into and nobody to type at it. Say that, rather than
          # promising an enter that will only refuse.
          if (p in hless)        d = "headless, ended — nothing to resume"
          else if (sid[p] != "") d = "closed — enter resumes it"
          else                   d = "closed, no session id — cannot resume"
        }
        if (dir == "") dir = "(unknown)"
        # The loc column says WHERE the agent is, and for a headless one the
        # answer is the thing worth knowing before pressing enter: nowhere.
        where = (p in hless) ? "headless" : (isalive ? loc[p] : "—")

        # Group by the repo, but keep the subdirectory visible on the row so a
        # session started deeper in the tree is still identifiable.
        grpkey = (dir in root) ? root[dir] : dir
        subp = (grpkey != dir) ? substr(dir, length(grpkey) + 2) "  " : ""

        n++; rp[n] = p; rs[n] = s; rage[n] = age; rg[n] = grpkey
        rdead[n] = (s == "dead") ? 1 : 0
        rsid[n] = (p in sid) ? sid[p] : ""
        pre = (islive && subs[p] > 0) ? sprintf("⑂%d ", subs[p]) : ""
        nm = nameof(p, rsid[n], dir)

        # Cost columns. ctx is the live context size — the thing that decides
        # whether this session should be compacted; burn is what it has spent in
        # the last five hours, which is the window the plan limit rolls over.
        # Both are joined on the session id, so they follow a resumed session.
        sq = rsid[n]
        cx = (sq in uctx) ? uctx[sq] : 0
        bn = (sq in u5h)  ? u5h[sq]  : 0
        sb = (sq in usub) ? usub[sq] : 0
        # Session total. Claude Code own ledger when the status line has reported
        # one, the per-request priced estimate otherwise — a closed session, or
        # one that has not rendered a status line yet, has only the estimate.
        ud = (sq in uusd) ? uusd[sq] : 0
        exact = (sq in scost)
        if (exact) ud = scost[sq]
        udsub = (sq in uusdsub) ? uusdsub[sq] : 0
        unp = (sq in uunp) ? uunp[sq] : 0
        gburn[grpkey] += (sq in uusd5h) ? uusd5h[sq] : 0
        # Built field by field rather than as one format string: which fields
        # exist at all depends on the width, and a %-Ns of a field that was
        # dropped still costs its N spaces.
        row = sprintf("%s%s%s%s", col[s], icon[s], (lw ? sprintf(" %-*s", lw, lbl[s]) : ""), R)
        row = row sprintf(" %6s  ", agetxt)
        # Immediately before the name, where the eye is already going. Padded
        # with ufit rather than %-*s: "·" is three bytes and %-*s pads by them.
        if (bdgw)
          row = row sprintf("%s%s%s ", DIM,
                            ufit(badgeof((p in cfgd) ? cfgd[p] : "",
                                         (p in hascfg) ? hascfg[p] : 0), bdgw), R)
        row = row ufit(nm, namew)
        # Flat mode only: in the tree the group header above the row says this.
        if (projw) row = row sprintf(" %s%-*.*s%s", DIM, projw, projw, base(grpkey), R)
        if (ctxw)  row = row sprintf(" %s%*s%s", ctxcol(cx), ctxw, tok(cx), R)
        # What this session has cost, priced per request at the model that ran
        # it. A trailing ? means some of it ran on a model with no published
        # rate, so the figure is a floor rather than the whole bill.
        # An estimate is never shown as though it were the bill. "~" means this
        # is tusage pricing the transcript, which cannot see retries, titles or
        # summaries and so reads a few percent — sometimes a fifth — under what
        # Claude Code says. "?" on top of that means part of it ran on a model
        # with no rate at all, so it is a floor.
        # Built as a string first, because the markers only mean anything
        # when there is a figure to mark: money() returns nothing at all below a
        # cent, and prefixing that left a lone "~" sitting in the column of every
        # session that had not spent anything yet.
        udtxt = money(ud)
        if (udtxt != "")
          udtxt = (exact ? "" : "~") udtxt (!exact && unp > 0 ? "?" : "")
        if (burnw) row = row sprintf(" %s%*s%s", DIM, burnw, udtxt, R)
        if (mdlw)  row = row sprintf(" %s%-*.*s%s", DIM, mdlw, mdlw, curmodel(sq), R)
        if (acctw) row = row sprintf(" %s%-*.*s%s", DIM, acctw, acctw,
                                     acctname((p in cfgd) ? cfgd[p] : "",
                                              (p in hascfg) ? hascfg[p] : 0), R)
        if (locw)  row = row sprintf(" %s%-*s%s", DIM, locw, tailfit(where, locw), R)
        # The subagent share of that money — the answer to "why is this session
        # expensive when I have barely typed into it".
        if (udsub > 0 && burnw) pre = pre sprintf("%s⑂%s%s ", DIM, money(udsub), R)
        if (detw) {
          dtl = subp d
          if (uclen(dtl) > detw) dtl = uclip(dtl, detw - 1) "…"
          row = row " " pre DIM dtl R
        } else if (pre != "") row = row " " pre
        rbody[n] = row

        # The most urgent state in the project, which is what decides whether
        # its header is bold and whether the whole project sinks to the closed
        # section — and nothing else. It used to be the sort key too, which is
        # what made a project climb the list the moment one of its agents blocked
        # and drop back when you answered it.
        if (!(grpkey in gtotal) || prio[s] < gmin[grpkey]) gmin[grpkey] = prio[s]

        # A group header stands in for the row directly under it, so it carries
        # the state, session and directory of that member too — otherwise enter
        # on the header of a closed project could not resume it, having no id.
        # "Directly under it" is the row order below, so the member is picked on
        # the same key: open, then most recently typed into.
        # (No apostrophes in here: the whole program is one single-quoted string.)
        if (!(grpkey in gtotal) || rdead[n] < gtdead[grpkey] ||
            (rdead[n] == gtdead[grpkey] && age < gtage[grpkey])) {
          gtdead[grpkey] = rdead[n]; gtage[grpkey] = age; gfirst[grpkey] = p
          gstate[grpkey] = s; gsid[grpkey] = rsid[n]; gdir[grpkey] = dir
        }
        gtotal[grpkey]++
        gcount[grpkey SUBSEP s]++
      }

      if (grp) {
        for (g in gtotal) {
          badge = ""
          for (i = 1; i <= norder; i++)
            if (gcount[g SUBSEP ORD[i]])
              badge = badge sprintf("%s%s%d%s ", col[ORD[i]], icon[ORD[i]], gcount[g SUBSEP ORD[i]], R)
          # A project with nothing running is dimmed and sinks below every
          # project that still has a live agent, so the closed ones read as
          # their own section rather than being mixed in.
          # The full path is the first thing to drop: the basename already says
          # which project it is, and the header must never be the widest line.
          gpath = (cols >= 92) ? sprintf("  %s%s%s", DIM, tilde(g), R) : ""
          # The five-hour total is money like any other, so it goes when the cost
          # column goes: hiding the dollars on the rows and leaving them on the
          # header would be hiding nothing at all. Built before the sprintf
          # rather than as a third ternary in it — BWK awk will not take a
          # newline after the "?" of one.
          gbt = ""
          if (gburn[g] > 0 && cols >= 60 && !("cost" in hid))
            gbt = sprintf("%s%s/5h%s", DIM, money(gburn[g]), R)
          hdr = sprintf("%s▾ %s%s%s  %s%s",
                        (gmin[g] < prio["dead"] ? BOLD : DIM), dirname(g), R, gpath, badge, gbt)
          printf "%d\t%s\t0\t0\t0\t%s\t%s\t%s\t%s\t%s\n",
                 (gmin[g] < prio["dead"] ? 0 : 1), g, gfirst[g], hdr,
                 gstate[g], gsid[g], gdir[g]
        }
      }
      # THE ORDER, and the two things it is deliberately NOT sensitive to:
      # state, and anything that moves during a turn. Projects keep the place
      # their path puts them (field 1 is only open-or-closed, field 2 the path),
      # so answering a blocked agent no longer drags its project up the list and
      # back down again. Inside a project a row sorts on how recently YOU typed
      # into it — the newest conversation on top, an agent that is working
      # usually being the one you just sent something to — and that clock only
      # moves when you press enter, so two working agents cannot trade places
      # while they run. Closed agents keep to the bottom of their project, as
      # closed-only projects keep to the bottom of the list.
      for (i = 1; i <= n; i++)
        printf "%d\t%s\t1\t%d\t%d\t%s\t%s\t%s\t%s\t%s\n",
               (grp ? (gmin[rg[i]] < prio["dead"] ? 0 : 1) : rdead[i]),
               (grp ? rg[i] : ""),
               rdead[i], rage[i], rp[i], rbody[i], rs[i], rsid[i], rg[i]
    }' |
    sort -t"$TAB" -k1,1n -k2,2 -k3,3n -k4,4n -k5,5n |
    awk -F"$TAB" -v grp="$grp" -v cur="$curseat" -v dks="$dockedset" -v RSC="$RS" '
      # The marker is drawn where the tee draws its dash, so a docked row is no
      # wider than any other and nothing shifts when a chat is docked. In flat
      # mode there is no tee to borrow from, so the two columns are given to
      # every row instead and come out of the body — fitcols says what that
      # costs.
      BEGIN {
        DIM = "\033[90m"; R = "\033[0m"; HOT = "\033[1;33m"
        ndk = split(dks, dka, RSC)
        for (di = 1; di <= ndk; di++) if (dka[di] != "") isdock[dka[di]] = 1
      }
      { g[NR]=$2; kind[NR]=$3; pane[NR]=$6; body[NR]=$7; state[NR]=$8; sid[NR]=$9; dir[NR]=$10 }
      END {
        for (i = 1; i <= NR; i++) {
          # A group header carries its most urgent member pane id too, and a
          # header is not a chat: it is never marked.
          if (kind[i] == 0)                     mk = DIM "─" R
          else if (cur != "" && pane[i] == cur) mk = HOT "▶" R
          else if (pane[i] in isdock)           mk = DIM "▹" R
          else                                  mk = grp ? DIM "─" R : " "
          if (!grp)              tee = mk " "
          else if (kind[i] == 0) tee = ""
          else tee = DIM "  " ((i == NR || g[i+1] != g[i]) ? "└" : "├") R mk " "
          print pane[i] "\t" tee body[i] "\t" state[i] "\t" sid[i] "\t" dir[i]
        }
      }'
}

counts() {
  # The window names are swept from here as well as from the refresher, so they
  # keep up for somebody who never opens the dashboard at all: the status bar is
  # the one thing that runs either way. Backgrounded and throttled — see
  # sync_names_due — and started before the counting so the two overlap.
  if sync_names_due; then
    sync_window_names >/dev/null 2>&1 &
  fi
  # A config with something wrong in it, ahead of the counts: the status bar is
  # there whether or not the dashboard is open, and a profile pointing nowhere
  # is worth a glance before the next agent starts on it. Nothing at all when
  # nothing is wrong, so the bar of a good config is unchanged to the byte.
  cfg_count_cached
  [ "$CFG_NPROBLEMS" -gt 0 ] && printf '#[fg=magenta]cfg!%d ' "$CFG_NPROBLEMS"
  # TA_MARKS=0: the status bar wants field 3 of every row and nothing else, so
  # the seat marks would be computed and thrown away — see list().
  TA_MARKS=0 list | awk -F"$TAB" '
    # Group headers carry the state of their most urgent member, so counting
    # every row made a single blocked agent show up twice in the status bar.
    index($2, "\342\226\276") > 0 { next }   # UTF-8 for the header marker
    { n[$3]++ }
    END {
      out = ""
      if (n["blocked"]) out = out sprintf("#[fg=yellow]⚠%d ", n["blocked"])
      if (n["done"])    out = out sprintf("#[fg=cyan]✓%d ",   n["done"])
      if (n["working"]) out = out sprintf("#[fg=green]●%d ",  n["working"])
      printf "%s#[default]", out
    }'
  # ...followed by what the last five hours cost, so the number that decides
  # whether you are about to hit the limit is on screen without asking.
  command -v tusage >/dev/null 2>&1 && tusage --no-update --burn 2>/dev/null
  # ...and then the month against its limit, for the one account being watched.
  # Prints nothing at all when no usage block names one, so the status bar of a
  # config without the feature is unchanged to the byte.
  usage_line status
}
