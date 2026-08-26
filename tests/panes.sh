#!/usr/bin/env bash
#
# tests/panes.sh — seats: several chats docked side by side, panes that belong to
# nobody but the user, and closing a pane without closing a session.
#
# NOTHING HERE MAY TOUCH THE DEFAULT TMUX SOCKET. The server is created with
# `tmux -L tatest-$$ -f /dev/null` and torn down in the trap, and tagents is
# pointed at it by exporting $TMUX in the test process — never by putting a
# `tmux` shim on $PATH, which has already once let a test relocate a real pane
# when the shim went missing.
#
# The dashboard under test is a REAL list: `tagents` running in a pane of that
# server, claiming it, with its refresher behind it. The agents are a copy of
# /bin/sleep named `claude`, so the process walk in live_panes counts them —
# a #!/bin/sh stub would be a `sh` to ps and would never be a live agent.
#
# bash 3.2, runnable from any cwd, non-zero exit on any failing check.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TA="$HERE/../tagents"

command -v tmux >/dev/null 2>&1 || { echo "panes.sh: no tmux"; exit 1; }
command -v fzf  >/dev/null 2>&1 || { echo "panes.sh: no fzf"; exit 1; }

S=tatest-$$
SOCK=""
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tagents-panes.XXXXXX") || exit 1
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
         else fail=$((fail+1)); printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fi; }
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
# asks, and a #!/bin/sh script would not do: macOS ps reports the INTERPRETER, so
# a script called claude is an `sh` to everything that looks. So the stub is a
# copy of /bin/sleep under that name — and a copy of a system binary is killed on
# sight on arm64 (its signature is only valid for the original inode), which is
# what the ad-hoc re-sign is for. tusage is real and reads the real usage index;
# stubbed to nothing so this stays hermetic and fast.
cp /bin/sleep "$BIN/claude" || exit 1
codesign --remove-signature "$BIN/claude" >/dev/null 2>&1
codesign -f -s - "$BIN/claude" >/dev/null 2>&1
"$BIN/claude" 0 >/dev/null 2>&1 ||
  { echo "panes.sh: cannot build a stub agent (codesign?)"; exit 1; }
printf '#!/bin/sh\nexit 0\n' >"$BIN/tusage"
chmod +x "$BIN/claude" "$BIN/tusage"

# EXPORTED BEFORE THE SERVER EXISTS. A tmux server keeps the environment it was
# started with and hands it to every command it runs, so anything the list or an
# agent pane needs has to be in place now.
export PATH="$BIN:$PATH"
export TA_STATE_DIR="$STATE"
export TA_SESSION=tatest-dash
export TA_CONFIG=/nonexistent/config.yaml   # no profiles: no dialog anywhere
unset TMUX TMUX_PANE TA_MODE TA_FLAT TA_COLS TA_NEW_CMD TA_RESUME_CMD TA_HOME
unset CLAUDE_CONFIG_DIR

tm() { tmux -L "$S" "$@"; }

tm -f /dev/null new-session -d -s tatest-dash -x 200 -y 50 "exec '$TA'" || exit 1
tm set -g default-shell /bin/sh >/dev/null 2>&1
tm set -g default-command '' >/dev/null 2>&1
tm new-session -d -s tatest-work -c "$REPO" >/dev/null 2>&1

SOCK=$(tm display -p '#{socket_path}' 2>/dev/null)
[ -n "$SOCK" ] || { echo "panes.sh: no socket for $S"; exit 1; }

# A client on a pty, so the focus hooks have somewhere to fire and select-pane
# means something. Its stdin is a sleep, so it never reads EOF and detaches on
# its own; the whole thing is orphaned deliberately, which is why the sleep
# writes its pid down for the trap rather than being a job to wait on.
( { sleep 300 & printf '%s\n' "$!" >"$ROOT/keeper.pid"; wait; } |
    script -q /dev/null tmux -L "$S" attach -t tatest-dash >/dev/null 2>&1 & ) >/dev/null 2>&1
sleep 0.5

