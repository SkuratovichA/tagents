#!/usr/bin/env bash
#
# tests/dispatch.sh — the one thing `tagents` does with a verb it does not know:
# hand it to tagents-core, argv and exit code intact.
#
# What is actually at stake is the OTHER half: every flag the dashboard answers
# itself must never reach the forwarder, because the day one does, a typo in
# `--counts` starts a process instead of printing a line. So the reserved names
# are tested as carefully as the forwarded ones.
#
# tagents-core is a STUB on a temp $PATH that records the argv it was given and
# exits with whatever $STUB_EXIT says — nothing here runs node, and nothing here
# can reach a real tagents-core the developer happens to have installed, because
# every case rebuilds $PATH from scratch.
#
# No tmux, no fzf, no Claude. bash 3.2, runnable from any cwd, non-zero exit
# when any check fails.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# A suite that is not run against a scratch default server aborts here, before it can reach the live one (tests/scratch-guard.sh).
. "$HERE/scratch-guard.sh" && scratch_guard dispatch.sh || exit 1
TA="$HERE/../tagents"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tagents-dispatch.XXXXXX") || exit 1
TMP=$(cd "$TMP" && pwd -P) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

pass=0; fail=0

ok() {  # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
  fi
}

contains() {  # <name> <needle> <haystack>
  case "$3" in
    *"$2"*) pass=$((pass + 1)); printf '  ok   %s\n' "$1" ;;
    *) fail=$((fail + 1))
       printf '  FAIL %s\n       expected to contain: %s\n       actual: %s\n' "$1" "$2" "$3" ;;
  esac
}

t() { printf '\n%s\n' "$1"; }

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------
# A stub that answers to the name and writes down what it was handed. One
# argument per line, so an argument containing a space is still one line.
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/tagents-core" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$ARGV_FILE"
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$BIN/tagents-core"

ARGV="$TMP/argv"
BARE=/usr/bin:/bin:/usr/sbin:/sbin      # no tagents-core anywhere on it
export ARGV_FILE="$ARGV"

# A copy of the script with nothing beside it: no packages/, so the only
# tagents-core it can find is one on $PATH.
SOLO="$TMP/solo"; mkdir -p "$SOLO/lib"
cp "$TA" "$SOLO/tagents"; cp -R "$HERE/../lib/tagents" "$SOLO/lib/"

# ...and a copy with a built core beside it, the way a repo checkout looks.
REPO="$TMP/repo"; mkdir -p "$REPO/packages/core/dist/cli" "$REPO/lib"
cp "$TA" "$REPO/tagents"; cp -R "$HERE/../lib/tagents" "$REPO/lib/"
cat > "$REPO/packages/core/dist/cli/main.js" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$ARGV_FILE"
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$REPO/packages/core/dist/cli/main.js"

run() {  # <script> <PATH> [args…] — prints stdout+stderr, sets $rc
  local script path_
  script=$1; path_=$2; shift 2
  rm -f "$ARGV"
  out=$(PATH="$path_" TA_STATE_DIR="$TMP/state" TA_CONFIG="$TMP/no-config.yaml" \
        /bin/bash "$script" "$@" 2>&1)
  rc=$?
  printf '%s' "$out"
}

argv() { [ -f "$ARGV" ] && tr '\n' ' ' < "$ARGV" | sed 's/ $//'; }

# ---------------------------------------------------------------------------
t "1. a verb the dashboard does not know goes to tagents-core"
# ---------------------------------------------------------------------------

STUB_EXIT=0 run "$SOLO/tagents" "$BIN:$BARE" session list --label x >/dev/null
ok "the whole argv is forwarded, flags and all" "session list --label x" "$(argv)"
ok "...and the verb's exit code is the script's"  0 "$rc"

# The exit code is the POINT of exec-ing: a wrapper that swallowed it would
# make every scripted `tagents plugin add` look like it worked.
STUB_EXIT=3 run "$SOLO/tagents" "$BIN:$BARE" plugin add ./x >/dev/null
ok "a refusal comes back as 3, not as 0" 3 "$rc"
ok "...having been handed the arguments" "plugin add ./x" "$(argv)"

STUB_EXIT=2 run "$SOLO/tagents" "$BIN:$BARE" nonsense >/dev/null
ok "an unknown verb is tagents-core's to refuse, not ours" 2 "$rc"
ok "...and it got the chance to"                           "nonsense" "$(argv)"

