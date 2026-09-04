#!/usr/bin/env bash
#
# tests/notes.sh — tnotes: the editor pane beside a Claude pane, where it goes
# when you look away, and what happens to the draft when nvim quits.
#
# NOTHING HERE MAY TOUCH THE DEFAULT TMUX SOCKET, and nothing here may touch the
# real ta-notes session either: the server is created with `tmux -L tatest-$$ -f
# /dev/null`, tnotes is pointed at it by exporting $TMUX into the one command
# under test, and the parking session tnotes creates is created on THAT server.
#
# THE STUBS. `claude` is a re-signed copy of /bin/cat, which is two things at
# once: #{pane_current_command} says "claude", so tnotes takes the pane for a
# chat, and everything pasted into that pane comes back out on its stdout — the
# chat pane runs `claude > pasted.txt`, so the paste path is asserted on bytes
# rather than on tmux having been called. `nvim` is a script that records its
# argv, writes $NVIM_WRITE into prompt.md and then sits until $TN_ROOT/nvim.quit
# appears, which is how the test says "now the user quits the editor". `tnotes`
# itself is deliberately NOT on the server's PATH: the focus hooks tagents
# installs would otherwise fire a background sync on every select-pane here and
# race the syncs the test runs on purpose.
#
# bash 3.2, runnable from any cwd, non-zero exit on any failing check.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TA="$HERE/../tagents"
TN="$HERE/../tnotes"

command -v tmux >/dev/null 2>&1 || { echo "notes.sh: no tmux"; exit 1; }
command -v git  >/dev/null 2>&1 || { echo "notes.sh: no git"; exit 1; }

S=tatest-$$
SOCK=""
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tagents-notes.XXXXXX") || exit 1
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
t()    { printf '\n%s\n' "$1"; }

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------
BIN="$ROOT/bin";      mkdir -p "$BIN"
STATE="$ROOT/state";  mkdir -p "$STATE"
REPO="$ROOT/repo";    mkdir -p "$REPO/.git"
NOTES="$REPO/.claude/notes"

# A copy of a system binary is killed on sight on arm64 — its signature is only
# valid for the original inode — which is what the ad-hoc re-sign is for.
cp /bin/cat "$BIN/claude" || exit 1
codesign --remove-signature "$BIN/claude" >/dev/null 2>&1
codesign -f -s - "$BIN/claude" >/dev/null 2>&1
printf 'x\n' | "$BIN/claude" >/dev/null 2>&1 ||
  { echo "notes.sh: cannot build a stub agent (codesign?)"; exit 1; }

# THE LIVE CLI IS NOT NAMED `claude`. It runs out of
# ~/.local/share/claude/versions/<version>, so #{pane_current_command} on a real
# chat pane reads `2.1.261`. A second stub under that name — the same re-signed
# cat, so it pastes back the same way — is what keeps the version-number branch
# of tnotes' is_claude_cmd honest.
VCMD=2.1.261
cp "$BIN/claude" "$BIN/$VCMD" || exit 1
codesign --remove-signature "$BIN/$VCMD" >/dev/null 2>&1
codesign -f -s - "$BIN/$VCMD" >/dev/null 2>&1
printf 'x\n' | "$BIN/$VCMD" >/dev/null 2>&1 ||
  { echo "notes.sh: cannot build a version-named stub agent (codesign?)"; exit 1; }

cat >"$BIN/nvim" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$TN_ROOT/nvim.log"
[ -n "${NVIM_WRITE:-}" ] && printf '%b' "$NVIM_WRITE" >prompt.md
while [ ! -f "$TN_ROOT/nvim.quit" ]; do sleep 0.2; done
exit 0
STUB
cat >"$BIN/tagents" <<STUB
#!/bin/sh
exec bash "$TA" "\$@"
STUB
chmod +x "$BIN/claude" "$BIN/$VCMD" "$BIN/nvim" "$BIN/tagents"

