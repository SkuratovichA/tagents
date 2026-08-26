#!/usr/bin/env bash
#
# tests/ui.sh — what a row actually looks like: the account badge before the
# name, the columns ctrl-w can hide, the ? window that RUNS the key you pick,
# and the one-line header.
#
# NOTHING HERE MAY TOUCH THE DEFAULT TMUX SOCKET. The server is created with
# `tmux -L tatest-$$ -f /dev/null` and torn down in the trap, and tagents is
# pointed at it by exporting $TMUX in the test process — never by putting a
# `tmux` shim on $PATH, which has already once let a test relocate a real pane
# when the shim went missing.
#
# The dashboard is a REAL list: `tagents` running in a pane of that server,
# claiming it, so the ? window has a sidebar to undock a chat out of. The agents
# are a copy of /bin/sleep named `claude`, so the process walk in live_panes
# counts them — a #!/bin/sh stub would be an `sh` to ps and never an agent.
#
# fzf is driven with --filter, which prints the matching rows and exits instead
# of drawing anything: the only way to pick a row of a picker from a script.
#
# bash 3.2, runnable from any cwd, non-zero exit on any failing check.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TA="$HERE/../tagents"

command -v tmux >/dev/null 2>&1 || { echo "ui.sh: no tmux"; exit 1; }
command -v fzf  >/dev/null 2>&1 || { echo "ui.sh: no fzf"; exit 1; }

S=tatest-$$
SOCK=""
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tagents-ui.XXXXXX") || exit 1
ROOT=$(cd "$ROOT" && pwd -P) || exit 1
# The keeper sleep is reaped by pid: `script` and the attach both die with the
# server, but a `sleep` feeding the pipe never writes to it, so it never takes
# SIGPIPE and would sit there for its full five minutes after the run.
# The socket FILE goes too: kill-server takes the server down and leaves the
# socket behind, and a directory of dead tatest-<pid> sockets is what every run
# of these suites used to add to.
trap 'tmux -L "$S" kill-server >/dev/null 2>&1
      [ -s "$ROOT/keeper.pid" ] && kill "$(cat "$ROOT/keeper.pid")" 2>/dev/null
      [ -n "$SOCK" ] && rm -f "$SOCK"
      rm -rf "$ROOT"' EXIT INT TERM

pass=0; fail=0
ok()   { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
         else fail=$((fail+1)); printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"; fi; }
has()  { case "$3" in *"$2"*) pass=$((pass+1)); printf '  ok   %s\n' "$1" ;;
         *) fail=$((fail+1)); printf '  FAIL %s\n       expected to contain: %s\n       actual: %s\n' "$1" "$2" "$3" ;; esac; }
hasnt(){ case "$3" in *"$2"*) fail=$((fail+1)); printf '  FAIL %s\n       must not contain: %s\n       actual: %s\n' "$1" "$2" "$3" ;;
         *) pass=$((pass+1)); printf '  ok   %s\n' "$1" ;; esac; }
t()    { printf '\n%s\n' "$1"; }

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------
BIN="$ROOT/bin";      mkdir -p "$BIN"
STATE="$ROOT/state";  mkdir -p "$STATE"
REPO="$ROOT/repo";    mkdir -p "$REPO/.git"

# An agent is a process ps calls "claude" — that is the whole of what live_panes
# asks, and a #!/bin/sh script would not do: macOS ps reports the INTERPRETER,
# so a script called claude is an `sh` to everything that looks. Hence a copy of
# /bin/sleep under that name, re-signed because a copy of a system binary is
# killed on sight on arm64.
cp /bin/sleep "$BIN/claude" || exit 1
codesign --remove-signature "$BIN/claude" >/dev/null 2>&1
codesign -f -s - "$BIN/claude" >/dev/null 2>&1
"$BIN/claude" 0 >/dev/null 2>&1 ||
  { echo "ui.sh: cannot build a stub agent (codesign?)"; exit 1; }

# tusage, stubbed to one session so the money columns have something to show and
# something to hide. The field order is the one list() reads: sid, cost, reqs,
# ctx, last, slug, subagent cost, live subagents, cost 5h, model, $, $ 5h,
# $ subagents, unpriced requests.
cat >"$BIN/tusage" <<'EOF'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = --sessions ]; then
    printf 'sid-p\t0\t1\t150000\t0\tslug\t0\t0\t0\tclaude-opus-5\t12.34\t3.5\t1.25\t0\n'
    exit 0
  fi
