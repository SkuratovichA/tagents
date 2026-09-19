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
# work's, and a dir nobody claims is nobody's. The directory exists and has
# been used, because a profile pointing nowhere is a config problem now, and a
# problem puts an extra item in the header these checks measure the width of.
LOGIN="$ROOT/claude-personal"
mkdir -p "$LOGIN"; : >"$LOGIN/.claude.json"
CFG="$ROOT/config.yaml"
cat >"$CFG" <<EOF
claude:
  profiles:
    personal:
      config_dir: $LOGIN
    work:
EOF
# ...and the same two with a badge written out by hand, two characters wide.
CFG2="$ROOT/config-badge.yaml"
cat >"$CFG2" <<EOF
claude:
  profiles:
    personal:
      config_dir: $LOGIN
      badge: PP
    work:
EOF

# ...and one that ignores the one-or-two-character promise outright.
CFG3="$ROOT/config-long.yaml"
cat >"$CFG3" <<EOF
claude:
  profiles:
    personal:
      config_dir: $LOGIN
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

# A row of the list by pane id — never the group header, which carries the pane
# id of the row directly under it as well.
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
mkrec 8001 sid-p "$LOGIN"                   # claims the personal profile
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
  "$(date +%s)" working sid-live "$REPO" "" "on it" "$LOGIN" \
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
# The control is a CHECKOUT, not a file. Since the program moved into
# lib/tagents/*.sh the entry alone refuses to run, and a control that cannot run
# prints nothing — which compares equal to nothing, so this case would have gone
# on "passing" through the else branch below.
CONTROL="$ROOT/tagents-control"
if mkdir -p "$CONTROL" &&
   git -C "$HERE/.." archive HEAD tagents lib/tagents 2>/dev/null | tar -x -C "$CONTROL" 2>/dev/null &&
   [ -s "$CONTROL/tagents" ] && [ -r "$CONTROL/lib/tagents/core.sh" ]; then
  agenorm() { sed 's/[0-9]*:[0-9][0-9]/AGE/g'; }
  before=$(env TMUX="$TMUXV" TA_COLS=140 TA_MARKS=0 TA_CONFIG=/nonexistent/config.yaml \
             bash "$CONTROL/tagents" --list | strip | agenorm)
  after=$(rows_at 140 TA_CONFIG=/nonexistent/config.yaml | agenorm)
  ok "no config: the rows are what they were before any of this" "$before" "$after"
else
  printf '  --   no committed tagents to compare against, skipping the control run\n'
fi

# ---------------------------------------------------------------------------
t "1b. a pane wider than the table"
# ---------------------------------------------------------------------------
# A record of its own, with a label far longer than the 24 columns the width
# table used to stop at, torn down again at the end of the section so nothing
# after it sees an extra agent in the tree.
LONG=abcdefghij-klmnopqrst-uvwxyz-0123456789
mkrec 8009 sid-wide ""
printf 'sid-wide\t%s\n' "$LONG" >>"$STATE/labels.tsv"

WIDE=$(rows_at 230)
# THE NAME COLUMN GROWS INTO WHATEVER THE DETAIL DOES NOT NEED. With every
# column shown, 110 columns leave the name no room and it is cut; hide the
# columns and the same 110 spell it out — the freed width goes to the name
# before it goes to the detail. At 140 the detail already has spare columns,
# and at 230 there is room for anything.
hasnt "at 110 columns with every column shown the long name is cut" "$LONG" "$(row_of %8009 "$(rows_at 110)")"
has   "...but with the columns hidden it is spelled out" "$LONG" \
      "$(row_of %8009 "$(rows_at 110 TA_HIDE_COLS=ctx,cost,model,acct,loc)")"
has   "at 140 columns the detail has spare room, so it is spelled out too" "$LONG" "$(row_of %8009 "$(rows_at 140)")"
# A 61-column sidebar with the columns hidden: the tier would give the name 18;
# the names get everything but ten columns of detail.
has   "on a 61-column sidebar with the columns hidden the name gets the width" "${LONG:0:30}" \
      "$(row_of %8009 "$(rows_at 61 TA_HIDE_COLS=ctx,cost,model,acct,loc)")"
has   "...and at 230 it is spelled out in full"   "$LONG" "$(row_of %8009 "$WIDE")"

