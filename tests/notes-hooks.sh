#!/usr/bin/env bash
#
# tests/notes-hooks.sh — the two notes-workspace hooks.
#
# No tmux, no fzf, no Claude: both hooks are stdin-JSON in, stdout-JSON out, so
# the whole contract is exercised by piping payloads at them over a throwaway
# git repo in a mktemp dir. Nothing here touches the real notes folder, the real
# ~/.claude, or the running dashboard.
#
# bash 3.2, runnable from any cwd, non-zero exit when any check fails.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOKS="$HERE/../hooks"
DOTFILES=${TA_DOTFILES:-$HOME/git/personal/.dotfiles}
# pwd -P: git reports a toplevel with symlinks resolved (/private/var on macOS),
# and the hooks compare paths against it.
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tagents-notes.XXXXXX") && ROOT=$(cd "$ROOT" && pwd -P) || exit 1
trap 'rm -rf "$ROOT"' EXIT INT TERM

# The hooks commit; a machine without a global identity must not fail the suite.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

pass=0; fail=0

ok() {  # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
  fi
}

contains() {  # <name> <needle> <haystack>
  case "$3" in
    *"$2"*) pass=$((pass + 1)); printf '  ok   %s\n' "$1" ;;
    *) fail=$((fail + 1))
       printf '  FAIL %s\n       expected to contain: %s\n' "$1" "$2" ;;
  esac
}

lacks() {  # <name> <needle> <haystack>
  case "$3" in
    *"$2"*) fail=$((fail + 1))
            printf '  FAIL %s\n       expected NOT to contain: %s\n' "$1" "$2" ;;
    *) pass=$((pass + 1)); printf '  ok   %s\n' "$1" ;;
  esac
}

t() { printf '\n%s\n' "$1"; }

PROJ="$ROOT/proj"
SUB="$PROJ/sub"
NOTES="$PROJ/.claude/notes"
MARKER="$NOTES/.git/ta-last-seen"

mkdir -p "$SUB" "$NOTES"
git -C "$PROJ" init -q
git -C "$NOTES" init -q
: >"$NOTES/prompt.md"
printf 'line one\n' >"$NOTES/doc.md"
git -C "$NOTES" add -A && git -C "$NOTES" commit -q -m "init"

ncommit() { git -C "$NOTES" rev-list --count HEAD; }
nhead()   { git -C "$NOTES" rev-parse HEAD; }
marker()  { cat "$MARKER" 2>/dev/null; }

# The prompt is always submitted from the SUBDIRECTORY, which is what proves the
# folder is resolved from the repo root and not from the cwd.
submit() {  # [cwd] [session id] -> additionalContext, or empty
  local c=${1:-$SUB} s=${2:-t}
  printf '{"hook_event_name":"UserPromptSubmit","cwd":"%s","session_id":"%s","prompt":"x"}' "$c" "$s" \
    | sh "$HOOKS/notes-context.sh" 2>&1 | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}

raw_submit() {  # [cwd] [session id] -> the hook's literal stdout
  local c=${1:-$SUB} s=${2:-t}
  printf '{"hook_event_name":"UserPromptSubmit","cwd":"%s","session_id":"%s","prompt":"x"}' "$c" "$s" \
    | sh "$HOOKS/notes-context.sh" 2>&1
}

submit_ref() {  # <prompt> [cwd] -> the hook's literal stdout
  local p=$1 c=${2:-$SUB}
  printf '{"hook_event_name":"UserPromptSubmit","cwd":"%s","session_id":"t","prompt":"%s"}' "$c" "$p" \
    | sh "$HOOKS/notes-context.sh" 2>&1
}

ctx_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null; }

session_start() {  # <cwd>
  printf '{"hook_event_name":"SessionStart","cwd":"%s","session_id":"t","source":"startup"}' "$1" \
    | sh "$HOOKS/notes-context.sh" 2>&1
}

