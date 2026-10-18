#!/usr/bin/env bash
#
# tests/events.sh — the event stream of the state hook: <state dir>/events.tsv,
# one line per event worth a notification, appended while the switch
# <state dir>/events.on exists. The notify plugin follows that file, and the hook
# runs on every tool call of every session, so two things are pinned besides the
# lines themselves: the state record and history.tsv stay byte for byte what the
# merge base with origin/main (and this hook with the switch off) write, and the
# hook starts no program the merge base's does not, SessionStart excepted.
#
# No tmux server is involved at all. Every run has $TMUX pointed at a socket that
# does not exist and a logging `tmux` shim first on $PATH, so the hook can neither
# see nor reach any real server. NOTHING HERE MAY TOUCH THE DEFAULT TMUX SOCKET.
#
# bash 3.2, runnable from any cwd, non-zero exit on any failing check.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# A suite that is not run against a scratch default server aborts here, before it can reach the live one (tests/scratch-guard.sh).
. "$HERE/scratch-guard.sh" && scratch_guard events.sh || exit 1
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

# The suite runs inside a real Claude session, which exports this; the hook
# reads it as "the claude I am running inside" and would classify these runs
# against that session's ancestry.
unset CLAUDE_PID

SHIM="$ROOT/shim"; mkdir -p "$SHIM"
cat >"$SHIM/tmux" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$SHIM/tmux"
DEAD="$ROOT/no-such-socket,0,0"

# The reference hook for the byte-for-byte and process checks: the one at the
# merge base with origin/main, so the reference does not move when main does and
# the comparisons keep meaning "what this branch changed". Where that cannot be
# resolved (no remote, a shallow clone) the comparisons against it print SKIP and
# the rest still runs.
HOOK_MAIN="$ROOT/hook-main.sh"
HAVE_REF=0
BASE=$(git -C "$HERE/.." merge-base HEAD origin/main 2>/dev/null)
if [ -n "$BASE" ] &&
   git -C "$HERE/.." show "$BASE:hooks/tmux-agent-state.sh" >"$HOOK_MAIN" 2>/dev/null &&
   [ -s "$HOOK_MAIN" ]; then
  HAVE_REF=1
fi

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

t "c. a plain tool call writes nothing; the answer to a question is written"
fresh "$S"
run_hook "$HOOK" "$S" "$(payload PreToolUse '{"tool_name":"Bash","tool_input":{"command":"ls"}}')"
run_hook "$HOOK" "$S" "$(payload PostToolUse '{"tool_name":"Bash","tool_response":"x"}')"
ok "a Bash PreToolUse and PostToolUse: no events.tsv" none "$(lines "$E")"
fresh "$S"
run_hook "$HOOK" "$S" "$(payload PostToolUse '{"tool_name":"AskUserQuestion","tool_response":{"answers":{"q":"a"}}}')"
ok "AskUserQuestion answered: one line" 1 "$(lines "$E")"
ok "...event" PostToolUse "$(field 2 "$E")"
ok "...tool" AskUserQuestion "$(field 10 "$E")"
ok "...no text" "" "$(field 12 "$E")"
ok "...13 fields" 13 "$(nf "$E")"
fresh "$S"
run_hook "$HOOK" "$S" "$(payload PostToolUse '{"tool_name":"ExitPlanMode","tool_response":"approved"}')"
ok "ExitPlanMode approved: one line" 1 "$(lines "$E")"
ok "...event" PostToolUse "$(field 2 "$E")"
ok "...tool" ExitPlanMode "$(field 10 "$E")"
ok "...no text" "" "$(field 12 "$E")"

t "c2. a Stop carries the first non-empty line of last_assistant_message"
fresh "$S"
run_hook "$HOOK" "$S" "$(payload Stop "$(jq -nc '{last_assistant_message:"\n  \nFirst   line here\nsecond line"}')")"
ok "first non-empty line, collapsed" "First line here" "$(field 12 "$E")"
fresh "$S"
run_hook "$HOOK" "$S" "$(payload Stop)"
ok "a Stop without the field: empty text" "" "$(field 12 "$E")"
ok "...and still one line" 1 "$(lines "$E")"

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

