#!/usr/bin/env bash
#
# tests/usage.sh — the monthly limit on screen: the status bar figure, the
# footer under the list, the $ table, and the account environment tusage is
# handed.
#
# tusage is stubbed, so nothing here reads a real transcript or a real index:
# the stub prints a canned --daily table out of a file the fixtures write, and
# dumps TU_ACCOUNTS/TU_ACCOUNT_RULES into another so the environment tagents
# exports can be asserted from the far side. A throwaway tmux server is up only
# because --counts renders the list to count it, and the sweep it starts must
# not be allowed to find the real one and rename its windows.
#
# bash 3.2, runnable from any cwd, non-zero exit on any failing check.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TA="$HERE/../tagents"

command -v tmux >/dev/null 2>&1 || { echo "usage.sh: no tmux"; exit 1; }

S=tausage-$$
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tagents-usage.XXXXXX") || exit 1
ROOT=$(cd "$ROOT" && pwd -P) || exit 1
SOCK=""
trap 'tmux -L "$S" kill-server >/dev/null 2>&1
      [ -n "$SOCK" ] && rm -f "$SOCK"
      rm -rf "$ROOT"' EXIT INT TERM

pass=0; fail=0
ok()   { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
         else fail=$((fail+1)); printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"; fi; }
has()  { case "$3" in *"$2"*) pass=$((pass+1)); printf '  ok   %s\n' "$1" ;;
         *) fail=$((fail+1)); printf '  FAIL %s\n       expected to contain: %s\n       actual: %s\n' "$1" "$2" "$3" ;; esac; }
hasnt(){ case "$3" in *"$2"*) fail=$((fail+1)); printf '  FAIL %s\n       must not contain: %s\n       actual: %s\n' "$1" "$2" "$3" ;;
         *) pass=$((pass+1)); printf '  ok   %s\n' "$1" ;; esac; }
t()    { printf '\n%s\n' "$1"; }

TAB=$(printf '\t')
ESC=$(printf '\033')
strip() { sed "s/${ESC}\[[0-9;]*m//g"; }

BIN="$ROOT/bin";     mkdir -p "$BIN"
STATE="$ROOT/state"; mkdir -p "$STATE"
REPO="$ROOT/repo";   mkdir -p "$REPO/.git"
ROWS="$ROOT/rows"
ENVOUT="$ROOT/tusage-env"

