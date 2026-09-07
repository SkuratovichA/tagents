#!/usr/bin/env bash
#
# tests/closed.sh — ctrl-b: every session that is not running, under the name
# the dashboard knows it by, and resuming one of them.
#
# Same shape as tests/launch.sh: a tmux server of its own (`tmux -L tatest-$$ -f
# /dev/null`), tagents pointed at it through an exported $TMUX, and a `claude`
# stub that writes down the account, the arguments and the directory it was
# started with. NOTHING HERE MAY TOUCH THE DEFAULT TMUX SOCKET.
#
# $HOME is moved into the temp root, because that is where the two accounts'
# history.jsonl files have to live: the profile with no config_dir IS ~/.claude,
# and the whole point of the join is that the file a prompt was written to says
# which login can resume the session.
#
# bash 3.2, runnable from any cwd, non-zero exit on any failing check.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TA="$HERE/../tagents"

command -v tmux >/dev/null 2>&1 || { echo "closed.sh: no tmux"; exit 1; }
command -v fzf  >/dev/null 2>&1 || { echo "closed.sh: no fzf"; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "closed.sh: no jq"; exit 1; }

S=tatest-$$
SOCK=""
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tagents-closed.XXXXXX") || exit 1
ROOT=$(cd "$ROOT" && pwd -P) || exit 1
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

TAB=$(printf '\t')

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------
BIN="$ROOT/bin";     mkdir -p "$BIN"
LIVEBIN="$ROOT/livebin"; mkdir -p "$LIVEBIN"
OUT="$ROOT/out";     mkdir -p "$OUT"
STATE="$ROOT/state"; mkdir -p "$STATE"
HOMED="$ROOT/home";  mkdir -p "$HOMED/.claude" "$HOMED/.claude-p"
PROJA="$ROOT/proj-a"; mkdir -p "$PROJA"

