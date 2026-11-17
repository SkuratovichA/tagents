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
for prog in jq date tmux ps awk cat wc mv rm mkdir find sed; do
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

t "p. field 13 of a pane-less session is the label its record keeps"
# A child inherits TA_LABEL from its parent; the hook blanks that in the child's
# record (ta_disown), and the stream carries what the record says. The child's
# record is written by hand with the field 10 the hook would have left in it.
# Run without TMUX_PANE, so the hook takes the record of s-sid-kid (rule 1).
kid() {  # <record field 10> [env assignments...] — one Stop of the child
  local f10=$1; shift
  fresh "$S"
  printf '%s\t%s\t%s\t%s\t\t\t\t%s\t\t%s\t%s\t%s\n' 1 done sid-kid /work "$$" "$f10" s-sid-par sid-par \
    >"$S/s-sid-kid.tsv"
  printf '%s' "$(payload Stop '{"session_id":"sid-kid"}')" |
    env -u TMUX_PANE PATH="$SHIM:$PATH" TMUX="$DEAD" TA_STATE_DIR="$S" "$@" sh "$HOOK" >/dev/null 2>&1
}
kid "" TA_LABEL=lbl
ok "the child's key is s-<sid>" s-sid-kid "$(field 3 "$E")"
ok "an inherited label gives an empty field 13" "" "$(field 13 "$E")"
ok "...still 13 fields" 13 "$(nf "$E")"
kid own TA_LABEL=own
ok "a label of the child's own is kept in field 13" own "$(field 13 "$E")"
fresh "$S"
run_hook "$HOOK" "$S" "$(payload Stop)" TA_LABEL=lbl
ok "the parent's own line still carries its label" lbl "$(field 13 "$E")"
fresh "$S"
printf '%s' "$(payload Stop '{"session_id":"sid-new"}')" |
  env -u TMUX_PANE PATH="$SHIM:$PATH" TMUX="$DEAD" TA_STATE_DIR="$S" TA_LABEL=job sh "$HOOK" >/dev/null 2>&1
ok "a new headless record keeps the label it starts with" job "$(field 13 "$E")"

t "q. a late PostToolUse does not overwrite a newer state"
# Claude Code 2.1.319 runs the PostToolUse of a call that finishes after a new message interrupted the turn, so it can arrive after the next turn's events.
rec_state() { field 2 "$S/7.tsv"; }
tid() { printf '{"tool_name":"Bash","tool_use_id":"%s"}' "$1"; }
fresh "$S"
run_hook "$HOOK" "$S" "$(payload UserPromptSubmit '{"prompt":"one"}')"
run_hook "$HOOK" "$S" "$(payload PreToolUse "$(tid toolu_A)")"
run_hook "$HOOK" "$S" "$(payload UserPromptSubmit '{"prompt":"two"}')"
run_hook "$HOOK" "$S" "$(payload Notification '{"notification_type":"permission_prompt","message":"needs you"}')"
ok "the Notification of the new turn blocks the session" blocked "$(rec_state)"
run_hook "$HOOK" "$S" "$(payload PostToolUse "$(tid toolu_A)")"
ok "...and the late PostToolUse of the interrupted turn leaves it blocked" blocked "$(rec_state)"
run_hook "$HOOK" "$S" "$(payload PreToolUse "$(tid toolu_B)")"
run_hook "$HOOK" "$S" "$(payload Notification '{"notification_type":"permission_prompt","message":"needs you"}')"
run_hook "$HOOK" "$S" "$(payload PostToolUse "$(tid toolu_B)")"
ok "a PostToolUse of a call of this turn still unblocks the row after the prompt is answered" working "$(rec_state)"
run_hook "$HOOK" "$S" "$(payload Stop)"
run_hook "$HOOK" "$S" "$(payload PostToolUse "$(tid toolu_B)")"
ok "a late PostToolUse after Stop leaves the session done" done "$(rec_state)"
run_hook "$HOOK" "$S" "$(payload PostToolUse '{"tool_name":"Bash"}')"
ok "a PostToolUse with no id keeps the old behaviour" working "$(rec_state)"
run_hook "$HOOK" "$S" "$(payload SessionEnd '{"reason":"clear"}')"
ok "SessionEnd removes the list of the turn's calls" 0 "$([ -e "$S/7.tools" ] && echo 1 || echo 0)"
fresh "$S"
run_hook "$HOOK" "$S" "$(payload UserPromptSubmit '{"prompt":"one"}')"
run_hook "$HOOK" "$S" "$(payload Notification '{"notification_type":"permission_prompt","message":"needs you"}')"
rm -f "$S/7.tools"
run_hook "$HOOK" "$S" "$(payload PostToolUse "$(tid toolu_C)")"
ok "with no list of the turn's calls (hook upgraded mid-turn) a PostToolUse applies as before" working "$(rec_state)"
touch -t 200001010000 "$S/old-headless.tools"
run_hook "$HOOK" "$S" "$(payload PreToolUse "$(tid toolu_D)")"
ok "a list nobody touched for days is swept when a new one is created" 0 "$([ -e "$S/old-headless.tools" ] && echo 1 || echo 0)"
ok "...and the new one is kept" 1 "$([ -e "$S/7.tools" ] && echo 1 || echo 0)"