done
exit 0
EOF
chmod +x "$BIN/claude" "$BIN/tusage"

# personal has a config_dir, work has none — so an empty recorded account is
# work's, and a dir nobody claims is nobody's.
CFG="$ROOT/config.yaml"
cat >"$CFG" <<EOF
claude:
  profiles:
    personal:
      config_dir: $HOME/.claude-personal
    work:
EOF
# ...and the same two with a badge written out by hand, two characters wide.
CFG2="$ROOT/config-badge.yaml"
cat >"$CFG2" <<EOF
claude:
  profiles:
    personal:
      config_dir: $HOME/.claude-personal
      badge: PP
    work:
EOF

# ...and one that ignores the one-or-two-character promise outright.
CFG3="$ROOT/config-long.yaml"
cat >"$CFG3" <<EOF
claude:
  profiles:
    personal:
      config_dir: $HOME/.claude-personal
      badge: personal!
    work:
EOF

# EXPORTED BEFORE THE SERVER EXISTS. A tmux server keeps the environment it was
# started with and hands it to every command it runs, so anything the list or an
# agent pane needs has to be in place now.
export PATH="$BIN:$PATH"
export TA_STATE_DIR="$STATE"
export TA_SESSION=tatest-dash
export TA_CONFIG="$CFG"
unset TMUX TMUX_PANE TA_MODE TA_FLAT TA_COLS TA_NEW_CMD TA_RESUME_CMD TA_HOME
unset TA_HIDE_COLS CLAUDE_CONFIG_DIR FZF_DEFAULT_OPTS

tm() { tmux -L "$S" "$@"; }

tm -f /dev/null new-session -d -s tatest-dash -x 200 -y 50 "exec '$TA'" || exit 1
tm set -g default-shell /bin/sh >/dev/null 2>&1
tm set -g default-command '' >/dev/null 2>&1
tm new-session -d -s tatest-work -c "$REPO" >/dev/null 2>&1

SOCK=$(tm display -p '#{socket_path}' 2>/dev/null)
[ -n "$SOCK" ] || { echo "ui.sh: no socket for $S"; exit 1; }
TMUXV="$SOCK,0,0"

# A client on a pty, so the focus hooks have somewhere to fire and select-pane
# means something. Its stdin is a sleep, so it never reads EOF and detaches on
# its own; the whole thing is orphaned deliberately, which is why the sleep
# writes its pid down for the trap rather than being a job to wait on.
( { sleep 300 & printf '%s\n' "$!" >"$ROOT/keeper.pid"; wait; } |
    script -q /dev/null tmux -L "$S" attach -t tatest-dash >/dev/null 2>&1 & ) >/dev/null 2>&1
sleep 0.5

run() { env TMUX="$TMUXV" bash "$TA" "$@"; }

ESC=$(printf '\033')
strip() { sed "s/${ESC}\[[0-9;]*m//g"; }

# Every environment variable a check needs is handed to `env` here rather than
# prefixed onto the run() call: bash leaves an assignment made in front of a
# FUNCTION set in the shell afterwards, and a TA_HIDE_COLS left behind would
# quietly hide a column in every check after it.
rows_at() {  # <cols> [VAR=value ...] -> the list at that width, without colour
  local cols=$1
  shift
  env TMUX="$TMUXV" TA_COLS="$cols" TA_MARKS=0 "$@" bash "$TA" --list | strip
}

# A row of the list by pane id — never the group header, which carries its most
# urgent member's pane id as well.
row_of() {
  printf '%s\n' "${2:-}" |
    awk -F'\t' -v p="${1:-}" 'index($2, "\342\226\276") == 0 && $1 == p { print $2; exit }'
}
hdr_row() {  # the group header line
  printf '%s\n' "${1:-}" | awk -F'\t' 'index($2, "\342\226\276") > 0 { print $2; exit }'
}
# WHAT SITS BETWEEN THE AGE AND THE NAME — the badge cell, padding and all, so a
# missing column and a blank one are told apart rather than both reading as "no
# badge". There is exactly one m:ss on a row and the name appears once.
cell() {  # <pane> <rows> <name>
  row_of "$1" "$2" | sed -n "s/.*[0-9]:[0-9][0-9]  \(.*\)$3 .*/\1/p"
}

