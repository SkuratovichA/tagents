#!/usr/bin/env bash
#
# tests/tags.sh — the tags of a session: the three verbs that write them (--tags, --tags-add, --tags-set), the hidden suffix a tagged row carries so the dashboard's search finds the session, the preview line, the state hook that drops them on /clear and on no other ending, and the plugin's SessionStart line.
#
# The verbs and the hooks need no tmux. The list and the preview run against a scratch tmux server whose agents are a copy of /bin/sleep named `claude`, so the process walk counts them (see tests/names.sh). Examples are neutral: tickets are proj-123 and OPS-42.
#
# bash 3.2, runnable from any cwd, non-zero exit on any failing check.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# A suite that is not run against a scratch default server aborts here, before it can reach the live one (tests/scratch-guard.sh).
. "$HERE/scratch-guard.sh" && scratch_guard tags.sh || exit 1
TA="$HERE/../tagents"
LIB="$HERE/../lib/tagents"
HOOK="$HERE/../hooks/tmux-agent-state.sh"
PHOOK="$HERE/../hooks/plugin/session-start.sh"

command -v tmux >/dev/null 2>&1 || { echo "tags.sh: no tmux"; exit 1; }
command -v fzf >/dev/null 2>&1 || { echo "tags.sh: no fzf"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "tags.sh: no jq"; exit 1; }

[ "${TERM:-dumb}" = dumb ] && TERM=xterm-256color
export TERM

S=tatest-$$
SOCK=""
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tagents-tags.XXXXXX") || exit 1
ROOT=$(cd "$ROOT" && pwd -P) || exit 1
trap 'tmux -L "$S" kill-server >/dev/null 2>&1
      [ -n "$SOCK" ] && rm -f "$SOCK"
      rm -rf "$ROOT"' EXIT INT TERM