t "r. a transcript with a line cut through an emoji does not matter to the hook"
# The hook records the transcript's path and never opens the file; Claude Code before 2.1.309 left such lines on disk.
fresh "$S"
printf '{"type":"user","message":{"content":"a"}}\n{"type":"assistant","message":{"content":"cut \360\237\n{"type":"user","message":{"content":"b"}}\n' >"$ROOT/cut.jsonl"
run_hook "$HOOK" "$S" "$(payload Stop "$(jq -nc --arg p "$ROOT/cut.jsonl" '{transcript_path:$p}')")"
ok "the state record is written" done "$(rec_state)"
ok "...and names the transcript" "$ROOT/cut.jsonl" "$(field 5 "$S/7.tsv")"

t "s. a warning a subagent asked for goes away when that subagent goes on"
# A Notification that is not the idle ping blocks the record. When it may have come from a subagent (the main conversation has no call of its own waiting), the hook remembers the state to go back to in perm/<key>, with the subagents that had a call in flight; an event of the last of them puts it back.
P="$S/perm/7"
# a TMUX shim that logs what it is asked, for the checks that name the tmux call
TSHIM="$ROOT/tshim"; mkdir -p "$TSHIM"; TLOG="$ROOT/tmux.log"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\nexit 1\n' "$TLOG" >"$TSHIM/tmux"; chmod +x "$TSHIM/tmux"
rec_detail() { field 6 "$S/7.tsv"; }
ev()    { run_hook "$HOOK" "$S" "$(payload "$@")"; }
agpre() { ev PreToolUse "$(jq -nc --arg a "$1" '{agent_id:$a,tool_name:"Bash",tool_input:{command:("sleep " + $a)},tool_use_id:("t-" + $a)}')"; }
agpost() { ev PostToolUse "$(jq -nc --arg a "$1" '{agent_id:$a,tool_name:"Bash",tool_use_id:("t-" + $a)}')"; }
ask() { ev Notification '{"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'; }
perm_has() { [ -e "$P" ] && echo 1 || echo 0; }
done_turn() { fresh "$S"; ev UserPromptSubmit '{"prompt":"go"}'; ev Stop; }