wrote() {  # <file_path> — a PostToolUse Write, as Claude Code reports it
  printf '{"hook_event_name":"PostToolUse","cwd":"%s","session_id":"t","tool_name":"Write","tool_input":{"file_path":"%s"}}' \
    "$SUB" "$1" | sh "$HOOKS/notes-autocommit.sh" 2>&1
}

STANDING='is a git-versioned notes folder'

# ---------------------------------------------------------------------------
t "1. first prompt: the whole folder, and the marker is banked"
# ---------------------------------------------------------------------------
out=$(submit)
contains "the standing line rides along"  "$STANDING"  "$out"
contains "...and the folder path"         "$NOTES"     "$out"
contains "the changed file is named"      "doc.md"     "$out"
contains "with its content"               "+line one"  "$out"
ok "the marker is now HEAD" "$(nhead)" "$(marker)"

# ---------------------------------------------------------------------------
t "2. nothing changed: nothing said"
# ---------------------------------------------------------------------------
ok "a second prompt injects nothing" "" "$(raw_submit)"

# ---------------------------------------------------------------------------
t "3. the user's own commit is what the diff is FOR"
# ---------------------------------------------------------------------------
printf '> is this right?\n' >>"$NOTES/doc.md"
git -C "$NOTES" commit -qam "user: q"
out=$(submit)
contains "their comment arrives as a + line" "+> is this right?" "$out"
contains "...with the commit subject"        "user: q"           "$out"
lacks    "prompt.md is never replayed"       "prompt.md"         "$out"
ok "the marker advanced" "$(nhead)" "$(marker)"

# ---------------------------------------------------------------------------
t "4. a prompt.md-only commit is not a change"
# ---------------------------------------------------------------------------
printf 'typed into the editor\n' >"$NOTES/prompt.md"
git -C "$NOTES" commit -qam "user: outbox"
ok "an outbox-only commit injects nothing" "" "$(raw_submit)"
ok "...and is still banked"                "$(nhead)" "$(marker)"

# ---------------------------------------------------------------------------
t "5. SessionStart is the standing line, and only where the folder is"
# ---------------------------------------------------------------------------
out=$(session_start "$SUB")
ok "the event name is echoed back" "SessionStart" \
   "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName // ""')"
contains "...carrying the standing line" "$STANDING" \
         "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')"
mkdir -p "$ROOT/elsewhere"
ok "a project with no notes folder is silent" "" "$(session_start "$ROOT/elsewhere")"
ok "...and so is a prompt from it"            "" "$(raw_submit "$ROOT/elsewhere")"

# ---------------------------------------------------------------------------
t "6. autocommit: Claude's own writes never come back as comments"
# ---------------------------------------------------------------------------
before=$(ncommit)
printf 'an old silent pond\n' >"$NOTES/haiku.md"
ok "the hook prints nothing" "" "$(wrote "$NOTES/haiku.md")"
ok "one commit was made"     "$((before + 1))" "$(ncommit)"
ok "...named for the file"   "claude: haiku.md" "$(git -C "$NOTES" log -1 --format='%s')"
ok "...and banked"           "$(nhead)" "$(marker)"
ok "so the next prompt is silent" "" "$(raw_submit)"

before=$(ncommit)
printf 'not a note\n' >"$PROJ/outside.md"
wrote "$PROJ/outside.md" >/dev/null
ok "a file outside the folder is not committed" "$before" "$(ncommit)"
mkdir -p "$ROOT/proj/.claude/notes-archive"
printf 'x\n' >"$ROOT/proj/.claude/notes-archive/a.md"
wrote "$ROOT/proj/.claude/notes-archive/a.md" >/dev/null
ok "...nor is a sibling folder with the same prefix" "$before" "$(ncommit)"
printf 'send this\n' >"$NOTES/prompt.md"
wrote "$NOTES/prompt.md" >/dev/null
ok "...nor the outbox itself" "$before" "$(ncommit)"
git -C "$NOTES" checkout -q -- prompt.md