# HOW MANY TIMES a word is on a row. The flat project column and the name are
# both the basename of the repo here, so "is the project still there" cannot be
# asked with `has` — only by counting.
occurs() { printf '%s' "${2:-}" | awk -v w="${1:-}" '{ print gsub(w, "") + 0 }'; }

where() { tm display -p -t "${1:-}" '#{window_id}' 2>/dev/null; }
lives() { tm list-panes -a -F '#{pane_id}' 2>/dev/null |
            awk -v p="${1:-}" '$1 == p { f = 1 } END { print f ? "yes" : "no" }'; }

# The records the badge is read off. Pane ids nothing owns, so these are closed
# rows: what the account column says has nothing to do with whether a Claude is
# running, and a closed row renders every column a live one does.
mkrec() {  # <pane key> <session id> <recorded account, or - for a 6-field record>
  if [ "$3" = - ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date +%s)" done "$2" "$REPO" "" "waiting" >"$STATE/$1.tsv"
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date +%s)" done "$2" "$REPO" "" "waiting" "$3" >"$STATE/$1.tsv"
  fi
}
mkrec 8001 sid-p "$HOME/.claude-personal"   # claims the personal profile
mkrec 8002 sid-w ""                         # unset: the one profile with no dir
mkrec 8003 sid-u "/tmp/.claude-nobody"      # a dir no profile has heard of
mkrec 8004 sid-o -                          # written before the account was

# The list claims the pane it runs in; the ? window needs that claim to have a
# sidebar to undock out of.
LIST=""
i=0
while [ "$i" -lt 80 ]; do
  LIST=$(tm list-panes -a -F '#{pane_id} #{@tagents_list}' 2>/dev/null |
           awk '$2 != "" { print $1; exit }')
  [ -n "$LIST" ] && break
  i=$((i + 1)); sleep 0.25
done
[ -n "$LIST" ] || { echo "ui.sh: the list never claimed a pane"; exit 1; }
DWIN=$(where "$LIST")

# One live agent, for the columns that only exist for a pane that is really
# there. Its own session id, and NOT one of the closed records above: a session
# that is running right now is never also offered as a closed one, so sharing an
# id would take that closed row off the list entirely.
A=$(tm new-window -d -t tatest-work: -P -F '#{pane_id}' -c "$REPO" \
      "exec '$BIN/claude' 600" 2>/dev/null)
