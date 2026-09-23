#!/usr/bin/env bash
#
# tests/resurrect.sh — what comes back after a reboot: the snapshot of every
# live chat, which snapshot a restore picks, and where a docked chat is filed.
#
# NOTHING HERE MAY TOUCH THE DEFAULT TMUX SOCKET. The server is created with
# `tmux -L tatest-$$ -f /dev/null` and torn down in the trap, and tagents is
# pointed at it by exporting $TMUX in the test process — never by putting a
# `tmux` shim on $PATH.
#
# HOME is moved under the run's own directory before anything else: both
# accounts of the config live there too, so a transcript check or a default
# login can never reach the real ~/.claude.
#
# `claude` is a stub, first on $PATH BEFORE the server starts. Like the one in
# tests/launch.sh it writes down its account, arguments and cwd; unlike it, it
# also plays the SessionStart hook, so the pane gets the record a real chat
# would have, and it stays alive under its own path as argv[0] — which is how
# the ps walk recognises a Claude and hands over the pid whose argv is kept.
#
# bash 3.2, runnable from any cwd, non-zero exit on any failing check.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TA="$HERE/../tagents"
HOOK="$HERE/../hooks/tmux-agent-state.sh"

command -v tmux >/dev/null 2>&1 || { echo "resurrect.sh: no tmux"; exit 1; }
command -v fzf  >/dev/null 2>&1 || { echo "resurrect.sh: no fzf"; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "resurrect.sh: no jq"; exit 1; }

S=tatest-$$
SOCK=""
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tagents-run.XXXXXX") || exit 1
# ...resolved, because tmux reports a pane cwd with the symlinks already gone
# (/var/folders is /private/var/folders on macOS) and the rows compare the two
# as strings.
ROOT=$(cd "$ROOT" && pwd -P) || exit 1
export HOME="$ROOT/home"; mkdir -p "$HOME"
# The keeper sleep is reaped by pid, and the socket FILE goes with the server —
# the same teardown as tests/launch.sh, for the same reasons.
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
BIN="$ROOT/bin";   mkdir -p "$BIN"
OUT="$ROOT/out";   mkdir -p "$OUT"
STATE="$ROOT/state"; mkdir -p "$STATE"
PERS="$ROOT/personal/repo"; mkdir -p "$PERS/.git"
NOR="$ROOT/elsewhere/repo"; mkdir -p "$NOR/.git"
mkdir -p "$ROOT/cfg-p" "$HOME/.claude"

# The last line is the part that matters to a snapshot. A script's own process
# is named after its interpreter (/bin/sh, bash), so it would never pass for a
# Claude; `exec -a "$0"` keeps a process alive whose name is this file's path,
# ending in /claude like the real CLI's, and whose argv still carries every
# argument the stub was given — the --effort a restore has to replay. The
# `; :` stops bash from exec'ing the sleep in its place.
cat >"$BIN/claude" <<'EOF'
#!/bin/bash
out="$TA_STUB_OUT/${TMUX_PANE#%}.out"
{ printf 'CFG=%s\n' "${CLAUDE_CONFIG_DIR-<unset>}"; printf 'ARGS=%s\n' "$*"; printf 'PWD=%s\n' "$PWD"; } >"$out"
sid=""; prev=""; for a in "$@"; do [ "$prev" = --resume ] && sid=$a; prev=$a; done
[ -n "$sid" ] || sid="sid-${TMUX_PANE#%}"
printf '{"hook_event_name":"SessionStart","session_id":"%s","cwd":"%s","transcript_path":"","source":"startup"}' "$sid" "$PWD" |
  sh "$TA_STUB_HOOK" >/dev/null 2>&1
exec -a "$0" /bin/bash -c 'sleep 600; :' "$0" "$@"
EOF
# tusage is real and reads the real usage index; stubbed to nothing so the
# dashboard under test stays hermetic and fast.
printf '#!/bin/sh\nexit 0\n' >"$BIN/tusage"
chmod +x "$BIN/claude" "$BIN/tusage"

CFG="$ROOT/config.yaml"
cat >"$CFG" <<EOF
claude:
  args: --dangerously-skip-permissions
  profiles:
    personal:
      config_dir: $ROOT/cfg-p
    work:
resurrect:
  every: 0
EOF

# EXPORTED BEFORE THE SERVER EXISTS. A tmux server keeps the environment it was
# started with and hands it to every command it runs, so anything the stub or a
# pane-side tagents needs has to be in place now.
export PATH="$BIN:$PATH"
export TA_STUB_OUT="$OUT"
export TA_STUB_HOOK="$HOOK"
export TA_STATE_DIR="$STATE"
export TA_SESSION=tatest-dash
export TA_CONFIG="$CFG"
unset TMUX TMUX_PANE TA_MODE TA_FLAT TA_COLS TA_NEW_CMD TA_RESUME_CMD TA_HOME
unset CLAUDE_CONFIG_DIR TA_RESURRECT_EVERY TA_RESURRECT_KEEP