run() { env TMUX="$SOCK,0,0" bash "$TA" "$@"; }

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
where()  { tm display -p -t "${1:-}" '#{window_id}' 2>/dev/null; }
npanes() { tm list-panes -t "${1:-}" -F x 2>/dev/null | wc -l | tr -d ' '; }
nwins()  { tm list-windows -a -F x 2>/dev/null | wc -l | tr -d ' '; }
lives()  { tm list-panes -a -F '#{pane_id}' 2>/dev/null |
             awk -v p="${1:-}" '$1 == p { f = 1 } END { print f ? "yes" : "no" }'; }
layout() { tm list-panes -t "${1:-}" -F '#{pane_id}' 2>/dev/null | tr '\n' ' '; }

# The seats of the sidebar window, as one line: "%12:docked %14:free".
kinds() {
  run --seats "$LIST" 2>/dev/null |
    awk -F'\t' '{ s = s (s == "" ? "" : " ") $1 ":" $2 } END { print s }'
}
# Which placeholder is keeping a given chat's seat, and where.
parked_for() {
  tm list-panes -a -F '#{pane_id} #{?@tagents_slot,slot,-} #{@tagents_parked}' 2>/dev/null |
    awk -v a="${1:-}" '$2 == "slot" && $3 == a { print $1; exit }'
}
free_seat() { run --seats "$LIST" 2>/dev/null | awk -F'\t' '$2 == "free" { print $1; exit }'; }
# Which seat the sidebar window thinks the cursor is in, as tmux stores it.
cur_opt() { tm show -vw -t "$DWIN" @tagents_cur 2>/dev/null; }

# THE USER'S TERMINAL, ASSERTED AFTER EVERY SINGLE STEP. A sidebar window that
# holds nothing but seats is the two-pane shape the old positional code got right
# as well, so a check that runs without a marker-less pane in the window proves
# nothing about the report this all comes from. One terminal is created before
# the first check and lives to the last; every numbered check ends with this.
term_ok() { ok "the user terminal is untouched ($1)" \
               "yes $TWIN" "$(lives "$TERM1") $(where "$TERM1")"; }

# A row of the list, by pane id — never the group header, which carries its most
# urgent member's pane id as well.
row_of() {
  printf '%s\n' "${2:-}" |
    awk -F'\t' -v p="${1:-}" 'index($2, "\342\226\276") == 0 && $1 == p { print $2; exit }'
}

n=0
mkagent() {  # <name> -> the pane of a new agent window in the work session
  local nm=$1 p
  n=$((n + 1))
  p=$(tm new-window -d -t tatest-work: -P -F '#{pane_id}' -c "$REPO" \
        "exec '$BIN/claude' 600" 2>/dev/null)
  # A record of its own, so the agent has a row in the list to be marked on.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%s)" working "sid-$nm" "$REPO" "" "agent $nm" "" >"$STATE/${p#%}.tsv"
  printf '%s\t%s\n' "sid-$nm" "$nm" >>"$STATE/labels.tsv"
  printf '%s' "$p"
}

# The list claims the pane it runs in; everything here needs that claim.
LIST=""
i=0
while [ "$i" -lt 80 ]; do
  LIST=$(tm list-panes -a -F '#{pane_id} #{@tagents_list}' 2>/dev/null |
           awk '$2 != "" { print $1; exit }')
  [ -n "$LIST" ] && break
  i=$((i + 1)); sleep 0.25
done
[ -n "$LIST" ] || { echo "panes.sh: the list never claimed a pane"; exit 1; }
DWIN=$(where "$LIST")

A=$(mkagent A); AHOME=$(where "$A")
B=$(mkagent B); BHOME=$(where "$B")
C=$(mkagent C); CHOME=$(where "$C")

# One seat to start from, rather than waiting on the refresher to notice.
run --ensure-seat "$LIST" >/dev/null 2>&1
sleep 0.3

# ---------------------------------------------------------------------------
t "0. the ground the rest stands on"
# ---------------------------------------------------------------------------
ok "the sidebar starts as the list and one free seat" \
   "$(free_seat):free" "$(kinds)"
ok "...which is two panes" 2 "$(npanes "$DWIN")"
has "the stub is a live agent, not a closed row" "working" \
    "$(run --list | awk -F'\t' -v p="$A" '$1 == p { print $3; exit }')"
