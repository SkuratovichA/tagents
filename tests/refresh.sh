#!/usr/bin/env bash
#
# tests/refresh.sh — what the refresher loop posts to the picker, and when.
#
# The refresher sleeps on the tmux channel tagents-ev and is woken by a signal
# (a hook, tmux itself, tagents writing something the list draws); it used to tick
# every two seconds. What is asserted here is the shape of a quiet minute and of a
# busy one: a reload on the first pass, on a wake where something the picker draws
# changed, on the slow pass (every wake with TA_REFRESH_SLOW=0, none with a large
# one) and at the idle timeout; nothing posted, and no program but the snapshot,
# on a wake where nothing moved; a reload that was refused made again; five
# refused posts ending the loop; a list that is gone ending it without a poll.
#
# THE TEST DRIVES THE WAKES ITSELF. A "tick" here is a pass: tick 1 is the first
# one, which the loop makes unasked, and every later one is a `tmux wait-for -S
# tagents-ev` the test sends after filing what changed (`act`). The shims write the
# tick into their logs, from a file the test keeps. Each step is given 1.7 s, which
# is the loop's one-second delay after a wake and the second look a second later.
#
# THE REAL LOOP RUNS, with its network replaced by shims first on the refresher's
# PATH only. The curl shim logs the body it was asked to post, and fails on the
# ticks a scenario names. The tmux shim logs the verb and then execs the real
# tmux, found by absolute path before the shim went on the PATH, against a server
# of this test's own.
#
# EVERY RING IS COUNTED (EV_BUMP, core.sh) and the loop waits by that count: sections
# 20 to 24 are the checks that came out of the architecture review: fresh counts on
# the bar after the last change, a busy period that posts and starts programs per
# pass and not per ring, two rings in the gap between waits, the focus events and the
# slow pass that restores a wiped hook, and a refresher that ends with its fzf. The
# tmux shim can hold a `wait-for` or `if-shell` back (the file `gap`), which is the
# gap between two waits made as long as a test needs it.
#
# NOTHING HERE MAY TOUCH THE DEFAULT TMUX SOCKET: the server is
# `tmux -L tatest-refresh-$$ -f /dev/null` and $TMUX names it.
#
# bash 3.2, runnable from any cwd, non-zero exit on any failing check.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# A suite that is not run against a scratch default server aborts here, before it can reach the live one (tests/scratch-guard.sh).
. "$HERE/scratch-guard.sh" && scratch_guard refresh.sh || exit 1
TA="$HERE/../tagents"

command -v tmux >/dev/null 2>&1 || { echo "refresh.sh: no tmux"; exit 1; }
command -v fzf  >/dev/null 2>&1 || { echo "refresh.sh: no fzf"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "refresh.sh: no curl"; exit 1; }
REALTMUX=$(command -v tmux)

S=tatest-refresh-$$
SOCK=""
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tagents-refresh.XXXXXX") || exit 1
ROOT=$(cd "$ROOT" && pwd -P) || exit 1
trap 'tmux -L "$S" kill-server >/dev/null 2>&1
      [ -n "$SOCK" ] && rm -f "$SOCK"
      rm -rf "$ROOT"' EXIT INT TERM

pass=0; fail=0
ok()   { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
         else fail=$((fail+1)); printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"; fi; }
has()  { case "$3" in *"$2"*) pass=$((pass+1)); printf '  ok   %s\n' "$1" ;;
         *) fail=$((fail+1)); printf '  FAIL %s\n       expected to contain: %s\n       actual: %s\n' "$1" "$2" "$3" ;; esac; }
t()    { printf '\n%s\n' "$1"; }

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------
BIN="$ROOT/bin";     mkdir -p "$BIN"
STATE="$ROOT/state"
TREE="$ROOT/tree";   mkdir -p "$TREE"
RFCFG="$ROOT/config.yaml"
PORT=4242

# The refresher is started as $TREE/tagents so that ${SELF%/*}/tnotes is a stub of
# ours and not the real editor manager; the symlink is followed for the modules.
ln -s "$TA" "$TREE/tagents"
cat >"$TREE/tnotes" <<'EOF'
#!/bin/sh
# No tick number: the sync is started in the background and reads the clock late.
echo "$*" >>"$RF_DIR/tnotes.log"
EOF

cat >"$BIN/curl" <<'EOF'
#!/bin/sh
n=0; read -r n <"$RF_DIR/tick"
body=
while [ $# -gt 0 ]; do case $1 in -d) shift; body=$1 ;; esac; shift; done
echo "$n $body" >>"$RF_DIR/curl.log"
# A list that answers: its tally is written a moment after the reload, from the
# state files it was drawn from (the file `tally` is the script that does that).
case $body in reload-sync*) [ -f "$RF_DIR/tally" ] && ( sleep 0.4; sh "$RF_DIR/tally" ) >/dev/null 2>&1 & ;; esac
if [ -f "$RF_DIR/curlfail" ]; then
  read -r mode rest <"$RF_DIR/curlfail"
  case $mode in
    from)  [ "$n" -ge "$rest" ] && exit 1 ;;
    ticks) case " $rest " in *" $n "*) exit 1 ;; esac ;;
    times) if [ "$rest" -gt 0 ]; then echo "times $((rest - 1))" >"$RF_DIR/curlfail"; exit 1; fi ;;
  esac
fi
exit 0
EOF
cat >"$BIN/tmux" <<EOF
#!/bin/sh
n=0; read -r n <"\$RF_DIR/tick"
echo "\$n \$1" >>"\$RF_DIR/tmux.log"
# The waits the loop asks of tmux (ev_wait's if-shell), counted for settle.
case "\$*" in *"wait-for tagents-ev"*) [ "\$1" = if-shell ] && echo "\$n" >>"\$RF_DIR/ev.waits" ;; esac
# THE GAP: a wait (the old helper's wait-for, the new waiter's if-shell) that is held
# back for as long as the file says, which is how long nothing is waiting on the channel.
if [ -f "\$RF_DIR/gap" ]; then
  case "\$1" in
    if-shell) read -r g <"\$RF_DIR/gap"; sleep "\$g" ;;
    wait-for) [ "\$2" = -S ] || { read -r g <"\$RF_DIR/gap"; sleep "\$g"; } ;;
  esac
fi
exec "$REALTMUX" "\$@"
EOF
cat >"$BIN/tusage" <<'EOF'
#!/bin/sh
n=0; read -r n <"$RF_DIR/tick"
echo "$n $*" >>"$RF_DIR/tusage.log"
# Opt-in: a slow month fetch, for the pin that a slow pass still lands on its tick.
case "$*" in *--daily*) [ -n "${RF_SLOW_DAILY-}" ] && /bin/sleep "$RF_SLOW_DAILY" ;; esac
# What the stamp said when the update began, and the burn a scenario files.
case "$*" in
  --update*) cat "$RF_STATE/.counts.ts" >"$RF_DIR/ts.update.$n" 2>/dev/null
             # What the update was handed in the environment: usage_env's exports.
             printf '%s' "${TU_ACCOUNT_RULES-}" >"$RF_DIR/rules.update.$n"
             printf '%s' "${TU_ACCOUNTS-}" >"$RF_DIR/accts.update.$n" ;;
  *--burn*)  cat "$RF_DIR/burn" 2>/dev/null ;;
