# tests/lib/parity.sh — the helpers of the parity suites (tests/rust-parity.sh, tests/rust-mcp-parity.sh, tests/rust-knowledge-parity.sh, tests/rust-notify-parity.sh, tests/rust-plugin-parity.sh and tests/rust-session-parity.sh).
#
# A helper is here when it is byte for byte the same in two or more suites. One that differs stays in its suite, whose header names the difference.
# The suite sources this file after it has set `pass` and `fail` to 0, beside the counters of its own. The rest of what a helper reads comes from the suite that calls it: `snapshot` reads `RUN`, `sc_user` calls the suite's `reset` and `sc` and counts into `skipped`, and `must_not` reads `RAN` and `$TMP/transcript.node`, which the suite's `play` leaves.
#
# bash 3.2.

# One `stat` format per platform: the path, the type and mode as `ls -l` writes them, and the link target.
if stat -c %A / > /dev/null 2>&1; then STAT_FORMAT=(-c '%n %A %N'); else STAT_FORMAT=(-f '%N %Sp %Y'); fi
IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1

ok() { pass=$((pass + 1)); }
bad() {  # <label> <detail...>
  fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; shift
  [ $# -gt 0 ] && printf '       %s\n' "$@"
}
t() { printf '\n%s\n' "$1"; }

# What the run left: every path with its mode and its checksum or link target.
snapshot() {
  ( cd "$RUN" && { find . -exec stat "${STAT_FORMAT[@]}" {} + 2> /dev/null ; find . -type f -exec cksum {} + 2> /dev/null; } | LC_ALL=C sort )
}

# A scenario that needs a user who is not root (a mode that keeps root out means nothing to root).
sc_user() {  # <label> <the rest of sc's words>
  if [ "$IS_ROOT" -eq 1 ]; then skipped=$((skipped + 1)); reset; return; fi
  sc "$@"
}

# The steps of a script, as JSON the driver reads.
steps() { local out= s; for s in "$@"; do out=${out:+$out,}$s; done; printf '[%s]' "$out"; }

# The string is not in the node transcript.
must_not() {  # <label> <needle>
  [ -n "$RAN" ] || return 0
  if grep -qF -- "$2" "$TMP/transcript.node"; then bad "tripwire $1: node said what this scenario expects it not to say" "found: $2"; else ok; fi
}
