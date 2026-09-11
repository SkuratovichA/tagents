#!/usr/bin/env bash
#
# tests/headless.sh — sessions with no pane at all. A `claude -p` started by a
# daemon, a launchd job or a nohup fires exactly the same hooks as an agent you
# opened yourself; the hook used to throw the record away at its pane check,
# which is why the busiest agents on the machine were invisible.
#
# Two halves, with two different ways of keeping away from the real tmux.
#
# THE HOOK HALF needs no server at all: it runs the hook with $TMUX pointed at a
# socket that does not exist and a logging `tmux` shim first on $PATH. The shim
# is the assertion surface — every tmux call the hook makes is a line in a file,
# which is how "no pane option is ever set for a pane-less session" is proved —
# and the dead socket is the safety net under it, so a vanished shim cannot
# reach the real server either. The shim is on the PATH of those runs ONLY.
#
# THE DASHBOARD HALF is the usual shape: a tmux server of its own (`tmux -L
# tatest-$$ -f /dev/null`), tagents pointed at it through an exported $TMUX.
# NOTHING HERE MAY TOUCH THE DEFAULT TMUX SOCKET.
#
# The fake claude is a copy of /bin/sh named `claude`: ps then reports the
# process as `claude` (macOS ps names the binary, which is why a #!/bin/sh
# script called claude is an `sh` to everything that looks) and it can still run
# the hook as its own child. That is what proves the pid the hook records is the
# claude process rather than whatever shell the hook was started from.
#
# bash 3.2, runnable from any cwd, non-zero exit on any failing check.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TA="$HERE/../tagents"
HOOK="$HERE/../hooks/tmux-agent-state.sh"

command -v tmux >/dev/null 2>&1 || { echo "headless.sh: no tmux"; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "headless.sh: no jq"; exit 1; }

S=tatest-$$
SOCK=""
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tagents-headless.XXXXXX") || exit 1
ROOT=$(cd "$ROOT" && pwd -P) || exit 1
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

TAB=$(printf '\t')

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------
BIN="$ROOT/bin";     mkdir -p "$BIN"
SHIM="$ROOT/shim";   mkdir -p "$SHIM"
STATE="$ROOT/state"; mkdir -p "$STATE"
REPO="$ROOT/repo";   mkdir -p "$REPO/.git"
TMUXLOG="$ROOT/tmux.log"
: >"$TMUXLOG"

# The fake claude: a copy of /bin/sh, so it is a `claude` to ps and a shell to
# us. Re-signed because a copy of a system binary is killed on sight on arm64,
# its signature being valid only for the original inode (see tests/panes.sh).
cp /bin/sh "$BIN/claude" || exit 1
codesign --remove-signature "$BIN/claude" >/dev/null 2>&1
codesign -f -s - "$BIN/claude" >/dev/null 2>&1
"$BIN/claude" -c 'exit 0' >/dev/null 2>&1 ||
  { echo "headless.sh: cannot build a stub claude (codesign?)"; exit 1; }
printf '#!/bin/sh\nexit 0\n' >"$BIN/tusage"
chmod +x "$BIN/tusage"

# Every argument of every tmux call the hook makes, one line each, and no tmux
# at all underneath it: the hook must survive its tmux failing anyway (a
# headless session usually has no server to talk to).
cat >"$SHIM/tmux" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMUXLOG"
exit 1
EOF
chmod +x "$SHIM/tmux"

export PATH="$BIN:$PATH"
export TA_STATE_DIR="$STATE"
export TA_SESSION=tatest-dash
export TA_CONFIG=/nonexistent/config.yaml   # no profiles: no dialog anywhere
unset TMUX TMUX_PANE TA_MODE TA_FLAT TA_COLS TA_NEW_CMD TA_RESUME_CMD TA_HOME
unset CLAUDE_CONFIG_DIR TA_LABEL TA_LOG

LOG="$ROOT/ticket-agent.log"
printf 'the daemon said hello\nand then it said goodbye\n' >"$LOG"