# The rows have to grow into the pane, not past it: fzf wraps anything wider and
# a wrapped row is two rows.  Counted in characters, not bytes — the tree and the
# badges are multibyte.
WIDEST=$(printf '%s\n' "$WIDE" | cut -f2 |
           while IFS= read -r l; do
             printf '%s' "$l" | LC_ALL=en_US.UTF-8 wc -m
           done | sort -n | tail -1 | tr -d ' ')
ok "...and no row overflows the pane it was built for" \
   yes "$([ "${WIDEST:-999}" -le 228 ] && echo yes || echo no)"

# The other half of the same bargain: a column is dropped because the detail
# needs the room, so where the detail does not need it the column stays.
has "87 columns still have room for the model" "opus5" "$(row_of %8001 "$(rows_at 87)")"

rm -f "$STATE/8009.tsv"
grep -v '^sid-wide	' "$STATE/labels.tsv" >"$STATE/labels.new" 2>/dev/null
mv "$STATE/labels.new" "$STATE/labels.tsv" 2>/dev/null

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
# The table against the bindings is checked at the bottom of this file, against
# the argv fzf was really handed — the keys are configurable now, so the source
# of dash() is no longer an answer to "what is bound".
TABLE=$(run --keys | cut -f1 | sort)
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
has "--check is documented"          "--check"         "$HELP"

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
TAB=$'\t'

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

# THE TABLE AND THE BINDINGS CANNOT DRIFT, and this is the only honest place to
# say so: every key comes out of the config now, so what is bound is whatever
# fzf was handed above — never what the source of dash() looks like. Both shapes
# are checked, because the popup builds its own set. The exceptions are the ones
# they always were: the two that are listed and cannot be run from the ? window
# (ctrl-q arrives through --expect, esc through the abort binding), and the
# aliases nobody needs a row for — start and resize are fzf hooks rather than
# keys, double-click is enter, f2 is the rename key.
binds_of() {  # <argv dump> -> the key of every --bind, one per line
  printf '%s\n' "$1" | sed -n 's/^--bind=\([^:]*\):.*/\1/p' |
    grep -v -e '^start$' -e '^resize$' -e '^double-click$' -e '^f2$' | sort -u
}
# read, not `for k in $BOUND`: two of these keys are $ and ?, and an unquoted ?
# is a glob that would match any one-character file next to the suite.
drift() {  # <where> <bound keys>
  local where=$1 bound=$2 k
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    case "$TABLE" in *"$k"*) pass=$((pass+1)); printf '  ok   %s: %s is bound and listed\n' "$where" "$k" ;;
      *) fail=$((fail+1)); printf '  FAIL %s: %s is bound and has no row in keys_table\n' "$where" "$k" ;;
    esac
  done <<EOF
$bound
EOF
  while IFS= read -r k; do
    case $k in ''|ctrl-q|esc) continue ;; esac
    case "$bound" in *"$k"*) pass=$((pass+1)); printf '  ok   %s: %s is listed and bound\n' "$where" "$k" ;;
      *) fail=$((fail+1)); printf '  FAIL %s: %s has a row in keys_table and nothing is bound to it\n' "$where" "$k" ;;
    esac
  done <<EOF
$TABLE
EOF
}
drift sidebar "$(binds_of "$SIDEBAR")"
drift popup   "$(binds_of "$POPUP")"

# ---------------------------------------------------------------------------
t "7. every key comes out of the config"
# ---------------------------------------------------------------------------
# A key moved in the config is the key fzf is handed and the key the ? window
# lists — one answer, arrived at once, in both places.
KCFG="$ROOT/keys-good.yaml"
cat >"$KCFG" <<'YEOF'
keys:
  closed: ctrl-o
  borrow: ctrl-y
YEOF
KDUMP=$(dumpargs "$ROOT/fzf-keys" "TA_CONFIG='$KCFG'")
has "a configured key is the one fzf binds" \
    "--bind=ctrl-o:execute-silent($SELF --act closed)" "$KDUMP"
has "...and the key it displaced moves with it" \
    "--bind=ctrl-y:execute-silent($SELF --act borrow {1})" "$KDUMP"
KT=$(env TMUX="$TMUXV" TA_CONFIG="$KCFG" bash "$TA" --keys)
has "...and --keys says the same"     "ctrl-o${TAB}:closed" "$KT"
has "...for both of them"             "ctrl-y${TAB}borrow"  "$KT"

