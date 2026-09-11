# lib/tagents/dash.sh — the dashboard itself
#
# dash(): claim the pane (or stay a popup/plain list), decide once whether prompts can be popups and whether ctrl-v is a real window or fzf's own toggle, hand-write every --bind through kb (several carry suffixes a generated loop could not express), and loop fzf against --list until quit — plus dash_header, the one-line header it rebuilds every frame. The 'dashboard' banner at 4845-4847 and the 5192-5197 note ('a new key is two edits') head the file.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# ---------------------------------------------------------------------------
# dashboard
# ---------------------------------------------------------------------------

# The key list, packed into as few lines as fit. fzf TRUNCATES a header, it does
# not wrap one, so in a sidebar 90 columns wide everything from rename onwards
# was simply not on screen — which is no place to keep the key that ends a
# session. Packed from the real width rather than split at a fixed point,
# because the items are not fixed either: enter is labelled differently
# depending on where the list is running, ctrl-q is absent in a popup, and
# TA_RENAME_KEY can be any length.
#
# Two columns go on fzf own left indent and two more on the ellipsis it draws
# when a line still does not fit, so a line has cols - 4 to play with.
keyhdr() {  # <cols> <item>... -> the header, one item per line at worst
  local cols=${1:-80}
  shift
  case $cols in ''|*[!0-9]*) cols=80 ;; esac
  [ "$cols" -lt 24 ] && cols=24
  printf '%s\n' "$@" | awk -v w="$((cols - 4))" '
    function uclen(s,   i, n, c) {
      n = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c >= "\200" && c <= "\277") continue   # UTF-8 continuation byte
        n++
      }
      return n
    }
    { it[++n] = $0 }
    END {
      # Greedy first-fit, which for a fixed width is also the fewest lines
      # possible — so no key is dropped and none is hidden, and a wide dashboard
      # collapses the lot back onto one line by itself. The cap is only there so
      # a pane too narrow to hold the keys spends four rows on them rather than
      # every row it has; past that fzf truncates, as it did for all of them
      # before.
      for (i = 1; i <= n; i++) {
        cand = (line == "") ? it[i] : line " · " it[i]
        if (line != "" && uclen(cand) > w && lines < 3) {
          out = out line "\n"; lines++; line = it[i]
        } else line = cand
      }
      printf "%s%s", out, line
    }'
}