field() {  # <n> <state file>
  awk -F"$TAB" -v n="$1" 'NR==1 { print $n; exit }' "$2" 2>/dev/null
}
nf() { awk -F"$TAB" 'NR==1 { print NF; exit }' "$1" 2>/dev/null; }

# A hook run with no pane anywhere: no $TMUX_PANE, a $TMUX that resolves to
# nothing, and the shim on $PATH. It runs INSIDE the fake claude, whose own pid
# it writes down, so the recorded pid can be compared against it.
CLPID="$ROOT/claude.pid"
hless() {  # <event> <session id> [extra json] [env assignments...]
  local ev=$1 sid=$2 extra=${3:-} payload
  shift 3 2>/dev/null || shift $#
  payload="{\"hook_event_name\":\"$ev\",\"session_id\":\"$sid\",\"cwd\":\"$REPO\",\"transcript_path\":\"$ROOT/t.jsonl\",\"source\":\"startup\"$extra}"
  env PATH="$SHIM:$PATH" TMUX="$ROOT/no-such-socket,0,0" "$@" \
    "$BIN/claude" -c 'printf %s "$1" | sh "$2"; printf %s "$$" >"$3"' \
    claude "$payload" "$HOOK" "$CLPID"
}

# ---------------------------------------------------------------------------
t "1. the hook records a session that has no pane"
# ---------------------------------------------------------------------------
hless SessionStart sid-h1 "" TA_LABEL=ticket-agent TA_LOG="$LOG" \
      CLAUDE_CONFIG_DIR="$ROOT/.claude-work"
F="$STATE/s-sid-h1.tsv"

ok "the record is keyed by session id" 1 "$([ -e "$F" ] && echo 1 || echo 0)"
ok "...and nothing is keyed by a pane" 0 \
   "$(ls "$STATE" | grep -c '^[0-9][0-9]*\.tsv$')"
ok "it has ten fields" 10 "$(nf "$F")"
ok "state" new "$(field 2 "$F")"
ok "session id" sid-h1 "$(field 3 "$F")"
ok "cwd" "$REPO" "$(field 4 "$F")"
ok "the account is still the seventh" "$ROOT/.claude-work" "$(field 7 "$F")"
ok "the eighth field is the claude process" "$(cat "$CLPID")" "$(field 8 "$F")"
ok "the ninth is TA_LOG" "$LOG" "$(field 9 "$F")"
ok "the tenth is TA_LABEL" ticket-agent "$(field 10 "$F")"

ok "no pane option is set for a pane that does not exist" 0 \
   "$(grep -c '^set ' "$TMUXLOG")"
has "the only thing asked of tmux is the pane map" "list-panes" "$(cat "$TMUXLOG")"

# ---------------------------------------------------------------------------
t "2. the timeline gets its lines"
# ---------------------------------------------------------------------------
H="$STATE/history.tsv"
ok "one line, six fields" 6 "$(nf "$H")"
ok "the event" start "$(field 2 "$H")"
ok "the session" sid-h1 "$(field 3 "$H")"
ok "the pane column is empty, there being no pane" "" "$(field 4 "$H")"
ok "TA_LABEL names it" ticket-agent "$(field 5 "$H")"
ok "and the cwd is the launch directory" "$REPO" "$(field 6 "$H")"

hless Stop sid-h1 "" TA_LABEL=ticket-agent TA_LOG="$LOG"
ok "a finished turn is logged too" turn "$(awk -F"$TAB" 'NR==2 { print $2 }' "$H")"
ok "...and the state file follows it" done "$(field 2 "$F")"

# ---------------------------------------------------------------------------
t "3. subagents of a headless session"
# ---------------------------------------------------------------------------
hless PreToolUse sid-h1 ',"agent_id":"a1","tool_name":"Bash"' TA_LOG="$LOG"
ok "a subagent record lands under the session key" 1 \
   "$([ -e "$STATE/sub/s-sid-h1.a1" ] && echo 1 || echo 0)"
hless SubagentStop sid-h1 ',"agent_id":"a1"' TA_LOG="$LOG"
ok "...and SubagentStop takes it away" 0 \
   "$([ -e "$STATE/sub/s-sid-h1.a1" ] && echo 1 || echo 0)"
