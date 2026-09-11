# lib/tagents/names.sh — what an agent is called, and the window it names
#
# Labels (keyed by session id so they survive docking and resuming), untitle_of — the one shared glyph-stripping rule rows, windows and dialogs must not disagree about — rename_win as the sole tmux rename call site with its @tagents_name stamp, the sync_window_names sweep (133 lines) with its throttle, and the rename dialog itself (rename_agent/ask_rename, moved up from the popup section so the whole naming story is one file). Both section essays — 'names' at 1456-1462 and 'WINDOWS NAMED AFTER THEIR AGENTS' at 1594-1618 — head their halves.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# ---------------------------------------------------------------------------
# names
# ---------------------------------------------------------------------------
# Claude sessions have no name of their own, but Claude does keep the terminal
# title up to date (that is what /rename sets), so the title is the default
# name. A name set here overrides it and is keyed by session id, so it survives
# the pane moving, being docked, or the session being resumed.
LABELS="$STATE_DIR/labels.tsv"

set_label() {
  local keyv=$1 name=$2 tmpf
  [ -z "$keyv" ] && return 1
  mkdir -p "$STATE_DIR" 2>/dev/null
  tmpf="$STATE_DIR/.labels.$$"
  { [ -e "$LABELS" ] && awk -F"$TAB" -v k="$keyv" '$1 != k' "$LABELS"; } >"$tmpf" 2>/dev/null
  [ -n "$name" ] && printf '%s\t%s\n' "$keyv" "$name" >>"$tmpf"
  mv -f "$tmpf" "$LABELS" 2>/dev/null || rm -f "$tmpf"
}

label_of() {
  local keyv=$1
  [ -e "$LABELS" ] || return 0
  awk -F"$TAB" -v k="$keyv" '$1 == k { print $2; exit }' "$LABELS"
}

# THE NAME A TITLE GIVES, in shell — the same rule untitle() applies in list()
# and in sync_window_names, and it has to stay the same rule: the row, the window
# name, the kill dialog and the preview heading are all naming one agent, and a
# heading that says something else reads as the wrong agent entirely.
#
# What the dialogs used to do was `${nm#* }`, which is not "strip the glyph" but
# "drop the first WORD": `Data service architecture` was announced as `service
# architecture` while the row and the window name kept all three. A glyph is one
# character and no letter or digit; anything else is left alone.
untitle_of() {  # <pane title>
  printf '%s\n' "${1:-}" | awk '
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
    { print untitle($0) }'
}

pane_for_sid() {
  local sid=$1 f b
  state_files | while IFS= read -r f; do
    b=${f##*/}
    awk -F"$TAB" -v s="$sid" -v p="%${b%.tsv}" \
        'NR == 1 && $3 == s { print p; exit }' "$f"
  done | head -1
}

# The --label entry point: same as ctrl-r, for scripts and for naming an agent from
# somewhere other than the dashboard.
label_cmd() {
  local keyv=$1 name=${2:-} pane
  [ -n "$keyv" ] || { echo "tagents --label: need a session id or pane id" >&2; return 2; }
  set_label "$keyv" "$name"
  case "$keyv" in
    %[0-9]*) pane=$keyv ;;
    *)       pane=$(pane_for_sid "$keyv") ;;
  esac
  [ -n "$pane" ] && name_window "$pane" "$name"
  return 0
}

# The dashboard is one way to find an agent; the tmux status bar is the other,
# and it is the one that works when you are not looking at the dashboard. So a
# named agent names its window too.
#
# IT NO LONGER REFUSES A SHARED WINDOW. This used to rename only a window the
# agent had to itself, on the grounds that a name describing the pane next door
# is worse than no name — but the only way here is a person typing a name at a
# prompt, about the agent they are looking at, and quietly doing nothing with it
# is worse than either. Which of several agents in one window names it is
# sync_window_names decision; an explicit rename simply wins, until the next
# agent in there is renamed by hand as well.
#
# @tagents_name IS WHAT THE SYNC READS BACK. It is how "tagents named this
# window" is told from "a person did", and only the first of those may ever be
# renamed over. So every rename here records it, and clearing the name clears it
# — the window goes back to tmux automatic name and to the sync decision.
#
# THE ONE PLACE A WINDOW IS RENAMED, because a name does not always come out of
# tmux the way it went in, and both ways it can change are silent.
#
# A `#` IN A NAME IS A FORMAT. rename-window expands what it is handed, so an
# agent titled `Deploy #Staging` named its window `Deploy worktaging` (#S is the
# session name) and `#H` put the host name in — a ticket number in a title is
# enough to trigger it. `##` is the literal one and round-trips exactly.
#
# A NAME STARTING WITH `-` IS A FLAG. `rename-window -t @1 '-wip refactor'` fails
# with "unknown flag -w", hence the `--`.
#
# AND THE STAMP IS WHAT TMUX ENDED UP WITH, never what was asked for.
# @tagents_name is compared against #{window_name} on the next pass to tell our
# own name from a person's, so recording the unescaped request would make the
# window read as one somebody typed — and freeze it at that name for ever. A
# rename that failed records nothing at all, for exactly the same reason.
rename_win() {  # <window id> <name>
  local wid=${1:-} nm=${2:-} esc
  { [ -n "$wid" ] && [ -n "$nm" ]; } || return 1
  esc=$(printf '%s' "$nm" | sed 's/#/##/g')
  tmux rename-window -t "$wid" -- "$esc" 2>/dev/null || return 1
  tmux set -w -t "$wid" @tagents_name \
       "$(tmux display -p -t "$wid" '#{window_name}' 2>/dev/null)" 2>/dev/null
  return 0
}

