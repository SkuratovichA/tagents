#!/usr/bin/env bash
#
# tests/launch.sh — starting and resuming agents, end to end, against a tmux
# server of its own.
#
# NOTHING HERE MAY TOUCH THE DEFAULT TMUX SOCKET. The server is created with
# `tmux -L tatest-$$ -f /dev/null` and torn down in the trap, and tagents is
# pointed at it by exporting $TMUX in the test process — never by putting a
# `tmux` shim on $PATH, which has already once let a test relocate a real pane
# when the shim went missing.
#
# `claude` is a stub, first on $PATH BEFORE the server starts, because a window
# opened by the server inherits the server's environment and nothing later can
# change it. The stub records the account it was started on, its arguments and
# its cwd into a file named after its pane, then sleeps: that file is the whole
# assertion surface.
#
# bash 3.2, runnable from any cwd, non-zero exit on any failing check.

set -uo pipefail

# The keeper client below attaches through `script`, and a tmux client with no
# $TERM cannot open its terminal: a worker started without one (a launchd job,
# an `env -i`) would run every check against a server nobody is attached to.
# bash sets an unexported TERM=dumb when it starts without one, so "dumb" is
# the missing case too: ${TERM:-...} kept it, and the keeper failed with
# "open terminal failed: terminal does not support clear".
[ "${TERM:-dumb}" = dumb ] && TERM=xterm-256color
export TERM

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# A suite that is not run against a scratch default server aborts here, before it can reach the live one (tests/scratch-guard.sh).
. "$HERE/scratch-guard.sh" && scratch_guard launch.sh || exit 1
TA="$HERE/../tagents"
HOOK="$HERE/../hooks/tmux-agent-state.sh"

command -v tmux >/dev/null 2>&1 || { echo "launch.sh: no tmux"; exit 1; }
command -v fzf  >/dev/null 2>&1 || { echo "launch.sh: no fzf"; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "launch.sh: no jq"; exit 1; }

S=tatest-$$
SOCK=""
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tagents-run.XXXXXX") || exit 1
# ...resolved, because tmux reports a pane cwd with the symlinks already gone
# (/var/folders is /private/var/folders on macOS) and session_for_dir compares
# the two as strings.
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
BIN="$ROOT/bin";   mkdir -p "$BIN"
OUT="$ROOT/out";   mkdir -p "$OUT"
STATE="$ROOT/state"; mkdir -p "$STATE"
PERS="$ROOT/personal/repo"; mkdir -p "$PERS/.git"
NOR="$ROOT/elsewhere/repo"; mkdir -p "$NOR/.git"