esac
exit 0
EOF
chmod +x "$BIN"/* "$TREE/tnotes"

unset TMUX TMUX_PANE TA_MODE TA_FLAT TA_COLS TA_NEW_CMD TA_RESUME_CMD TA_HOME TA_HOST
unset CLAUDE_CONFIG_DIR TU_ACCOUNTS TU_ACCOUNT_RULES
export HOME="$ROOT/home"; mkdir -p "$HOME"

tm() { tmux -L "$S" "$@"; }

# The strings of a ring, as core.sh has them: read from the file, so that the test
# cannot hold a copy that drifts. EVB is the format that bumps the count.
EVB=$(sed -n "s/^EV_BUMP='\(.*\)'\$/\1/p" "$HERE/../lib/tagents/core.sh")
[ -n "$EVB" ] || { echo "refresh.sh: no EV_BUMP in core.sh"; exit 1; }
# ...and as show-hooks prints it, which is tmux's own spelling of the same commands.
EVSHOW="set-option -Fg @tagents_evgen \"$EVB\" ; wait-for -S tagents-ev"
# How many hooks, of the given event or of all, carry the ring at [42]: the hooks of
# a pane or a window are in the window scope, the rest in the session's.
hooks42() {  # [event]
  { tm show-hooks -g; tm show-hooks -gw; } 2>/dev/null |
    awk -v ev="${1:-}" -v txt="[42] $EVSHOW" 'ev == "" ? index($0, txt) : $0 == ev txt' | wc -l | tr -d ' '
}
# One ring the way every ringer makes it: the count first, then the signal.
ring() { tm set -gF @tagents_evgen "$EVB" \; wait-for -S tagents-ev; }
# The modules tagents loads, read from its own loop, so that a function the refresher runs can be run here the way it runs it.
LISTED_MODS=$(awk '/^[[:space:]]*for ta_mod in/ { grab = 1 } grab { l = $0; sub(/^[[:space:]]*for ta_mod in[[:space:]]*/, "", l); fin = (l ~ /;[[:space:]]*do[[:space:]]*$/); sub(/;[[:space:]]*do[[:space:]]*$/, "", l); sub(/\\[[:space:]]*$/, "", l); printf "%s ", l; if (fin) exit }' "$TA")
modsh() {  # <code> — runs it in a shell with every module sourced, against this suite's server
  env TMUX="$SOCK,0,0" TMUX_PANE="$DP" TA_STATE_DIR="$STATE" TA_CONFIG="$RFCFG" TA_SESSION=tatest-dash SELF="$TREE/tagents" \
      /bin/bash -c 'for m in '"$LISTED_MODS"'; do . "'"$HERE"'/../lib/tagents/$m.sh"; done; '"$1" >/dev/null 2>&1
}

# The dashboard window the loop looks after: the list pane, which says a live
# list (this very process) is running in it.
tm -f /dev/null new-session -d -s tatest-dash -x 200 -y 50 'sleep 600' || exit 1
tm set -g default-shell /bin/sh >/dev/null 2>&1
SOCK=$(tm display -p '#{socket_path}' 2>/dev/null)
[ -n "$SOCK" ] || { echo "refresh.sh: no socket for $S"; exit 1; }
DP=$(tm display -p -t tatest-dash: '#{pane_id}')
tm set -p -t "$DP" @tagents_list "$$"
tm set -p -t "$DP" @tagents_dash 1
# A server that has been through the upgrade already: the one pass that sends docked chats home and asks tnotes for the editors an older version parked runs at most once per server, and the scenarios below count what tnotes is asked.
tm set -g @tagents_migrated 1

# The state directory, every file and directory in it dated long ago: a file the
# loop sees as changed is then one a scenario wrote, never one the fixture did.
mkstate() {
  rm -rf "$STATE"; mkdir -p "$STATE/sub" "$STATE/model" "$STATE/prompt"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 100 working sid-a "$ROOT" "" "agent a" "" >"$STATE/9.tsv"
  printf 'x\n' >"$STATE/sub/9.a"
  printf 'sid-a\tm\t\tOpus\n' >"$STATE/model/sid-a.tsv"
  printf '100\n' >"$STATE/prompt/9"
  printf '%s\t%s\n' sid-a "$ROOT" >"$STATE/origin.tsv"
  printf '9\tname\n' >"$STATE/labels.tsv"
  touch -t 200001010000 "$STATE" "$STATE"/* "$STATE"/*/*
}

# A RING WITH NOBODY WAITING LEAVES THE CHANNEL'S WOKEN FLAG SET (the last scenario's
# own ring on its way out, for one), and the next wait then returns at once: a pass
# nobody asked for, which a scenario that counts slow passes sees as one on tick 1.
# A real waiter takes the flag, so one is started and ended after 0.3 s.
drain_ev() { ( tm wait-for tagents-ev & w=$!; /bin/sleep 0.3; kill "$w" 2>/dev/null; wait "$w" 2>/dev/null ) >/dev/null 2>&1; }

