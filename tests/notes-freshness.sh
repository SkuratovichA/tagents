#!/usr/bin/env bash
#
# tests/notes-freshness.sh — the PostToolUse hook that tells a session when the
# notes document it just read describes a world that has moved on.
#
# No tmux, no Claude, no network: the hook is stdin-JSON in, stdout-JSON out,
# so the whole contract is exercised by piping payloads at it over throwaway
# git repos in a mktemp dir. Commit dates are pinned with GIT_COMMITTER_DATE so
# "written before / landed after" is a fact of the fixture and not of the clock.
# Nothing here touches the real notes folders or the real ~/.claude.
#
# bash 3.2, runnable from any cwd, non-zero exit when any check fails.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/../hooks/notes-freshness.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/notes-freshness-t.XXXXXX") || exit 1
trap 'rm -rf "$ROOT"' EXIT INT TERM

OLD=2026-09-01T12:00:00     # when the documents were written
NEW=2026-09-10T12:00:00     # when the work landed

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
       else fail=$((fail+1)); printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fi; }
contains() { case "$3" in *"$2"*) pass=$((pass+1)); printf '  ok   %s\n' "$1" ;;
             *) fail=$((fail+1)); printf '  FAIL %s\n       expected to contain: %s\n       actual: %s\n' "$1" "$2" "$3" ;; esac; }
missing() { case "$3" in *"$2"*) fail=$((fail+1)); printf '  FAIL %s\n       should NOT contain: %s\n' "$1" "$2" ;;
            *) pass=$((pass+1)); printf '  ok   %s\n' "$1" ;; esac; }
t() { printf '\n%s\n' "$1"; }

run() {  # <file> [session id] [tool name] -> the hook's stdout
  printf '{"hook_event_name":"PostToolUse","tool_name":"%s","tool_input":{"file_path":"%s"},"session_id":"%s"}' \
    "${3:-Read}" "$1" "${2:-s1}" | sh "$HOOK" 2>/dev/null
}
ctx() { run "$@" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null; }

mkrepo() {  # <dir> [date] — a git repo with one commit
  mkdir -p "$1" && git -C "$1" init -q 2>/dev/null
  git -C "$1" config user.email t@t; git -C "$1" config user.name t
  # Section 5 puts a repo inside a repo on purpose; the advice about submodules
  # is not a finding, it is noise on top of one.
  git -C "$1" config advice.addEmbeddedRepo false
  echo seed >"$1/seed"; git -C "$1" add -A
  GIT_AUTHOR_DATE="${2:-2026-08-01T00:00:00}" GIT_COMMITTER_DATE="${2:-2026-08-01T00:00:00}" \
    git -C "$1" commit -qm seed
}

land() {  # <repo> <relative path> <date> — one commit touching that path
  mkdir -p "$(dirname "$1/$2")"; printf 'more\n' >>"$1/$2"; git -C "$1" add -A
  GIT_AUTHOR_DATE="$3" GIT_COMMITTER_DATE="$3" git -C "$1" commit -qm "touch $2"
}

doc() {  # <notes dir> <name> <date> <body…on stdin> — a committed document
  mkdir -p "$1"; cat >"$1/$2"
  git -C "$1" add -A
  GIT_AUTHOR_DATE="$3" GIT_COMMITTER_DATE="$3" git -C "$1" commit -qm "doc $2"
}

# ---------------------------------------------------------------------------
t "1. anything that is not a notes document is silence"

mkrepo "$ROOT/proj"
N="$ROOT/proj/.claude/notes"
mkrepo "$N" "$OLD"
doc "$N" plain.md "$OLD" <<'EOF'
# a finding

The PATCH route does not validate name length.
EOF

ok "an empty payload"            "" "$(printf '' | sh "$HOOK" 2>/dev/null)"
ok "not JSON at all"             "" "$(printf 'not json' | sh "$HOOK" 2>/dev/null)"
ok "no file_path field"          "" "$(printf '{"tool_name":"Read"}' | sh "$HOOK" 2>/dev/null)"
ok "a tool that is not Read"     "" "$(ctx "$N/plain.md" s1 Edit)"
ok "a file outside a notes folder" "" "$(ctx "$ROOT/proj/seed" s1)"
ok "a file that does not exist"  "" "$(ctx "$N/nope.md" s1)"
ok "prompt.md is a channel, not a document" "" "$(ctx "$N/prompt.md" s1)"

mkdir -p "$N/AA-1"; printf '# AA-1\n' >"$N/AA-1/ledger.md"
ok "a ledger carries its own sync stamp" "" "$(ctx "$N/AA-1/ledger.md" s1)"

# ---------------------------------------------------------------------------
t "2. a document nothing has outrun yet"

ok "committed, and the repo has not moved since" "" "$(ctx "$N/plain.md" s-quiet)"

printf '# brand new\n' >"$N/uncommitted.md"
ok "never committed: no claim to make about it" "" "$(ctx "$N/uncommitted.md" s1)"