pass=0; fail=0
ok()   { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
         else fail=$((fail+1)); printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"; fi; }
t()    { printf '\n%s\n' "$1"; }
TAB=$(printf '\t')

BIN="$ROOT/bin";      mkdir -p "$BIN"
STATE="$ROOT/state";  mkdir -p "$STATE"
REPO="$ROOT/repo";    mkdir -p "$REPO/.git"

cp /bin/sleep "$BIN/claude" || exit 1
codesign --remove-signature "$BIN/claude" >/dev/null 2>&1
codesign -f -s - "$BIN/claude" >/dev/null 2>&1
"$BIN/claude" 0 >/dev/null 2>&1 || { echo "tags.sh: cannot build a stub agent (codesign?)"; exit 1; }
printf '#!/bin/sh\nexit 0\n' >"$BIN/tusage"
chmod +x "$BIN/claude" "$BIN/tusage"

export PATH="$BIN:$PATH"
export TA_STATE_DIR="$STATE"
export TA_SESSION=tatest-dash
export TA_CONFIG=/nonexistent/config.toml
export TA_COUNTS_EVERY=0
unset TMUX TMUX_PANE TA_MODE TA_FLAT TA_COLS TA_NEW_CMD TA_RESUME_CMD TA_HOME
unset TA_HIDE_COLS TA_NAMES_EVERY CLAUDE_CONFIG_DIR CLAUDE_PID CLAUDE_CODE_ENTRYPOINT

tm() { tmux -L "$S" "$@"; }
tm -f /dev/null new-session -d -s tatest-work -c "$REPO" -x 200 -y 50 || exit 1
tm set -g default-shell /bin/sh >/dev/null 2>&1
tm set -g default-command '' >/dev/null 2>&1
tm new-session -d -s tatest-dash -c "$REPO" >/dev/null 2>&1
SOCK=$(tm display -p '#{socket_path}' 2>/dev/null)
[ -n "$SOCK" ] || { echo "tags.sh: no socket for $S"; exit 1; }
TMUXV="$SOCK,0,0"

run() { env TMUX="$TMUXV" bash "$TA" "$@"; }

mkrec() {  # <pane> <session id>
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" working "$2" "$REPO" "" "on it" "" >"$STATE/${1#%}.tsv"
}
newagent() {  # <title> <sid> -> pane id
  local p
  p=$(tm new-window -d -t tatest-work: -P -F '#{pane_id}' -c "$REPO" "exec '$BIN/claude' 600" 2>/dev/null)
  tm select-pane -T "$1" -t "$p" 2>/dev/null
  mkrec "$p" "$2"
  printf '%s' "$p"
}
tags_line() { awk -F"$TAB" -v k="$1" '$1 == k { print $2; exit }' "$STATE/tags.tsv" 2>/dev/null; }
# The age of a row ticks in seconds, so it is taken out before two rows are compared.
rowof() { run --list 2>/dev/null | awk -F'\t' -v p="$1" '$1 == p { print; exit }' | sed -E 's/ [0-9]+:[0-9][0-9] / AGE /'; }

# ---------------------------------------------------------------------------
t "1. the three verbs"
# ---------------------------------------------------------------------------
P1=$(newagent 'first agent' sid-t1)
P2=$(newagent 'second agent' sid-t2)
P3=$(newagent 'third agent' sid-t3)
rm -f "$STATE/$(printf %s "$P3" | tr -d %).tsv"   # a pane whose record names no session
printf '1\t2\n' >"$STATE/$(printf %s "$P3" | tr -d %).tsv"

out=$(run --tags sid-t1); rc=$?
ok "a session with no tags prints nothing" "" "$out"
ok "...and exits 0" 0 "$rc"
out=$(run --tags-add sid-t1 'Proj-123,Api  OPS-42' 2>&1); rc=$?
ok "--tags-add splits on commas and spaces and lowercases" "proj-123 api ops-42" "$out"
ok "--tags-add exits 0" 0 "$rc"
ok "the line is session id, TAB, the tags" "proj-123 api ops-42" "$(tags_line sid-t1)"
ok "--tags prints them on one line" "proj-123 api ops-42" "$(run --tags sid-t1)"
out=$(run --tags-add sid-t1 'api new.tag' 2>&1)
ok "a duplicate is dropped, the old tags come first" "proj-123 api ops-42 new.tag" "$out"
out=$(run --tags-add "$P1" 'by-pane' 2>&1)
ok "a pane id is resolved to the session in its record" "proj-123 api ops-42 new.tag by-pane" "$out"
ok "...and the line is the session's" "proj-123 api ops-42 new.tag by-pane" "$(tags_line sid-t1)"
ok "--tags takes a pane id too" "proj-123 api ops-42 new.tag by-pane" "$(run --tags "$P1")"
ok "nothing is keyed by the pane" 0 "$(grep -c "^$P1" "$STATE/tags.tsv")"
# EVERY WORD AFTER K IS A TAG: the shell splits a list the caller did not quote, and the verb must not keep the first word alone.
run --tags-set sid-t1 >/dev/null 2>&1
out=$(run --tags-add sid-t1 first second 2>&1)
ok "--tags-add K a b stores both words" "first second" "$out"
ok "...and the file holds both" "first second" "$(tags_line sid-t1)"
out=$(run --tags-set sid-t1 third fourth 2>&1)
ok "--tags-set K a b stores both words" "third fourth" "$out"
ok "...and the file holds both" "third fourth" "$(tags_line sid-t1)"
out=$(run --tags-set sid-t1 2>&1)
ok "--tags-set K with no tags clears them" "" "$out"
ok "...and removes the line" "" "$(tags_line sid-t1)"

# A FAILED WRITE IS NOT A SUCCESS: the state directory takes no new file here, so tsv_put cannot make its temporary file.
before=$(cat "$STATE/tags.tsv" 2>/dev/null)
chmod a-w "$STATE"
out=$(run --tags-add sid-t1 anything 2>"$ROOT/err"); rc=$?
chmod u+w "$STATE"
ok "a write that fails exits 1" 1 "$rc"
ok "...prints nothing on stdout" "" "$out"
case $(cat "$ROOT/err") in "tagents --tags-add: cannot write "*tags.tsv) r=said ;; *) r=$(cat "$ROOT/err") ;; esac
ok "...and says which file it cannot write" said "$r"
ok "...and the file is as it was" "$before" "$(cat "$STATE/tags.tsv" 2>/dev/null)"