# ---------------------------------------------------------------------------
t "7. a huge diff is a summary, not a context flood"
# ---------------------------------------------------------------------------
i=0
: >"$NOTES/big.md"
while [ $i -lt 5000 ]; do printf 'ZZQQUNIQUE %s\n' "$i" >>"$NOTES/big.md"; i=$((i + 1)); done
git -C "$NOTES" add -A && git -C "$NOTES" commit -q -m "user: dump"
out=$(submit)
contains "the stat still names the file" "big.md" "$out"
contains "...and says why the body is missing" "diff over 60 KB" "$out"
lacks    "the body itself stays out" "ZZQQUNIQUE 4999" "$out"

# ---------------------------------------------------------------------------
t "8. autocommit commits where git has no identity to commit with"
# ---------------------------------------------------------------------------
# This machine sets user.name per repository, so a freshly created notes folder
# has none: with the global config out of reach too, the commit used to fail
# silently, the marker never moved, and every later diff was measured from the
# wrong base while the model's document sat there uncommitted.
NOID="$ROOT/noid"; NOIDN="$NOID/.claude/notes"
mkdir -p "$NOIDN" "$ROOT/nohome"
git -C "$NOID" init -q
git -C "$NOIDN" init -q
: >"$NOIDN/prompt.md"
git -C "$NOIDN" add -A && git -C "$NOIDN" commit -q -m init

# The suite exports an identity so its own fixtures can commit; the hook has to
# run without one, which means the env vars go too, not just the config files.
noid_wrote() {  # <file_path>
  printf '{"hook_event_name":"PostToolUse","cwd":"%s","session_id":"t","tool_name":"Write","tool_input":{"file_path":"%s"}}' \
    "$NOID" "$1" \
    | env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
          HOME="$ROOT/nohome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
          sh "$HOOKS/notes-autocommit.sh" 2>&1
}

printf 'an old silent pond\n' >"$NOIDN/haiku.md"
ok "the hook is still silent"     "" "$(noid_wrote "$NOIDN/haiku.md")"
ok "the write became a commit"    "claude: haiku.md" "$(git -C "$NOIDN" log -1 --format='%s' 2>/dev/null)"
ok "...and the marker advanced"   "$(git -C "$NOIDN" rev-parse HEAD 2>/dev/null)" \
   "$(cat "$NOIDN/.git/ta-last-seen" 2>/dev/null)"

# ---------------------------------------------------------------------------
t "9. a session that never heard about the folder is told once"
# ---------------------------------------------------------------------------
SEEN="$NOTES/.git/ta-seen-sessions"
ok "the marker is level with HEAD" "$(nhead)" "$(marker)"
out=$(raw_submit "$SUB" s-one)
contains "a session nobody told gets the standing line" "$STANDING" \
         "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')"
lacks    "...and nothing else"     "changed since your last turn" "$out"
ok "the same session is not told twice" "" "$(raw_submit "$SUB" s-one)"
contains "a second session is told too" "$STANDING" "$(submit "$SUB" s-two)"
ok "both ids are remembered" "s-one s-two" \
   "$(grep -x -e s-one -e s-two "$SEEN" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"

# ---------------------------------------------------------------------------
t "10. garbage in, silence out"
# ---------------------------------------------------------------------------
out=$(printf 'not json at all' | sh "$HOOKS/notes-context.sh" 2>&1); rc=$?
ok "invalid JSON exits 0" 0 "$rc"
ok "...with no output"    "" "$out"
out=$(printf 'not json at all' | sh "$HOOKS/notes-autocommit.sh" 2>&1); rc=$?
ok "the autocommit too"   0 "$rc"
ok "...silently"          "" "$out"