# ---------------------------------------------------------------------------
t "3. no pin: the repository around the notes folder"

land "$ROOT/proj" app/reports.py "$NEW"
land "$ROOT/proj" docs/readme.md "$NEW"
out=$(ctx "$N/plain.md" s3)
contains "counts what landed since it was written" "2 commits have landed in proj" "$out"
contains "...and says the count is the whole repository" "pins no paths" "$out"
contains "...and separates what still holds from what does not" "hypotheses to verify" "$out"
contains "...naming the document" "plain.md" "$out"
ok "the event name is echoed back" "PostToolUse" \
   "$(run "$N/plain.md" s3b | jq -r '.hookSpecificOutput.hookEventName')"

before=$(cat "$N/plain.md")
ctx "$N/plain.md" s3c >/dev/null
ok "the document itself is never touched" "$before" "$(cat "$N/plain.md")"

# ---------------------------------------------------------------------------
t "4. the pin counts only the paths the document is about"

doc "$N" pinned.md "$OLD" <<EOF
# scoped finding

<!-- pinned: .@$(git -C "$ROOT/proj" rev-parse HEAD) · app -->

Only the reports module matters here.
EOF

ok "nothing has touched that scope yet" "" "$(ctx "$N/pinned.md" s4)"

land "$ROOT/proj" docs/other.md "$NEW"
ok "a commit outside the scope is not drift" "" "$(ctx "$N/pinned.md" s4b)"

land "$ROOT/proj" app/reports.py "$NEW"
out=$(ctx "$N/pinned.md" s4c)
contains "a commit inside the scope is" "1 commits touched the paths it pins" "$out"
missing "...and it does not fall back to the whole repo" "pins no paths" "$out"

# ---------------------------------------------------------------------------
t "5. several repositories, one document"

mkrepo "$ROOT/proj/sibling"
sib=$(git -C "$ROOT/proj/sibling" rev-parse HEAD)
doc "$N" multi.md "$OLD" <<EOF
# spans two repos

<!-- pinned: .@$(git -C "$ROOT/proj" rev-parse HEAD) · app -->
<!-- pinned: sibling@$sib -->

Both sides moved together.
EOF

ok "both pinned repos are still where the document left them" "" "$(ctx "$N/multi.md" s5)"

land "$ROOT/proj" app/reports.py "$NEW"
land "$ROOT/proj/sibling" lib.py "$NEW"
land "$ROOT/proj/sibling" other.py "$NEW"
out=$(ctx "$N/multi.md" s5b)
contains "the counts are summed" "3 commits touched the paths it pins" "$out"
contains "...and broken down per repository" "sibling 2" "$out"

# ---------------------------------------------------------------------------
t "6. a pin that came loose invents nothing"

doc "$N" loose.md "$OLD" <<'EOF'
# rebased out from under itself

<!-- pinned: .@0000000000000000000000000000000000000000 · app -->

The sha no longer exists in that repo.
EOF

out=$(ctx "$N/loose.md" s6)
missing "no count is conjured from a sha that is gone" "touched the paths it pins" "$out"
contains "...it falls back to the repository around it" "have landed in proj" "$out"

# ---------------------------------------------------------------------------
t "7. an example of the marker is not a pin"

doc "$N" about.md "$OLD" <<EOF
# how the convention works

A document pins the commits it was written against. The marker goes in the
first ten lines of the file, at the start of a line, and looks like this:

    <!-- pinned: aa-architecture@deadbee · app/reports -->

Indented inside a fence it is an example, not a pin, which is why the scan is
anchored and stops after line ten.

<!-- pinned: .@$(git -C "$ROOT/proj" rev-parse HEAD) · app -->
EOF

out=$(ctx "$N/about.md" s7)
contains "a quoted marker does not pin the document" "have landed in proj" "$out"
missing "...and neither does one below line ten" "touched the paths it pins" "$out"

# ---------------------------------------------------------------------------
t "8. once per document per session"

ok "the same session is not told twice" "" "$(ctx "$N/plain.md" s3)"
contains "a different session is" "have landed in proj" "$(ctx "$N/plain.md" s-other)"
ok "...and that one is then quiet too" "" "$(ctx "$N/plain.md" s-other)"
missing "the bookkeeping stays inside .git" "ta-freshness-seen" \
        "$(git -C "$N" status --porcelain)"

# ---------------------------------------------------------------------------
t "9. a notes folder with no repository beside it"

S="$ROOT/solo/.claude/notes"
mkrepo "$S" "$OLD"
doc "$S" old.md "$OLD" <<'EOF'
# an audit of something that lives elsewhere
EOF

export NF_AGE_DAYS=9999
ok "young enough not to nag" "" "$(ctx "$S/old.md" s9)"

export NF_AGE_DAYS=1
out=$(ctx "$S/old.md" s9b)
contains "old enough to say so" "days ago" "$out"
contains "...and honest that it cannot measure drift" "no repository beside it" "$out"
unset NF_AGE_DAYS

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
