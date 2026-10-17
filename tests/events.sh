#!/usr/bin/env bash
#
# tests/events.sh — the event stream of the state hook: <state dir>/events.tsv,
# one line per event worth a notification, appended while the switch
# <state dir>/events.on exists. The notify plugin follows that file, and the hook
# runs on every tool call of every session, so two things are pinned besides the
# lines themselves: the state record and history.tsv stay byte for byte what
# origin/main writes, and the hook starts no program that origin/main's does not.
#
# No tmux server is involved at all. Every run has $TMUX pointed at a socket that
# does not exist and a logging `tmux` shim first on $PATH, so the hook can neither
# see nor reach any real server. NOTHING HERE MAY TOUCH THE DEFAULT TMUX SOCKET.
#
# bash 3.2, runnable from any cwd, non-zero exit on any failing check.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/../hooks/tmux-agent-state.sh"

command -v jq >/dev/null 2>&1 || { echo "events.sh: no jq"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "events.sh: no git"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tagents-events.XXXXXX") || exit 1
ROOT=$(cd "$ROOT" && pwd -P) || exit 1
trap 'rm -rf "$ROOT"' EXIT INT TERM

pass=0; fail=0
ok()   { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
         else fail=$((fail+1)); printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"; fi; }
t()    { printf '\n%s\n' "$1"; }

TAB=$(printf '\t')

SHIM="$ROOT/shim"; mkdir -p "$SHIM"
cat >"$SHIM/tmux" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$SHIM/tmux"
DEAD="$ROOT/no-such-socket,0,0"

# origin/main's hook, the reference for the byte-for-byte and process checks.
HOOK_MAIN="$ROOT/hook-main.sh"
git -C "$HERE/.." show origin/main:hooks/tmux-agent-state.sh >"$HOOK_MAIN" 2>/dev/null ||
  { echo "events.sh: cannot read origin/main:hooks/tmux-agent-state.sh"; exit 1; }

# <hook> <state dir> <payload> [env assignments...] — one hook run, with a pane.
run_hook() {
  local hook=$1 st=$2 payload=$3
  shift 3
  printf '%s' "$payload" |
    env PATH="$SHIM:$PATH" TMUX="$DEAD" TMUX_PANE=%7 TA_STATE_DIR="$st" "$@" sh "$hook" >/dev/null 2>&1
}
# <event> [extra json object] — a payload.
payload() {
  local x=${2:-}; [ -n "$x" ] || x='{}'
  jq -nc --arg e "$1" --argjson x "$x" \
    '{hook_event_name:$e, session_id:"sid-1", cwd:"/work", transcript_path:"/work/t.jsonl"} + $x'
}
# <state dir> — a fresh dir with the switch on.
fresh() { rm -rf "$1"; mkdir -p "$1"; : >"$1/events.on"; }
field() { awk -F"$TAB" -v n="$1" -v r="${3:-1}" 'NR==r { print $n; exit }' "$2" 2>/dev/null; }
nf()    { awk -F"$TAB" -v r="${2:-1}" 'NR==r { print NF; exit }' "$1" 2>/dev/null; }
lines() { if [ -e "$1" ]; then wc -l <"$1" | tr -d ' '; else echo none; fi; }

S="$ROOT/st"; E="$S/events.tsv"

t "a. without the switch there is no stream"
rm -rf "$S"; mkdir -p "$S"
run_hook "$HOOK" "$S" "$(payload Stop)"
ok "no events.tsv" none "$(lines "$E")"
ok "the state record is written all the same" 1 "$([ -e "$S/7.tsv" ] && echo 1 || echo 0)"

t "b. a Stop with a pane"
fresh "$S"
run_hook "$HOOK" "$S" "$(payload Stop)" TA_LABEL=lbl CLAUDE_CONFIG_DIR=/cfg
ok "one line" 1 "$(lines "$E")"
ok "thirteen fields" 13 "$(nf "$E")"
ok "the time is epoch seconds" 1 "$(field 1 "$E" | grep -c '^[0-9][0-9]*$')"
ok "event" Stop "$(field 2 "$E")"
ok "key" 7 "$(field 3 "$E")"
ok "sid" sid-1 "$(field 4 "$E")"
ok "no agent" "" "$(field 5 "$E")"
ok "pane" %7 "$(field 6 "$E")"
ok "cwd" /work "$(field 7 "$E")"
ok "transcript" /work/t.jsonl "$(field 8 "$E")"
ok "config" /cfg "$(field 9 "$E")"
ok "label" lbl "$(field 13 "$E")"

t "c. a plain tool call and a PostToolUse write nothing"
fresh "$S"
run_hook "$HOOK" "$S" "$(payload PreToolUse '{"tool_name":"Bash","tool_input":{"command":"ls"}}')"
run_hook "$HOOK" "$S" "$(payload PostToolUse '{"tool_name":"AskUserQuestion"}')"
ok "no events.tsv" none "$(lines "$E")"

t "d. AskUserQuestion"
fresh "$S"
run_hook "$HOOK" "$S" "$(payload PreToolUse '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Pick one?"}]}}')"
ok "one line" 1 "$(lines "$E")"
ok "tool" AskUserQuestion "$(field 10 "$E")"
ok "text" "Pick one?" "$(field 12 "$E")"

