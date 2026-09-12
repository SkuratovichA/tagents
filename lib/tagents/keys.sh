# lib/tagents/keys.sh — every key, and where it comes from
#
# KEY_DEFAULTS as the single source of truth (fzf silently drops a duplicate --bind, so a collision is only visible from the whole table, and table order is precedence order), key_valid/resolve_keys/key_warn's once-per-process resolution into the K_* variables, kb/BINDS for dash(), keys_table (which tests/ui.sh pins against the real argv), the ? window (ask_keys/keys_window/keys_height), and keyhdr — the greedy header packer, moved in from the 'dashboard' banner because what it packs is the key list.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# ---------------------------------------------------------------------------
# keys: every one of them, and where each one comes from
# ---------------------------------------------------------------------------
# EVERY KEY, ITS DEFAULT, AND THE VARIABLE THE REST OF THE FILE READS IT FROM.
# One table for the lot, because a collision is only visible from the whole set:
# fzf keeps the LAST --bind for a key and drops the earlier one without a word,
# so two verbs configured onto one key is a verb that silently stopped existing.
# The order here is the order of keys_table, and it is also the order of
# precedence — an earlier verb keeps a key a later one asks for.
#
# closed is ctrl-y and not the ctrl-b it was born with: ctrl-b is the tmux
# prefix on a default install, so it never reached the list at all.
KEY_DEFAULTS="open enter K_OPEN
beside ctrl-s K_BESIDE
new ctrl-n K_NEW
pick ctrl-p K_PICK
goto ctrl-g K_GOTO
borrow ctrl-o K_BORROW
send ctrl-e K_SEND
rename ctrl-r K_RENAME
undock ctrl-u K_UNDOCK
kill ctrl-x K_KILL
tree ctrl-t K_TREE
preview ctrl-v K_PREVIEW
refresh ctrl-l K_REFRESH
columns ctrl-w K_COLUMNS
usage \$ K_USAGE
closed ctrl-y K_CLOSED
keys ? K_KEYS
quit ctrl-q K_QUIT"
KEYS_RESOLVED=''
KEY_NOTES=''
KEY_TAKEN=' '
KEY_NL='
'

# WHAT FZF WILL ACCEPT, CHECKED BEFORE IT IS HANDED OVER. A --bind fzf cannot
# parse makes it refuse to start, and fzf refusing to start IS the dashboard not
# starting — so a typo in the config has to be caught here rather than found out
# there. The names are fzf's own (0.74); anything else is a key only if it is a
# single character, which is how $ and ? got in.
key_valid() {  # <key>
  case $1 in
    ctrl-[a-z]|alt-[a-z]|alt-[0-9]|f[1-9]|f1[0-2]) return 0 ;;
    enter|tab|btab|space|bspace|del|esc) return 0 ;;
    up|down|left|right|home|end|pgup|pgdn) return 0 ;;
    ?) ;;
    *) return 1 ;;
  esac
  # Not the quoting characters: the binding is a shell string first and an fzf
  # argument second, and either of them ends it early. Not whitespace either —
  # fzf has names of its own for those, listed above.
  case $1 in ' '|"$TAB"|'\'|'"'|"'") return 1 ;; esac
  return 0
}

key_note()  { KEY_NOTES="$KEY_NOTES${KEY_NOTES:+$KEY_NL}$1"; }
key_taken() { case $KEY_TAKEN in *" $1 "*) return 0 ;; esac; return 1; }

# Resolved once per process and then remembered, the way the config is: dash()
# rebuilds its header on every frame and would otherwise pay for the lookup
# again each time — and a complaint about a key belongs on screen once, not once
# a second.
resolve_keys() {
  local verb def var val
  [ -n "$KEYS_RESOLVED" ] && return 0
  KEYS_RESOLVED=1
  # Loaded here, in this process: every cfg_get below runs in a subshell, and a
  # subshell inherits a parse already made but cannot hand one back — so
  # without this the file was parsed eighteen times, and a line the parser
  # refused was complained about eighteen times.
  cfg_load || true
  KEY_NOTES=''
  KEY_TAKEN=' '
  while read -r verb def var; do
    [ -n "$verb" ] || continue
    val=$(cfg_get "keys.$verb") || val=''
    [ -n "$val" ] || { [ "$verb" = rename ] && val=${TA_RENAME_KEY:-}; }
    [ -n "$val" ] || val=$def
    if ! key_valid "$val"; then
      key_note "keys.$verb: '$val' is not a key fzf knows — using $def"
      val=$def
    fi
    if key_taken "$val"; then
      # Its default is the second chance and the last one. Left unbound rather
      # than bound over the top of somebody else: a verb that is missing can be
      # looked for, a verb that quietly stole another key cannot.
      if [ "$val" != "$def" ] && ! key_taken "$def"; then
        key_note "keys.$verb: $val is taken already — using $def"
        val=$def
      else
        key_note "keys.$verb: $val is taken already — $verb is unbound"
        val=''
      fi
    fi
    [ -n "$val" ] && KEY_TAKEN="$KEY_TAKEN$val "
    eval "$var=\$val"
  done <<EOF
$KEY_DEFAULTS
EOF
  return 0
}