out=$(run --tags-set "$P1" 'x1:y/z, a_b' 2>&1)
ok "--tags-set replaces the list" "x1:y/z a_b" "$out"
out=$(run --tags-set sid-t1 '' 2>&1); rc=$?
ok "--tags-set with an empty TAGS prints nothing" "" "$out"
ok "...exits 0" 0 "$rc"
ok "...and removes the line" "" "$(tags_line sid-t1)"
ok "...the file holds no line for it" 0 "$(grep -c 'sid-t1' "$STATE/tags.tsv")"

run --tags-set sid-t2 'keep me' >/dev/null 2>&1
before=$(cat "$STATE/tags.tsv")
out=$(run --tags-add sid-t2 'ok-one bad!tag' 2>&1); rc=$?
ok "an invalid tag exits 2" 2 "$rc"
case $out in *'"bad!tag"'*'1 to 32'*) r=named ;; *) r="$out" ;; esac
ok "...and the message names the tag and the rule" named "$r"
ok "...and nothing is written" "$before" "$(cat "$STATE/tags.tsv")"
for bad in '-lead' '.lead' 'UPPER+PLUS' 'a b#c' 'back\slash' "$(printf 'a%.0s' $(seq 33))"; do
  run --tags-add sid-t2 "$bad" >/dev/null 2>&1; rc=$?
  ok "refused: $bad" 2 "$rc"
done
ok "a tag with a slash in it is valid" "ns/proj-123 a-b.c_d:e/f" "$(run --tags-set sid-t2 'ns/proj-123 a-b.c_d:e/f' 2>/dev/null)"
ok "a tag of 32 characters is valid" 0 "$(run --tags-add sid-t2 "$(printf 'a%.0s' $(seq 32))" >/dev/null 2>&1; echo $?)"
run --tags-set sid-t2 'keep me' >/dev/null 2>&1

run --tags-set sid-t2 't1 t2 t3 t4 t5 t6 t7 t8 t9 t10' >/dev/null 2>&1
ok "ten tags are kept" "t1 t2 t3 t4 t5 t6 t7 t8 t9 t10" "$(tags_line sid-t2)"
before=$(cat "$STATE/tags.tsv")
out=$(run --tags-add sid-t2 'eleven' 2>&1); rc=$?
ok "--tags-add of an eleventh tag exits 2" 2 "$rc"
case $out in *10*sid-t2*"t1 t2 t3"*--tags-set*) r=said ;; *) r="$out" ;; esac
ok "...and says the limit, the session, its tags and --tags-set" said "$r"
ok "...and writes nothing" "$before" "$(cat "$STATE/tags.tsv")"
run --tags-set sid-t2 't1 t2 t3 t4 t5 t6 t7 t8 t9 t10 t11' >/dev/null 2>&1; rc=$?
ok "--tags-set of eleven tags exits 2" 2 "$rc"
ok "...and writes nothing" "$before" "$(cat "$STATE/tags.tsv")"
ok "--tags-add of a tag it already has stays within the limit" 0 "$(run --tags-add sid-t2 't3' >/dev/null 2>&1; echo $?)"

run --tags-add '' x >/dev/null 2>&1; rc=$?
ok "an empty K is exit 2" 2 "$rc"
case $(run --tags-add '' x 2>&1) in *'need a session id or pane id'*) r=said ;; *) r=no ;; esac
ok "...with the message --label gives" said "$r"
out=$(run --tags-add "$P3" x 2>&1); rc=$?
ok "a pane whose record names no session is exit 2" 2 "$rc"
case $out in *"no session in pane $P3"*) r=said ;; *) r="$out" ;; esac
ok "...and the message names the pane" said "$r"
run --tags 'two words' >/dev/null 2>&1; rc=$?
ok "a K with whitespace that is not a pane id is exit 2" 2 "$rc"
run --tags-add sid-t1 ' , ' >/dev/null 2>&1; rc=$?
ok "--tags-add with no tag in TAGS is exit 2" 2 "$rc"
ok "a K that is not a pane id is taken as a session id" 0 "$(run --tags-add '%x1' abc >/dev/null 2>&1; echo $?)"
run --tags-set '%x1' '' >/dev/null 2>&1

