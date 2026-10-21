#!/usr/bin/env bash
#
# tests/ticket-ledger.sh — the SessionStart hook that answers "which ticket is
# this session on".
#
# No tmux, no Claude, no network: the hook is stdin-JSON in, stdout-JSON out,
# so the whole contract is exercised by piping payloads at it over throwaway
# git repos in a mktemp dir. $TA_STATE_DIR is redirected, PATH is stripped of `gh`
# for the run, and nothing here touches the real notes folders, the real
# ~/.claude, or the running dashboard.
#
# bash 3.2, runnable from any cwd, non-zero exit when any check fails.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# A suite that is not run against a scratch default server aborts here, before it can reach the live one (tests/scratch-guard.sh).
. "$HERE/scratch-guard.sh" && scratch_guard ticket-ledger.sh || exit 1
HOOK="$HERE/../hooks/ticket-ledger.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ticket-ledger-t.XXXXXX") || exit 1
trap 'rm -rf "$ROOT"' EXIT INT TERM

# A scratch HOME, so that a hook reading the wrong variable can never write into
# a real one: the default $HOME/.claude/agent-state is under it.
export HOME="$ROOT/home"
mkdir -p "$HOME"
export TA_STATE_DIR="$ROOT/state"
mkdir -p "$TA_STATE_DIR"
# `gh` must never be reached from a test: the PR block is a network call and
# this suite has to pass on a laptop with no token and no wifi.
export PATH="$ROOT/bin:$PATH"
mkdir -p "$ROOT/bin"
# Shadowed for the WHOLE suite, not just the section that tests it. A real gh
# on PATH makes the hook spawn its background refresh, and that refresh moves
# a file over the PR cache — which raced with section 7's fixture and failed it
# about one run in three.
printf '#!/bin/sh\nexit 1\n' >"$ROOT/bin/gh"; chmod +x "$ROOT/bin/gh"

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
       else fail=$((fail+1)); printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fi; }
contains() { case "$3" in *"$2"*) pass=$((pass+1)); printf '  ok   %s\n' "$1" ;;
             *) fail=$((fail+1)); printf '  FAIL %s\n       expected to contain: %s\n       actual: %s\n' "$1" "$2" "$3" ;; esac; }
missing() { case "$3" in *"$2"*) fail=$((fail+1)); printf '  FAIL %s\n       should NOT contain: %s\n' "$1" "$2" ;;
            *) pass=$((pass+1)); printf '  ok   %s\n' "$1" ;; esac; }
t() { printf '\n%s\n' "$1"; }

run() {  # <cwd> [session id] -> the hook's stdout
  printf '{"hook_event_name":"SessionStart","cwd":"%s","session_id":"%s"}' "$1" "${2:-s1}" |
    sh "$HOOK" 2>/dev/null
}
ctx() { run "$@" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null; }

repo() {  # <dir> <branch> — a git repo with one commit, on that branch
  mkdir -p "$1" && git -C "$1" init -q 2>/dev/null
  git -C "$1" config user.email t@t; git -C "$1" config user.name t
  echo x >"$1/f"; git -C "$1" add f; git -C "$1" commit -qm init
  git -C "$1" checkout -q -b "$2" 2>/dev/null
}

ledger() {  # <repo> <ticket> — a ledger with both halves
  mkdir -p "$1/.claude/notes/$2"
  cat >"$1/.claude/notes/$2/ledger.md" <<EOF
# $2 — a thing

<!-- derived · rewritten by the SessionStart hook · do not hand-edit this block -->
## State · synced never
worktree  stale line that must be replaced
<!-- /derived -->

## Decisions
- snapshots, not artifacts — the reason nobody can regenerate

## Open questions
- does hiding hide it for shared viewers too?

## Next
- write the e2e specs
EOF
}

# ---------------------------------------------------------------------------
t "1. resolving the ticket"

repo "$ROOT/a" feature/PROJ-2102-report-editing
contains "the branch name names the ticket" "like PROJ-2102," "$(ctx "$ROOT/a")"

repo "$ROOT/plain" main
mkdir -p "$ROOT/plain/PROJ-3001-worktree" && (cd "$ROOT/plain/PROJ-3001-worktree" && git init -q && git config user.email t@t && git config user.name t)
contains "a worktree directory names it when the branch does not" "like PROJ-3001," "$(ctx "$ROOT/plain/PROJ-3001-worktree")"

printf 's9\tPROJ-4004 the label\n' >"$TA_STATE_DIR/labels.tsv"
ok "the dashboard label is the last resort" "" "$(ctx "$ROOT/plain" s-none)"
contains "...and it does resolve when it matches" "like PROJ-4004," "$(ctx "$ROOT/plain" s9)"

ok "no ticket anywhere is silence, not noise" "" "$(ctx "$ROOT/plain" s-unknown)"

# ---------------------------------------------------------------------------
t "2. bad input is silence too"

ok "an empty payload" "" "$(printf '' | sh "$HOOK" 2>/dev/null)"
ok "not JSON at all" "" "$(printf 'not json' | sh "$HOOK" 2>/dev/null)"
ok "a cwd that does not exist" "" "$(printf '{"cwd":"/nope/nope"}' | sh "$HOOK" 2>/dev/null)"
ok "no cwd field" "" "$(printf '{"hook_event_name":"SessionStart"}' | sh "$HOOK" 2>/dev/null)"

# ---------------------------------------------------------------------------
t "3. no ledger yet"

out=$(ctx "$ROOT/a")
contains "says where the ledger would go" ".claude/notes/PROJ-2102/ledger.md" "$out"
contains "...and what would be worth writing into it" "rejected" "$out"

