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

# The oracle (tag v0.6.7) also lists the three `knowledge` verbs in its usage, which moved to the okb binary and are gone from this one; those lines are dropped from its transcript. The oracle (tag v0.6.7) still words the usage line of `notify run` as handing over to node when the binary cannot start; that hand-over is gone, the line says only that the binary serves it. Put the new words into the oracle's transcript file(s) so the usage text compares as the same (a known difference in docs/architecture/rust-core.md).
oracle_usage_words() {  # <file...>
  perl -CSD -pi -e 's/the Rust binary serves it and hands over to node when it cannot start/the Rust binary serves it/; s/бинарник на Rust, а если он не может стартовать, управление передаётся node/бинарник на Rust/; $_ = "" if /^  knowledge (mcp|serve|join)\b.*\(.*: Rust binary only\)$/' "$@"
}

# The oracle (tag v0.7.0) is the program `tagents-knowledge` and tells where the folder is named in the words of tagents: its variable and a `[knowledge]` table in the config. okb is called `okb`, names its own variable and keeps `dir` at the top of its own config; the program name, the sentence and the snippet are put into okb's words in the oracle's transcript.
oracle_okb_words() {  # <file...>
  perl -CSD -pi -e 's/tagents-knowledge/okb/g; s/no knowledge directory: set TAGENTS_KNOWLEDGE_DIR, pass --dir/no knowledge directory: set OKB_DIR, pass --dir/; $_ = "" if /^  \[knowledge\]$/' "$@"
}
