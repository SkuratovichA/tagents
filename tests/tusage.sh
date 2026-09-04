#!/usr/bin/env bash
#
# tests/tusage.sh — the money layer: per-day, per-account dollars.
#
# No tmux, no Claude, no transcripts: the index is hand-written into a mktemp
# dir and pointed at with $TU_STATE/$TU_PROJECTS, so nothing here reads or
# writes the real one. Everything runs with --no-update, which is also how the
# dashboard reads: a report must never need the updater to have run first.
#
# The expected dollar figures are computed by hand from the PRICES table in
# tusage and written out in the comments beside each fixture row — if a rate
# changes, the arithmetic here is the thing that has to change with it.
#
# bash 3.2, runnable from any cwd, non-zero exit when any check fails.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TU="$HERE/../tusage"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tusage-t.XXXXXX") || exit 1
trap 'rm -rf "$ROOT"' EXIT INT TERM

TAB=$(printf '\t')
pass=0; fail=0

ok() {  # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
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
#  fixture
# ---------------------------------------------------------------------------

# Local day of an epoch, whichever date(1) is installed.
dayof() { date -r "$1" +%Y-%m-%d 2>/dev/null || date -d "@$1" +%Y-%m-%d; }

NOW=$(date +%s)
T2=$(( NOW / 300 * 300 ))          # a bucket in this month, so --since month sees it
T1=$(( T2 - 172800 ))              # two days back: a different local day under any tz
D1=$(dayof "$T1"); D2=$(dayof "$T2")

export TU_STATE="$ROOT/usage" TU_PROJECTS="$ROOT/projects"
# The projects dir has to exist BEFORE projects.tsv is written, or slug_map's
# find -newer guard fires and regenerates the (empty) map over the fixture.
mkdir -p "$TU_PROJECTS" "$TU_STATE" "$ROOT/acct/work" "$ROOT/acct/personal"

# facts: 1 bucket 2 slug 3 sid 4 agentid 5 agenttype 6 kind 7 model
#        8 reqs 9 in 10 cw5 11 cw1h 12 cr 13 out 14 maxctx
#
# opus-5 is $5/MTok in, $25/MTok out; sonnet-5 is $3/$15 (its introductory pair
# expired at epoch 1788220799, before any fixture row). Cache multipliers are
# ratios of the input rate: 5m write 1.25x, 1h write 2x, read 0.1x.
{
  # A  day1 work     1M input on opus            -> 1e6*5/1e6            = 5.0000
  printf '%s\tw-slug\ts-work\t-\t-\t-\tclaude-opus-5\t2\t1000000\t0\t0\t0\t0\t1000000\n' "$T1"
  # B  day1 personal 1M 5m cache-write on sonnet -> 1.25*1e6*3/1e6       = 3.7500
  printf '%s\tp-slug\ts-pers\t-\t-\t-\tclaude-sonnet-5\t1\t0\t1000000\t0\t0\t0\t1000000\n' "$T1"
  # F  day1 personal 100k input on opus          -> 1e5*5/1e6            = 0.5000
  printf '%s\tw-slug\ts-dup\t-\t-\t-\tclaude-opus-5\t1\t100000\t0\t0\t0\t0\t100000\n' "$T1"
  # C  day2 work     1M output on opus           -> 1e6*25/1e6           = 25.0000
  printf '%s\tw-slug\ts-work\t-\t-\t-\tclaude-opus-5\t3\t0\t0\t0\t0\t1000000\t0\n' "$T2"
  # D  day2 work     200k in + 100k 1h + 1M read -> (2e5*5 + 2*1e5*5 + 0.1*1e6*5)/1e6 = 2.5000
  printf '%s\tj-slug\ts-rule\t-\t-\t-\tclaude-opus-5\t1\t200000\t0\t100000\t1000000\t0\t1300000\n' "$T2"
  # E  day2 work     an unrated model            -> 0.0000, unpriced 1
  printf '%s\tj-slug\ts-rule\t-\t-\t-\tclaude-gizmo-9\t1\t500000\t0\t0\t0\t500000\t500000\n' "$T2"
} >"$TU_STATE/facts.tsv"

{
  printf 's-work\tw-slug\t%s\t%s\tclaude-opus-5\n' "$T1" "$T2"
  printf 's-pers\tp-slug\t%s\t%s\tclaude-sonnet-5\n' "$T1" "$T1"
  printf 's-dup\tw-slug\t%s\t%s\tclaude-opus-5\n'  "$T1" "$T1"
  printf 's-rule\tj-slug\t%s\t%s\tclaude-opus-5\n' "$T2" "$T2"
  printf 's-near\tx-slug\t%s\t%s\tclaude-opus-5\n' "$T2" "$T2"
} >"$TU_STATE/sessions.tsv"

{
  printf 'w-slug\t%s\n' "$ROOT/git/work/other"
  printf 'p-slug\t%s\n' "$ROOT/git/personal/other"
  printf 'j-slug\t%s\n' "$ROOT/git/work/proj"
  printf 'x-slug\t%s\n' "$ROOT/git/workx/proj"
} >"$TU_STATE/projects.tsv"

hist() { printf '{"display":"x","pastedContents":{},"timestamp":%s,"project":"%s","sessionId":"%s"}\n' "$2" "$ROOT" "$1"; }
{ hist s-work 1000; hist s-dup 1000; } >"$ROOT/acct/work/history.jsonl"
{ hist s-pers 1000; hist s-dup 2000; } >"$ROOT/acct/personal/history.jsonl"

export TU_ACCOUNTS="work=$ROOT/acct/work;personal=$ROOT/acct/personal"
export TU_ACCOUNT_RULES="$ROOT/git/work=work;$ROOT/git/personal=personal"

tu() { bash "$TU" --no-update "$@" 2>&1; }

# ---------------------------------------------------------------------------
t "1. --daily: dollars per day per account"
# ---------------------------------------------------------------------------

want=$(printf '%s\tpersonal\t4.2500\t2\t0\n%s\twork\t5.0000\t2\t0\n%s\twork\t27.5000\t5\t1' \
       "$D1" "$D1" "$D2")
got=$(tu --daily --since 30d)
ok "day x account x dollars" "$want" "$got"

# B 3.75 + F 0.50; F is s-dup, which is only personal because the personal
# history touched it later than the work one.
contains "the duplicated sid lands on the newer history" "${D1}${TAB}personal${TAB}4.2500" "$got"
# C 25.00 + D 2.50 + E 0.00, and E is the row with no published rate.
contains "an unrated row adds no dollars but is counted" "${D2}${TAB}work${TAB}27.5000${TAB}5${TAB}1" "$got"

ok "no header, one row per day/account" 3 "$(printf '%s\n' "$got" | grep -c .)"

# ---------------------------------------------------------------------------
t "2. accounts.tsv"
# ---------------------------------------------------------------------------

acc=$(sort "$TU_STATE/accounts.tsv")
contains "history maps a work session"     "s-work${TAB}work"     "$acc"
contains "history maps a personal session" "s-pers${TAB}personal" "$acc"
contains "the newest history line wins"    "s-dup${TAB}personal"  "$acc"
ok "...and only once" 1 "$(printf '%s\n' "$acc" | grep -c "^s-dup${TAB}")"
contains "a session no history lists falls to the dir rule" "s-rule${TAB}work" "$acc"
# ~/git/workx is not inside ~/git/work, however much the prefix looks like it.
contains "the rule match is path-component aware" "s-near${TAB}?" "$acc"

ok "written temp-then-mv, nothing left behind" "" \
   "$(ls "$TU_STATE" | grep 'tmp' | tr '\n' ' ')"

# ---------------------------------------------------------------------------
t "3. --since month"
# ---------------------------------------------------------------------------

got=$(tu --daily --since month); rc=$?
ok "parses"                 0 "$rc"
contains "and covers today" "$D2" "$got"
# *m still means minutes: a one-minute window sees none of the fixture.
ok "1m is still one minute" "" "$(tu --daily --since 1m)"

# ---------------------------------------------------------------------------
t "4. --sessions is unchanged"
# ---------------------------------------------------------------------------

line=$(tu --sessions --since 30d | grep '^s-work')
ok "still 14 fields" 14 "$(printf '%s\n' "$line" | awk -F"$TAB" '{ print NF }')"
# A 5.00 + C 25.00, priced per row at each row's own model.
ok "still the same dollars" "30.000000" "$(printf '%s\n' "$line" | cut -f11)"

# ---------------------------------------------------------------------------
t "5. a changed spec is a stale map"
# ---------------------------------------------------------------------------

# Same histories, new names: the cached map must not answer with the old ones.
names=$(TU_ACCOUNTS="alpha=$ROOT/acct/work;beta=$ROOT/acct/personal" tu --daily --since 30d | cut -f2 | sort -u | tr '\n' ' ')
contains "alpha is there"          "alpha" "$names"
contains "beta is there"           "beta"  "$names"
ok "the old names are gone"        ""      "$(printf '%s' "$names" | grep -o -E 'work|personal' | head -1)"
# And back again, because the spec file — not a timestamp — decides.
names=$(tu --daily --since 30d | cut -f2 | sort -u | tr '\n' ' ')
contains "work is back"            "work"  "$names"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
