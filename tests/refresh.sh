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
t "2b. a deleted state file reloads the list on the next tick"
# ---------------------------------------------------------------------------
newrun gone
act 3 'rm -f "$RF_STATE/9.tsv"'
go 6
ok "the state file removed between two idle ticks (3) reloads once, then the forced tick" "1 3 5" "$(reloads)"
ok "the other ticks stay quiet" "2 4 6" "$(ignores)"

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

# ---------------------------------------------------------------------------
t "9. the refresher keeps the status bar's cache from the tally the list wrote"
# ---------------------------------------------------------------------------
# The list writes .counts.tally each time it is rendered with its marks on; the
# loop turns the last one into .counts.out and stamps .counts.ts on every tick
# its post is answered, so the bar serves the cache and starts no list of its
# own. The text is the tally with the config marker in front (a bad number in the
# config gives exactly one).
TALLY1='#[fg=yellow]⚠1 #[fg=green]●2 #[default]'
TALLY2='#[fg=cyan]✓4 #[default]'
EXP1="#[fg=magenta]cfg!1 $TALLY1"
EXP2="#[fg=magenta]cfg!1 $TALLY2"
now_s() { date +%s; }
num() {  # <file> — the epoch in it, or 0 for a file that is missing or empty
  local v=""; read -r v <"$1" 2>/dev/null
  case ${v:-x} in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}
newrun counts
printf 'usage:\n  monthly_limit_usd: abc\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
# The list renders during tick 1, and the first tally is there for the loop's
# first answered post; the second is written on the 5th tick.
act 1 "printf '%s' '$TALLY1' >\"\$RF_STATE/.counts.tally\""
act 2 'cat "$RF_STATE/.counts.out" >"$RF_DIR/out.2"; ls -i "$RF_STATE/.counts.out" >"$RF_DIR/ino.2"; cat "$RF_STATE/.counts.ts" >"$RF_DIR/ts.2"'
act 4 'ls -i "$RF_STATE/.counts.out" >"$RF_DIR/ino.4"; cat "$RF_STATE/.counts.ts" >"$RF_DIR/ts.4"; [ -e "$RF_STATE/.resurrect.ts" ] && echo yes >"$RF_DIR/res.4"'
act 5 "printf '%s' '$TALLY2' >\"\$RF_STATE/.counts.tally\""
act 6 'cat "$RF_STATE/.counts.out" >"$RF_DIR/out.6"; ls -i "$RF_STATE/.counts.out" >"$RF_DIR/ino.6"'
go 7
END_S=$(now_s)
ok "after the first answered tick .counts.out is the config marker and the tally" "$EXP1" "$(cat "$D/out.2" 2>/dev/null)"
ts_end=$(num "$STATE/.counts.ts")
ok ".counts.ts holds an epoch within 2 s of now" 1 "$(( ts_end > 0 && END_S - ts_end >= 0 && END_S - ts_end <= 2 ? 1 : 0 ))"
ok "the stamp moves on every answered tick" 1 "$(( $(num "$D/ts.2") > 0 && $(num "$D/ts.4") > $(num "$D/ts.2") ? 1 : 0 ))"
ok "there is a cache file to compare" 1 "$([ -s "$D/ino.2" ] && echo 1 || echo 0)"
ok ".counts.out is not rewritten while its text is the same (same inode)" "$(cat "$D/ino.2" 2>/dev/null)" "$(cat "$D/ino.4" 2>/dev/null)"
ok "a tally that changed is written (new text, new inode)" "$EXP2" "$(cat "$D/out.6" 2>/dev/null)"
ok "...into a different file" 1 "$([ -n "$(cat "$D/ino.6" 2>/dev/null)" ] && [ "$(cat "$D/ino.6" 2>/dev/null)" != "$(cat "$D/ino.2" 2>/dev/null)" ] && echo 1 || echo 0)"
ok "no temp file is left in the state directory" 0 "$(ls -A "$STATE" | grep -c '^\.counts\.out\.')"
ok "the resurrect snapshot is not due before the 5th tick" "" "$(cat "$D/res.4" 2>/dev/null)"
ok "...and is taken on it, since the bar no longer does" yes "$([ -e "$STATE/.resurrect.ts" ] && echo yes || echo no)"
ok "the three marker files are gone when the loop ends" 0 "$(markers)"