has "--counts still counts the live agents" "●" "$(run --counts)"
HELP=$(run --help)
has "--help documents the collapse entry" "--collapse"    "$HELP"
has "...and the seat repair"              "--ensure-seat" "$HELP"

# The user's terminal, split BELOW the list — the reported layout — before
# anything is ever docked. It stays for the whole run; see term_ok.
TERM1=$(tm split-window -v -d -t "$LIST" -P -F '#{pane_id}' "sleep 600" 2>/dev/null)
TWIN=$(where "$TERM1")
ok "a user terminal in the sidebar window" "$DWIN" "$TWIN"

# ---------------------------------------------------------------------------
t "1. a terminal split below the list is not the docked chat"
# ---------------------------------------------------------------------------
# The reported layout exactly: columns(rows(list, terminal), chat). Enter used to
# take the terminal for the chat, break it out into a window of its own, and dock
# into a third column.
run --act open "$A" live sid-A "$REPO"; sleep 0.4
wins=$(nwins)
run --act open "$B" live sid-B "$REPO"; sleep 0.4
ok "the chosen agent is docked"          "$DWIN"  "$(where "$B")"
ok "the one it replaced went home"       "$AHOME" "$(where "$A")"
ok "the terminal is still there"         yes      "$(lives "$TERM1")"
ok "...in the same window"               "$TWIN"  "$(where "$TERM1")"
ok "no window was opened for it"         "$wins"  "$(nwins)"
ok "no third column"                     3        "$(npanes "$DWIN")"
ok "the only seat is the chat"           "$B:docked" "$(kinds)"
term_ok 1

# ---------------------------------------------------------------------------
t "2. ctrl-s opens a second chat beside the first"
# ---------------------------------------------------------------------------
run --undock-window "$DWIN"; sleep 0.4
# ctrl-s with nothing docked has nothing to sit beside. It used to split a new
# placeholder off the empty one regardless, which left a grey pane a chat wide
# standing between the list and the chat with nothing to ever close it.
EMPTY=$(free_seat)
run --act beside "$A" live sid-A "$REPO"; sleep 0.4
ok "ctrl-s on an empty sidebar docks into the seat" "$DWIN" "$(where "$A")"
ok "...the placeholder took the chat's place at home" "$AHOME" "$(where "$EMPTY")"
ok "...and no second seat was split"           "$A:docked" "$(kinds)"
ok "...so the sidebar is list, terminal, chat" 3 "$(npanes "$DWIN")"
run --undock-window "$DWIN"; sleep 0.4
run --act open "$A" live sid-A "$REPO"; sleep 0.4
run --act beside "$B" live sid-B "$REPO"; sleep 0.4
ok "both chats are in the sidebar" "$DWIN$DWIN" "$(where "$A")$(where "$B")"
ok "list, terminal, A and B"       4 "$(npanes "$DWIN")"
ok "two seats, both docked"        "$A:docked $B:docked" "$(kinds)"
ok "A's seat is kept at home"      "$AHOME" "$(where "$(parked_for "$A")")"
ok "B's seat is kept at home"      "$BHOME" "$(where "$(parked_for "$B")")"
term_ok 2

# ---------------------------------------------------------------------------
t "3. the list marks the docked chats, and the one you are in"
# ---------------------------------------------------------------------------
tm select-pane -t "$A" 2>/dev/null; sleep 0.5
ok "the seat you focused is the current one" "$A" "$(run --current-seat "$LIST")"
ROWS=$(TA_COLS=120 run --list)
has   "the current chat is marked"     "▶" "$(row_of "$A" "$ROWS")"
has   "the other docked one is marked" "▹" "$(row_of "$B" "$ROWS")"
hasnt "...and only one row is current" "▶" "$(row_of "$B" "$ROWS")"
hasnt "an undocked agent is unmarked"  "▹" "$(row_of "$C" "$ROWS")"

tm select-pane -t "$B" 2>/dev/null; sleep 0.5
ok "focusing the other seat moves it" "$B" "$(run --current-seat "$LIST")"
ROWS=$(TA_COLS=120 run --list)
has   "the mark follows the cursor"   "▶" "$(row_of "$B" "$ROWS")"
hasnt "...and leaves the other one"   "▶" "$(row_of "$A" "$ROWS")"
# The status bar reads one field of a row and throws the marks away, so it does
# not pay for working them out. TA_MARKS=0 is what --counts sets.
hasnt "TA_MARKS=0 renders none of it" "▶" "$(TA_MARKS=0 TA_COLS=120 run --list)"
term_ok 3

