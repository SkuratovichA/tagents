#!/usr/bin/env bash
#
# tests/modules.sh — the layout itself: ./tagents is the entry point, and every
# other line of the program lives in lib/tagents/*.sh, which it sources.
#
# What goes wrong once a program is more than one file, and what each case here
# is for: a module nobody sources (dead code that reads as live), a module named
# in the list but not on disk (a dashboard that will not start at all), the same
# function defined in two modules (bash keeps the last one and says nothing), a
# module that RUNS something when it is sourced, a verb in the dispatch whose
# function went missing with the module it was in, and the entry point copied on
# its own — which is how this program used to be shipped, so somebody will.
#
# No tmux, no fzf, no Claude. bash 3.2, runnable from any cwd, non-zero exit
# when any check fails.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TA="$HERE/../tagents"
LIB="$HERE/../lib/tagents"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tagents-modules.XXXXXX") || exit 1
TMP=$(cd "$TMP" && pwd -P) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/state"; : > "$TMP/none.yaml"

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

# The loader is one line in the entry, and this is the only place that knows its
# shape; everything below is derived from it rather than from a second list.
LISTED=$(awk '
  /^[[:space:]]*for ta_mod in/ { grab = 1 }
  grab {
    line = $0
    sub(/^[[:space:]]*for ta_mod in[[:space:]]*/, "", line)
    fin = (line ~ /;[[:space:]]*do[[:space:]]*$/)
    sub(/;[[:space:]]*do[[:space:]]*$/, "", line)
    sub(/\\[[:space:]]*$/, "", line)
    printf "%s ", line
    if (fin) exit
  }' "$TA")

# ---------------------------------------------------------------------------
t "1. the list in the entry and the directory say the same thing"
# ---------------------------------------------------------------------------
ok "the entry names the modules it sources" yes "$([ -n "$LISTED" ] && echo yes || echo no)"

missing=
for m in $LISTED; do [ -r "$LIB/$m.sh" ] || missing="$missing $m"; done
ok "every module in the list is on disk" "" "$missing"

orphan=
for f in "$LIB"/*.sh; do
  b=$(basename "$f" .sh)
  case " $LISTED " in *" $b "*) ;; *) orphan="$orphan $b" ;; esac
done
ok "every module on disk is in the list" "" "$orphan"

dupes=$(grep -hE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$LIB"/*.sh | sed 's/().*//' | sort | uniq -d | tr '\n' ' ')
ok "no function is defined in two modules" "" "${dupes% }"

# ---------------------------------------------------------------------------
t "2. a module defines things and does nothing"
# ---------------------------------------------------------------------------
# Sourced files are read on every single invocation, including the ones the
# status bar makes: anything that runs here runs hundreds of times a day, and
# anything that prints corrupts --list, which is parsed.
out=$(env -i HOME="$TMP" PATH=/usr/bin:/bin TERM=dumb \
        TA_STATE_DIR="$TMP/state" TA_CONFIG="$TMP/none.yaml" \
        /bin/bash -c 'for m in '"$LISTED"'; do . "'"$LIB"'/$m.sh"; done
                      echo "FUNCS=$(compgen -A function | wc -l | tr -d " ")"' 2>&1)
case $out in
  FUNCS=*) n=${out#FUNCS=} ;;
  *) n=0 ;;
esac
ok "sourcing every module prints nothing at all" "FUNCS=$n" "$out"
ok "...and leaves the program defined" yes "$([ "${n:-0}" -ge 100 ] && echo yes || echo "no ($n functions)")"

# ---------------------------------------------------------------------------
t "3. every verb the dispatch answers still has its function"
# ---------------------------------------------------------------------------
# A module dropped from the list would leave the flags it served pointing at
# nothing — and bash only finds that out when the flag is typed.
verbs=$(awk '/^case "\$\{1:-\}" in/,/^esac$/' "$TA" |
        sed -n 's/^  [^)]*)[[:space:]]*\(.*\)$/\1/p' |
        sed 's/^shift; //' | awk '{print $1}' |
        grep -E '^[a-z_][a-z0-9_]*$' | sort -u)
# Defined here wins over anything on $PATH: `dash` is this program's main loop
# on a Mac and a shell on a Linux box, and the one that matters is ours.
undefined=
for v in $verbs; do
  grep -qE "^$v\(\)" "$LIB"/*.sh "$TA" && continue
  env -i PATH=/usr/bin:/bin /bin/bash -c "command -v $v" >/dev/null 2>&1 && continue
  undefined="$undefined $v"
done
ok "every function the dispatch calls is defined somewhere" "" "$undefined"

# ---------------------------------------------------------------------------
t "4. how it is reached: through symlinks, and not as a lonely copy"
# ---------------------------------------------------------------------------
# Installed, this is ~/.local/bin/tagents -> a checkout that is itself a git
# submodule of the dotfiles; a link to a link is the normal case, not an exotic
# one, and the modules are found beside the REAL file at the end of it.
ln -s "$TA" "$TMP/link"
ln -s "$TMP/link" "$TMP/link-to-link"
for l in link link-to-link; do
  out=$(TA_STATE_DIR="$TMP/state" TA_CONFIG="$TMP/none.yaml" /bin/bash "$TMP/$l" --config 2>&1); rc=$?
  ok "reached through a $l it finds its modules" 0 "$rc"
done

cp "$TA" "$TMP/lonely"
out=$(TA_STATE_DIR="$TMP/state" TA_CONFIG="$TMP/none.yaml" /bin/bash "$TMP/lonely" --config 2>&1); rc=$?
ok "a copy of the entry on its own refuses to run" 1 "$rc"
contains "...and says what is missing" "cannot load" "$out"
contains "...and that it is an entry point, not a script" "entry point of a checkout" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