# THE READ AND THE WRITE ARE ONE STEP: a lock held by somebody else is a refusal, not a write over theirs.
mkdir "$STATE/.tags.lock" && printf '%s\n' "$$" >"$STATE/.tags.lock/owner"
run --tags-set sid-t2 'keep me' >/dev/null 2>&1
before=$(cat "$STATE/tags.tsv")
out=$(run --tags-add sid-t2 'while-locked' 2>"$ROOT/err"); rc=$?
ok "a held lock is exit 1" 1 "$rc"
ok "...prints nothing on stdout" "" "$out"
ok "...and says the file is busy" "tagents --tags-add: the tags file is busy" "$(cat "$ROOT/err")"
ok "...and the file is as it was" "$before" "$(cat "$STATE/tags.tsv")"
rmdir "$STATE/.tags.lock" 2>/dev/null; rm -rf "$STATE/.tags.lock"
run --tags-set sid-t2 'keep me' >/dev/null 2>&1
run --tags-add sid-t2 'bad!tag' >/dev/null 2>&1
ok "an invalid tag does not leave the lock behind" no "$([ -e "$STATE/.tags.lock" ] && echo yes || echo no)"
run --tags-set sid-t2 't1 t2 t3 t4 t5 t6 t7 t8 t9 t10' >/dev/null 2>&1
run --tags-add sid-t2 'eleven' >/dev/null 2>&1
ok "...nor the refusal of an eleventh tag" no "$([ -e "$STATE/.tags.lock" ] && echo yes || echo no)"
chmod a-w "$STATE"; run --tags-add sid-t2 'x' >/dev/null 2>&1; chmod u+w "$STATE"
ok "...nor a write that fails" no "$([ -e "$STATE/.tags.lock" ] && echo yes || echo no)"
run --tags-set sid-t2 'keep me' >/dev/null 2>&1
ok "...nor a write that succeeds" no "$([ -e "$STATE/.tags.lock" ] && echo yes || echo no)"
run --tags-set sid-t2 '' >/dev/null 2>&1
# Eight sessions tag themselves at the same moment, as after a restart: every one of them must have its line.
lost=0
for round in 1 2 3 4 5; do
  rm -f "$STATE/tags.tsv"
  for n in 1 2 3 4 5 6 7 8; do run --tags-add "sid-c$n" "round$round n$n" >/dev/null 2>&1 & done
  wait
  for n in 1 2 3 4 5 6 7 8; do
    [ "$(tags_line "sid-c$n")" = "round$round n$n" ] || lost=$((lost + 1))
  done
done
ok "eight --tags-add calls started together each leave their line, in five rounds" 0 "$lost"
rm -f "$STATE/tags.tsv"

# The verbs are declared with no `requires`, so they run with no tmux server at all.
out=$(env -u TMUX TA_STATE_DIR="$ROOT/bare" bash "$TA" --tags-add sid-bare 'ops-42' 2>&1); rc=$?
ok "no tmux needed: it writes and prints" "ops-42" "$out"
ok "...and exits 0" 0 "$rc"
ok "...the file is in the state directory" "ops-42" "$(awk -F"$TAB" '$1 == "sid-bare" { print $2 }' "$ROOT/bare/tags.tsv")"