# THE DATE IS THE ONE INPUT THIS TEST CANNOT CHOOSE. Everything below is built
# against today rather than against a frozen day, because usage_line reads the
# clock directly and there is no seam to inject one through.
YM=$(date +%Y-%m)
TODAY=$(date +%F)
D=$(date +%d); D=$((10#$D))
DIM=$(date -v1d -v+1m -v-1d +%d 2>/dev/null); DIM=$((10#${DIM:-30}))
LEFT=$((DIM - D + 1))
# The working-day counts the allowance and the pace now use (Mon–Fri), computed
# with date so the test does not share the arithmetic it is checking.
WD_LEFT=0; WD_DONE=0
i=1; while [ "$i" -le "$DIM" ]; do
  k=$(date -v"${i}d" +%u 2>/dev/null || echo 1)
  if [ "$k" -le 5 ]; then [ "$i" -ge "$D" ] && WD_LEFT=$((WD_LEFT + 1)); [ "$i" -le "$D" ] && WD_DONE=$((WD_DONE + 1)); fi
  i=$((i + 1))
done
[ "$WD_LEFT" -gt 0 ] || WD_LEFT=$LEFT
[ "$WD_DONE" -gt 0 ] || WD_DONE=$D

# tusage. --daily prints whatever the current fixture wrote; --sessions is the
# one row list() needs to render something; every call records the account
# environment it was given.
cat >"$BIN/tusage" <<'EOF'
#!/bin/sh
printf 'ACCOUNTS=%s\nRULES=%s\nARGS=%s\n' "${TU_ACCOUNTS:-}" "${TU_ACCOUNT_RULES:-}" "$*" >>"$TU_ENVOUT"
# --until closes the window at an instant. The canned table is one row per day,
# so the stub cuts on the day that instant falls in — which is all the real one
# can do to a day row either.
UNTIL=""; prev=""
for a in "$@"; do
  [ "$prev" = --until ] && UNTIL=$a
  prev=$a
done
for a in "$@"; do
  if [ "$a" = --daily ]; then
    if [ -n "$UNTIL" ]; then
      u=$(date -r "$UNTIL" +%Y-%m-%d 2>/dev/null || date -d "@$UNTIL" +%Y-%m-%d)
      awk -F'\t' -v u="$u" '$1 <= u' "$TU_ROWS" 2>/dev/null
    else
      cat "$TU_ROWS" 2>/dev/null
    fi
    exit 0
  fi
  if [ "$a" = --sessions ]; then
    printf 'sid-p\t0\t1\t150000\t0\tslug\t0\t0\t0\tclaude-opus-5\t12.34\t3.5\t1.25\t0\n'
    exit 0
  fi
done
exit 0
EOF
chmod +x "$BIN/tusage"

calc() { awk "BEGIN { printf \"%.4f\", $1 }"; }

# Month-to-date lands exactly on the number asked for whatever day this runs:
# everything but a 40-dollar slice for today goes on the 1st, and on the 1st
# itself there is only the one day to put it on.
mkrows() {  # <work month-to-date>
  : >"$ROWS"
  if [ "$D" -gt 1 ]; then
    printf '%s-01\tpersonal\t%s\t3\t1\n' "$YM" "$(calc 7.5)"           >>"$ROWS"
    printf '%s-01\twork\t%s\t11\t0\n'    "$YM" "$(calc "$1 / 2")"      >>"$ROWS"
    printf '%s\twork\t%s\t9\t2\n'        "$TODAY" "$(calc "$1 / 2")"   >>"$ROWS"
  else
    printf '%s\tpersonal\t%s\t3\t1\n' "$TODAY" "$(calc 7.5)" >>"$ROWS"
    printf '%s\twork\t%s\t9\t2\n'     "$TODAY" "$(calc "$1")" >>"$ROWS"
  fi
}

# work has no config_dir, so it is the default account; personal has one. The
# rules are what TU_ACCOUNT_RULES is built from.
mkcfg() {  # <file> <usage block, or empty for none>
  cat >"$1" <<EOF
claude:
  profiles:
    personal:
      config_dir: $ROOT/claude-personal
    work:
  rules:
    - dir: $REPO
      profile: work
    - session: personal
      profile: personal
${2:-}
EOF
}

CFG="$ROOT/config.yaml"
mkcfg "$CFG" "usage:
  watch: work
  monthly_limit_usd: 850
  safety_margin_pct: 5"
CALCFG="$ROOT/config-calendar.yaml"
mkcfg "$CALCFG" "usage:
  watch: work
  monthly_limit_usd: 850
  safety_margin_pct: 5
  workdays: false"
NOWATCH="$ROOT/config-nowatch.yaml"
mkcfg "$NOWATCH" "usage:
  monthly_limit_usd: 850
  safety_margin_pct: 5"
NOBLOCK="$ROOT/config-noblock.yaml"
mkcfg "$NOBLOCK" ""

unset TMUX TMUX_PANE TA_MODE TA_FLAT TA_COLS TA_HIDE_COLS CLAUDE_CONFIG_DIR FZF_DEFAULT_OPTS
tm() { tmux -L "$S" "$@"; }
tm -f /dev/null new-session -d -s tatest-dash -x 200 -y 50 sh || exit 1
SOCK=$(tm display -p '#{socket_path}' 2>/dev/null)
[ -n "$SOCK" ] || { echo "usage.sh: no socket for $S"; exit 1; }
TMUXV="$SOCK,0,0"

run() {  # <config> <args...> — the environment every check needs, never exported
  local cfg=$1
  shift
  env TMUX="$TMUXV" PATH="$BIN:$PATH" TA_CONFIG="$cfg" TA_STATE_DIR="$STATE" \
      TA_COLS=140 TA_MARKS=0 TU_ROWS="$ROWS" TU_ENVOUT="$ENVOUT" \
      bash "$TA" "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
t "1. the status bar figure"
# ---------------------------------------------------------------------------
# Under budget AND under pace, which on the 2nd of the month is a small number:
# the dim case is the one with nothing wrong with it, so it has to satisfy both
# tests at once, and what "under pace" allows depends on how far in we are.
CALM=$(awk -v d="$WD_DONE" -v l="$WD_LEFT" 'BEGIN { printf "%d", int(807.5 * d / (d + l) * 0.5) }')
mkrows "$CALM"
C=$(run "$CFG" --counts)
has "the watched account's month is in the status bar" "w \$$CALM/850" "$C"
has "...with the day's allowance beside it"            "/d"            "$C"
has "...dim while the month is well inside the limit"  "#[fg=colour244]" "$C"

mkrows 722.5
has "70% of the limit turns it yellow" "#[fg=yellow]" "$(run "$CFG" --counts)"
mkrows 807.5
C=$(run "$CFG" --counts)
has "90% turns it red"        "#[fg=red]"    "$C"
has "...and rounds to dollars" "w \$808/850" "$C"

# PACE IS A SECOND REASON TO WARN, and the interesting one: 65% spent is not
# alarming as a total, and is alarming on the 3rd of the month. Late enough in
# the month no such fixture exists — with two days left, 35% of the limit IS
# more than a day's allowance — so the case is asserted only where it is real.
mkrows 552.5
if awk -v m=552.5 -v d="$WD_DONE" -v l="$WD_LEFT" 'BEGIN { exit !(m / d > (807.5 - m) / l) }'; then
  has "spending faster than the month allows warns too" "#[fg=yellow]" "$(run "$CFG" --counts)"
else
  printf '  --   too late in the month for a pace-only fixture, skipping\n'
fi

# WORKING DAYS, NOT CALENDAR DAYS. The footer says which it counted, and the
# allowance over fewer days is the larger number.
mkrows 400
F=$(run "$CFG" --ask-usage </dev/null | strip)
has "the footer counts working days by default" "/day left ($WD_LEFT""wd)" "$F"
F2=$(run "$CALCFG" --ask-usage </dev/null | strip)
has "...and calendar days when asked" "/day left ($LEFT""d)" "$F2"

# ---------------------------------------------------------------------------
t "2. no watched account, no feature"
# ---------------------------------------------------------------------------
mkrows 510
ok "a usage block naming nobody changes nothing" \
   "$(run "$NOBLOCK" --counts)" "$(run "$NOWATCH" --counts)"
hasnt "...and prints no figure at all" "/850" "$(run "$NOWATCH" --counts)"

# ---------------------------------------------------------------------------
t "3. the config leaves and the key"
# ---------------------------------------------------------------------------
CF=$(run "$CFG" --config)
has "--config shows the watched profile" "usage.watch${TAB}work"          "$CF"
has "...the limit"                       "usage.monthly_limit_usd${TAB}850" "$CF"
has "...and the margin"                  "usage.safety_margin_pct${TAB}5"   "$CF"
has "\$ has a row in the key table" "\$${TAB}:usage" "$(run "$CFG" --keys)"

# ---------------------------------------------------------------------------
t "4. the \$ table"
# ---------------------------------------------------------------------------
# Driven with a pipe, which is what a test has instead of the popup tty: less
# renders to a pipe the way cat does, so this is what the popup would show.
U=$(run "$CFG" --ask-usage </dev/null | strip)
has "the table names the month and the account" "usage · " "$U"
has "...and the account it is about"            "work"     "$U"
has "...today is a row"                         "$TODAY"   "$U"
has "...and the limit line closes it"           "of \$850" "$U"
hasnt "the account nobody is watching is absent" "personal" "$U"
if [ "$D" -gt 1 ]; then
  ok "the newest day is the first row" "$TODAY" \
     "$(printf '%s\n' "$U" | sed -n '3s/^  \([0-9-]*\) .*/\1/p')"
else
  printf '  --   the 1st of the month has one day, nothing to order\n'
fi

# ---------------------------------------------------------------------------
t "5. the accounts tusage is handed"
# ---------------------------------------------------------------------------
# tusage cannot work out which login a transcript belongs to — the accounts are
# tagents' config and the mapping is tagents' rules. Both travel as environment.
: >"$ENVOUT"
run "$CFG" --counts >/dev/null
E=$(cat "$ENVOUT")
has "the profiles reach tusage"        "ACCOUNTS=personal=$ROOT/claude-personal;work=" "$E"
has "...and so do the directory rules" "RULES=$REPO=work"                              "$E"

# The refresher is the one WRITER: its --update rebuilds the account map, and
# a rebuild under different labels than the readers use flips the map on every
# tick. Driven against a dead port it updates on its 5th tick and leaves after
# five refused posts — about ten seconds.
: >"$ENVOUT"
( TA_PORT=1 run "$CFG" --refresher >/dev/null 2>&1 & ); i=0
while [ "$i" -lt 60 ] && ! grep -q -- '--update' "$ENVOUT" 2>/dev/null; do sleep 0.25; i=$((i+1)); done
sleep 0.3
UPD=$(awk '/^ACCOUNTS=/{a=$0} /^ARGS=.*--update/{print a; exit}' "$ENVOUT")
ok "the refresher hands tusage --update the same accounts" "ACCOUNTS=personal=$ROOT/claude-personal;work=" "$UPD"

# ---------------------------------------------------------------------------
t "6. the meter calibrates the month"
# ---------------------------------------------------------------------------
# The reading is taken at the end of the 1st, so --until has a day to cut at and
# the estimate it is compared with is smaller than the month total.
MDAY1="$YM-01"
MLABEL="${MDAY1#*-} 23:59"
: >"$ROWS"
printf '%s\twork\t400.0000\t10\t0\n' "$MDAY1" >>"$ROWS"
MTOT=400
if [ "$D" -gt 1 ]; then printf '%s\twork\t200.0000\t10\t0\n' "$TODAY" >>"$ROWS"; MTOT=600; fi

mkmeter() {  # <when> <what the meter showed> -> the config path
  mkcfg "$ROOT/config-meter.yaml" "usage:
  watch: work
  monthly_limit_usd: 850
  safety_margin_pct: 5
  meter: \"$1 = $2\""
  printf '%s' "$ROOT/config-meter.yaml"
}

# 360 against the 400 the estimate had at that instant: a factor of 0.9.
SCALED=$(awk -v t="$MTOT" 'BEGIN { printf "%d", t * 0.9 + 0.5 }')
MCFG=$(mkmeter "$MDAY1 23:59" 360)
C=$(run "$MCFG" --counts)
has "the month is scaled to the meter"    "w ~\$$SCALED/850"   "$C"
F=$(run "$MCFG" --ask-usage </dev/null | strip)
has "...the footer names the reading"     "~meter $MLABEL"     "$F"
has "...and carries the scaled month"     "\$$SCALED of \$850" "$F"

# A reading from another month says nothing about this month's ratio.
OCFG=$(mkmeter "2000-01-02 10:00" 360)
C=$(run "$OCFG" --counts)
has   "a reading from another month is ignored" "w \$$MTOT/850" "$C"
hasnt "...and nothing wears a ~"                "~\$"           "$C"
has   "...the footer says why"  "meter reading unusable" \
      "$(run "$OCFG" --ask-usage </dev/null | strip)"

# 1200 against 400 is a mistyped figure or the other account's meter, not a 3x
# correction to apply to everything on screen.
XCFG=$(mkmeter "$MDAY1 23:59" 1200)
C=$(run "$XCFG" --counts)
has   "an implausible factor is ignored" "w \$$MTOT/850" "$C"
hasnt "...with no ~ either"              "~\$"           "$C"
has   "...and the footer says why"  "meter reading unusable" \
      "$(run "$XCFG" --ask-usage </dev/null | strip)"

# Nothing changes for a config with no reading in it at all.
hasnt "no meter, no note" "meter" "$(run "$CFG" --ask-usage </dev/null | strip)"

# ---------------------------------------------------------------------------
t "7. the meter tusage fetched sets the limit"
# ---------------------------------------------------------------------------
# tusage leaves each account's own reading in usage/meter.tsv under the state
# dir, with the day rows already scaled to it — so all the dashboard has to add
# is the limit the account reports and the ~ that says where the figure is from.
MTSV="$STATE/usage/meter.tsv"; mkdir -p "$STATE/usage"
MNOW=$(date +%s)
mkmrow() {  # <status> <fetched at>
  printf 'work\t830.16\t1000.00\t%s\t%s\t%s\n' "$2" "$1" "$((MNOW + 900))" >"$MTSV"
}

mkmrow ok "$MNOW"
C=$(run "$CFG" --counts)
has "the limit is the account's, not the config's" "w ~\$$MTOT/1000" "$C"
F=$(run "$CFG" --ask-usage </dev/null | strip)
has "...the footer names the time it was read" "~meter $(date -r "$MNOW" +%H:%M)" "$F"
has "...and carries the same limit"            "of \$1000"                        "$F"

# Three days on the month has moved without it, and the estimate on its own is
# the honest answer: the configured limit comes back and the ~ comes off.
mkmrow ok "$((MNOW - 259200))"
C=$(run "$CFG" --counts)
has   "a stale reading is not a reading" "w \$$MTOT/850" "$C"
hasnt "...and nothing wears a ~"         "~\$"           "$C"

# A row left by a fetch that failed carries the figures before it, which is
# worth reading in --meter and worth nothing on the status bar.
mkmrow error "$MNOW"
has "an error row is ignored too" "w \$$MTOT/850" "$(run "$CFG" --counts)"

# A reading typed into the config was put there on purpose, so it wins.
# (mkmeter writes one file, and section 6 left the implausible reading in it.)
MCFG=$(mkmeter "$MDAY1 23:59" 360)
mkmrow ok "$MNOW"
C=$(run "$MCFG" --counts)
has "the configured reading wins"  "w ~\$$SCALED/850" "$C"
has "...and the footer names it"   "~meter $MLABEL"   "$(run "$MCFG" --ask-usage </dev/null | strip)"
rm -f "$MTSV"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