cat >"$BIN/claude" <<'EOF'
#!/bin/sh
out="$TA_STUB_OUT/$(printf '%s' "${TMUX_PANE#%}").out"
{
  printf 'CFG=%s\n' "${CLAUDE_CONFIG_DIR-<unset>}"
  printf 'ARGS=%s\n' "$*"
  printf 'PWD=%s\n' "$PWD"
} >"$out"
sleep 600
EOF
chmod +x "$BIN/claude"
# An agent is a process ps calls "claude" — a #!/bin/sh stub is an `sh` to ps and
# would never be counted, so the pane that stands in for a RUNNING session gets a
# copy of /bin/sleep under that name instead. A copy of a system binary is killed
# on sight on arm64 (its signature is only valid for the original inode), which
# is what the ad-hoc re-sign is for; see tests/panes.sh.
cp /bin/sleep "$LIVEBIN/claude" || exit 1
codesign --remove-signature "$LIVEBIN/claude" >/dev/null 2>&1
codesign -f -s - "$LIVEBIN/claude" >/dev/null 2>&1
"$LIVEBIN/claude" 0 >/dev/null 2>&1 ||
  { echo "closed.sh: cannot build a stub agent (codesign?)"; exit 1; }

CFG="$ROOT/config.yaml"
cat >"$CFG" <<EOF
claude:
  args: --dangerously-skip-permissions
  profiles:
    work:
    personal:
      config_dir: $HOMED/.claude-p
EOF

NOW=$(date +%s)
# Two accounts, one transcript pool each. s-old and s-live were typed into the
# work login, s-named into the personal one.
jline() {  # <sid> <epoch> <project> <display>
  printf '{"display":"%s","project":"%s","sessionId":"%s","timestamp":%s000}\n' \
    "$4" "$3" "$1" "$2"
}
{
  jline s-old  $((NOW - 9000)) "$PROJA" "first prompt of the old one"
  jline s-old  $((NOW - 8000)) "$PROJA" "second prompt of the old one"
  jline s-live $((NOW - 100))  "$PROJA" "a prompt in the running one"
} >"$HOMED/.claude/history.jsonl"
jline s-named $((NOW - 400)) "$PROJA" "the prompt nobody reads" >"$HOMED/.claude-p/history.jsonl"

# The durable log the state hook appends to: a start, a turn and an end for the
# closed session, and a start for the one still running.
{
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' $((NOW - 9100)) start s-old '%701' '' "$PROJA"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' $((NOW - 8500)) turn  s-old '%701' '' "$PROJA"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' $((NOW - 8000)) end   s-old '%701' '' "$PROJA"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' $((NOW - 200))  start s-live '%702' '' "$PROJA"
} >"$STATE/history.tsv"
printf 's-named\tmy named one\n' >"$STATE/labels.tsv"

export PATH="$BIN:$PATH"
export HOME="$HOMED"
export TA_STUB_OUT="$OUT"
export TA_STATE_DIR="$STATE"
export TA_SESSION=tatest-dash
export TA_CONFIG="$CFG"
unset TMUX TMUX_PANE TA_MODE TA_FLAT TA_COLS TA_NEW_CMD TA_RESUME_CMD TA_HOME
unset CLAUDE_CONFIG_DIR FZF_DEFAULT_OPTS

tm() { tmux -L "$S" "$@"; }

tm -f /dev/null new-session -d -s tatest-dash -x 200 -y 50 'sleep 600' || exit 1
tm set -g default-shell /bin/sh >/dev/null 2>&1
tm set -g default-command '' >/dev/null 2>&1

SOCK=$(tm display -p '#{socket_path}' 2>/dev/null)
[ -n "$SOCK" ] || { echo "closed.sh: no socket for $S"; exit 1; }

( { sleep 300 & printf '%s\n' "$!" >"$ROOT/keeper.pid"; wait; } |
    script -q /dev/null tmux -L "$S" attach -t tatest-dash >/dev/null 2>&1 & ) >/dev/null 2>&1
sleep 0.5

# The pane that makes s-live live, plus the state record that ties the pane to
# the session id — which is what closed_rows subtracts.
LP=$(tm new-window -d -t tatest-dash: -P -F '#{pane_id}' -c "$PROJA" \
       "exec '$LIVEBIN/claude' 600" 2>/dev/null)
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$NOW" working s-live "$PROJA" "" "the running one" "" >"$STATE/${LP#%}.tsv"
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

col() { awk -F"$TAB" -v s="$1" -v n="$2" '$1 == s { print $n; exit }'; }

# ---------------------------------------------------------------------------
t "1. --closed-rows is every session that is not running"
# ---------------------------------------------------------------------------
ROWS=$(run --closed-rows)
hasnt "a session that is running right now is not closed" "s-live" "$ROWS"
has   "the one that ended is there"                       "s-old"  "$ROWS"
has   "so is the one that only labels.tsv named"          "s-named" "$ROWS"

ok "its name is the first prompt that was typed into it" \
   "first prompt of the old one" "$(printf '%s\n' "$ROWS" | col s-old 6)"
ok "the account is the one whose history.jsonl holds it" \
   "work" "$(printf '%s\n' "$ROWS" | col s-old 4)"
ok "the directory is the cwd the hook wrote down" \
   "$PROJA" "$(printf '%s\n' "$ROWS" | col s-old 7)"
ok "and it was found in both files" \
   "both" "$(printf '%s\n' "$ROWS" | col s-old 8)"

ok "an explicit name beats the first prompt" \
   "my named one" "$(printf '%s\n' "$ROWS" | col s-named 6)"
ok "...on the account that account's file says" \
   "personal" "$(printf '%s\n' "$ROWS" | col s-named 4)"
ok "...with that profile's badge" \
   "p" "$(printf '%s\n' "$ROWS" | col s-named 5)"
ok "...and its directory comes from the prompt log" \
   "$PROJA" "$(printf '%s\n' "$ROWS" | col s-named 7)"

ok "newest activity first" "s-named" "$(printf '%s\n' "$ROWS" | awk 'NR == 1 { print $1 }')"

# ---------------------------------------------------------------------------
t "2. the preview is the conversation"
# ---------------------------------------------------------------------------
PV=$(run --closed-preview s-old work "$PROJA")
has "the first prompt is in it"  "first prompt of the old one"  "$PV"
has "the second one too"         "second prompt of the old one" "$PV"
has "and the directory it ran in" "$PROJA" "$PV"
hasnt "another session's prompts are not" "the prompt nobody reads" "$PV"

# ---------------------------------------------------------------------------
t "3. enter resumes the session it was asked about"
# ---------------------------------------------------------------------------
# --filter makes fzf print the match and exit instead of drawing anything, which
# is the only way to drive a picker from a script.
clear_out
FZF_DEFAULT_OPTS='--filter=s-old' TA_MODE=popup run --ask-closed
f=$(waitout) || { echo "  FAIL nothing resumed"; fail=$((fail+1)); f=/dev/null; }
has "it really is a resume of that session" "--resume s-old" "$(field ARGS "$f")"
ok  "on the account it ran on"   "<unset>" "$(field CFG "$f")"
ok  "in the directory it ran in" "$PROJA"  "$(field PWD "$f")"

clear_out
FZF_DEFAULT_OPTS='--filter=named' TA_MODE=popup run --ask-closed
f=$(waitout) || { echo "  FAIL nothing resumed"; fail=$((fail+1)); f=/dev/null; }
has "the personal session comes back on the personal login" \
    "--resume s-named" "$(field ARGS "$f")"
ok  "...which is that profile's config dir" "$HOMED/.claude-p" "$(field CFG "$f")"

clear_out
FZF_DEFAULT_OPTS='--filter=zzz' TA_MODE=popup run --ask-closed
sleep 1
ok "choosing nothing resumes nothing" 0 "$(ls "$OUT" 2>/dev/null | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
t "4. a directory that is gone is not a reason to refuse"
# ---------------------------------------------------------------------------
GONE="$ROOT/proj-gone"; mkdir -p "$GONE"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' $((NOW - 300)) start s-gone '%703' '' "$GONE" \
  >>"$STATE/history.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' $((NOW - 250)) end   s-gone '%703' '' "$GONE" \
  >>"$STATE/history.tsv"
ok "it is offered while the directory is there" \
   "$GONE" "$(run --closed-rows | col s-gone 7)"
rmdir "$GONE"
clear_out
FZF_DEFAULT_OPTS='--filter=s-gone' TA_MODE=popup run --ask-closed
f=$(waitout) || { echo "  FAIL nothing resumed"; fail=$((fail+1)); f=/dev/null; }
has "it still resumes"          "--resume s-gone" "$(field ARGS "$f")"
ok  "...from $HOME instead"     "$HOMED"          "$(field PWD "$f")"

# ---------------------------------------------------------------------------
t "5. the key is listed"
# ---------------------------------------------------------------------------
has "ctrl-b has a row in the key table" "ctrl-b" "$(run --keys | cut -f1)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