AHOME=$(where "$A")
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date +%s)" working sid-live "$REPO" "" "on it" "$HOME/.claude-personal" \
  >"$STATE/${A#%}.tsv"
run --ensure-seat "$LIST" >/dev/null 2>&1
sleep 0.3

# ---------------------------------------------------------------------------
t "1. the badge column"
# ---------------------------------------------------------------------------
WIDE=$(rows_at 140)
NARROW=$(rows_at 60)

ok "a record claiming personal is p (wide)"   "p " "$(cell %8001 "$WIDE" repo)"
ok "...and p on a narrow pane too"            "p " "$(cell %8001 "$NARROW" repo)"
ok "an unset account is the profile that has none" "w " "$(cell %8002 "$WIDE" repo)"
ok "...also at 60 columns"                    "w " "$(cell %8002 "$NARROW" repo)"
ok "a dir no profile claims is ?"             "? " "$(cell %8003 "$WIDE" repo)"
ok "a six-field record says nothing, in the column width" \
   "  " "$(cell %8004 "$WIDE" repo)"

BADGED=$(rows_at 140 TA_CONFIG="$CFG2")
ok "an explicit badge is rendered as written" "PP " "$(cell %8001 "$BADGED" repo)"
ok "...and every other badge is padded to it" "w  " "$(cell %8002 "$BADGED" repo)"

# A LONGER ONE IS CLIPPED, and the reason is not tidiness: the column is as wide
# as the widest badge at EVERY breakpoint, so `badge: personal!` widened every
# row by eight columns and took the detail column off a narrow list entirely.
LONG=$(rows_at 140 TA_CONFIG="$CFG3")
ok "a badge longer than two characters is clipped to two" "pe " "$(cell %8001 "$LONG" repo)"
ok "...so the column is still two wide for everybody else" "w  " "$(cell %8002 "$LONG" repo)"
ok "...at the width where it did the damage, too" "pe " \
   "$(cell %8001 "$(rows_at 45 TA_CONFIG="$CFG3")" repo)"

# With nothing configured there is no column at all — not an empty one.
NOCFG=$(rows_at 140 TA_CONFIG=/nonexistent/config.yaml)
ok "no profiles, no column"       "" "$(cell %8001 "$NOCFG" repo)"
ok "...at every width"            "" "$(cell %8001 "$(rows_at 60 TA_CONFIG=/nonexistent/config.yaml)" repo)"

# ...and the rows are the ones this printed before the column existed. The
# control is the committed tagents, so this compares against the real thing
# rather than against a description of it; the age is the one field that moves
# between two runs a fraction of a second apart, so it is normalised away.
CONTROL="$ROOT/tagents-control"
if git -C "$HERE/.." show HEAD:tagents >"$CONTROL" 2>/dev/null && [ -s "$CONTROL" ]; then
  agenorm() { sed 's/[0-9]*:[0-9][0-9]/AGE/g'; }
  before=$(env TMUX="$TMUXV" TA_COLS=140 TA_MARKS=0 TA_CONFIG=/nonexistent/config.yaml \
             bash "$CONTROL" --list | strip | agenorm)
  after=$(rows_at 140 TA_CONFIG=/nonexistent/config.yaml | agenorm)
  ok "no config: the rows are what they were before any of this" "$before" "$after"
else
  printf '  --   no committed tagents to compare against, skipping the control run\n'
fi

# ---------------------------------------------------------------------------
t "2. hiding columns"
# ---------------------------------------------------------------------------
# The money first: hiding cost has to take every dollar figure with it, and
# leave the ⑂ subagent COUNT alone, which is not money.
FULL=$(rows_at 140)
has "the cost column is there to begin with" '$12.3' "$(row_of %8001 "$FULL")"
has "...and the subagent share with it"      '⑂$1.25' "$(row_of %8001 "$FULL")"
has "...and the project total in the header" "/5h"    "$(hdr_row "$FULL")"

NOCOST=$(rows_at 140 TA_HIDE_COLS=cost)
hasnt "hiding cost takes the column"          '$12.3'  "$(row_of %8001 "$NOCOST")"
hasnt "...the subagent share"                 '⑂$'     "$(row_of %8001 "$NOCOST")"
hasnt "...and the /5h total off the header"   "/5h"    "$(hdr_row "$NOCOST")"
has   "...while the context is untouched"     "150k"   "$(row_of %8001 "$NOCOST")"
has   "...and so is the model"                "opus5"  "$(row_of %8001 "$NOCOST")"

hasnt "hiding ctx takes the token figure"   "150k"     "$(row_of %8001 "$(rows_at 140 TA_HIDE_COLS=ctx)")"
hasnt "hiding model takes the model"        "opus5"    "$(row_of %8001 "$(rows_at 140 TA_HIDE_COLS=model)")"
hasnt "hiding acct takes the account name"  "personal" "$(row_of %8001 "$(rows_at 140 TA_HIDE_COLS=acct)")"
ok    "hiding badge takes the indicator"    ""         "$(cell %8001 "$(rows_at 140 TA_HIDE_COLS=badge)" repo)"
# loc is asked of the live agent: a closed row has no pane to name.
has   "the location column is there"        "tatest-work:" "$(row_of "$A" "$(rows_at 140)")"
hasnt "hiding loc takes it"                 "tatest-work:" "$(row_of "$A" "$(rows_at 140 TA_HIDE_COLS=loc)")"
# AND IT TAKES NOTHING ELSE WITH IT. Flat mode has no group headers, so the
# 14-wide project column is the only thing on the row that says which project an
# agent belongs to — and it was drawn under the location column's own width, so
# `loc` quietly took it away too. Counted rather than grepped: here the project
# and the agent are both called "repo".
FLAT=$(rows_at 140 TA_FLAT=1)
FLATNOLOC=$(rows_at 140 TA_FLAT=1 TA_HIDE_COLS=loc)
ok    "flat rows name the project as well as the agent" 2 \
      "$(occurs repo "$(row_of %8001 "$FLAT")")"
ok    "...and hiding loc leaves the project where it was" 2 \
      "$(occurs repo "$(row_of %8001 "$FLATNOLOC")")"
hasnt "...while the pane column really is gone" "tatest-work:" "$(row_of "$A" "$FLATNOLOC")"
# Two at once, and the detail column gets the width — nothing is reordered.
NOBOTH=$(rows_at 140 TA_HIDE_COLS=cost,model)
hasnt "several at once: no cost"  '$12.3' "$(row_of %8001 "$NOBOTH")"
hasnt "...and no model"           "opus5" "$(row_of %8001 "$NOBOTH")"
has   "...and the name is still there" "repo" "$(row_of %8001 "$NOBOTH")"

# The picker itself. No port: there is no list listening for this one, which
# must degrade to "the toggle happens, nothing reloads".
ok "nothing is hidden to start with" "" "$(run --hidden-cols)"
env TMUX="$TMUXV" FZF_DEFAULT_OPTS=--filter=cost bash "$TA" --ask-columns
ok "the picker hides the column it was given" "cost" "$(run --hidden-cols)"
has "...and says so in its own rows" "[ ] cost" "$(run --col-rows)"
hasnt "...and the list drawn after it has no money on it" '$12.3' \
      "$(row_of %8001 "$(rows_at 140)")"
env TMUX="$TMUXV" FZF_DEFAULT_OPTS=--filter=cost bash "$TA" --ask-columns
ok "and shows it again on the second pass" "" "$(run --hidden-cols)"
has "...with the checkmark back" "[x] cost" "$(run --col-rows)"
# A KEY IS A STRING. The membership test used to be a regular expression, so
# `co.t` matched `cost`, passed the "is this a real column" guard and was written
# into the state file as a hidden column nothing renders and the picker cannot
# offer back. --toggle-col is a documented entry point and takes its key from a
# human.
run --toggle-col 'co.t' >/dev/null 2>&1
ok "a key that merely matches a column as a regex is not a column" "" "$(run --hidden-cols)"
run --toggle-col '.*' >/dev/null 2>&1
ok "...nor is one that matches all of them"                        "" "$(run --hidden-cols)"
run --toggle-col zzz >/dev/null 2>&1
ok "...and an ordinary unknown key is still refused"               "" "$(run --hidden-cols)"
# The environment override is exactly that — an override, not a second file.
ok "TA_HIDE_COLS wins over the state file" "model" \
   "$(env TMUX="$TMUXV" TA_HIDE_COLS=model bash "$TA" --hidden-cols)"

# THE BINDING ITSELF. Everything above drove the picker with --filter, which
# never reaches a binding at all — so the picker is run in a pane of the
# throwaway server here and the key is actually pressed. What is being checked
# is the half of the design that only exists in the binding: enter toggles, the
# picker STAYS OPEN with the checkmark flipped, and the cursor is where it was.
PICK=$(tm new-window -d -t tatest-dash: -P -F '#{pane_id}' \
         "exec '$TA' --ask-columns" 2>/dev/null)
sleep 1
tm send-keys -t "$PICK" Down Down Enter; sleep 1    # third row down is cost
ok  "enter in the picker hides the row under the cursor" "cost" "$(run --hidden-cols)"
has "...and the picker is still up, checkmark flipped"   "[ ] cost" \
    "$(tm capture-pane -p -t "$PICK" 2>/dev/null)"
tm send-keys -t "$PICK" Enter; sleep 1
ok  "...with the cursor still on it, so enter puts it back" "" "$(run --hidden-cols)"
tm send-keys -t "$PICK" Escape; sleep 0.7
ok  "esc closes the picker" no "$(lives "$PICK")"

# ---------------------------------------------------------------------------
t "3. the ? window"
# ---------------------------------------------------------------------------
# THE TABLE AND THE BINDINGS CANNOT DRIFT. Every key dash() binds has to have a
# row in keys_table, and every row has to be a key that is really bound — except
# the two that are listed and cannot be run from here (ctrl-q comes through
# --expect, esc through the abort binding), and the aliases nobody needs a row
# for: start is fzf's own boot hook, double-click is enter, f2 is the rename key.
TABLE=$(run --keys | cut -f1 | sort)
BOUND=$(awk '/^dash\(\) \{/, /^\}$/' "$TA" |
          sed -n "s/.*--bind=['\"]\{0,1\}\([^:'\"]*\):.*/\1/p" |
          sed "s/\\\$RENAME_KEY/ctrl-r/" |
          grep -v -e '^start$' -e '^double-click$' -e '^f2$' | sort -u)
for k in $BOUND; do
  case "$TABLE" in *"$k"*) pass=$((pass+1)); printf '  ok   %s is bound and listed\n' "$k" ;;
    *) fail=$((fail+1)); printf '  FAIL %s is bound by dash() and has no row in keys_table\n' "$k" ;;
  esac
