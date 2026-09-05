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

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
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

# Where an agent LIVES, docked or not: a docked chat sits in the sidebar, but the
# placeholder keeping its seat warm (@tagents_parked names the chat) is in the
# home window, and that window's session is the answer. An undocked chat is its
# own answer.
home_sess_of() {  # <stub .out file> -> session name of the agent's home window
  local n=${1##*/} home
  n=${n%.out}
  home=$(tm list-panes -a -F '#{session_name} #{?@tagents_parked,#{@tagents_parked},-}' 2>/dev/null |
           awk -v p="%$n" '$2 == p { print $1; exit }')
  [ -n "$home" ] && { printf '%s' "$home"; return 0; }
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
row=$(TA_COLS=130 run --list | awk -F'\t' -v p="%$PN" '$1 == p { print $2; exit }' |
        sed 's/\033\[[0-9;]*m//g')
has "the list shows the account column" "personal" "$row"

# The hook records whatever CLAUDE_CONFIG_DIR held, trailing slash and all,
# while the profile side has already had one stripped. Unmatched, the basename
# fallback then ate the whole string and the column went blank — which in this
# column means "the record predates it", a different answer entirely.
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date +%s)" done "sid-slash" "$PERS" "" closed "$HOME/.claude-personal/" \
  >"$STATE/9102.tsv"
row=$(TA_COLS=130 run --list | awk -F'\t' '$1 == "%9102" { print $2; exit }' |
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
# The window is still opened with -d in the project's session, but the new pane
# is then docked into the seat like enter would do, and the cursor lands in it:
# ctrl-n leaves you looking at the agent you just asked for. The pane id is what
# survives the dock swap, so that is what the client's current pane is checked
# against — whichever window it now sits in.
clear_out
run --act new "%$PN" dead sid-focus "$PERS"
f=$(waitout) || { echo "  FAIL nothing started"; fail=$((fail+1)); f=/dev/null; }
sleep 0.8
n=${f##*/}; n=${n%.out}
csess=$(tm list-clients -F '#{client_session}' 2>/dev/null | head -1)
ok "the client's current pane is the agent it just started" \
   "%$n" "$(tm display -p -t "$csess:" '#{pane_id}' 2>/dev/null)"
ok "and that pane is docked in a sidebar seat" \
   yes "$([ -n "$(tm display -p -t "%$n" '#{@tagents_docked}' 2>/dev/null)" ] && echo yes || echo no)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
