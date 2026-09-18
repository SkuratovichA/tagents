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
# The suite itself runs inside a real Claude session, which exports both of
# these: left in place, every hook run below would be classified against THAT
# session's ancestry instead of the fixture's.
unset CLAUDE_PID CLAUDE_CODE_SESSION_ID

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
# A TMUX SERVER OF ITS OWN, and both halves need it: the child cases below run
# against real panes on it, and the dashboard rows after them are read through
# it. NOTHING HERE MAY TOUCH THE DEFAULT TMUX SOCKET.
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

# ---------------------------------------------------------------------------
# CHILD SESSIONS: a `claude -p` an agent starts from its own Bash tool.
#
# The whole of the classification is ancestry, so the fixtures have to be real
# processes in a real ppid chain — a fake parent claude that starts a fake child
# claude that runs the hook, and panes on the private server whose occupant IS
# one of them. Both fakes are the same copy of /bin/sh named `claude`.
#
# The tmux shim of the hook half would fail every call, which is no good here:
# these runs must reach the PRIVATE server and nothing else. So a second shim
# FORWARDS instead — and refuses, loudly and in the log, any call made without a
# $TMUX to point it at a socket, which is the only way one of them could land on
# the default server.
# ---------------------------------------------------------------------------
SHIM2="$ROOT/shim2"; mkdir -p "$SHIM2"
TMUXLOG2="$ROOT/tmux-fwd.log"; : >"$TMUXLOG2"
PSLOG="$ROOT/ps.log"; : >"$PSLOG"
REALTMUX=$(command -v tmux)
cat >"$SHIM2/tmux" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMUXLOG2"
[ -n "\${TMUX:-}" ] || { printf 'DEFAULT-SOCKET %s\n' "\$*" >>"$TMUXLOG2"; exit 1; }
exec "$REALTMUX" "\$@"
EOF
# Every ps the hook makes, one line each: the walk is the expensive half and the
# hot path must not make one at all, which is not provable any other way.
cat >"$SHIM2/ps" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$PSLOG"
exec /bin/ps "\$@"
EOF
chmod +x "$SHIM2/tmux" "$SHIM2/ps"

# A repo of its own for the children: a child usually runs somewhere else
# than the agent that started it, and the name must not be a prefix of the
# parent's, or a group header would match both.
REPO2="$ROOT/kidrepo"; mkdir -p "$REPO2/.git"

# A fake PARENT claude: it writes its own pid down, waits for the go-ahead — so
# a record naming that pid can be in place before the child ever classifies
# itself — then runs the CHILD claude as a real child of its own and waits.
cat >"$ROOT/parent.sh" <<'EOS'
#!/bin/sh
printf '%s' "$$" >"$1"
if [ "$2" != - ]; then
  n=0
  while [ ! -e "$2" ] && [ "$n" -lt 400 ]; do n=$((n + 1)); sleep 0.05; done
fi
fin=$3
shift 3
"$@"
if [ "$fin" != - ]; then : >"$fin"; sleep 600; fi
EOS
# A fake CHILD claude. $CLAUDE_PID is its own pid, which is exactly what Claude
# Code exports to a hook, and the hook runs as its child.
cat >"$ROOT/kid.sh" <<'EOS'
#!/bin/sh
printf '%s' "$$" >"$1"
CLAUDE_PID=$$
export CLAUDE_PID
printf '%s' "$2" | sh "$3"
EOS
# A fake claude that IS a pane's own process and runs the hook itself: the
# ordinary case, the one that must never be read as somebody's child. It stays
# asleep afterwards so the pane keeps its occupant.
cat >"$ROOT/solo.sh" <<'EOS'
#!/bin/sh
printf '%s' "$$" >"$1"
if [ "$2" != - ]; then
  n=0
  while [ ! -e "$2" ] && [ "$n" -lt 400 ]; do n=$((n + 1)); sleep 0.05; done
fi
CLAUDE_PID=$$
export CLAUDE_PID
printf '%s' "$4" | sh "$5"
: >"$3"
sleep 600; :
EOS
# TWO CLAUDES IN ONE PANE: one asleep (a sibling suspended with ctrl-z) and one
# that execs over the pane's shell and so IS the pane's process. Reaching your
# own pane is what makes you not a child, however many of you are in it.
# The `; :' is not decoration: with a single command a shell execs it in place,
# so the sibling would be a `sleep' in the process table and no claude at all.
cat >"$ROOT/sibling.sh" <<'EOS'
#!/bin/sh
"$1" -c 'sleep 600; :' claude &
printf '%s' "$!" >"$3.sib"
exec "$1" "$2" "$3" "$4" "$5" "$6" "$7"
EOS
chmod +x "$ROOT/parent.sh" "$ROOT/kid.sh" "$ROOT/solo.sh" "$ROOT/sibling.sh"

