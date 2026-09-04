#!/usr/bin/env bash
#
# tests/names.sh — the tmux window an agent lives in is named after that agent.
#
# Every lettered case of the contract in the header of `tagents` (WINDOW NAMES)
# is a check here: a new agent naming its window, an agent sharing a window with
# shells, two agents deciding between them, an explicit ctrl-r, a window a
# person renamed by hand, a title that changes mid-session, and the whole thing
# working with no dashboard open at all.
#
# NOTHING HERE MAY TOUCH THE DEFAULT TMUX SOCKET. The server is created with
# `tmux -L tatest-$$ -f /dev/null`, torn down in the trap along with its socket
# file, and tagents is pointed at it by exporting $TMUX in the test process —
# never by putting a `tmux` shim on $PATH, which has already once let a test
# relocate a real pane when the shim went missing.
#
# THERE IS NO LIST RUNNING HERE, deliberately: the whole point of the status bar
# path is that it works when the dashboard is closed, and a suite that always
# has one open could not tell the two apart. What the sweep skips — the
# dashboard window, a window a list is in, a docked chat — is said by markers,
# so the markers are set by hand and nothing has to be started for them.
#
# The agents are a copy of /bin/sleep named `claude`, so the process walk in
# live_panes counts them — a #!/bin/sh stub would be an `sh` to ps and never an
# agent. Pane titles are what Claude publishes as it works, and are set here with
# `tmux select-pane -T` — except where the title is the point of the check, which
# goes through settitle() and OSC 2 because select-pane -T expands tmux formats.
#
# bash 3.2, runnable from any cwd, non-zero exit on any failing check.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TA="$HERE/../tagents"

command -v tmux >/dev/null 2>&1 || { echo "names.sh: no tmux"; exit 1; }

S=tatest-$$
SOCK=""
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tagents-names.XXXXXX") || exit 1
ROOT=$(cd "$ROOT" && pwd -P) || exit 1
# The socket FILE goes too. kill-server takes the server down but leaves the
# socket behind, and a directory of dead tatest-<pid> sockets is what every run
# of these suites used to add to.
trap 'tmux -L "$S" kill-server >/dev/null 2>&1
      [ -s "$ROOT/keeper.pid" ] && kill "$(cat "$ROOT/keeper.pid")" 2>/dev/null
      [ -n "$SOCK" ] && rm -f "$SOCK"
      rm -rf "$ROOT"' EXIT INT TERM