done
for k in $TABLE; do
  case "$k" in ctrl-q|esc) continue ;; esac
  case "$BOUND" in *"$k"*) pass=$((pass+1)); printf '  ok   %s is listed and bound\n' "$k" ;;
    *) fail=$((fail+1)); printf '  FAIL %s has a row in keys_table and dash() binds nothing to it\n' "$k" ;;
  esac
done
has "the two that cannot be run from here are still listed" "ctrl-q" "$TABLE"
has "...both of them"                                       "esc"    "$TABLE"

# AND IT REALLY RUNS THE KEY. Undock, end to end: a chat docked in the sidebar
# goes home, exactly as ctrl-u would have sent it.
run --act open "$A" live sid-live "$REPO" >/dev/null 2>&1; sleep 0.5
ok "the agent is docked in the sidebar" "$DWIN" "$(where "$A")"
env TMUX="$TMUXV" FZF_DEFAULT_OPTS=--filter=undock bash "$TA" \
  --ask-keys "" "$A" live sid-live "$REPO" >/dev/null 2>&1
sleep 0.5
ok "picking undock in the ? window sends it home" "$AHOME" "$(where "$A")"
ok "...and the agent is still alive"              yes      "$(lives "$A")"

# AND IT RUNS THE KEYS THAT ASK A QUESTION. Every check above runs --ask-keys as
# a plain process, which is the one shape that cannot see this: the ? window is
# the body of a display-popup, and a display-popup issued from inside one returns
# rc=0 and does nothing at all. So rename, send, kill and ctrl-p each returned
# from prompt() believing they had asked, and the key was a silent no-op. Run
# here as a real popup body, with the answer on stdin — the prompt reads the
# popup's own tty, which is what a pipe into it stands in for.
KST="$ROOT/keys-state"; mkdir -p "$KST"
tm display-popup -E -w 60% -h 20 -t "$LIST" \
  sh -c "printf 'zzname\n' | env TMUX='$TMUXV' TA_STATE_DIR='$KST' \
           FZF_DEFAULT_OPTS=--filter=rename bash '$TA' --ask-keys '' $A working sid-pop '$REPO'" \
  >/dev/null 2>&1