# A KEY FZF DOES NOT KNOW WOULD STOP IT STARTING, so it never reaches fzf: the
# default is kept and the reason is said out loud.
BCFG="$ROOT/keys-bogus.yaml"
printf 'keys:\n  closed: bogus\n' >"$BCFG"
BDUMP=$(dumpargs "$ROOT/fzf-bogus" "TA_CONFIG='$BCFG'")
has "an unusable key falls back to the default" \
    "--bind=ctrl-y:execute-silent($SELF --act closed)" "$BDUMP"
ok  "...and nothing is bound to the name itself" 0 \
    "$(printf '%s\n' "$BDUMP" | grep -c '^--bind=bogus:' | tr -d ' ')"
has "...and --keys says why" \
    "# keys.closed: 'bogus' is not a key fzf knows — using ctrl-y" \
    "$(env TMUX="$TMUXV" TA_CONFIG="$BCFG" bash "$TA" --keys)"

# TWO VERBS ON ONE KEY IS ONE VERB GONE — fzf keeps the last --bind silently, so
# the collision is settled here instead: the verb that owns the key by the
# table's order keeps it, and the late one goes back to its own default.
CCFG="$ROOT/keys-clash.yaml"
printf 'keys:\n  send: ctrl-g\n' >"$CCFG"
CDUMP=$(dumpargs "$ROOT/fzf-clash" "TA_CONFIG='$CCFG'")
has "the verb that had the key keeps it" \
    "--bind=ctrl-g:execute-silent($SELF --act goto {1})" "$CDUMP"
has "...and the one that asked for it stays on its default" \
    "--bind=ctrl-e:execute-silent($SELF --act send {1})" "$CDUMP"
ok  "...so the key is bound exactly once" 1 \
    "$(printf '%s\n' "$CDUMP" | grep -c '^--bind=ctrl-g:' | tr -d ' ')"
has "...and --keys says which" \
    "# keys.send: ctrl-g is taken already — using ctrl-e" \
    "$(env TMUX="$TMUXV" TA_CONFIG="$CCFG" bash "$TA" --keys)"

# ---------------------------------------------------------------------------
t "8. the dialogs draw — fzf paints on stderr, and nothing may silence it"
# ---------------------------------------------------------------------------
# On fzf 0.52 the UI goes to fd 2; an fzf run with 2>/dev/null is a blank modal
# that still takes keys. The account picker was exactly that for a whole
# session. Two guards: a static scan of every fzf call, and the picker itself
# rendered in a pane and read back.
ok "no fzf dialog throws its stderr away" "" \
   "$(awk 'FNR==1 {s=0}
           /\| *fzf |^[[:space:]]*fzf --/{s=FNR}
           s && FNR-s<8 && /2>\/dev\/null\)/ {print FILENAME":"FNR; s=0}' \
        "$TA" "$HERE"/../lib/tagents/*.sh)"
PWIN=$(tm new-window -d -t tatest-work: -P -F '#{pane_id}' -c "$REPO" \
         "exec bash --noprofile --norc" 2>/dev/null)
sleep 0.4
tm send-keys -t "$PWIN" "clear; env TA_CONFIG='$CFG' '$TA' --ask-profile pick '$REPO' tatest-dash" Enter
i=0; while [ "$i" -lt 40 ]; do
  case "$(tm capture-pane -p -t "$PWIN" 2>/dev/null)" in *"account>"*) break ;; esac
  sleep 0.1; i=$((i+1))
done
SCREEN=$(tm capture-pane -p -t "$PWIN" 2>/dev/null)
has "the account picker has its prompt on screen"  "account>"           "$SCREEN"
has "...and the profile rows"                       "default (~/.claude)" "$SCREEN"
has "...and its header"                             "start a new agent"   "$SCREEN"
tm send-keys -t "$PWIN" Escape 2>/dev/null; sleep 0.3
tm kill-window -t "$PWIN" 2>/dev/null