pass=0; fail=0
ok()   { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
         else fail=$((fail+1)); printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"; fi; }
t()    { printf '\n%s\n' "$1"; }

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------
BIN="$ROOT/bin";      mkdir -p "$BIN"
STATE="$ROOT/state";  mkdir -p "$STATE"
REPO="$ROOT/repo";    mkdir -p "$REPO/.git"

# macOS ps reports the INTERPRETER, so a script called claude is an `sh` to
# everything that looks — hence a copy of /bin/sleep under that name, re-signed
# because a copy of a system binary is killed on sight on arm64.
cp /bin/sleep "$BIN/claude" || exit 1
codesign --remove-signature "$BIN/claude" >/dev/null 2>&1
codesign -f -s - "$BIN/claude" >/dev/null 2>&1
"$BIN/claude" 0 >/dev/null 2>&1 ||
  { echo "names.sh: cannot build a stub agent (codesign?)"; exit 1; }
printf '#!/bin/sh\nexit 0\n' >"$BIN/tusage"
chmod +x "$BIN/claude" "$BIN/tusage"

# EXPORTED BEFORE THE SERVER EXISTS. A tmux server keeps the environment it was
# started with and hands it to every command it runs.
export PATH="$BIN:$PATH"
export TA_STATE_DIR="$STATE"
export TA_SESSION=tatest-dash
export TA_CONFIG=/nonexistent/config.yaml   # no profiles: no dialog anywhere
unset TMUX TMUX_PANE TA_MODE TA_FLAT TA_COLS TA_NEW_CMD TA_RESUME_CMD TA_HOME
unset TA_HIDE_COLS TA_NAMES_EVERY CLAUDE_CONFIG_DIR

tm() { tmux -L "$S" "$@"; }

tm -f /dev/null new-session -d -s tatest-work -c "$REPO" -x 200 -y 50 || exit 1
tm set -g default-shell /bin/sh >/dev/null 2>&1
tm set -g default-command '' >/dev/null 2>&1
# The dedicated dashboard session, with the window a list would run in marked
# but no list in it: dash_window falls back to that marker, which is what
# name_window checks before it renames anything.
tm new-session -d -s tatest-dash -c "$REPO" >/dev/null 2>&1

SOCK=$(tm display -p '#{socket_path}' 2>/dev/null)
[ -n "$SOCK" ] || { echo "names.sh: no socket for $S"; exit 1; }
TMUXV="$SOCK,0,0"

# A client on a pty. Nothing here needs one — no popup is opened — but a server
# with no client at all is not the shape any of this runs in, and window sizes
# and the active pane behave differently without one.
( { sleep 300 & printf '%s\n' "$!" >"$ROOT/keeper.pid"; wait; } |
    script -q /dev/null tmux -L "$S" attach -t tatest-work >/dev/null 2>&1 & ) >/dev/null 2>&1
sleep 0.5

run() { env TMUX="$TMUXV" bash "$TA" "$@"; }

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
# A TITLE THE WAY A TERMINAL SETS ONE. `select-pane -T` looks like the same
# thing and is not: tmux expands FORMATS in what it is given, so `Deploy
# #Staging` arrives as `Deploy <session name>taging` and a check about a `#` in a
# title would be checking tmux's own expansion rather than anything here. OSC 2
# written to the pane's tty is what Claude does, and it is taken literally.
settitle() {  # <pane> <title>
  local p=${1:-} want=${2:-} tty i=0
  tty=$(tm display -p -t "$p" '#{pane_tty}' 2>/dev/null)
  [ -n "$tty" ] || return 1
  printf '\033]2;%s\033\\' "$want" >"$tty" 2>/dev/null
  while [ "$i" -lt 40 ]; do
    [ "$(tm display -p -t "$p" '#{pane_title}' 2>/dev/null)" = "$want" ] && return 0
    i=$((i + 1)); sleep 0.05
  done
  return 1
}

wof()   { tm display -p -t "${1:-}" '#{window_id}' 2>/dev/null; }
wname() { tm display -p -t "${1:-}" '#{window_name}' 2>/dev/null; }
wauto() { tm display -p -t "${1:-}" '#{automatic-rename}' 2>/dev/null; }
wrec()  { tm show -vw -t "${1:-}" @tagents_name 2>/dev/null; }

# A record with a timestamp of its own, which is what decides who names a window
# two agents share. Written as the hook writes it: ts, state, session id, cwd,
# transcript, detail, account.
mkrec() {  # <pane> <session id> <timestamp>
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$3" working "$2" "$REPO" "" "on it" "" >"$STATE/${1#%}.tsv"
}

# An agent in a window of its own: a live claude, a title of the kind Claude
# publishes, and a state record.
newagent() {  # <session> <title> <sid> [ts] -> pane id
  local sess=$1 title=$2 sid=$3 ts=${4:-} p
  [ -n "$ts" ] || ts=$(date +%s)
  p=$(tm new-window -d -t "$sess:" -P -F '#{pane_id}' -c "$REPO" \
        "exec '$BIN/claude' 600" 2>/dev/null)
  tm select-pane -T "$title" -t "$p" 2>/dev/null
  mkrec "$p" "$sid" "$ts"
  printf '%s' "$p"
}

# ...and a second agent in an existing window.
addagent() {  # <window> <title> <sid> [ts] -> pane id
  local win=$1 title=$2 sid=$3 ts=${4:-} p
  [ -n "$ts" ] || ts=$(date +%s)
  p=$(tm split-window -d -t "$win" -P -F '#{pane_id}' -c "$REPO" \
        "exec '$BIN/claude' 600" 2>/dev/null)
  tm select-pane -T "$title" -t "$p" 2>/dev/null
  mkrec "$p" "$sid" "$ts"
  printf '%s' "$p"
}

NOW=$(date +%s)

# ---------------------------------------------------------------------------
t "0. the ground the rest stands on"
# ---------------------------------------------------------------------------
DP=$(tm list-panes -t tatest-dash -F '#{pane_id}' 2>/dev/null | head -1)
DWIN=$(wof "$DP")
tm set -w -t "$DWIN" @tagents 1 >/dev/null 2>&1
ok "the dashboard window is where the marker says" 1 \
   "$(tm show -vw -t "$DWIN" @tagents 2>/dev/null)"

A=$(newagent tatest-work 'p-aa99-bugs' sid-a "$NOW")
AW=$(wof "$A")
ok "a fresh agent window is tmux's to name" 1 "$(wauto "$AW")"
ok "...and nothing has claimed its name yet" "" "$(wrec "$AW")"
ok "the stub really is a live agent" "$A" \
   "$(run --list 2>/dev/null | awk -F'\t' -v p="$A" '$1 == p { print $1; exit }')"

# ---------------------------------------------------------------------------
t "(a) a new agent names its window"
# ---------------------------------------------------------------------------
run --sync-names >/dev/null 2>&1
ok "the window takes the agent's title"        "p-aa99-bugs" "$(wname "$AW")"
ok "...and tagents records that it named it"   "p-aa99-bugs" "$(wrec "$AW")"
ok "...which turns tmux's own renaming off"    0             "$(wauto "$AW")"
# Idempotent: a second pass has nothing to say and must not thrash the name.
run --sync-names >/dev/null 2>&1
ok "a second pass leaves it exactly there"     "p-aa99-bugs" "$(wname "$AW")"

# The spinner glyph Claude puts in front of the title is not part of the name.
tm select-pane -T '✳ p-aa99-bugs busy' -t "$A"
run --sync-names >/dev/null 2>&1
ok "the leading glyph is stripped, as on the row" "p-aa99-bugs busy" "$(wname "$AW")"
tm select-pane -T 'p-aa99-bugs' -t "$A"
run --sync-names >/dev/null 2>&1

# ---------------------------------------------------------------------------
t "(b) an agent sharing its window with shells"
# ---------------------------------------------------------------------------
# A window that is a shell first and grows an agent beside it — the ordinary
# split. The shell's pane title is the host name, which names nothing, so the
# agent is the only candidate however new the shell is.
SHW=$(tm new-window -d -t tatest-work: -P -F '#{window_id}' -c "$REPO" 2>/dev/null)
B=$(addagent "$SHW" 'p-shared-work' sid-b "$NOW")
ok "the window really has a shell and an agent" 2 \
   "$(tm list-panes -t "$SHW" -F x 2>/dev/null | wc -l | tr -d ' ')"
run --sync-names >/dev/null 2>&1
ok "the agent names the window it shares" "p-shared-work" "$(wname "$SHW")"

# ...and a window with no agent in it at all is not this function's business.
PLAIN=$(tm new-window -d -t tatest-work: -P -F '#{window_id}' -c "$REPO" 2>/dev/null)
PLAINNAME=$(wname "$PLAIN")
run --sync-names >/dev/null 2>&1
ok "a window with no agent is left alone" "$PLAINNAME" "$(wname "$PLAIN")"

# Nor is an agent with nothing to call itself: no label, and a title that is
# tmux's default (the host name). The window keeps whatever tmux calls it.
NN=$(newagent tatest-work "$(hostname -s)" sid-nn "$NOW")
NNW=$(wof "$NN")
NNNAME=$(wname "$NNW")
run --sync-names >/dev/null 2>&1
ok "an agent with no display name renames nothing" "$NNNAME" "$(wname "$NNW")"
ok "...and claims no name either"                  ""        "$(wrec "$NNW")"

# ---------------------------------------------------------------------------
t "(c) two agents in one window: the newer activity wins"
# ---------------------------------------------------------------------------
C1=$(newagent tatest-work 'older-agent' sid-c1 "$((NOW - 600))")
CW=$(wof "$C1")
C2=$(addagent "$CW" 'newer-agent' sid-c2 "$((NOW - 60))")
run --sync-names >/dev/null 2>&1
ok "the newer state record names the window" "newer-agent" "$(wname "$CW")"

# ...and it follows the work: the other one is used, and the window is its.
mkrec "$C1" sid-c1 "$NOW"
run --sync-names >/dev/null 2>&1
ok "working in the other one hands the name over" "older-agent" "$(wname "$CW")"
ok "...and the record follows"                    "older-agent" "$(wrec "$CW")"

# A tie is broken by the pane index, so the answer is at least stable rather
# than whatever order awk happens to walk the panes in.
mkrec "$C2" sid-c2 "$NOW"
run --sync-names >/dev/null 2>&1
ok "the same timestamp twice: the leftmost pane wins" "older-agent" "$(wname "$CW")"

# A pane with no record at all sorts below every pane that has one — it has no
# activity to compare, and treating that as "just now" would let a session that
# has never emitted an event take the window off one that is working.
D1=$(newagent tatest-work 'has-a-record' sid-d1 "$((NOW - 3600))")
DW2=$(wof "$D1")
D2=$(addagent "$DW2" 'no-record-at-all' sid-d2 "$NOW")
rm -f "$STATE/${D2#%}.tsv"
run --sync-names >/dev/null 2>&1
ok "a pane with no state record does not outrank one with" \
   "has-a-record" "$(wname "$DW2")"

# ---------------------------------------------------------------------------
t "(d) ctrl-r renames the window at once, and the sweep agrees"
# ---------------------------------------------------------------------------
E=$(newagent tatest-work 'title-of-e' sid-e "$NOW")
EW=$(wof "$E")
run --label sid-e 'named-by-hand' >/dev/null 2>&1
ok "naming the agent renames its window immediately" "named-by-hand" "$(wname "$EW")"
ok "...and records the name, so the sweep may keep it" "named-by-hand" "$(wrec "$EW")"
run --sync-names >/dev/null 2>&1
ok "...and the sweep does not fight it: a label beats a title" \
   "named-by-hand" "$(wname "$EW")"

# An explicit rename is deliberate, so it renames a SHARED window too — the old
# refusal ("only when the window is the agent's alone") meant ctrl-r on an agent
# with a shell beside it did nothing at all, silently.
F=$(addagent "$EW" 'title-of-f' sid-f "$NOW")
run --label sid-f 'shared-and-named' >/dev/null 2>&1
ok "ctrl-r on an agent sharing a window still renames it" \
   "shared-and-named" "$(wname "$EW")"

# Clearing the name gives the window back to tmux — and to the sweep, which now
# has a title to go on again. f is the newer of the two here, so the name the
# sweep settles on is f's title rather than e's label.
run --label sid-f '' >/dev/null 2>&1
mkrec "$F" sid-f "$((NOW + 60))"
ok "an empty name gives the window back to tmux" 1 "$(wauto "$EW")"
ok "...and drops the claim with it"              "" "$(wrec "$EW")"
run --sync-names >/dev/null 2>&1
ok "...so the sweep names it after the newest agent again" \
   "title-of-f" "$(wname "$EW")"

# ---------------------------------------------------------------------------
t "(e) a name a person typed is never overwritten"
# ---------------------------------------------------------------------------
tm rename-window -t "$AW" 'mine-do-not-touch'
run --sync-names >/dev/null 2>&1
ok "a window renamed by hand is left alone" "mine-do-not-touch" "$(wname "$AW")"
tm select-pane -T 'p-aa99-renamed' -t "$A"
run --sync-names >/dev/null 2>&1
ok "...even after the agent's own title changes" "mine-do-not-touch" "$(wname "$AW")"

# ...until the day its name is one of the two the sweep is allowed to take: the
# name tagents last gave it (still recorded), or tmux's automatic one.
tm rename-window -t "$AW" "$(wrec "$AW")"
run --sync-names >/dev/null 2>&1
ok "a name back to the recorded one is the sweep's again" \
   "p-aa99-renamed" "$(wname "$AW")"

# ---------------------------------------------------------------------------
t "(f) /rename mid-session: the window follows on the next pass"
# ---------------------------------------------------------------------------
tm select-pane -T 'p-aa99-refactor' -t "$A"
ok "the window has not moved on its own" "p-aa99-renamed" "$(wname "$AW")"
run --sync-names >/dev/null 2>&1
ok "the next pass follows the new title"  "p-aa99-refactor" "$(wname "$AW")"

# ---------------------------------------------------------------------------
t "a name is a name, not a tmux format"
# ---------------------------------------------------------------------------
# rename-window EXPANDS what it is given, so `Deploy #Staging` used to name the
# window `Deploy worktaging` — #S being the session name — while @tagents_name
# recorded the name that was asked for. The two then disagreed for ever, which
# reads to the sweep as "somebody named this window": frozen at the garbage
# name, and never renamed again however the title changes.
K=$(newagent tatest-work 'placeholder' sid-k "$NOW")
KW=$(wof "$K")
settitle "$K" 'Deploy #Staging pipeline' || echo "  (settitle failed)"
ok "the title really does carry a #" 'Deploy #Staging pipeline' \
   "$(tm display -p -t "$K" '#{pane_title}')"
run --sync-names >/dev/null 2>&1
ok "a # in the name reaches the window intact" 'Deploy #Staging pipeline' "$(wname "$KW")"
ok "...and what is recorded is what the window really says" \
   "$(wname "$KW")" "$(wrec "$KW")"
run --sync-names >/dev/null 2>&1
ok "...so a second pass has nothing to do" 'Deploy #Staging pipeline' "$(wname "$KW")"
settitle "$K" 'clean-title-now' || echo "  (settitle failed)"
run --sync-names >/dev/null 2>&1
ok "...and the window is not frozen at it" 'clean-title-now' "$(wname "$KW")"

# The same through the explicit path: a label is typed by a person, and a ticket
# number is the likeliest place a # ever comes from.
run --label sid-k 'ticket #Sup-42' >/dev/null 2>&1
ok "ctrl-r with a # in the name lands verbatim too" 'ticket #Sup-42' "$(wname "$KW")"
ok "...and records the name the window has"        'ticket #Sup-42' "$(wrec "$KW")"
run --sync-names >/dev/null 2>&1
ok "...and the sweep leaves it exactly there"      'ticket #Sup-42' "$(wname "$KW")"

# A NAME STARTING WITH A DASH IS A FLAG to rename-window ("unknown flag -w"),
# and the failure was silent while the stamp went on regardless — a window
# recorded as ours under a name it never had, and so frozen at the old one.
DSH=$(newagent tatest-work 'before-the-dash' sid-dsh "$NOW")
DSHW=$(wof "$DSH")
run --sync-names >/dev/null 2>&1
settitle "$DSH" '-wip refactor' || echo "  (settitle failed)"
run --sync-names >/dev/null 2>&1
ok "a name starting with a dash is a name" '-wip refactor' "$(wname "$DSHW")"
settitle "$DSH" 'sane-again' || echo "  (settitle failed)"
run --sync-names >/dev/null 2>&1
ok "...and the next title still gets through" 'sane-again' "$(wname "$DSHW")"

# THE GLYPH IS ONE CHARACTER, not "every byte that is not alphanumeric": macOS
# awk counts bytes, so the old rule read every byte of a Cyrillic word as a
# glyph and ate the first word of the title outright.
CYR=$(newagent tatest-work 'before-cyrillic' sid-cyr "$NOW")
CYRW=$(wof "$CYR")
run --sync-names >/dev/null 2>&1
settitle "$CYR" 'два слова' || echo "  (settitle failed)"
run --sync-names >/dev/null 2>&1
ok "a Cyrillic title keeps its first word" 'два слова' "$(wname "$CYRW")"
settitle "$CYR" '✳ два слова' || echo "  (settitle failed)"
run --sync-names >/dev/null 2>&1
ok "...and the spinner glyph in front of it still comes off" \
   'два слова' "$(wname "$CYRW")"

# ---------------------------------------------------------------------------
t "the plan is checked again before it is applied"
# ---------------------------------------------------------------------------
# THE PLAN IS COMPUTED FROM ONE SNAPSHOT AND APPLIED A MOMENT LATER, and a hand
# rename landing in between was clobbered AND stamped as ours — which hands the
# window over permanently, the one thing "a name you typed is never overwritten"
# promises cannot happen.
#
# The gap is made wide on purpose rather than raced: live_panes walks the
# process tree, so a `ps` that sleeps first is a planning phase long enough to
# rename the window by hand well inside it.
SLOW="$ROOT/slowbin"; mkdir -p "$SLOW"
printf '#!/bin/sh\nsleep 2\nexec /bin/ps "$@"\n' >"$SLOW/ps"
chmod +x "$SLOW/ps"
RC=$(newagent tatest-work 'sweep-target' sid-rc "$NOW")
RCW=$(wof "$RC")
run --sync-names >/dev/null 2>&1
ok "the window is the sweep's to rename" 'sweep-target' "$(wname "$RCW")"
settitle "$RC" 'new-title-now' || echo "  (settitle failed)"
( env TMUX="$TMUXV" PATH="$SLOW:$PATH" bash "$TA" --sync-names >/dev/null 2>&1 & )
sleep 0.5
tm rename-window -t "$RCW" 'MINE-DO-NOT-TOUCH'
sleep 3
ok "a rename inside the sweep is not clobbered" 'MINE-DO-NOT-TOUCH' "$(wname "$RCW")"
ok "...and the sweep does not claim the window either" 'sweep-target' "$(wrec "$RCW")"

# ---------------------------------------------------------------------------
t "what the sweep never touches"
# ---------------------------------------------------------------------------
# The dashboard window: an agent docked in it is a pane the sidebar borrowed,
# and naming that window after it would name the dashboard.
DA=$(tm split-window -d -t "$DWIN" -P -F '#{pane_id}' -c "$REPO" \
       "exec '$BIN/claude' 600" 2>/dev/null)
tm select-pane -T 'docked-chat' -t "$DA"
mkrec "$DA" sid-da "$NOW"
DNAME=$(wname "$DWIN")
run --sync-names >/dev/null 2>&1
ok "the dashboard window keeps its name" "$DNAME" "$(wname "$DWIN")"
# ...and ctrl-r on that agent does not rename the dashboard either.
run --label sid-da 'docked-by-hand' >/dev/null 2>&1
ok "...and an explicit rename does not reach it" "$DNAME" "$(wname "$DWIN")"

# A window a list is running in is a sidebar, whatever session it is in. The pid
# in @tagents_list is what makes the claim live, so this suite lends it its own.
LW=$(newagent tatest-work 'would-be-name' sid-lw "$NOW")
LWIN=$(wof "$LW")
LNAME=$(wname "$LWIN")
tm set -p -t "$LW" @tagents_list "$$" >/dev/null 2>&1
run --sync-names >/dev/null 2>&1
ok "a window with a live list in it is a sidebar, not an agent" \
   "$LNAME" "$(wname "$LWIN")"
tm set -up -t "$LW" @tagents_list >/dev/null 2>&1
run --sync-names >/dev/null 2>&1
ok "...and once that list is gone it is an ordinary window again" \
   "would-be-name" "$(wname "$LWIN")"

# A docked chat is skipped by its MARKER, not by where it happens to sit: it is
# a pane on loan to a sidebar, and the window it is standing in is not its home.
GW=$(newagent tatest-work 'docked-elsewhere' sid-gw "$NOW")
GWIN=$(wof "$GW")
GNAME=$(wname "$GWIN")
tm set -p -t "$GW" @tagents_docked "$DWIN" >/dev/null 2>&1
run --sync-names >/dev/null 2>&1
ok "a docked chat names no window" "$GNAME" "$(wname "$GWIN")"
tm set -up -t "$GW" @tagents_docked >/dev/null 2>&1

# ---------------------------------------------------------------------------
t "(g) with no dashboard at all, the status bar does it"
# ---------------------------------------------------------------------------
# Nothing in this suite has ever started a list or a refresher, so --counts is
# the only thing that can have named anything below. It sweeps in the
# background, so the check waits for the rename rather than for the process.
awaitname() {  # <window> <expected> -> the name, once it settles
  local i=0
  while [ "$i" -lt 40 ]; do
    [ "$(wname "$1")" = "$2" ] && break
    i=$((i + 1)); sleep 0.25
  done
  wname "$1"
}
H=$(newagent tatest-work 'p-status-bar' sid-h "$NOW")
HW=$(wof "$H")
rm -f "$STATE/.names.ts"
run --counts >/dev/null 2>&1
rc=$?
ok "--counts exits on its own account, whatever the sweep is doing" 0 "$rc"
ok "the status bar names the window with no list anywhere" \
   "p-status-bar" "$(awaitname "$HW" 'p-status-bar')"

# THROTTLED, because the status bar runs on every interval on every client and
# a pass over every pane of every window is not free. Within the window the
# stamp file names, a second call does nothing at all.
tm select-pane -T 'p-status-bar-two' -t "$H"
run --counts >/dev/null 2>&1
sleep 1.5
ok "a second call inside 30s does not sweep again" "p-status-bar" "$(wname "$HW")"
# ...and once the stamp is old enough it does.
printf '%s\n' "$(( $(date +%s) - 31 ))" >"$STATE/.names.ts"
run --counts >/dev/null 2>&1
ok "...and does once the stamp is old enough" \
   "p-status-bar-two" "$(awaitname "$HW" 'p-status-bar-two')"

# The interval is a variable so this can be asked without waiting 30 seconds for
# the answer, and the answer is the same one.
tm select-pane -T 'p-status-bar-three' -t "$H"
env TMUX="$TMUXV" TA_NAMES_EVERY=0 bash "$TA" --counts >/dev/null 2>&1
ok "TA_NAMES_EVERY shortens the throttle" \
   "p-status-bar-three" "$(awaitname "$HW" 'p-status-bar-three')"

# And the status bar itself is unharmed by any of it: the counts are still the
# only thing on stdout.
COUNTS=$(run --counts 2>/dev/null)
case "$COUNTS" in
  *"●"*) pass=$((pass+1)); printf '  ok   %s\n' "--counts still counts the live agents" ;;
  *) fail=$((fail+1)); printf '  FAIL %s\n       actual: [%s]\n' "--counts still counts the live agents" "$COUNTS" ;;