# One scenario: a directory of its own for the logs and the actions, the tmux
# options put back, the claim already ours (a list that has been up for a while).
newrun() {
  D="$ROOT/run.$1"; rm -rf "$D"; mkdir -p "$D"
  echo 0 >"$D/tick"; : >"$D/curl.log"; : >"$D/tmux.log"; : >"$D/tusage.log"; : >"$D/tnotes.log"
  mkstate
  drain_ev
  rm -f "$RFCFG"
  tm set -gu @ta_notes_any >/dev/null 2>&1
  tm set -p -t "$DP" @tagents_port "$PORT"
  tm set -gu @tagents_counts >/dev/null 2>&1
  SLOW=3600; IDLE=600; TAIL=0.5; MINP=1
  sleep 600 & LISTPID=$!
}
act() {  # <tick> <commands> — what happens just before that tick
  printf '%s\n' "$2" >"$D/at.$1"
}
# The list this refresher watches: a process of its own, ended by a scenario that
# wants to see the loop notice. TA_LIST_PID is what list() hands the real one.
SLOW=3600; IDLE=600; LISTPID=$$
# THE POSTS' INTERVAL (TA_REFRESH_MIN) is one second here: the scenarios wake the loop
# every 1.7 s and expect a reload on each wake that has something to draw. The
# throttle has a section of its own.
MINP=1
# What a scenario files before a tick (`act`) runs with the variables the actions
# are written against, which are the refresher's too.
rf_env() {
  env RF_DIR="$D" RF_TMUX="$REALTMUX" RF_S="$S" RF_STATE="$STATE" RF_CFG="$RFCFG" RF_DP="$DP" RF_SLOW_DAILY="${RF_SLOW_DAILY-}" "$@"
}
evwaits() { if [ -f "$D/ev.waits" ]; then wc -l <"$D/ev.waits" | tr -d ' '; else echo 0; fi; }
start_ref() {
  [ -f "$D/at.1" ] && rf_env sh "$D/at.1"
  echo 1 >"$D/tick"
  EVMARK=$(evwaits)
  env RF_DIR="$D" RF_TMUX="$REALTMUX" RF_S="$S" RF_STATE="$STATE" RF_CFG="$RFCFG" RF_DP="$DP" RF_SLOW_DAILY="${RF_SLOW_DAILY-}" \
      PATH="$BIN:$PATH" TMUX="$SOCK,0,0" TMUX_PANE="$DP" TA_PORT="$PORT" TA_LIST_PID="$LISTPID" \
      TA_REFRESH_SLOW="$SLOW" TA_REFRESH_IDLE="$IDLE" TA_REFRESH_MIN="$MINP" \
      TA_STATE_DIR="$STATE" TA_CONFIG="$RFCFG" TA_SESSION=tatest-dash \
      bash "$TREE/tagents" --refresher >"$D/out" 2>&1 &
  RPID=$!
  local i=0
  while ! grep -q reload-sync "$D/curl.log" && kill -0 "$RPID" 2>/dev/null && [ "$i" -lt 80 ]; do
    /bin/sleep 0.1; i=$((i + 1))
  done
  /bin/sleep 1.7   # the delay after the pass, and the second look
}
# THE LOOP IS BACK IN ITS WAIT before the next ring is sent. A wake is a pass, a nap of
# one second and a second look, and under load that takes longer than the 1.7 s a tick
# is given: the next ring then lands with nobody waiting, the pass in progress takes it
# in with its snapshot (a ring is a count, see EV_BUMP), a third ring cancels the woken
# flag of the second (two signals with no waiter between them), and the slow work of
# the tick before is logged against the tick after. The 1.7 s are kept: this waits for
# the loop's own next wait only when it is not there yet, which is never the case on a
# machine that is keeping up (the wait comes about 1.3 s after a ring). The little
# extra is for the wait that has been asked of tmux and not yet taken by the server.
idle_ref() {
  local t=0 late=""
  while [ "$(evwaits)" -le "$EVMARK" ] && kill -0 "$RPID" 2>/dev/null && [ "$t" -lt 200 ]; do
    late=1; /bin/sleep 0.1; t=$((t + 1))
  done
  [ -z "$late" ] || /bin/sleep 0.2
}
wake() {  # one ring, after the change filed for it
  local n=$1
  idle_ref
  [ -f "$D/at.$n" ] && rf_env sh "$D/at.$n"
  echo "$n" >"$D/tick"
  EVMARK=$(evwaits)
  tm set -gF @tagents_evgen "$EVB" \; wait-for -S tagents-ev
  /bin/sleep 1.7
}
# Waits until the loop has finished the last tick: it has gone round to wait again
# since the last ring (a) and nothing it writes has changed for 1.3 s (b), which is
# longer than its 1 s nap and the second look after a post. One ceiling of 20 s.
settle() {
  local t=0 quiet=0 sum last=
  while [ "$t" -lt 200 ] && kill -0 "$RPID" 2>/dev/null; do
    sum=$(cat "$D"/*.log "$STATE/.counts.out" 2>/dev/null | cksum)
    if [ "$sum" = "$last" ]; then quiet=$((quiet + 1)); else quiet=0; fi
    last=$sum
    [ "$(evwaits)" -gt "$EVMARK" ] && [ "$quiet" -ge 13 ] && return 0
    /bin/sleep 0.1; t=$((t + 1))
  done
  return 0
}
stop_ref() {  # a loop that ends by itself is waited for (up to $1 tenths of a second); one that does not is ended the way a closing list ends it: the list process gone, the channel rung
  local i=0
  while kill -0 "$RPID" 2>/dev/null && [ "$i" -lt "${1:-0}" ]; do /bin/sleep 0.1; i=$((i + 1)); done
  if kill -0 "$RPID" 2>/dev/null; then
    # What the loop does on its way out is not a tick's work: it is logged as "end".
    echo end >"$D/tick"
    kill "$LISTPID" 2>/dev/null; tm wait-for -S tagents-ev
    i=0; while kill -0 "$RPID" 2>/dev/null && [ "$i" -lt 60 ]; do /bin/sleep 0.1; i=$((i + 1)); done
  fi
  if kill -0 "$RPID" 2>/dev/null; then kill -9 "$RPID" 2>/dev/null; echo "  (the loop did not stop: killed)"; fi
  wait "$RPID" 2>/dev/null
  /bin/sleep 0.3   # the notes sync is started in the background
}
go() {  # <ticks> — tick 1 is the first pass, each further tick one ring
  local n=2
  start_ref
  while [ "$n" -le "$1" ] && kill -0 "$RPID" 2>/dev/null; do wake "$n"; n=$((n + 1)); done
  /bin/sleep "${TAIL:-0.5}"
  # The time the last tick was given, taken BEFORE settle: settle waits as long as the
  # load needs, and a check of the age of a stamp the last slow pass renewed (section 9)
  # is made against this and not against a clock that settle has moved on.
  GO_S=$(date +%s)
  settle
  stop_ref 0
}

# What the loop posted, as the list of ticks.
reloads() { awk '$2 ~ /^reload-sync/ { printf "%s%s", s, $1; s = " " } END { print "" }' "$D/curl.log"; }
# How many times the loop asked tmux anything on each of the given ticks (the
# waiter's own if-shell is the channel, not a question).
tmuxn() {
  local k out=""
  for k in "$@"; do
    out="$out${out:+ }$k:$(awk -v k="$k" '$1 == k && $2 != "wait-for" && $2 != "if-shell"' "$D/tmux.log" | wc -l | tr -d ' ')"
  done
  printf '%s' "$out"
}
lasttick() { cat "$D/tick" 2>/dev/null; }
markers() { ls -A "$STATE" 2>/dev/null | grep -c '^\.refresher\.'; }
updates() { awk '$2 == "--update" { printf "%s%s", s, $1; s = " " } END { print "" }' "$D/tusage.log"; }
now_s() { date +%s; }
num() {  # <file> — the epoch in it, or 0 for a file that is missing or empty
  local v=""; read -r v <"$1" 2>/dev/null
  case ${v:-x} in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}

# ---------------------------------------------------------------------------
t "1. a quiet minute: a reload on the first pass, and nothing at all after it"
# ---------------------------------------------------------------------------
newrun quiet
go 5
ok "one reload, the first pass's: four rings with nothing changed post nothing" "1" "$(reloads)"
ok "a wake where nothing moved asks tmux once (the snapshot)" "2:1 3:1 4:1 5:1" "$(tmuxn 2 3 4 5)"
ok "no notes editors, no notes sync"                   "" "$(cat "$D/tnotes.log")"
ok "no markers are left when the loop ends"            0  "$(markers)"
ok "the hooks of install_event_hooks are in the server, at [42], with the count first" 18 \
   "$(hooks42)"
ok "...and one waiter per wait: the loop started as many as it was woken, plus the first" "5" \
   "$(awk '$2 == "if-shell"' "$D/tmux.log" | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
t "2. what the picker draws changes on disk: a reload on the wake that follows"
# ---------------------------------------------------------------------------
newrun disk
printf 'x: 1\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
act 2  'printf "%s\t%s\t%s\n" 100 working sid-n >"$RF_STATE/7.tsv"'
act 4  'echo x >"$RF_STATE/sub/7.b"'
act 6  'printf "sid-a\tm\t\tSonnet\n" >"$RF_STATE/model/sid-a.tsv"'
act 8  'rm -f "$RF_STATE/prompt/9"'
act 10 'echo "x: 2" >"$RF_CFG"'
go 11
ok "a new state file (2), a new sub file (4), a rewritten model file (6), a removed prompt file (8) and the config (10) each reload once, and the wakes between stay quiet" \
   "1 2 4 6 8 10" "$(reloads)"

t "2b. a deleted state file reloads the list on the wake that follows"
newrun gone
act 2 'rm -f "$RF_STATE/9.tsv"'
go 3
ok "the state file removed (2) reloads once, and 3 is quiet" "1 2" "$(reloads)"

# ---------------------------------------------------------------------------
t "3. tmux changes: a reload, and the port claim looked at again"
# ---------------------------------------------------------------------------
newrun tmux
act 2 '"$RF_TMUX" -L "$RF_S" set -p -t "$RF_DP" @tagents_joined tatest-home'
act 4 '"$RF_TMUX" -L "$RF_S" set -up -t "$RF_DP" @tagents_port'
act 5 '"$RF_TMUX" -L "$RF_S" show -pv -t "$RF_DP" @tagents_port >"$RF_DIR/port.5"'
go 6
has "a field the snapshot covers (2) and the claim taken away (4) each reload" "1 2 4" "$(reloads)"
ok "the wake after the second look is quiet again, one tmux call" "3:1 5:1 6:1" "$(tmuxn 3 5 6)"
ok "the claim taken away is made again within the wake" "$PORT" "$(cat "$D/port.5" 2>/dev/null)"
# What the snapshot does not cover moves nothing: a title is not in it.
newrun title
act 2 '"$RF_TMUX" -L "$RF_S" select-pane -T "some title" -t "$RF_DP"'
go 4
ok "a pane title changes nothing the snapshot covers" "1" "$(reloads)"

# ---------------------------------------------------------------------------
t "4. five refused posts in a row end the loop, and nothing else does"
# ---------------------------------------------------------------------------
newrun refused
act 2 'printf "%s\t%s\t%s\n" 100 working sid-n >"$RF_STATE/7.tsv"; echo "from 2" >"$RF_DIR/curlfail"'
start_ref; wake 2
stop_ref 150
ok "the loop gave up on its own, after the fifth refused post (the retries are 2 s apart)" 5 "$(awk '$1 >= 2' "$D/curl.log" | wc -l | tr -d ' ')"
ok "the claim is given up with it" "" "$(tm show -pv -t "$DP" @tagents_port 2>/dev/null)"
ok "no markers are left" 0 "$(markers)"

# ---------------------------------------------------------------------------
t "5. a reload that was refused is made again, without another ring"
# ---------------------------------------------------------------------------
newrun retry
act 3 'printf "%s\t%s\t%s\n" 100 working sid-n >"$RF_STATE/7.tsv"; echo "times 1" >"$RF_DIR/curlfail"'
TAIL=2.5 go 3
ok "the reload of wake 3 failed, and the retry does it again 2 s on with nothing else changed" "1 3 3" "$(reloads)"

# ---------------------------------------------------------------------------
t "6. a config changed under a running refresher is read again on the slow pass"
# ---------------------------------------------------------------------------
newrun cfgon
SLOW=0
printf 'x: 1\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
act 2 'printf "usage:\n  watch: me\n" >"$RF_CFG"'
go 4
ok "usage turned on while it ran: tusage --update on each slow wake from the next" "2 3 4" "$(updates)"
ok "the first pass is not a slow one" "" "$(awk '$1 == 1 && $2 == "--update"' "$D/tusage.log")"

newrun cfgoff
SLOW=0
printf 'usage:\n  watch: me\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
act 2 'printf "x: 1\n" >"$RF_CFG"'
go 4
ok "usage turned off while it ran: no tusage --update after it" "" "$(updates)"

newrun slowoff
printf 'usage:\n  watch: me\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
go 4
ok "with the slow pass out of reach, rings never run tusage --update" "" "$(updates)"

# ---------------------------------------------------------------------------
t "7. the notes editors are looked after only while there are some, on the slow pass"
# ---------------------------------------------------------------------------
# Some: a pane that names its chat (@ta_notes_for), or the ta-notes session an older tnotes parked editors in. Made before the scenario starts, so that the events of making them are drained with the rest.
ED=$(tm split-window -d -P -F '#{pane_id}' -t "$DP" 'sleep 600')
tm set -p -t "$ED" @ta_notes_for %1
/bin/sleep 0.3
newrun notes
SLOW=0
go 3
# The refresher starts tnotes with `&`, so the last sync can write its line after
# the loop has ended (one TERM-less run read an empty log): wait for two lines.
i=0; while [ "$(grep -c . "$D/tnotes.log" 2>/dev/null)" -lt 2 ] && [ "$i" -lt 30 ]; do /bin/sleep 0.1; i=$((i + 1)); done
ok "with an editor pane about, tnotes sync is started on each of the two slow wakes" "sync sync" \
   "$(tr '\n' ' ' <"$D/tnotes.log" | sed 's/ $//')"
tm kill-pane -t "$ED" 2>/dev/null
tm new-session -d -s ta-notes 'sleep 600'
/bin/sleep 0.3
newrun notes_parked
SLOW=0
go 3
i=0; while [ "$(grep -c . "$D/tnotes.log" 2>/dev/null)" -lt 2 ] && [ "$i" -lt 30 ]; do /bin/sleep 0.1; i=$((i + 1)); done
ok "with the ta-notes session of an older version about, so is it" "sync sync" \
   "$(tr '\n' ' ' <"$D/tnotes.log" | sed 's/ $//')"
tm kill-session -t '=ta-notes' 2>/dev/null

# ---------------------------------------------------------------------------
t "8. the idle timeout is a slow pass of its own, and a dead list ends the loop"
# ---------------------------------------------------------------------------
newrun idle
IDLE=2
printf 'usage:\n  watch: me\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
TAIL=9 go 1
ok "no ring, and the loop still reloads and updates: at least twice after the first pass" 1 \
   "$([ "$(awk '$1 == 1 && /reload-sync/' "$D/curl.log" | wc -l | tr -d ' ')" -ge 3 ] && echo 1 || echo 0)"
ok "...with tusage --update on the idle passes" 1 "$([ "$(grep -c -- '--update' "$D/tusage.log")" -ge 2 ] && echo 1 || echo 0)"

newrun dead
start_ref
kill "$LISTPID" 2>/dev/null; wait "$LISTPID" 2>/dev/null
tm wait-for -S tagents-ev
i=0; while kill -0 "$RPID" 2>/dev/null && [ "$i" -lt 40 ]; do /bin/sleep 0.1; i=$((i + 1)); done
ok "the list process gone and the channel rung: the loop ends within 4 s, by itself" gone "$(kill -0 "$RPID" 2>/dev/null && echo alive || echo gone)"
stop_ref 0
ok "...and its markers are gone" 0 "$(markers)"

# ---------------------------------------------------------------------------
t "9. the refresher keeps the status bar's cache and the tmux option from the tally the list wrote"
# ---------------------------------------------------------------------------
TALLY1='#[fg=yellow]⚠1 #[fg=green]●2 #[default]'
TALLY2='#[fg=cyan]✓4 #[default]'
EXP1="#[fg=magenta]cfg!1 $TALLY1"
EXP2="#[fg=magenta]cfg!1 $TALLY2"
newrun counts
SLOW=0
printf 'usage:\n  monthly_limit_usd: abc\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
# A tally the list "wrote during the first reload" is written here before the refresher
# starts, and one older than the refresher is never served (refresher_counts), so a
# second boundary between the two would fail the check: it is dated well ahead.
TALLYNEW='touch -t 203001010000 "$RF_STATE/.counts.tally"'
act 1 "printf '%s' '$TALLY1' >\"\$RF_STATE/.counts.tally\"; $TALLYNEW"
act 2 'cat "$RF_STATE/.counts.out" >"$RF_DIR/out.2"; ls -i "$RF_STATE/.counts.out" >"$RF_DIR/ino.2"; cat "$RF_STATE/.counts.ts" >"$RF_DIR/ts.2"; "$RF_TMUX" -L "$RF_S" show -gv @tagents_counts >"$RF_DIR/opt.2"'
act 3 'ls -i "$RF_STATE/.counts.out" >"$RF_DIR/ino.3"; cat "$RF_STATE/.counts.ts" >"$RF_DIR/ts.3"; [ -e "$RF_STATE/.resurrect.ts" ] && echo yes >"$RF_DIR/res.3"'
act 4 "printf '%s' '$TALLY2' >\"\$RF_STATE/.counts.tally\""
act 5 'cat "$RF_STATE/.counts.out" >"$RF_DIR/out.5"; ls -i "$RF_STATE/.counts.out" >"$RF_DIR/ino.5"; "$RF_TMUX" -L "$RF_S" show -gv @tagents_counts >"$RF_DIR/opt.5"'
tm set -gu @tagents_counts
go 5
END_S=$GO_S
ok "after the first answered pass .counts.out is the config marker and the tally" "$EXP1" "$(cat "$D/out.2" 2>/dev/null)"
ok "...and the tmux option holds exactly that text" "$EXP1" "$(cat "$D/opt.2" 2>/dev/null)"
ts_end=$(num "$STATE/.counts.ts")
ok ".counts.ts holds an epoch within 4 s of now" 1 "$(( ts_end > 0 && END_S - ts_end >= 0 && END_S - ts_end <= 4 ? 1 : 0 ))"
ok "the stamp moves on every slow wake" 1 "$(( $(num "$D/ts.2") > 0 && $(num "$D/ts.3") > $(num "$D/ts.2") ? 1 : 0 ))"
ok "there is a cache file to compare" 1 "$([ -s "$D/ino.2" ] && echo 1 || echo 0)"
ok ".counts.out is not rewritten while its text is the same (same inode)" "$(cat "$D/ino.2" 2>/dev/null)" "$(cat "$D/ino.3" 2>/dev/null)"
ok "a tally that changed is written (new text), and the option follows" "$EXP2" "$(cat "$D/out.5" 2>/dev/null)"
ok "...into a different file" 1 "$([ -n "$(cat "$D/ino.5" 2>/dev/null)" ] && [ "$(cat "$D/ino.5" 2>/dev/null)" != "$(cat "$D/ino.2" 2>/dev/null)" ] && echo 1 || echo 0)"
ok "...and the option is the new text" "$EXP2" "$(cat "$D/opt.5" 2>/dev/null)"
ok "no temp file is left in the state directory" 0 "$(ls -A "$STATE" | grep -c '^\.counts\.out\.')"
ok "the resurrect snapshot is taken on a slow wake, since the bar no longer does" yes "$([ -e "$STATE/.resurrect.ts" ] && echo yes || echo no)"
ok "the option is taken down when the loop ends" "" "$(tm show -gv @tagents_counts 2>/dev/null)"
ok "no markers are left" 0 "$(markers)"

t "10. a tally from before this refresher started is not served"
newrun oldtally
printf 'usage:\n  monthly_limit_usd: abc\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
printf '%s' "$TALLY1" >"$STATE/.counts.tally"; touch -t 200001010000 "$STATE/.counts.tally"
go 3
ok "no cache is written from it" no "$([ -e "$STATE/.counts.out" ] && echo yes || echo no)"
ok "...and no stamp is put on it" no "$([ -e "$STATE/.counts.ts" ] && echo yes || echo no)"
ok "...and no option is set" "" "$(tm show -gv @tagents_counts 2>/dev/null)"

t "11. once the list stops answering the stamp stops moving"
newrun deaf
act 1 "printf '%s' '$TALLY1' >\"\$RF_STATE/.counts.tally\"; $TALLYNEW"
act 2 'cat "$RF_STATE/.counts.ts" >"$RF_DIR/ts.2"; printf "%s\t%s\t%s\n" 100 working sid-n >"$RF_STATE/7.tsv"; echo "from 2" >"$RF_DIR/curlfail"'
start_ref; wake 2
stop_ref 150
END_S=$(now_s)
ts_end=$(num "$STATE/.counts.ts")
ok "the stamp was put on the answered pass" 1 "$(( $(num "$D/ts.2") > 0 ? 1 : 0 ))"
ok "every post from 2 on was refused, and the loop ended" 5 "$(awk '$1 >= 2' "$D/curl.log" | wc -l | tr -d ' ')"
ok "the stamp is where the answered pass left it" "$(num "$D/ts.2")" "$ts_end"
ok "...which is not now" 1 "$(( END_S - ts_end >= 3 ? 1 : 0 ))"

t "12. the stamp is renewed at the start of the slow pass, before the work"
newrun stamp
SLOW=0
printf 'usage:\n  watch: me\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
act 1 "printf '%s' '$TALLY1' >\"\$RF_STATE/.counts.tally\"; $TALLYNEW"
act 3 'cat "$RF_STATE/.counts.ts" >"$RF_DIR/ts.3"; /bin/sleep 1.1'
go 3
ok "tusage --update ran on the slow wake" yes "$([ -e "$D/ts.update.3" ] && echo yes || echo no)"
ok "the stamp it found is newer than the one the wake began with (a slow update cannot age it)" 1 \
   "$(( $(num "$D/ts.3") > 0 && $(num "$D/ts.update.3") > $(num "$D/ts.3") ? 1 : 0 ))"

t "13. the burn and the month are taken again on the slow pass only"
newrun burn
SLOW=0
printf 'usage:\n  watch: me\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
printf '5h $1.00 ' >"$D/burn"
act 1 "printf '%s' '$TALLY1' >\"\$RF_STATE/.counts.tally\"; $TALLYNEW"
act 3 'cat "$RF_STATE/.counts.out" >"$RF_DIR/out.3"; printf "5h \$2.00 " >"$RF_DIR/burn"'
go 4
has "the burn is in the text from the first pass" '5h $1.00 ' "$(cat "$D/out.3" 2>/dev/null)"
has "...and the tally follows it" "$TALLY1" "$(cat "$D/out.3" 2>/dev/null)"
has "...a burn that moved is read again on the next slow wake" '5h $2.00 ' "$(cat "$STATE/.counts.out" 2>/dev/null)"
newrun burn2
printf 'usage:\n  watch: me\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
printf '5h $1.00 ' >"$D/burn"
act 1 "printf '%s' '$TALLY1' >\"\$RF_STATE/.counts.tally\"; $TALLYNEW"
act 3 'printf "5h \$2.00 " >"$RF_DIR/burn"; printf "%s\t%s\t%s\n" 100 working sid-n >"$RF_STATE/7.tsv"'
go 4
has "a burn that moves is not read by a wake that is not the slow pass" '5h $1.00 ' "$(cat "$STATE/.counts.out" 2>/dev/null)"

t "14. the slow pass fetches the month once, for the bar and the footer together"
newrun month
SLOW=0
printf 'usage:\n  watch: me\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
act 1 "printf '%s' '$TALLY1' >\"\$RF_STATE/.counts.tally\"; $TALLYNEW"
go 2
ok "tusage --daily ran once on the slow wake" 1 "$(awk '$1 == 2 && /--daily/' "$D/tusage.log" | wc -l | tr -d ' ')"
has "...and the footer was posted on it" "change-footer(" "$(awk '$1 == 2' "$D/curl.log")"

t "14b. a slow pass still lands on its tick"
newrun slowmonth
SLOW=0
printf 'usage:\n  watch: me\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
act 1 "printf '%s' '$TALLY1' >\"\$RF_STATE/.counts.tally\"; $TALLYNEW"
RF_SLOW_DAILY=3 go 2
unset RF_SLOW_DAILY
ok "tusage --daily ran on tick 2 although it took 3 s" 1 "$(awk '$1 == 2 && /--daily/' "$D/tusage.log" | wc -l | tr -d ' ')"
has "...and the footer was posted on tick 2" "change-footer(" "$(awk '$1 == 2' "$D/curl.log")"

t "15. the bar's config marker follows the config for as long as the refresher lives"
export TA_CFG_CHECK_EVERY=3
BADCONFIG='usage:\n  monthly_limit_usd: abc\n'
tallyact() { act 1 "printf '%s' '$TALLY1' >\"\$RF_STATE/.counts.tally\"; $TALLYNEW"; }
seeout() { act 2 'cat "$RF_STATE/.counts.out" >"$RF_DIR/out.2"'; }

newrun cfgone
SLOW=0
printf "$BADCONFIG" >"$RFCFG"; touch -t 200001010000 "$RFCFG"
tallyact; seeout
printf '%s 1 %s\n' "$(now_s)" "$RFCFG" >"$STATE/.cfg-check"
go 5
ok "one problem and a fresh verdict: the marker says 1 from the start" "$EXP1" "$(cat "$D/out.2" 2>/dev/null)"
ok "...and still says 1 once the verdict has aged and the slow passes have computed it again (not 2)" "$EXP1" "$(cat "$STATE/.counts.out" 2>/dev/null)"
ok "...and the verdict kept for the next bar is 1 problem" 1 "$(awk '{ print $2 }' "$STATE/.cfg-check" 2>/dev/null)"

newrun cfgfix
SLOW=0
printf "$BADCONFIG" >"$RFCFG"; touch -t 200001010000 "$RFCFG"
tallyact; seeout; act 3 'printf "x: 1\n" >"$RF_CFG"'
go 5
ok "a config with a problem has the marker" "$EXP1" "$(cat "$D/out.2" 2>/dev/null)"
ok "fixed under the refresher: the marker is gone by the next slow pass" "$TALLY1" "$(cat "$STATE/.counts.out" 2>/dev/null)"

newrun cfgbreak
SLOW=0
printf 'x: 1\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
tallyact; seeout; act 3 'printf "usage:\n  monthly_limit_usd: abc\n" >"$RF_CFG"'
go 5
ok "a good config has no marker" "$TALLY1" "$(cat "$D/out.2" 2>/dev/null)"
ok "broken under the refresher: the marker is there by the next slow pass" "$EXP1" "$(cat "$STATE/.counts.out" 2>/dev/null)"
unset TA_CFG_CHECK_EVERY

newrun cfgenv
SLOW=0
mkdir -p "$ROOT/claude-personal"
cat >"$RFCFG" <<YAML
usage:
  watch: personal
claude:
  profiles:
    personal:
      config_dir: $ROOT/claude-personal
  rules:
    - dir: $ROOT/proj
      profile: personal
YAML
touch -t 200001010000 "$RFCFG"
cat >"$D/cfg.norules" <<YAML
usage:
  watch: personal
claude:
  profiles:
    personal:
      config_dir: $ROOT/claude-personal
YAML
printf 'usage:\n  watch: personal\n' >"$D/cfg.noprofiles"
act 3 'cp "$RF_DIR/cfg.norules" "$RF_CFG"'
act 5 'cp "$RF_DIR/cfg.noprofiles" "$RF_CFG"'
go 5
has "the directory rule is handed to the update while the config has it" "$ROOT/proj=personal" "$(cat "$D/rules.update.2" 2>/dev/null)"
ok "the rule removed from the config is gone from the next update" "" "$(cat "$D/rules.update.3" 2>/dev/null)"
has "the profile map stays while the config has the profile" "personal=" "$(cat "$D/accts.update.3" 2>/dev/null)"
ok "the profiles removed from the config are gone from the next update" "" "$(cat "$D/accts.update.5" 2>/dev/null)"

t "16. a config or an overlay that is deleted, or made again, is read again on the next slow pass"
newrun cfggone
SLOW=0
printf 'usage:\n  watch: me\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
act 3 'rm -f "$RF_CFG"'
act 5 'printf "usage:\n  watch: me\n" >"$RF_CFG"'
go 5
ok "the config deleted at wake 3: no tusage --update on 3 and 4; made again at 5: one on 5" "2 5" "$(updates)"

export TA_HOST=ovlhost
OVLF="${RFCFG%.yaml}.ovlhost.yaml"
newrun ovlgone
SLOW=0
rm -f "$OVLF"
printf 'x: 1\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
printf 'usage:\n  watch: me\n' >"$OVLF"; touch -t 200001010000 "$OVLF"
act 3 "rm -f '$OVLF'"
act 5 "printf 'usage:\\n  watch: me\\n' >'$OVLF'"
go 5
ok "the overlay with the usage block deleted at 3: no update on 3 and 4; made again at 5: one on 5" "2 5" "$(updates)"
rm -f "$OVLF"
unset TA_HOST

# ---------------------------------------------------------------------------
t "17. markers are named by pid; what a dead pid left is swept at the start"
# ---------------------------------------------------------------------------
newrun sweep
sh -c 'exit 0' & deadpid=$!; wait "$deadpid" 2>/dev/null
for n in "$deadpid" "$$"; do
  : >"$STATE/.refresher.$n"; : >"$STATE/.refresher.$n.cfg"; : >"$STATE/.refresher.$n.start"
  : >"$STATE/.refresher.$n.evq"; : >"$STATE/.refresher.$n.nap"
  : >"$STATE/.counts.tally.$n"; : >"$STATE/.counts.out.$n"
done
act 2 'ls -A "$RF_STATE" >"$RF_DIR/ls.2"'
go 2
ok "the files of the dead pid are all gone" "0" "$(ls -A "$STATE" | grep -c "\.$deadpid")"
ok "the files of the live pid are all kept" "7" "$(ls -A "$STATE" | grep -c "\.$$")"
ok "while it runs the loop has its markers, the FIFOs among them, named by its pid and not by the port" "5" \
   "$(grep -v "\.$$" "$D/ls.2" | grep -c '^\.refresher\.[0-9][0-9]*\(\.cfg\|\.start\|\.evq\|\.nap\)\{0,1\}$')"
ok "...of which none is the port's" "0" "$(grep -c "^\.refresher\.$PORT" "$D/ls.2")"
ok "...and its own are gone again when it ends (the five of the live pid stay)" "5" "$(markers)"
rm -f "$STATE"/.refresher.* "$STATE"/.counts.*.[0-9]*

# ---------------------------------------------------------------------------
t "18. every kind of path collect() and list() read reloads the list when written"
# ---------------------------------------------------------------------------
# refresh_changed (refresh.sh) is a hand copy of what collect() and list() open.
# One write of each kind on its own wake, to files the count of state files cannot
# explain: the existing ones are rewritten, so a reload on that wake is the gate's.
export TA_HOST=ovlhost
newrun paths
printf 'x: 1\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
printf 'y: 1\n' >"$OVLF"; touch -t 200001010000 "$OVLF"
printf '%s\t%s\t%s\n' 100 working sid-s >"$STATE/s-1.tsv"; touch -t 200001010000 "$STATE/s-1.tsv"
act 2  'printf "%s\t%s\t%s\n" 101 working sid-a >"$RF_STATE/9.tsv"'
act 3  'printf "%s\t%s\t%s\n" 101 working sid-s >"$RF_STATE/s-1.tsv"'
act 4  'printf "sid-a\tother\n" >"$RF_STATE/origin.tsv"'
act 5  'printf "9\tnamed\n" >"$RF_STATE/labels.tsv"'
act 6  'printf "cost\n" >"$RF_STATE/cols"'
act 7  ': >"$RF_STATE/.flat"'
act 8  'echo y >"$RF_STATE/sub/9.b"'
act 9  'printf "sid-b\tm\t\tSonnet\n" >"$RF_STATE/model/sid-b.tsv"'
act 10 'echo 200 >"$RF_STATE/prompt/9"'
act 11 'echo "x: 2" >"$RF_CFG"'
act 12 'echo "y: 2" >"${RF_CFG%.yaml}.ovlhost.yaml"'
go 13
ok "state file, s- file, origins, labels, cols, .flat, sub, model, prompt, config and overlay each reload on their own wake, and the wake after is quiet" \
   "1 2 3 4 5 6 7 8 9 10 11 12" "$(reloads)"
rm -f "$OVLF"
unset TA_HOST

# ---------------------------------------------------------------------------
t "19. the doorbells: the agent-state hook wakes a waiter, and a hook of the owner's is left alone"
# ---------------------------------------------------------------------------
# The pane the hook is run for, made before the scenario starts so that its own events are drained with the rest.
HKP=$(tm split-window -d -P -F '#{pane_id}' -t "$DP" 'sleep 600')
newrun bell
tm set-hook -g 'after-split-window[7]' 'set -g @mine yes'
tm set-hook -g 'after-split-window[42]' 'set -g @mine no'
HOOK="$HERE/../hooks/tmux-agent-state.sh"
printf '{"hook_event_name":"PreToolUse","session_id":"sid-b","cwd":"/tmp","transcript_path":"","tool_name":"Bash","tool_input":{"command":"ls"}}' >"$D/pre.json"
rm -f "$D/woke"
( tm wait-for tagents-ev; : >"$D/woke" ) &
/bin/sleep 0.5
env TMUX="$SOCK,0,0" TMUX_PANE="$HKP" TA_STATE_DIR="$STATE" sh "$HOOK" <"$D/pre.json"
/bin/sleep 0.5
ok "a hook event rings tagents-ev" yes "$([ -e "$D/woke" ] && echo yes || echo no)"
ok "...and still sets @agent on the pane" working "$(tm show -pv -t "$HKP" @agent 2>/dev/null)"
rm -f "$D/woke"
( tm wait-for tagents-ev; : >"$D/woke" ) &
/bin/sleep 0.5
env TMUX="$SOCK,0,0" TMUX_PANE=%999999 TA_STATE_DIR="$STATE" sh "$HOOK" <"$D/pre.json"
/bin/sleep 0.5
ok "an event whose pane is gone rings it all the same (the signal is first in the list)" yes "$([ -e "$D/woke" ] && echo yes || echo no)"
modsh install_event_hooks; modsh install_event_hooks
ok "installing the event hooks twice leaves one ring on each of the 18 events" 18 "$(hooks42)"
tm split-window -d -t tatest-dash: 'sleep 1'
/bin/sleep 0.3
ok "the owner's hook at [7] ran beside ours" yes "$(tm show -gv @mine 2>/dev/null | grep -q yes && echo yes || echo no)"

# THE HOOK'S COPY OF THE COUNT. The agent-state hook is POSIX sh and cannot source core.sh, so it carries the format that bumps @tagents_evgen itself; the two must stay the same text.
HOOKB=$(sed -n "s/^EV_BUMP='\(.*\)'\$/\1/p" "$HOOK")
ok "the hook's EV_BUMP is core.sh's, character for character" "$EVB" "$HOOKB"
ok "no ring in the hook is a bare signal: the count comes first" 0 \
   "$(grep -c 'tmux wait-for -S tagents-ev' "$HOOK" | tr -d ' ')"
ok "...six rings: the subagent pair, the removal pair and the event pair" 6 \
   "$(grep -c 'tmux set -gF @tagents_evgen "\$EV_BUMP" \\; wait-for -S tagents-ev' "$HOOK" | tr -d ' ')"
g0=$(tm show -gv @tagents_evgen 2>/dev/null); g0=${g0:-0}
env TMUX="$SOCK,0,0" TMUX_PANE="$HKP" TA_STATE_DIR="$STATE" sh "$HOOK" <"$D/pre.json"
g1=$(tm show -gv @tagents_evgen 2>/dev/null); g1=${g1:-0}
ok "one hook event adds one to the count" 1 "$((g1 - g0))"

# ---------------------------------------------------------------------------
t "20. the bar shows the new tally within 3 s of the last change, with no further ring"
# ---------------------------------------------------------------------------
# The reload is asynchronous: the tally the pass reads right after the post is the
# previous reload's. A list is stood in for by the curl shim, which writes the tally
# 0.4 s after a reload from the state files it was drawn from. The change is filed
# and rung once; the second look a second on is what has to pick up the new tally.
newrun fresh
cat >"$D/tally" <<TALLYEOF
n=0; for f in "$STATE"/[0-9]*.tsv; do [ -e "\$f" ] && n=\$((n + 1)); done
printf '#[fg=cyan]✓%s #[default]' "\$n" >"$STATE/.counts.tally.\$\$" && mv -f "$STATE/.counts.tally.\$\$" "$STATE/.counts.tally"
TALLYEOF
start_ref
ok "the first list's tally is on the bar" '#[fg=cyan]✓1 #[default]' "$(cat "$STATE/.counts.out" 2>/dev/null)"
printf '%s\t%s\t%s\n' 100 working sid-n >"$STATE/7.tsv"
T0=$SECONDS; echo 2 >"$D/tick"; ring
want='#[fg=cyan]✓2 #[default]'
while [ "$SECONDS" -lt $((T0 + 6)) ] && [ "$(cat "$STATE/.counts.out" 2>/dev/null)" != "$want" ]; do /bin/sleep 0.1; done
T1=$SECONDS
ok ".counts.out has the tally of the last change" "$want" "$(cat "$STATE/.counts.out" 2>/dev/null)"
ok "...within 3 s of the ring" 1 "$(( T1 - T0 <= 3 ? 1 : 0 ))"
# the option is set by the program that follows the file's write, so it is waited for too
i=0; while [ "$i" -lt 20 ] && [ "$(tm show -gv @tagents_counts 2>/dev/null)" != "$want" ]; do i=$((i + 1)); /bin/sleep 0.1; done
ok "...and so has the tmux option, the one the bar prints" "$want" "$(tm show -gv @tagents_counts 2>/dev/null)"
ok "...the one ring made one reload" "1 2" "$(reloads)"
stop_ref 0

# ---------------------------------------------------------------------------
t "21. a busy period: at most one reload per TA_REFRESH_MIN, programs per pass and not per ring"
# ---------------------------------------------------------------------------
# About ten rings a second for six seconds, each with a state file rewritten. It used
# to be a reload a second (the loop's own second look and its delay) and one
# `tmux wait-for` started per ring; now it is one reload per two seconds, and one
# snapshot and one wait per pass.
newrun busy
MINP=2
start_ref
R0=$(wc -l <"$D/curl.log" | tr -d ' '); P0=$(wc -l <"$D/tmux.log" | tr -d ' '); W0=$(grep -c ' list-panes$' "$D/tmux.log")
i=0; T0=$SECONDS
while [ "$((SECONDS - T0))" -lt 6 ]; do
  i=$((i + 1))
  printf '%s\t%s\t%s\t%s\n' "$((100 + i))" working sid-a "$ROOT" >"$STATE/9.tsv"
  echo 2 >"$D/tick"; ring
  /bin/sleep 0.1
done
RINGS=$i
R1=$(wc -l <"$D/curl.log" | tr -d ' '); P1=$(wc -l <"$D/tmux.log" | tr -d ' '); W1=$(grep -c ' list-panes$' "$D/tmux.log")
POSTS=$((R1 - R0)); PROGS=$((P1 - P0)); PASSES=$((W1 - W0))
printf '       (%s rings in 6 s: %s reloads, %s tmux programs, %s passes)\n' "$RINGS" "$POSTS" "$PROGS" "$PASSES"
ok "at most 4 reloads in the six seconds" 1 "$(( POSTS <= 4 ? 1 : 0 ))"
ok "...and it did draw: the changes were not dropped" 1 "$(( POSTS >= 2 ? 1 : 0 ))"
ok "the tmux programs are about the passes (a snapshot and a wait each, and a few extras), not the rings" 1 "$(( PROGS <= PASSES * 3 + 4 ? 1 : 0 ))"
ok "...which is far fewer than the rings (half of them at the most)" 1 "$(( PROGS * 2 < RINGS ? 1 : 0 ))"
# A change right after the burst is drawn once the interval allows, on the strength of its
# own ring: nothing rings after it.
R2=$(wc -l <"$D/curl.log" | tr -d ' ')
printf '%s\t%s\t%s\t%s\n' 999 working sid-a "$ROOT" >"$STATE/9.tsv"
ring
/bin/sleep 3.5
ok "a change made just after the burst is drawn within 3.5 s, though it came inside the interval of a post" 1 \
   "$(( $(wc -l <"$D/curl.log" | tr -d ' ') > R2 ? 1 : 0 ))"
stop_ref 0
MINP=1

# ---------------------------------------------------------------------------
t "22. rings that land between two waits are not lost"
# ---------------------------------------------------------------------------
# Two signals with nobody waiting cancel each other. The shim holds every wait back
# 2.5 s (the gap), a change is filed and rung once, and while the wait is still not
# there a second change is filed and rung TWICE: with signals alone that is a flag set
# and cleared again, and the loop sleeps until its idle timeout. With the count, the
# wait finds it has moved and returns at once.
newrun gap
start_ref
echo 2.5 >"$D/gap"
printf '%s\t%s\t%s\n' 100 working sid-n >"$STATE/7.tsv"
echo 2 >"$D/tick"; ring
/bin/sleep 1.5
echo y >"$STATE/sub/9.z"
ring; ring
rm -f "$D/gap"
/bin/sleep 4.5
ok "the first change is drawn on its ring, the second on the wait that found the count moved" "1 2 2" "$(reloads)"
stop_ref 0

# ---------------------------------------------------------------------------
t "23. the focus events ring from [42], once, and the slow pass puts a wiped hook back"
# ---------------------------------------------------------------------------
newrun focus
modsh install_event_hooks
for ev in pane-focus-in after-select-pane after-select-window client-session-changed; do
  ok "$ev rings from [42], with the count first" 1 "$(hooks42 "$ev")"
  ok "...and nothing else of ours rings: the signal appears once in its list" 1 \
     "$( { tm show-hooks -g; tm show-hooks -gw; } 2>/dev/null | grep "^$ev\[" | grep -c 'wait-for -S tagents-ev')"
done
for ev in session-window-changed client-session-changed; do
  ok "$ev carries the follow hook at [43], once" 1 "$( { tm show-hooks -g; tm show-hooks -gw; } 2>/dev/null | grep "^$ev\[43\]" | grep -c -- '--follow')"
done
# One focus change, one ring. A plain pane and a plain window: the guards of the
# other hooks are false for them, so nothing but the ring runs.
W2=$(tm new-window -d -P -F '#{window_id}' -t tatest-dash: 'sleep 600')
P2=$(tm split-window -d -P -F '#{pane_id}' -t tatest-dash:0 'sleep 600')
/bin/sleep 0.3
# A pane that has never had the focus fires one more event the first time (tmux 3.7b),
# so it is given the focus once and the next change is the one that is counted.
tm select-pane -t "$P2"; tm select-pane -t tatest-dash:0.0; /bin/sleep 0.3
g0=$(tm show -gv @tagents_evgen 2>/dev/null); g0=${g0:-0}
tm select-pane -t "$P2"; /bin/sleep 0.3
g1=$(tm show -gv @tagents_evgen 2>/dev/null); g1=${g1:-0}
ok "select-pane rings the refresher exactly once" 1 "$((g1 - g0))"
tm select-window -t "$W2"; /bin/sleep 0.3
g2=$(tm show -gv @tagents_evgen 2>/dev/null); g2=${g2:-0}
ok "select-window rings it exactly once" 1 "$((g2 - g1))"
tm select-window -t tatest-dash:0; tm kill-window -t "$W2" 2>/dev/null
# The ring is the LAST thing an event runs: tmux runs the entries in index order,
# and a probe at [3] of an event of install_event_hooks's, and one at [9] of a focus
# event, each see the count as it was before the ring.
tm set-hook -g 'after-new-window[3]' "set -gF @probe3 '#{@tagents_evgen}'"
tm set-hook -g 'after-select-pane[9]' "set -gF @probe9 '#{@tagents_evgen}'"
b=$(tm show -gv @tagents_evgen 2>/dev/null); b=${b:-0}
W3=$(tm new-window -d -P -F '#{window_id}' -t tatest-dash: 'sleep 600'); /bin/sleep 0.3
ok "after-new-window: the entry at [3] ran before the ring at [42]" "$b" "$(tm show -gv @probe3 2>/dev/null)"
ok "...and the ring ran (a new window is several events, each with its own)" 1 "$(( $(tm show -gv @tagents_evgen 2>/dev/null) > b ? 1 : 0 ))"
tm kill-window -t "$W3" 2>/dev/null
tm set-hook -gu 'after-new-window[3]'
P3=$(tm split-window -d -P -F '#{pane_id}' -t tatest-dash: 'sleep 600'); /bin/sleep 0.3
b=$(tm show -gv @tagents_evgen 2>/dev/null); b=${b:-0}
tm select-pane -t "$P3"; /bin/sleep 0.3
ok "after-select-pane: the entry at [9] ran before the ring at [42]" "$b" "$(tm show -gv @probe9 2>/dev/null)"
tm kill-pane -t "$P3" 2>/dev/null
tm set-hook -gu 'after-select-pane[9]'

# A .tmux.conf that sets a hook of ours without an index wipes the event's list,
# [42] with it. The refresher puts it back on its slow pass.
newrun heal
SLOW=0
act 2 '"$RF_TMUX" -L "$RF_S" set-hook -g pane-focus-in "set -g @mine x"; "$RF_TMUX" -L "$RF_S" show-hooks -gw >"$RF_DIR/hooks.before"'
act 4 '"$RF_TMUX" -L "$RF_S" show-hooks -gw >"$RF_DIR/hooks.after"'
go 4
ok "a hook set without an index leaves nothing of ours in the event" 0 "$(grep -c '^pane-focus-in\[42\]' "$D/hooks.before")"
ok "...and the slow pass of the wake that follows has put [42] back" 1 "$(awk -v e="pane-focus-in[42] $EVSHOW" '$0 == e' "$D/hooks.after" | wc -l | tr -d ' ')"
ok "...beside the one that wiped it" 1 "$(grep -c '^pane-focus-in\[0\] set-option -g @mine x' "$D/hooks.after")"

# With the cockpit up the slow pass sets the viewport's guard at [44] as well, and a guard something outside removed comes back.
newrun heal44
SLOW=0
tm new-session -d -s tagents -x 80 -y 24 'sleep 600' \; set -t '=tagents:' @tagents_cockpit 1
act 2 '"$RF_TMUX" -L "$RF_S" set-hook -gu "client-session-changed[44]"; "$RF_TMUX" -L "$RF_S" show-hooks -g >"$RF_DIR/hooks.before"'
act 4 '"$RF_TMUX" -L "$RF_S" show-hooks -g >"$RF_DIR/hooks.after"'
go 4
ok "a removed guard is gone before the slow pass" 0 "$(grep -c '^client-session-changed\[44\]' "$D/hooks.before")"
ok "...and the slow pass has put the guard back at [44], once" 1 "$(grep -c '^client-session-changed\[44\] if-shell -F' "$D/hooks.after")"
tm kill-session -t '=tagents:'; tm set-hook -gu 'client-session-changed[44]'

# ---------------------------------------------------------------------------
t "24. a refresher started from fzf ends with its fzf, though the bash around it lives on"
# ---------------------------------------------------------------------------
# The bind is the real one, read out of dash.sh: $PPID is what the shell fzf starts
# for an execute-silent sees as its parent, which is fzf. $$ of dash() is the bash
# that starts fzf again after an abort, and a refresher watching that outlives
# every fzf it was made for.
RAW=$(sed -n 's/^  kb start  *"\(.*\)"$/\1/p' "$HERE/../lib/tagents/dash.sh")
has "the bind of dash.sh hands the refresher fzf's own pid by way of PPID" 'TA_LIST_PID=\$PPID' "$RAW"
newrun fzf
# The wrapper builds the bind the way dash() does: the text of dash.sh between its
# double quotes, in a bash whose $$ is the wrapper's and whose SELF is the checkout.
{
  echo '#!/bin/bash'
  echo "# The bash around fzf: it goes on when fzf is gone, as dash() does after an abort."
  echo "echo \$\$ >'$D/wrap.pid'"
  echo "SELF='$TREE/tagents'"
  printf 'bind="%s"\n' "$RAW"
  echo "printf 'a\\nb\\n' | fzf --listen --bind \"start:\$bind\""
  echo "sleep 60"
} >"$D/wrap.sh"
WN=$(tm new-window -d -P -F '#{window_id}' -t tatest-dash: \
      "env TA_STATE_DIR='$STATE' TA_CONFIG='$RFCFG' TA_SESSION=tatest-dash TA_REFRESH_IDLE=2 bash '$D/wrap.sh'")
i=0; while [ -z "$(ls -A "$STATE" 2>/dev/null | grep '^\.refresher\.[0-9]*\.start$')" ] && [ "$i" -lt 100 ]; do /bin/sleep 0.1; i=$((i + 1)); done
RPID=$(ls -A "$STATE" 2>/dev/null | sed -n 's/^\.refresher\.\([0-9]*\)\.start$/\1/p' | head -1)
WPID=$(cat "$D/wrap.pid" 2>/dev/null)
FPID=$(ps -A -o pid=,ppid=,comm= | awk -v w="$WPID" '$2 == w && $3 ~ /fzf$/ { print $1 }' | head -1)
ok "a refresher was started by the bind, and fzf is a child of the wrapper" 1 "$([ -n "$RPID" ] && [ -n "$FPID" ] && echo 1 || echo 0)"
ok "it is alive while its fzf is" alive "$(kill -0 "$RPID" 2>/dev/null && echo alive || echo gone)"
kill "$FPID" 2>/dev/null
# Six seconds: the idle timeout (2 s) finds the list gone. A refresher that watched the
# wrong process would end only by its five refused posts, two seconds apart, after ten.
i=0; while kill -0 "$RPID" 2>/dev/null && [ "$i" -lt 60 ]; do /bin/sleep 0.1; i=$((i + 1)); done
ok "fzf is killed: the refresher ends within the idle timeout, not by its refused posts" gone "$(kill -0 "$RPID" 2>/dev/null && echo alive || echo gone)"
ok "...while the bash around fzf lives on" alive "$(kill -0 "$WPID" 2>/dev/null && echo alive || echo gone)"
tm kill-window -t "$WN" 2>/dev/null
kill -9 "$RPID" 2>/dev/null
rm -f "$STATE"/.refresher.*

# ---------------------------------------------------------------------------
t "25. what the loop leaves behind: no waiter, no bar text"
# ---------------------------------------------------------------------------
# The exit frees the waiter that is outstanding: its `tmux if-shell` would otherwise
# sit in the server until somebody rang the channel.
newrun orphan
start_ref
wake 2
stop_ref 0
/bin/sleep 0.5
ok "no waiter of the loop is left in the server once the loop has ended" 0 \
   "$(ps -A -o ppid=,command= | awk '$1 == 1 && /if-shell/ && /tagents_evgen/' | wc -l | tr -d ' ')"

# A loop that is killed with -9 leaves its waiter in the server, as it always did,
# until the channel is rung; the waiter must then end, and not sit for ever in the
# open of a FIFO that nobody reads any more.
newrun killed
start_ref
wake 2
kill -9 "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null
ring; /bin/sleep 1
ok "no process of a loop killed with -9 is left once the channel has been rung" 0 \
   "$(ps -A -o ppid=,command= | awk -v t="$TREE/tagents" '$1 == 1 && index($0, t)' | wc -l | tr -d ' ')"
rm -f "$STATE"/.refresher.*

# A refresher that was killed with -9 cannot take @tagents_counts down. The list that
# closes does, when no marker with a live pid is left (release_dash, sidebar.sh).
newrun deadbar
tm set -g @tagents_counts 'frozen'
sh -c 'exit 0' & gone=$!; wait "$gone" 2>/dev/null
: >"$STATE/.refresher.$gone.start"
env TMUX="$SOCK,0,0" TMUX_PANE="$DP" TA_STATE_DIR="$STATE" TA_CONFIG="$RFCFG" TA_SESSION=tatest-dash \
    /bin/bash -c 'for m in '"$LISTED_MODS"'; do . "'"$HERE"'/../lib/tagents/$m.sh"; done; release_dash' >/dev/null 2>&1
ok "the list that closes takes the bar's text down when the only marker left is a dead refresher's" "" "$(tm show -gv @tagents_counts 2>/dev/null)"
tm set -g @tagents_counts 'kept'
sleep 600 & alive=$!
: >"$STATE/.refresher.$alive.start"
env TMUX="$SOCK,0,0" TMUX_PANE="$DP" TA_STATE_DIR="$STATE" TA_CONFIG="$RFCFG" TA_SESSION=tatest-dash \
    /bin/bash -c 'for m in '"$LISTED_MODS"'; do . "'"$HERE"'/../lib/tagents/$m.sh"; done; release_dash' >/dev/null 2>&1
ok "...and leaves it alone while another refresher is alive" kept "$(tm show -gv @tagents_counts 2>/dev/null)"
kill "$alive" 2>/dev/null; rm -f "$STATE"/.refresher.*; tm set -gu @tagents_counts
tm set -p -t "$DP" @tagents_list "$$"

# ctrl-q in the cockpit (cockpit_quit, cockpit.sh) leaves the server as it was before the cockpit: no hook at [44], no table, no viewport option, and no session tagents.
newrun cquit
cq_hooks() { tm show-hooks -g 2>/dev/null; }
cq_before=$(cq_hooks)
tm new-session -d -s tagents -x 80 -y 24 'sleep 600' \; set -t '=tagents:' @tagents_cockpit 1
modsh 'cockpit_guard_install; tmux bind-key -T tagents-cockpit C-b select-pane; tmux set -g @tagents_viewport_tty /dev/x \; set -g @tagents_viewport_shown "$1" \; set -g @tagents_viewport_window w \; set -g @tagents_viewport_idle 1'
ok "the cockpit's hook, table and options are on the server before the quit" 1 "$(tm show-hooks -g | grep -c '^client-session-changed\[44\]')"
modsh 'cockpit_quit'
ok "after the quit no hook of the cockpit is left" "$cq_before" "$(cq_hooks)"
ok "...no viewport option is left" "" "$(tm show -g 2>/dev/null | grep '^@tagents_viewport')"
ok "...no key table is left" "" "$(tm list-keys -T tagents-cockpit 2>/dev/null)"
ok "...and the session tagents is gone" 0 "$(tm has-session -t '=tagents:' 2>/dev/null && echo 1 || echo 0)"
tm set -p -t "$DP" @tagents_list "$$"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