ok "a subagent event writes no history line" 2 "$(wc -l <"$H" | tr -d ' ')"

# ---------------------------------------------------------------------------
t "4. a session with a pane is untouched by any of it"
# ---------------------------------------------------------------------------
: >"$TMUXLOG"
printf '%s' "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"sid-p1\",\"cwd\":\"$REPO\",\"transcript_path\":\"\",\"prompt\":\"hello\"}" |
  env PATH="$SHIM:$PATH" TMUX="$ROOT/no-such-socket,0,0" TMUX_PANE=%9101 \
      TA_LABEL=ticket-agent TA_LOG="$LOG" sh "$HOOK"
ok "a paned record still has seven fields and no more" 7 "$(nf "$STATE/9101.tsv")"
ok "...none of them TA_LOG" "" "$(field 9 "$STATE/9101.tsv")"
ok "...and the pane option is still set" 1 \
   "$(grep -c '^set -p -t %9101 @agent working$' "$TMUXLOG")"
ok "the pane map is not even asked for when TMUX_PANE is set" 0 \
   "$(grep -c 'list-panes' "$TMUXLOG")"
rm -f "$STATE/9101.tsv"

# ---------------------------------------------------------------------------
t "5. SessionEnd drops the record, with no pane to unset anything on"
# ---------------------------------------------------------------------------
: >"$TMUXLOG"
hless SessionEnd sid-h1 "" TA_LOG="$LOG"
ok "the record is gone" 0 "$([ -e "$F" ] && echo 1 || echo 0)"
ok "the end is in the history" end "$(awk -F"$TAB" 'NR==3 { print $2 }' "$H")"
ok "and nothing was unset on a pane" 0 "$(grep -c '@agent' "$TMUXLOG")"

# ---------------------------------------------------------------------------
# the dashboard half: a tmux server of its own, and rows built by hand
# ---------------------------------------------------------------------------
tm() { tmux -L "$S" "$@"; }
tm -f /dev/null new-session -d -s tatest-dash -x 200 -y 50 'sleep 600' || exit 1
tm set -g default-shell /bin/sh >/dev/null 2>&1
tm set -g default-command '' >/dev/null 2>&1
SOCK=$(tm display -p '#{socket_path}' 2>/dev/null)
[ -n "$SOCK" ] || { echo "headless.sh: no socket for $S"; exit 1; }
# A client on a pty, so display-message has somewhere to go. Its stdin is a
# sleep, so it never reads EOF and detaches by itself; the sleep is orphaned
# deliberately and reaped by pid from the trap.
( { sleep 300 & printf '%s\n' "$!" >"$ROOT/keeper.pid"; wait; } |
    script -q /dev/null tmux -L "$S" attach -t tatest-dash >/dev/null 2>&1 & ) >/dev/null 2>&1
sleep 0.5

run() { env TMUX="$SOCK,0,0" bash "$TA" "$@"; }
plain() { LC_ALL=C sed 's/\x1b\[[0-9;]*m//g'; }
row_of() {  # <pane key> — the rendered row for it, colours stripped
  # Not the group header: it carries the pane key of its most urgent member too,
  # so matching on the key alone finds the header first (see counts(), which
  # skips it by the same marker).
  TA_COLS=130 run --list |
    awk -F"$TAB" -v p="$1" \
        '$1 == p && index($2, "\342\226\276") == 0 { print $2; exit }' | plain
}

# A live headless session is one whose recorded pid is alive: this very shell
# will do, and a pid that has been waited on is the surest dead one there is.
sleep 30 & DEADPID=$!
kill "$DEADPID" 2>/dev/null; wait "$DEADPID" 2>/dev/null
NOW=$(date +%s)
hrec() {  # <sid> <state> <pid> <log> <label>
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$NOW" "$2" "$1" "$REPO" "" "Bash ls" "" "$3" "$4" "$5" >"$STATE/s-$1.tsv"
}
hrec live working "$$" "$LOG" ticket-agent
hrec gone done "$DEADPID" "" iteration

