# tests/wait.sh — sourced by the tmux suites: the assertion helpers (ok, has, hasnt, t, near) with their pass/fail counters, and the polling helpers (wait_eq, wait_eq_long, settle).
#
# It sets no shell options and starts nothing. The suite prints its own summary from $pass and $fail. bash 3.2.

pass=0; fail=0
ok()   { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
         else fail=$((fail+1)); printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"; fi; }
has()  { case "$3" in *"$2"*) pass=$((pass+1)); printf '  ok   %s\n' "$1" ;;
         *) fail=$((fail+1)); printf '  FAIL %s\n       expected to contain: %s\n       actual: %s\n' "$1" "$2" "$3" ;; esac; }
hasnt(){ case "$3" in *"$2"*) fail=$((fail+1)); printf '  FAIL %s\n       must not contain: %s\n       actual: %s\n' "$1" "$2" "$3" ;;
         *) pass=$((pass+1)); printf '  ok   %s\n' "$1" ;; esac; }
t()    { printf '\n%s\n' "$1"; }
near() {  # <name> <expected> <actual> — within one column
  local d=$(( $2 - $3 )); [ "$d" -lt 0 ] && d=$(( -d ))
  if [ "$d" -le 1 ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s\n       expected: %s (±1)\n       actual:   %s\n' "$1" "$2" "$3"; fi; }

wait_eq() {  # <expected> <cmd...> — polls ~3 s, prints the last value seen
  local want=$1 got i=0; shift
  while :; do got=$("$@"); [ "$got" = "$want" ] && break; i=$((i + 1)); [ "$i" -ge 30 ] && break; sleep 0.1; done
  printf '%s' "$got"
}
wait_eq_long() {  # <expected> <cmd...> — the same, up to ~8 s: for a list that a hook starts, which is a fresh fzf and a fresh bash
  local want=$1 got i=0; shift
  while :; do got=$("$@"); [ "$got" = "$want" ] && break; i=$((i + 1)); [ "$i" -ge 80 ] && break; sleep 0.1; done
  printf '%s' "$got"
}
settle() { sleep "${1:-0.6}"; }