cat >"$BIN/claude" <<'EOF'
#!/bin/sh
# The account, the arguments and the directory — the three things a launch is
# supposed to get right — then stay alive so the pane counts as a live agent.
out="$TA_STUB_OUT/$(printf '%s' "${TMUX_PANE#%}").out"
{
  printf 'CFG=%s\n' "${CLAUDE_CONFIG_DIR-<unset>}"
  printf 'ARGS=%s\n' "$*"
  printf 'PWD=%s\n' "$PWD"
} >"$out"
sleep 600
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
      config_dir: ~/.claude-personal
    work:
  rules:
    - dir: $ROOT/personal
      profile: personal
EOF

# EXPORTED BEFORE THE SERVER EXISTS. A tmux server keeps the environment it was
# started with and hands it to every command it runs, so anything the stub or a
# pane-side tagents needs has to be in place now.
export PATH="$BIN:$PATH"
export TA_STUB_OUT="$OUT"
export TA_STATE_DIR="$STATE"
export TA_SESSION=tatest-dash
export TA_CONFIG="$CFG"
unset TMUX TMUX_PANE TA_MODE TA_FLAT TA_COLS TA_NEW_CMD TA_RESUME_CMD TA_HOME
unset CLAUDE_CONFIG_DIR
# The suite runs inside a real Claude session, which exports this; the hook
# reads it as "the claude I am running inside" and would classify these runs
# against that session's ancestry.
unset CLAUDE_PID

tm() { tmux -L "$S" "$@"; }

tm -f /dev/null new-session -d -s tatest-dash -x 200 -y 50 'sleep 600' || exit 1
tm set -g default-shell /bin/sh >/dev/null 2>&1
tm set -g default-command '' >/dev/null 2>&1
# The session that owns the personal project: session_for_dir votes on the live
# panes sitting in a directory, so a new agent for it must land here.
tm new-session -d -s tatest-proj -c "$PERS" >/dev/null 2>&1
tm new-session -d -s tatest-other -c "$NOR" >/dev/null 2>&1

SOCK=$(tm display -p '#{socket_path}' 2>/dev/null)
[ -n "$SOCK" ] || { echo "launch.sh: no socket for $S"; exit 1; }

# A client on a pty, so display-popup and display-message have somewhere to go.
# Its stdin is a sleep, so it never reads EOF and detaches on its own. The whole
# thing is orphaned deliberately (the subshell exits at once), which is why the
# sleep writes its pid down for the trap rather than being a job to wait on.
( { sleep 300 & printf '%s\n' "$!" >"$ROOT/keeper.pid"; wait; } |
    script -q /dev/null tmux -L "$S" attach -t tatest-dash >/dev/null 2>&1 & ) >/dev/null 2>&1
sleep 0.5

run() { env TMUX="$SOCK,0,0" bash "$TA" "$@"; }

clear_out() { rm -f "$OUT"/*.out 2>/dev/null; return 0; }

# A call that would wait for a person (a dialog) is cut off after ~10s with 124 instead of holding the suite: its stderr lands in $BOUNDED_ERR.
BOUNDED_ERR=""
run_bounded() {
  local i=0 pid
  BOUNDED_ERR=$OUT/bounded.err
  run "$@" >/dev/null 2>"$BOUNDED_ERR" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 40 ]; do i=$((i + 1)); sleep 0.25; done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; fi
  wait "$pid"
}

waitout() {  # -> path of the first stub file to appear, or 1 after ~6s
  local i f
  i=0
  while [ "$i" -lt 24 ]; do
    for f in "$OUT"/*.out; do
      [ -e "$f" ] && { printf '%s' "$f"; return 0; }
    done
    i=$((i + 1)); sleep 0.25
  done
  return 1
}

field() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$2"; }

sess_of_out() {  # which tmux session the pane that wrote this file is in
  local n=${1##*/}; n=${n%.out}
  tm list-panes -a -F '#{pane_id} #{session_name}' 2>/dev/null |
    awk -v p="%$n" '$1 == p { print $2; exit }'
}

# Where an agent LIVES: the session of the window its pane is in.
home_sess_of() {  # <stub .out file> -> session name of the agent's window
  sess_of_out "$1"
}

# ---------------------------------------------------------------------------
t "1. --new with an explicit profile"
# ---------------------------------------------------------------------------
clear_out
run --new "$PERS" personal
f=$(waitout) || { echo "  FAIL nothing started"; fail=$((fail+1)); f=/dev/null; }
ok "the account is the profile's config dir" "$HOME/.claude-personal" "$(field CFG "$f")"
ok "the arguments are the configured ones" "--dangerously-skip-permissions" "$(field ARGS "$f")"
ok "it starts in the project directory" "$PERS" "$(field PWD "$f")"
ok "the agent's home is the session that owns the project" tatest-proj "$(home_sess_of "$f")"

# ---------------------------------------------------------------------------
t "2. a profile with no config_dir unsets an inherited one"
# ---------------------------------------------------------------------------
clear_out
CLAUDE_CONFIG_DIR=/leak run --new "$PERS" work
f=$(waitout) || { echo "  FAIL nothing started"; fail=$((fail+1)); f=/dev/null; }
ok "unset, not empty and not inherited" "<unset>" "$(field CFG "$f")"