# ---------------------------------------------------------------------------
t "9. a wrong config is on the dashboard, and in the status bar"
# ---------------------------------------------------------------------------
# The reported bug: a profile whose config_dir is not on this machine, and a
# dashboard that looked fine while the agent it started was logged out. The
# list is drawn for real in a pane — popup mode, so it claims no sidebar and esc
# closes it — and read back. A session of its own, 220 columns wide: popup mode
# gives 55% of the pane to the preview, and at 80 columns the header is
# truncated to ".." before the item under test. Sized by hand, because with the
# keeper client attached on an 80x24 pty, window-size=latest makes every new
# window 80 wide whatever -x asks for. Last, so the list it draws disturbs
# nothing above.
BROKEN="$ROOT/config-broken.yaml"
cat >"$BROKEN" <<EOF
claude:
  profiles:
    personal:
      config_dir: $ROOT/claude-nowhere
    work:
EOF
tm new-session -d -s tatest-cfg -x 220 -y 50 -c "$REPO" "exec bash --noprofile --norc" 2>/dev/null
tm set -w -t tatest-cfg: window-size manual 2>/dev/null
tm resize-window -t tatest-cfg: -x 220 -y 50 2>/dev/null
CWIN=$(tm display -p -t tatest-cfg: '#{pane_id}' 2>/dev/null)
sleep 0.4
tm send-keys -t "$CWIN" "clear; env TA_CONFIG='$BROKEN' TA_MODE=popup '$TA'" Enter
i=0; while [ "$i" -lt 60 ]; do
  case "$(tm capture-pane -p -t "$CWIN" 2>/dev/null)" in *"agents>"*) break ;; esac
  sleep 0.1; i=$((i+1))
done
SCREEN=$(tm capture-pane -p -t "$CWIN" 2>/dev/null)
has "the header says how many problems, and where to look" \
    "config: 1 problem (tagents --check)" "$SCREEN"
tm send-keys -t "$CWIN" Escape 2>/dev/null; sleep 0.3
tm kill-session -t tatest-cfg 2>/dev/null
has   "the status bar carries it too" "cfg!1" \
      "$(env TMUX="$TMUXV" TA_CONFIG="$BROKEN" bash "$TA" --counts 2>/dev/null)"
hasnt "...and says nothing for the good one" "cfg!" "$(run --counts 2>/dev/null)"
hasnt "...nor does the header"               "config:" "$(run --header 100 'open here' 'ctrl-q quit')"

# The count the bar shows is remembered against the config's own mtime rather
# than recomputed on every tick, so two things have to hold: a second call
# agrees with the first, and fixing the file clears the marker at once instead
# of when a timer allows.
has "a second call agrees with the first" "cfg!1" \
    "$(env TMUX="$TMUXV" TA_CONFIG="$BROKEN" bash "$TA" --counts 2>/dev/null)"
mkdir -p "$ROOT/claude-nowhere"; : >"$ROOT/claude-nowhere/.claude.json"
sleep 1   # mtime is the key and it is kept in seconds
cat >"$BROKEN" <<EOF
claude:
  profiles:
    personal:
      config_dir: $ROOT/claude-nowhere
    work:
EOF
hasnt "fixing the config clears it on the next call" "cfg!" \
      "$(env TMUX="$TMUXV" TA_CONFIG="$BROKEN" bash "$TA" --counts 2>/dev/null)"
# And a problem fixed WITHOUT touching the config — the directory appearing —
# is picked up when the verdict ages out, which TA_CFG_CHECK_EVERY=0 forces.
rm -rf "$ROOT/claude-nowhere"
has "a problem that returns is seen again once the verdict ages out" "cfg!1" \
    "$(env TMUX="$TMUXV" TA_CONFIG="$BROKEN" TA_CFG_CHECK_EVERY=0 bash "$TA" --counts 2>/dev/null)"

# ---------------------------------------------------------------------------
t "10. the order — projects keep their place, rows follow when you last typed"
# ---------------------------------------------------------------------------
# WHAT THIS IS FOR. The list used to be sorted by state: a project climbed to the
# top the moment one of its agents blocked and dropped back when you answered it,
# and inside a project a row jumped as its agent went working → idle → working.
# Nothing you can read that way stays where you left it. The order is now the
# path for projects and "when did I last type into it" for rows — the one clock
# that does not move during a turn.
mkdir -p "$STATE/prompt"
said() { printf '%s\n' "$(( $(date +%s) - $2 ))" >"$STATE/prompt/${1#%}"; }