t "k. the state record and history.tsv are byte for byte the same"
# Two comparisons, each after every payload. Against the reference hook (the merge
# base with origin/main): the branch changed nothing a reader of the state record
# or of history.tsv sees. Against this same hook with the switch off: the stream
# is a pure add-on, and this stays meaningful after the branch is merged, when
# the reference is no longer a different hook.
FIXED="$ROOT/fixed"; mkdir -p "$FIXED"
printf '#!/bin/sh\necho 1700000000\n' >"$FIXED/date"; chmod +x "$FIXED/date"
# The reference reads the clock with `date`; this branch's hook reads it inside the
# one jq it runs, as (now|floor), so the same moment is fixed there: a jq that
# puts the epoch in place of that expression in the program it is given, and is
# the real jq in every other respect. The reference's program has no such
# expression and goes through untouched.
REALJQ=$(command -v jq)
cat >"$FIXED/jq" <<SH
#!/bin/sh
for a in "\$@"; do
  shift
  case \$a in *'(now|floor)'*) a=\$(printf '%s' "\$a" | sed 's/(now|floor)/1700000000/') ;; esac
  set -- "\$@" "\$a"
done
exec "$REALJQ" "\$@"
SH
chmod +x "$FIXED/jq"
A="$ROOT/ka"; B="$ROOT/kb"; C="$ROOT/kc"; fresh "$A"; rm -rf "$B" "$C"; mkdir -p "$B" "$C"
same=1
[ "$HAVE_REF" = 1 ] || echo "  SKIP the comparisons against the merge-base hook: it cannot be resolved here"
step() {  # <label> <payload>
  printf '%s' "$2" | env PATH="$FIXED:$SHIM:$PATH" TMUX="$DEAD" TMUX_PANE=%7 TA_STATE_DIR="$A" sh "$HOOK" >/dev/null 2>&1
  printf '%s' "$2" | env PATH="$FIXED:$SHIM:$PATH" TMUX="$DEAD" TMUX_PANE=%7 TA_STATE_DIR="$C" sh "$HOOK" >/dev/null 2>&1
  if [ "$HAVE_REF" = 1 ]; then
    printf '%s' "$2" | env PATH="$FIXED:$SHIM:$PATH" TMUX="$DEAD" TMUX_PANE=%7 TA_STATE_DIR="$B" sh "$HOOK_MAIN" >/dev/null 2>&1
    if diff -r -x events.tsv -x events.on "$A" "$B" >"$ROOT/diff.log" 2>&1; then
      ok "identical to the reference after $1" 1 1
    else
      ok "identical to the reference after $1" identical "$(head -5 "$ROOT/diff.log" | cut -c1-200)"
    fi
  fi
  if diff -r -x events.tsv -x events.on "$A" "$C" >"$ROOT/diff.log" 2>&1; then
    ok "identical to the switch off after $1" 1 1
  else
    ok "identical to the switch off after $1" identical "$(head -5 "$ROOT/diff.log" | cut -c1-200)"
  fi
}
step SessionStart "$(payload SessionStart '{"source":"startup"}')"
step UserPromptSubmit "$(payload UserPromptSubmit '{"prompt":"hello there"}')"
step "PreToolUse Bash" "$(payload PreToolUse '{"tool_name":"Bash","tool_input":{"command":"ls"}}')"
step Notification "$(payload Notification '{"notification_type":"permission_prompt","message":"needs you"}')"
step Stop "$(payload Stop)"
step SessionEnd "$(payload SessionEnd '{"reason":"clear"}')"
ok "the new hook did write its stream meanwhile" 5 "$(lines "$A/events.tsv" | tr -d ' ')"
ok "history.tsv has lines in both" 3 "$(lines "$C/history.tsv")"
ok "the switch-off run wrote no stream" none "$(lines "$C/events.tsv")"
# Odd payloads: whatever each hook makes of them (a record, or nothing at all
# when jq rejects the payload), both must make the same.
BIG=$(printf 'y%.0s' $(seq 1 10240))
step "an empty tool_name on PreToolUse" "$(payload PreToolUse '{"tool_name":""}')"
step "a 10 KB Notification message" "$(payload Notification "$(jq -nc --arg m "$BIG" '{notification_type:"permission_prompt",message:$m}')")"
step "tool_input as a string" "$(payload PreToolUse '{"tool_name":"Bash","tool_input":"ls -l"}')"
step "message as an array" "$(payload Notification '{"notification_type":"permission_prompt","message":["a","b"]}')"
step "message as an object" "$(payload Notification '{"notification_type":"permission_prompt","message":{"k":"v"}}')"
step "questions: []" "$(payload PreToolUse '{"tool_name":"AskUserQuestion","tool_input":{"questions":[]}}')"
step "plan: null" "$(payload PreToolUse '{"tool_name":"ExitPlanMode","tool_input":{"plan":null}}')"
step "Stop with a multi-line last_assistant_message" "$(payload Stop "$(jq -nc '{last_assistant_message:"one\ntwo"}')")"
step "Stop with last_assistant_message as an object" "$(payload Stop '{"last_assistant_message":{"k":"v"}}')"
step "Stop with a 10 KB last_assistant_message" "$(payload Stop "$(jq -nc --arg m "$BIG" '{last_assistant_message:$m}')")"
step "PostToolUse of AskUserQuestion" "$(payload PostToolUse '{"tool_name":"AskUserQuestion","tool_response":{"answers":{}}}')"