# ---------------------------------------------------------------------------
t "2b. --new with a profile that does not exist"
# ---------------------------------------------------------------------------
# One letter short of "personal". Unchecked, this used to start an agent on the
# DEFAULT account — the silent wrong login the whole config exists to end.
clear_out
before=$(tm list-windows -a -F x 2>/dev/null | wc -l | tr -d ' ')
run --new "$PERS" personl >/dev/null 2>&1; rc=$?
sleep 1
ok "a misspelt profile is refused"  1 "$rc"
ok "...and starts nothing"          0 "$(ls "$OUT" 2>/dev/null | wc -l | tr -d ' ')"
ok "...and opens no window"         "$before" "$(tm list-windows -a -F x 2>/dev/null | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
t "3. --new with no profile goes through the rules"
# ---------------------------------------------------------------------------
clear_out
run --new "$PERS"
f=$(waitout) || { echo "  FAIL nothing started"; fail=$((fail+1)); f=/dev/null; }
ok "the dir rule picks personal" "$HOME/.claude-personal" "$(field CFG "$f")"

# ---------------------------------------------------------------------------
t "4. the account dialog"
# ---------------------------------------------------------------------------
# --filter makes fzf print the match and exit instead of drawing anything, which
# is the only way to drive a picker from a script.
clear_out
FZF_DEFAULT_OPTS='--filter=work' TA_MODE=popup \
  run --ask-profile new "$NOR" tatest-other
f=$(waitout) || { echo "  FAIL nothing started"; fail=$((fail+1)); f=/dev/null; }
ok "choosing work starts on the default account" "<unset>" "$(field CFG "$f")"
ok "...in the directory it was asked about" "$NOR" "$(field PWD "$f")"

clear_out
FZF_DEFAULT_OPTS='--filter=zzz' TA_MODE=popup \
  run --ask-profile new "$NOR" tatest-other
sleep 1
n=$(ls "$OUT" 2>/dev/null | wc -l | tr -d ' ')
ok "choosing nothing starts nothing" 0 "$n"

# ---------------------------------------------------------------------------
t "5. the hook records the account"
# ---------------------------------------------------------------------------
PN=9101
hookrun() {  # <config dir or ->
  local cd=$1
  printf '%s' "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"sid-$PN\",\"cwd\":\"$PERS\",\"transcript_path\":\"\",\"source\":\"startup\"}" |
    if [ "$cd" = - ]; then
      env -u CLAUDE_CONFIG_DIR TMUX="$SOCK,0,0" TMUX_PANE="%$PN" sh "$HOOK"
    else
      env TMUX="$SOCK,0,0" TMUX_PANE="%$PN" CLAUDE_CONFIG_DIR="$cd" sh "$HOOK"
    fi
}
hookrun "$HOME/.claude-personal"
ok "the record has seven fields" 7 \
   "$(awk -F'\t' 'NR==1 { print NF }' "$STATE/$PN.tsv" 2>/dev/null)"
ok "the seventh is the account" "$HOME/.claude-personal" \
   "$(awk -F'\t' 'NR==1 { print $7 }' "$STATE/$PN.tsv" 2>/dev/null)"
has "the preview names the profile" "account: personal" "$(run --preview "%$PN" dead)"

hookrun -
ok "an unset account still writes seven fields" 7 \
   "$(awk -F'\t' 'NR==1 { print NF }' "$STATE/$PN.tsv" 2>/dev/null)"
ok "...with the seventh empty" "" \
   "$(awk -F'\t' 'NR==1 { print $7 }' "$STATE/$PN.tsv" 2>/dev/null)"
has "the preview says which account that is" "account: work" "$(run --preview "%$PN" dead)"

hookrun "$HOME/.claude-personal"
# Read the row for that pane alone: the group header carries the project path,
# which contains the word "personal" and would pass a grep over the whole list.
row=$(TA_COLS=130 run --list | awk -F'\t' -v p="%$PN" '$1 == p && index($2, "\342\226\276") == 0 { print $2; exit }' |
        sed 's/\033\[[0-9;]*m//g')
has "the list shows the account column" "personal" "$row"

# The hook records whatever CLAUDE_CONFIG_DIR held, trailing slash and all,
# while the profile side has already had one stripped. Unmatched, the basename
# fallback then ate the whole string and the column went blank — which in this
# column means "the record predates it", a different answer entirely.
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date +%s)" done "sid-slash" "$PERS" "" closed "$HOME/.claude-personal/" \
  >"$STATE/9102.tsv"
row=$(TA_COLS=130 run --list | awk -F'\t' '$1 == "%9102" && index($2, "\342\226\276") == 0 { print $2; exit }' |
        sed 's/\033\[[0-9;]*m//g')