name_window() {
  local pane=$1 name=$2 win
  case "$pane" in %[0-9]*) ;; *) return 0 ;; esac
  win=$(tmux display -p -t "$pane" '#{window_id}' 2>/dev/null)
  [ -n "$win" ] || return 0
  # A docked agent physically sits in the dashboard window; renaming that would
  # rename the dashboard, not the agent.
  [ "$win" = "$(dash_window)" ] && return 0
  if [ -n "$name" ]; then
    # rename-window turns automatic-rename off for that window by itself, which
    # is what is wanted here: the name is ours now, and @tagents_name is what
    # says so on the next pass. Through rename_win for the escaping and for the
    # stamp — a label with a `#` in it is a name like any other.
    rename_win "$win" "$name"
  else
    # Clearing the name unsets the window-local option so tmux takes the window
    # back, and drops our claim on it with it.
    tmux setw -t "$win" -u automatic-rename 2>/dev/null
    tmux set -uw -t "$win" @tagents_name 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# WINDOWS NAMED AFTER THEIR AGENTS
#
# One pass, safe to run at any time, and run from two places so it works with
# and without a dashboard on screen: the refresher every ~10s while a list is
# up, and counts() — which the tmux status bar calls whether or not it is —
# throttled to one pass every 30s and always in the background.
#
# WHICH AGENT NAMES A WINDOW THEY SHARE: the one with the newest state
# timestamp, tie broken by the lowest pane index. The agent you are actually
# working with names the window. Panes with no name to give are not candidates,
# so a shell split off beside an agent never wins by being newer — its title is
# the host name, which names nothing.
#
# WHAT IS LEFT OUT: the dashboard window and any window a list is running in
# (their name is the dashboard, not an agent), and docked chats — those sit in a
# sidebar window that is skipped anyway, but the marker is the reason, not the
# geography.
#
# AND A NAME A PERSON TYPED IS NEVER OVERWRITTEN. A window is renamed only when
# its current name is tmux automatic one, or the name this function gave it last
# time — recorded in @tagents_name at every rename here and in name_window.
# Anything else was typed by somebody and is left alone, until the day its name
# coincides with one of those two again.
# ---------------------------------------------------------------------------
sync_window_names() {
  local plan line wid nm cur b f
  plan=$({
    # One list-panes for the lot: window options resolve in a pane format, so
    # the window name, its automatic-rename and both markers come back per pane.
    # A literal tab must never go into a tmux format (outside a UTF-8 locale it
    # renders as "_" and every field merges into one), and the title goes last
    # because it is the one field that carries arbitrary text — the same rule
    # collect() follows, for the same reason.
    tmux list-panes -a -F "P|@|#{pane_id}|@|#{window_id}|@|#{pane_index}|@|#{window_name}|@|#{automatic-rename}|@|#{@tagents}|@|#{@tagents_docked}|@|#{@tagents_name}|@|#{pane_title}" 2>/dev/null
    live_panes | sort -u | sed 's/^/L|@|/'
    # The pid in @tagents_list is what tells a list that is running from a
    # marker left behind by one that is gone, so this is asked in shell.
    list_windows | sort -u | sed 's/^/X|@|/'
    [ -e "$LABELS" ] && awk -F"$TAB" '{ print "N|@|" $1 "|@|" $2 }' "$LABELS"
    state_files | while IFS= read -r f; do
      b=${f##*/}; b=${b%.tsv}
      awk -F"$TAB" -v k="%$b" 'NR == 1 { print "S|@|" k "|@|" $1 "|@|" $3; exit }' "$f"
    done
  } | awk -v host="$(hostname -s 2>/dev/null)" -v OFS="$TAB" '
    # Claude prefixes the terminal title with a spinner glyph; the rest is the
    # session title it maintains itself. Same rule as the list — and the same
    # rule untitle_of applies in shell, because the row, this window name and the
    # modal heading are all about one agent.
    #
    # THE GLYPH IS ONE CHARACTER, and that is the whole of the test. This used to
    # strip a leading run of "not alphanumeric" BYTES, and macOS awk counts
    # bytes: every byte of a Cyrillic or CJK word is outside [:alnum:], so
    # "два слова" came back as "слова" — the first word of any non-ASCII title
    # eaten, and here that is written into a window name and into @tagents_name,
    # where it sticks. A leading token is a glyph when it is a single character
    # and not a letter or a digit; anything longer is a word, in whatever
    # alphabet it happens to be written.
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
    # THE DISPLAY NAME, exactly as the list resolves it: the label, by session id
    # first and pane second, else the cleaned pane title, and nothing at all when
    # that is empty or the host name (tmux default title, which names nothing).
    # Never the directory basename the list falls back to — tmux own
    # automatic-rename already names a window after what is running in it, and
    # renaming it after its own project would be a rename fought every pass.
    function disp(dp,   dn) {
      dn = ""
      if ((dp in psid) && psid[dp] != "" && (psid[dp] in lab)) dn = lab[psid[dp]]
      else if (dp in lab) dn = lab[dp]
      else dn = untitle(ptitle[dp])
      return (dn == host) ? "" : dn
    }
    { nf = split($0, a, "\\|@\\|"); kd = a[1] }
    kd == "P" {
      pw[a[2]] = a[3]; pidx[a[2]] = a[4] + 0
      wname[a[3]] = a[5]
      # tmux spells this option 1/0 in a format and on/off in show-options; both
      # are read, and anything else is taken as off — refusing to rename is the
      # safe half of a guess about whose name it is.
      wauto[a[3]] = (a[6] == "1" || a[6] == "on") ? 1 : 0
      if (a[7] != "") skip[a[3]] = 1     # the dashboard window
      if (a[8] != "") pdock[a[2]] = 1    # a chat docked into some sidebar
      wrec[a[3]] = a[9]
      t = a[10]; for (i = 11; i <= nf; i++) t = t "|@|" a[i]
      ptitle[a[2]] = t
      next
    }
    kd == "L" { plive[a[2]] = 1; next }
    kd == "X" { skip[a[2]] = 1; next }   # a window a list is running in
    kd == "N" { lab[a[2]] = a[3]; next }
    kd == "S" { pts[a[2]] = a[3] + 0; psid[a[2]] = a[4]; next }
    END {
      for (p in plive) {
        if (!(p in pw) || (p in pdock)) continue
        wi = pw[p]
        if (wi in skip) continue
        nm = disp(p)
        if (nm == "") continue
        # A pane with no state record has no activity to compare, so it sorts
        # BELOW every pane that has one rather than above them all as a 0 would.
        ts = (p in pts) ? pts[p] : -1
        if (!(wi in bn) || ts > bts[wi] || (ts == bts[wi] && pidx[p] < bix[wi])) {
          bn[wi] = nm; bts[wi] = ts; bix[wi] = pidx[p]
        }
      }
      for (wi in bn) {
        if (bn[wi] == wname[wi]) continue          # already says it
        if (!wauto[wi] && wrec[wi] != wname[wi]) continue   # somebody named it
        print wi, bn[wi]
      }
    }')
  [ -n "$plan" ] || return 0
  # Not IFS="$TAB" read: tab is IFS whitespace, so a name with a leading space
  # would come back trimmed and a rename would never settle.
  while IFS= read -r line; do
    wid=${line%%"$TAB"*}
    nm=${line#*"$TAB"}
    { [ -n "$wid" ] && [ -n "$nm" ] && [ "$wid" != "$nm" ]; } || continue
    # THE PLAN IS A FIFTH OF A SECOND OLD by the time it is applied — one
    # list-panes over every pane of every window, a ps walk and a file per agent
    # — and "a name you typed is never overwritten" has to hold across that gap
    # too. A hand rename landing inside it was clobbered AND stamped as ours,
    # which hands the window over permanently; the sweep runs every ten seconds,
    # so the gap is live a couple of percent of the time. So the three facts the
    # decision rests on are asked again, one round trip before the rename: at
    # most a handful of windows are ever in the plan.
    # The two booleans are answered by tmux itself (a format compares strings
    # perfectly well) and go FIRST, so the window name — the one free-text field
    # — can be read off the end without a separator having to survive it.
    cur=$(tmux display -p -t "$wid" \
            '#{?automatic-rename,1,0}#{?#{==:#{@tagents_name},#{window_name}},1,0}|@|#{window_name}' \
            2>/dev/null)
    [ -n "$cur" ] || continue
    # The first two characters, not everything up to the separator: a tmux too
    # old for #{==:} renders that comparison literally, and reading the answer
    # positionally leaves the automatic-rename half of the guard working — which
    # is the safe half — instead of skipping every window for ever.
    case ${cur:0:2} in
      1?|?1) ;;                      # tmux own name, or still the one we gave it
      *) continue ;;                 # somebody named it since the plan was made
    esac
    [ "${cur#*"|@|"}" = "$nm" ] && continue      # already says it
    rename_win "$wid" "$nm"
  done <<EOF
$plan
EOF
  return 0
}

# HOW OFTEN THE SWEEP RUNS WITH NO DASHBOARD OPEN. counts() is called by the
# status bar of every attached client on every status interval, so the sweep is
# throttled through a stamp file to one pass every 30 seconds — and it still
# runs in the background, because a status bar that waits on a walk over every
# pane of every window is a status bar that stutters.
NAMES_STAMP="$STATE_DIR/.names.ts"
NAMES_EVERY=${TA_NAMES_EVERY:-30}

sync_names_due() {  # 0 at most once every NAMES_EVERY seconds, and stamps it
  local now last
  now=$(date +%s)
  last=$(cat "$NAMES_STAMP" 2>/dev/null)
  case ${last:-x} in ''|*[!0-9]*) last=0 ;; esac
  [ "$(( now - last ))" -ge "$NAMES_EVERY" ] || return 1
  mkdir -p "$STATE_DIR" 2>/dev/null
  # Stamped before the work, not after: several clients redraw at the same
  # instant, and a stamp written at the end would let every one of them start a
  # sweep of its own first.
  printf '%s\n' "$now" >"$NAMES_STAMP" 2>/dev/null
  return 0
}