tm() { tmux -L "$S" "$@"; }

tm -f /dev/null new-session -d -s tatest-dash -x 200 -y 50 'sleep 600' || exit 1
tm set -g default-shell /bin/sh >/dev/null 2>&1
tm set -g default-command '' >/dev/null 2>&1
tm new-session -d -s tatest-proj -c "$PERS" >/dev/null 2>&1
tm new-session -d -s tatest-other -c "$NOR" >/dev/null 2>&1

SOCK=$(tm display -p '#{socket_path}' 2>/dev/null)
[ -n "$SOCK" ] || { echo "resurrect.sh: no socket for $S"; exit 1; }

# A client on a pty, so display-message has somewhere to go — see
# tests/launch.sh for why the keeper is orphaned and reaped by pid.
( { sleep 300 & printf '%s\n' "$!" >"$ROOT/keeper.pid"; wait; } |
    script -q /dev/null tmux -L "$S" attach -t tatest-dash >/dev/null 2>&1 & ) >/dev/null 2>&1
sleep 0.5

run() { env TMUX="$SOCK,0,0" bash "$TA" "$@"; }

field() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$2"; }

waitrec() {  # <pane number> — the stub's SessionStart has written the record
  local i=0
  while [ "$i" -lt 50 ]; do
    [ -s "$STATE/$1.tsv" ] && return 0
    i=$((i + 1)); sleep 0.1
  done
  return 1
}

row() {  # <snapshot file> <sid> -> that session's A row
  awk -F'\t' -v s="$2" '$1 == "A" && $2 == s' "$1" 2>/dev/null
}

col() {  # <row> <column number>, empty columns kept
  printf '%s\n' "$1" | awk -F'\t' -v n="$2" '{ print $n }'
}

resurrect_files() { ls "$STATE/resurrect" 2>/dev/null | grep -c -E '^[0-9]+\.tsv$'; }

newest() { ls -1 "$STATE/resurrect" 2>/dev/null | grep -E '^[0-9]+\.tsv$' | sort -rn | awk 'NR == 1 { print }'; }

# ---------------------------------------------------------------------------
t "1. a capture: one row per live chat, keyed by session id"
# ---------------------------------------------------------------------------
tm new-window -d -t tatest-proj:1 -c "$PERS" \
  "env CLAUDE_CONFIG_DIR=$ROOT/cfg-p claude --dangerously-skip-permissions --effort high"
tm rename-window -t tatest-proj:1 Alpha
tm set -w -t tatest-proj:1 @tagents_name Alpha
tm new-window -d -t tatest-other:1 -c "$NOR" "claude --dangerously-skip-permissions"
tm rename-window -t tatest-other:1 Hand
# A pane with a record and no Claude in it: the record alone must not count.
tm new-window -d -t tatest-other:2 -c "$NOR" 'sleep 600'