ok "picking rename inside the popup really asks, and the name lands" \
   "$(printf 'sid-pop\tzzname')" "$(cat "$KST/labels.tsv" 2>/dev/null)"

# The two listed keys do nothing at all from here, which is the whole of what
# they promise: no error, and nothing killed.
wins=$(tm list-windows -a -F x 2>/dev/null | wc -l | tr -d ' ')
env TMUX="$TMUXV" FZF_DEFAULT_OPTS=--filter=quit bash "$TA" \
  --ask-keys "" "$A" live sid-live "$REPO" >/dev/null 2>&1
ok "picking quit exits cleanly"       0    "$?"
ok "...and kills nothing"             yes  "$(lives "$A")"
ok "...and closes no window"          "$wins" "$(tm list-windows -a -F x 2>/dev/null | wc -l | tr -d ' ')"
ok "...and the list is still running" yes  "$(lives "$LIST")"

# ---------------------------------------------------------------------------
t "4. the header is one line"
# ---------------------------------------------------------------------------
H=$(run --header 100 'open here' 'ctrl-q quit')
ok  "one line at 100 columns" 1 "$(printf '%s\n' "$H" | awk 'END { print NR }')"
has "...naming the ? window"  "? keys" "$H"
has "...and enter"            "enter open here" "$H"
HP=$(run --header 100 'open in sidebar' '')
ok  "one line in popup mode too" 1 "$(printf '%s\n' "$HP" | awk 'END { print NR }')"
hasnt "...without the quit key" "ctrl-q" "$HP"
# keyhdr still packs: three items do not fit a pane this narrow, and a truncated
# header is a key nobody can see.
ok "a very narrow pane still gets every item, on more lines" 2 \
   "$(run --header 34 'open here' 'ctrl-q quit' | awk 'END { print NR }')"