t "10. a tally from before this refresher started is not served"
newrun oldtally
printf 'usage:\n  monthly_limit_usd: abc\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
printf '%s' "$TALLY1" >"$STATE/.counts.tally"; touch -t 200001010000 "$STATE/.counts.tally"
go 4
ok "no cache is written from it" no "$([ -e "$STATE/.counts.out" ] && echo yes || echo no)"
ok "...and no stamp is put on it" no "$([ -e "$STATE/.counts.ts" ] && echo yes || echo no)"

t "11. once the list stops answering the stamp stops moving"
newrun deaf
act 1 "printf '%s' '$TALLY1' >\"\$RF_STATE/.counts.tally\""
act 3 'cat "$RF_STATE/.counts.ts" >"$RF_DIR/ts.3"'
act 4 ':'
act 5 ':'
act 6 ':'
echo "from 3" >"$D/curlfail"
go 8
END_S=$(now_s)
ts_end=$(num "$STATE/.counts.ts")
ok "the stamp was put on the answered ticks" 1 "$(( $(num "$D/ts.3") > 0 ? 1 : 0 ))"
ok "every post from tick 3 on was refused, and the loop ended" 7 "$(lasttick)"
ok "the stamp is where tick 2 left it, three seconds and a tick 0 later" "$(num "$D/ts.3")" "$ts_end"
ok "...which is not now" 1 "$(( END_S - ts_end >= 3 ? 1 : 0 ))"

t "12. the stamp is renewed straight after the sleep on the 5th tick, before the work"
newrun slow
printf 'usage:\n  watch: me\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
act 1 "printf '%s' '$TALLY1' >\"\$RF_STATE/.counts.tally\""
# Read as the 5th tick begins: tick 4 has stamped by then, tick 5 has not. The act
# is followed by a sleep of 1.1 s, so a stamp that tick 5 itself puts on before
# the update is a second newer, and one that it does not is the same.
act 5 'cat "$RF_STATE/.counts.ts" >"$RF_DIR/ts.5"'
go 5
ok "tusage --update ran on the 5th tick" yes "$([ -e "$D/ts.update.5" ] && echo yes || echo no)"
ok "the stamp it found is newer than the one the 5th tick began with (a slow update cannot age it)" 1 \
   "$(( $(num "$D/ts.5") > 0 && $(num "$D/ts.update.5") > $(num "$D/ts.5") ? 1 : 0 ))"

t "13. the burn and the month are taken again on the 5th tick"
newrun burn
printf 'usage:\n  watch: me\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
printf '5h $1.00 ' >"$D/burn"
act 1 "printf '%s' '$TALLY1' >\"\$RF_STATE/.counts.tally\""
act 3 'cat "$RF_STATE/.counts.out" >"$RF_DIR/out.3"; printf "5h \$2.00 " >"$RF_DIR/burn"'
act 4 'cat "$RF_STATE/.counts.out" >"$RF_DIR/out.4"'
go 5
has "the burn is in the text from the first tick" '5h $1.00 ' "$(cat "$D/out.3" 2>/dev/null)"
has "...and the tally follows it" "$TALLY1" "$(cat "$D/out.3" 2>/dev/null)"
ok "a burn that moves is not read between 5th ticks" "$(cat "$D/out.3" 2>/dev/null)" "$(cat "$D/out.4" 2>/dev/null)"
has "...and is read again on the 5th" '5h $2.00 ' "$(cat "$STATE/.counts.out" 2>/dev/null)"

t "14. the 5th tick fetches the month once, for the bar and the footer together"
newrun month
printf 'usage:\n  watch: me\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
act 1 "printf '%s' '$TALLY1' >\"\$RF_STATE/.counts.tally\""
go 5
ok "tusage --daily ran once on the 5th tick" 1 "$(awk '$1 == 5 && /--daily/' "$D/tusage.log" | wc -l | tr -d ' ')"
has "...and the footer was posted on it" "change-footer(" "$(awk '$1 == 5' "$D/curl.log")"

t "15. the bar's config marker follows the config for as long as the refresher lives"
# A fresh process computes the verdict once; a refresher is the same process for
# a day. TA_CFG_CHECK_EVERY is small, so that the verdict kept in .cfg-check ages
# inside a scenario (every act below costs the 1.1 s that ages it).
export TA_CFG_CHECK_EVERY=3
BADCONFIG='usage:\n  monthly_limit_usd: abc\n'
tallyact() { act 1 "printf '%s' '$TALLY1' >\"\$RF_STATE/.counts.tally\""; }
seeout() { act 2 'cat "$RF_STATE/.counts.out" >"$RF_DIR/out.2"'; }