P1=$(tm display -p -t tatest-proj:1.0 '#{pane_id}'); N1=${P1#%}
P2=$(tm display -p -t tatest-other:1.0 '#{pane_id}'); N2=${P2#%}
PS=$(tm display -p -t tatest-other:2.0 '#{pane_id}'); NS=${PS#%}
SID1=sid-$N1; SID2=sid-$N2
mkdir -p "$STATE/model"
printf '%s\tclaude-opus-5-5\tOpus 5.5\t0\n' "$(date +%s)" >"$STATE/model/$SID1.tsv"
printf '%s\tidle\tsid-sleep\t%s\t\t\t\n' "$(date +%s)" "$NOR" >"$STATE/$NS.tsv"

waitrec "$N1"; ok "the first stub wrote its record" 0 "$?"
waitrec "$N2"; ok "the second stub wrote its record" 0 "$?"

run --resurrect-save; ok "--resurrect-save succeeds" 0 "$?"
ok "one snapshot file" 1 "$(resurrect_files)"
S1="$STATE/resurrect/$(newest)"

r1=$(row "$S1" "$SID1")
ok "row 1: the account"        "$ROOT/cfg-p"      "$(col "$r1" 3)"
ok "row 1: hascfg"             1                  "$(col "$r1" 4)"
ok "row 1: session"            tatest-proj        "$(col "$r1" 5)"
ok "row 1: window index"       1                  "$(col "$r1" 6)"
ok "row 1: pane index"         0                  "$(col "$r1" 7)"
ok "row 1: window name"        Alpha              "$(col "$r1" 8)"
ok "row 1: tagents' own name"  Alpha              "$(col "$r1" 9)"
ok "row 1: directory"          "$PERS"            "$(col "$r1" 10)"
ok "row 1: not docked"         ""                 "$(col "$r1" 11)"
ok "row 1: no notes editor"    ""                 "$(col "$r1" 12)"
ok "row 1: the model"          claude-opus-5-5    "$(col "$r1" 13)"
has "row 1: argv keeps --effort" "--effort high"  "$(col "$r1" 14)"

r2=$(row "$S1" "$SID2")
ok "row 2: default account, empty"  ""            "$(col "$r2" 3)"
ok "row 2: ...but the field exists" 1             "$(col "$r2" 4)"
ok "row 2: session"            tatest-other       "$(col "$r2" 5)"
ok "row 2: window name"        Hand               "$(col "$r2" 8)"
ok "row 2: a typed name is not tagents'" ""       "$(col "$r2" 9)"
ok "row 2: directory"          "$NOR"             "$(col "$r2" 10)"
ok "row 2: no model recorded"  ""                 "$(col "$r2" 13)"
ok "row 2: fourteen columns"   14                 "$(printf '%s\n' "$r2" | awk -F'\t' '{ print NF }')"

ok "the sleep pane gets no row" "" "$(row "$S1" sid-sleep)"
ok "two A rows in all" 2 "$(awk -F'\t' '$1 == "A"' "$S1" | wc -l | tr -d ' ')"

sleep 1   # a second capture in a new second, so a new file would have a new name
run --resurrect-save
ok "the same set again writes no second file" 1 "$(resurrect_files)"
ok "--resurrect-rows latest prints the snapshot" "$(cat "$S1")" "$(run --resurrect-rows latest)"

tm kill-window -t tatest-other:2 2>/dev/null
rm -f "$STATE/$NS.tsv"

# ---------------------------------------------------------------------------
t "2. the snapshot to restore is the newest written before the server started"
# ---------------------------------------------------------------------------
start=$(tm display -p '#{start_time}')
out=$(run --resurrect-rows 2>"$ROOT/err"); rc=$?
ok "no pre-start snapshot: no rows" "" "$out"
has "...and it says so" "before this tmux server started" "$(cat "$ROOT/err")"
ok "...and exits non-zero" 1 "$rc"

# A capture taken in the server's own first second holds what was live AFTER
# the boot — nothing, at first — so a file named for the start second is not a
# pre-start one. S1 may already carry that name; a stand-in is made only if not.
same="$STATE/resurrect/$start.tsv"
made=
[ -e "$same" ] || { row "$S1" "$SID1" >"$same"; made=1; }
ok "a snapshot from the start second is not pre-start" "" "$(run --resurrect-rows 2>/dev/null)"
if [ -n "$made" ]; then rm -f "$same"; fi

# The newest pre-start file holds row 1 only, an older one row 2 only, and S1
# (both rows) is newer than either but written after the start.
row "$S1" "$SID1" >"$STATE/resurrect/$((start - 10)).tsv"
row "$S1" "$SID2" >"$STATE/resurrect/$((start - 100)).tsv"
out=$(run --resurrect-rows)
ok "the newest pre-start snapshot is picked" "$(row "$S1" "$SID1")" "$out"
hasnt "...not the newer post-start one" "$SID2" "$out"
ok "a named file is printed as it is" "$(row "$S1" "$SID2")" \
   "$(run --resurrect-rows "$STATE/resurrect/$((start - 100)).tsv")"
rm -f "$STATE/resurrect/$((start - 10)).tsv" "$STATE/resurrect/$((start - 100)).tsv"

# ---------------------------------------------------------------------------
t "3. a docked chat is filed at its home seat, and the sidebar is noted"
# ---------------------------------------------------------------------------
PH=$(tm split-window -d -t tatest-proj:1 -P -F '#{pane_id}' 'sleep 600')
tm set -p -t "$PH" @tagents_slot 1
tm set -p -t "$PH" @tagents_parked "$P1"
tm set -p -t "$P1" @tagents_docked @1
tm set -w -t tatest-dash:0 @tagents 1

sleep 1
run --resurrect-save
S3="$STATE/resurrect/$(newest)"
ok "a changed set is a new file" 2 "$(resurrect_files)"
r1=$(row "$S3" "$SID1")
ok "docked: the placeholder's session"      tatest-proj "$(col "$r1" 5)"
ok "docked: the placeholder's window index" 1           "$(col "$r1" 6)"
ok "docked: the placeholder's pane index"   1           "$(col "$r1" 7)"
ok "docked: marked as docked"               1           "$(col "$r1" 11)"
ok "the sidebar window is a D row" "D	tatest-dash	0" "$(awk -F'\t' '$1 == "D"' "$S3")"

tm set -up -t "$P1" @tagents_docked
tm set -uw -t tatest-dash:0 @tagents
tm kill-pane -t "$PH" 2>/dev/null
rm -f "$S3"
ok "...and cleaned up: S1 is the newest again" "${S1##*/}" "$(newest)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