# A second project, whose path sorts AFTER the first — the point of the checks
# below is that nothing it does moves it off that place.
REPO2="$ROOT/repo-z"; mkdir -p "$REPO2/.git"
# ...and a third with nothing but a closed agent in it, whose path sorts FIRST.
REPO3="$ROOT/repo-aaa"; mkdir -p "$REPO3/.git"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date +%s)" done sid-cold "$REPO3" "" "over" "$LOGIN" >"$STATE/8010.tsv"
said %8010 30

agent() {  # <dir> <pane key var> — a live claude in its own window
  tm new-window -d -t tatest-work: -P -F '#{pane_id}' -c "$1" \
    "exec '$BIN/claude' 600" 2>/dev/null
}
live() {  # <pane> <state> <sid> <dir>
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%s)" "$2" "$3" "$4" "" "on it" "$LOGIN" >"$STATE/${1#%}.tsv"
}
A2=$(agent "$REPO")
B=$(agent "$REPO2")
live "$A2" working sid-live2 "$REPO"
live "$B"  working sid-liveZ "$REPO2"
# A is the live agent of section 0, and is the older conversation of the two.
said "$A"  600
said "$A2"  60
said "$B"   60
said %8001  90
said %8002 300
said %8003 900
said %8004  30
sleep 0.3

groups() { rows_at 140 | awk -F'\t' 'index($2, "\342\226\276") > 0 { split($2, a, " "); print a[2] }' | tr '\n' ' '; }
order()  { rows_at 140 | awk -F'\t' 'index($2, "\342\226\276") == 0 { print $1 }' | tr '\n' ' '; }
ok "projects sort by path, and the closed-only one is last" \
   "repo repo-z repo-aaa " "$(groups)"
ok "inside a project the newest conversation is on top, closed ones below" \
   "$A2 $A %8004 %8001 %8002 %8003 %8010 " \
   "$(order | sed "s/$B //")"

# THE CHECK THIS EXISTS FOR. Everything above moved only because a timestamp
# said so; here nothing moves at all, because a state change is not one.
live "$B" blocked sid-liveZ "$REPO2"
ok "a blocked agent does not drag its project up the list" \
   "repo repo-z repo-aaa " "$(groups)"
live "$A" blocked sid-live "$REPO"
ok "...nor its own row up its project" \
   "$A2 $A %8004 %8001 %8002 %8003 %8010 " "$(order | sed "s/$B //")"
live "$A" working sid-live "$REPO"

# ...and typing into it IS one: the only thing that reorders the list is you.
said "$A" 1
ok "answering it puts it on top, where you just left off" \
   "$A $A2 %8004 %8001 %8002 %8003 %8010 " "$(order | sed "s/$B //")"
said "$A" 600

# The header is a stand-in for the row under it, which is now the newest one
# rather than the most urgent — enter on a header and enter on its first row
# must still mean the same agent.
ok "the header carries the pane id of the row below it" "$A2" \
   "$(rows_at 140 | awk -F'\t' 'index($2, "\342\226\276") > 0 { print $1; exit }')"

# ---------------------------------------------------------------------------
t "10b. the age column is time since YOUR last message"
# ---------------------------------------------------------------------------
# The record is rewritten on every tool call, so an age taken from it read 0:00
# for every working agent — useless for the one question it is asked: how long
# since I last said anything, i.e. how much of the one-hour prompt cache is left.
live "$A2" working sid-live2 "$REPO"     # record timestamp: now
said "$A2" 1800                          # ...but the last prompt was 30m ago
has "a working agent says how long its turn has been running" " 30:00  " \
    "$(row_of "$A2" "$(rows_at 140)")"
said "$A2" 3660
has "past the hour it reads in hours, which is the cache gone" " 1h01  " \
    "$(row_of "$A2" "$(rows_at 140)")"
# A session recorded before the hook ever wrote one of these files has nothing
# but its event time, and must still render an age rather than 1970.
rm -f "$STATE/prompt/${A2#%}"
hasnt "a session with no prompt file yet does not fall back to the epoch" "h" \
      "$(row_of "$A2" "$(rows_at 140)" | sed 's/[^0-9h:].*//')"

tm kill-pane -t "$A2" 2>/dev/null
tm kill-pane -t "$B" 2>/dev/null

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