# THE ONE PLACE A REJECTED KEY IS REPORTED. The dashboard has no stderr anybody
# reads — fzf owns the screen from the moment it starts — so the message goes
# where tmux puts its own; and `tagents --keys`, which is where somebody looks
# to find out what their config actually did, prints the same lines as comments.
key_warn() {  # [prefix] — no prefix means tmux display-message
  local n pre=${1:-}
  [ -n "$KEY_NOTES" ] || return 0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if [ -n "$pre" ]; then printf '%s%s\n' "$pre" "$n"
    else tmux display-message "tagents: $n" 2>/dev/null || true
    fi
  done <<EOF
$KEY_NOTES
EOF
  return 0
}

# A verb whose key was configured onto somebody else's has no key at all, and
# "--bind=:execute-silent(...)" is exactly the argument fzf refuses to start on
# — so an unbound verb contributes nothing here rather than an empty binding.
BINDS=()
kb() {  # <key> <action>
  [ -n "$1" ] || return 0
  BINDS[${#BINDS[@]}]="--bind=$1:$2"
  return 0
}

# EVERY KEY IN ONE PLACE, and the place a new one is added. The fzf --bind
# strings themselves stay hand-written down in dash() — several of them carry
# suffixes (+reload-sync, +abort) and quoting that a table would have to encode
# to say nothing new — but the help window is generated from here, so a key that
# exists in one and not the other is a key that is either undiscoverable or a
# lie. tests/ui.sh greps both and refuses to let them drift.
#
# Column 2 is what enter on that row does: an act() verb, or a name starting
# with ":" for the things fzf does to itself. ":quit" is the pair that can only
# be LISTED here — quitting the list from a child popup cannot go through
# --expect — so they are shown dim and selecting one just closes the help.
#
# Each line says its own verb in words, and that is not decoration: the picker
# searches what it shows, so somebody who remembers "undock" but not ctrl-u can
# type the word and get the key.
keys_table() {  # key<TAB>verb<TAB>what it does
  resolve_keys
  # The awk drops any verb left without a key. A row with an empty first column
  # is a lie in both directions: nothing is bound to it, and the ? window would
  # offer it anyway.
  printf '%s\n' \
"$K_OPEN${TAB}open${TAB}open it in the sidebar and put the cursor in it" \
"$K_BESIDE${TAB}beside${TAB}open it beside the current seat — two chats at once" \
"$K_NEW${TAB}new${TAB}start a new agent in this project" \
"$K_PICK${TAB}pick${TAB}the same, picking the account it starts on" \
"$K_GOTO${TAB}goto${TAB}go to the agent where it lives" \
"$K_BORROW${TAB}borrow${TAB}borrow its whole window into this session" \
"$K_SEND${TAB}send${TAB}send a line straight into it" \
"$K_RENAME${TAB}rename${TAB}rename this agent — an empty name restores its title" \
"$K_UNDOCK${TAB}undock${TAB}undock the current seat and close it behind the chat" \
"$K_KILL${TAB}kill${TAB}kill this agent, asking first; a closed row is forgotten" \
"$K_TREE${TAB}:tree${TAB}tree or flat" \
"$K_PREVIEW${TAB}:preview${TAB}the preview in a window of its own — in the prefix+a popup, fzf's toggle beside the list" \
"$K_REFRESH${TAB}:refresh${TAB}refresh now" \
"$K_COLUMNS${TAB}:columns${TAB}show or hide columns" \
"$K_USAGE${TAB}:usage${TAB}usage this month, per day" \
"$K_CLOSED${TAB}:closed${TAB}closed sessions — pick one to resume" \
"$K_KEYS${TAB}:none${TAB}this window" \
"$K_QUIT${TAB}:quit${TAB}quit the dashboard — from the list itself, not from here" \
"esc${TAB}:quit${TAB}in the popup, close it — from the list itself, not from here" |
    awk -F"$TAB" 'length($1) > 0'
}

# ? — THE KEYS, AND ENTER RUNS THE ONE YOU PICK. Four rows of header for keys
# nobody reads is width taken off every row of the list, so the header keeps
# only the two keys that cannot be discovered any other way and everything else
# moved in here, tmux prefix+? style.
#
# It acts on the row the cursor was on, which is why the row fields travel here
# exactly as they do for every direct binding ({1} {3} {4} {5}).
ask_keys() {  # <port> <pane> <state> <sid> <dir>
  local port=${1:-} pane=${2:-} state=${3:-} sid=${4:-} dir=${5:-}
  local key verb desc w=0 rows="" dim reset pick nl
  # WHICH KIND OF LIST OPENED THIS, read before the TA_MODE below overwrites it.
  # A popup list runs this body inline and hands its own environment down, so
  # TA_MODE is popup here; a sidebar list opens it as a popup of its own, and a
  # popup is a child of the tmux server, which has none of that environment. So
  # an empty mode means "the list is a sidebar", which is what :preview needs.
  local mode=${TA_MODE:-}
  nl='
'
  dim=$(printf '\033[90m'); reset=$(printf '\033[0m')
  while IFS="$TAB" read -r key verb desc; do
    [ ${#key} -gt "$w" ] && w=${#key}
  done <<EOF
$(keys_table)
EOF
  while IFS="$TAB" read -r key verb desc; do
    [ -n "$key" ] || continue
    desc="$(printf '%-*s' "$w" "$key")  $desc"
    [ "$verb" = :quit ] && desc="$dim$desc$reset"
    rows="$rows$key$TAB$verb$TAB$desc$nl"
  done <<EOF
$(keys_table)
EOF
  # Not piped into `cut`: under pipefail an esc (fzf exits 130) would take the
  # whole pipeline down with it, and esc is the ordinary way out of here.
  pick=$(printf '%s' "$rows" | fzf --ansi --delimiter="$TAB" --with-nth=3 \
           --layout=reverse --height=100% --no-info --prompt='keys> ' \
           --header="every key — enter runs the one you pick
on the row the cursor was on · esc closes")
  # A --filter run prints every match rather than the one under a cursor; the
  # first is the one that was asked for.
  pick=${pick%%$nl*}
  [ -n "$pick" ] || return 0
  verb=${pick#*$TAB}; verb=${verb%%$TAB*}
  # TA_HOME is fzf's own environment, and a popup is spawned by the tmux server
  # with none of it. borrow and undock both need it, so it is answered the same
  # way dash() answers it — the session of the client that opened this.
  [ -n "${TA_HOME:-}" ] || TA_HOME=$(tmux display -p '#S' 2>/dev/null)
  export TA_HOME
  # THIS BODY IS ALREADY A POPUP, and the acts below are the ones that ask a
  # question. prompt() answers a question with a display-popup, and a popup
  # issued from inside a popup returns rc=0 and silently does nothing — so
  # picking rename, send, kill, ctrl-p, or enter on a closed row whose account
  # nobody recorded, did precisely nothing: prompt returned 0, the caller
  # believed it had asked, and the key was a no-op. It is the same answer
  # prompt() already gives the popup list, and it is right on the inline path
  # too — there prompt() would refuse anyway, so this only ever agrees with it.
  TA_MODE=popup
  export TA_MODE
  case $verb in
    :quit|:none) return 0 ;;
    :tree)       toggle_group; post_fzf "$port" "reload-sync($SELF --list)" ;;
    # In the popup list the text preview IS the live view and fzf own toggle is
    # the whole of it. In a sidebar the preview is a popup, and this body is
    # already one — see preview_popup for why that has to go the long way round.
    # The condition is dash() own: wherever the modal cannot exist, ctrl-v is
    # still bound to fzf toggle, and posting it is exactly what the key does.
    :preview)
      if [ "$mode" = popup ] || ! has_popup; then
        post_fzf "$port" "toggle-preview"
      else
        tmux run-shell -b "'$SELF' --preview-popup '$pane' '$state'" 2>/dev/null
      fi ;;
    :refresh)    post_fzf "$port" "reload-sync($SELF --list)" ;;
    # Straight into ask_columns rather than through prompt(): this is already a
    # terminal of its own — a popup, or an inline body that has the screen — and
    # a popup cannot open a second popup at all.
    :columns)    ask_columns "$port" ;;
    # Same reasoning as :columns — this body already owns a terminal, and a
    # popup cannot open a second one.
    :usage)      ask_usage ;;
    # Same again: this body is already a terminal of its own, and the picker
    # resumes on its own rather than reporting a verb back to the list.
    :closed)     ask_closed "$port" ;;
    *)           "$SELF" --act "$verb" "$pane" "$state" "$sid" "$dir"
                 post_fzf "$port" "reload-sync($SELF --list)" ;;
  esac
  return 0
}

# Tall enough for every key plus the two header lines, the prompt and some air.
keys_height() {
  local n
  n=$(keys_table | wc -l | tr -d ' ')
  printf '%s' "$(( ${n:-0} + 6 ))"
}

# THE PORT IS READ IN THE CHILD FZF RUNS, which is the only process that has it:
# fzf exports FZF_PORT to the children of its own bindings, and a tmux popup is
# spawned by the server and inherits nothing from fzf. So it is passed on as an
# argument, exactly as the row fields are.
keys_window() {  # <pane> <state> <sid> <dir> — the ? key
  local pane=${1:-} state=${2:-} sid=${3:-} dir=${4:-} port=${FZF_PORT:-}
  prompt "$(keys_height)" --ask-keys "$port" "$pane" "$state" "$sid" "$dir" && return 0
  ask_keys "$port" "$pane" "$state" "$sid" "$dir"
}