# ---------------------------------------------------------------------------
t "11. the dotfiles template registers both hooks"
# ---------------------------------------------------------------------------
S="$DOTFILES/claude/settings.json"
if [ -f "$S" ] && command -v jq >/dev/null 2>&1; then
  jq -e . "$S" >/dev/null 2>&1
  ok "settings.json is valid JSON" 0 $?
  q() { jq -r "$1" "$S" 2>/dev/null; }
  ok "UserPromptSubmit runs notes-context" true \
     "$(q '[.hooks.UserPromptSubmit[].hooks[].command] | any(test("notes-context.sh"))')"
  ok "SessionStart runs notes-context" true \
     "$(q '[.hooks.SessionStart[].hooks[].command] | any(test("notes-context.sh"))')"
  ok "PostToolUse runs notes-autocommit on the write tools" true \
     "$(q '[.hooks.PostToolUse[] | select(.matcher == "Write|Edit|MultiEdit") | .hooks[].command] | any(test("notes-autocommit.sh"))')"
  ok "...async, so it is off the tool-call path" true \
     "$(q '[.hooks.PostToolUse[] | select(.matcher == "Write|Edit|MultiEdit") | .hooks[] | select(.command | test("notes-autocommit.sh")) | .async] | all')"
else
  printf '  skip settings.json (%s not found)\n' "$S"
fi

# ---------------------------------------------------------------------------
t "12. the submit is where a draft becomes a sent message"
# ---------------------------------------------------------------------------
SENT="$NOTES/.git/ta-sent"
REF='@.claude/notes/prompt.md '
printf 'do the thing\n' >"$NOTES/prompt.md"
before=$(ncommit)
out=$(submit_ref "$REF")
ok "the draft was committed"            "$((before + 1))" "$(ncommit)"
ok "...under its own first line"        "user: do the thing" "$(git -C "$NOTES" log -1 --format='%s')"
ok "...and the sent marker is HEAD"     "$(nhead)" "$(cat "$SENT" 2>/dev/null)"
contains "the turn is told the attachment is the message" \
         "attached prompt.md is the user's message" "$(ctx_of "$out")"
ok "the file is left for the CLI to read" "do the thing" "$(cat "$NOTES/prompt.md")"

# A reference that resolves nowhere is somebody else's @-mention.
before=$(ncommit); prev=$(cat "$SENT" 2>/dev/null)
printf 'a second thought\n' >"$NOTES/prompt.md"
out=$(submit_ref '@docs/prompt.md ')
ok "a mention of another file is not a send" "$before" "$(ncommit)"
lacks "...and the turn is not told otherwise" "attached prompt.md" "$out"

# ---------------------------------------------------------------------------
t "13. an empty outbox is not a message, and a plain prompt is not a send"
# ---------------------------------------------------------------------------
: >"$NOTES/prompt.md"
git -C "$NOTES" add -A >/dev/null 2>&1
git -C "$NOTES" commit -q -m "user: outbox cleared" >/dev/null 2>&1
before=$(ncommit); prev=$(cat "$SENT" 2>/dev/null)
out=$(submit_ref "$REF")
ok "a blank outbox commits nothing"  "$before" "$(ncommit)"
ok "...and does not move the marker" "$prev"   "$(cat "$SENT" 2>/dev/null)"
lacks "...and says nothing"          "attached prompt.md" "$out"

printf 'still a draft\n' >"$NOTES/prompt.md"
before=$(ncommit)
out=$(raw_submit)
ok "a prompt with no reference commits nothing" "$before" "$(ncommit)"
lacks "...and mentions no attachment"           "attached prompt.md" "$out"
ok "...and the draft is untouched" "still a draft" "$(cat "$NOTES/prompt.md")"

# THE MENTION IS RESOLVED, NOT PATTERN-MATCHED. The prompt is submitted from a
# subdirectory, so an absolute path is the only form that needs no repo root.
before=$(ncommit)
out=$(submit_ref "@$NOTES/prompt.md " "$SUB")
ok "an absolute reference is a send too" "$((before + 1))" "$(ncommit)"
ok "...named after the draft"            "user: still a draft" "$(git -C "$NOTES" log -1 --format='%s')"
ok "...and marks it sent"                "$(nhead)" "$(cat "$SENT" 2>/dev/null)"
contains "...and tells the turn" "attached prompt.md is the user's message" "$(ctx_of "$out")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