has "a trailing slash still names the profile" "personal" "$row"
rm -f "$STATE/9102.tsv" "$STATE/$PN.tsv"

# ---------------------------------------------------------------------------
t "6. resuming keeps the account the session ran on"
# ---------------------------------------------------------------------------
# A pane sitting at a shell with the WRONG account exported: this is the path
# where an inherited value could win, since the command is typed into that very
# shell rather than started by the tmux server.
clear_out
RP=$(tm new-window -d -t tatest-proj: -P -F '#{pane_id}' -c "$PERS" 2>/dev/null)
tm send-keys -t "$RP" 'export CLAUDE_CONFIG_DIR=/leak' Enter
sleep 0.4
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date +%s)" done "sid-resume" "$PERS" "" "closed" "$HOME/.claude-personal" \
  >"$STATE/${RP#%}.tsv"
run --act open "$RP" dead sid-resume "$PERS"
f=$(waitout) || { echo "  FAIL nothing resumed"; fail=$((fail+1)); f=/dev/null; }
ok "the recorded account wins over the exported one" \
   "$HOME/.claude-personal" "$(field CFG "$f")"
has "and it really is a resume" "--resume sid-resume" "$(field ARGS "$f")"

# A record from before the account was recorded has six fields and no opinion,
# so the rules answer instead.
clear_out
RP2=$(tm new-window -d -t tatest-proj: -P -F '#{pane_id}' -c "$PERS" 2>/dev/null)
sleep 0.3
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date +%s)" done "sid-old" "$PERS" "" "closed" >"$STATE/${RP2#%}.tsv"
run --act open "$RP2" dead sid-old "$PERS"
f=$(waitout) || { echo "  FAIL nothing resumed"; fail=$((fail+1)); f=/dev/null; }
ok "a six-field record falls back to the rules" \
   "$HOME/.claude-personal" "$(field CFG "$f")"

# A NAME IS NOT AN ACCOUNT. profile_of_cfg prints "default" when nothing claims
# an empty recorded value, because the column has to say something; a config
# with a profile actually NAMED default must not have that label handed back to
# it as a match, or the session comes back on a login it never ran on.
cat >"$ROOT/collide.yaml" <<EOF
claude:
  profiles:
    default:
      config_dir: ~/.claude-work
    personal:
      config_dir: ~/.claude-personal
EOF
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date +%s)" done "sid-collide" "$PERS" "" closed "" >"$STATE/9103.tsv"
line=$(TA_CONFIG="$ROOT/collide.yaml" run --preview %9103 dead 2>/dev/null |
         sed 's/\033\[[0-9;]*m//g' | tail -1)
hasnt "a profile named default is not the unset account" "CLAUDE_CONFIG_DIR=" "$line"
has "...it resumes on the account it ran on" "env -u CLAUDE_CONFIG_DIR" "$line"
rm -f "$STATE/9103.tsv"

# ---------------------------------------------------------------------------
t "7. no config file at all changes nothing"
# ---------------------------------------------------------------------------
clear_out
TA_CONFIG=/nonexistent/config.yaml run --new "$PERS"
f=$(waitout) || { echo "  FAIL nothing started"; fail=$((fail+1)); f=/dev/null; }
ok "the environment is inherited, as it always was" "<unset>" "$(field CFG "$f")"
ok "and the arguments are the old default" "--dangerously-skip-permissions" "$(field ARGS "$f")"

clear_out
before=$(tm list-windows -a -F x 2>/dev/null | wc -l | tr -d ' ')
TA_CONFIG=/nonexistent/config.yaml run --act pick "$PERS" '' '' "$PERS"
sleep 0.6
after=$(tm list-windows -a -F x 2>/dev/null | wc -l | tr -d ' ')
ok "ctrl-p with nothing configured opens no window" "$before" "$after"
ok "...and starts nothing" 0 "$(ls "$OUT" 2>/dev/null | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
t "8. prompts work in popup mode"
# ---------------------------------------------------------------------------
# A popup cannot open a popup, so the whole prefix+a mode used to have no
# working prompt at all: the key ran, nothing was asked, nothing changed.
printf 'newname\n' | TA_MODE=popup run --act rename "%$PN" dead sid-rename >/dev/null 2>&1
ok "rename reads its answer inline" "newname" \
   "$(awk -F'\t' '$1 == "sid-rename" { print $2; exit }' "$STATE/labels.tsv" 2>/dev/null)"