PPIDF="$ROOT/parent.pid"; KPIDF="$ROOT/kid.pid"
GO="$ROOT/go"; FIN="$ROOT/fin"
PAYLOAD=""
FAMPID=""
KIDPANES=""

waitfor() {  # <file> — 20s at the outside; every producer here is milliseconds
  local n=0
  while [ ! -e "$1" ] && [ "$n" -lt 400 ]; do n=$((n + 1)); sleep 0.05; done
}
mkpay() {  # <event> <sid> [extra json] [cwd]
  PAYLOAD="{\"hook_event_name\":\"$1\",\"session_id\":\"$2\",\"cwd\":\"${4:-$REPO2}\",\"transcript_path\":\"$ROOT/t.jsonl\",\"source\":\"startup\"${3:-}}"
}
sum() { cksum <"${1:-/dev/null}" 2>/dev/null; }
prec() {  # <key> <sid> — a seven-field paned record, as the hook writes one
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$NOW0" working "$2" "$REPO" "" "Bash ls" "" >"$STATE/$1.tsv"
}
hrec10() {  # <key> <sid> <pid> <label> — a headless record, ten fields
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$NOW0" working "$2" "$REPO" "" "Bash ls" "" "$3" "" "$4" >"$STATE/$1.tsv"
}
crec12() {  # <key> <sid> <pid> <parent key> <parent sid>
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$NOW0" working "$2" "$REPO2" "" "Bash ls" "" "$3" "" "" "$4" "$5" \
    >"$STATE/$1.tsv"
}
# The family, with the test stepping in between the two processes.
family_start() {  # [env assignments...]
  rm -f "$PPIDF" "$KPIDF" "$GO" "$FIN"
  env PATH="$SHIM:$PATH" TMUX="$ROOT/no-such-socket,0,0" "$@" \
      "$BIN/claude" "$ROOT/parent.sh" "$PPIDF" "$GO" - \
      "$BIN/claude" "$ROOT/kid.sh" "$KPIDF" "$PAYLOAD" "$HOOK" &
  FAMPID=$!
  waitfor "$PPIDF"
}
family_go() { : >"$GO"; wait "$FAMPID" 2>/dev/null; }
# The hook run straight from the test shell under a fake child claude that does
# NOT descend from the pane whose $TMUX_PANE it was handed — the shape of the
# bug this is all about.
kidrun() {  # [env assignments...]
  rm -f "$KPIDF"
  env PATH="$SHIM2:$PATH" TMUX="$SOCK,0,0" "$@" \
      "$BIN/claude" "$ROOT/kid.sh" "$KPIDF" "$PAYLOAD" "$HOOK"
}
# ...and the hook with an explicit $CLAUDE_PID, for the events that are about
# the cache in the record rather than about the ancestry.
hookas() {  # <claude pid> [env assignments...]
  printf '%s' "$PAYLOAD" |
    env PATH="$SHIM2:$PATH" TMUX="$SOCK,0,0" CLAUDE_PID="$1" "${@:2}" sh "$HOOK"
}
# A window on the private server whose command is given verbatim. The pane id
# lands in $PANEID rather than on stdout: it is also remembered here so the
# whole lot can be torn down afterwards, and a command substitution would throw
# that half away with the subshell.
newpane() {  # <command> — sets PANEID
  PANEID=$(tm new-window -d -P -F '#{pane_id}' "$1" 2>/dev/null)
  KIDPANES="$KIDPANES $PANEID"
}