done_turn
agpre a1
ask
ok "background: the notification blocks the record" blocked "$(rec_state)"
ok "...and perm/<key> is written" 1 "$(perm_has)"
ok "...line 1 is the state to go back to" done "$(sed -n 1p "$P")"
ok "...line 2 is its detail" "" "$(sed -n 2p "$P")"
ok "...line 3 lists the agents in flight between spaces" " a1 " "$(sed -n 3p "$P")"
ok "...three lines" 3 "$(wc -l <"$P" | tr -d ' ')"
: >"$TLOG"
run_hook "$HOOK" "$S" "$(payload PostToolUse '{"agent_id":"a1","tool_name":"Bash","tool_use_id":"t-a1"}')" PATH="$TSHIM:$PATH"
ok "...the asker's PostToolUse puts done back" done "$(rec_state)"
ok "...the perm file is gone" 0 "$(perm_has)"
ok "...one tmux call rings the channel and sets @agent" "set -gF @tagents_evgen #{e|+|:#{@tagents_evgen},1} ; wait-for -S tagents-ev ; set -p -t %7 @agent done" "$(cat "$TLOG" | tr '\n' ' ' | sed 's/ $//')"

# the detail of the record comes back too, and the other fields stay
fresh "$S"
ev UserPromptSubmit '{"prompt":"go"}'
ev PreToolUse '{"tool_name":"Read","tool_input":{"file_path":"/x"},"tool_use_id":"m1"}'
ev PostToolUse '{"tool_name":"Read","tool_use_id":"m1"}'
agpre a1
BEFORE=$(cat "$S/7.tsv")
ask
ok "a working record with a finished call: remembered" 1 "$(perm_has)"
agpost a1
ok "...the state is working again" working "$(rec_state)"
ok "...with the old detail" "Read ✓" "$(rec_detail)"
ok "...and every other field as it was, but the time" "$(printf '%s' "$BEFORE" | cut -f2-)" "$(cut -f2- "$S/7.tsv")"

t "s2. two subagents in flight: the first to go on keeps the warning, the second clears it"
done_turn
agpre a1; agpre a2
ask
ok "both are listed" " a1 a2 " "$(sed -n 3p "$P")"
agpost a1
ok "the first one's event keeps blocked" blocked "$(rec_state)"
ok "...and the file lists the other one" " a2 " "$(sed -n 3p "$P")"
agpost a1
ok "...an event of the one that is already off the list changes nothing" blocked "$(rec_state)"
agpost a2
ok "the second one's event clears it" done "$(rec_state)"
ok "...and the file is gone" 0 "$(perm_has)"

t "s3. a subagent whose call had finished before the notification is not on the list"
done_turn
agpre a1; agpre a2; agpost a2
ask
ok "only the one with a call in flight is listed" " a1 " "$(sed -n 3p "$P")"
agpre a2; agpost a2
ok "events of the other one change nothing" blocked "$(rec_state)"
ok "...and the file stays as it was" " a1 " "$(sed -n 3p "$P")"
done_turn
agpre a1; agpost a1
ask
ok "with every subagent's call finished nothing is remembered" 0 "$(perm_has)"
done_turn
ask
ok "with no subagent at all nothing is remembered" 0 "$(perm_has)"

t "s4. a call of the main conversation is waiting"
fresh "$S"
ev UserPromptSubmit '{"prompt":"go"}'
ev PreToolUse '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Pick?"}]},"tool_use_id":"q1"}'
agpre a1
ask
ok "AskUserQuestion pending: nothing is remembered" 0 "$(perm_has)"
agpost a1
ok "...and the subagent's call ending leaves the row blocked" blocked "$(rec_state)"
fresh "$S"
ev UserPromptSubmit '{"prompt":"go"}'
ev PreToolUse '{"tool_name":"Bash","tool_input":{"command":"rm x"},"tool_use_id":"b1"}'
agpre a1
ask
ok "a Bash call in flight in the main conversation: nothing is remembered" 0 "$(perm_has)"
agpost a1
ok "...and the row stays blocked" blocked "$(rec_state)"

t "s5. an Agent call in flight in the main conversation is not a prompt for the owner"
fresh "$S"
ev UserPromptSubmit '{"prompt":"go"}'
ev PreToolUse '{"tool_name":"Agent","tool_input":{"description":"look around"},"tool_use_id":"g1"}'
agpre a1
ask
ok "remembered" 1 "$(perm_has)"
agpost a1
ok "the subagent's next event puts working back" working "$(rec_state)"
ok "...with the detail of the Agent call" "Agent look around" "$(rec_detail)"