# ---------------------------------------------------------------------------
t "4. the derived block, and only the derived block"

ledger "$ROOT/a" PROJ-2102
out=$(ctx "$ROOT/a")
led="$ROOT/a/.claude/notes/PROJ-2102/ledger.md"
contains "the pointer names the ledger" "ledger.md" "$out"
contains "...and carries the next action" "write the e2e specs" "$out"
contains "...and counts the open questions" "Open questions: 1" "$out"

contains "the block now holds the branch"  'branch `feature/PROJ-2102-report-editing`' "$(cat "$led")"
missing "...and the stale line is gone" "stale line that must be replaced" "$(cat "$led")"
contains "the hand-written half is untouched" "snapshots, not artifacts" "$(cat "$led")"
contains "...all of it" "does hiding hide it for shared viewers too?" "$(cat "$led")"

echo "dirt" >"$ROOT/a/untracked"
ctx "$ROOT/a" >/dev/null
contains "a dirty tree is counted" "uncommitted" "$(cat "$led")"

ok "the markers survive a second run" 1 "$(grep -c '^<!-- /derived -->' "$led")"
ctx "$ROOT/a" >/dev/null; ctx "$ROOT/a" >/dev/null
ok "...and a third and fourth, without duplicating the block" 1 "$(grep -c '^## State' "$led")"

# ---------------------------------------------------------------------------
t "5. a ledger with no markers is not this hook's to edit"

mkdir -p "$ROOT/a/.claude/notes/PROJ-9999"
printf '# PROJ-9999\n\nhand written, no markers anywhere\n' >"$ROOT/a/.claude/notes/PROJ-9999/ledger.md"
repo "$ROOT/b" feature/PROJ-9999-thing
mkdir -p "$ROOT/b/.claude/notes/PROJ-9999"
printf '# PROJ-9999\n\nhand written, no markers anywhere\n' >"$ROOT/b/.claude/notes/PROJ-9999/ledger.md"
before=$(cat "$ROOT/b/.claude/notes/PROJ-9999/ledger.md")
ctx "$ROOT/b" >/dev/null
ok "left byte for byte alone" "$before" "$(cat "$ROOT/b/.claude/notes/PROJ-9999/ledger.md")"

# ---------------------------------------------------------------------------
t "6. the spec line"

mkdir -p "$ROOT/b/openspec/changes/proj-9999-thing"
printf 'stage: applied\n' >"$ROOT/b/openspec/changes/proj-9999-thing/ledger.yaml"
printf '# proposal for PROJ-9999\n' >"$ROOT/b/openspec/changes/proj-9999-thing/proposal.md"
git -C "$ROOT/b" add -A >/dev/null 2>&1; git -C "$ROOT/b" commit -qm spec
ledger "$ROOT/b" PROJ-9999
ctx "$ROOT/b" >/dev/null
contains "names the change and its stage" 'stage `applied`' "$(cat "$ROOT/b/.claude/notes/PROJ-9999/ledger.md")"

printf '\n\n' >>"$ROOT/b/openspec/changes/proj-9999-thing/proposal.md"
git -C "$ROOT/b" add -A >/dev/null 2>&1; git -C "$ROOT/b" commit -qm "spec moved on"
printf '\n' >>"$ROOT/b/openspec/changes/proj-9999-thing/proposal.md"
git -C "$ROOT/b" add -A >/dev/null 2>&1; git -C "$ROOT/b" commit -qm "spec moved on again"
ctx "$ROOT/b" >/dev/null
contains "and says so when the change has moved since that stage" "STALE" "$(cat "$ROOT/b/.claude/notes/PROJ-9999/ledger.md")"

# ---------------------------------------------------------------------------
t "7. PR state is served from cache and never waited on"

mkdir -p "$TA_STATE_DIR/ledger"
printf 'web-ui#77 open · common-lib#7 merged\n' >"$TA_STATE_DIR/ledger/prs.PROJ-2102.txt"
ctx "$ROOT/a" >/dev/null
contains "the cached listing lands in the block" "web-ui#77 open" "$(cat "$led")"

# Now make it slow rather than absent, and force the TTL open so the refresh
# actually fires on this call.
cat >"$ROOT/bin/gh" <<'EOF'
#!/bin/sh
sleep 30   # a hook that waits on this has already failed
EOF
chmod +x "$ROOT/bin/gh"
touch -t 200001010000 "$TA_STATE_DIR/ledger/prs.PROJ-2102.txt"
start=$(date +%s)
ctx "$ROOT/a" >/dev/null
elapsed=$(( $(date +%s) - start ))
if [ "$elapsed" -le 3 ]; then pass=$((pass+1)); printf '  ok   a slow gh does not delay the session (%ss)\n' "$elapsed"
else fail=$((fail+1)); printf '  FAIL a slow gh delayed the session by %ss\n' "$elapsed"; fi
rm -f "$ROOT/bin/gh"

# ---------------------------------------------------------------------------
t "8. the state directory is TA_STATE_DIR, the one every other part reads"

FRESH="$ROOT/fresh-state"
out=$(TA_STATE_DIR="$FRESH" run "$ROOT/a" s-fresh)
ok "with only TA_STATE_DIR set, the PR cache directory lands under it" yes \
   "$([ -d "$FRESH/ledger" ] && echo yes || echo no)"
ok "...and nothing appears under \$HOME/.claude/agent-state" "" \
   "$(ls -A "$HOME/.claude/agent-state" 2>/dev/null)$([ -e "$HOME/.claude/agent-state" ] && echo exists)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