# EXPORTED BEFORE THE SERVER EXISTS. A tmux server keeps the environment it was
# started with and hands it to every command it runs, so the stubs' own
# variables have to be in place now.
export PATH="$BIN:$PATH"
export TA_STATE_DIR="$STATE"
export TA_SESSION=tatest-dash
export TA_CONFIG=/nonexistent/config.yaml
export TN_ROOT="$ROOT"
export NVIM_WRITE='hello\n\nworld\n'
unset TMUX TMUX_PANE TA_MODE TA_FLAT TA_COLS TA_NEW_CMD TA_RESUME_CMD TA_HOME
unset CLAUDE_CONFIG_DIR

tm() { tmux -L "$S" "$@"; }

tm -f /dev/null new-session -d -s tatest-work -x 200 -y 50 -c "$REPO" || exit 1
tm set -g default-shell /bin/sh >/dev/null 2>&1
tm set -g default-command '' >/dev/null 2>&1

SOCK=$(tm display -p '#{socket_path}' 2>/dev/null)
[ -n "$SOCK" ] || { echo "notes.sh: no socket for $S"; exit 1; }

( { sleep 300 & printf '%s\n' "$!" >"$ROOT/keeper.pid"; wait; } |
    script -q /dev/null tmux -L "$S" attach -t tatest-work >/dev/null 2>&1 & ) >/dev/null 2>&1
sleep 0.5

run() { env TMUX="$SOCK,0,0" bash "$TN" "$@"; }

where()  { tm display -p -t "${1:-}" '#{window_id}' 2>/dev/null; }
sess()   { tm display -p -t "${1:-}" '#{session_name}' 2>/dev/null; }
npanes() { tm list-panes -t "${1:-}" -F x 2>/dev/null | wc -l | tr -d ' '; }
lives()  { tm list-panes -a -F '#{pane_id}' 2>/dev/null |
             awk -v p="${1:-}" '$1 == p { f = 1 } END { print f ? "yes" : "no" }'; }
popt()   { tm show -pv -t "${2:-}" "${1:-}" 2>/dev/null; }
notes_of() { popt @ta_notes "${1:-}"; }

wait_file() { local i=0; while [ "$i" -lt 60 ]; do [ -e "$1" ] && return 0
                sleep 0.1; i=$((i+1)); done; return 1; }
wait_gone() { local i=0; while [ "$i" -lt 80 ]; do [ "$(lives "$1")" = no ] && return 0
                sleep 0.1; i=$((i+1)); done; return 1; }

# THE USER'S TERMINAL, ASSERTED AT THE END. tnotes splits, breaks out and joins
# panes in windows the user also keeps their own things in; a pane carrying none
# of its markers must come through all of it exactly where it was.
TERM1=$(tm list-panes -t tatest-work:0 -F '#{pane_id}' | head -1)
TWIN=$(where "$TERM1")

CHAT=$(tm new-window -d -t tatest-work: -P -F '#{pane_id}' -c "$REPO" \
         "exec claude >'$ROOT/pasted.txt'" 2>/dev/null)
CWIN=$(where "$CHAT")
SHELLP=$(tm new-window -d -t tatest-work: -P -F '#{pane_id}' -c "$REPO" \
           "exec sleep 600" 2>/dev/null)
SWIN=$(where "$SHELLP")
[ -n "$CHAT" ] && [ -n "$SHELLP" ] || { echo "notes.sh: could not make the panes"; exit 1; }
sleep 0.6
ok "the chat pane is running claude" claude "$(tm display -p -t "$CHAT" '#{pane_current_command}')"

# ---------------------------------------------------------------------------
t "1. a pane that is not a Claude pane is refused"
# ---------------------------------------------------------------------------
run toggle "$SHELLP" >/dev/null 2>&1
ok "toggle exits 1" 1 "$?"
ok "no pane was split off it" 1 "$(npanes "$SWIN")"
ok "no marker on it" "" "$(notes_of "$SHELLP")"

