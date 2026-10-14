#!/usr/bin/env bash
#
# tests/refresh.sh — what the refresher loop posts to the picker, and when.
#
# Every two seconds the refresher used to reload the picker and ask tmux about the
# seats, and each reload costs a few dozen programs the endpoint security agent
# inspects one by one. What is asserted here is the shape of a quiet minute: a
# reload on the first tick, on every 5th (the forced one that carries the age
# column, the titles and the process deaths) and on a tick where something the
# picker draws changed; a bare `ignore` on the rest, which still proves fzf is
# listening; and one tmux call — the snapshot — on a tick where nothing moved.
#
# THE REAL LOOP RUNS, with its clock and its network replaced by shims first on
# the refresher's PATH only. The sleep shim is the tick: it counts the calls to
# `sleep 2`, runs the action a scenario filed for that tick, and ends the loop
# when told to. The curl shim logs the body it was asked to post, and fails on the
# ticks a scenario names. The tmux shim logs the verb and then execs the real
# tmux, found by absolute path before the shim went on the PATH, against a server
# of this test's own.
#
# NOTHING HERE MAY TOUCH THE DEFAULT TMUX SOCKET: the server is
# `tmux -L tatest-refresh-$$ -f /dev/null` and $TMUX names it.
#
# bash 3.2, runnable from any cwd, non-zero exit on any failing check.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
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

# `sleep 2` is the tick; any other sleep is the real one.
cat >"$BIN/sleep" <<'EOF'
#!/bin/sh
[ "${1:-}" = 2 ] || exec /bin/sleep "$@"
n=0; read -r n <"$RF_DIR/tick"
n=$((n + 1)); echo "$n" >"$RF_DIR/tick"
read -r max <"$RF_DIR/maxtick"
[ "$n" -gt "$max" ] && exit 1
# A change filed for this tick is made now, and a second goes by before the tick
# runs: the marker the loop touches on a reload is then strictly newer than the
# change, whatever the resolution of the file times.
if [ -f "$RF_DIR/at.$n" ]; then sh "$RF_DIR/at.$n"; /bin/sleep 1.1; fi
exit 0
EOF
cat >"$BIN/curl" <<'EOF'
#!/bin/sh
n=0; read -r n <"$RF_DIR/tick"
body=
while [ $# -gt 0 ]; do case $1 in -d) shift; body=$1 ;; esac; shift; done
echo "$n $body" >>"$RF_DIR/curl.log"
if [ -f "$RF_DIR/curlfail" ]; then
  read -r mode rest <"$RF_DIR/curlfail"
  case $mode in
    from)  [ "$n" -ge "$rest" ] && exit 1 ;;
    ticks) case " $rest " in *" $n "*) exit 1 ;; esac ;;
  esac