t "s6. the main conversation goes on, or ends"
done_turn
agpre a1
ask
ev PreToolUse '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"x1"}'
ok "a main-conversation event removes the file" 0 "$(perm_has)"
agpost a1
ok "...and the row is left as that event made it" working "$(rec_state)"
done_turn
agpre a1
ask
ev Notification '{"notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
ok "an idle ping removes it as well" 0 "$(perm_has)"
done_turn
agpre a1
ask
ev SessionEnd '{"reason":"clear"}'
ok "SessionEnd removes it" 0 "$(perm_has)"
ok "...with the record" 0 "$([ -e "$S/7.tsv" ] && echo 1 || echo 0)"
# a finished child goes with its parent, and so does what was remembered for it
done_turn
mkdir -p "$S/perm"
printf '1\tblocked\tsid-kid\t/w\t/t\tm\t\t99999999\t\t\t7\tsid-1\n' >"$S/s-sid-kid.tsv"
printf 'done\n\n a1 \n' >"$S/perm/s-sid-kid"
ev SessionEnd '{"reason":"clear"}'
ok "a finished child's record goes with the parent's SessionEnd" 0 "$([ -e "$S/s-sid-kid.tsv" ] && echo 1 || echo 0)"
ok "...and so does its perm file" 0 "$([ -e "$S/perm/s-sid-kid" ] && echo 1 || echo 0)"
# a late PostToolUse of an old turn rewrites nothing and so forgets nothing
fresh "$S"
ev UserPromptSubmit '{"prompt":"go"}'
ev PreToolUse '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"m0"}'
ev Stop
agpre a1
ask
ev PostToolUse '{"tool_name":"Bash","tool_use_id":"m0"}'
ok "a late PostToolUse that the record drops keeps the file" 1 "$(perm_has)"
ok "...and the row stays blocked" blocked "$(rec_state)"

t "s7. the record changed hands, or is no longer blocked"
done_turn
agpre a1
ask
awk -F"$TAB" -v OFS="$TAB" '{ $3="sid-2"; print }' "$S/7.tsv" >"$S/x.tsv" && mv "$S/x.tsv" "$S/7.tsv"
BEFORE=$(cat "$S/7.tsv")
agpost a1
ok "another session id under the same key: the file is removed" 0 "$(perm_has)"
ok "...and the record is left alone" "$BEFORE" "$(cat "$S/7.tsv")"
done_turn
agpre a1
ask
awk -F"$TAB" -v OFS="$TAB" '{ $2="working"; $6="Edit x"; print }' "$S/7.tsv" >"$S/x.tsv" && mv "$S/x.tsv" "$S/7.tsv"
BEFORE=$(cat "$S/7.tsv")
agpost a1
ok "a record that is no longer blocked: the file is removed" 0 "$(perm_has)"
ok "...and the record is left alone" "$BEFORE" "$(cat "$S/7.tsv")"
ok "...no temp file is left in the state directory" 0 "$(ls -a "$S" | grep -c '^\.7\.')"

t "s8. a headless record keeps its ten fields"
fresh "$S"
hl() { printf '%s' "$(payload "$@")" | env -u TMUX_PANE PATH="$SHIM:$PATH" TMUX="$DEAD" TA_STATE_DIR="$S" TA_LABEL=job TA_LOG=/log/x sh "$HOOK" >/dev/null 2>&1; }
hl UserPromptSubmit '{"prompt":"go"}'
hl Stop
hl PreToolUse '{"agent_id":"a1","tool_name":"Bash","tool_input":{"command":"sleep"},"tool_use_id":"t-a1"}'
hl Notification '{"notification_type":"permission_prompt","message":"needs you"}'
HR="$S/s-sid-1.tsv"; HP="$S/perm/s-sid-1"
ok "the notification blocks it" blocked "$(field 2 "$HR")"
ok "...and remembers under the session's key" 1 "$([ -e "$HP" ] && echo 1 || echo 0)"
hl PostToolUse '{"agent_id":"a1","tool_name":"Bash","tool_use_id":"t-a1"}'
ok "the state is back" done "$(field 2 "$HR")"
ok "...still ten fields" 10 "$(nf "$HR")"
ok "...with the log and the label" "/log/x job" "$(field 9 "$HR") $(field 10 "$HR")"
ok "...and the file is gone" 0 "$([ -e "$HP" ] && echo 1 || echo 0)"