# ---------------------------------------------------------------------------
t "4. --undock-pane sends one chat home and closes its seat"
# ---------------------------------------------------------------------------
BPID=$(tm display -p -t "$B" '#{pane_pid}' 2>/dev/null)
PB=$(parked_for "$B")
run --undock-pane "$B"; rc=$?
sleep 0.4
ok "it exits 0 on a docked chat"        0 "$rc"
ok "the chat is back in its own window" "$BHOME" "$(where "$B")"
ok "the same pane, not a new one"       yes "$(lives "$B")"
ok "...with its claude still running"   0 "$(kill -0 "$BPID" 2>/dev/null; echo $?)"
ok "the seat it left is closed"         no "$(lives "$PB")"
ok "the sidebar is the list, the terminal and A" 3 "$(npanes "$DWIN")"
ok "one seat, still docked"             "$A:docked" "$(kinds)"
term_ok 4

# ---------------------------------------------------------------------------
t "5. enter replaces the seat you are in, not the other one"
# ---------------------------------------------------------------------------
run --act beside "$B" live sid-B "$REPO"; sleep 0.4
tm select-pane -t "$A" 2>/dev/null; sleep 0.5
run --act open "$C" live sid-C "$REPO"; sleep 0.4
ok "the new chat took the seat it was in" "$DWIN"  "$(where "$C")"
ok "the chat that was in it went home"    "$AHOME" "$(where "$A")"
ok "the other seat was left alone"        "$DWIN"  "$(where "$B")"
ok "still two seats"                      4 "$(npanes "$DWIN")"
term_ok 5

# ---------------------------------------------------------------------------
t "6. the last seat is never closed"
# ---------------------------------------------------------------------------
run --undock-pane "$B" >/dev/null 2>&1; sleep 0.4
PC=$(parked_for "$C")
run --undock-pane "$C" >/dev/null 2>&1; sleep 0.4
ok "the last chat goes home too"        "$CHOME" "$(where "$C")"
ok "...and its placeholder stays as the seat" "$PC:free" "$(kinds)"
ok "the sidebar is the list, the terminal and the seat" 3 "$(npanes "$DWIN")"
# The marker for "which seat is current" may not outlive the seat it names: it
# is the one docking marker nothing else ever clears.
ok "and the current-seat marker does not name the chat that left" no \
   "$(if [ "$(cur_opt)" = "$C" ]; then echo yes; else echo no; fi)"
term_ok 6

# ---------------------------------------------------------------------------
t "7. --undock-pane refuses everything that is not a docked chat"
# ---------------------------------------------------------------------------
before=$(layout "$DWIN")
run --undock-pane "$TERM1"; ok "a terminal is not ours"      1 "$?"
run --undock-pane "$PC";    ok "a placeholder is not a chat" 1 "$?"
run --undock-pane "$LIST";  ok "nor is the list"             1 "$?"
ok "and nothing moved" "$before" "$(layout "$DWIN")"
term_ok 7

# ---------------------------------------------------------------------------
t "8. --undock-window empties the sidebar for a kill-window binding"
# ---------------------------------------------------------------------------
run --act open "$A" live sid-A "$REPO"; sleep 0.4
run --act beside "$B" live sid-B "$REPO"; sleep 0.4
run --undock-window "$DWIN"; rc=$?
sleep 0.4
ok "it exits 0"                     0 "$rc"
ok "A is home"                      "$AHOME" "$(where "$A")"
ok "B is home"                      "$BHOME" "$(where "$B")"
ok "one seat is left behind"        free "$(run --seats "$LIST" | awk -F'\t' '{ print $2; exit }')"
before=$(layout "$AHOME")
run --undock-window "$AHOME"; ok "a window with nothing docked is fine too" 0 "$?"
ok "...and unchanged"               "$before" "$(layout "$AHOME")"
term_ok 8