# ---------------------------------------------------------------------------
t "2. the row"
# ---------------------------------------------------------------------------
run --tags-set sid-t2 '' >/dev/null 2>&1
run --tags-set sid-t1 '' >/dev/null 2>&1
R1=$(rowof "$P1"); R2=$(rowof "$P2")
tally() { env TA_TALLY=1 TMUX="$TMUXV" bash "$TA" --list 2>/dev/null; }
# The widest field 2 of the list in characters, without what a tagged row carries behind it.
width() {  # [env assignments...]
  env TMUX="$TMUXV" "$@" bash "$TA" --list 2>/dev/null | cut -f2 | sed -E 's/ {300,}.*$//' |
    while IFS= read -r l; do printf '%s' "$l" | LC_ALL=en_US.UTF-8 wc -m; done | sort -n | tail -1 | tr -d ' '
}
TALLY0=$(tally); WIDTH0=$(width TA_COLS=100)
UNTAG500=$(env TMUX="$TMUXV" TA_COLS=500 bash "$TA" --list 2>/dev/null | awk -F'\t' -v p="$P1" '$1 == p { print $2; exit }' | sed -E 's/ [0-9]+:[0-9][0-9] / AGE /')
ok "the untagged row is in the list" yes "$([ -n "$R1" ] && [ -n "$R2" ] && echo yes || echo no)"
run --tags-set sid-t1 'proj-123 xqz' >/dev/null 2>&1
T1=$(rowof "$P1")
ok "a tagged row keeps its five fields" 5 "$(printf '%s\n' "$T1" | awk -F'\t' '{ print NF }')"
TAGTXT="proj-123 xqz PROJ-123 XQZ"
SFX="$(printf '%300s' '')$TAGTXT"
f2=$(printf '%s\n' "$T1" | awk -F'\t' '{ print $2 }')
case $f2 in *"$SFX") r=yes ;; *) r=no ;; esac
ok "field 2 ends with 300 spaces, the tags, a space and the tags in upper case, on a list narrower than that" yes "$r"
# A LIST WIDER THAN THE PADDING gets a wider one, or the tags would be drawn: the spaces are as many as the list is wide.
T500=$(env TMUX="$TMUXV" TA_COLS=500 bash "$TA" --list 2>/dev/null | awk -F'\t' -v p="$P1" '$1 == p { print $2; exit }' | sed -E 's/ [0-9]+:[0-9][0-9] / AGE /')
case $T500 in *"$(printf '%500s' '')$TAGTXT") r=yes ;; *) r=no ;; esac
ok "on a list 500 columns wide the tags come after 500 spaces" yes "$r"
ok "...and what is before them is the row it was" "$UNTAG500" "${T500%"$(printf '%500s' '')$TAGTXT"}"
ok "...and what is before the suffix is the row it was" "$(printf '%s\n' "$R1" | awk -F'\t' '{ print $2 }')" "${f2%"$SFX"}"
ok "the other fields are untouched" "$(printf '%s\n' "$R1" | cut -f1,3-)" "$(printf '%s\n' "$T1" | cut -f1,3-)"
ok "the row of the untagged session next to it is byte for byte what it was" "$R2" "$(rowof "$P2")"
ok "the tally does not see the tags" "$TALLY0" "$(tally)"
ok "...nor does the width of the rows before the suffix" "$WIDTH0" "$(width TA_COLS=100)"

# ---------------------------------------------------------------------------
t "3. the search finds the session by a tag, in all lower case or all upper case"
# ---------------------------------------------------------------------------
LIST=$(run --list 2>/dev/null)
# The options of the dashboard's own fzf call that decide what is matched.
dashfzf=$(awk '/fzf \\$/,/--prompt/' "$LIB/dash.sh")
case $dashfzf in *'--with-nth=2'*) r=yes ;; *) r=no ;; esac
ok "the dashboard matches on field 2" yes "$r"
case $dashfzf in *'--no-hscroll'*) r=yes ;; *) r=no ;; esac
ok "...and its fzf runs with --no-hscroll" yes "$r"
for q in proj-123 PROJ-123 xqz XQZ; do
  hit=$(printf '%s\n' "$LIST" | fzf --filter="$q" --ansi --no-sort --delimiter="$TAB" --with-nth=2 | cut -f1 | tr '\n' ' ')
  ok "the query $q finds the tagged session and not the other" "$P1 " "$hit"