# ---------------------------------------------------------------------------
t "2. toggle opens the editor beside the chat"
# ---------------------------------------------------------------------------
run toggle "$CHAT" >/dev/null 2>&1
ok "toggle exits 0" 0 "$?"
ED=$(notes_of "$CHAT")
ok "the chat names an editor" yes "$([ -n "$ED" ] && echo yes || echo no)"
ok "the editor is in the chat's window" "$CWIN" "$(where "$ED")"
ok "two panes there now" 2 "$(npanes "$CWIN")"
ok "the editor names the chat back" "$CHAT" "$(popt @ta_notes_for "$ED")"
ok "and says it is open" 1 "$(popt @ta_notes_open "$ED")"
ok "the notes dir is a repo" yes "$([ -d "$NOTES/.git" ] && echo yes || echo no)"
ok "prompt.md exists" yes "$([ -f "$NOTES/prompt.md" ] && echo yes || echo no)"
ok "the global flag is set" 1 "$(tm show -gv @ta_notes_any 2>/dev/null)"
wait_file "$ROOT/nvim.log"
has "nvim was opened on prompt.md" prompt.md "$(cat "$ROOT/nvim.log" 2>/dev/null)"

# ---------------------------------------------------------------------------
t "3. sync with nothing arriving changes nothing"
# ---------------------------------------------------------------------------
run sync >/dev/null 2>&1
ok "sync exits 0" 0 "$?"
ok "the editor stayed put" "$CWIN" "$(where "$ED")"
ok "and is alive" yes "$(lives "$ED")"
run sync >/dev/null 2>&1
ok "twice is the same as once" "$CWIN" "$(where "$ED")"

# ---------------------------------------------------------------------------
t "4. arriving in another window parks it; coming back brings it home"
# ---------------------------------------------------------------------------
OTHER=$(tm new-window -d -t tatest-work: -P -F '#{pane_id}' -c "$REPO" "exec sleep 600")
tm select-window -t "$(where "$OTHER")" >/dev/null 2>&1
run sync "$OTHER" >/dev/null 2>&1
ok "the editor went to the parking session" ta-notes "$(sess "$ED")"
ok "it is still alive" yes "$(lives "$ED")"
ok "and still counts as open" 1 "$(popt @ta_notes_open "$ED")"
ok "the chat still names it" "$ED" "$(notes_of "$CHAT")"
ok "the chat's window is down to one pane" 1 "$(npanes "$CWIN")"
tm select-window -t "$CWIN" >/dev/null 2>&1
run sync "$CHAT" >/dev/null 2>&1
ok "arriving at the chat brings it back" "$CWIN" "$(where "$ED")"
ok "two panes there again" 2 "$(npanes "$CWIN")"

# ---------------------------------------------------------------------------
t "5. toggling it away is a decision sync does not overrule"
# ---------------------------------------------------------------------------
run toggle "$CHAT" >/dev/null 2>&1
ok "toggle parked it" ta-notes "$(sess "$ED")"
ok "and marked it closed" 0 "$(popt @ta_notes_open "$ED")"
run sync "$CHAT" >/dev/null 2>&1
ok "sync leaves a closed editor parked" ta-notes "$(sess "$ED")"
run toggle "$CHAT" >/dev/null 2>&1
ok "toggle brings it back" "$CWIN" "$(where "$ED")"
ok "open again" 1 "$(popt @ta_notes_open "$ED")"

# ---------------------------------------------------------------------------
t "6. quitting nvim commits the draft and pastes it into the chat"
# ---------------------------------------------------------------------------
: >"$ROOT/pasted.txt"
touch "$ROOT/nvim.quit"
wait_gone "$ED"
sleep 0.5
ok "the editor pane is gone" no "$(lives "$ED")"
ok "the whole draft arrived, newlines and all" "$(printf 'hello\n\nworld')" "$(cat "$ROOT/pasted.txt" 2>/dev/null)"
ok "prompt.md was emptied" 0 "$(wc -c <"$NOTES/prompt.md" | tr -d ' ')"
ok "one commit" 1 "$(git -C "$NOTES" log --oneline 2>/dev/null | wc -l | tr -d ' ')"
ok "named after the first line" hello "$(git -C "$NOTES" log -1 --format=%s 2>/dev/null)"
ok "the chat's marker was cleared" "" "$(notes_of "$CHAT")"
ok "the chat's window is back to one pane" 1 "$(npanes "$CWIN")"