NOW0=$(date +%s)
rm -f "$STATE"/*.tsv "$STATE"/sub/* 2>/dev/null

# ---------------------------------------------------------------------------
t "H1. a child of a parent that has no pane either is filed under the parent"
# ---------------------------------------------------------------------------
# Rule 1(a): the only thing that names a pane-less parent is its own record, so
# the parent is found by the pid in field 8 of it.
mkpay SessionStart sid-c1
family_start TA_LABEL=ticket-agent
P1=$(cat "$PPIDF")
hrec10 "s-sid-p1h" sid-p1h "$P1" tg-orchestrator
BEFORE=$(sum "$STATE/s-sid-p1h.tsv")
family_go
C1="$STATE/s-sid-c1.tsv"
ok "the child is keyed by its own session, never the parent's file" 1 \
   "$([ -e "$C1" ] && echo 1 || echo 0)"
ok "it has twelve fields" 12 "$(nf "$C1")"
ok "the eleventh is the parent's record key" "s-sid-p1h" "$(field 11 "$C1")"
ok "the twelfth is the parent's session" sid-p1h "$(field 12 "$C1")"
ok "the eighth is still its own claude" "$(cat "$KPIDF")" "$(field 8 "$C1")"
ok "the parent's record is untouched, to the byte" "$BEFORE" \
   "$(sum "$STATE/s-sid-p1h.tsv")"
ok "a label of its own survives" ticket-agent "$(field 10 "$C1")"

# ---------------------------------------------------------------------------
t "H8. an inherited label names the parent, not the child"
# ---------------------------------------------------------------------------
mkpay SessionStart sid-c8
family_start TA_LABEL=tg-orchestrator
P8=$(cat "$PPIDF")
hrec10 "s-sid-p8" sid-p8 "$P8" tg-orchestrator
family_go
C8="$STATE/s-sid-c8.tsv"
ok "the parent's own name is not copied onto the child" "" "$(field 10 "$C8")"
ok "...nor into the history line" "" \
   "$(awk -F"$TAB" '$3 == "sid-c8" { print $5; exit }' "$H")"

mkpay SessionStart sid-c8b
family_start TA_LABEL=other
P8B=$(cat "$PPIDF")
hrec10 "s-sid-p8b" sid-p8b "$P8B" tg-orchestrator
family_go
ok "a name that is the child's own is kept" other \
   "$(field 10 "$STATE/s-sid-c8b.tsv")"

# ---------------------------------------------------------------------------
t "H1b. a child of an agent sitting in a pane is filed under that pane"
# ---------------------------------------------------------------------------
# Rule 1(b): the claude above us has no record of its own to be found by pid,
# but our chain walks straight through it into its pane.
rm -f "$STATE"/s-*.tsv
mkpay SessionStart sid-c2
rm -f "$PPIDF" "$KPIDF" "$GO" "$FIN"
newpane "exec env PATH='$SHIM2:$PATH' '$BIN/claude' '$ROOT/parent.sh' '$PPIDF' '$GO' '$FIN' '$BIN/claude' '$ROOT/kid.sh' '$KPIDF' '$PAYLOAD' '$HOOK'"
PN1=$PANEID
ok "the parent has a pane of its own" 1 \
   "$(printf '%s' "$PN1" | grep -c '^%[0-9]')"
waitfor "$PPIDF"
prec "${PN1#%}" sid-p2p
BEFORE=$(sum "$STATE/${PN1#%}.tsv")
: >"$GO"
waitfor "$FIN"
C2="$STATE/s-sid-c2.tsv"
ok "the child is keyed by its own session here too" 12 "$(nf "$C2")"
ok "the eleventh field is the parent's pane" "${PN1#%}" "$(field 11 "$C2")"
ok "the twelfth is the session in that pane" sid-p2p "$(field 12 "$C2")"
ok "the pane's own record is untouched" "$BEFORE" "$(sum "$STATE/${PN1#%}.tsv")"

# ---------------------------------------------------------------------------
t "H2. the bug itself: an inherited \$TMUX_PANE is not a pane of one's own"
# ---------------------------------------------------------------------------
rm -f "$STATE"/s-*.tsv
: >"$TMUXLOG2"
# `-c 'sleep 600'` alone is not a claude to ps: a shell execs the last command
# of a -c in place, so the process would rename itself `sleep` on the spot. A
# second command after it is what keeps the shell — and the name — alive.
newpane "exec '$BIN/claude' -c 'sleep 600; :'"
PN2=$PANEID; K2=${PN2#%}
prec "$K2" sid-p3p
printf '%s\tBash ls\n' "$NOW0" >"$STATE/sub/$K2.a1"
BEFORE=$(sum "$STATE/$K2.tsv")
mkpay SessionStart sid-c3
kidrun TMUX_PANE="$PN2"
C3="$STATE/s-sid-c3.tsv"
ok "the child got a record of its own" 12 "$(nf "$C3")"
ok "...pointing at the pane it inherited" "$K2" "$(field 11 "$C3")"
ok "...and at the session that really owns it" sid-p3p "$(field 12 "$C3")"
ok "the pane's record survived SessionStart" "$BEFORE" "$(sum "$STATE/$K2.tsv")"
for ev in PreToolUse Stop SessionEnd; do
  mkpay "$ev" sid-c3 ',"tool_name":"Bash"'
  kidrun TMUX_PANE="$PN2"
  ok "...and $ev" "$BEFORE" "$(sum "$STATE/$K2.tsv")"
done
ok "the parent's subagent record is still there" 1 \
   "$([ -e "$STATE/sub/$K2.a1" ] && echo 1 || echo 0)"
ok "the child's own record went with its SessionEnd" 0 \
   "$([ -e "$C3" ] && echo 1 || echo 0)"
ok "no state was mirrored onto the parent's pane" 0 \
   "$(grep -c "set -p -t $PN2 @agent" "$TMUXLOG2")"
ok "...and nothing was unset on it either" 0 "$(grep -c 'set -up' "$TMUXLOG2")"

# ---------------------------------------------------------------------------
t "H2b. an orphan is still a child of the pane it was handed"
# ---------------------------------------------------------------------------
# Rule 2 is about THIS session's chain, not about who is still alive in there.
rm -f "$STATE"/s-*.tsv
newpane "exec sleep 600"
PN3=$PANEID; K3=${PN3#%}
prec "$K3" sid-p4p
BEFORE=$(sum "$STATE/$K3.tsv")
mkpay SessionStart sid-c4
kidrun TMUX_PANE="$PN3"
ok "a pane with nobody left in it is still the parent" "$K3" \
   "$(field 11 "$STATE/s-sid-c4.tsv")"
ok "...and its record is untouched" "$BEFORE" "$(sum "$STATE/$K3.tsv")"

# ---------------------------------------------------------------------------
t "H3. a session that reaches its own pane is never a child"
# ---------------------------------------------------------------------------
rm -f "$STATE"/s-*.tsv
mkpay SessionStart sid-c5 "" "$REPO"
rm -f "$ROOT/solo.pid" "$ROOT/solo.go" "$ROOT/solo.fin"
newpane "exec env PATH='$SHIM2:$PATH' '$BIN/claude' '$ROOT/solo.sh' '$ROOT/solo.pid' '$ROOT/solo.go' '$ROOT/solo.fin' '$PAYLOAD' '$HOOK'"
PN4=$PANEID; K4=${PN4#%}
waitfor "$ROOT/solo.pid"
# The stale record goes in FIRST, or the hook would overwrite it and prove
# nothing: what is being asserted is that this session takes the pane back.
prec "$K4" sid-stale
: >"$ROOT/solo.go"
waitfor "$ROOT/solo.fin"
ok "the record is keyed by the pane" 7 "$(nf "$STATE/$K4.tsv")"
ok "...and names this session, not the stale one" sid-c5 "$(field 3 "$STATE/$K4.tsv")"
ok "nothing was filed under the session id" 0 \
   "$([ -e "$STATE/s-sid-c5.tsv" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
t "H3b. ...nor is one that shares its pane with a sibling"
# ---------------------------------------------------------------------------
mkpay SessionStart sid-c6 "" "$REPO"
rm -f "$ROOT/sib.pid" "$ROOT/sib.pid.sib" "$ROOT/sib.fin"
newpane "exec env PATH='$SHIM2:$PATH' '$BIN/claude' '$ROOT/sibling.sh' '$BIN/claude' '$ROOT/solo.sh' '$ROOT/sib.pid' - '$ROOT/sib.fin' '$PAYLOAD' '$HOOK'"
PN5=$PANEID; K5=${PN5#%}
waitfor "$ROOT/sib.fin"
# The premise first: the pane really does hold two processes the hook's walk
# would call claude. Without this the case passes for the wrong reason.
SIBPID=$(cat "$ROOT/sib.pid.sib" 2>/dev/null)
ok "the sibling is a claude in the process table" claude \
   "$(ps -o comm= -p "${SIBPID:-0}" 2>/dev/null | sed 's:.*/::')"