t "l. no new process, SessionStart excepted"
# Two kinds of check: absolute ones from the logged calls (exactly one jq, at most
# one tmux), and comparisons with this same hook run with the switch off, which
# is what "the stream costs no process" means. The merge-base hook is no
# reference for this: once child sessions were merged it already starts the awk
# that reads the record on every event, and at SessionStart the `ps` and the
# pane map of the ancestry walk, none of which the stream has anything to do with.
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
ncall() { printf '%s' "$1" | tr ' ' '\n' | grep -c "^$2\$"; }  # <calls> <program>
atmost1() { [ "$1" -le 1 ] && echo 1 || echo "$1"; }
i=0
while IFS= read -r p; do
  i=$((i+1)); fresh "$ROOT/la$i"
  lbl=$(printf '%s' "$p" | jq -r '.hook_event_name + " " + (.tool_name // "")')
  new=$(count "$HOOK" "$ROOT/la$i" "$p")
  ok "exactly one jq: $lbl" 1 "$(ncall "$new" jq)"
  ok "at most one tmux: $lbl" 1 "$(atmost1 "$(ncall "$new" tmux)")"
  ok "no wc: $lbl" 0 "$(ncall "$new" wc)"
  # The payload goes into jq on stdin and jq reads the clock: no cat, no date.
  ok "no cat and no date: $lbl" 0 "$(( $(ncall "$new" cat) + $(ncall "$new" date) ))"
  rm -rf "$ROOT/lb$i"; mkdir -p "$ROOT/lb$i"
  old=$(count "$HOOK" "$ROOT/lb$i" "$p")
  ok "same programs as with the switch off: $lbl" "$old" "$new"
  ok "...and some were started at all" 1 "$([ -n "$old" ] && echo 1 || echo 0)"
done <<EOP
$(payload PreToolUse '{"tool_name":"Bash","tool_input":{"command":"ls"}}')
$(payload PreToolUse '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Pick?"}]}}')
$(payload Stop)
$(payload Notification '{"notification_type":"permission_prompt","message":"m"}')
$(payload PostToolUse '{"tool_name":"AskUserQuestion","tool_response":{}}')
EOP
ok "the AskUserQuestion run really wrote an event" 1 "$(lines "$ROOT/la2/events.tsv")"
ok "the answer run really wrote an event" 1 "$(lines "$ROOT/la5/events.tsv")"
# SessionStart is the one event that starts a program the switch-off run does
# not: the size check for the rotation of events.tsv is a wc, and only when the
# file exists. Pinned here so the exception is stated, not hidden: exactly one
# more wc. Its tmux calls are the ancestry walk's pane map plus the pane option,
# so the bound there is "no more than with the switch off", not one.
nwc() { printf '%s' "$1" | tr ' ' '\n' | grep -c '^wc$'; }
SS=$(payload SessionStart '{"source":"startup"}')
fresh "$ROOT/lsa"; printf '1\n' >"$ROOT/lsa/events.tsv"; printf '1\n' >"$ROOT/lsa/history.tsv"
rm -rf "$ROOT/lsb"; mkdir -p "$ROOT/lsb"; printf '1\n' >"$ROOT/lsb/history.tsv"
new=$(count "$HOOK" "$ROOT/lsa" "$SS")
ok "SessionStart with both files: exactly one jq" 1 "$(ncall "$new" jq)"
ok "...and exactly two wc, one per file" 2 "$(nwc "$new")"
old=$(count "$HOOK" "$ROOT/lsb" "$SS")
ok "...no more tmux than with the switch off" "$(ncall "$old" tmux)" "$(ncall "$new" tmux)"
ok "...exactly one more wc than with the switch off" "$(($(nwc "$old") + 1))" "$(nwc "$new")"
fresh "$ROOT/lsa"; printf '1\n' >"$ROOT/lsa/events.tsv"
new=$(count "$HOOK" "$ROOT/lsa" "$SS")
ok "SessionStart with only events.tsv: exactly one wc" 1 "$(nwc "$new")"
fresh "$ROOT/lsa"; rm -rf "$ROOT/lsb"; mkdir -p "$ROOT/lsb"
new=$(count "$HOOK" "$ROOT/lsa" "$SS")
ok "SessionStart with no events.tsv yet: no wc" 0 "$(nwc "$new")"
old=$(count "$HOOK" "$ROOT/lsb" "$SS")
ok "...same programs as with the switch off" "$old" "$new"