newrun cfgone
printf "$BADCONFIG" >"$RFCFG"; touch -t 200001010000 "$RFCFG"
tallyact; seeout; act 3 ':'; act 4 ':'
# A verdict made just now: the refresher starts on a cache hit, so the one
# problem is counted without the check having run in its shell.
printf '%s 1 %s\n' "$(now_s)" "$RFCFG" >"$STATE/.cfg-check"
go 5
ok "one problem and a fresh verdict: the marker says 1 from the start" "$EXP1" "$(cat "$D/out.2" 2>/dev/null)"
ok "...and still says 1 once the verdict has aged and the 5th tick has computed it again (not 2)" "$EXP1" "$(cat "$STATE/.counts.out" 2>/dev/null)"
ok "...and the verdict kept for the next bar is 1 problem" 1 "$(awk '{ print $2 }' "$STATE/.cfg-check" 2>/dev/null)"

newrun cfgfix
printf "$BADCONFIG" >"$RFCFG"; touch -t 200001010000 "$RFCFG"
tallyact; seeout; act 3 'printf "x: 1\n" >"$RF_CFG"'
go 5
ok "a config with a problem has the marker" "$EXP1" "$(cat "$D/out.2" 2>/dev/null)"
ok "fixed under the refresher: the marker is gone by the next 5th tick" "$TALLY1" "$(cat "$STATE/.counts.out" 2>/dev/null)"

newrun cfgbreak
printf 'x: 1\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
tallyact; seeout; act 3 'printf "usage:\n  monthly_limit_usd: abc\n" >"$RF_CFG"'
go 5
ok "a good config has no marker" "$TALLY1" "$(cat "$D/out.2" 2>/dev/null)"
ok "broken under the refresher: the marker is there by the next 5th tick" "$EXP1" "$(cat "$STATE/.counts.out" 2>/dev/null)"
unset TA_CFG_CHECK_EVERY

# What usage_env exports is the config's, and goes when the config's entry goes.
newrun cfgenv
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
act 6  'cp "$RF_DIR/cfg.norules" "$RF_CFG"'
act 11 'cp "$RF_DIR/cfg.noprofiles" "$RF_CFG"'
go 15
has "the directory rule is handed to the update while the config has it" "$ROOT/proj=personal" "$(cat "$D/rules.update.5" 2>/dev/null)"
ok "the rule removed from the config is gone from the next update" "" "$(cat "$D/rules.update.10" 2>/dev/null)"
has "the profile map stays while the config has the profile" "personal=" "$(cat "$D/accts.update.10" 2>/dev/null)"
ok "the profiles removed from the config are gone from the next update" "" "$(cat "$D/accts.update.15" 2>/dev/null)"
ok "all three updates ran" "5 10 15" "$(awk '$2 == "--update" { printf "%s%s", s, $1; s = " " } END { print "" }' "$D/tusage.log")"

t "16. a config or an overlay that is deleted, or made again, is read again on the next 5th tick"
# A file that is not there is never newer than anything, so the mtime rule cannot
# see it go; the refresher remembers whether each of the two existed at its last read.
updates() { awk '$2 == "--update" { printf "%s%s", s, $1; s = " " } END { print "" }' "$D/tusage.log"; }

newrun cfggone
printf 'usage:\n  watch: me\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
act 3 'rm -f "$RF_CFG"'
act 6 'printf "usage:\n  watch: me\n" >"$RF_CFG"'
go 10
ok "the config deleted at tick 3: no tusage --update on the 5th; made again at tick 6: one on the 10th" "10" "$(updates)"

export TA_HOST=ovlhost
OVLF="${RFCFG%.yaml}.ovlhost.yaml"
newrun ovlgone
rm -f "$OVLF"
printf 'x: 1\n' >"$RFCFG"; touch -t 200001010000 "$RFCFG"
printf 'usage:\n  watch: me\n' >"$OVLF"; touch -t 200001010000 "$OVLF"
act 3 "rm -f '$OVLF'"
act 6 "printf 'usage:\\n  watch: me\\n' >'$OVLF'"
go 10
ok "the overlay with the usage block deleted at tick 3: no update on the 5th; made again at tick 6: one on the 10th" "10" "$(updates)"
rm -f "$OVLF"
unset TA_HOST

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