done
hit=$(printf '%s\n' "$LIST" | fzf --filter="Proj-123" --ansi --no-sort --delimiter="$TAB" --with-nth=2 | cut -f1 | tr '\n' ' ')
ok "a query that mixes the cases finds nothing: fzf's smart-case makes it case-sensitive" "" "$hit"
hit=$(printf '%s\n' "$LIST" | fzf --filter="first agent" --ansi --no-sort --delimiter="$TAB" --with-nth=2 | cut -f1 | tr '\n' ' ')
ok "the name still finds it" "$P1 " "$hit"
hit=$(printf '%s\n' "$LIST" | fzf --filter="qqqzz-9" --ansi --no-sort --delimiter="$TAB" --with-nth=2 | cut -f1 | tr '\n' ' ')
ok "a tag nobody has finds nothing" "" "$hit"

# ---------------------------------------------------------------------------
t "4. the state hook drops the tags on /clear and on no other ending"
# ---------------------------------------------------------------------------
HS="$ROOT/hookstate"; mkdir -p "$HS"
SHIM="$ROOT/shim"; mkdir -p "$SHIM"; printf '#!/bin/sh\nexit 1\n' >"$SHIM/tmux"; chmod +x "$SHIM/tmux"
hook() {  # <session id, or empty> <reason>
  jq -nc --arg s "$1" --arg r "$2" '{hook_event_name:"SessionEnd", cwd:"/work", transcript_path:"/work/t.jsonl", reason:$r} + (if $s == "" then {} else {session_id:$s} end)' |
    env PATH="$SHIM:$PATH" TMUX="$ROOT/no-such-socket,0,0" TMUX_PANE=%7 TA_STATE_DIR="$HS" sh "$HOOK" >/dev/null 2>&1
}
seed() { printf 'sid-1\tproj-123 api\nsid-2\tops-42\n' >"$HS/tags.tsv"; }
seed; hook sid-1 clear
ok "clear removes the line of that session" "" "$(awk -F"$TAB" '$1 == "sid-1"' "$HS/tags.tsv")"
ok "...and leaves another session's line" "sid-2${TAB}ops-42" "$(cat "$HS/tags.tsv")"
for reason in logout prompt_input_exit other bypass_permissions_disabled ""; do
  seed; hook sid-1 "$reason"
  ok "the reason '$reason' keeps the tags" "sid-1${TAB}proj-123 api
sid-2${TAB}ops-42" "$(cat "$HS/tags.tsv")"
done
seed; hook "" clear
ok "clear with no session id drops nothing" "sid-1${TAB}proj-123 api
sid-2${TAB}ops-42" "$(cat "$HS/tags.tsv")"
rm -f "$HS/tags.tsv"; hook sid-1 clear
ok "clear with no tags file creates none" no "$([ -e "$HS/tags.tsv" ] && echo yes || echo no)"
ok "no temp file is left behind" 0 "$(ls "$HS" | grep -c 'tags.tsv\.')"
# A SESSION WITH NO LINE in a file that exists: the awk finds nothing to drop and fails, and the temp file it was filling must go.
seed; cp "$HS/tags.tsv" "$ROOT/tags.before"
hook sid-none clear
ok "clear for a session with no line leaves the file byte for byte" "" "$(cmp "$ROOT/tags.before" "$HS/tags.tsv" 2>&1)"
ok "...and no tags.tsv.* is left beside it" 0 "$(ls -A "$HS" | grep -c '^tags\.tsv\.')"

# END TO END, whatever either side calls the file: tags written by the verb, dropped by the hook, read back by the verb.
rm -f "$HS/tags.tsv"
env TA_STATE_DIR="$HS" bash "$TA" --tags-add sid-e2e 'proj-123 api' >/dev/null 2>&1
env TA_STATE_DIR="$HS" bash "$TA" --tags-add sid-keep 'ops-42' >/dev/null 2>&1
ok "tags written with --tags-add are read back with --tags" "proj-123 api" "$(env TA_STATE_DIR="$HS" bash "$TA" --tags sid-e2e 2>&1)"
hook sid-e2e clear
ok "...and read back empty after the hook's clear" "" "$(env TA_STATE_DIR="$HS" bash "$TA" --tags sid-e2e 2>&1)"
ok "...while another session's tags are still there" "ops-42" "$(env TA_STATE_DIR="$HS" bash "$TA" --tags sid-keep 2>&1)"