t "s9. a subagent event starts no program when there is nothing remembered"
fresh "$ROOT/pa"; mkdir -p "$ROOT/pa/sub" "$ROOT/pa/prompt"; printf '1\tBash x\n' >"$ROOT/pa/sub/7.a1"
PA=$(payload PostToolUse '{"agent_id":"a1","tool_name":"Bash","tool_use_id":"t-a1"}')
new=$(count "$HOOK" "$ROOT/pa" "$PA")
BASE_CALLS="awk jq"   # the awk is the read of the record every event starts; the jq reads the payload
ok "a PostToolUse of a subagent with no perm file: what every event starts, nothing more" "$BASE_CALLS" "$(printf '%s' "$new" | sed 's/ $//')"
if [ "$HAVE_REF" = 1 ]; then
  fresh "$ROOT/pb"; mkdir -p "$ROOT/pb/sub" "$ROOT/pb/prompt"; printf '1\tBash x\n' >"$ROOT/pb/sub/7.a1"
  ok "...the programs the merge-base hook starts" "$(count "$HOOK_MAIN" "$ROOT/pb" "$PA")" "$new"
fi
fresh "$ROOT/pc"; mkdir -p "$ROOT/pc/sub" "$ROOT/pc/prompt" "$ROOT/pc/perm"; printf '1\tBash x\n' >"$ROOT/pc/sub/7.a1"; printf 'done\n\n a9 \n' >"$ROOT/pc/perm/7"
ok "an agent that is not on the list: the same programs" "$BASE_CALLS" "$(count "$HOOK" "$ROOT/pc" "$PA" | sed 's/ $//')"
ok "...and the file is untouched" " a9 " "$(sed -n 3p "$ROOT/pc/perm/7")"
NT=$(payload Notification '{"notification_type":"permission_prompt","message":"m"}')
fresh "$ROOT/pe"; printf '1\tdone\tsid-1\t/w\t/t\t\t\n' >"$ROOT/pe/7.tsv"
n0=$(ncall "$(count "$HOOK" "$ROOT/pe" "$NT")" awk)
if [ "$HAVE_REF" = 1 ]; then
  fresh "$ROOT/pb"; printf '1\tdone\tsid-1\t/w\t/t\t\t\n' >"$ROOT/pb/7.tsv"
  ok "a Notification with no subagent starts no more awk than the merge-base hook" "$(ncall "$(count "$HOOK_MAIN" "$ROOT/pb" "$NT")" awk)" "$n0"
fi
fresh "$ROOT/pd"; mkdir -p "$ROOT/pd/sub" "$ROOT/pd/prompt"; printf '%s\tBash x\n' "$(date +%s)" >"$ROOT/pd/sub/7.a1"; printf '1\tdone\tsid-1\t/w\t/t\t\t\n' >"$ROOT/pd/7.tsv"
c=$(count "$HOOK" "$ROOT/pd" "$NT")
ok "a Notification with a subagent in flight: one awk more (the read of the record), and two mv (record, perm file)" "$((n0+1)) 2" "$(ncall "$c" awk) $(ncall "$c" mv)"