# ---------------------------------------------------------------------------
t "9. a new agent gets the cursor"
# ---------------------------------------------------------------------------
# The window is still opened with -d in the project's session, but the new window
# is then selected like enter would do: the viewport shows it and its pane is the
# active one, so ctrl-n leaves you looking at the agent you just asked for. The
# popup of section 4 started an agent with no dashboard up, which brings the
# cockpit up first, so from here on the dashboard is the cockpit and the window
# on screen is the one its viewport shows.
clear_out
ok "the cockpit is up, brought by the popup of section 4" 1 "$(tm show -qv -t '=tagents:' @tagents_cockpit 2>/dev/null)"
run --act new "%$PN" dead sid-focus "$PERS"
f=$(waitout) || { echo "  FAIL nothing started"; fail=$((fail+1)); f=/dev/null; }
sleep 0.8
n=${f##*/}; n=${n%.out}
vt=$(tm show -gqv @tagents_viewport_tty 2>/dev/null)
vw=$(tm list-clients -F '#{client_name} #{window_id}' 2>/dev/null | awk -v c="$vt" '$1 == c { print $2 }')
ok "the viewport shows the window of the agent it just started" \
   "$(tm display -p -t "%$n" '#{window_id}' 2>/dev/null)" "$vw"
ok "...and the agent's pane is the active one there" \
   "%$n" "$(tm display -p -t "$vw" '#{pane_id}' 2>/dev/null)"

# ---------------------------------------------------------------------------
t "10. the hook records when you last typed, and nothing else touches it"
# ---------------------------------------------------------------------------
# One file per session holding one epoch second, and the ONLY event that writes
# it is UserPromptSubmit: the list is ordered on it and the age column is read
# off it, so a clock that moved on every tool call would put both back where
# they were — a working agent forever at 0:00 and rows trading places mid-turn.
PP=9301
ev() {  # <json body>
  printf '%s' "$1" |
    env TMUX="$SOCK,0,0" TMUX_PANE="%$PP" sh "$HOOK"
}
ev "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"sid-$PP\",\"cwd\":\"$PERS\",\"transcript_path\":\"\",\"prompt\":\"go\"}"
typed=$(cat "$STATE/prompt/$PP" 2>/dev/null)
ok "a prompt writes the second it was sent" yes \
   "$([ -n "$typed" ] && [ "$typed" -ge $(( $(date +%s) - 5 )) ] && echo yes || echo no)"

sleep 1
ev "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"sid-$PP\",\"cwd\":\"$PERS\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}"
ev "{\"hook_event_name\":\"Stop\",\"session_id\":\"sid-$PP\",\"cwd\":\"$PERS\"}"
ok "a whole turn of events leaves it alone" "$typed" \
   "$(cat "$STATE/prompt/$PP" 2>/dev/null)"
ok "...while the record itself has moved on" yes \
   "$(awk -F'\t' -v w="$typed" 'NR==1 { print ($1 > w) ? "yes" : "no" }' "$STATE/$PP.tsv")"

ev "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"sid-$PP\",\"cwd\":\"$PERS\"}"
ok "and the session ending takes it with the record" no \
   "$([ -e "$STATE/prompt/$PP" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
t "A click on a notice names the chat by its session id"
# ---------------------------------------------------------------------------
# The notice was posted for a pane that has since been killed; the click still
# says "live" and carries that pane. The record is what remains, and the session
# id in it is what the click is about.
clear_out
GP=$(tm new-window -d -t tatest-proj: -P -F '#{pane_id}' -c "$PERS" 2>/dev/null)
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date +%s)" working "sid-gone" "$PERS" "" "closed" "$HOME/.claude-personal" \
  >"$STATE/${GP#%}.tsv"
tm kill-pane -t "$GP" 2>/dev/null; sleep 0.3
run --act open "$GP" live sid-gone "$PERS"
f=$(waitout) || { echo "  FAIL nothing resumed"; fail=$((fail+1)); f=/dev/null; }
ok "a live click for a pane that is gone resumes from its record" \
   "$HOME/.claude-personal" "$(field CFG "$f")"
has "...as a resume of that session" "--resume sid-gone" "$(field ARGS "$f")"
ok "no select lock is left behind" no "$([ -e "$STATE/.select.lock" ] && echo yes || echo no)"

# A session no record names: nothing is resumed, and the click still succeeds.
clear_out
run --act open "%9998" live sid-nobody "$PERS"; rc=$?
sleep 1.5
ok "a session no record names exits 0" 0 "$rc"
ok "...and resumes nothing" 0 "$(ls "$OUT" 2>/dev/null | wc -l | tr -d ' ')"
rm -f "$STATE/${GP#%}.tsv"

t "11. a session marked @tagents_cockpit never owns a project"
CPD="$ROOT/personal/cp-project"; mkdir -p "$CPD/.git"
tm new-session -d -s tatest-cpv -c "$CPD" 'sleep 600' >/dev/null 2>&1
tm new-session -d -s tatest-cpd -c "$CPD" 'sleep 600' >/dev/null 2>&1
tm split-window -d -t '=tatest-cpd:' -c "$CPD" 'sleep 600' >/dev/null 2>&1
tm set -t '=tatest-cpd:' @tagents_cockpit 1 >/dev/null 2>&1
clear_out
run --new "$CPD" >/dev/null 2>&1
f=$(waitout)
ok "a new chat for the project goes to the session that is not the dashboard" tatest-cpv "$(sess_of_out "$f")"
tm kill-session -t '=tatest-cpd:' >/dev/null 2>&1; tm kill-session -t '=tatest-cpv:' >/dev/null 2>&1


t "12. --window opens a plain window running a command"
# The twin of --new for anything that is not an agent: the command is the window's own, the window lands in the session that owns the directory, and the line it prints says where.
WD="$ROOT/personal/window-project"; mkdir -p "$WD/.git"
tm new-session -d -s tatest-winowner -c "$WD" 'sleep 600' >/dev/null 2>&1
clear_out
rm -f "$OUT/win.txt"
before=$(tm list-windows -a -F x 2>/dev/null | wc -l | tr -d ' ')
line=$(run --window "$WD" "pwd > $OUT/win.txt; sleep 600" 2>/dev/null); rc=$?
i=0; while [ ! -s "$OUT/win.txt" ] && [ "$i" -lt 24 ]; do i=$((i + 1)); sleep 0.25; done
ok "it succeeds" 0 "$rc"
ok "the command ran in the directory it was given" "$WD" "$(cat "$OUT/win.txt" 2>/dev/null)"
ok "exactly one window was opened" "$((before + 1))" "$(tm list-windows -a -F x 2>/dev/null | wc -l | tr -d ' ')"
wpane=${line%%	*}
ok "it prints the new pane first" "$(tm list-panes -a -F '#{pane_id}' 2>/dev/null | grep -Fx "$wpane")" "$wpane"
ok "the window is in the session that owns the directory" tatest-winowner \
   "$(tm display -p -t "$wpane" '#{session_name}' 2>/dev/null)"
ok "it prints where the window is, after the pane" \
   "$(tm display -p -t "$wpane" '#{session_name}:#{window_index}' 2>/dev/null)" "${line#*	}"
ok "it runs no agent: the claude stub never started" 0 "$(ls "$OUT"/*.out 2>/dev/null | wc -l | tr -d ' ')"
ok "the new window is the one selected in its session, as enter on a row would leave it" 1 \
   "$(tm display -p -t "$wpane" '#{window_active}' 2>/dev/null)"

# A relative directory is the caller's, not the tmux server's.
rm -f "$OUT/rel.txt"
( cd "$ROOT/personal" && run --window window-project "pwd > $OUT/rel.txt; sleep 600" >/dev/null 2>&1 )
i=0; while [ ! -s "$OUT/rel.txt" ] && [ "$i" -lt 24 ]; do i=$((i + 1)); sleep 0.25; done
ok "a relative directory is resolved where the command was typed" "$WD" "$(cat "$OUT/rel.txt" 2>/dev/null)"

before=$(tm list-windows -a -F x 2>/dev/null | wc -l | tr -d ' ')
err=$(run --window "$WD" 2>&1 >/dev/null); rc=$?
ok "a missing command is a usage error" 2 "$rc"
has "...that says what it needs" "--window takes a directory and one command, quoted" "$err"
err=$(run --window 2>&1 >/dev/null); rc=$?
ok "a missing directory is a usage error too" 2 "$rc"
# A command typed without quotes arrives as several words; the extra ones used to be dropped and a different command run.
err=$(run --window "$WD" echo hello 2>&1 >/dev/null); rc=$?
ok "a command in more than one word is a usage error" 2 "$rc"
has "...that says to quote it" "--window takes a directory and one command, quoted" "$err"
err=$(run --window "$WD" "sleep 600" extra 2>&1 >/dev/null); rc=$?
ok "so is one word too many after a quoted command" 2 "$rc"
err=$(run --window "$ROOT/no-such-dir" "sleep 600" 2>&1 >/dev/null); rc=$?
ok "a directory that is not there is refused" 1 "$rc"
has "...by name" "$ROOT/no-such-dir" "$err"
ok "none of the refusals opened a window" "$before" "$(tm list-windows -a -F x 2>/dev/null | wc -l | tr -d ' ')"

# A command that starts with a dash is the command, not a flag of tmux: without `--` before it tmux refuses with "unknown flag" and no window opens. What the window's shell then makes of it is the shell's own business, so only the opening is checked.
dashline=$(run --window "$WD" "-zzz-not-a-command" 2>/dev/null); rc=$?
ok "a command that starts with a dash is not read as a tmux flag" 0 "$rc"
has "...and the window it opened is printed" "%" "$dashline"

# CDPATH is the caller's, and a relative name is looked up where the caller stands: with CDPATH set `cd` would take the same name from there and print where it went, into the very value the directory is read from.
mkdir -p "$ROOT/cdp/window-project"
rm -f "$OUT/cdp.txt"
cdline=$(cd "$ROOT/personal" && CDPATH="$ROOT/cdp" run --window window-project "pwd > $OUT/cdp.txt; sleep 600" 2>/dev/null)
i=0; while [ ! -s "$OUT/cdp.txt" ] && [ "$i" -lt 24 ]; do i=$((i + 1)); sleep 0.25; done
ok "a CDPATH does not move a relative directory" "$WD" "$(cat "$OUT/cdp.txt" 2>/dev/null)"
cdpane=${cdline%%	*}
ok "...and what is printed is one line: the pane and where it is" "$(tm display -p -t "$cdpane" '#{session_name}:#{window_index}' 2>/dev/null)" "${cdline#*	}"
ok "...a single line" 1 "$(printf '%s\n' "$cdline" | wc -l | tr -d ' ')"
tm kill-session -t '=tatest-winowner:' >/dev/null 2>&1

t "13. --detach makes the window and leaves the screen alone"
# The default selects what it starts (open_agent), as enter on a row would; detached, the window is made where it belongs and nothing is selected or switched to, and no dialog is ever opened.
tm new-session -d -s tatest-winowner -c "$WD" 'sleep 600' >/dev/null 2>&1
active_before=$(tm display -p -t '=tatest-winowner:' '#{window_id}' 2>/dev/null)
rm -f "$OUT/det.txt"
line=$(run --window --detach "$WD" "pwd > $OUT/det.txt; sleep 600" 2>/dev/null); rc=$?
i=0; while [ ! -s "$OUT/det.txt" ] && [ "$i" -lt 24 ]; do i=$((i + 1)); sleep 0.25; done
dpane=${line%%	*}
ok "--window --detach succeeds" 0 "$rc"
ok "...runs the command in the directory" "$WD" "$(cat "$OUT/det.txt" 2>/dev/null)"
ok "...prints the pane and where it is, as without the flag" "$(tm display -p -t "$dpane" '#{session_name}:#{window_index}' 2>/dev/null)" "${line#*	}"
ok "...and the new window is not the selected one" 0 "$(tm display -p -t "$dpane" '#{window_active}' 2>/dev/null)"
ok "...the window that was selected still is" "$active_before" "$(tm display -p -t '=tatest-winowner:' '#{window_id}' 2>/dev/null)"
tm kill-session -t '=tatest-winowner:' >/dev/null 2>&1

clear_out
plain=$(run --new "$PERS" personal 2>/dev/null)
f=$(waitout) || { echo "  FAIL nothing started"; fail=$((fail+1)); f=/dev/null; }
pane="%${f##*/}"; pane=${pane%.out}
ok "without the flag the agent's window is selected, as enter on a row leaves it" 1 "$(tm display -p -t "$pane" '#{window_active}' 2>/dev/null)"
ok "...and nothing is printed, as it always was" "" "$plain"

clear_out
nline=$(run --new --detach "$PERS" personal 2>/dev/null); rc=$?
f=$(waitout) || { echo "  FAIL nothing started"; fail=$((fail+1)); f=/dev/null; }
pane="%${f##*/}"; pane=${pane%.out}
ok "--new --detach succeeds" 0 "$rc"
ok "...prints one line: the pane, a tab and where the window is, as --window does" "$pane	$(tm display -p -t "$pane" '#{session_name}:#{window_index}' 2>/dev/null)" "$nline"
ok "...starts the agent on the account asked for" "$HOME/.claude-personal" "$(field CFG "$f")"
ok "...in the session that owns the project" tatest-proj "$(sess_of_out "$f")"
ok "...and its window is not selected" 0 "$(tm display -p -t "$pane" '#{window_active}' 2>/dev/null)"

# No rule matches $NOR, so the config says to ask which account: a dialog needs a person, a detached start has none.
ok "the rules ask for this directory" ask "$(run --profile-for "$NOR" 2>/dev/null)"
clear_out
before=$(tm list-windows -a -F x 2>/dev/null | wc -l | tr -d ' ')
run_bounded --new --detach "$NOR"; rc=$?; err=$(cat "$BOUNDED_ERR")
sleep 1
ok "a detached start the rules cannot decide is a usage error" 2 "$rc"
has "...that names the profiles to pass" "personal work" "$err"
ok "...opens no window" "$before" "$(tm list-windows -a -F x 2>/dev/null | wc -l | tr -d ' ')"
ok "...and starts nothing" 0 "$(ls "$OUT"/*.out 2>/dev/null | wc -l | tr -d ' ')"
run_bounded --new --detach "$PERS" ask; rc=$?
ok "asking for the question by name is refused the same way" 2 "$rc"

# A refusal is read by a program: its reason is on standard error, and no window is opened for it.
clear_out
before=$(tm list-windows -a -F x 2>/dev/null | wc -l | tr -d ' ')
run_bounded --new --detach "$ROOT/no-such-directory"; rc=$?; err=$(cat "$BOUNDED_ERR")
ok "a detached start in a directory that is not there is refused" 1 "$rc"
has "...and standard error says why" "is not a directory" "$err"
has "...and names the directory" "$ROOT/no-such-directory" "$err"
ok "...opening no window" "$before" "$(tm list-windows -a -F x 2>/dev/null | wc -l | tr -d ' ')"

# A relative directory is the caller's here too. Outside a git repository the directory is used as given, and a name that is not made absolute matches no session by its path, so the agent would land in a session that does not own it (and tmux would resolve a relative `-c` against a directory of its own on a tmux that does not take the client's).
RELD="$ROOT/personal/plain-dir"; mkdir -p "$RELD"
tm new-session -d -s tatest-plain -c "$RELD" 'sleep 600' >/dev/null 2>&1
clear_out
rline=$( cd "$ROOT/personal" && run --new --detach plain-dir personal 2>/dev/null ); rc=$?
rpane=${rline%%	*}
ok "a detached start in a relative directory succeeds" 0 "$rc"
ok "...in the directory it names" "$(cd -P "$RELD" && pwd)" "$(tm display -p -t "$rpane" '#{pane_current_path}' 2>/dev/null)"
ok "...in the session that owns that directory" tatest-plain "$(tm display -p -t "$rpane" '#{session_name}' 2>/dev/null)"
tm kill-session -t '=tatest-plain:' >/dev/null 2>&1

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
