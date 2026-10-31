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
# A suite that is not run against a scratch default server aborts here, before it can reach the live one (tests/scratch-guard.sh).
. "$HERE/scratch-guard.sh" && scratch_guard modules.sh || exit 1
TA="$HERE/../tagents"
LIB="$HERE/../lib/tagents"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tagents-modules.XXXXXX") || exit 1
TMP=$(cd "$TMP" && pwd -P) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/state"; : > "$TMP/none.toml"

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
case " $LISTED " in *" cockpit dash "*|*" cockpit "*" dash "*) cd_order=before ;; *) cd_order=after ;; esac
ok "the cockpit module is sourced before the dashboard's" before "$cd_order"
ok "no function is defined in two modules" "" "${dupes% }"
# The glyph rule is awk source in one variable (AWK_UNTITLE, names.sh), spliced into the three awk programs that need it: it must not be copied back in.
ok "the glyph rule is written once" 1 "$(cat "$LIB"/*.sh | grep -c 'function untitle')"

# Under a UTF-8 locale macOS awk compares strings by the locale's collation, where every Cyrillic letter weighs the same ("я" == "ю", "aя" == "a"), so every awk this program runs is pinned to bytes. A call is the word awk followed by an option or a program, outside a comment; the pinned ones are cut out of the line before the rest is looked at, so a second, bare call on the same line still shows.
unpinned=$(cd "$HERE/.." && for f in lib/tagents/*.sh hooks/*.sh tagents tnotes tusage; do
  [ -f "$f" ] || continue
  grep -nvE '^[[:space:]]*#' "$f" |
    sed -e 's/LC_ALL=C \(command \)\{0,1\}\(\/usr\/bin\/\)\{0,1\}awk//g' |
    grep -E "(^[0-9]+:|[^[:alnum:]_./-])(command )?(/usr/bin/)?awk[[:space:]]+(-[Fvfe]|'|\")" |
    sed "s|^|$f:|" | cut -c1-120
done)
ok "every awk call in lib/, hooks/ and the tagents, tnotes and tusage scripts runs as LC_ALL=C awk" "" "$unpinned"

# ---------------------------------------------------------------------------
t "2. a module defines things and does nothing"
# ---------------------------------------------------------------------------
# Sourced files are read on every single invocation, including the ones the
# status bar makes: anything that runs here runs hundreds of times a day, and
# anything that prints corrupts --list, which is parsed.
out=$(env -i HOME="$TMP" PATH=/usr/bin:/bin TERM=dumb \
        TA_STATE_DIR="$TMP/state" TA_CONFIG="$TMP/none.toml" \
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
  out=$(TA_STATE_DIR="$TMP/state" TA_CONFIG="$TMP/none.toml" /bin/bash "$TMP/$l" --config 2>&1); rc=$?
  ok "reached through a $l it finds its modules" 0 "$rc"
done

cp "$TA" "$TMP/lonely"
out=$(TA_STATE_DIR="$TMP/state" TA_CONFIG="$TMP/none.toml" /bin/bash "$TMP/lonely" --config 2>&1); rc=$?
ok "a copy of the entry on its own refuses to run" 1 "$rc"
contains "...and says what is missing" "cannot load" "$out"
contains "...and that it is an entry point, not a script" "entry point of a checkout" "$out"

# ---------------------------------------------------------------------------
t "5. every message goes through notice, and tnotes' copies match the originals"
# ---------------------------------------------------------------------------
# The dashboard's own status line is off in the cockpit, so a message shown with a bare display-message never reaches the user. notice() in core.sh is the one place that names the viewport's client; a line anywhere else that runs display-message is a message that will be lost there. Comments, and the one definition, are not sites.
NOTICE_BODY=$(awk '/^notice\(\) \{/ { grab = 1 } grab { print } grab && /^\}/ { exit }' "$LIB/core.sh")
DEF_LINE=$(printf '%s\n' "$NOTICE_BODY" | grep -F 'display-message "$1"')
sites=$(for f in "$TA" "$LIB"/*.sh "$HERE/../tnotes"; do
          awk -v f="${f##*/}" -v def="$DEF_LINE" '
            { l = $0 }
            l == def { next }
            { sub(/^[ \t]+/, "", l); if (l ~ /^#/) next; sub(/[ \t]#[ \t].*$/, "", l) }
            l ~ /display-message/ { print f ":" NR ": " l }' "$f"
        done)
ok "no line outside notice() runs display-message" "" "$sites"
contains "notice() is defined in core.sh" 'notice() {' "$NOTICE_BODY"
contains "...and it names the viewport's client" '@tagents_viewport_tty' "$NOTICE_BODY"

# tnotes sources nothing from lib/, so it carries copies of notice() and of cockpit_up(); they are the same lines.
TN_BODY=$(awk '/^notice\(\) \{/ { grab = 1 } grab { print } grab && /^\}/ { exit }' "$HERE/../tnotes")
ok "tnotes' notice() has the body of core.sh's" "$NOTICE_BODY" "$TN_BODY"
UP_LINE=$(grep -h '^cockpit_up()' "$LIB/cockpit.sh")
ON_LINE=$(grep -h '^cockpit_on()' "$HERE/../tnotes")
ok "tnotes' cockpit check has the body of cockpit_up()" "${UP_LINE#cockpit_up}" "${ON_LINE#cockpit_on}"
ok "...and the original is there to compare with" yes "$([ -n "$UP_LINE" ] && echo yes || echo no)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
