#!/bin/bash
# Manual check of the notification helper on this Mac: selftest.sh <app path>.
# Builds the app when it is stale, then runs every verb once and prints one line per step: PASS, FAIL or SKIP.
# The steps that post a notice need the notification permission and print SKIP without it: run
# `<app>/Contents/MacOS/tagents-notify authorize` once and answer the system prompt. Exits 1 when a step that ran failed.
set -u

[ $# -eq 1 ] || { echo "usage: selftest.sh <app path>" >&2; exit 2; }
app=${1%/}
here=$(cd "$(dirname "$0")" && pwd)
bin="$app/Contents/MacOS/tagents-notify"
work=$(mktemp -d)
id="tagents-selftest-$$-$(date +%s)"
posted=no
failures=0

cleanup() {
  [ "$posted" = yes ] && "$bin" withdraw "$id" </dev/null >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

pass() { printf 'PASS  %s: %s\n' "$1" "$2"; }
skip() { printf 'SKIP  %s (%s)\n' "$1" "$2"; }
bad() { printf 'FAIL  %s: %s\n' "$1" "$2"; failures=$((failures + 1)); }

now() { python3 -c 'import time; print(time.time())'; }
field() { python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print(v if isinstance(v,str) else json.dumps(v))' "$1" < "$work/out"; }
one_line_json() {
  [ "$(wc -l < "$work/out" | tr -d ' ')" = 1 ] && python3 -c 'import json,sys; json.loads(sys.stdin.read())' < "$work/out" 2>/dev/null
}
count_of_id() { python3 -c 'import json,sys; print(json.load(sys.stdin)["ids"].count(sys.argv[1]))' "$id" < "$work/out"; }

# run <seconds> <stdin file> <args...>: the helper under a watchdog; sets rc, elapsed and the file $work/out.
run() {
  limit=$1; input=$2; shift 2
  started=$(now)
  "$bin" "$@" < "$input" > "$work/out" 2> "$work/err" &
  helper=$!
  ( sleep "$limit"; kill -9 "$helper" 2>/dev/null ) >/dev/null 2>&1 &
  watchdog=$!
  wait "$helper"; rc=$?
  kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
  elapsed=$(awk "BEGIN { printf \"%.1f\", $(now) - $started }")
}

# step <name> <exit code> <ok field> <seconds> <stdin file> <args...>: runs the verb and checks the exit code,
# exactly one line of JSON and its ok field. Returns 1 after printing FAIL; the caller adds its own checks on PASS.
step() {
  name=$1; want_rc=$2; want_ok=$3; limit=$4; input=$5; shift 5
  run "$limit" "$input" "$@"
  line=$(head -c 300 "$work/out" | tr '\n' ' ')
  if [ "$rc" != "$want_rc" ]; then bad "$name" "exit $rc, wanted $want_rc: $line"; return 1; fi
  if ! one_line_json; then bad "$name" "not exactly one line of JSON: $line"; return 1; fi
  if [ "$(field ok)" != "$want_ok" ]; then bad "$name" "ok is not $want_ok: $line"; return 1; fi
  return 0
}

echo "app: $app" >&2
sh "$here/build.sh" "$app" >/dev/null || { echo "FAIL  build"; exit 1; }

auth=unknown
if step status 0 true 20 /dev/null status; then
  auth=$(field status)
  pass status "$(cat "$work/out")"
fi

pid=$(tmux list-clients -F '#{client_pid}' 2>/dev/null | head -1)
[ -n "$pid" ] || pid=$$
if step "terminal $pid" 0 true 20 /dev/null terminal "$pid"; then
  if [ -n "$(field app)" ]; then pass "terminal $pid" "$(cat "$work/out")"; else bad "terminal $pid" "no terminal app above the pid: $(cat "$work/out")"; fi
fi

if [ "$auth" = authorized ] || [ "$auth" = provisional ]; then
  printf '{"id":"%s","thread":"tagents-selftest","kind":"selftest","title":"tagents selftest","subtitle":"selftest","body":"%s","click":{"argv":[],"env":{}},"terminalPid":%s,"skipIfFrontmost":false}\n' "$id" "$id" "$pid" > "$work/notice.json"
  posted=yes
  if step post 0 true 20 "$work/notice.json" post; then
    if [ "$(field shown)" = true ]; then pass post "$(cat "$work/out")"; else bad post "not shown: $(cat "$work/out")"; fi
  fi
  step "post (same id)" 0 true 20 "$work/notice.json" post && pass "post (same id)" "$(cat "$work/out")"

  polls=0
  while [ $polls -lt 25 ]; do
    run 20 /dev/null delivered
    one_line_json && [ "$(count_of_id)" -ge 1 ] && break
    polls=$((polls + 1)); sleep 0.2
  done
  if step delivered 0 true 20 /dev/null delivered; then
    n=$(count_of_id)
    if [ "$n" = 1 ]; then pass delivered "the id is listed once, after $polls extra polls"; else bad delivered "the id is listed $n times: $(cat "$work/out")"; fi
  fi

  if step withdraw 0 true 20 /dev/null withdraw "$id"; then
    pass withdraw "$(cat "$work/out")"
    posted=no
    if step "delivered (after withdraw)" 0 true 20 /dev/null delivered; then
      if [ "$(count_of_id)" = 0 ]; then pass "delivered (after withdraw)" "the id is gone"; else bad "delivered (after withdraw)" "still listed: $(cat "$work/out")"; fi
    fi
  fi
else
  for name in post delivered withdraw; do skip "$name" "not authorized: $auth"; done
fi

printf 'not json' > "$work/bad.json"
step "post (invalid JSON)" 1 false 20 "$work/bad.json" post && pass "post (invalid JSON)" "$(cat "$work/out")"
step "unknown verb" 2 false 20 /dev/null frobnicate && pass "unknown verb" "$(cat "$work/out")"

if step "no arguments" 0 true 10 /dev/null; then
  if awk "BEGIN { exit !($elapsed < 6) }"; then pass "no arguments" "exited in ${elapsed}s: $(cat "$work/out")"; else bad "no arguments" "took ${elapsed}s, wanted under 6: $(cat "$work/out")"; fi
fi

if [ $failures -gt 0 ]; then echo "$failures step(s) failed"; exit 1; fi
echo "all steps that ran passed"