# ---------------------------------------------------------------------------
t "5. the header comment IS the help"
# ---------------------------------------------------------------------------
# The usage block is what --help prints, so an entry point missing from it is an
# entry point nobody can find. The --ask-* bodies are deliberately not in there;
# these two are not internals — they are the picker, taken apart.
HELP=$(run --help)
has "--col-rows is documented"   "--col-rows"   "$HELP"
has "--toggle-col is documented" "--toggle-col" "$HELP"
# ...and a key taken off fzf says what it cost, the way ? already does.
has "the ctrl-w entry says what it takes from the filter query" \
    "delete-the-word" "$HELP"
has "--preview-popup is documented"  "--preview-popup" "$HELP"
has "--sync-names is documented"     "--sync-names"    "$HELP"

# ---------------------------------------------------------------------------
t "6. ctrl-v is a modal, not a column off the list"
# ---------------------------------------------------------------------------
# THE BODY. Driven with a pipe, which is what a test has instead of the popup
# tty: less renders to a pipe the way cat does, so what comes out is exactly
# what the popup would have shown.
PV=$(env TMUX="$TMUXV" bash "$TA" --ask-preview %8001 done </dev/null 2>/dev/null | strip)
has "the modal renders the preview"        "session sid-p" "$PV"
has "...the state and the detail with it"  "waiting"       "$PV"
has "...names the agent on the first line" "repo"          "$PV"
has "...and says how to close it"          "q closes"      "$PV"

# AND WITHOUT A PAGER. `less` is what makes the tusage table and the transcript
# tail scrollable, and it is also what a stripped-down machine has not got — so
# the text is printed and any key closes it instead. The PATH here is built by
# hand rather than emptied: everything the body reaches for is on it except the
# one thing being taken away.
NOLESS="$ROOT/noless"; mkdir -p "$NOLESS"
# bash is on it because `env PATH=… bash` looks the interpreter up in the NEW
# PATH, so leaving it out is a test that runs nothing and reports no output.
for b in awk bash basename cat cut date dirname find grep head hostname jq \
         mkdir rm sed sort tail tmux tr wc; do
  bp=$(command -v "$b" 2>/dev/null) && ln -sf "$bp" "$NOLESS/$b"
done
PVNL=$(env TMUX="$TMUXV" PATH="$BIN:$NOLESS" bash "$TA" --ask-preview %8001 done \
         </dev/null 2>/dev/null | strip)
has "with no less on PATH the same text is printed" "session sid-p" "$PVNL"
has "...and the hint says what closes it now"       "any key closes" "$PVNL"

# THE HEADING IS THE AGENT'S NAME — ALL OF IT. The checks above reach the
# basename fallback (%8001 is a pane that does not exist), so no title was ever
# resolved by them: what the heading used to do to a real one was drop the first
# WORD, `Data service architecture` announced as `service architecture`, while
# the row and the window name for the same agent kept all three. Only a leading
# glyph comes off, which is the rule the list and the sweep both apply.
heading() {  # <pane> -> the modal's first line, without the hint after it
  env TMUX="$TMUXV" bash "$TA" --ask-preview "${1:-}" working </dev/null 2>/dev/null |
    strip | sed -n '1s/  q closes$//p'
}
tm select-pane -T 'Data service architecture' -t "$A"
ok "the heading names the agent, whole" "Data service architecture" "$(heading "$A")"
tm select-pane -T '✳ Data service architecture' -t "$A"
ok "...with Claude's spinner glyph off it" "Data service architecture" "$(heading "$A")"
# ...and it agrees with the two other places the same agent is named.
tm select-pane -T 'Data service architecture' -t "$A"
run --sync-names >/dev/null 2>&1
ok "...and with the name its window gets" "$(heading "$A")" \
   "$(tm display -p -t "$A" '#{window_name}')"

# THE ? WINDOW'S OWN ROUTE TO IT. In the popup list ctrl-v is still fzf's own
# toggle, so :preview POSTs it — captured with a curl of our own, since what is
# being checked is the request and not what fzf does with it.
CURLBIN="$ROOT/curlbin"; mkdir -p "$CURLBIN"
cat >"$CURLBIN/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$ROOT/curl.log"
EOF
chmod +x "$CURLBIN/curl"
: >"$ROOT/curl.log"
env TMUX="$TMUXV" PATH="$CURLBIN:$PATH" TA_MODE=popup FZF_DEFAULT_OPTS=--filter=preview \
  bash "$TA" --ask-keys 4242 "$A" working sid-live "$REPO" >/dev/null 2>&1