t "s10. two subagents that both ask"
done_turn
agpre a1
ask
agpre a2
ask
ok "a second notification keeps the state to go back to" done "$(sed -n 1p "$P")"
ok "...and its detail" "" "$(sed -n 2p "$P")"
ok "...and lists both agents" " a1 a2 " "$(sed -n 3p "$P")"
agpost a1
ok "the first one going on keeps the warning" blocked "$(rec_state)"
agpost a2
ok "the second one going on clears it" done "$(rec_state)"
ok "...and the file is gone" 0 "$(perm_has)"
ev UserPromptSubmit '{"prompt":"go"}'
ev PreToolUse '{"tool_name":"Read","tool_input":{"file_path":"/x"},"tool_use_id":"m1"}'
ev PostToolUse '{"tool_name":"Read","tool_use_id":"m1"}'
agpre a1
ask
agpre a2
ask
ok "a second notification of a working record keeps its detail" "Read ✓" "$(sed -n 2p "$P")"
ev Stop
ok "a main-conversation event still forgets the pair" 0 "$(perm_has)"

t "s11. what a subagent event of an agent that is gone, or a command that ends in a tick, mean"
done_turn
mkdir -p "$S/sub"; printf '%s\tBash sleep\n' "$(( $(date +%s) - 4000 ))" >"$S/sub/7.old"
ask
ok "a subagent file older than SUB_TTL is not an asker" 0 "$(perm_has)"
done_turn
agpre a1
ev PreToolUse '{"agent_id":"a2","tool_name":"Bash","tool_input":{"command":"echo ✓"},"tool_use_id":"t-a2"}'
ask
ok "a command line that ends in a tick is still a call in flight" " a1 a2 " "$(sed -n 3p "$P")"
fresh "$S"
ev UserPromptSubmit '{"prompt":"go"}'
ev PreToolUse '{"tool_name":"Bash","tool_input":{"command":"echo ✓"},"tool_use_id":"b9"}'
agpre a1
ask
ok "...and so is one of the main conversation: nothing is remembered" 0 "$(perm_has)"
fresh "$S"
ev UserPromptSubmit '{"prompt":"go"}'
ev PreToolUse '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"b8"}'
ev PostToolUse '{"tool_name":"Bash","tool_use_id":"b8"}'
agpre a1
ask
ok "a main call that finished (<Tool> ✓) is not in the way" 1 "$(perm_has)"

t "s12. the user's prompt, the Task tool and the other ways a subagent can go on"
fresh "$S"
ev UserPromptSubmit '{"prompt":"Bash ls -la"}'
agpre a1
ask
ok "a working record holding the user's prompt, with an empty sidecar: remembered" 1 "$(perm_has)"
agpost a1
ok "...and the prompt comes back as the detail" "Bash ls -la" "$(rec_detail)"
fresh "$S"
ev UserPromptSubmit '{"prompt":"go"}'
ev PreToolUse '{"tool_name":"Task","tool_input":{"description":"look around"},"tool_use_id":"g2"}'
agpre a1
ask
ok "a Task call in flight in the main conversation: remembered" 1 "$(perm_has)"
agpost a1
ok "...and the subagent's next event puts working back" "working|Task look around" "$(rec_state)|$(rec_detail)"
done_turn
agpre a1
ask
: >"$TLOG"
run_hook "$HOOK" "$S" "$(payload SubagentStop '{"agent_id":"a1","agent_type":"Explore"}')" PATH="$TSHIM:$PATH"
ok "...restoring with one tmux call" 1 "$(wc -l <"$TLOG" | tr -d ' ')"
ok "...that rings the channel and sets @agent" "set -gF @tagents_evgen #{e|+|:#{@tagents_evgen},1} ; wait-for -S tagents-ev ; set -p -t %7 @agent done" "$(tr '\n' ' ' <"$TLOG" | sed 's/ $//')"
ok "...and the subagent's file is gone" 0 "$([ -e "$S/sub/7.a1" ] && echo 1 || echo 0)"