# ---------------------------------------------------------------------------
t "9. a seat that dies is rebuilt, terminal or no terminal"
# ---------------------------------------------------------------------------
# The old test for this was "is the window down to one pane", which stopped
# being true the moment somebody opened a terminal in the sidebar — so a dead
# seat was never repaired again.
tm kill-pane -t "$(free_seat)" 2>/dev/null; sleep 0.3
ok "no seat left at all" "" "$(kinds)"
i=0
while [ "$i" -lt 40 ]; do
  [ -n "$(free_seat)" ] && break
  i=$((i + 1)); sleep 0.5
done
ok "the refresher puts one back"  free "$(run --seats "$LIST" | awk -F'\t' '{ print $2; exit }')"
ok "exactly one"                  1 "$(run --seats "$LIST" | wc -l | tr -d ' ')"
term_ok 9

# ---------------------------------------------------------------------------
t "10. going to a placeholder brings its chat home, and closes the seat"
# ---------------------------------------------------------------------------
run --act open "$A" live sid-A "$REPO"; sleep 0.4
run --act beside "$B" live sid-B "$REPO"; sleep 0.4
PA=$(parked_for "$A")
run --unpark "$PA"; sleep 0.5
i=0
while [ "$i" -lt 20 ]; do
  [ "$(lives "$PA")" = no ] && break
  i=$((i + 1)); sleep 0.25
done
ok "the chat came home"            "$AHOME" "$(where "$A")"
ok "the seat it left is closed"    no "$(lives "$PA")"
ok "the other chat is still docked" "$B:docked" "$(kinds)"

PB=$(parked_for "$B")
run --unpark "$PB"; sleep 0.8
ok "the last one comes home too"   "$BHOME" "$(where "$B")"
ok "...and its placeholder stays"  "$PB:free" "$(kinds)"
term_ok 10

# ---------------------------------------------------------------------------
t "11. the plain two-pane sidebar behaves exactly as it did"
# ---------------------------------------------------------------------------
# The one check that has to see a sidebar holding nothing but seats, so the
# terminal steps out into a window of its own for the length of it and comes
# back afterwards — the same pane throughout, which is what every term_ok here
# is about.
tm break-pane -d -s "$TERM1" 2>/dev/null; sleep 0.3
run --act open "$A" live sid-A "$REPO"; sleep 0.4
ok "docked"                          "$DWIN"  "$(where "$A")"
ok "two panes, list and chat"        2 "$(npanes "$DWIN")"
ok "the placeholder holds its seat"  "$AHOME" "$(where "$(parked_for "$A")")"
run --act undock "$A"; sleep 0.4
ok "ctrl-u sends it home"            "$AHOME" "$(where "$A")"
ok "still two panes"                 2 "$(npanes "$DWIN")"
ok "and the seat is free again"      free "$(run --seats "$LIST" | awk -F'\t' '{ print $2; exit }')"
tm join-pane -v -d -s "$TERM1" -t "$LIST" 2>/dev/null; sleep 0.3
term_ok 11

# ---------------------------------------------------------------------------
t "12. killing one docked chat leaves the other one alone"
# ---------------------------------------------------------------------------
run --act open "$A" live sid-A "$REPO"; sleep 0.4
run --act beside "$B" live sid-B "$REPO"; sleep 0.4
# TA_MODE=popup makes the confirmation run inline, on this pipe: a popup cannot
# open a popup, and that is the path ctrl-x takes in the prefix+a list.
printf 'y\n' | TA_MODE=popup run --act kill "$B" live sid-B >/dev/null 2>&1
sleep 0.8
ok "the agent it named is gone"       no "$(lives "$B")"
ok "the other chat is still docked"   "$DWIN" "$(where "$A")"
ok "and still the only seat"          "$A:docked" "$(kinds)"
ok "the sidebar is list, terminal and chat" 3 "$(npanes "$DWIN")"
term_ok 12