libname=$(sed -n 's/^TAGS="\$STATE_DIR\/\(.*\)"$/\1/p' "$LIB/tags.sh")
hookname=$(sed -n 's/.*-e "\$dir\/\([^"]*\)".*/\1/p' "$HOOK" | grep tags | head -1)
ok "the hook writes the file name lib/tagents/tags.sh uses" "$libname" "$hookname"
ok "...and it is tags.tsv" "tags.tsv" "$libname"

# ---------------------------------------------------------------------------
t "5. the plugin's SessionStart hook"
# ---------------------------------------------------------------------------
ph() {  # <payload> [env assignments...]
  local p=$1; shift
  printf '%s' "$p" | env -u CLAUDE_CODE_ENTRYPOINT -u TMUX_PANE "$@" sh "$PHOOK"
}
PAY='{"session_id":"abc-123","hook_event_name":"SessionStart","source":"startup"}'
WANT="tagents: this session's id is abc-123. Tag it with the tagents plugin's tool tagents_tags_add (k: that id, tags: words separated by spaces, such as a ticket key, the repository or a topic) as soon as you know what the session is about, and again when the work moves on, so the owner can find it by typing a tag into the dashboard's search. A session keeps at most 10 tags: tagents_tags reads them and tagents_tags_set replaces the list."
out=$(ph "$PAY" TMUX_PANE=%3); rc=$?
ok "in a pane it prints the one line, with the session id" "$WANT" "$out"
ok "...and exits 0" 0 "$rc"
ok "an interactive entrypoint named cli is reminded too" "$WANT" "$(ph "$PAY" TMUX_PANE=%3 CLAUDE_CODE_ENTRYPOINT=cli)"
out=$(ph "$PAY"); rc=$?
ok "without TMUX_PANE it prints nothing" "" "$out"
ok "...and exits 0" 0 "$rc"
out=$(ph "$PAY" TMUX_PANE=%3 CLAUDE_CODE_ENTRYPOINT=sdk-cli); rc=$?
ok "a headless entrypoint prints nothing" "" "$out"
ok "...and exits 0" 0 "$rc"
out=$(ph '{"hook_event_name":"SessionStart"}' TMUX_PANE=%3); rc=$?
ok "a payload with no session id prints nothing" "" "$out"
ok "...and exits 0" 0 "$rc"
ok "hooks.json registers it for SessionStart with no matcher" \
   'SessionStart|sh "${CLAUDE_PLUGIN_ROOT}/hooks/plugin/session-start.sh"|null' \
   "$(jq -r '.hooks | to_entries[] | .key + "|" + .value[0].hooks[0].command + "|" + (.value[0].matcher | tostring)' "$HERE/../hooks/hooks.json")"
ok "...and registers nothing else" 1 "$(jq '.hooks | length' "$HERE/../hooks/hooks.json")"
# install.sh wraps every hooks/*.sh into the user's hooks directory (its install_hooks loop), as a settings hook. The plugin's hook is registered by hooks/hooks.json and must not be wrapped there, so it lives in hooks/plugin/, which the glob does not reach: tests/install.sh pins that an install writes no wrapper for it.
ok "the plugin's hook is in hooks/plugin/" 1 "$([ -f "$PHOOK" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
t "6. the preview"
# ---------------------------------------------------------------------------
PV1=$(run --preview "$P1" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
PV2=$(run --preview "$P2" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
case $PV1 in *"session sid-t1"*) r=yes ;; *) r=no ;; esac
ok "the preview is of the session" yes "$r"
ok "a tagged session shows its tags" "tags: proj-123 xqz" "$(printf '%s\n' "$PV1" | grep '^tags:')"
ok "...right after the session line" "session sid-t1
tags: proj-123 xqz" "$(printf '%s\n' "$PV1" | grep -A1 '^session ')"
ok "an untagged session has no tags line" 0 "$(printf '%s\n' "$PV2" | grep -c '^tags:')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