has "in the popup list :preview posts fzf's own toggle" \
    "toggle-preview" "$(cat "$ROOT/curl.log" 2>/dev/null)"

# ...while in a sidebar the ? window is itself a popup, and a popup cannot open
# a second one. It asks the tmux server to open the modal instead, once this
# popup has closed — so nothing is posted and a preview body turns up shortly
# after. The state is a token of this run so the process it is looked for by
# cannot be anybody else's.
PVSTATE="zzpv$$"
: >"$ROOT/curl.log"
env TMUX="$TMUXV" PATH="$CURLBIN:$PATH" FZF_DEFAULT_OPTS=--filter=preview \
  bash "$TA" --ask-keys 4242 "$A" "$PVSTATE" sid-live "$REPO" >/dev/null 2>&1
ok "in a sidebar :preview posts nothing at all" "" "$(cat "$ROOT/curl.log" 2>/dev/null)"
PVPID=""
i=0
while [ "$i" -lt 24 ]; do
  PVPID=$(ps -eo pid=,args= 2>/dev/null |
            awk -v k="--ask-preview $A $PVSTATE" 'index($0, k) > 0 { print $1; exit }')
  [ -n "$PVPID" ] && break
  i=$((i + 1)); sleep 0.25
done
ok "...and opens the modal through the tmux server instead" \
   yes "$([ -n "$PVPID" ] && echo yes || echo no)"
tm display-popup -C >/dev/null 2>&1
[ -n "$PVPID" ] && kill "$PVPID" 2>/dev/null
sleep 0.3

# THE FZF COMMAND LINE ITSELF, from a real run: a fake fzf that writes its
# arguments down and then sits there, because dash() restarts fzf every time it
# exits and a fake that returned would respawn itself for ever. The list is
# started in a window of the throwaway server, which is the only way it gets a
# TMUX_PANE to claim and a tty to measure — this is the last section for that
# reason, since claiming makes it the sidebar in place of the real list above.
FZFBIN="$ROOT/fzfbin"; mkdir -p "$FZFBIN"
cat >"$FZFBIN/fzf" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done >"$FZFDUMP"
exec sleep 300
EOF
chmod +x "$FZFBIN/fzf"

dumpargs() {  # <dump file> <extra env for the list> -> the argv, one per line
  local out=$1 envs=$2 w
  rm -f "$out"
  w=$(tm new-window -d -t tatest-dash: -P -F '#{window_id}' \
        "PATH='$FZFBIN':\$PATH FZFDUMP='$out' $envs exec '$TA'" 2>/dev/null)
  i=0
  while [ "$i" -lt 40 ]; do
    [ -s "$out" ] && break
    i=$((i + 1)); sleep 0.25
  done
  tm kill-window -t "$w" >/dev/null 2>&1
  cat "$out" 2>/dev/null
}

# $SELF is the path tagents resolves for itself, which is the one written into
# every binding — never the $HERE/../tagents this suite calls it by.
SELF=$(cd "$(dirname "$TA")" && pwd)/$(basename "$TA")

SIDEBAR=$(dumpargs "$ROOT/fzf-sidebar" '')
ok "the sidebar list asks fzf for no preview at all" 0 \
   "$(printf '%s\n' "$SIDEBAR" | grep -c -e '^--preview=' -e '^--preview-window=' | tr -d ' ')"
has "...and ctrl-v opens the modal instead" \
    "--bind=ctrl-v:execute-silent($SELF --act preview {1} {3})" "$SIDEBAR"

POPUP=$(dumpargs "$ROOT/fzf-popup" 'TA_MODE=popup')
ok "the popup list still gets its preview" 1 \
   "$(printf '%s\n' "$POPUP" | grep -c '^--preview=' | tr -d ' ')"
has "...beside the list, as before"        "--preview-window=right,55%,border-left,wrap" "$POPUP"
has "...where ctrl-v is fzf's own toggle"  "--bind=ctrl-v:toggle-preview" "$POPUP"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
