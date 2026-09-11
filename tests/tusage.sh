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
# Ten minutes back, not the bucket that holds now: a row in the current bucket
# lands inside a one-minute window when the clock is near the bucket edge, and
# the "1m is still one minute" check then sees it. Still this month for --since.
T2=$(( (NOW - 600) / 300 * 300 ))
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
names=$(TU_ACCOUNTS="alpha=$ROOT/acct/work;beta=$ROOT/acct/personal" TU_ACCOUNT_RULES="$ROOT/git/work=alpha;$ROOT/git/personal=beta" tu --daily --since 30d | cut -f2 | sort -u | tr '\n' ' ')
contains "alpha is there"          "alpha" "$names"
contains "beta is there"           "beta"  "$names"
ok "the old names are gone"        ""      "$(printf '%s' "$names" | grep -o -E 'work|personal' | head -1)"
# And back again, because the spec file — not a timestamp — decides.
names=$(tu --daily --since 30d | cut -f2 | sort -u | tr '\n' ' ')
contains "work is back"            "work"  "$names"

# ---------------------------------------------------------------------------
t "5b. --calibrate prices an account at what its meter said"
# ---------------------------------------------------------------------------
# The fixture's work month is 5.00 + 27.50 = 32.50 at list; a meter that said
# 16.25 means the account is billed at half of list.
out=$(tu --calibrate work 16.25 2>&1); rc=$?
ok "it succeeds"                     0 "$rc"
contains "...and says the factor"    "x0.5000" "$out"
ok "the factor is kept per account"  "work	0.5000" "$(cut -f1,2 "$ROOT/usage/factor.tsv")"
ok "--daily now reports the metered dollars" "16.2500" \
   "$(tu --daily --since 30d | awk -F"$TAB" '$2 == "work" { s += $3 } END { printf "%.4f", s }')"
ok "...the other account is untouched"       "4.2500" \
   "$(tu --daily --since 30d | awk -F"$TAB" '$2 == "personal" { s += $3 } END { printf "%.4f", s }')"
ok "TU_NO_FACTOR=1 gives list price back"    "32.5000" \
   "$(TU_NO_FACTOR=1 tu --daily --since 30d | awk -F"$TAB" '$2 == "work" { s += $3 } END { printf "%.4f", s }')"
# A reading taken before the newest rows only divides by what existed then: the
# 27.50 row sits at T2, so a reading one second earlier sees the 5.00 alone.
out=$(tu --calibrate work 2.5 --at "$((T2 - 1))" 2>&1)
contains "--at divides by the month as of then" "x0.5000" "$out"
out=$(tu --calibrate work 500 2>&1); rc=$?
ok "an absurd factor is refused"     1 "$rc"
contains "...and says why"            "not a price" "$out"
ok "...leaving the factor as it was" "0.5000" "$(awk -F"$TAB" '$1=="work"{print $2}' "$ROOT/usage/factor.tsv")"

# ---------------------------------------------------------------------------
t "6. a transcript that moves between project dirs is still one transcript"
# ---------------------------------------------------------------------------

# This section is last on purpose: it runs the real updater, and its --rebuild
# throws the hand-written index above away.

isoof() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }

SID=d1d1d1d1-2222-3333-4444-555555555555
# 100k input on opus-5 = $0.50 a record, so the arithmetic is readable.
rec() {  # <requestId> <epoch>
  printf '{"type":"assistant","requestId":"%s","timestamp":"%s","sessionId":"%s","message":{"model":"claude-opus-5","usage":{"input_tokens":100000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n' \
    "$1" "$(isoof "$2")" "$SID"
}
usd_of() {  # dollars --sessions attributes to $SID
  bash "$TU" --no-update --sessions --since 30d 2>/dev/null | awk -F"$TAB" -v s="$SID" '$1 == s { print $11 }'
}

A="$TU_PROJECTS/-wt-gone"; B="$TU_PROJECTS/-the-parent"
mkdir -p "$A/$SID/subagents"
{ rec q1 "$T2"; rec q2 $((T2 + 60)); rec q3 $((T2 + 120)); } >"$A/$SID.jsonl"
rec q4 $((T2 + 180)) >"$A/$SID/subagents/agent-x.jsonl"

bash "$TU" --update >/dev/null 2>&1
ok "three records plus one subagent record" "2.000000" "$(usd_of)"

# The worktree went away and Claude Code re-homed the whole session under the
# parent project; one more record arrived after the move.
mkdir -p "$B"
mv "$A/$SID.jsonl" "$A/$SID" "$B/"
rec q5 $((T2 + 240)) >>"$B/$SID.jsonl"
out=$(bash "$TU" --update 2>&1)

ok "the move costs one record, not a second copy of the session" "2.500000" "$(usd_of)"
off=$(cat "$TU_STATE/offsets.tsv")
contains "offsets follow the file to its new home" "$B/$SID.jsonl" "$off"
contains "...the subagent file too" "$B/$SID/subagents/agent-x.jsonl" "$off"
ok "and the old path is gone" 0 "$(printf '%s\n' "$off" | grep -c "^$A/")"
ok "one row per file, no more" 2 "$(printf '%s\n' "$off" | grep -c .)"
ok "the key is the 4th field" "$SID" \
   "$(printf '%s\n' "$off" | awk -F"$TAB" -v p="$B/$SID.jsonl" '$1 == p { print $4 }')"

# Mid-move — or a stray copy — both halves sit on disk at once.
cp "$B/$SID.jsonl" "$A/$SID.jsonl"
out=$(bash "$TU" --rebuild 2>&1)
contains "a rebuild says what it skipped" "duplicate transcript copies skipped" "$out"
ok "and counts the session once" "2.500000" "$(usd_of)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