t "e. ExitPlanMode takes the first non-empty line, without the heading marker"
fresh "$S"
run_hook "$HOOK" "$S" "$(payload PreToolUse "$(jq -nc '{tool_name:"ExitPlanMode",tool_input:{plan:"\n\n  \n# Plan: refactor the parser\n\nstep 1"}}')")"
ok "tool" ExitPlanMode "$(field 10 "$E")"
ok "text" "Plan: refactor the parser" "$(field 12 "$E")"

t "f. a Notification"
fresh "$S"
run_hook "$HOOK" "$S" "$(payload Notification '{"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}')"
ok "sub" permission_prompt "$(field 11 "$E")"
ok "text" "Claude needs your permission to use Bash" "$(field 12 "$E")"
fresh "$S"
run_hook "$HOOK" "$S" "$(payload Notification '{"notificationType":"idle_prompt","message":"Claude is waiting for your input"}')"
ok "an idle ping is written too, under the camel-case name" idle_prompt "$(field 11 "$E")"

t "g. SubagentStop with an agent_id"
fresh "$S"
mkdir -p "$S/sub"; printf '1\tx\n' >"$S/sub/7.a1"
run_hook "$HOOK" "$S" "$(payload SubagentStop '{"agent_id":"a1","agent_type":"Explore"}')"
ok "one line" 1 "$(lines "$E")"
ok "agent" a1 "$(field 5 "$E")"
ok "sub" Explore "$(field 11 "$E")"
ok "the subagent record is still removed" 0 "$([ -e "$S/sub/7.a1" ] && echo 1 || echo 0)"

t "h. sanitising and the 240 clip"
fresh "$S"
run_hook "$HOOK" "$S" "$(payload Notification "$(jq -nc --arg m "$(printf 'one\ttwo\nthree')" '{notification_type:"x",message:$m}')")"
ok "one line, tab and newline gone" 1 "$(lines "$E")"
ok "13 fields" 13 "$(nf "$E")"
ok "replaced by spaces" "one two three" "$(field 12 "$E")"
fresh "$S"
LONG=$(printf 'x%.0s' $(seq 1 300))
run_hook "$HOOK" "$S" "$(payload PreToolUse "$(jq -nc --arg q "$LONG" '{tool_name:"AskUserQuestion",tool_input:{questions:[{question:$q}]}}')")"
TXT=$(field 12 "$E")
ok "240 characters" 240 "$(printf '%s' "$TXT" | jq -R 'length')"
ok "ending in an ellipsis" "…" "$(printf '%s' "$TXT" | jq -rR '.[-1:]')"

t "i. a malformed tool_input costs nothing"
fresh "$S"
run_hook "$HOOK" "$S" "$(payload PreToolUse '{"tool_name":"AskUserQuestion","tool_input":{"questions":"nope"}}')"
ok "the state record is written" 1 "$([ -e "$S/7.tsv" ] && echo 1 || echo 0)"
ok "the event is written" 1 "$(lines "$E")"
ok "with empty text" "" "$(field 12 "$E")"
fresh "$S"
run_hook "$HOOK" "$S" "$(payload PreToolUse '{"tool_name":"ExitPlanMode","tool_input":{"plan":5}}')"
ok "a numeric plan: the state record is written" 1 "$([ -e "$S/7.tsv" ] && echo 1 || echo 0)"
ok "...and the event has empty text" "" "$(field 12 "$E")"