ok "...and so is the one that ran the hook" claude \
   "$(ps -o comm= -p "$(cat "$ROOT/sib.pid" 2>/dev/null || echo 0)" 2>/dev/null |
        sed 's:.*/::')"
ok "two claudes in one pane, and the pane is still the key" 7 "$(nf "$STATE/$K5.tsv")"
ok "...with this session in it" sid-c6 "$(field 3 "$STATE/$K5.tsv")"
ok "and nothing under the session id" 0 \
   "$([ -e "$STATE/s-sid-c6.tsv" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
t "H4. the answer is decided once and then read off the record"
# ---------------------------------------------------------------------------
rm -f "$STATE"/s-*.tsv
mkpay SessionStart sid-c3
kidrun TMUX_PANE="$PN2"
OWNPID=$(field 8 "$C3")
: >"$PSLOG"
mkpay PreToolUse sid-c3 ',"tool_name":"Bash","tool_input":{"command":"ls"}'
hookas "$OWNPID" TMUX_PANE="$PN2"
ok "the process table is not read at all on the hot path" 0 \
   "$(wc -l <"$PSLOG" | tr -d ' ')"
ok "the parent's key is carried forward" "$K2" "$(field 11 "$C3")"
ok "...and the parent's session with it" sid-p3p "$(field 12 "$C3")"
ok "...and the pid that owns the record" "$OWNPID" "$(field 8 "$C3")"
ok "while the state follows the event" working "$(field 2 "$C3")"
BEFORE=$(sum "$STATE/$K2.tsv")
: >"$PSLOG"
hookas 999999 TMUX_PANE="$PN2"
ok "a record owned by another pid is re-decided, not reused" 1 \
   "$([ -s "$PSLOG" ] && echo 1 || echo 0)"
ok "...and the pane's record is still not ours to write" "$BEFORE" \
   "$(sum "$STATE/$K2.tsv")"

# ---------------------------------------------------------------------------
t "H2c. a record lost mid-flight is decided again, not written over the pane"
# ---------------------------------------------------------------------------
rm -f "$C3"
BEFORE=$(sum "$STATE/$K2.tsv")
mkpay PreToolUse sid-c3 ',"tool_name":"Bash"'
hookas "$$" TMUX_PANE="$PN2"
ok "the child is a child again" "$K2" "$(field 11 "$C3")"
ok "and the pane's record is still untouched" "$BEFORE" "$(sum "$STATE/$K2.tsv")"
mkpay SessionEnd sid-c3
hookas "$$" TMUX_PANE="$PN2"
ok "its SessionEnd takes its own record and no other" 0 \
   "$([ -e "$C3" ] && echo 1 || echo 0)"