t "s13. a headless restore rings and sets no pane option"
fresh "$S"
hl UserPromptSubmit '{"prompt":"go"}'
hl Stop
hl PreToolUse '{"agent_id":"a1","tool_name":"Bash","tool_input":{"command":"sleep"},"tool_use_id":"t-a1"}'
hl Notification '{"notification_type":"permission_prompt","message":"needs you"}'
: >"$TLOG"
printf '%s' "$(payload PostToolUse '{"agent_id":"a1","tool_name":"Bash","tool_use_id":"t-a1"}')" |
  env -u TMUX_PANE PATH="$TSHIM:$PATH" TMUX="$DEAD" TA_STATE_DIR="$S" TA_LABEL=job TA_LOG=/log/x sh "$HOOK" >/dev/null 2>&1
ok "the headless row is back to done" done "$(field 2 "$S/s-sid-1.tsv")"
ok "...with one tmux call that only rings" "set -gF @tagents_evgen #{e|+|:#{@tagents_evgen},1} ; wait-for -S tagents-ev" "$(tr '\n' ' ' <"$TLOG" | sed 's/ $//')"

t "s14. a child record keeps its twelve fields"
fresh "$S"
printf '%s\t%s\t%s\t%s\t\t\t\t%s\t\t%s\t%s\t%s\n' 1 done sid-kid /work "$$" own s-sid-par sid-par >"$S/s-sid-kid.tsv"
kev() { printf '%s' "$(payload "$1" "$(jq -nc --argjson x "${2:-{\}}" '$x + {session_id:"sid-kid"}')")" |
  env -u TMUX_PANE PATH="$SHIM:$PATH" TMUX="$DEAD" TA_STATE_DIR="$S" sh "$HOOK" >/dev/null 2>&1; }
kev PreToolUse '{"agent_id":"a1","tool_name":"Bash","tool_input":{"command":"sleep"},"tool_use_id":"t-a1"}'
kev Notification '{"notification_type":"permission_prompt","message":"needs you"}'
ok "the child's record is blocked and remembered under its own key" "blocked 1" "$(field 2 "$S/s-sid-kid.tsv") $([ -e "$S/perm/s-sid-kid" ] && echo 1 || echo 0)"
kev PostToolUse '{"agent_id":"a1","tool_name":"Bash","tool_use_id":"t-a1"}'
ok "the state is back" done "$(field 2 "$S/s-sid-kid.tsv")"
ok "...still twelve fields" 12 "$(nf "$S/s-sid-kid.tsv")"
ok "...with the parent's key and session id" "s-sid-par sid-par own" "$(field 11 "$S/s-sid-kid.tsv") $(field 12 "$S/s-sid-kid.tsv") $(field 10 "$S/s-sid-kid.tsv")"

t "s15. perm/ is made only when it is missing"
NT=$(payload Notification '{"notification_type":"permission_prompt","message":"m"}')
nmk() { printf '%s' "$1" | tr ' ' '\n' | grep -c '^mkdir$'; }
fresh "$ROOT/pf"; mkdir -p "$ROOT/pf/sub" "$ROOT/pf/prompt"; printf '%s\tBash x\n' "$(date +%s)" >"$ROOT/pf/sub/7.a1"; printf '1\tdone\tsid-1\t/w\t/t\t\t\n' >"$ROOT/pf/7.tsv"
ok "the first memory makes the directory" 1 "$(nmk "$(count "$HOOK" "$ROOT/pf" "$NT")")"
rm -f "$ROOT/pf/perm/7"; printf '1\tdone\tsid-1\t/w\t/t\t\t\n' >"$ROOT/pf/7.tsv"
ok "the next one finds it" 0 "$(nmk "$(count "$HOOK" "$ROOT/pf" "$NT")")"
c=$(count "$HOOK" "$ROOT/pa" "$PA")
ok "a subagent event starts no mkdir, find or sed" 0 "$(( $(ncall "$c" mkdir) + $(ncall "$c" find) + $(ncall "$c" sed) ))"