fi
exit 0
EOF
cat >"$BIN/tmux" <<EOF
#!/bin/sh
n=0; read -r n <"\$RF_DIR/tick"
echo "\$n \$1" >>"\$RF_DIR/tmux.log"
exec "$REALTMUX" "\$@"
EOF
cat >"$BIN/tusage" <<'EOF'
#!/bin/sh
n=0; read -r n <"$RF_DIR/tick"
echo "$n $*" >>"$RF_DIR/tusage.log"
EOF
chmod +x "$BIN"/* "$TREE/tnotes"

unset TMUX TMUX_PANE TA_MODE TA_FLAT TA_COLS TA_NEW_CMD TA_RESUME_CMD TA_HOME TA_HOST
unset CLAUDE_CONFIG_DIR TU_ACCOUNTS TU_ACCOUNT_RULES
export HOME="$ROOT/home"; mkdir -p "$HOME"

tm() { tmux -L "$S" "$@"; }

# The dashboard window the loop looks after: the list pane, which says a live
# list (this very process) is running in it, and one free seat beside it, so the
# self-heal that rebuilds a missing seat has nothing to do.
tm -f /dev/null new-session -d -s tatest-dash -x 200 -y 50 'sleep 600' || exit 1
tm set -g default-shell /bin/sh >/dev/null 2>&1
SOCK=$(tm display -p '#{socket_path}' 2>/dev/null)
[ -n "$SOCK" ] || { echo "refresh.sh: no socket for $S"; exit 1; }
DP=$(tm display -p -t tatest-dash: '#{pane_id}')
SEAT=$(tm split-window -d -P -F '#{pane_id}' -t "$DP" 'sleep 600')
tm set -p -t "$SEAT" @tagents_slot 1
tm set -p -t "$DP" @tagents_list "$$"
tm set -p -t "$DP" @tagents_dash 1

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

# One scenario: a directory of its own for the logs and the actions, the tmux
# options put back, the claim already ours (a list that has been up for a while).
newrun() {
  D="$ROOT/run.$1"; rm -rf "$D"; mkdir -p "$D"
  echo 0 >"$D/tick"; : >"$D/curl.log"; : >"$D/tmux.log"; : >"$D/tusage.log"; : >"$D/tnotes.log"
  mkstate
  rm -f "$RFCFG"
  tm set -gu @ta_notes_any >/dev/null 2>&1
  tm set -wu -t "$DP" @tagents_cur >/dev/null 2>&1
  tm set -p -t "$DP" @tagents_port "$PORT"
}
act() {  # <tick> <commands> — what happens just before that tick
  printf '%s\n' "$2" >"$D/at.$1"
}
# Runs the refresher for <maxtick> ticks. A watchdog ends a loop that does not,
# which is a failure of its own: the shim is the only thing that stops it.
go() {
  local pid i=0
  echo "$1" >"$D/maxtick"
  env RF_DIR="$D" RF_TMUX="$REALTMUX" RF_S="$S" RF_STATE="$STATE" RF_CFG="$RFCFG" RF_DP="$DP" RF_SEAT="$SEAT" \
      PATH="$BIN:$PATH" TMUX="$SOCK,0,0" TMUX_PANE="$DP" TA_PORT="$PORT" \
      TA_STATE_DIR="$STATE" TA_CONFIG="$RFCFG" TA_SESSION=tatest-dash \
      bash "$TREE/tagents" --refresher >"$D/out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 600 ]; do /bin/sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; echo "  (the loop did not stop: killed)"; fi
  wait "$pid" 2>/dev/null
  /bin/sleep 0.3   # the notes sync is started in the background
}

# What the loop posted, as the list of ticks.
reloads() { awk '$2 ~ /^reload-sync/ { printf "%s%s", s, $1; s = " " } END { print "" }' "$D/curl.log"; }
ignores() { awk '$2 == "ignore"      { printf "%s%s", s, $1; s = " " } END { print "" }' "$D/curl.log"; }
# How many times the loop asked tmux anything on each of the given ticks.
tmuxn() {
  local k out=""
  for k in "$@"; do
    out="$out${out:+ }$k:$(awk -v k="$k" '$1 == k' "$D/tmux.log" | wc -l | tr -d ' ')"
  done
  printf '%s' "$out"
}
lasttick() { cat "$D/tick" 2>/dev/null; }
markers() { ls -A "$STATE" 2>/dev/null | grep -c '^\.refresher\.'; }

# ---------------------------------------------------------------------------
t "1. a quiet minute: a reload on the first tick and every fifth, nothing else"
# ---------------------------------------------------------------------------
newrun quiet
go 10
ok "reloads: the first tick and the two forced ones"   "1 5 10"        "$(reloads)"
ok "every other tick posts ignore, and it is answered" "2 3 4 6 7 8 9" "$(ignores)"
has "a reload is still the list reload"                "--list)" "$(grep -m1 reload-sync "$D/curl.log")"
ok "a tick where nothing moved asks tmux once (the snapshot)" \
   "2:1 3:1 4:1 6:1 7:1 8:1 9:1" "$(tmuxn 2 3 4 6 7 8 9)"
ok "no notes editors, no notes sync"                   "" "$(cat "$D/tnotes.log")"
ok "both marker files are gone when the loop ends"     0  "$(markers)"

# ---------------------------------------------------------------------------
t "2. what the picker draws changes on disk: a reload on the next tick"
# ---------------------------------------------------------------------------
newrun disk
printf 'x: 1\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
act 3  'printf "%s\t%s\t%s\n" 100 working sid-n >"$RF_STATE/7.tsv"'
act 7  'echo x >"$RF_STATE/sub/7.b"'
act 9  'printf "sid-a\tm\t\tSonnet\n" >"$RF_STATE/model/sid-a.tsv"'
act 12 'rm -f "$RF_STATE/prompt/9"'
act 13 'echo "x: 2" >"$RF_CFG"'
go 14
ok "a new state file (3), a new sub file (7), a rewritten model file (9), a removed prompt file (12) and the config (13) each reload once" \
   "1 3 5 7 9 10 12 13" "$(reloads)"
ok "and the ticks between them stay quiet" "2 4 6 8 11 14" "$(ignores)"

# ---------------------------------------------------------------------------
t "3. tmux changes: a reload, and the seats looked at again"
# ---------------------------------------------------------------------------
newrun tmux
act 3 '"$RF_TMUX" -L "$RF_S" set -w -t "$RF_DP" @tagents_cur "$RF_SEAT"'
act 6 '"$RF_TMUX" -L "$RF_S" set -up -t "$RF_DP" @tagents_port'
act 7 '"$RF_TMUX" -L "$RF_S" show -pv -t "$RF_DP" @tagents_port >"$RF_DIR/port.7"'
go 9
ok "the seat stamp (3) and the claim taken away (6) each reload, and the claim made again shows in the next snapshot (7)" \
   "1 3 5 6 7" "$(reloads)"
ok "the other ticks stay quiet"                                   "2 4 8 9" "$(ignores)"
ok "the tick after the stamp is quiet again, one tmux call" \
   "4:1 8:1" "$(tmuxn 4 8)"
if [ "$(tmuxn 3)" != "3:1" ]; then r=more; else r=one; fi
ok "the seat block ran on the tick the stamp changed" more "$r"
ok "the claim taken away is made again within the tick" "$PORT" "$(cat "$D/port.7" 2>/dev/null)"

# ---------------------------------------------------------------------------
t "4. five refused posts in a row end the loop, and a refused ignore is one of the five"
# ---------------------------------------------------------------------------
newrun refused
echo "from 2" >"$D/curlfail"
go 20
ok "the loop gives up on the sixth tick, not the seventh" 6 "$(lasttick)"
ok "the first refused post was an ignore (the claim given up with it makes every later tick a reload)" "2" "$(ignores)"
ok "the claim is given up with it" "" "$(tm show -pv -t "$DP" @tagents_port 2>/dev/null)"
ok "both marker files are gone" 0 "$(markers)"

# ---------------------------------------------------------------------------
t "5. a reload that was refused is made again on the next tick"
# ---------------------------------------------------------------------------
newrun retry
echo "ticks 3" >"$D/curlfail"
act 3 'printf "%s\t%s\t%s\n" 100 working sid-n >"$RF_STATE/7.tsv"'
go 4
ok "the reload of tick 3 failed, tick 4 does it again with nothing else changed" "1 3 4" "$(reloads)"
ok "tick 2 was idle" 2 "$(ignores)"

# ---------------------------------------------------------------------------
t "6. a config changed under a running refresher is read again on the next 5th tick"
# ---------------------------------------------------------------------------
newrun cfgon
printf 'x: 1\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
act 3 'printf "usage:\n  watch: me\n" >"$RF_CFG"'
go 10
ok "usage turned on while it ran: tusage --update at ticks 5 and 10" "5 10" \
   "$(awk '$2 == "--update" { printf "%s%s", s, $1; s = " " } END { print "" }' "$D/tusage.log")"
ok "...and the config change itself reloaded the list" "1 3 5 10" "$(reloads)"

newrun cfgoff
printf 'usage:\n  watch: me\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
act 3 'printf "x: 1\n" >"$RF_CFG"'
go 10
ok "usage turned off while it ran: no tusage --update after it" "" \
   "$(awk '$2 == "--update" { printf "%s%s", s, $1; s = " " } END { print "" }' "$D/tusage.log")"

# ---------------------------------------------------------------------------
t "7. the notes editors are looked after only while there are some"
# ---------------------------------------------------------------------------
newrun notes
tm set -g @ta_notes_any 1
go 10
ok "with @ta_notes_any set, tnotes sync is started on each of the two forced ticks" "sync sync" \
   "$(tr '\n' ' ' <"$D/tnotes.log" | sed 's/ $//')"
tm set -gu @ta_notes_any

# ---------------------------------------------------------------------------
t "8. ignore is an action fzf takes and does nothing with"
# ---------------------------------------------------------------------------
FZPORT="$ROOT/fzf.port"
tm new-window -d -t tatest-dash: -n fz \
  "printf 'alpha\nbeta\n' | fzf --listen --bind 'start:execute-silent(echo \$FZF_PORT >$FZPORT)'"
i=0; while [ ! -s "$FZPORT" ] && [ "$i" -lt 50 ]; do /bin/sleep 0.1; i=$((i + 1)); done
FP=$(cat "$FZPORT" 2>/dev/null)
if [ -n "$FP" ]; then
  /bin/sleep 0.3
  BEFORE=$(tm capture-pane -p -t tatest-dash:fz)
  code=$(curl -s -o /dev/null -w '%{http_code}' -XPOST "http://127.0.0.1:$FP" -d ignore); rc=$?
  /bin/sleep 0.3
  AFTER=$(tm capture-pane -p -t tatest-dash:fz)
  ok "curl posting ignore exits 0"                  0   "$rc"
  ok "...and fzf answers 200"                       200 "$code"
  ok "...and the screen is exactly as it was"       "$BEFORE" "$AFTER"
  ok "a made-up action is refused, so the 200 means something" 400 \
     "$(curl -s -o /dev/null -w '%{http_code}' -XPOST "http://127.0.0.1:$FP" -d no-such-action)"
else
  fail=$((fail + 1)); printf '  FAIL fzf never published its port\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