# ---------------------------------------------------------------------------
t "7. a draft is never typed into something that is not claude"
# ---------------------------------------------------------------------------
printf 'second draft\nmore\n' >"$NOTES/prompt.md"
run send "$SHELLP" "$NOTES" >/dev/null 2>&1
ok "send exits 1" 1 "$?"
ok "the draft is kept" "$(printf 'second draft\nmore')" "$(cat "$NOTES/prompt.md")"
ok "but it was committed" 2 "$(git -C "$NOTES" log --oneline 2>/dev/null | wc -l | tr -d ' ')"
ok "under its own first line" "second draft" "$(git -C "$NOTES" log -1 --format=%s 2>/dev/null)"

# ---------------------------------------------------------------------------
t "8. an editor whose chat is gone is closed by sync"
# ---------------------------------------------------------------------------
rm -f "$ROOT/nvim.quit"
run toggle "$CHAT" >/dev/null 2>&1
ED2=$(notes_of "$CHAT")
ok "a second editor opened" yes "$([ -n "$ED2" ] && echo yes || echo no)"
tm kill-pane -t "$CHAT" >/dev/null 2>&1
sleep 0.3
run sync >/dev/null 2>&1
ok "the orphan is gone" no "$(lives "$ED2")"
ok "and the global flag with it" "" "$(tm show -gv @ta_notes_any 2>/dev/null)"

# ---------------------------------------------------------------------------
t "9. a chat whose command is a version number is still a chat"
# ---------------------------------------------------------------------------
VCHAT=$(tm new-window -d -t tatest-work: -P -F '#{pane_id}' -c "$REPO" \
          "exec $VCMD >'$ROOT/pasted2.txt'" 2>/dev/null)
VWIN=$(where "$VCHAT")
sleep 0.6
ok "the pane reports the version, not claude" "$VCMD" \
   "$(tm display -p -t "$VCHAT" '#{pane_current_command}')"
ok "and there is no state record to fall back on" no \
   "$([ -f "$STATE/${VCHAT#%}.tsv" ] && echo yes || echo no)"
: >"$ROOT/pasted2.txt"
printf 'third draft\n' >"$NOTES/prompt.md"
run send "$VCHAT" "$NOTES" >/dev/null 2>&1
ok "send exits 0" 0 "$?"
i=0; while [ "$i" -lt 40 ] && [ ! -s "$ROOT/pasted2.txt" ]; do sleep 0.1; i=$((i+1)); done
ok "the draft was typed into it" "third draft" "$(cat "$ROOT/pasted2.txt" 2>/dev/null)"
ok "and the outbox was cleared" 0 "$(wc -c <"$NOTES/prompt.md" | tr -d ' ')"
run toggle "$VCHAT" >/dev/null 2>&1
ok "toggle exits 0" 0 "$?"
VED=$(notes_of "$VCHAT")
ok "an editor opened beside it" yes "$([ -n "$VED" ] && echo yes || echo no)"
ok "...in its own window" "$VWIN" "$(where "$VED")"

# ---------------------------------------------------------------------------
t "10. everything else in the server was left alone"
# ---------------------------------------------------------------------------
ok "the user terminal is untouched" "yes $TWIN" "$(lives "$TERM1") $(where "$TERM1")"
ok "the pane that was never a chat is untouched" "yes $SWIN" "$(lives "$SHELLP") $(where "$SHELLP")"
ok "and still has its window to itself" 1 "$(npanes "$SWIN")"

# The seat logic must not have noticed any of this: an editor pane carries no
# @tagents_* marker, so seats() cannot see it and nothing in panes.sh can change.
bash "$HERE/panes.sh" >"$ROOT/panes.log" 2>&1
ok "tests/panes.sh is unaffected" 0 "$?"
has "and says so" " 0 failed" "$(tail -1 "$ROOT/panes.log")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