# The one line the dashboard now spends on keys, and the reason keyhdr still
# packs it: at 34 columns even three items need two rows. Everything else moved
# into the ? window, so what is left is the key you cannot guess (enter, whose
# label depends on where the list is running), the key that shows the rest, and
# the way out.
dash_header() {  # <cols> <enter label> [quit item]
  local items=()
  resolve_keys
  [ -n "$K_OPEN" ] && items[${#items[@]}]="$K_OPEN ${2:-open in sidebar}"
  [ -n "$K_KEYS" ] && items[${#items[@]}]="$K_KEYS keys"
  [ -n "${3:-}" ] && items[${#items[@]}]=$3
  keyhdr "${1:-80}" ${items[@]+"${items[@]}"}
}

# A NEW KEY IS TWO EDITS, AND THE SECOND IS NOT OPTIONAL: the --bind below, and
# a row in keys_table(). The bindings are written out by hand because several of
# them carry suffixes the table could only encode verbatim (+reload-sync, the
# popup mode +abort, the execute/execute-silent choice), but the ? window is
# generated from the table alone — so a key bound and not listed is a key nobody
# can find, and a key listed and not bound is a lie. tests/ui.sh fails on either.
dash() {
  local home=${TA_HOME:-} mode=${TA_MODE:-dash} out key rows
  local rc started fails=0 esc_act=ignore quit fl ft
  local header
  local enter_lbl='open in sidebar' preview_win='' sidebar=0 after='' vact
  # The --preview pair, present only where ctrl-v still toggles one. An empty
  # array cannot be expanded under `set -u` in bash 3.2 without the
  # ${x[@]+"${x[@]}"} guard below, and empty is the ordinary case now.
  local pv=() xp=()
  # A prompt that opens a popup returns at once, so fzf never has to give up the
  # screen for it — that is what keeps rename and send from flashing the list.
  # Without popups the prompt has to happen in this pane, which needs `execute`.
  # So does a list that IS a popup: a popup cannot open a second one, so its
  # prompts run inline too, on the tty the popup already has. Without this every
  # prompt in prefix+a mode ran behind execute-silent and was never seen.
  local ask='execute-silent'
  { has_popup && [ "$mode" != popup ]; } || ask='execute'
  [ -z "$home" ] && home=$(tmux display -p '#S' 2>/dev/null)
  if [ -z "$home" ]; then
    echo "tagents: not inside tmux" >&2
    return 1
  fi
  # In a popup Esc is the natural "close this overlay". In the dedicated
  # dashboard session it must not close anything: the window is the session's
  # reason to exist, and losing it leaves you staring at whatever else is there.
  # A popup also closes once it has done what you asked; the sidebar stays.
  # Resolved before the header is built and before a single bind is made,
  # because every one of them now reads the answer out of these variables.
  resolve_keys
  key_warn
  quit=''
  [ -n "$K_QUIT" ] && quit="$K_QUIT quit"
  if [ "$mode" = popup ]; then esc_act=abort; quit=''; after='+abort'; fi

  # A LIST RUNNING IN A PANE IS THE SIDEBAR. Not "is it running in the pane some
  # marker points at" — it claims the pane, so enter docks the chat into the right
  # half of this very window and the cursor lands in it, whichever window that
  # happens to be. Reading the marker instead is what sent you to another window:
  # the marker had drifted onto a chat elsewhere, and enter followed the marker.
  # The docked pane then stands in for fzf's preview — it is the live thing.
  #
  # A popup is the one list with no pane of its own (TMUX_PANE is empty inside
  # display-popup) and nowhere to put a seat, so it keeps the text preview and
  # hands the chat to the dedicated sidebar instead.
  if [ "$mode" != popup ] && [ -n "${TMUX_PANE:-}" ] && claim_dash; then
    trap release_dash EXIT INT TERM
    enter_lbl='open here'
    sidebar=1
  fi

  # CTRL-V IS A MODAL WHEREVER ONE CAN BE HAD, and fzf own preview is then not
  # built at all: a --preview that is only ever hidden is a preview process
  # waiting to be spawned by a key nobody binds to it any more.
  #
  # The two cases that keep the old behaviour are the two where the modal cannot
  # exist, and they are the same condition $ask was derived from a few lines up:
  # a popup cannot open a second popup, and a tmux without display-popup cannot
  # open the first. There ctrl-v stays fzf toggle-preview — and the preview it
  # toggles has to exist, so the pair goes back in.
  vact="$ask($SELF --act preview {1} {3})"
  if [ "$ask" != execute-silent ]; then
    vact=toggle-preview
    # Worked out HERE, where the pair is built, and nowhere else: on the modal
    # path there is no --preview at all and a preview_window computed for it
    # would be a line describing a flag nobody passes. Beside the list in a
    # popup, which has the room and cannot open a modal; hidden until ctrl-v in a
    # sidebar that has none — 55% of a 45% column reads neither half.
    if [ "$sidebar" = 1 ]; then preview_win=hidden
    else preview_win='right,55%,border-left,wrap'; fi
    pv=(--preview="$SELF --preview {1} {3}" --preview-window="$preview_win")
  fi
  # THE BINDINGS, ASSEMBLED RATHER THAN WRITTEN OUT ON THE fzf LINE — because a
  # key can now be configured away, and an unbound verb has to leave no argument
  # behind at all. The action strings are still one per verb and still by hand:
  # several carry suffixes (+reload-sync, the popup +abort, the execute against
  # execute-silent choice) that a loop over keys_table could only encode
  # verbatim. Aliases nobody needs a row in the table for follow the verb they
  # alias: double-click is enter, f2 is the rename key.
  BINDS=()
  kb "$K_OPEN"    "execute-silent($SELF --act open {1} {3} {4} {5})$after"
  kb double-click "execute-silent($SELF --act open {1} {3} {4} {5})$after"
  kb "$K_GOTO"    "execute-silent($SELF --act goto {1})$after"
  kb "$K_BORROW"  "execute-silent($SELF --act borrow {1})$after"
  kb "$K_SEND"    "$ask($SELF --act send {1})$after"
  kb "$K_BESIDE"  "execute-silent($SELF --act beside {1} {3} {4} {5})$after"
  kb "$K_RENAME"  "$ask($SELF --act rename {1} {3} {4})"
  kb f2           "$ask($SELF --act rename {1} {3} {4})"
  kb "$K_UNDOCK"  "execute-silent($SELF --act undock {1})+reload-sync($SELF --list)"
  kb "$K_KILL"    "$ask($SELF --act kill {1} {3} {4})"
  kb "$K_NEW"     "$ask($SELF --act new {1} {3} {4} {5})$after"
  kb "$K_PICK"    "$ask($SELF --act pick {1} {3} {4} {5})$after"
  kb "$K_COLUMNS" "$ask($SELF --act columns)"
  kb "$K_USAGE"   "$ask($SELF --act usage)"
  kb "$K_CLOSED"  "$ask($SELF --act closed)$after"
  kb "$K_KEYS"    "$ask($SELF --act keys {1} {3} {4} {5})$after"
  kb esc          "$esc_act"
  kb "$K_PREVIEW" "$vact"
  kb "$K_TREE"    "execute-silent($SELF --toggle-group)+reload-sync($SELF --list)"
  kb "$K_REFRESH" "reload-sync($SELF --list)"
  kb resize       "reload-sync($SELF --list)"
  kb start        "execute-silent(TA_PORT=\$FZF_PORT nohup $SELF --refresher >/dev/null 2>&1 &)"
  # --expect is the one route quit has, and it is a flag rather than a bind, so
  # it needs the same "not there at all" shape the array gives everything else.
  xp=()
  [ -n "$K_QUIT" ] && xp=(--expect="$K_QUIT")

  export TA_HOME="$home"

  # First frame only: fzf hands every later reload an authoritative FZF_COLUMNS,
  # but the initial list is built before fzf exists. `tput cols` is unreliable
  # here (this runs inside a command substitution, so stdout is a pipe), and in
  # a popup there is no pane to measure — the controlling terminal knows.
  if [ -z "${TA_COLS:-}" ]; then
    TA_COLS=$(stty size </dev/tty 2>/dev/null | cut -d' ' -f2)
    case ${TA_COLS:-x} in ''|*[!0-9]*) TA_COLS='' ;; esac
  fi

  # Terminal flow control has to go. With ixon on, ctrl-s is XOFF: it blocks
  # every write to this tty, so the dashboard goes blank and stays blank, and
  # ctrl-q is XON, which means the documented quit key never reaches fzf.
  stty -ixon 2>/dev/null || true

  while :; do
    rows=$(list)
    [ -z "$rows" ] && rows="-${TAB}$(printf '\033[90m')no claude sessions running$(printf '\033[0m')${TAB}none"
    started=$SECONDS
    # THE FOOTER IS THE ONLY FIXED LINE LEFT. --header is spent on key hints and
    # is computed once per launch; this one is rebuilt every frame here and, for
    # the frames fzf redraws itself, by the refresher through change-footer. An
    # empty array when no account is watched: an unset --footer is no line at
    # all, while --footer="" is a blank row taken off the list.
    unset ft
    fl=$(usage_line footer) && [ -n "$fl" ] && ft=(--footer="$fl")
    header=$(dash_header "${TA_COLS:-80}" "$enter_lbl" "$quit")
    out=$(printf '%s\n' "$rows" | fzf \
      --ansi --no-sort --delimiter="$TAB" --with-nth=2 \
      --listen --height=100% --layout=reverse --info=inline \
      --prompt='agents> ' \
      --header="$header" \
      ${pv[@]+"${pv[@]}"} \
      ${ft[@]+"${ft[@]}"} \
      ${BINDS[@]+"${BINDS[@]}"} \
      ${xp[@]+"${xp[@]}"})
    rc=$?

    if [ $rc -ne 0 ]; then
      [ "$mode" = popup ] && break
      # Never let an abort take the dashboard down — just come back up. Bail out
      # only if fzf is dying instantly, which would otherwise spin forever.
      if [ $(( SECONDS - started )) -lt 1 ]; then
        fails=$((fails + 1))
        [ $fails -ge 5 ] && { echo "tagents: fzf keeps failing, giving up" >&2; break; }
      else
        fails=0
      fi
      continue
    fi
    fails=0

    # Keys do their work inside fzf now, so reaching here means a deliberate
    # quit — or, in a popup, the abort that follows a completed action.
    key=$(printf '%s\n' "$out" | sed -n 1p)
    [ "$key" = ctrl-q ] && break
    [ "$mode" = popup ] && break
  done
}