# ---------------------------------------------------------------------------
t "13. a row whose pane died between the render and the keypress"
# ---------------------------------------------------------------------------
# The row says "working" for up to two seconds after its claude exits, which is
# the window ask_kill has always guarded against. Enter used to stamp the
# placeholder as standing in for a pane that was already gone — a seat parked for
# nobody, which collapse_seat refuses for ever — and ctrl-s used to split a fresh
# placeholder first, leaking one pane per keypress.
D=$(mkagent D)
tm kill-pane -t "$D" 2>/dev/null; sleep 0.4
before=$(kinds); beforen=$(npanes "$DWIN")
run --act open "$D" live sid-D "$REPO" >/dev/null 2>&1; sleep 0.4
ok "enter on it leaves the seats alone" "$before"  "$(kinds)"
ok "...and opens no pane"               "$beforen" "$(npanes "$DWIN")"
run --act beside "$D" live sid-D "$REPO" >/dev/null 2>&1; sleep 0.4
ok "ctrl-s on it leaves the seats alone" "$before"  "$(kinds)"
ok "...and leaks no seat"                "$beforen" "$(npanes "$DWIN")"
ok "no placeholder is parked for a pane that is gone" "" "$(parked_for "$D")"
term_ok 13

# ---------------------------------------------------------------------------
t "14. two placeholders unparked at once still leave a seat"
# ---------------------------------------------------------------------------
# One gesture per window, a focus hook on each: both unparks read "two seats, so
# there is another one" before either kills, and the sidebar ends up with no seat
# at all — the one thing the whole design rests on never happening.
run --undock-window "$DWIN" >/dev/null 2>&1; sleep 0.4
run --act open "$A" live sid-A "$REPO"; sleep 0.4
run --act beside "$C" live sid-C "$REPO"; sleep 0.4
PA=$(parked_for "$A"); PC=$(parked_for "$C")
ok "two chats to bring home" "$DWIN$DWIN" "$(where "$A")$(where "$C")"
run --unpark "$PA" >/dev/null 2>&1 &
run --unpark "$PC" >/dev/null 2>&1 &
wait
i=0
while [ "$i" -lt 8 ]; do
  [ "$(run --seats "$LIST" | wc -l | tr -d ' ')" = 1 ] && break
  i=$((i + 1)); sleep 0.25
done
ok "both chats came home"          "$AHOME$CHOME" "$(where "$A")$(where "$C")"
ok "and exactly one seat is left"  1 "$(run --seats "$LIST" | wc -l | tr -d ' ')"

# ...and the same thing without having to win a race to see it. Several free
# placeholders at once is the state those unparks leave behind for the instant
# before either collapse runs, and --collapse is the entry point their command
# lists call; four of them makes the interleaving reliable rather than lucky.
# Every one of these used to read "more than one seat, so there is another" and
# every one of them used to kill.
i=0
while [ "$(run --seats "$LIST" | wc -l | tr -d ' ')" -lt 4 ] && [ "$i" -lt 6 ]; do
  P2=$(tm split-window -h -d -P -F '#{pane_id}' -t "$LIST" "exec '$TA' --slot" 2>/dev/null)
  [ -n "$P2" ] && tm set -p -t "$P2" @tagents_slot 1 2>/dev/null
  i=$((i + 1)); sleep 0.2
done
ok "four free seats to close" 4 "$(run --seats "$LIST" | wc -l | tr -d ' ')"
for s in $(run --seats "$LIST" | awk -F'\t' '{ print $1 }'); do
  run --collapse "$s" >/dev/null 2>&1 &
done
wait
sleep 0.6
ok "they close down to one, never to none" 1 "$(run --seats "$LIST" | wc -l | tr -d ' ')"

# ...and deterministically, because a race that is only sometimes lost is a
# check that only sometimes runs. Holding the lock a collapse has to take is the
# same interleaving as losing the race, on demand: the seat count it read is
# somebody else's business now, so it must leave the seat standing rather than
# act on what it saw.
P2=$(tm split-window -h -d -P -F '#{pane_id}' -t "$LIST" "exec '$TA' --slot" 2>/dev/null)
[ -n "$P2" ] && tm set -p -t "$P2" @tagents_slot 1 2>/dev/null
sleep 0.3
ok "two free seats again" 2 "$(run --seats "$LIST" | wc -l | tr -d ' ')"
mkdir "$STATE/.collapse.lock" 2>/dev/null
run --collapse "$(free_seat)" >/dev/null 2>&1
ok "a collapse that cannot take the lock closes nothing" \
   2 "$(run --seats "$LIST" | wc -l | tr -d ' ')"