t "m. a file over 5 MiB is rotated on SessionStart, a smaller one is not"
for f in events history; do
  fresh "$S"; F="$S/$f.tsv"
  dd if=/dev/zero of="$F" bs=1048576 count=6 2>/dev/null
  run_hook "$HOOK" "$S" "$(payload SessionStart '{"source":"startup"}')"
  ok "$f.tsv over the limit: moved to $f.tsv.1" 6291456 "$(wc -c <"$F.1" 2>/dev/null | tr -d ' ')"
  ok "...and a fresh $f.tsv holds the new line" 1 "$(lines "$F")"
  fresh "$S"
  printf 'old\n' >"$F"
  run_hook "$HOOK" "$S" "$(payload SessionStart '{"source":"startup"}')"
  ok "$f.tsv under the limit: not moved" none "$(lines "$F.1")"
  ok "...and the new line is appended" 2 "$(lines "$F")"
done

t "o. files the hook creates are 0600 (umask 077)"
fresh "$S"
run_hook "$HOOK" "$S" "$(payload SessionStart '{"source":"startup"}')"
ok "a new state record" 600 "$(stat -f %Lp "$S/7.tsv")"
ok "a new events.tsv" 600 "$(stat -f %Lp "$E")"
ok "a new history.tsv" 600 "$(stat -f %Lp "$S/history.tsv")"
fresh "$S"; dd if=/dev/zero of="$E" bs=1048576 count=6 2>/dev/null
run_hook "$HOOK" "$S" "$(payload SessionStart '{"source":"startup"}')"
ok "events.tsv recreated after a rotation" 600 "$(stat -f %Lp "$E")"

t "n. a background job without TMUX_PANE, re-keyed off its parent's pane"
# The hook finds the pane by walking up to an ancestor that tmux lists as a pane
# root; a tmux shim naming this very script's pid as the root of pane %9 stands in
# for that. Session sid-owner owns pane 9's record, so sid-bg is given s-sid-bg.
WSHIM="$ROOT/wshim"; mkdir -p "$WSHIM"
printf '#!/bin/sh\necho "MAP %s %%9"\n' "$$" >"$WSHIM/tmux"; chmod +x "$WSHIM/tmux"
fresh "$S"
printf '%s' "$(payload Stop '{"session_id":"sid-owner"}')" |
  env PATH="$SHIM:$PATH" TMUX="$DEAD" TMUX_PANE=%9 TA_STATE_DIR="$S" sh "$HOOK" >/dev/null 2>&1
printf '%s' "$(payload Stop '{"session_id":"sid-bg"}')" |
  env -u TMUX_PANE PATH="$WSHIM:$PATH" TMUX="$DEAD" TA_STATE_DIR="$S" sh "$HOOK" >/dev/null 2>&1
ok "two lines" 2 "$(lines "$E")"
ok "the owner's key is the pane" 9 "$(field 3 "$E" 1)"
ok "the owner's pane column is set" %9 "$(field 6 "$E" 1)"
ok "the job's key is s-<sid>" s-sid-bg "$(field 3 "$E" 2)"
ok "the job's pane column is empty" "" "$(field 6 "$E" 2)"
ok "13 fields" 13 "$(nf "$E" 2)"
ok "pane 9's record still belongs to the owner" sid-owner "$(field 3 "$S/9.tsv")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