# An argument with a space in it must survive as ONE argument.
STUB_EXIT=0 run "$SOLO/tagents" "$BIN:$BARE" session prompt ref "two words" >/dev/null
ok "an argument with a space stays one argument" 4 "$(wc -l < "$ARGV" | tr -d ' ')"

# ---------------------------------------------------------------------------
t "2. the dashboard's own flags never reach it"
# ---------------------------------------------------------------------------

for flag in --help --keys --hidden-cols --config --check --header --viewport; do
  run "$SOLO/tagents" "$BIN:$BARE" "$flag" >/dev/null
  ok "$flag is answered here"   ""  "$(argv)"
done
run "$SOLO/tagents" "$BIN:$BARE" --help >/dev/null
contains "the help lists --viewport" "tagents --viewport" "$out"
run "$SOLO/tagents" "$BIN:$BARE" --viewport >/dev/null
ok       "--viewport outside tmux is refused" 1 "$rc"

# A --flag the dashboard does not know is a typo in ITS vocabulary, and stays
# the error it always was rather than becoming somebody else's problem.
# $out and $rc, not a command substitution: a subshell would lose the code.
run "$SOLO/tagents" "$BIN:$BARE" --nope >/dev/null
ok       "an unknown option is still an unknown option" 2 "$rc"
contains "...with the line it always printed" "tagents: unknown option --nope" "$out"
ok       "...and nothing was forwarded"       ""  "$(argv)"

# The verbs the previous version handed to tmux keep arriving after an update
# lands under a running list: its focus hooks stay until the first start of this
# version removes them. A non-zero exit there is a "returned 2" on every focus,
# and anything printed is shown over the pane.
for flag in --poke --unpark --undock-pane --undock-window; do
  run "$SOLO/tagents" "$BIN:$BARE" "$flag" '%67' >/dev/null
  ok "$flag from the previous version's tmux exits 0" 0 "$rc"
  ok "...prints nothing"                              ""  "$out"
  ok "...and forwards nothing"                        ""  "$(argv)"
done

# ---------------------------------------------------------------------------
t "3. where tagents-core is found"
# ---------------------------------------------------------------------------

STUB_EXIT=5 run "$REPO/tagents" "$BARE" session list >/dev/null
ok "a checkout finds it beside the script, with nothing on \$PATH" "session list" "$(argv)"
ok "...and passes that exit code through too"                      5 "$rc"

# On $PATH wins: that is the installed one, and it is the one the user chose.
STUB_EXIT=0 run "$REPO/tagents" "$BIN:$BARE" doctor >/dev/null
ok "an installed tagents-core is preferred to the checkout" "doctor" "$(argv)"

# The Rust front door, built in the tree: it is a stub too, and says it was the one that ran.
mkdir -p "$REPO/target/release"
cat > "$REPO/target/release/tagents-core" <<'EOF'
#!/bin/sh
{ echo rust; printf '%s\n' "$@"; } > "$ARGV_FILE"
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$REPO/target/release/tagents-core"

STUB_EXIT=4 run "$REPO/tagents" "$BARE" session list --label x >/dev/null
ok "a Rust binary built beside the script runs, with the whole argv" "rust session list --label x" "$(argv)"
ok "...and its exit code is the script's" 4 "$rc"
STUB_EXIT=0 run "$REPO/tagents" "$BIN:$BARE" doctor >/dev/null
ok "an installed tagents-core is still preferred to it" "doctor" "$(argv)"
chmod -x "$REPO/target/release/tagents-core"
STUB_EXIT=0 run "$REPO/tagents" "$BARE" session list >/dev/null
ok "a Rust binary that is not executable is passed over for the node CLI" "session list" "$(argv)"
rm -rf "$REPO/target"
STUB_EXIT=0 run "$REPO/tagents" "$BARE" session list >/dev/null
ok "with no Rust binary at all it is the node CLI, as before" "session list" "$(argv)"

# ---------------------------------------------------------------------------
t "4. with no tagents-core at all"
# ---------------------------------------------------------------------------

run "$SOLO/tagents" "$BARE" session list >/dev/null
ok       "exit 2, the same code a usage error gets" 2 "$rc"
ok       "one line, not a stack of them"            1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
contains "...naming the verb that went nowhere"     'session' "$out"
contains "...and saying it is not on PATH"          'no tagents-core on PATH' "$out"
contains "...and where else it looked"              'packages/core/dist/cli/main.js' "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