esac

# ---------------------------------------------------------------------------
t "the rename dialog opens on the name that is there"
# ---------------------------------------------------------------------------
# A fake fzf that writes its argv down and answers with the --query it was
# handed, so what the dialog was seeded with can be read back afterwards, and
# exits 130 on demand for the esc case.
FZFBIN="$ROOT/fzfbin"; mkdir -p "$FZFBIN"
cat >"$FZFBIN/fzf" <<'FZFEOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done >"$FZFDUMP"
q=""
while [ $# -gt 0 ]; do
  [ "$1" = --query ] && q=$2
  shift
done
[ -n "${FZFRC:-}" ] && exit "$FZFRC"
printf '%s\n' "$q"
FZFEOF
chmod +x "$FZFBIN/fzf"

qof() { awk '$0 == "--query" { getline; print; exit }' "${1:-}" 2>/dev/null; }
askrename() {  # <dump> <sid> [env assignments] -> the dialog's argv in <dump>
  local dump=$1 sid=$2 envs=${3:-} i=0
  rm -f "$dump"
  # In a window of the throwaway server, which is where a real pty is: the
  # dialog only opens where fzf has a terminal to draw on. TA_MODE=popup keeps
  # the prompt inline — a popup cannot open a popup, and this is the shape
  # prefix+a runs in anyway.
  tm new-window -d -t tatest-work: \
    "PATH='$FZFBIN':\$PATH FZFDUMP='$dump' TA_MODE=popup $envs exec bash '$TA' --act rename '$RP' live '$sid'" \
    >/dev/null 2>&1
  while [ "$i" -lt 40 ]; do
    [ -f "$dump" ] && { sleep 0.5; return 0; }
    i=$((i + 1)); sleep 0.25
  done
  return 1
}

RP=$(newagent tatest-work 'renamed agent' sid-pre)
printf 'sid-pre\tcurrent name\n' >>"$STATE/labels.tsv"
askrename "$ROOT/pre.args" sid-pre
ok "the dialog is seeded with the current label" "current name" "$(qof "$ROOT/pre.args")"

printf 'sid-esc\tkeep me\n' >>"$STATE/labels.tsv"
askrename "$ROOT/esc.args" sid-esc FZFRC=130
ok "esc keeps the label it opened with" "keep me" \
   "$(awk -F'\t' '$1 == "sid-esc" { print $2; exit }' "$STATE/labels.tsv" 2>/dev/null)"

# No label yet: the name on screen is the next best thing to start from, and an
# empty box would be a rename that begins by throwing the name away.
askrename "$ROOT/none.args" sid-nolabel
case "$(qof "$ROOT/none.args")" in
  "") fail=$((fail+1)); printf '  FAIL %s\n' "an unlabelled agent is seeded with its displayed name" ;;
  *)  pass=$((pass+1)); printf '  ok   %s\n' "an unlabelled agent is seeded with its displayed name" ;;
esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