t "s16. a memory that was cut short names no state to go back to"
done_turn
agpre a1
ask
: >"$P"
run_hook "$HOOK" "$S" "$(payload PostToolUse '{"agent_id":"a1","tool_name":"Bash","tool_use_id":"t-a1"}')" plist=" a1 " pstate=working
ok "an empty perm file is dropped, whatever the environment holds, and the row stays as it was" "blocked 0" "$(rec_state) $(perm_has)"
done_turn
agpre a1
ask
: >"$P"
ask
ok "a second notification over an empty memory does not write one of empty lines" 0 "$(perm_has)"
ok "...and the row stays blocked" blocked "$(rec_state)"
done_turn
agpre a1
ask
printf 'done\n' >"$P"
agpost a1
ok "a memory with a state and no list names nobody: nothing changes" blocked "$(rec_state)"

t "s17. the two rings of the subagent branch"
RING='set -gF @tagents_evgen #{e|+|:#{@tagents_evgen},1} ; wait-for -S tagents-ev'
tev()  { run_hook "$HOOK" "$S" "$(payload "$@")" PATH="$TSHIM:$PATH"; }
tlog() { tr '\n' ' ' <"$TLOG" | sed 's/ $//'; }
fresh "$S"; : >"$TLOG"
tev PreToolUse '{"agent_id":"a1","tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"t-a1"}'
ok "a new agent_id rings once, and sets no pane option" "$RING" "$(tlog)"
: >"$TLOG"
tev PreToolUse '{"agent_id":"a1","tool_name":"Read","tool_input":{"file_path":"/x"},"tool_use_id":"t-a1b"}'
ok "a second event of the same agent logs nothing" "" "$(tlog)"
tev SubagentStop '{"agent_id":"a1","agent_type":"Explore"}'
ok "a SubagentStop of an existing file rings once" "$RING" "$(tlog)"
: >"$TLOG"
tev SubagentStop '{"agent_id":"a1","agent_type":"Explore"}'
ok "a SubagentStop with no file logs nothing" "" "$(tlog)"

t "s18. the subagent's file is settled before the restore rings"
TSHIM2="$ROOT/tshim2"; mkdir -p "$TSHIM2"; TLOG2="$ROOT/tmux2.log"
cat >"$TSHIM2/tmux" <<'SH'
#!/bin/sh
printf '%s|exists=%s|detail=%s\n' "$*" "$([ -e "$SUBF" ] && echo yes || echo no)" "$(cut -f2 "$SUBF" 2>/dev/null)" >>"$TLOG2"
exit 1
SH
chmod +x "$TSHIM2/tmux"
tev2() { run_hook "$HOOK" "$S" "$(payload "$@")" PATH="$TSHIM2:$PATH" SUBF="$S/sub/7.a1" TLOG2="$TLOG2"; }
done_turn
agpre a1
ask
: >"$TLOG2"
tev2 SubagentStop '{"agent_id":"a1","agent_type":"Explore"}'
ok "at the restore's ring a stopped subagent's file is already gone" "yes" "$(grep -c 'set -p -t %7 @agent done|exists=no|detail=$' "$TLOG2" | sed 's/1/yes/')"
done_turn
agpre a1
ask
: >"$TLOG2"
tev2 PostToolUse '{"agent_id":"a1","tool_name":"Bash","tool_use_id":"t-a1"}'
ok "...and a rewritten one already holds its new detail" "yes" "$(grep -c 'set -p -t %7 @agent done|exists=yes|detail=Bash ✓$' "$TLOG2" | sed 's/1/yes/')"

t "s19. an Agent or Task call with no argument is still a call of the main conversation that nobody is asked about"
for tool in Agent Task; do
  fresh "$S"
  ev UserPromptSubmit '{"prompt":"go"}'
  ev PreToolUse "$(jq -nc --arg t "$tool" '{tool_name:$t,tool_input:{},tool_use_id:"g1"}')"
  ok "$tool with no argument has the bare tool name as its detail" "$tool" "$(rec_detail)"
  agpre a1
  ask
  ok "...and is remembered" 1 "$(perm_has)"
  agpost a1
  ok "...and the subagent's next event puts it back" "working|$tool" "$(rec_state)|$(rec_detail)"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
