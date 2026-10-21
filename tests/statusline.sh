# tests/statusline.sh — what hooks/claude-statusline.sh prints, and what it
# writes, for a fixed payload: golden bytes embedded below, generated once from
# the version of the 14.10.2026 commit "perf(counts): the status bar serves a
# cache the picker's refresher keeps from the list's own tally" (before its
# escape bytes came from one printf instead of five). And that an unchanged run
# leaves the model file alone: the picker reloads when anything under model/
# changes, and every open session runs this hook every 30 s.
#
# bash 3.2, runnable from any cwd, non-zero exit on any failing check.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# A suite that is not run against a scratch default server aborts here, before it can reach the live one (tests/scratch-guard.sh).
. "$HERE/scratch-guard.sh" && scratch_guard statusline.sh || exit 1
HOOK="$HERE/../hooks/claude-statusline.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tagents-statusline.XXXXXX") || exit 1
trap 'rm -rf "$ROOT"' EXIT INT TERM

pass=0; fail=0
ok() {  # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else fail=$((fail + 1)); printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"; fi
}

command -v jq >/dev/null 2>&1 || { echo "jq missing: not run"; exit 0; }

payload() {  # <context used %> <fast mode>
  printf '{"session_id":"sid-1","model":{"id":"claude-opus-5[1m]","display_name":"Opus"},"cost":{"total_cost_usd":1.25},"context_window":{"used_percentage":%s},"fast_mode":%s}' "$1" "$2"
}
# Prints the stdout bytes as hex, then the model file without its timestamp.
run_one() {  # <state dir> <payload>
  mkdir -p "$1"
  printf '%s' "$2" | TA_STATE_DIR="$1" /bin/sh "$HOOK" | od -An -c | tr -s ' \n' ' '
  cut -f2- "$1/model/sid-1.tsv" | od -An -c | tr -s ' \n' ' '
}
# Golden outputs, from that 14.10.2026 hook: <context %> <fast> <colour code>
ESC=$(printf '\033')
golden() {  # <colour sgr> <pct> <fast mark>
  printf '%s%s%%%s ctx%s%s\n' "${ESC}[$1" "$2" "${ESC}[90m" "$3" "${ESC}[0m" | od -An -c | tr -s ' \n' ' '
  printf 'claude-opus-5\tOpus\t1.25\n' | od -An -c | tr -s ' \n' ' '
}
bolt=$(printf ' \342\232\241')
# sgr is the whole escape tail ("90m", "33m", "1;31m"), written out per case.
check() {  # <pct> <fast> <sgr> <mark>
  local want got
  want=$(golden "$3" "$1" "$4")
  got=$(run_one "$ROOT/state-$1" "$(payload "$1" "$2")")
  ok "context $1%, fast $2: the output and the model file match the golden bytes" "$want" "$got"
}
check 10 false 90m ""
check 59 true 90m "$bolt"
check 60 false 33m ""
check 84 true 33m "$bolt"
check 85 false 1\;31m ""
check 99 true 1\;31m "$bolt"

# An unchanged run leaves the file alone (inode and mtime), a changed cost
# rewrites it, a missing file is created.
sd="$ROOT/state-idem"; mf="$sd/model/sid-1.tsv"
p1=$(payload 10 false)
run_one "$sd" "$p1" >/dev/null
before=$(stat -f '%i %m' "$mf")
sleep 1.1
run_one "$sd" "$p1" >/dev/null
ok "the same payload twice leaves the model file's inode and mtime unchanged" "$before" "$(stat -f '%i %m' "$mf")"
p2=$(printf '%s' "$p1" | sed 's/"total_cost_usd":1.25/"total_cost_usd":2.5/')
run_one "$sd" "$p2" >/dev/null
ok "a changed cost rewrites the model file" "claude-opus-5	Opus	2.5" "$(cut -f2- "$mf")"
ok "a changed cost changes the file's mtime" "1" "$([ "$(stat -f '%i %m' "$mf")" != "$before" ] && echo 1 || echo 0)"
rm -f "$mf"
run_one "$sd" "$p1" >/dev/null
ok "a missing model file is created" "claude-opus-5	Opus	1.25" "$(cut -f2- "$mf")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