ok "...leaving the pane's where it was" "$BEFORE" "$(sum "$STATE/$K2.tsv")"

# ---------------------------------------------------------------------------
t "H7. a stale child record cannot re-adopt the session"
# ---------------------------------------------------------------------------
sleep 30 & STALEPID=$!
kill "$STALEPID" 2>/dev/null; wait "$STALEPID" 2>/dev/null
crec12 "s-sid-c7" sid-c7 "$STALEPID" "$K2" sid-p3p
mkpay SessionStart sid-c7 "" "$REPO"
rm -f "$ROOT/h7.pid" "$ROOT/h7.fin"
newpane "exec env PATH='$SHIM2:$PATH' '$BIN/claude' '$ROOT/solo.sh' '$ROOT/h7.pid' - '$ROOT/h7.fin' '$PAYLOAD' '$HOOK'"
PN6=$PANEID; K6=${PN6#%}
waitfor "$ROOT/h7.fin"
ok "the child record is gone" 0 \
   "$([ -e "$STATE/s-sid-c7.tsv" ] && echo 1 || echo 0)"
ok "...and the session is in its pane" sid-c7 "$(field 3 "$STATE/$K6.tsv")"

# ---------------------------------------------------------------------------
t "H9. a parent's SessionEnd takes its finished children with it"
# ---------------------------------------------------------------------------
rm -f "$STATE"/s-*.tsv
sleep 30 & DEADKID=$!
kill "$DEADKID" 2>/dev/null; wait "$DEADKID" 2>/dev/null
crec12 "s-sid-d" sid-d "$DEADKID" 9102 sid-par
crec12 "s-sid-l" sid-l "$$" 9102 sid-par
printf '%s\tBash ls\n' "$NOW0" >"$STATE/sub/s-sid-d.a1"
prec 9102 sid-par
mkpay SessionEnd sid-par
hookas "$$" TMUX_PANE=%9102
ok "the finished child's record went with the parent" 0 \
   "$([ -e "$STATE/s-sid-d.tsv" ] && echo 1 || echo 0)"
ok "...and its subagent files" 0 \
   "$([ -e "$STATE/sub/s-sid-d.a1" ] && echo 1 || echo 0)"
ok "a child still running is kept" 1 \
   "$([ -e "$STATE/s-sid-l.tsv" ] && echo 1 || echo 0)"
ok "and the parent's own record is gone" 0 \
   "$([ -e "$STATE/9102.tsv" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
t "H6. the history says which lines belong to a child"
# ---------------------------------------------------------------------------
ok "a child's pane column is empty" "" \
   "$(awk -F"$TAB" '$3 == "sid-c3" && $2 == "start" { print $4; exit }' "$H")"
ok "...and its seventh column is the parent's session" sid-p3p \
   "$(awk -F"$TAB" '$3 == "sid-c3" && $2 == "start" { print $7; exit }' "$H")"
ok "an end line carries it too" sid-p3p \
   "$(awk -F"$TAB" '$3 == "sid-c3" && $2 == "end" { print $7; exit }' "$H")"
ok "a session with a pane still writes six fields and no more" 6 \
   "$(awk -F"$TAB" '$3 == "sid-c5" { print NF; exit }' "$H")"
ok "...with the pane where it always was" "$PN4" \
   "$(awk -F"$TAB" '$3 == "sid-c5" { print $4; exit }' "$H")"

ok "nothing here ever reached for the default tmux socket" 0 \
   "$(grep -c 'DEFAULT-SOCKET' "$TMUXLOG2")"

# The child half is done with: its panes would otherwise read as live agents in
# every list below, and its records as rows.
for p in $KIDPANES; do tm kill-window -t "$p" >/dev/null 2>&1; done
rm -f "$STATE"/*.tsv "$STATE"/sub/* 2>/dev/null
sleep 0.3

# ---------------------------------------------------------------------------
# the dashboard half: rows built by hand, read through the server above
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# CHILDREN ON THE DASHBOARD: rows written by hand, under a parent that is real
# ---------------------------------------------------------------------------
rm -f "$STATE"/*.tsv "$STATE"/sub/* 2>/dev/null
NOW=$(date +%s)

crec() {  # <sid> <state> <pid> <label> <parent key> <parent sid> [age] [cwd] [transcript]
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(( NOW - ${7:-0} ))" "$2" "$1" "${8:-$REPO2}" "${9:-}" "Bash ls" "" \
    "$3" "" "$4" "$5" "$6" >"$STATE/s-$1.tsv"
}
prec2() {  # <key> <sid> — the record of a session that owns a pane
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$NOW" working "$2" "$REPO" "" "Read main.c" "" >"$STATE/$1.tsv"
}
rowfor() {  # <pane key> — the whole row, tabs intact, colours stripped
  TA_COLS=130 run --list | plain |
    awk -F"$TAB" -v p="$1" '$1 == p && index($2, "▾") == 0 { print; exit }'
}
hdrfor() {  # <group basename> — the group header row, colours stripped
  TA_COLS=130 run --list | plain |
    awk -F"$TAB" -v n="▾ $1 " 'index($2, n) > 0 { print; exit }'
}
# Every ROW key in the order they come out, headers left out: a header carries
# the pane key of its most urgent member too, and would be read as a second row.
order() {
  TA_COLS=130 run --list | plain |
    awk -F"$TAB" 'index($2, "▾") == 0 { printf "%s ", $1 }'
}
# Like run(), but through the forwarding shim, so every tmux call it makes —
# display-message included — is a line in a file to assert on.
actlog() { env PATH="$SHIM2:$PATH" TMUX="$SOCK,0,0" bash "$TA" "$@"; }

# The parent: a real fake claude in a real pane, so live_panes sees it the way
# it sees any agent, and a record of its own beside it.
newpane "exec '$BIN/claude' -c 'sleep 600; :'"
MUM=$PANEID; MUMK=${MUM#%}
prec2 "$MUMK" sid-mum
sleep 0.3

# A transcript with the shape a real one has: the title the session gave itself,
# a prompt, a reply with a text block and a tool call — and a HALF-WRITTEN last
# line, which is the normal state of a file something is still appending to.
KIDTR="$ROOT/kid.jsonl"
{
  printf '%s\n' '{"type":"ai-title","aiTitle":"the nightly sweep"}'
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"sweep the queue"}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"swept, nothing left"},{"type":"tool_use","name":"Bash","input":{"command":"ls -la /queue"}}]}}'
  printf '%s' '{"type":"assistant","message":{"content":[{"type":"te'
} >"$KIDTR"

crec kid1 working "$$" "" "$MUMK" sid-mum 0 "$REPO2" "$KIDTR"

# ---------------------------------------------------------------------------
t "D1. a child renders under the agent that started it"
# ---------------------------------------------------------------------------
KIDROW=$(rowfor "%s-kid1")
MUMROW=$(rowfor "$MUM")
ok "the child sits directly under its parent" "$MUM %s-kid1" \
   "$(order | awk '{ for (i = 1; i <= NF; i++) if ($i == "'"$MUM"'") print $i, $(i+1) }')"
ok "...in the group of the parent, not of its own repo" "$REPO" \
   "$(printf '%s' "$KIDROW" | awk -F"$TAB" '{ print $5 }')"
has "the parent draws the tee it always drew" "  └─ " "$MUMROW"
has "and the child hangs one level deeper" "     └─ " "$KIDROW"
has "the location column says what it is" "child" "$KIDROW"
has "...and the detail still names the repo it actually runs in" "kidrepo" "$KIDROW"

# ---------------------------------------------------------------------------
t "D1b. flat is flat"
# ---------------------------------------------------------------------------
FKID=$(TA_COLS=130 TA_FLAT=1 run --list | plain |
         awk -F"$TAB" '$1 == "%s-kid1" { print; exit }')
ok "the child keeps its own group" "$REPO2" \
   "$(printf '%s' "$FKID" | awk -F"$TAB" '{ print $5 }')"
hasnt "and there is no tree to hang it in" "└─" "$FKID"
has "only the column that says what it is" "child" "$FKID"

# ---------------------------------------------------------------------------
t "D2. the header stands in for the parent, and counts the child"
# ---------------------------------------------------------------------------
ok "the header names a pane somebody can be sent to" "$MUM" \
   "$(hdrfor repo | awk -F"$TAB" '{ print $1 }')"
has "the parent shows what is fanned out under it" "⑂1" "$(rowfor "$MUM")"
crec kid1 blocked "$$" "" "$MUMK" sid-mum 0 "$REPO2" "$KIDTR"
has "a blocked child is a blocked group" "⚠1" "$(hdrfor repo)"
ok "...and the header is still the parent" "$MUM" \
   "$(hdrfor repo | awk -F"$TAB" '{ print $1 }')"
crec kid1 working "$$" "" "$MUMK" sid-mum 0 "$REPO2" "$KIDTR"

# ---------------------------------------------------------------------------
t "D3. nothing that needs a pane is attempted on a child either"
# ---------------------------------------------------------------------------
: >"$TMUXLOG2"
WINS=$(tm list-windows -a -F x 2>/dev/null | wc -l | tr -d ' ')
for verb in open beside goto send rename; do
  actlog --act "$verb" "%s-kid1" working kid1 "$REPO2" >/dev/null 2>&1
  ok "--act $verb is refused quietly" 0 "$?"
done
ok "every one of them said it was a child" 5 \
   "$(grep -c 'child session' "$TMUXLOG2")"
ok "and none of them opened a window" "$WINS" \
   "$(tm list-windows -a -F x 2>/dev/null | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
t "D4. the preview of a child is its transcript"
# ---------------------------------------------------------------------------
PV=$(run --preview "%s-kid1" working | plain)
has "it says whose session this is" "parent:" "$PV"
has "...by the name the parent row shows" "parent: repo" "$PV"
has "...and by its record key" "($MUMK)" "$PV"
has "with no log there is the transcript" "child session" "$PV"
has "the tool calls are in it" "▸ Bash" "$PV"
has "...and what was said" "swept, nothing left" "$PV"
hasnt "a half-written last line takes nothing with it" "error" "$PV"
# ...and a child that DOES have a log is previewed from the log, as before.
crec kid1 working "$$" "" "$MUMK" sid-mum 0 "$REPO2" "$KIDTR"
awk -F"$TAB" -v OFS="$TAB" -v l="$LOG" \
    'NR==1 { $9 = l; print }' "$STATE/s-kid1.tsv" >"$ROOT/tmp.tsv" &&
  mv "$ROOT/tmp.tsv" "$STATE/s-kid1.tsv"
PV=$(run --preview "%s-kid1" working | plain)
has "a log still wins over the transcript" "the daemon said hello" "$PV"
crec kid1 working "$$" "" "$MUMK" sid-mum 0 "$REPO2" "$KIDTR"

# ---------------------------------------------------------------------------
t "D9. a child is called what the session called itself"
# ---------------------------------------------------------------------------
has "the ai-title is the name" "the nightly sweep" "$(rowfor "%s-kid1")"
ok "...and it is worked out once" "the nightly sweep" \
   "$(awk -F"$TAB" '$1 == "kid1" { print $2; exit }' "$STATE/title.tsv")"
# A transcript with no title of its own is a miss, and a miss is cached too —
# otherwise every repaint re-reads two hundred lines of it for the same answer.
printf '%s\n' '{"type":"user","message":{"content":"nothing to see"}}' >"$ROOT/plain.jsonl"
crec kid2 working "$$" "" "$MUMK" sid-mum 0 "$REPO2" "$ROOT/plain.jsonl"
rowfor "%s-kid2" >/dev/null
ok "a title that is not there is remembered as not there" "-" \
   "$(awk -F"$TAB" '$1 == "kid2" { print $2; exit }' "$STATE/title.tsv")"
ok "...once, not once per repaint" 1 \
   "$(awk -F"$TAB" '$1 == "kid2"' "$STATE/title.tsv" | wc -l | tr -d ' ')"
rowfor "%s-kid2" >/dev/null
ok "...still once after another look" 1 \
   "$(awk -F"$TAB" '$1 == "kid2"' "$STATE/title.tsv" | wc -l | tr -d ' ')"
# A session that is still talking has a bigger transcript on every repaint, and
# that alone must not buy another read: the title record is near the top, so a
# few new bytes at the end cannot have put one there.
SZ0=$(awk -F"$TAB" '$1 == "kid2" { print $3; exit }' "$STATE/title.tsv")
printf '%s\n' '{"type":"user","message":{"content":"still nothing"}}' >>"$ROOT/plain.jsonl"
rowfor "%s-kid2" >/dev/null
ok "a growing transcript does not multiply the rows" 1 \
   "$(awk -F"$TAB" '$1 == "kid2"' "$STATE/title.tsv" | wc -l | tr -d ' ')"
ok "...nor buy it another read" "$SZ0" \
   "$(awk -F"$TAB" '$1 == "kid2" { print $3; exit }' "$STATE/title.tsv")"
has "and the row falls back to the directory" "kidrepo" "$(rowfor "%s-kid2")"
rm -f "$STATE/s-kid2.tsv"

# ---------------------------------------------------------------------------
t "D8. the status bar counts a working child like any other agent"
# ---------------------------------------------------------------------------
has "the child is in the totals" "●2" "$(run --counts)"

# ---------------------------------------------------------------------------
t "D10. a grandchild joins the family, it does not start a third level"
# ---------------------------------------------------------------------------
crec kid3 working "$$" "" "s-kid1" kid1 0 "$REPO2" ""
ORD=$(order)
ok "the whole family is one block under the pane" "$MUM %s-kid1 %s-kid3 " \
   "$(printf '%s' "$ORD" | awk '{ for (i = 1; i <= NF; i++) if ($i == "'"$MUM"'") printf "%s %s %s ", $i, $(i+1), $(i+2) }')"
has "the grandchild hangs beside its parent, not under it" "     └─ " \
   "$(rowfor "%s-kid3")"
has "...which now has a sibling below it" "     ├─ " "$(rowfor "%s-kid1")"
ok "...and it is in the group of the pane" "$REPO" \
   "$(rowfor "%s-kid3" | awk -F"$TAB" '{ print $5 }')"
rm -f "$STATE/s-kid3.tsv"

# ---------------------------------------------------------------------------
t "D6. a child whose parent is nowhere renders on its own, as it always did"
# ---------------------------------------------------------------------------
crec orphan working "$$" "" 9109 sid-nobody 0 "$REPO2" ""
OROW=$(rowfor "%s-orphan")
ok "it is back in its own group" "$REPO2" \
   "$(printf '%s' "$OROW" | awk -F"$TAB" '{ print $5 }')"
has "at the top level of it" "  └─ " "$OROW"
has "...and still says what it is" "child" "$OROW"
rm -f "$STATE/s-orphan.tsv"

# ---------------------------------------------------------------------------
t "D6b. ...and so does one whose parent is on file but not on the list"
# ---------------------------------------------------------------------------
# A parent record more than a day old is past DEAD_TTL and draws no row. Nesting
# was decided against the records rather than against the rows, so the child was
# filed in a group with no header of its own and charged the deeper tee's three
# columns of detail — and then drawn at the top level anyway.
agenorm() { sed 's/[0-9]*:[0-9][0-9]/AGE/g'; }
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(( NOW - 86410 ))" done sid-ghost "$REPO" "" "Read main.c" "" >"$STATE/9107.tsv"
crec ghostkid working "$$" "" 9107 sid-ghost 0 "$REPO2" ""
GROW=$(rowfor "%s-ghostkid" | agenorm)
ok "it is in its own group" "$REPO2" \
   "$(printf '%s' "$GROW" | awk -F"$TAB" '{ print $5 }')"
has "at the top level of it" "  └─ " "$GROW"
has "...and still says what it is" "child" "$GROW"
rm -f "$STATE/9107.tsv"
ok "the row is the one it draws with no such record at all" \
   "$(rowfor "%s-ghostkid" | agenorm)" "$GROW"
rm -f "$STATE/s-ghostkid.tsv"

# ---------------------------------------------------------------------------
t "D7. a dead child says so, and does not linger for a day"
# ---------------------------------------------------------------------------
crec kidx done "$DEADPID" "" "$MUMK" sid-mum 0 "$REPO2" ""
DROW=$(rowfor "%s-kidx")
has "a dead pid reads as closed here too" "✗ closed" "$DROW"
has "and says why there is nothing to press" "child ended" "$DROW"
hasnt "...rather than offering a resume" "enter resumes it" "$DROW"
# An hour old: past SUB_TTL, nowhere near DEAD_TTL.
crec kidold done "$DEADPID" "" "$MUMK" sid-mum 3600 "$REPO2" ""
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(( NOW - 3600 ))" done sid-oldh "$REPO" "" "Bash ls" "" "$DEADPID" "" iteration \
  >"$STATE/s-sid-oldh.tsv"
ROWS=$(order)
hasnt "a dead child expires on the subagent clock" "%s-kidold " "$ROWS"
has "while a dead headless of the same age is still offered" "%s-sid-oldh " "$ROWS"
rm -f "$STATE/s-kidx.tsv" "$STATE/s-kidold.tsv" "$STATE/s-sid-oldh.tsv"

# ---------------------------------------------------------------------------
t "D5. a child is not a conversation to come back to"
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/.claude"
printf '%s\tstart\tsid-mum\t%s\tmum\t%s\n' "$(( NOW - 3600 ))" "$MUM" "$REPO" >"$H"
printf '%s\tstart\tkid-done\t\tsweeper\t%s\tsid-mum\n' "$(( NOW - 3000 ))" "$REPO2" >>"$H"
printf '%s\tend\tkid-done\t\tsweeper\t%s\tsid-mum\n' "$(( NOW - 2400 ))" "$REPO2" >>"$H"
# The control: an ordinary ended session, six columns and no parent, which must
# still be offered — the suppression has to be about children and nothing else.
printf '%s\tstart\tsid-plain\t%%9108\tnightly\t%s\n' "$(( NOW - 3000 ))" "$REPO" >>"$H"
printf '%s\tend\tsid-plain\t%%9108\tnightly\t%s\n' "$(( NOW - 2400 ))" "$REPO" >>"$H"
# ...and a prompt line for it in an account history, which is the other half of
# what the picker joins: neither half may put a child back on the list.
printf '{"sessionId":"kid-done","timestamp":%s000,"project":"%s","display":"sweep the queue"}\n' \
  "$(( NOW - 3000 ))" "$REPO2" >"$ROOT/.claude/history.jsonl"
CR=$(HOME="$ROOT" run --closed-rows)
hasnt "an ended child is not offered for resume" "kid-done$TAB" "$CR"
has "while an ordinary ended session still is" "sid-plain$TAB" "$CR"
TL=$(COLUMNS=120 HOME="$ROOT" run --timeline | plain)
has "the timeline still draws the child" "sweeper" "$TL"
has "...marked as the work of another agent" "↳ sweeper" "$TL"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