rmdir "$STATE/.collapse.lock" 2>/dev/null
run --collapse "$(free_seat)" >/dev/null 2>&1; sleep 0.3
ok "...and with the lock free it closes the seat" \
   1 "$(run --seats "$LIST" | wc -l | tr -d ' ')"
ok "and nothing is left holding it" no \
   "$(if [ -d "$STATE/.collapse.lock" ]; then echo yes; else echo no; fi)"
term_ok 14

# ---------------------------------------------------------------------------
t "15. the current seat survives a walk through a terminal and the list"
# ---------------------------------------------------------------------------
# The seat you were last in is where enter opens the next chat, and by the time
# you press enter you are in the list — so tmux's own active and last pane are
# both panes of somebody else's. The focus hook is what records the seat.
run --act open "$A" live sid-A "$REPO"; sleep 0.4
run --act beside "$C" live sid-C "$REPO"; sleep 0.4
tm select-pane -t "$A" 2>/dev/null; sleep 0.4
ok "the seat you focused is current"  "$A" "$(run --current-seat "$LIST")"
tm select-pane -t "$TERM1" 2>/dev/null; sleep 0.3
tm select-pane -t "$LIST" 2>/dev/null; sleep 0.3
ok "...still, from the list"          "$A" "$(run --current-seat "$LIST")"
ROWS=$(TA_COLS=120 run --list)
has   "and the row marked is its own"  "▶" "$(row_of "$A" "$ROWS")"
hasnt "not the seat you were not in"   "▶" "$(row_of "$C" "$ROWS")"
term_ok 15

# ---------------------------------------------------------------------------
t "16. the current-seat marker does not outlive the seat"
# ---------------------------------------------------------------------------
ok "the marker names the seat"     "$A" "$(cur_opt)"
run --undock-pane "$A"; sleep 0.5
ok "undocking clears it"           no \
   "$(if [ "$(cur_opt)" = "$A" ]; then echo yes; else echo no; fi)"
ok "the other chat is still docked" "$C:docked" "$(kinds)"
term_ok 16

# ---------------------------------------------------------------------------
t "17. one sidebar does not take another sidebar's empty seat"
# ---------------------------------------------------------------------------
# "A spare placeholder" was answered globally, and ensure_seat joins whatever it
# names into its own window — so a second list holding an empty seat had it taken
# away and was left with nothing to dock into until its own refresher noticed.
run --undock-window "$DWIN" >/dev/null 2>&1; sleep 0.5
W2=$(tm new-window -d -t tatest-dash: -P -F '#{window_id}' "exec '$TA'" 2>/dev/null)
LIST2=""
i=0
while [ "$i" -lt 60 ]; do
  LIST2=$(tm list-panes -t "$W2" -F '#{pane_id} #{@tagents_list}' 2>/dev/null |
            awk '$2 != "" { print $1; exit }')
  [ -n "$LIST2" ] && break
  i=$((i + 1)); sleep 0.25
done
ok "a second list is running" yes "$(if [ -n "$LIST2" ]; then echo yes; else echo no; fi)"
run --ensure-seat "$LIST2" >/dev/null 2>&1; sleep 0.3
S2=$(run --seats "$LIST2" 2>/dev/null | awk -F'\t' '$2 == "free" { print $1; exit }')
ok "it has a free seat of its own" yes "$(if [ -n "$S2" ]; then echo yes; else echo no; fi)"
tm kill-pane -t "$(free_seat)" 2>/dev/null; sleep 0.3
ok "the first sidebar has none"    "" "$(kinds)"
run --ensure-seat "$LIST" >/dev/null 2>&1; sleep 0.4
ok "it grows one of its own"       1 "$(run --seats "$LIST" | wc -l | tr -d ' ')"
ok "and the other one keeps its seat" "$W2" "$(where "$S2")"
term_ok 17
# The second list took the shared "which sidebar do non-list callers mean"
# marker, as the newest list is meant to; hand it back so nothing after this
# reads the window that is about to be killed.
tm kill-window -t "$W2" 2>/dev/null; sleep 0.3
tm set -p -t "$LIST" @tagents_dash 1 >/dev/null 2>&1
tm set -w -t "$DWIN" @tagents 1 >/dev/null 2>&1

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
