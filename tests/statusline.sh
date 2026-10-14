#!/usr/bin/env bash
#
# tests/statusline.sh — what hooks/claude-statusline.sh prints, and what it
# writes, for a fixed payload: the same bytes as the version before its escape
# bytes came from one printf instead of five. The reference is a commit, read
# with git show, so the check says "unchanged since" and not "equal to a copy".
#
# bash 3.2, runnable from any cwd, non-zero exit on any failing check.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/../hooks/claude-statusline.sh"
REF_COMMIT=63351d8
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tagents-statusline.XXXXXX") || exit 1
trap 'rm -rf "$ROOT"' EXIT INT TERM

pass=0; fail=0
ok() {  # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else fail=$((fail + 1)); printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"; fi
}

command -v jq >/dev/null 2>&1 || { echo "jq missing: not run"; exit 0; }
git -C "$HERE/.." show "$REF_COMMIT:hooks/claude-statusline.sh" >"$ROOT/ref.sh" 2>/dev/null ||
  { echo "commit $REF_COMMIT not available: not run"; exit 0; }

payload() {  # <context used %> <fast mode>
  printf '{"session_id":"sid-1","model":{"id":"claude-opus-5[1m]","display_name":"Opus"},"cost":{"total_cost_usd":1.25},"context_window":{"used_percentage":%s},"fast_mode":%s}' "$1" "$2"
}
# Prints <stdout bytes as hex>, then the model file without its timestamp.
run_one() {  # <script> <state dir> <payload>
  mkdir -p "$2"
  printf '%s' "$3" | TA_STATE_DIR="$2" /bin/sh "$1" | od -An -c | tr -s ' \n' ' '
  cut -f2- "$2/model/sid-1.tsv" | od -An -c | tr -s ' \n' ' '
}

for case in "10 false" "59 true" "60 false" "84 true" "85 false" "99 true"; do
  set -- $case
  p=$(payload "$1" "$2")
  a=$(run_one "$ROOT/ref.sh" "$ROOT/state-ref-$1" "$p")
  b=$(run_one "$HOOK" "$ROOT/state-new-$1" "$p")
  ok "context $1%, fast $2: the output and the model file are unchanged" "$a" "$b"
  case "$a" in *033*) ;; *) fail=$((fail + 1)); printf '  FAIL context %s: no escape in the reference output\n' "$1" ;; esac
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
