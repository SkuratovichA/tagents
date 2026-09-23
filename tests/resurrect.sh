#!/usr/bin/env bash
#
# tests/resurrect.sh — what comes back after a reboot: the snapshot of every
# live chat, which snapshot a restore picks, and where a docked chat is filed;
# then the restore itself, on a second server standing in for the one a reboot
# brings up: each chat back in its pane, on its login, with its model — and
# every way a row can fail to come back without anything else going wrong;
# last, the dashboard window and the notes editors a reboot leaves behind.
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
# tnotes is stubbed too: a restore only has to ASK for each editor back, and
# the log of what it asked is the whole assertion (tests/notes.sh owns tnotes).
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$TA_STUB_OUT/tnotes.log"\n' >"$BIN/tnotes"
chmod +x "$BIN/claude" "$BIN/tusage" "$BIN/tnotes"

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

waitfiles() {  # <count> — a capture started in the background has landed (~10 s)
  local i=0
  while [ "$i" -lt 100 ]; do
    [ "$(resurrect_files)" -ge "$1" ] && return 0
    i=$((i + 1)); sleep 0.1
  done
  return 1
}

newest() { ls -1 "$STATE/resurrect" 2>/dev/null | grep -E '^[0-9]+\.tsv$' | sort -rn | awk 'NR == 1 { print }'; }