# ---------------------------------------------------------------------------
t "6. a live headless row shows what it is doing"
# ---------------------------------------------------------------------------
LIVEROW=$(row_of "%s-live")
has "the state is the one the record says" "● working" "$LIVEROW"
has "TA_LABEL is the name" "ticket-agent" "$LIVEROW"
has "the location column says there is no pane" "headless" "$LIVEROW"
has "the detail is the hook detail" "Bash ls" "$LIVEROW"

# ---------------------------------------------------------------------------
t "7. a headless row whose process is gone is closed, and not resumable"
# ---------------------------------------------------------------------------
DEADROW=$(row_of "%s-gone")
has "a dead pid reads as closed" "✗ closed" "$DEADROW"
has "and says why enter will not help" "nothing to resume" "$DEADROW"
hasnt "...rather than offering a resume" "enter resumes it" "$DEADROW"
ok "the closed one sorts below the live one" "%s-live" \
   "$(TA_COLS=130 TA_FLAT=1 run --list | awk -F"$TAB" '$3 != "" { print $1; exit }')"

# ---------------------------------------------------------------------------
t "8. the status bar counts them"
# ---------------------------------------------------------------------------
CNT=$(run --counts)
has "a working headless session is in the totals" "●1" "$CNT"
hrec live blocked "$$" "$LOG" ticket-agent
has "so is a blocked one" "⚠1" "$(run --counts)"
hrec live working "$$" "$LOG" ticket-agent

# ---------------------------------------------------------------------------
t "9. the preview is the log, there being no pane to capture"
# ---------------------------------------------------------------------------
PV=$(run --preview "%s-live" working | plain)
has "the record is still summarised" "session live" "$PV"
has "the log is named" "$LOG" "$PV"
has "...and tailed" "the daemon said hello" "$PV"
PV=$(run --preview "%s-gone" dead | plain)
has "with no TA_LOG it says so" "no pane" "$PV"
hasnt "...and never offers the resume command" "enter runs" "$PV"

# ---------------------------------------------------------------------------
t "10. nothing that needs a pane is attempted on a headless row"
# ---------------------------------------------------------------------------
PANES=$(tm list-panes -a -F '#{pane_id}' | wc -l | tr -d ' ')
for verb in open beside borrow goto send rename; do
  run --act "$verb" "%s-live" working live "$REPO" >/dev/null 2>&1
  ok "--act $verb is refused quietly" 0 "$?"
done
ok "no pane was created, moved or docked" "$PANES" \
   "$(tm list-panes -a -F '#{pane_id}' | wc -l | tr -d ' ')"
ok "and nothing is docked into the dashboard" 0 \
   "$(tm list-panes -a -F '#{?@tagents_docked,1,}' | grep -c 1)"

# ---------------------------------------------------------------------------
t "11. the timeline draws them"
# ---------------------------------------------------------------------------
printf '%s\tstart\tlive\t\tticket-agent\t%s\n' "$((NOW - 1800))" "$REPO" >"$H"
printf '%s\tturn\tlive\t\tticket-agent\t%s\n'  "$((NOW - 600))"  "$REPO" >>"$H"
printf '%s\tstart\tgone\t\titeration\t%s\n'    "$((NOW - 3600))" "$REPO" >>"$H"
printf '%s\tend\tgone\t\titeration\t%s\n'      "$((NOW - 900))"  "$REPO" >>"$H"
TL=$(COLUMNS=120 run --timeline | plain)
has "the running one is named" "ticket-agent" "$TL"
has "...and reads as still going" "now" "$TL"
has "the finished one is there too" "iteration" "$TL"

# ---------------------------------------------------------------------------
t "12. a headless session that is still running is not a closed one"
# ---------------------------------------------------------------------------
# $HOME is moved out of the way: closed_rows joins the state against every
# account history.jsonl it can find, and this suite has no business reading the
# real ones (or waiting for them).
CR=$(HOME="$ROOT" run --closed-rows)
hasnt "the live one is not offered for resume" "live$TAB" "$CR"
has "the ended one is" "gone$TAB" "$CR"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