rename_agent() {
  local pane=$1 sid=${2:-} keyv
  [ "$pane" = "-" ] && return 0
  # Prefer the session id; a session that has not emitted an event yet has none,
  # so fall back to the pane, which is at least stable while it lives.
  keyv=${sid:-$pane}
  prompt 10 --ask-rename "$keyv" "$pane" && return 0
  ask_rename "$keyv" "$pane"
}

ask_rename() {  # the prompt itself — normally the body of the popup
  local keyv=$1 pane=${2:-} cur name rc
  # THE NAME YOU ARE CHANGING IS THE ONE YOU START FROM. A rename is almost
  # always a small edit of the name already there, and retyping it from nothing
  # is how a rename turns into a typo. bash 3.2 has no `read -i` to seed a line
  # with; fzf has --query, and --print-query hands it straight back, so the
  # dialog opens on the current name with the cursor at the end of it. Its list
  # is empty on purpose — there is nothing to pick here, only a line to type.
  cur=$(label_of "$keyv")
  [ -n "$cur" ] || cur=$(preview_name "$pane")
  if [ -t 0 ]; then
    name=$(fzf --print-query --query "$cur" --layout=reverse --height=100% \
             --no-info --prompt='name> ' \
             --header="name this agent
empty clears it · esc cancels" </dev/null)
    rc=$?
    # Esc (130) leaves the label exactly as it was. Every Enter here exits 1 —
    # nothing in the list to accept — and prints the query as its only line.
    [ "$rc" = 130 ] && return 0
    name=${name%%$'\n'*}
  else
    # NO TERMINAL, NO DIALOG: fzf has nothing to draw on when this is driven
    # from a pipe rather than typed into, which is how a scripted rename and the
    # tests reach it. Bounded, because inline (no popup) fzf has handed the
    # terminal over and a read that never returns takes the dashboard with it.
    printf '\033[1mname this agent\033[0m\n'
    printf '\033[90m%s\033[0m\n' "$keyv"
    [ -n "$cur" ] && printf '\033[90mnow: %s\033[0m\n' "$cur"
    printf '\033[90mempty clears it · ctrl-c cancels\033[0m\n> '
    IFS= read -r -t 300 name || return 0
  fi
  set_label "$keyv" "$name"
  name_window "$pane" "$name"
}