clear_out() { rm -f "$OUT"/*.out 2>/dev/null; return 0; }

nouts() { ls "$OUT" 2>/dev/null | grep -c '\.out$'; }

nwin() { tm list-windows -t "=$1" 2>/dev/null | wc -l | tr -d ' '; }

outof() {  # <pane id> -> the stub file that pane writes, once it is there (~5 s)
  local f="$OUT/${1#%}.out" i=0
  while [ "$i" -lt 50 ]; do
    [ -s "$f" ] && { printf '%s' "$f"; return 0; }
    i=$((i + 1)); sleep 0.1
  done
  printf '%s' "$f"; return 1
}

arow() {  # <sid cfgd hascfg sess widx pidx wname tname dir docked notes model argv> -> a crafted A row
  printf 'A'; for f in "$@"; do printf '\t%s' "$f"; done; printf '\n'
}

transcript() {  # <sid> — a conversation the default login still holds
  mkdir -p "$HOME/.claude/projects/x"; : >"$HOME/.claude/projects/x/$1.jsonl"
}

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

# ---------------------------------------------------------------------------
t "4. a restore on the same server finds both chats running and starts nothing"
# ---------------------------------------------------------------------------
before=$(nouts)
out=$(run --resurrect --from "$S1"); rc=$?
ok "--resurrect succeeds" 0 "$rc"
ok "both chats are already running" 2 "$(printf '%s\n' "$out" | grep -c 'already running')"
sleep 0.5
ok "...and nothing was launched" "$before" "$(nouts)"
ok "the lock is released" "" "$(ls -d "$STATE/.resurrect.lock" 2>/dev/null)"

# ---------------------------------------------------------------------------
t "5. after a server restart every chat comes back where it was, on its login"
# ---------------------------------------------------------------------------
# Server B is what tmux-resurrect leaves: the same sessions and windows, the
# same names, an idle shell where each chat was. S1 is now from before it.
tm kill-server >/dev/null 2>&1
sleep 1
clear_out
tm -f /dev/null new-session -d -s tatest-dash -x 200 -y 50 'sleep 600' || exit 1
tm set -g default-shell /bin/sh >/dev/null 2>&1
tm set -g default-command '' >/dev/null 2>&1
tm set -gw window-size manual >/dev/null 2>&1
tm new-session -d -s tatest-proj -x 200 -y 50 -c "$PERS"
tm new-window -d -t tatest-proj: -n Alpha -c "$PERS"
tm new-session -d -s tatest-other -x 200 -y 50 -c "$NOR"
tm new-window -d -t tatest-other: -n Hand -c "$NOR"
for w in tatest-proj:0 tatest-proj:1 tatest-other:0 tatest-other:1; do
  tm resize-window -t "$w" -x 200 -y 50 >/dev/null 2>&1
done
SOCK=$(tm display -p '#{socket_path}' 2>/dev/null)
mkdir -p "$ROOT/cfg-p/projects/x"
: >"$ROOT/cfg-p/projects/x/$SID1.jsonl"
transcript "$SID2"

out=$(run --resurrect); rc=$?
ok "--resurrect succeeds" 0 "$rc"
B1=$(tm display -p -t tatest-proj:1.0 '#{pane_id}')
B2=$(tm display -p -t tatest-other:1.0 '#{pane_id}')
f1=$(outof "$B1"); ok "chat 1 is running in its own pane" 0 "$?"
has "chat 1: its conversation"  "--resume $SID1"           "$(field ARGS "$f1")"
has "chat 1: its model"         "--model claude-opus-5-5"  "$(field ARGS "$f1")"
has "chat 1: its effort"        "--effort high"            "$(field ARGS "$f1")"
ok  "chat 1: its login"         "$ROOT/cfg-p"              "$(field CFG "$f1")"
ok  "chat 1: its directory"     "$PERS"                    "$(field PWD "$f1")"
f2=$(outof "$B2"); ok "chat 2 is running in its own pane" 0 "$?"
has "chat 2: its conversation"  "--resume $SID2"           "$(field ARGS "$f2")"
ok  "chat 2: the default login" "<unset>"                  "$(field CFG "$f2")"
ok  "chat 2: its directory"     "$NOR"                     "$(field PWD "$f2")"
hasnt "chat 2: no model was recorded, none is passed" "--model" "$(field ARGS "$f2")"
ok "no window added in tatest-proj"  2 "$(nwin tatest-proj)"
ok "no window added in tatest-other" 2 "$(nwin tatest-other)"
ok "Alpha is tagents' name again" Alpha "$(tm show -wv -t tatest-proj:1 @tagents_name 2>/dev/null)"
ok "Hand keeps its name"          Hand  "$(tm display -p -t tatest-other:1 '#{window_name}')"
ok "...and stays a typed name"    ""    "$(tm show -wv -t tatest-other:1 @tagents_name 2>/dev/null)"
ok "the report has two resumed lines" 2 "$(printf '%s\n' "$out" | grep -c '^✓')"
has "...and the totals" "2 resumed, 0 skipped, 2 recorded" "$out"

SNAP="$ROOT/snap"; mkdir -p "$SNAP"

# ---------------------------------------------------------------------------
t "6. --dry-run says what would come back and starts nothing"
# ---------------------------------------------------------------------------
transcript sid-dry
arow sid-dry "" 1 tatest-other 0 0 Dry "" "$NOR" "" "" "" "" >"$SNAP/dry.tsv"
before=$(nouts)
out=$(run --resurrect --dry-run --from "$SNAP/dry.tsv")
has "it would resume the row" "would resume tatest-other:0.0 Dry [sid-dry]" "$out"
sleep 0.5
ok "...and launched nothing" "$before" "$(nouts)"
ok "...and opened no window" 2 "$(nwin tatest-other)"

# ---------------------------------------------------------------------------
t "7. a pane that is busy is left alone: the chat gets a window of its own"
# ---------------------------------------------------------------------------
tm respawn-pane -k -t tatest-other:0.0 'sleep 600'
transcript sid-busy
arow sid-busy "" 1 tatest-other 0 0 Busy "" "$NOR" "" "" "" "" >"$SNAP/busy.tsv"
out=$(run --resurrect --from "$SNAP/busy.tsv")
ok "a third window in tatest-other" 3 "$(nwin tatest-other)"
pane=$(tm list-windows -t tatest-other -F '#{window_index} #{pane_id}' | sort -n | awk 'END { print $2 }')
f=$(outof "$pane"); ok "the chat runs in it" 0 "$?"
has "...resuming its conversation" "--resume sid-busy" "$(field ARGS "$f")"
ok "...under its recorded name" Busy "$(tm display -p -t "$pane" '#{window_name}')"
ok "the busy pane still runs its sleep" sleep "$(tm display -p -t tatest-other:0.0 '#{pane_current_command}')"

# ---------------------------------------------------------------------------
t "8. a session that is gone is created"
# ---------------------------------------------------------------------------
transcript sid-gone
arow sid-gone "" 1 tatest-gone 3 0 Gone "" "$NOR" "" "" "" "" >"$SNAP/gone.tsv"
out=$(run --resurrect --from "$SNAP/gone.tsv")
tm has-session -t =tatest-gone 2>/dev/null; ok "tatest-gone exists" 0 "$?"
pane=$(tm display -p -t tatest-gone:0.0 '#{pane_id}' 2>/dev/null)
f=$(outof "$pane"); ok "its window 0 runs the chat" 0 "$?"
has "...resuming its conversation" "--resume sid-gone" "$(field ARGS "$f")"
ok "...named from the snapshot" Gone "$(tm display -p -t tatest-gone:0 '#{window_name}' 2>/dev/null)"

# ---------------------------------------------------------------------------
t "9. a conversation whose transcript is gone is skipped"
# ---------------------------------------------------------------------------
arow sid-nots "" 1 tatest-other 1 0 Nots "" "$NOR" "" "" "" "" >"$SNAP/nots.tsv"
before=$(nouts); wins=$(nwin tatest-other)
out=$(run --resurrect --from "$SNAP/nots.tsv")
has "the report says why" "transcript gone" "$out"
sleep 0.5
ok "...and nothing was launched" "$before" "$(nouts)"
ok "...and no window opened" "$wins" "$(nwin tatest-other)"

# ---------------------------------------------------------------------------
t "10. a directory that is gone: resumed in HOME, and said so"
# ---------------------------------------------------------------------------
transcript sid-nodir
arow sid-nodir "" 1 tatest-nodir 0 0 Nodir "" /nonexistent "" "" "" "" >"$SNAP/nodir.tsv"
out=$(run --resurrect --from "$SNAP/nodir.tsv")
has "the report notes it" "/nonexistent is gone, resumed in ~" "$out"
pane=$(tm display -p -t tatest-nodir:0.0 '#{pane_id}' 2>/dev/null)
f=$(outof "$pane"); ok "the chat runs" 0 "$?"
ok "...in HOME" "$HOME" "$(field PWD "$f")"

# ---------------------------------------------------------------------------
t "11. --auto: off in the config is silent; on, the report goes to the log"
# ---------------------------------------------------------------------------
CFG2="$ROOT/config-off.yaml"
{ cat "$CFG"; printf '  auto: false\n'; } >"$CFG2"
transcript sid-auto
arow sid-auto "" 1 tatest-auto 0 0 Auto "" "$NOR" "" "" "" "" >"$SNAP/auto.tsv"
before=$(nouts)
out=$(TA_CONFIG="$CFG2" run --resurrect --auto --from "$SNAP/auto.tsv" 2>&1)
ok "off: prints nothing" "" "$out"
sleep 0.5
ok "off: launches nothing" "$before" "$(nouts)"
tm has-session -t =tatest-auto 2>/dev/null; ok "off: no session" 1 "$?"
ok "off: writes no log" "" "$(ls "$STATE/resurrect.log" 2>/dev/null)"
out=$(run --resurrect --auto --from "$SNAP/auto.tsv" 2>&1)
ok "on: prints nothing, the log is the report" "" "$out"
has "on: the log has the resumed line" "✓ tatest-auto:0.0 Auto" "$(cat "$STATE/resurrect.log" 2>/dev/null)"
pane=$(tm display -p -t tatest-auto:0.0 '#{pane_id}' 2>/dev/null)
f=$(outof "$pane"); ok "on: the chat runs" 0 "$?"
has "...resuming its conversation" "--resume sid-auto" "$(field ARGS "$f")"

# ---------------------------------------------------------------------------
t "12. an empty snapshot says so"
# ---------------------------------------------------------------------------
: >"$SNAP/empty.tsv"
has "nothing recorded" "nothing recorded" "$(run --resurrect --from "$SNAP/empty.tsv")"

# ---------------------------------------------------------------------------
t "13. a D row brings the dashboard back"
# ---------------------------------------------------------------------------
printf 'D\ttatest-dash\t0\n' >"$SNAP/dash.tsv"
out=$(run --resurrect --from "$SNAP/dash.tsv")
has "the report says so" "✓ dashboard" "$out"
ok "a window in tatest-dash carries the marker" 1 \
   "$(tm list-windows -t =tatest-dash -F '#{@tagents}' 2>/dev/null | grep -c '^1$')"

# ---------------------------------------------------------------------------
t "14. the status bar captures, throttled; every: 0 turns it off"
# ---------------------------------------------------------------------------
# The save is started in the background by --counts, so a new file is waited
# for rather than expected at once. Every chat restored above is a set no
# snapshot holds yet, so a capture that should not happen would show.
before=$(resurrect_files)
run --counts >/dev/null 2>&1
sleep 2
ok "every: 0 — no capture"  "$before" "$(resurrect_files)"
ok "...and no stamp either" ""        "$(ls "$STATE/.resurrect.ts" 2>/dev/null)"
TA_RESURRECT_EVERY=1 run --counts >/dev/null 2>&1
waitfiles $((before + 1)); ok "due: the status bar captures" 0 "$?"
ok "...and stamps the time" 1 "$(ls "$STATE/.resurrect.ts" 2>/dev/null | wc -l | tr -d ' ')"
# A changed set inside the interval is left for the next due tick: the stamp
# is the throttle, not the contents.
tm kill-session -t =tatest-nodir >/dev/null 2>&1
TA_RESURRECT_EVERY=3600 run --counts >/dev/null 2>&1
sleep 2
ok "not due: no capture, though the set changed" $((before + 1)) "$(resurrect_files)"
sleep 1
TA_RESURRECT_EVERY=1 run --counts >/dev/null 2>&1
waitfiles $((before + 2)); ok "due again: the changed set is captured" 0 "$?"
sleep 1
TA_RESURRECT_EVERY=1 run --counts >/dev/null 2>&1
sleep 2
ok "due, the same set: not written twice" $((before + 2)) "$(resurrect_files)"

# ---------------------------------------------------------------------------
t "15. --check names a resurrect key it cannot read"
# ---------------------------------------------------------------------------
sed 's/every: 0/every: soon/' "$CFG" >"$ROOT/config-every.yaml"
{ cat "$CFG"; printf '  notes: maybe\n'; }     >"$ROOT/config-notes.yaml"
{ cat "$CFG"; printf '  auto: sometimes\n'; }  >"$ROOT/config-auto.yaml"
hasnt "a good resurrect leaf: nothing said about it" "resurrect." "$(run --check 2>/dev/null)"
has "every: soon" 'resurrect.every: "soon" is not a number of seconds' \
    "$(TA_CONFIG="$ROOT/config-every.yaml" run --check 2>/dev/null)"
has "notes: maybe" 'resurrect.notes: "maybe" is not one of reopen, off' \
    "$(TA_CONFIG="$ROOT/config-notes.yaml" run --check 2>/dev/null)"
has "auto: sometimes" 'resurrect.auto: "sometimes" is not true or false' \
    "$(TA_CONFIG="$ROOT/config-auto.yaml" run --check 2>/dev/null)"

# ---------------------------------------------------------------------------
t "16. the dash window a reboot leaves is where the list starts, not beside it"
# ---------------------------------------------------------------------------
# Server C is the sidebar as tmux-resurrect restores it: a window called dash
# with no marker and an idle shell in each pane the list, its seat and a docked
# chat used to hold.
tm kill-server >/dev/null 2>&1
sleep 1
tm -f /dev/null new-session -d -s tatest-dash -x 200 -y 50 'sleep 600' || exit 1
tm set -g default-shell /bin/sh >/dev/null 2>&1
tm set -g default-command '' >/dev/null 2>&1
tm set -gw window-size manual >/dev/null 2>&1
SOCK=$(tm display -p '#{socket_path}' 2>/dev/null)
DW=$(tm new-window -d -t tatest-dash: -n dash -P -F '#{window_id}' -c "$NOR")
tm resize-window -t "$DW" -x 200 -y 50 >/dev/null 2>&1
DP=$(tm display -p -t "$DW" '#{pane_id}')
SP=$(tm split-window -d -t "$DW" -P -F '#{pane_id}' -c "$NOR")

dashes() { tm list-windows -t =tatest-dash -F '#{window_name}' 2>/dev/null | grep -c '^dash$'; }
# The list is a bash script, so its pane's command reads as a shell whatever it
# is doing; what tells it from the idle shell is the pid it stamps on its pane.
waitlist() {  # <pane id> — a list has started in it and claimed it (~5 s)
  local i=0 pid
  while [ "$i" -lt 50 ]; do
    pid=$(tm display -p -t "$1" '#{@tagents_list}' 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
    i=$((i + 1)); sleep 0.1
  done
  return 1
}

run --ensure-dash >/dev/null 2>&1; ok "--ensure-dash succeeds" 0 "$?"
ok "one window named dash" 1 "$(dashes)"
ok "...the one that was restored" "$DW" \
   "$(tm list-windows -t =tatest-dash -F '#{window_id} #{window_name}' | awk '$2 == "dash" { print $1 }')"
ok "...and it carries the marker" 1 "$(tm show -wv -t "$DW" @tagents 2>/dev/null)"
waitlist "$DP"; ok "the list runs in its first pane" 0 "$?"
has "...started there in place of the shell" tagents "$(tm display -p -t "$DP" '#{pane_start_command}')"
ok "the spare shell is gone" "" "$(tm display -p -t "$SP" '#{pane_id}' 2>/dev/null)"
# ensure_dash always gives the list a seat beside it; anything else would be a
# leftover shell or a second list grown next to the first.
ok "one pane besides the seat" 1 \
   "$(tm list-panes -t "$DW" -F '#{@tagents_slot}' 2>/dev/null | grep -c -v '^1$')"
ok "...and it is the one list" 1 \
   "$(tm list-panes -t "$DW" -F '#{@tagents_list}' 2>/dev/null | grep -c .)"

# A dash window with something running in it is somebody's, however it is
# named: left as it is, and the sidebar gets a window of its own.
tm kill-window -t "$DW" >/dev/null 2>&1
BW=$(tm new-window -d -t tatest-dash: -n dash -P -F '#{window_id}' 'sleep 600')
tm resize-window -t "$BW" -x 200 -y 50 >/dev/null 2>&1
run --ensure-dash >/dev/null 2>&1
ok "a dash window in use keeps what it runs" sleep "$(tm display -p -t "$BW" '#{pane_current_command}')"
ok "...keeps its one pane" 1 "$(tm display -p -t "$BW" '#{window_panes}')"
ok "...and gets no marker" "" "$(tm show -wv -t "$BW" @tagents 2>/dev/null)"
ok "a second dash is made beside it" 2 "$(dashes)"
ok "...and that one is the sidebar" 1 \
   "$(tm list-windows -t =tatest-dash -F '#{window_id} #{window_name} #{@tagents}' |
        awk -v b="$BW" '$1 != b && $2 == "dash" && $3 == "1"' | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
t "17. the editors tmux-resurrect orphaned go; a restored chat's editor comes back"
# ---------------------------------------------------------------------------
# ta-notes as a reboot leaves it: the holder, two editors nothing links to a
# chat any more, and one that still names its chat (an editor opened since).
# The session and holder names are tnotes' own; a rename there must fail here.
ok "tnotes parks editors in the session the restore cleans" ta-notes \
   "$(sed -n 's/^NOTES_SESSION=//p' "$HERE/../tnotes")"
has "...under a holder window called hold" "-n hold" "$(grep 'new-session' "$HERE/../tnotes")"
notes_park() {
  tm new-session -d -s ta-notes -n hold 'sleep 600'
  O1=$(tm new-window -d -t ta-notes: -P -F '#{window_id}' 'sleep 600')
  O2=$(tm new-window -d -t ta-notes: -P -F '#{window_id}' 'sleep 600')
  LW=$(tm new-window -d -t ta-notes: -P -F '#{window_id}' 'sleep 600')
  tm set -p -t "$LW" @ta_notes_for %1
}
# Not `display -t`: for a window id that is gone it prints nothing and exits 0.
gone() {  # <window id> -> there | gone
  case " $(tm list-windows -a -F '#{window_id}' 2>/dev/null | tr '\n' ' ') " in
    *" $1 "*) echo there ;; *) echo gone ;;
  esac
}
notes_park
transcript sid-notes
arow sid-notes "" 1 tatest-notes 0 0 Notes "" "$NOR" "" 1 "" "" >"$SNAP/notes.tsv"
rm -f "$OUT/tnotes.log"
out=$(run --resurrect --from "$SNAP/notes.tsv")
NP=$(tm display -p -t tatest-notes:0.0 '#{pane_id}' 2>/dev/null)
f=$(outof "$NP"); ok "the chat runs" 0 "$?"
ok "the first orphan is gone"  gone "$(gone "$O1")"
ok "the second orphan is gone" gone "$(gone "$O2")"
ok "the holder stays" 1 "$(tm list-windows -t =ta-notes -F '#{window_name}' 2>/dev/null | grep -c '^hold$')"
ok "the linked editor stays" there "$(gone "$LW")"
ok "tnotes was asked for the chat's editor" "toggle $NP" "$(cat "$OUT/tnotes.log" 2>/dev/null)"
has "...and the report says so" "notes beside $NP" "$out"

tm kill-session -t =ta-notes >/dev/null 2>&1
notes_park
CFG3="$ROOT/config-notes-off.yaml"
{ cat "$CFG"; printf '  notes: off\n'; } >"$CFG3"
transcript sid-notes-off
arow sid-notes-off "" 1 tatest-notesoff 0 0 Off "" "$NOR" "" 1 "" "" >"$SNAP/notes-off.tsv"
rm -f "$OUT/tnotes.log"
out=$(TA_CONFIG="$CFG3" run --resurrect --from "$SNAP/notes-off.tsv")
has "off: the chat is still restored" "✓ tatest-notesoff:0.0 Off" "$out"
ok "off: the first orphan is left"  there "$(gone "$O1")"
ok "off: the second orphan is left" there "$(gone "$O2")"
ok "off: tnotes is not asked" "" "$(cat "$OUT/tnotes.log" 2>/dev/null)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