t "j. a headless session has key s-<sid> and no pane"
fresh "$S"
printf '%s' "$(payload Stop)" |
  env -u TMUX_PANE PATH="$SHIM:$PATH" TMUX="$DEAD" TA_STATE_DIR="$S" sh "$HOOK" >/dev/null 2>&1
ok "key" s-sid-1 "$(field 3 "$E")"
ok "pane is empty" "" "$(field 6 "$E")"
ok "13 fields" 13 "$(nf "$E")"

t "k. the state record and history.tsv are byte for byte main's"
FIXED="$ROOT/fixed"; mkdir -p "$FIXED"
printf '#!/bin/sh\necho 1700000000\n' >"$FIXED/date"; chmod +x "$FIXED/date"
A="$ROOT/ka"; B="$ROOT/kb"; fresh "$A"; rm -rf "$B"; mkdir -p "$B"
same=1
step() {  # <label> <payload>
  printf '%s' "$2" | env PATH="$FIXED:$SHIM:$PATH" TMUX="$DEAD" TMUX_PANE=%7 TA_STATE_DIR="$A" sh "$HOOK" >/dev/null 2>&1
  printf '%s' "$2" | env PATH="$FIXED:$SHIM:$PATH" TMUX="$DEAD" TMUX_PANE=%7 TA_STATE_DIR="$B" sh "$HOOK_MAIN" >/dev/null 2>&1
  if diff -r -x events.tsv -x events.on "$A" "$B" >"$ROOT/diff.log" 2>&1; then
    ok "identical after $1" 1 1
  else
    ok "identical after $1" identical "$(head -5 "$ROOT/diff.log" | cut -c1-200)"
  fi
}
step SessionStart "$(payload SessionStart '{"source":"startup"}')"
step UserPromptSubmit "$(payload UserPromptSubmit '{"prompt":"hello there"}')"
step "PreToolUse Bash" "$(payload PreToolUse '{"tool_name":"Bash","tool_input":{"command":"ls"}}')"
step Notification "$(payload Notification '{"notification_type":"permission_prompt","message":"needs you"}')"
step Stop "$(payload Stop)"
step SessionEnd "$(payload SessionEnd '{"reason":"clear"}')"
ok "the new hook did write its stream meanwhile" 5 "$(lines "$A/events.tsv" | tr -d ' ')"
ok "history.tsv has lines in both" 3 "$(lines "$B/history.tsv")"

t "l. no new process"
# Every external program the hook can run, logged by name and then exec'd for
# real; the real paths are resolved before PATH changes.
LSHIM="$ROOT/lshim"; mkdir -p "$LSHIM"; CALLS="$ROOT/calls.log"
for prog in jq date tmux ps awk cat wc mv rm; do
  real=$(command -v "$prog") || { echo "events.sh: no $prog"; exit 1; }
  printf '#!/bin/sh\nprintf "%%s\\n" %s >>"%s"\nexec "%s" "$@"\n' "$prog" "$CALLS" "$real" >"$LSHIM/$prog"
  chmod +x "$LSHIM/$prog"
done
count() {  # <hook> <state dir> <payload> — the programs started, sorted, joined
  : >"$CALLS"
  printf '%s' "$3" | env PATH="$LSHIM:$PATH" TMUX="$DEAD" TMUX_PANE=%7 TA_STATE_DIR="$2" sh "$1" >/dev/null 2>&1
  sort "$CALLS" | tr '\n' ' '
}
i=0
while IFS= read -r p; do
  i=$((i+1)); fresh "$ROOT/la$i"; rm -rf "$ROOT/lb$i"; mkdir -p "$ROOT/lb$i"
  new=$(count "$HOOK" "$ROOT/la$i" "$p")
  old=$(count "$HOOK_MAIN" "$ROOT/lb$i" "$p")
  ok "same programs: $(printf '%s' "$p" | jq -r '.hook_event_name + " " + (.tool_name // "")')" "$old" "$new"
  ok "...and some were started at all" 1 "$([ -n "$old" ] && echo 1 || echo 0)"
done <<EOP
$(payload PreToolUse '{"tool_name":"Bash","tool_input":{"command":"ls"}}')
$(payload PreToolUse '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Pick?"}]}}')
$(payload Stop)
$(payload Notification '{"notification_type":"permission_prompt","message":"m"}')
EOP
ok "the AskUserQuestion run really wrote an event" 1 "$(lines "$ROOT/la2/events.tsv")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
