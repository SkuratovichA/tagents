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

# THE CLOCK. Section 5b and the meter sections divide a reading by the month to
# date, and the fixture keeps the work account's older row two days behind its
# newest, so both rows are in one month only from the 4th of it. This script and
# tusage therefore read a date(1) that starts no earlier than the 4th, and
# TU_TEST_NOW="YYYY-MM-DD HH:MM:SS" starts it at any other instant. Time keeps
# flowing from there, so ages and timeouts still elapse.
REAL_DATE=$(command -v date)
epoch_of() { date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s 2>/dev/null || date -d "$1" +%s; }
START=$(date +%s); REAL_START=$START
[ -z "${TU_TEST_NOW:-}" ] || START=$(epoch_of "$TU_TEST_NOW") || { echo "TU_TEST_NOW is not YYYY-MM-DD HH:MM:SS: $TU_TEST_NOW" >&2; exit 1; }
DOM=$(dayof "$START" | cut -c9-10)
[ "$((10#$DOM))" -ge 4 ] || START=$(( START + (4 - 10#$DOM) * 86400 ))
mkdir -p "$ROOT/clock"
cat >"$ROOT/clock/date" <<CLOCK
#!/bin/bash
for a in "\$@"; do case \$a in -j|-r|-d|-f|--date*) exec $REAL_DATE "\$@" ;; esac; done
e=\$(( \$($REAL_DATE +%s) + $(( START - REAL_START )) ))
$REAL_DATE -r "\$e" "\$@" 2>/dev/null || exec $REAL_DATE -d "@\$e" "\$@"
CLOCK
chmod +x "$ROOT/clock/date"
export PATH="$ROOT/clock:$PATH"
printf 'the clock starts at %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"

NOW=$(date +%s)
# Ten minutes back, not the bucket that holds now: a row in the current bucket
# lands inside a one-minute window when the clock is near the bucket edge, and
# the "1m is still one minute" check then sees it. Still this month for --since.
T2=$(( (NOW - 600) / 300 * 300 ))
T1=$(( T2 - 172800 ))              # two days back: a different local day under any tz
D1=$(dayof "$T1"); D2=$(dayof "$T2")

export TU_STATE="$ROOT/usage" TU_PROJECTS="$ROOT/projects"
# The names of sessions and the account names come from tagents' own state and
# config. Pointed at nothing, so no test reads the real ones whatever it runs.
export TA_STATE_DIR="$ROOT/ta-none" TA_CONFIG="$ROOT/no-such-config.toml"
# THE METER IS OFF EXCEPT WHERE IT IS THE SUBJECT. --update fetches it now, and
# a test suite must never ask the real keychain for a token or the real API for
# a figure. Section 5c turns it back on for its own calls, with fakes on PATH.
export TU_NO_METER=1
# The projects dir has to exist BEFORE projects.tsv is written, or slug_map's
# find -newer guard fires and regenerates the (empty) map over the fixture.
mkdir -p "$TU_PROJECTS" "$TU_STATE" "$ROOT/acct/work" "$ROOT/acct/personal"

# facts: 1 bucket 2 slug 3 sid 4 agentid 5 agenttype 6 kind 7 model
#        8 reqs 9 in 10 cw5 11 cw1h 12 cr 13 out 14 maxctx
#
# opus-5 is $5/MTok in, $25/MTok out; sonnet-5 is $2/$10. Write multipliers are
# ratios of the input rate: 5m write 1.25x, 1h write 2x. Reads are 0.1x the
# input rate for every model except fable/mythos 5.1, which state their own
# $0.25/MTok in the table — section 7 pins that, in its own fixture, because
# these rows are chosen to make the calibration factors come out round.
{
  # A  day1 work     1M input on opus            -> 1e6*5/1e6            = 5.0000
  printf '%s\tw-slug\ts-work\t-\t-\t-\tclaude-opus-5\t2\t1000000\t0\t0\t0\t0\t1000000\n' "$T1"
  # B  day1 personal 1M 5m cache-write on sonnet -> 1.25*1e6*2/1e6       = 2.5000
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

want=$(printf '%s\tpersonal\t3.0000\t2\t0\n%s\twork\t5.0000\t2\t0\n%s\twork\t27.5000\t5\t1' \
       "$D1" "$D1" "$D2")
got=$(tu --daily --since 30d)
ok "day x account x dollars" "$want" "$got"

# B 3.75 + F 0.50; F is s-dup, which is only personal because the personal
# history touched it later than the work one.
contains "the duplicated sid lands on the newer history" "${D1}${TAB}personal${TAB}3.0000" "$got"
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
t "4b. --sessions ctx is the context of the newest main-chain request"
# The dashboard's ctx column answers "how big is this chat now". The largest
# context of the last hour answered another question: after a /compact it kept
# the pre-compaction size for an hour, and a subagent's big context could show
# as the session's. Its own index, so the fixtures above stay as they are.
# ---------------------------------------------------------------------------

SAVE_STATE=$TU_STATE
export TU_STATE="$ROOT/ctx/usage"
mkdir -p "$TU_STATE"

# <sid> <bucket> <agentid> <model> <maxctx> [<lastctx>] — one facts row. Without
# the last argument the row has 14 fields, the format an index written before
# the newest-request column carries; with it, 15.
frow() {
  printf '%s\tx-slug\t%s\t%s\t-\t-\t%s\t1\t%s\t0\t0\t0\t0\t%s' "$2" "$1" "$3" "$4" "$5" "$5"
  [ $# -ge 6 ] && printf '\t%s' "$6"
  printf '\n'
}
ctx_of() {  # <sid> -> field 4 of --sessions
  bash "$TU" --no-update --sessions --since 30d 2>/dev/null | awk -F"$TAB" -v s="$1" '$1 == s { print $4 }'
}
OPUS=claude-opus-5
B0=$(( T2 - 1200 )); B1=$(( T2 - 600 ))

{
  # A compaction: the chat sat at 900k, then the next request landed in B1,
  # whose peak is still the 900k of the request before it but whose newest
  # request is only 80k.
  frow s-compact "$B0" - $OPUS 900000 900000
  frow s-compact "$B1" - $OPUS 900000 80000
  # A subagent with a bigger context than the main chain, in the newest bucket.
  frow s-sub "$B0" - $OPUS 120000 120000
  frow s-sub "$T2" ag1 $OPUS 700000 700000
  # A session that only ever ran subagents has no main-chain request to report.
  frow s-subonly "$T2" ag1 $OPUS 700000 700000
  # The zero-token placeholder is the newest row but is not a request that
  # carried any context, so it must not zero the column.
  frow s-synth "$T2" - $OPUS 60000 60000
  frow s-synth "$T2" - '<synthetic>' 0 0
  # An idle session still holds the context of its last request: a day-old chat
  # that was compacted is small, not "unknown" and not the peak it once had.
  frow s-idle "$(( T2 - 7200 - 600 ))" - $OPUS 500000 500000
  frow s-idle "$(( T2 - 7200 ))" - $OPUS 90000 40000
  # An index row from before the column existed: 14 fields, maxctx stands in for
  # the newest request's context. The newest main bucket decides, not the peak
  # of the session.
  frow s-old "$B0" - $OPUS 600000
  frow s-old "$B1" - $OPUS 200000
  # Both formats in one session: the 15-field row is the newer one.
  frow s-mixed "$B0" - $OPUS 800000
  frow s-mixed "$B1" - $OPUS 800000 70000
} >"$TU_STATE/facts.tsv"

ok "after a compaction the column shows the new size, not the peak" 80000 "$(ctx_of s-compact)"
ok "a subagent with a bigger context does not set it"               120000 "$(ctx_of s-sub)"
ok "a session of subagents only has no main-chain context"           0     "$(ctx_of s-subonly)"
ok "a zero-token placeholder does not zero it"                       60000 "$(ctx_of s-synth)"
ok "an idle session keeps its last context, not its peak"            40000 "$(ctx_of s-idle)"
ok "an index row in the old format falls back to its maxctx"         200000 "$(ctx_of s-old)"
ok "...a 15-field row after a 14-field one wins"                     70000 "$(ctx_of s-mixed)"
ok "--sessions still has 14 fields" 14 \
   "$(bash "$TU" --no-update --sessions --since 30d | awk -F"$TAB" 'NR == 1 { print NF }')"

export TU_STATE="$SAVE_STATE"

# ---------------------------------------------------------------------------
t "4c. what the report options leave alone: the bytes the dashboard reads"
# ---------------------------------------------------------------------------
# --sessions, --daily, --burn, --session <id> and --json are read by other
# programs (state.sh, usage.sh, list.sh, preview.sh, closed.sh), so their bytes
# are pinned against the fixture at the top of this file. A name typed in
# tagents and a cached title are present, and neither may reach these outputs
# or be rewritten by them. (No transcript is added: a new directory under
# $TU_PROJECTS would make slug_map regenerate the fixture's projects.tsv.)

export TA_STATE_DIR="$ROOT/ta12"
mkdir -p "$TA_STATE_DIR"
printf 's-work\tTyped Name\ns-work\tSecond Line\n' >"$TA_STATE_DIR/labels.tsv"
printf 's-pers\tCached Title\t100\n' >"$TA_STATE_DIR/title.tsv"
sum12() { cksum "$TA_STATE_DIR/labels.tsv" "$TA_STATE_DIR/title.tsv" | tr '\n' ' '; ls "$TA_STATE_DIR" | tr '\n' ' '; }
before12=$(sum12)

# Captured from the script before this change, with printf %q, so the escape
# sequences are the ones the popups render.
PIN_DETAIL_WORK=$'\E[1ms-work\E[0m  ?\n\E[90m  who                            cost        $    reqs   cwrite    cread      out\E[0m\n  · main                        6.0M    $30.0       5        0        0     1.0M\n\E[90m  TOTAL                          6.0M    $30.0\E[0m\nx'
PIN_DETAIL_RULE=$'\E[1ms-rule\E[0m  ?\n\E[90m  who                            cost        $    reqs   cwrite    cread      out\E[0m\n  · main                        3.5M    $2.50       2     100k     1.0M     500k\n\E[90m  TOTAL                          3.5M    $2.50\E[0m\n\n\E[90m  model                          cost        $\E[0m\n  claude-opus-5                  500k    $2.50\n  claude-gizmo-9                 3.0M       $0  \E[33m(no published rate)\E[0m\n\E[33m  1 request(s) ran on a model with no published rate �\200\224 $ is a floor\E[0m\nx'
PIN_DETAIL_NONE=$'\E[1mdeadbeef\E[0m  ?\n  (no usage recorded in the retained window)\nx'
PIN_BURN=\#\[fg=#665c54\]5h\ #\[fg=#928374\]\$27.5\ x
PIN_JSON=\,\{\"project\":\"j-slug\"\,\"session\":\"s-rule\"\,\"who\":\"main\"\,\"cost\":3500000\,\"requests\":2\}\,\{\"project\":\"p-slug\"\,\"session\":\"s-pers\"\,\"who\":\"main\"\,\"cost\":1250000\,\"requests\":1\}\,\{\"project\":\"w-slug\"\,\"session\":\"s-work\"\,\"who\":\"main\"\,\"cost\":6000000\,\"requests\":5\}\[\{\"project\":\"w-slug\"\,\"session\":\"s-dup\"\,\"who\":\"main\"\,\"cost\":100000\,\"requests\":1\}\]\}x

ok "--session <id>: heading, rows, total"      "$PIN_DETAIL_WORK" "$(tu --session s-work; echo x)"
ok "--session <id>: model table and the floor"  "$PIN_DETAIL_RULE" "$(tu --session s-rule; echo x)"
ok "--session <id>: an id with no usage"        "$PIN_DETAIL_NONE" "$(tu --session deadbeef; echo x)"
ok "--burn: one line, no newline"               "$PIN_BURN"        "$(tu --burn; echo x)"
ok "--json: the same objects"                   "$PIN_JSON"        "$(tu --json --since 30d | tr '}' '\n' | LC_ALL=C sort | tr '\n' '}'; echo x)"

sess12=$(tu --sessions --since 30d)
ok "--sessions: 14 fields on every row" "14" "$(printf '%s\n' "$sess12" | awk -F'\t' '{ print NF }' | sort -u)"
ok "--sessions: the first line of a session" \
   "s-work${TAB}6000000${TAB}5${TAB}1000000${TAB}${T2}${TAB}w-slug${TAB}0${TAB}0${TAB}5000000${TAB}claude-opus-5${TAB}30.000000${TAB}25.000000${TAB}0.000000${TAB}0" \
   "$(printf '%s\n' "$sess12" | grep '^s-work')"
case $sess12 in *"Typed Name"*|*"Cached Title"*) bad=1 ;; *) bad=0 ;; esac
ok "--sessions carries no name" 0 "$bad"
ok "--daily: five fields on every row" "5" "$(tu --daily --since 30d | awk -F'\t' '{ print NF }' | sort -u)"
ok "the pinned reports touched neither labels.tsv nor title.tsv" "$before12" "$(sum12)"
export TA_STATE_DIR="$ROOT/ta-none"

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
ok "the clock leaves both work rows in one month" "$(dayof "$T1" | cut -c1-7)" "$(dayof "$T2" | cut -c1-7)"
out=$(tu --calibrate work 16.25 2>&1); rc=$?
ok "it succeeds"                     0 "$rc"
contains "...and says the factor"    "x0.5000" "$out"
ok "the factor is kept per account"  "work	0.5000" "$(cut -f1,2 "$ROOT/usage/factor.tsv")"
ok "--daily now reports the metered dollars" "16.2500" \
   "$(tu --daily --since 30d | awk -F"$TAB" '$2 == "work" { s += $3 } END { printf "%.4f", s }')"
ok "...the other account is untouched"       "3.0000" \
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
t "5c. --meter reads the account's own spend"
# ---------------------------------------------------------------------------
# Nothing here touches the keychain or the network: `security` and `curl` are
# shell scripts on PATH, and every argv curl is handed is appended to a log the
# checks read back.
MBIN="$ROOT/mbin"; mkdir -p "$MBIN"
export CURL_LOG="$ROOT/curl.log"; : >"$CURL_LOG"
export MBODY="$ROOT/meter-body.json"

cat >"$MBIN/security" <<'EOF'
#!/bin/sh
printf '{"claudeAiOauth":{"accessToken":"t0k3n","expiresAt":1}}\n'
EOF
cat >"$MBIN/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$CURL_LOG"
out=""; prev=""
for a in "$@"; do
  [ "$prev" = -o ] && out=$a
  prev=$a
done
[ -n "$out" ] && cat "$MBODY" >"$out"
printf '%s' "${CURL_CODE:-200}"
EOF
chmod +x "$MBIN/security" "$MBIN/curl"

body() {  # <used, minor units> <limit, minor units> — what /api/oauth/usage answers
  printf '{"spend":{"used":{"amount_minor":%s,"exponent":2},"limit":{"amount_minor":%s,"exponent":2},"percent":83,"severity":"warning","enabled":true}}\n' \
    "$1" "$2" >"$MBODY"
}
TTL=900; CODE=200
meter() {  # tusage with the fakes in front of it and the meter switched on
  env PATH="$MBIN:$PATH" TU_NO_METER= TU_METER_TTL="$TTL" CURL_CODE="$CODE" \
      TU_METER_ITEMS="work=Test-credentials" \
      TU_ACCOUNTS="work=$ROOT/acct/work;personal=$ROOT/acct/personal" \
      bash "$TU" --no-update --meter "$@" 2>&1
}
curls() { grep -c . "$CURL_LOG"; }
mrow() { awk -F"$TAB" -v a="${2:-work}" -v n="$1" '$1 == a { print $n; exit }' "$ROOT/usage/meter.tsv"; }
fac() { awk -F"$TAB" '$1 == "work" { print $2 }' "$ROOT/usage/factor.tsv"; }

body 83016 100000
out=$(meter --force)
ok "the used figure is the minor units scaled by the exponent" "830.16" "$(mrow 2)"
ok "...and so is the limit"                                    "1000.00" "$(mrow 3)"
ok "...the row is good"                                        "ok"      "$(mrow 5)"
contains "--meter names the status"                            "ok"      "$out"
ok "one account, one fetch"                                    1         "$(curls)"
contains "the token travels as a header"  "Authorization: Bearer t0k3n" "$(cat "$CURL_LOG")"
ok "...and is written nowhere on disk"    0 "$(grep -rl t0k3n "$ROOT/usage" 2>/dev/null | grep -c .)"
# An account whose credentials this cannot name is not guessed at.
ok "a login with no known keychain item is left alone" "nometer" "$(mrow 5 personal)"
# 830.16 against the fixture month of 32.50 at list is not a price. The reading
# is still the reading; only the factor refuses to follow it.
contains "an impossible factor is refused out loud" "not a price" "$out"
ok "...leaving the factor as section 5b left it" "0.5000" "$(fac)"

n=$(curls); meter --refresh >/dev/null
ok "a second read inside the TTL asks nobody" "$n" "$(curls)"

# 26.00 against the same 32.50 is x0.8 — a factor a meter reading can produce.
body 2600 100000
TTL=0; meter --refresh >/dev/null; TTL=900
ok "a zero TTL fetches again"          "$((n + 1))" "$(curls)"
ok "...and the reading re-prices the account" "0.8000" "$(fac)"
ok "...the row follows it"                    "26.00"  "$(mrow 2)"

# A refused fetch keeps yesterday's figures rather than blanking the panel.
n=$(curls); CODE=500; out=$(meter --force); CODE=200
ok "a 500 is an error row"                 "error" "$(mrow 5)"
ok "...that keeps the reading before it"   "26.00" "$(mrow 2)"
ok "...with its limit"                     "1000.00" "$(mrow 3)"
contains "...and the output says so" "the last fetch failed" "$out"
ok "the failure still cost exactly one call" "$((n + 1))" "$(curls)"

# A plan seat answers the same endpoint with no spend object in it at all.
printf '{"account":{"uuid":"a1"}}\n' >"$MBODY"
out=$(meter --force)
ok "no spend object, no meter"       "nometer" "$(mrow 5)"
ok "...and the factor is untouched"  "0.8000"  "$(fac)"
contains "...the note says why"      "no spend meter" "$out"

n=$(curls)
env PATH="$MBIN:$PATH" TU_METER_ITEMS="work=Test-credentials" \
    TU_ACCOUNTS="work=$ROOT/acct/work" bash "$TU" --update >/dev/null 2>&1
ok "TU_NO_METER=1 --update asks nothing" "$n" "$(curls)"

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

# ---------------------------------------------------------------------------
t "7. a model that states its own cache-read rate is priced at it"
# Fable/Mythos 5.1 read at $0.25/MTok — 0.025x their $10 input, not the 0.1x
# every other model charges. Its own index, so the fixtures above stay round.
# In this shell, not a subshell: an ok() in a subshell increments a copy of the
# tally and the suite would then pass while this section failed.
SAVE_STATE=$TU_STATE; SAVE_PROJ=$TU_PROJECTS
SAVE_ACCT=$TU_ACCOUNTS; SAVE_RULES=$TU_ACCOUNT_RULES
export TU_STATE="$ROOT/cr/usage" TU_PROJECTS="$ROOT/cr/projects"
export TU_ACCOUNTS="work=$ROOT/cr/acct/work" TU_ACCOUNT_RULES=""
mkdir -p "$TU_STATE" "$TU_PROJECTS" "$ROOT/cr/acct/work"
hist s-cr 1000 >"$ROOT/cr/acct/work/history.jsonl"

cr_usd() { bash "$TU" --no-update --daily | awk -F"$TAB" '{ print $3 }'; }
cr_model() {  # <model id> — one row, 1M cache read and nothing else
  printf '%s\tc-slug\ts-cr\t-\t-\t-\t%s\t1\t0\t0\t0\t1000000\t0\t1000000\n' "$T2" "$1" >"$TU_STATE/facts.tsv"
  printf 's-cr\tc-slug\t%s\t%s\t%s\n' "$T2" "$T2" "$1" >"$TU_STATE/sessions.tsv"
  printf 'c-slug\t%s\n' "$ROOT/cr/git/work/cr" >"$TU_STATE/projects.tsv"
}

cr_model claude-fable-5-1
ok "fable 5.1 reads cost \$0.25/MTok, not 0.1x its input" "0.2500" "$(cr_usd)"
# A dated snapshot id must reach the same row through the longest-prefix match.
cr_model claude-fable-5-1-20260901
ok "...and a dated snapshot id matches the same rate"      "0.2500" "$(cr_usd)"
# fable 5 (no read rate of its own) and opus 5 keep the 0.1x default.
cr_model claude-fable-5
ok "...while fable 5 keeps the 0.1x default"               "1.0000" "$(cr_usd)"
cr_model claude-opus-5
ok "...and so does opus 5"                                 "0.5000" "$(cr_usd)"

# A factor is meter / what this index computed, so it is only valid for the
# price table it was derived against. Correcting a rate must not leave the old
# haircut sitting on top of the new prices.
cr_model claude-opus-5
ok "the fixture prices at list before calibration" "0.5000" "$(cr_usd)"
out=$(bash "$TU" --no-update --calibrate work 0.25 2>&1)
contains "...and calibrates against it" "x0.5000" "$out"
ok "...so --daily reports the metered dollars" "0.2500" "$(cr_usd)"

# Same index, a different table: the stored factor no longer applies, so the
# dollars must equal the unfactored dollars under the new table (1M read at
# 0.1 x $10 = $1.00), not the stale 0.5x of them.
ok "a factor derived against another price table is ignored" "1.0000" \
   "$(TU_PRICES='claude-opus-5 10 50' bash "$TU" --no-update --daily | awk -F"$TAB" '{ print $3 }')"
ok "...and the original table still gets its factor" "0.2500" "$(cr_usd)"

export TU_STATE="$SAVE_STATE" TU_PROJECTS="$SAVE_PROJ"
export TU_ACCOUNTS="$SAVE_ACCT" TU_ACCOUNT_RULES="$SAVE_RULES"

# ---------------------------------------------------------------------------
t "8. --update does nothing when no transcript was written"
# Its own state, on the real updater. The sleeps keep the steps in separate
# seconds where a step needs it; step 8b deliberately has none between its append and the update that must see it.
SAVE_STATE=$TU_STATE; SAVE_PROJ=$TU_PROJECTS
SAVE_ACCT=$TU_ACCOUNTS; SAVE_RULES=$TU_ACCOUNT_RULES
export TU_STATE="$ROOT/ed/usage" TU_PROJECTS="$ROOT/ed/projects"
export TU_ACCOUNTS="work=$ROOT/ed/acct/work" TU_ACCOUNT_RULES=""
mkdir -p "$TU_STATE" "$TU_PROJECTS/-ed" "$ROOT/ed/acct/work"

mt() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
sums() { cksum "$TU_STATE/offsets.tsv" "$TU_STATE/facts.tsv" "$TU_STATE/sessions.tsv" 2>&1; }
SID_SAVE=$SID
SID=e1e1e1e1-2222-3333-4444-555555555555
SID2=e2e2e2e2-2222-3333-4444-555555555555
rec q1 "$T2" >"$TU_PROJECTS/-ed/$SID.jsonl"
bash "$TU" --update >/dev/null 2>&1
sleep 2; bash "$TU" --update >/dev/null 2>&1
ok "the first pass counts the transcript" "0.500000" "$(usd_of)"

# 8a. nothing written: no rebuild, the index file untouched in bytes and mtime.
before="$(sums)|$(mt "$TU_STATE/offsets.tsv")|$(mt "$TU_STATE/facts.tsv")|$(mt "$TU_STATE/.stamp")"
sleep 1.1
out=$(bash "$TU" --update 2>&1); rc=$?
after="$(sums)|$(mt "$TU_STATE/offsets.tsv")|$(mt "$TU_STATE/facts.tsv")|$(mt "$TU_STATE/.stamp")"
ok "no change: same output and status as an update that found nothing" "|0" "$out|$rc"
ok "no change: index bytes, mtimes and the stamp untouched" "$before" "$after"

# 8b. one record appended and --update run at once, with no sleep between them (the stamp itself is about 1s old, from before 8a, so this is not the same second as the last update that wrote it).
rec q2 $((T2 + 60)) >>"$TU_PROJECTS/-ed/$SID.jsonl"
bash "$TU" --update >/dev/null 2>&1
ok "a transcript that grew by one record is counted, with no sleep" "1.000000" "$(usd_of)"

# 8c. a new transcript.
sleep 1.1
SID_E=$SID; SID=$SID2
rec q3 $((T2 + 120)) >"$TU_PROJECTS/-ed/$SID2.jsonl"
bash "$TU" --update >/dev/null 2>&1
ok "a new transcript is counted" "0.500000" "$(usd_of)"
SID=$SID_E

# 8d. no change again: the rows stay put, nothing is read twice.
bash "$TU" --update >/dev/null 2>&1; sleep 2; bash "$TU" --update >/dev/null 2>&1
ok "an update that finds nothing leaves the totals alone" "1.000000" "$(usd_of)"

# 8e. deletions: the directory changes, and nothing `-newer` on a file sees it.
# The rule: a directory not older than the stamp lets the update run.
sleep 1.1; s0=$(mt "$TU_STATE/.stamp")
rm "$TU_PROJECTS/-ed/$SID2.jsonl"
sleep 1.1
bash "$TU" --update >/dev/null 2>&1
ok "a deleted transcript lets the update run (stamp moved)" "moved" \
   "$([ "$(mt "$TU_STATE/.stamp")" != "$s0" ] && echo moved || echo stuck)"
ok "...and the surviving transcript is still counted once" "1.000000" "$(usd_of)"

# 8f. a transcript moved in with an OLD mtime (mv keeps it): only its directory
# changed, and the update still finds it.
SID_E=$SID; SID=e3e3e3e3-2222-3333-4444-555555555555
mkdir -p "$ROOT/ed/stage"
rec q4 $((T2 + 180)) >"$ROOT/ed/stage/$SID.jsonl"
touch -t 202001010000 "$ROOT/ed/stage/$SID.jsonl"
sleep 2; bash "$TU" --update >/dev/null 2>&1
mv "$ROOT/ed/stage/$SID.jsonl" "$TU_PROJECTS/-ed/"
bash "$TU" --update >/dev/null 2>&1
ok "a moved-in transcript with an old mtime is counted" "0.500000" "$(usd_of)"
SID=$SID_E

export TU_STATE="$SAVE_STATE" TU_PROJECTS="$SAVE_PROJ"
export TU_ACCOUNTS="$SAVE_ACCT" TU_ACCOUNT_RULES="$SAVE_RULES"
SID=$SID_SAVE

# ---------------------------------------------------------------------------
t "9. accounts whose names differ only in a Cyrillic letter are two accounts"
# ---------------------------------------------------------------------------
# macOS awk under a UTF-8 locale weighs every Cyrillic letter the same ("я" == "ю"), so an unpinned awk takes the two names for one: calibrating the second account wipes the first one's factor. tusage pins its awk to bytes.
CY="$ROOT/cy"
mkdir -p "$CY/state" "$CY/proj/-cy" "$CY/acct/ya" "$CY/acct/yu"
SID_CY=$SID
for who in ya yu; do
  SID=$who-0000-0000-0000-000000000000
  hist "$SID" 1000 >"$CY/acct/$who/history.jsonl"
  rec q1 "$T2" >"$CY/proj/-cy/$SID.jsonl"
done
cy() { TU_STATE="$CY/state" TU_PROJECTS="$CY/proj" TU_ACCOUNTS="aя=$CY/acct/ya;aю=$CY/acct/yu" TU_ACCOUNT_RULES="" \
  LC_ALL=en_US.UTF-8 bash "$TU" "$@" 2>&1; }
cy --update >/dev/null
cy --calibrate "aя" 0.25 >/dev/null
cy --calibrate "aю" 0.25 >/dev/null
ok "both accounts keep their own factor" 2 "$(cut -f1 "$CY/state/factor.tsv" 2>/dev/null | grep -c .)"
SID=$SID_CY

# ---------------------------------------------------------------------------
t "10. the updater records the newest request's context, and an old index survives it"
# Transcripts through the real updater: the newest request of a bucket is picked
# by timestamp, not by its place in the file, and a facts file written before
# the column existed keeps working without a --rebuild.
# ---------------------------------------------------------------------------
SAVE_STATE=$TU_STATE; SAVE_PROJ=$TU_PROJECTS
SAVE_ACCT=$TU_ACCOUNTS; SAVE_RULES=$TU_ACCOUNT_RULES
export TU_STATE="$ROOT/lc/usage" TU_PROJECTS="$ROOT/lc/projects"
export TU_ACCOUNTS="work=$ROOT/lc/acct/work" TU_ACCOUNT_RULES=""
mkdir -p "$TU_STATE" "$TU_PROJECTS/-lc-proj" "$ROOT/lc/acct/work"

S1=e1e1e1e1-2222-3333-4444-555555555555
S2=e2e2e2e2-2222-3333-4444-555555555555
lrec() {  # <sid> <requestId> <epoch> <input tokens> [<agentId>] [<model>]
  local who=""
  [ -n "${5:-}" ] && who=",\"agentId\":\"$5\""
  printf '{"type":"assistant","requestId":"%s","timestamp":"%s","sessionId":"%s"%s,"message":{"model":"%s","usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n' \
    "$2" "$(isoof "$3")" "$1" "$who" "${6:-claude-opus-5}" "$4"
}
lctx() {  # <sid> -> field 4 of --sessions
  bash "$TU" --no-update --sessions --since 30d 2>/dev/null | awk -F"$TAB" -v s="$1" '$1 == s { print $4 }'
}

# One bucket: 900k, a subagent at 700k, then the /compact answer at 60k, then
# the zero-token placeholder Claude Code writes after an interruption.
mkdir -p "$TU_PROJECTS/-lc-proj/$S1/subagents"
{ lrec $S1 m1 $((T2 + 10)) 900000
  lrec $S1 m2 $((T2 + 100)) 60000
  lrec $S1 m3 $((T2 + 200)) 0 "" "<synthetic>"; } >"$TU_PROJECTS/-lc-proj/$S1.jsonl"
lrec $S1 a1 $((T2 + 150)) 700000 ag1 >"$TU_PROJECTS/-lc-proj/$S1/subagents/agent-ag1.jsonl"
# The newer request written above the older one.
{ lrec $S2 n2 $((T2 + 100)) 50000
  lrec $S2 n1 $((T2 + 10)) 800000; } >"$TU_PROJECTS/-lc-proj/$S2.jsonl"

bash "$TU" --update >/dev/null 2>&1
ok "ctx is the newest main-chain request, not the bucket's peak or a subagent's" 60000 "$(lctx $S1)"
ok "...by timestamp, not by position in the file" 50000 "$(lctx $S2)"
ok "the main row carries both the peak and the newest" "15:900000:60000" \
   "$(awk -F"$TAB" -v s=$S1 '$3 == s && $4 == "-" && $7 == "claude-opus-5" { print NF ":" $14 ":" $15 }' "$TU_STATE/facts.tsv")"
ok "...and the placeholder's row, of the same bucket, the same newest" "15:60000" \
   "$(awk -F"$TAB" -v s=$S1 '$3 == s && $4 == "-" && $7 == "<synthetic>" { print NF ":" $15 }' "$TU_STATE/facts.tsv")"
ok "the subagent row keeps its own newest" "15:700000:700000" \
   "$(awk -F"$TAB" -v s=$S1 '$3 == s && $4 == "ag1" { print NF ":" $14 ":" $15 }' "$TU_STATE/facts.tsv")"

# The index as the previous version wrote it: 14 fields, offsets untouched.
cut -f1-14 "$TU_STATE/facts.tsv" >"$TU_STATE/facts.old" && mv -f "$TU_STATE/facts.old" "$TU_STATE/facts.tsv"
ok "the old index has 14 fields" 14 "$(awk -F"$TAB" '{ print NF }' "$TU_STATE/facts.tsv" | sort -u | tr '\n' ' ' | sed 's/ $//')"
ok "...and is still read, by maxctx" 900000 "$(lctx $S1)"

# The next request arrives: an incremental update, no --rebuild.
lrec $S1 m4 $((T2 + 300)) 40000 >>"$TU_PROJECTS/-lc-proj/$S1.jsonl"
bash "$TU" --update >/dev/null 2>&1
ok "an old index takes the next request without a rebuild" 40000 "$(lctx $S1)"
ok "...the new row has the new format, the old rows are left alone" "14 15" \
   "$(awk -F"$TAB" -v s=$S1 '$3 == s { print NF }' "$TU_STATE/facts.tsv" | sort -un | tr '\n' ' ' | sed 's/ $//')"

export TU_STATE="$SAVE_STATE" TU_PROJECTS="$SAVE_PROJ"
export TU_ACCOUNTS="$SAVE_ACCT" TU_ACCOUNT_RULES="$SAVE_RULES"

# ---------------------------------------------------------------------------
t "11. an empty week, a lock and who holds it, an interrupted update, a long one"
# On 27.10.2026 an index nobody had updated for seventeen days made `tusage`
# die in awk on a division by zero, and `tusage --by day` sit silent through a
# catch-up of two thousand transcripts until it was killed, which left its lock
# behind. Each of those, here, on its own index.
# ---------------------------------------------------------------------------
SAVE_STATE=$TU_STATE; SAVE_PROJ=$TU_PROJECTS
SAVE_ACCT=$TU_ACCOUNTS; SAVE_RULES=$TU_ACCOUNT_RULES
export TU_STATE="$ROOT/lk/usage" TU_PROJECTS="$ROOT/lk/projects"
export TU_ACCOUNTS="work=$ROOT/lk/acct/work" TU_ACCOUNT_RULES=""
mkdir -p "$TU_STATE" "$TU_PROJECTS/-lk" "$ROOT/lk/acct/work" "$ROOT/lk/tmp" "$ROOT/lk/bin"
held() { [ -e "$TU_STATE/.update.lock" ] && echo held || echo gone; }

# 11a. Nothing in the last seven days: the newest row is ten days old.
printf '%s\tk-slug\ts-old\t-\t-\t-\tclaude-opus-5\t1\t1000\t0\t0\t0\t0\t1000\n' $((NOW - 864000)) >"$TU_STATE/facts.tsv"
out=$(bash "$TU" --no-update 2>&1); rc=$?
ok "a summary of an empty week exits 0" 0 "$rc"
contains "...and says the week is empty" "nothing in the last 7 days" "$out"
ok "...with no awk error" 0 "$(printf '%s\n' "$out" | grep -c 'division')"

# 11b. A window of nothing but the zero-token placeholder: a total of 0.
printf '%s\tk-slug\ts-z\t-\t-\t-\t<synthetic>\t1\t0\t0\t0\t0\t0\t0\n' "$T2" >"$TU_STATE/facts.tsv"
out=$(bash "$TU" --no-update --by model 2>&1); rc=$?
ok "a window of zero-token requests is a table, not an awk error" 0 "$rc"
contains "...at a share of 0%" " 0.0%" "$out"
rm -f "$TU_STATE/facts.tsv" "$TU_STATE/sessions.tsv"

# 11c. Who holds the lock is decided by its pid, not by its age.
SID_LK=$SID; SID=f1f1f1f1-2222-3333-4444-555555555555
rec q1 "$T2" >"$TU_PROJECTS/-lk/$SID.jsonl"
sleep 0 & dead=$!; wait "$dead"
mkdir "$TU_STATE/.update.lock"; echo "$dead" >"$TU_STATE/.update.lock/pid"
bash "$TU" --update >/dev/null 2>&1
ok "a lock whose updater is gone is taken over at once" "0.500000" "$(usd_of)"
ok "...and is gone when that update ends" gone "$(held)"

rec q2 $((T2 + 60)) >>"$TU_PROJECTS/-lk/$SID.jsonl"
( exec -a tusage-holder sleep 30 ) & holder=$!
mkdir "$TU_STATE/.update.lock"; echo "$holder" >"$TU_STATE/.update.lock/pid"
touch -t 202001010000 "$TU_STATE/.update.lock"
bash "$TU" --update >/dev/null 2>&1
ok "a lock held by a running tusage is left alone, however old it is" "0.500000" "$(usd_of)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
bash "$TU" --update >/dev/null 2>&1
ok "...and taken over once that tusage is gone" "1.000000" "$(usd_of)"

rec q3 $((T2 + 120)) >>"$TU_PROJECTS/-lk/$SID.jsonl"
sleep 30 & other=$!
mkdir "$TU_STATE/.update.lock"; echo "$other" >"$TU_STATE/.update.lock/pid"
bash "$TU" --update >/dev/null 2>&1
ok "a pid that now belongs to another program does not hold the lock" "1.500000" "$(usd_of)"
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null

# A lock with no pid, as an older version took it, still goes by its age.
rec q4 $((T2 + 180)) >>"$TU_PROJECTS/-lk/$SID.jsonl"
mkdir "$TU_STATE/.update.lock"
bash "$TU" --update >/dev/null 2>&1
ok "a fresh lock with no pid is left alone" "1.500000" "$(usd_of)"
touch -t 202001010000 "$TU_STATE/.update.lock"
bash "$TU" --update >/dev/null 2>&1
ok "...an old one is taken over" "2.000000" "$(usd_of)"

# 11d. A TERM in the middle of the read, which a slow jq holds open. The kill is
# sent once the side stamp exists: it is touched after the traps are set.
REALJQ=$(command -v jq)
printf '#!/bin/sh\nsleep 2\nexec "%s" "$@"\n' "$REALJQ" >"$ROOT/lk/bin/jq"; chmod +x "$ROOT/lk/bin/jq"
rec q5 $((T2 + 240)) >>"$TU_PROJECTS/-lk/$SID.jsonl"
PATH="$ROOT/lk/bin:$PATH" TMPDIR="$ROOT/lk/tmp" bash "$TU" --update >/dev/null 2>&1 & upd=$!
i=0; while [ ! -e "$TU_STATE/.stamp.new" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
kill -TERM "$upd" 2>/dev/null; wait "$upd"; rc=$?
ok "a TERM ends the update with the signal's status" 143 "$rc"
ok "...takes the lock with it" gone "$(held)"
ok "...and its temp dir and side stamp" "0 0" \
   "$(ls "$ROOT/lk/tmp" | grep -c .) $([ -e "$TU_STATE/.stamp.new" ] && echo 1 || echo 0)"
ok "...and the index has none of the half-read update" "2.000000" "$(usd_of)"
bash "$TU" --update >/dev/null 2>&1
ok "the next update reads what the interrupted one did not" "2.500000" "$(usd_of)"

# 11e. A record still being written is read up to its last newline and no further.
rec q6 $((T2 + 300)) | tr -d '\n' >>"$TU_PROJECTS/-lk/$SID.jsonl"
bash "$TU" --update >/dev/null 2>&1
ok "a partial last line is not read" "2.500000" "$(usd_of)"
printf '\n' >>"$TU_PROJECTS/-lk/$SID.jsonl"
bash "$TU" --update >/dev/null 2>&1
ok "...and is counted once it is complete" "3.000000" "$(usd_of)"

# 11f. On a terminal, an update with enough to read says how far it got. The
# threshold is lowered to one transcript; to a pipe it stays silent (8a).
rec q7 $((T2 + 360)) >>"$TU_PROJECTS/-lk/$SID.jsonl"
out=$(TU_PROGRESS_MIN=1 script -q /dev/null bash "$TU" --update 2>&1 </dev/null)
contains "an update on a terminal says how far it got" "reading transcripts 1/1" "$out"
ok "...and still counts what it read" "3.500000" "$(usd_of)"
SID=$SID_LK

export TU_STATE="$SAVE_STATE" TU_PROJECTS="$SAVE_PROJ"
export TU_ACCOUNTS="$SAVE_ACCT" TU_ACCOUNT_RULES="$SAVE_RULES"


# ---------------------------------------------------------------------------
t "13. a fixture for the report options: twelve sessions in two accounts"
# ---------------------------------------------------------------------------
# Fixed dates and TZ=UTC, so a window given as dates reads the same on any day
# and in any zone. Sunday 2026-11-01 is the last day. Every figure expected
# below is computed from the PRICES table by hand: opus-5 is 5/25, sonnet-5 is
# 2/10, haiku-4-5 is 1/5; a 5m cache write is 1.25x and a read 0.1x the input
# rate. The figures of a row are input, output, cache write and cache read.

FX="$ROOT/fx"; FXH="$FX/home"
mkdir -p "$FX/usage" "$FX/projects" "$FX/ta" "$FX/acct/work" "$FX/acct/personal" "$FXH"
for s in billing webapp tagents site probe; do mkdir -p "$FX/projects/-h-$s"; done
ep() { date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s; }
fxsid() { printf '%s-6d4e-4b0a-9c75-1e2f8a7b5d90' "$1"; }

# day, project, session, model, requests, input, output, cache write, cache read
while read -r day proj sid8 model reqs in out cw cr; do
  ts=$(( $(ep "$day 12:00:00") / 300 * 300 ))
  printf '%s\t-h-%s\t%s\t-\t-\t-\tclaude-%s\t%s\t%s\t%s\t0\t%s\t%s\t100000\t100000\n' \
    "$ts" "$proj" "$(fxsid "$sid8")" "$model" "$reqs" "$in" "$cw" "$cr" "$out"
done >"$FX/usage/facts.tsv" <<'ROWS'
2026-10-06 billing 5a1d2c33 opus-5 150 330000 101000 2000000 24000000
2026-10-08 billing 5a1d2c33 opus-5 90 190000 60000 1100000 13000000
2026-10-14 webapp 6b2e3d44 sonnet-5 80 140000 50000 700000 8500000
2026-10-13 tagents 7c3f4e55 opus-5 130 280000 90000 1500000 18000000
2026-10-20 tagents 7c3f4e55 opus-5 160 350000 110000 1900000 22000000
2026-10-22 tagents 8d4a5f66 sonnet-5 40 70000 25000 300000 3500000
2026-10-27 site 0a6f7e92 sonnet-5 70 130000 49000 640000 7400000
2026-10-28 site 0a6f7e92 sonnet-5 33 60000 20000 280000 3300000
2026-10-28 webapp 91ab44ee sonnet-5 54 90000 31000 420000 5200000
2026-10-29 billing 3f9a1c20 opus-5 142 310000 96000 1900000 21400000
2026-10-29 billing 3f9a1c20 sonnet-5 38 120000 41000 410000 3100000
2026-10-30 webapp 91ab44ee opus-5 77 160000 58000 900000 11600000
2026-10-30 billing b72e90d4 sonnet-5 96 150000 52000 780000 9900000
2026-10-31 billing 3f9a1c20 opus-5 210 440000 150000 2600000 33000000
2026-10-31 webapp e5d1f0a7 haiku-4-5 22 40000 12000 150000 1100000
2026-10-31 tagents d8c3b615 opus-5 120 260000 88000 1400000 17200000
2026-11-01 billing 3f9a1c20 opus-5 88 200000 70000 1100000 14800000
2026-11-01 billing 3f9a1c20 sonnet-5 24 90000 30000 260000 2000000
2026-11-01 billing c04d7be1 opus-5 61 130000 44000 690000 8100000
2026-11-01 tagents d8c3b615 opus-5 95 210000 74000 1200000 15000000
2026-11-01 probe 7b2c5d33 haiku-4-5 18 30000 9000 90000 700000
ROWS

# sessions.tsv: sid, slug, first, last, model, taken from the facts rows
LC_ALL=C awk -F'\t' -v OFS='\t' '
  { if (!($3 in F) || $1 < F[$3]) F[$3] = $1
    if ($1 > L[$3]) L[$3] = $1
    S[$3] = $2; M[$3] = $7 }
  END { for (s in F) print s, S[s], F[s], L[s], M[s] }' "$FX/usage/facts.tsv" >"$FX/usage/sessions.tsv"

for s in billing:work/billing-api webapp:work/web-app tagents:personal/tagents site:personal/site probe:../scratch/probe; do
  printf -- '-h-%s\t%s/git/%s\n' "${s%%:*}" "$FXH" "${s#*:}"
done >"$FX/usage/projects.tsv"
sed -i.bak "s#git/\.\./scratch#scratch#" "$FX/usage/projects.tsv"; rm -f "$FX/usage/projects.tsv.bak"

fxhist() { printf '{"display":"x","pastedContents":{},"timestamp":1000,"project":"%s","sessionId":"%s"}\n' "$FXH" "$(fxsid "$2")" >>"$FX/acct/$1/history.jsonl"; }
for s in 3f9a1c20 b72e90d4 c04d7be1 91ab44ee e5d1f0a7 5a1d2c33 6b2e3d44; do fxhist work $s; done
for s in d8c3b615 0a6f7e92 7c3f4e55 8d4a5f66; do fxhist personal $s; done

# One call of tusage on the fixture, with nothing of the real machine in reach.
# The width is wide and colour is off unless a test says otherwise. FX_STATE
# names another index and FX_PRICES another price table; FX_TA the tagents state
# directory (names), FX_CONFIG the tagents config, FX_HOME the home, FX_ACCOUNTS
# the TU_ACCOUNTS (empty is unset), FX_RULES the TU_ACCOUNT_RULES, FX_TU the
# script to run and FX_SH the shell that runs it, FX_COLUMNS the COLUMNS (empty
# is none), FX_NO_COLOR the NO_COLOR (empty is set but empty) and FX_PTY, when
# set, runs it under a pseudo-terminal.
pty() {  # <command...>: standard output is a terminal, standard input is empty
  { if [ "$PTY" = bsd ]; then script -q /dev/null "$@" </dev/null
    else script -qc "$(printf '%q ' "$@")" /dev/null </dev/null; fi; } 2>/dev/null |
    LC_ALL=C tr -d '\r' | LC_ALL=C sed $'1s/^\\^D\010\010//'
}
PTY=""
if [ "$(script -q /dev/null bash -c 'test -t 1 && echo yes' </dev/null 2>/dev/null | tr -d '\r' | grep -c yes)" = 1 ]; then PTY=bsd
elif [ "$(script -qc "bash -c 'test -t 1 && echo yes'" /dev/null </dev/null 2>/dev/null | tr -d '\r' | grep -c yes)" = 1 ]; then PTY=gnu
fi
fx_raw() {
  (
    unset TU_PRICES TU_ACCOUNT_RULES NO_COLOR TU_KEEP_DAYS TU_ACCOUNTS
    [ -z "${FX_NO_COLOR+x}" ] || export NO_COLOR="$FX_NO_COLOR"
    [ -z "${FX_PRICES:-}" ] || export TU_PRICES="$FX_PRICES"
    [ -z "${FX_RULES:-}" ] || export TU_ACCOUNT_RULES="$FX_RULES"
    export TU_ACCOUNTS="${FX_ACCOUNTS-work=$FX/acct/work;personal=$FX/acct/personal}"
    export HOME="${FX_HOME:-$FXH}" TZ=UTC TERM="${FX_TERM:-xterm}" COLUMNS="${FX_COLUMNS-140}" \
      TU_STATE="${FX_STATE:-$FX/usage}" TU_PROJECTS="$FX/projects" TU_NO_METER=1 \
      TA_STATE_DIR="${FX_TA:-$FX/ta}" TA_CONFIG="${FX_CONFIG:-$FX/no-such-config.toml}"
    if [ -n "${FX_PTY:-}" ]; then pty ${FX_SH:-bash} "${FX_TU:-$TU}" --no-update "$@"
    else ${FX_SH:-bash} "${FX_TU:-$TU}" --no-update "$@"; fi
  )
}
fx() { fx_raw "$@" 2>&1; }
fxo() { fx_raw "$@" 2>/dev/null; }
fxe() { fx_raw "$@" 2>&1 >/dev/null; }
fxrc() { fx "$@" >/dev/null; echo $?; }
W="--since 2026-10-26 --until 2026-11-01"

ok "the fixture indexes twelve sessions" 12 "$(cut -f1 "$FX/usage/sessions.tsv" | sort -u | wc -l | tr -d ' ')"
ok "the fixture prices a day by hand: 2026-10-29 is 28.82 dollars in work" "2026-10-29${TAB}work${TAB}28.8200${TAB}180${TAB}0" \
   "$(fx --daily --since 1000d | grep '^2026-10-29')"

# ---------------------------------------------------------------------------
t "14. the command line: values that are not understood stop the run"
# ---------------------------------------------------------------------------

dims="account, project, session, day, week, month, hour, agent, model, workflow"
out=$(fx --by colour); rc=$?
ok "an unknown dimension exits 2" 2 "$rc"
contains "...and is named" "tusage: unknown dimension colour" "$out"
contains "...with the valid ones listed" "$dims" "$out"
out=$(fx --by day,day); rc=$?
ok "a repeated dimension exits 2" 2 "$rc"
contains "...and is named" "tusage: dimension day given twice" "$out"
out=$(fx --by account,project,session,model); rc=$?
ok "a fourth dimension exits 2" 2 "$rc"
contains "...and the message says three is the most" "at most three" "$out"
ok "--by with an empty list exits 2"  2 "$(fxrc --by '')"
ok "--by with an empty element exits 2" 2 "$(fxrc --by day,)"
ok "--top that is not a number exits 2" 2 "$(fxrc --by day --top many)"
ok "--top that is negative exits 2"     2 "$(fxrc --by day --top -1)"
out=$(fx --by day --sort size); rc=$?
ok "--sort other than cost exits 2" 2 "$rc"
contains "...and names the value that is accepted" "cost" "$out"
out=$(fx --by day --color purple); rc=$?
ok "--color other than auto, always, never exits 2" 2 "$rc"
contains "...and names the values" "always" "$out"
ok "--top 0 is accepted"  0 "$(fxrc --by day --top 0 $W)"
ok "--color never is accepted" 0 "$(fxrc --by day --color never $W)"
out=$(fx --by day --account nobody); rc=$?
ok "an unknown account exits 2" 2 "$rc"
contains "...and is named" "tusage: unknown account nobody" "$out"
contains "...with the known names listed" "work" "$out"
contains "...all of them" "personal" "$out"
ok "--account ? is accepted" 0 "$(fxrc --by day --account '?' $W)"
ok "--account with a comma list is accepted" 0 "$(fxrc --by day --account work,personal $W)"
ok "an unknown option still exits 2" 2 "$(fxrc --by day --nonsense)"
# These used to loop for ever: `shift 2` fails with one word left, so the
# same option was read again, and again.
for o in --by --since --until --account --project --top --sort --color --session; do
  out=$(fx "$o"); rc=$?
  ok "$o with no value exits 2" 2 "$rc"
  contains "...and says it needs one" "tusage: $o needs a value" "$out"
done

# ---------------------------------------------------------------------------
t "15. dates in the window"
# ---------------------------------------------------------------------------

want=$(printf '2026-10-28\tpersonal\t1.6800\t33\t0\n2026-10-28\twork\t2.5800\t54\t0\n2026-10-29\twork\t28.8200\t180\t0')
ok "--daily with two dates: both days, whole" "$want" "$(fx --daily --since 2026-10-28 --until 2026-10-29)"
ok "--until is the end of its day, not its start" "$(printf '2026-10-28\tpersonal\t1.6800\t33\t0\n2026-10-28\twork\t2.5800\t54\t0')" \
   "$(fx --daily --since 2026-10-28 --until 2026-10-28)"
ok "an all-digit --until is still an epoch" "$(printf '2026-10-28\tpersonal\t1.6800\t33\t0\n2026-10-28\twork\t2.5800\t54\t0')" \
   "$(fx --daily --since 2026-10-28 --until "$(ep '2026-10-28 23:59:59')")"
ok "--since is local midnight: a row at noon of that day is in" "1" \
   "$(fx --daily --since 2026-11-01 --until 2026-11-01 | grep -c 'personal')"
out=$(fx --sessions --since 2026-10-29 --until 2026-10-29)
ok "--sessions takes dates: one session that day" 1 "$(printf '%s\n' "$out" | grep -c .)"
contains "...the session of that day" "$(fxsid 3f9a1c20)" "$out"
out=$(fx --json --since 2026-10-30 --until 2026-10-30)
contains "--json takes dates: the two sessions of that day" "$(fxsid 91ab44ee)" "$out"
contains "...both" "$(fxsid b72e90d4)" "$out"
case $out in *"$(fxsid 3f9a1c20)"*) bad=1 ;; *) bad=0 ;; esac
ok "...and no other" 0 "$bad"
out=$(fx --daily --since 2026-02-30); rc=$?
ok "a date that does not exist exits 2" 2 "$rc"
contains "...and the message names the value" "tusage: bad --since value 2026-02-30" "$out"
out=$(fx --by day --since 2026-13-01); rc=$?
ok "a month that does not exist exits 2" 2 "$rc"
contains "...named" "tusage: bad --since value 2026-13-01" "$out"
out=$(fx --daily --until 2026-10-32); rc=$?
ok "--until likewise exits 2" 2 "$rc"
contains "...and says --until" "tusage: bad --until value 2026-10-32" "$out"
out=$(fx --daily --since yesterday); rc=$?
ok "a word that is not a duration exits 2" 2 "$rc"
contains "...named" "tusage: bad --since value yesterday" "$out"
ok "--since 5h, 3d, 30m and month still parse" "0 0 0 0" \
   "$(fxrc --daily --since 5h) $(fxrc --daily --since 3d) $(fxrc --daily --since 30m) $(fxrc --daily --since month)"



# ---------------------------------------------------------------------------
t "16. the breakdown: exact figures, read through --tsv"
# ---------------------------------------------------------------------------
# The expected rows below come from a second program, written apart from the
# awk of tusage, that prices the same twenty-one rows from the PRICES table.
# A row is the keys of its dimensions, then requests, input, output, cache
# write, cache read, dollars to six decimals, unpriced requests, the first and
# the last day and the number of days.

X_ACCT=$(cat <<'EOT'
work	812	1730000	584000	9210000	110200000	117.590000	0	2026-10-28	2026-11-01	5
personal	318	660000	231000	3520000	42900000	44.260000	0	2026-10-27	2026-11-01	4
?	18	30000	9000	90000	700000	0.257500	0	2026-11-01	2026-11-01	1
EOT
)

X_ACCT_PROJ=$(cat <<'EOT'
work	~/git/work/billing-api	659	1440000	483000	7740000	92300000	100.937500	0	2026-10-29	2026-11-01	4
work	~/git/work/web-app	153	290000	101000	1470000	17900000	16.652500	0	2026-10-28	2026-10-31	3
personal	~/git/personal/tagents	215	470000	162000	2600000	32200000	38.750000	0	2026-10-31	2026-11-01	2
personal	~/git/personal/site	103	190000	69000	920000	10700000	5.510000	0	2026-10-27	2026-10-28	2
?	~/scratch/probe	18	30000	9000	90000	700000	0.257500	0	2026-11-01	2026-11-01	1
EOT
)

X_ACCT_PROJ_SESS=$(cat <<'EOT'
work	~/git/work/billing-api	3f9a1c20-6d4e-4b0a-9c75-1e2f8a7b5d90	502	1160000	387000	6270000	74300000	86.075000	0	2026-10-29	2026-11-01	3
work	~/git/work/billing-api	c04d7be1-6d4e-4b0a-9c75-1e2f8a7b5d90	61	130000	44000	690000	8100000	10.112500	0	2026-11-01	2026-11-01	1
work	~/git/work/billing-api	b72e90d4-6d4e-4b0a-9c75-1e2f8a7b5d90	96	150000	52000	780000	9900000	4.750000	0	2026-10-30	2026-10-30	1
work	~/git/work/web-app	91ab44ee-6d4e-4b0a-9c75-1e2f8a7b5d90	131	250000	89000	1320000	16800000	16.255000	0	2026-10-28	2026-10-30	2
work	~/git/work/web-app	e5d1f0a7-6d4e-4b0a-9c75-1e2f8a7b5d90	22	40000	12000	150000	1100000	0.397500	0	2026-10-31	2026-10-31	1
personal	~/git/personal/tagents	d8c3b615-6d4e-4b0a-9c75-1e2f8a7b5d90	215	470000	162000	2600000	32200000	38.750000	0	2026-10-31	2026-11-01	2
personal	~/git/personal/site	0a6f7e92-6d4e-4b0a-9c75-1e2f8a7b5d90	103	190000	69000	920000	10700000	5.510000	0	2026-10-27	2026-10-28	2
?	~/scratch/probe	7b2c5d33-6d4e-4b0a-9c75-1e2f8a7b5d90	18	30000	9000	90000	700000	0.257500	0	2026-11-01	2026-11-01	1
EOT
)

X_SESS=$(cat <<'EOT'
3f9a1c20-6d4e-4b0a-9c75-1e2f8a7b5d90	502	1160000	387000	6270000	74300000	86.075000	0	2026-10-29	2026-11-01	3
d8c3b615-6d4e-4b0a-9c75-1e2f8a7b5d90	215	470000	162000	2600000	32200000	38.750000	0	2026-10-31	2026-11-01	2
91ab44ee-6d4e-4b0a-9c75-1e2f8a7b5d90	131	250000	89000	1320000	16800000	16.255000	0	2026-10-28	2026-10-30	2
c04d7be1-6d4e-4b0a-9c75-1e2f8a7b5d90	61	130000	44000	690000	8100000	10.112500	0	2026-11-01	2026-11-01	1
0a6f7e92-6d4e-4b0a-9c75-1e2f8a7b5d90	103	190000	69000	920000	10700000	5.510000	0	2026-10-27	2026-10-28	2
b72e90d4-6d4e-4b0a-9c75-1e2f8a7b5d90	96	150000	52000	780000	9900000	4.750000	0	2026-10-30	2026-10-30	1
e5d1f0a7-6d4e-4b0a-9c75-1e2f8a7b5d90	22	40000	12000	150000	1100000	0.397500	0	2026-10-31	2026-10-31	1
7b2c5d33-6d4e-4b0a-9c75-1e2f8a7b5d90	18	30000	9000	90000	700000	0.257500	0	2026-11-01	2026-11-01	1
EOT
)

X_DAY=$(cat <<'EOT'
2026-10-27	70	130000	49000	640000	7400000	3.830000	0	2026-10-27	2026-10-27	1
2026-10-28	87	150000	51000	700000	8500000	4.260000	0	2026-10-28	2026-10-28	1
2026-10-29	180	430000	137000	2310000	24500000	28.820000	0	2026-10-29	2026-10-29	1
2026-10-30	173	310000	110000	1680000	21500000	18.425000	0	2026-10-30	2026-10-30	1
2026-10-31	352	740000	250000	4150000	51300000	59.947500	0	2026-10-31	2026-10-31	1
2026-11-01	286	660000	227000	3340000	40600000	46.825000	0	2026-11-01	2026-11-01	1
EOT
)

X_WEEK=$(cat <<'EOT'
2026-10-05	240	520000	161000	3100000	37000000	44.500000	0	2026-10-06	2026-10-08	2
2026-10-12	210	420000	140000	2200000	26500000	26.255000	0	2026-10-13	2026-10-14	2
2026-10-19	200	420000	135000	2200000	25500000	29.215000	0	2026-10-20	2026-10-22	2
2026-10-26	1148	2420000	824000	12820000	153800000	162.107500	0	2026-10-27	2026-11-01	6
EOT
)

X_MONTH=$(cat <<'EOT'
2026-10	1512	3120000	1033000	16980000	202200000	215.252500	0	2026-10-06	2026-10-31	11
2026-11	286	660000	227000	3340000	40600000	46.825000	0	2026-11-01	2026-11-01	1
EOT
)

X_MODEL=$(cat <<'EOT'
claude-opus-5	793	1710000	580000	9790000	121100000	144.787500	0	2026-10-29	2026-11-01	4
claude-sonnet-5	315	640000	223000	2790000	30900000	16.665000	0	2026-10-27	2026-11-01	5
claude-haiku-4-5	40	70000	21000	240000	1800000	0.655000	0	2026-10-31	2026-11-01	2
EOT
)

X_PROJ_BREAK=$(cat <<'EOT'
~/git/work/billing-api	claude-opus-5	501	1080000	360000	6290000	77300000	92.362500	0	2026-10-29	2026-11-01	3
~/git/work/billing-api	claude-sonnet-5	158	360000	123000	1450000	15000000	8.575000	0	2026-10-29	2026-11-01	3
~/git/personal/tagents	claude-opus-5	215	470000	162000	2600000	32200000	38.750000	0	2026-10-31	2026-11-01	2
~/git/work/web-app	claude-opus-5	77	160000	58000	900000	11600000	13.675000	0	2026-10-30	2026-10-30	1
~/git/work/web-app	claude-sonnet-5	54	90000	31000	420000	5200000	2.580000	0	2026-10-28	2026-10-28	1
~/git/work/web-app	claude-haiku-4-5	22	40000	12000	150000	1100000	0.397500	0	2026-10-31	2026-10-31	1
~/git/personal/site	claude-sonnet-5	103	190000	69000	920000	10700000	5.510000	0	2026-10-27	2026-10-28	2
~/scratch/probe	claude-haiku-4-5	18	30000	9000	90000	700000	0.257500	0	2026-11-01	2026-11-01	1
EOT
)

X_ALL_WEEK=$(cat <<'EOT'
2026-10-05	240	520000	161000	3100000	37000000	44.500000	0	2026-10-06	2026-10-08	2
2026-10-12	210	420000	140000	2200000	26500000	26.255000	0	2026-10-13	2026-10-14	2
2026-10-19	200	420000	135000	2200000	25500000	29.215000	0	2026-10-20	2026-10-22	2
2026-10-26	1148	2420000	824000	12820000	153800000	162.107500	0	2026-10-27	2026-11-01	6
EOT
)

X_ALL_MONTH=$(cat <<'EOT'
2026-10	1512	3120000	1033000	16980000	202200000	215.252500	0	2026-10-06	2026-10-31	11
2026-11	286	660000	227000	3340000	40600000	46.825000	0	2026-11-01	2026-11-01	1
EOT
)

T_ACCT_PROJ=$(cat <<'EOT'
usage  2026-10-26 .. 2026-11-01  by account > project

                           reqs   input  output  cwrite   cread   total         $   share  days  span          models
work                        812    1.7M    584k    9.2M  110.2M  121.7M      $118   72.5%     5  10-28..11-01  opus-5,sonnet-5 +1
  ~/git/work/billing-api    659    1.4M    483k    7.7M   92.3M  102.0M      $101   62.3%     4  10-29..11-01  opus-5,sonnet-5
  ~/git/work/web-app        153    290k    101k    1.5M   17.9M   19.8M     $16.7   10.3%     3  10-28..10-31  opus-5,sonnet-5 +1
personal                    318    660k    231k    3.5M   42.9M   47.3M     $44.3   27.3%     4  10-27..11-01  opus-5,sonnet-5
  ~/git/personal/tagents    215    470k    162k    2.6M   32.2M   35.4M     $38.8   23.9%     2  10-31..11-01  opus-5
  ~/git/personal/site       103    190k     69k    920k   10.7M   11.9M     $5.51    3.4%     2  10-27..10-28  sonnet-5
? unplaced                   18     30k      9k     90k    700k    829k     $0.26    0.2%     1  11-01         haiku-4-5
  ~/scratch/probe            18     30k      9k     90k    700k    829k     $0.26    0.2%     1  11-01         haiku-4-5
total                      1148    2.4M    824k   12.8M  153.8M  169.9M      $162  100.0%     6  10-27..11-01  opus-5,sonnet-5 +1
EOT
)

T_WEEK_ACCT=$(cat <<'EOT'
usage  2026-10-05 .. 2026-11-01  by week > account

                reqs   input  output  cwrite   cread   total         $   share  models
wk 2026-10-05    240    520k    161k    3.1M   37.0M   40.8M     $44.5   17.0%  opus-5
  work           240    520k    161k    3.1M   37.0M   40.8M     $44.5   17.0%  opus-5
wk 2026-10-12    210    420k    140k    2.2M   26.5M   29.3M     $26.3   10.0%  opus-5,sonnet-5
  personal       130    280k     90k    1.5M   18.0M   19.9M     $22.0    8.4%  opus-5
  work            80    140k     50k    700k    8.5M    9.4M     $4.23    1.6%  sonnet-5
wk 2026-10-19    200    420k    135k    2.2M   25.5M   28.3M     $29.2   11.1%  opus-5,sonnet-5
  personal       200    420k    135k    2.2M   25.5M   28.3M     $29.2   11.1%  opus-5,sonnet-5
wk 2026-10-26   1148    2.4M    824k   12.8M  153.8M  169.9M      $162   61.9%  opus-5,sonnet-5 +1
  work           812    1.7M    584k    9.2M  110.2M  121.7M      $118   44.9%  opus-5,sonnet-5 +1
  personal       318    660k    231k    3.5M   42.9M   47.3M     $44.3   16.9%  opus-5,sonnet-5
  ? unplaced      18     30k      9k     90k    700k    829k     $0.26    0.1%  haiku-4-5
total           1798    3.8M    1.3M   20.3M  242.8M  268.2M      $262  100.0%  opus-5,sonnet-5 +1
EOT
)

T_PROJ_BREAK=$(cat <<'EOT'
usage  2026-10-26 .. 2026-11-01  by project > model

                         reqs   input  output  cwrite   cread   total         $   share  days  span
~/git/work/billing-api    659    1.4M    483k    7.7M   92.3M  102.0M      $101   62.3%     4  10-29..11-01
  opus-5                  501    1.1M    360k    6.3M   77.3M   85.0M     $92.4   57.0%     3  10-29..11-01
  sonnet-5                158    360k    123k    1.4M   15.0M   16.9M     $8.57    5.3%     3  10-29..11-01
~/git/personal/tagents    215    470k    162k    2.6M   32.2M   35.4M     $38.8   23.9%     2  10-31..11-01
  opus-5                  215    470k    162k    2.6M   32.2M   35.4M     $38.8   23.9%     2  10-31..11-01
~/git/work/web-app        153    290k    101k    1.5M   17.9M   19.8M     $16.7   10.3%     3  10-28..10-31
  opus-5                   77    160k     58k    900k   11.6M   12.7M     $13.7    8.4%     1  10-30
  sonnet-5                 54     90k     31k    420k    5.2M    5.7M     $2.58    1.6%     1  10-28
  haiku-4-5                22     40k     12k    150k    1.1M    1.3M     $0.40    0.2%     1  10-31
~/git/personal/site       103    190k     69k    920k   10.7M   11.9M     $5.51    3.4%     2  10-27..10-28
  sonnet-5                103    190k     69k    920k   10.7M   11.9M     $5.51    3.4%     2  10-27..10-28
~/scratch/probe            18     30k      9k     90k    700k    829k     $0.26    0.2%     1  11-01
  haiku-4-5                18     30k      9k     90k    700k    829k     $0.26    0.2%     1  11-01
total                    1148    2.4M    824k   12.8M  153.8M  169.9M      $162  100.0%     6  10-27..11-01
EOT
)

T_SESS_TOP3=$(cat <<'EOT'
usage  2026-10-26 .. 2026-11-01  by session

           reqs   input  output  cwrite   cread   total         $   share  days  span          models
3f9a1c20    502    1.2M    387k    6.3M   74.3M   82.1M     $86.1   53.1%     3  10-29..11-01  opus-5,sonnet-5
d8c3b615    215    470k    162k    2.6M   32.2M   35.4M     $38.8   23.9%     2  10-31..11-01  opus-5
91ab44ee    131    250k     89k    1.3M   16.8M   18.5M     $16.3   10.0%     2  10-28..10-30  opus-5,sonnet-5
… 5 more    300    540k    186k    2.6M   30.5M   33.9M     $21.0   13.0%     5  10-27..11-01  sonnet-5,opus-5 +1
total      1148    2.4M    824k   12.8M  153.8M  169.9M      $162  100.0%     6  10-27..11-01  opus-5,sonnet-5 +1
EOT
)

tsv() { fx --by "$@" --tsv; }

ok "--by account: three accounts, the dearest first, the unplaced one as ?" "$X_ACCT" "$(tsv account $W)"
ok "--by account,project: two keys, then ten figures" "$X_ACCT_PROJ" "$(tsv account,project $W)"
ok "...12 tab-separated fields on every row" "12" "$(tsv account,project $W | awk -F'\t' '{ print NF }' | sort -u)"
ok "--by account,project,session: three levels, a session as its full id" "$X_ACCT_PROJ_SESS" "$(tsv account,project,session $W)"
ok "--by session: the dearest session first" "$X_SESS" "$(tsv session $W)"
ok "--by model" "$X_MODEL" "$(tsv model $W)"
ok "--tsv prints no header and no colour" "0" "$(tsv account $W | grep -c -e $'\033' -e '^account')"

# A group is the sum of the rows beneath it, at every level.
sumrows() {  # <number of key fields> : the figures of the rows read on stdin, summed by their first key
  awk -F'\t' -v k="$1" '{ for (i = k + 1; i <= k + 5; i++) S[$1, i] += $i; S[$1, 99] += $(k + 6); K[$1] = 1 }
    END { for (a in K) { printf "%s", a; for (i = k + 1; i <= k + 5; i++) printf "\t%.0f", S[a, i]; printf "\t%.6f\n", S[a, 99] } }' | sort
}
top1=$(tsv account $W | awk -F'\t' '{ printf "%s", $1; for (i = 2; i <= 6; i++) printf "\t%.0f", $i; printf "\t%.6f\n", $7 }' | sort)
ok "...there are three accounts to sum" "3" "$(printf '%s\n' "$top1" | /usr/bin/grep -c .)"
ok "an account is the sum of its projects" "$top1" "$(tsv account,project $W | sumrows 2)"
ok "...and of its sessions, three levels down" "$top1" "$(tsv account,project,session $W | sumrows 3)"
proj1=$(tsv account,project $W | awk -F'\t' '{ printf "%s\t%s", $1, $2; for (i = 3; i <= 7; i++) printf "\t%.0f", $i; printf "\t%.6f\n", $8 }' | sort)
ok "a project is the sum of its sessions" "$proj1" \
   "$(tsv account,project,session $W | awk -F'\t' '{ k = $1 "\t" $2; for (i = 4; i <= 8; i++) S[k, i] += $i; S[k, 9] += $9; K[k] = 1 }
      END { for (a in K) { printf "%s", a; for (i = 4; i <= 8; i++) printf "\t%.0f", S[a, i]; printf "\t%.6f\n", S[a, 9] } }' | sort)"

# Time runs oldest first, and a week starts on Monday.
ok "--by day: oldest first" "$X_DAY" "$(tsv day $W)"
ok "--by week: Mondays, oldest first" "$X_WEEK" "$(tsv week --since 2026-10-05 --until 2026-11-01)"
ok "--by month splits at the month" "$X_MONTH" "$(tsv month --since 2026-10-01 --until 2026-11-01)"
ok "Sunday 2026-11-01 is in the week of Monday 2026-10-26" "2026-10-26" \
   "$(tsv week --since 2026-11-01 --until 2026-11-01 | cut -f1)"
ok "--by hour: the hour of the bucket, in the local zone" "2026-10-29 12:00" \
   "$(tsv hour --since 2026-10-29 --until 2026-10-29 | cut -f1)"
ok "a week table with no --since reaches back to the start of the index" "$X_ALL_WEEK" "$(tsv week)"
ok "a month table with no --since reaches back to the start of the index" "$X_ALL_MONTH" "$(tsv month)"
ok "...but a day table with none keeps to seven days" "0" "$(tsv day | grep -c '^2026-10-0')"

# A second index: the cases the twelve sessions do not have.
F2="$ROOT/fx2"; mkdir -p "$F2/usage" "$F2/projects/-h-x"
ts2=$(( $(ep '2026-10-20 12:00:00') / 300 * 300 ))
fx2() { FX_STATE="$F2/usage" fx "$@"; }
row2() {  # <session> <agent id> <agent type> <kind> <model> <reqs> <in> <cw5> <cw1h> <cr> <out>
  printf '%s\t-h-x\t%s-1111-2222-3333-444444444444\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t100\t100\n' \
    "$ts2" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}"
}
{ row2 aaaaaaaa - - - claude-opus-5 10 1000000 1000000 1000000 0 0
  row2 bbbbbbbb - - - claude-mystery-1 4 1000 0 0 0 1000
  row2 cccccccc - - - '<synthetic>' 1 0 0 0 0 0
  row2 aaaaaaaa ag1 general-purpose wf:review claude-sonnet-5 3 1000000 0 0 0 0
  row2 aaaaaaaa ag2 Explore bg claude-sonnet-5 2 1000000 0 0 0 0
} >"$F2/usage/facts.tsv"
printf -- '-h-x\t%s/git/x\n' "$FXH" >"$F2/usage/projects.tsv"
W2="--since 2026-10-20 --until 2026-10-20"
tsv2() { fx2 --by "$@" --tsv; }

D2="2026-10-20${TAB}2026-10-20"
# 5-minute and 1-hour cache writes are one column. Opus at 5 dollars in: 1M
# input is 5, 1M 5-minute writes 6.25 and 1M 1-hour writes 10.
ok "--by model: cache write is the 5- and the 1-hour writes together, each priced at its own rate" \
   "$(printf 'claude-opus-5\t10\t1000000\t0\t2000000\t0\t21.250000\t0\t%s\t1' "$D2")" \
   "$(tsv2 model $W2 | grep -F 'claude-opus-5')"
ok "a model with no rate counts its requests as unpriced and costs nothing" \
   "$(printf 'claude-mystery-1\t4\t1000\t1000\t0\t0\t0.000000\t4\t%s\t1' "$D2")" \
   "$(tsv2 model $W2 | grep -F 'claude-mystery-1')"
ok "the zero-token placeholder is not a hole in the bill" \
   "$(printf '<synthetic>\t1\t0\t0\t0\t0\t0.000000\t0\t%s\t1' "$D2")" \
   "$(tsv2 model $W2 | grep -F '<synthetic>')"
ok "the rows are by dollars, and a tie is by key" \
   "claude-opus-5 claude-sonnet-5 <synthetic> claude-mystery-1" \
   "$(tsv2 model $W2 | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
ok "--by agent: the main session, a workflow agent and a named subagent" \
   "$(printf '· main session\n⑂ Explore (bg)\n⑂ workflow agent')" \
   "$(tsv2 agent $W2 | cut -f1 | LC_ALL=C sort)"
ok "--by workflow covers only the workflow agents" \
   "$(printf 'wf:review\t3\t1000000\t0\t0\t0\t2.000000\t0\t%s\t1' "$D2")" \
   "$(tsv2 workflow $W2)"
ok "a window with nothing in it says so and exits 1" "no data in this window|1" \
   "$(fx --by day --since 2030-01-01 --until 2030-01-02 | tr '\n' ' ' | sed 's/ $//')|$(fxrc --by day --since 2030-01-01 --until 2030-01-02)"
ok "a missing index says so and exits 1" "tusage: no data yet|1" \
   "$(FX_STATE="$ROOT/none/usage" fx --by day | cut -c1-19)|$(FX_STATE="$ROOT/none/usage" fxrc --by day)"

# ---------------------------------------------------------------------------
t "17. per-model rows, the top rows and the order of the rows"
# ---------------------------------------------------------------------------

ok "--breakdown adds the model as one more key" "$X_PROJ_BREAK" "$(tsv project --breakdown $W)"
ok "...and the models of a project add up to the project" \
   "$(tsv project $W | awk -F'\t' '{ printf "%s\t%.6f\n", $1, $7 }' | sort)" \
   "$(tsv project --breakdown $W | awk -F'\t' '{ S[$1] += $8 } END { for (p in S) printf "%s\t%.6f\n", p, S[p] }' | sort)"
ok "--breakdown changes nothing when model is already a dimension" "$(tsv project,model $W)" "$(tsv project,model --breakdown $W)"
ok "...nor does it count towards the three dimensions" "0" "$(fxrc --by account,project,session --breakdown $W)"
ok "the table of --breakdown has the models indented under their project" "$T_PROJ_BREAK" "$(fx --by project --breakdown --color never $W)"

ok "--top 3 keeps the three dearest and sums the rest into one row" "$T_SESS_TOP3" "$(fx --by session --top 3 --color never $W)"
ok "--top 0 shows every row" "0" "$(fx --by session --top 0 $W | grep -c 'more')"
ok "...and a table that is shorter than the limit has no remainder row" "0" "$(fx --by session --top 8 $W | grep -c 'more')"
ok "--tsv ignores --top" "$X_SESS" "$(tsv session --top 3 $W)"
ok "--top cuts under each parent, not the table as a whole" "2" "$(fx --by account,project --top 1 $W | grep -c 'more')"
ok "time dimensions are never cut" "6" "$(fx --by day --top 2 $W | grep -c '^2026-')"
ok "the models of a breakdown are never cut" "6" "$(fx --by project --breakdown --top 3 --color never $W | grep -c -e opus -e sonnet -e haiku)"
ok "--sort cost puts a time dimension in dollar order" "$(printf '%s\n' "$X_DAY" | sort -t"$TAB" -k7,7nr)" "$(tsv day --sort cost $W)"

# Fourteen sessions with distinct dollars: the default is twelve rows and a rest.
F3="$ROOT/fx3"; mkdir -p "$F3/usage" "$F3/projects/-h-x"
i=1; while [ $i -le 14 ]; do
  printf '%s\t-h-x\t%08d-1111-2222-3333-444444444444\t-\t-\t-\tclaude-sonnet-5\t1\t%d\t0\t0\t0\t0\t100\t100\n' "$ts2" "$i" "$((i * 1000000))"
  i=$((i + 1))
done >"$F3/usage/facts.tsv"
printf -- '-h-x\t%s/git/x\n' "$FXH" >"$F3/usage/projects.tsv"
fx3() { FX_STATE="$F3/usage" fx "$@"; }
out=$(fx3 --by session --since 2026-10-20 --until 2026-10-20)
ok "the default is twelve rows" "12" "$(printf '%s\n' "$out" | grep -c '^000000')"
contains "...and a row that sums the two it left out" "… 2 more" "$out"
ok "--top 0 on fourteen sessions shows fourteen" "14" "$(fx3 --by session --top 0 --since 2026-10-20 --until 2026-10-20 | grep -c '^000000')"

# ---------------------------------------------------------------------------
t "18. the table: its figures, its closing lines"
# ---------------------------------------------------------------------------
lacks() {  # <name> <needle> <haystack>
  case "$3" in
    *"$2"*) fail=$((fail + 1)); printf '  FAIL %s\n       expected NOT to contain: %s\n       actual: %s\n' "$1" "$2" "$3" ;;
    *) pass=$((pass + 1)); printf '  ok   %s\n' "$1" ;;
  esac
}

table() { sed '/^total/q'; }  # the table, without the lines that close it
ok "account and project at 140 columns, to the character" "$T_ACCT_PROJ" "$(fx --by account,project --color never $W | table)"
ok "week and account: no days or span beside a time dimension, and the weeks run oldest first" "$T_WEEK_ACCT" \
   "$(fx --by week,account --color never --since 2026-10-05 --until 2026-11-01 | table)"

out=$(fx --by account --color never $W)
contains "a table with no time dimension has days and span" "span" "$(printf '%s\n' "$out" | sed -n 3p)"
contains "...and the models of the row, when no row is a model" "models" "$(printf '%s\n' "$out" | sed -n 3p)"
out=$(fx --by day --color never $W)
lacks "a table by day has no days column" " days" "$(printf '%s\n' "$out" | sed -n 3p)"
lacks "...and no span" "span" "$(printf '%s\n' "$out" | sed -n 3p)"
lacks "a table whose rows are models has no models column" "models" "$(fx --by model --color never $W | sed -n 3p)"
contains "the title names the window by its first and last day and the dimensions" \
  "usage  2026-10-26 .. 2026-11-01  by account > project" "$(fx --by account,project $W | sed -n 1p)"
contains "a breakdown adds the model to the title" "by project > model" "$(fx --by project --breakdown $W | sed -n 1p)"

out=$(fx --by account --color never $W)
contains "an unplaced session is the account ? unplaced" "? unplaced" "$out"
contains "...and the closing line counts it and says what places it" \
  "1 session belongs to no account: TU_ACCOUNT_RULES places a session by the directory it started in." "$out"
lacks "...but a table with no account dimension has no such line" "belongs to no account" "$(fx --by project $W)"

# A factor stored for work, under a price table the test sets: list price is
# said at the end when the account is a row, and only then.
FX_PRICES=$'claude-opus-5 5 25\nclaude-sonnet-5 2 10\nclaude-haiku-4-5 1 5\n'
fpr=$(printf '%s' "$FX_PRICES" | tr -s ' \n' ' ' | cksum | tr -d ' ')
printf 'work\t0.8\t1\t1\t%s\n' "$fpr" >"$FX/usage/factor.tsv"
contains "a stored factor: the closing line says the dollars are at list price and names --daily" \
  "Dollars are at list price. A meter factor is stored for work: tusage --daily scales its dollars by it." \
  "$(fx --by account --color never $W)"
lacks "...and it does not scale the dollars of the table" "\$94" "$(fx --by account --color never $W)"
lacks "a table with no account dimension does not mention the factor" "meter factor" "$(fx --by project $W)"
printf 'personal\t0.9\t1\t1\t%s\nwork\t0.8\t1\t1\t%s\n' "$fpr" "$fpr" >"$FX/usage/factor.tsv"
contains "two accounts with a factor are both named" "stored for work and personal" \
  "$(fx --by account --color never $W | tr '\n' ' ')"
rm -f "$FX/usage/factor.tsv"; unset FX_PRICES
lacks "no stored factor, no line about one" "meter factor" "$(fx --by account $W)"

out=$(fx2 --by model --color never $W2)
contains "a model with no rate: its dollars end in *" '$0*' "$out"
contains "...and the table says the figure is a floor" "a floor" "$out"
lacks "a table with every model rated has no such line" "a floor" "$(fx --by account $W)"


# ---------------------------------------------------------------------------
t "19. --account and --project narrow every report"
# ---------------------------------------------------------------------------
ok "--by account --account work keeps the one account" "$(printf '%s\n' "$X_ACCT" | sed -n 1p)" "$(tsv account --account work $W)"
ok "--account twice is a list" "$(printf '%s\n' "$X_ACCT" | sed -n 1,2p)" "$(tsv account --account work --account personal $W)"
ok "...and a comma list is the same list" "$(printf '%s\n' "$X_ACCT" | sed -n 1,2p)" "$(tsv account --account work,personal $W)"
ok "--account ? keeps the sessions no account claims" "$(printf '%s\n' "$X_ACCT" | sed -n 3p)" "$(tsv account --account '?' $W)"
ok "a project table of one account is that account's projects, dearest first" \
   "$(printf '%s\n' "$X_ACCT_PROJ" | awk -F'\t' '$1 == "work"' | cut -f2-)" "$(tsv project --account work $W)"

ok "--sessions --account work keeps the sessions of work" \
   "$(tsv account,project,session $W | awk -F'\t' '$1 == "work" { print $3 }' | sort)" \
   "$(fx --sessions $W --account work | cut -f1 | sort)"
ok "...with the 14 fields it has unfiltered" "14" "$(fx --sessions $W --account work | awk -F'\t' '{ print NF }' | sort -u)"
ok "...and a row is the row it is unfiltered" "$(fx --sessions $W | /usr/bin/grep "^$(fxsid 3f9a1c20)")" \
   "$(fx --sessions $W --account work | /usr/bin/grep "^$(fxsid 3f9a1c20)")"
ok "--daily --account work has the five fields and only work" "5|work" \
   "$(fx --daily $W --account work | awk -F'\t' '{ print NF }' | sort -u)|$(fx --daily $W --account work | cut -f2 | sort -u)"
ok "...and a row is the row it is unfiltered" "$(fx --daily $W | awk -F'\t' '$2 == "work"')" "$(fx --daily $W --account work)"
out=$(fx --json --since 1000d --account work)
contains "--json --account work lists the sessions of work" "$(fxsid 3f9a1c20)" "$out"
lacks "...and not those of personal" "$(fxsid d8c3b615)" "$out"

ok "--project keeps the projects whose path contains the text, ignoring case" \
   "$(printf '%s\n' "$X_SESS" | /usr/bin/grep -e "^$(fxsid 3f9a1c20)" -e "^$(fxsid c04d7be1)" -e "^$(fxsid b72e90d4)")" \
   "$(tsv session --project BILLING $W)"
ok "--project twice keeps a row that matches either" "4" "$(tsv session --project billing --project probe $W | wc -l | tr -d ' ')"
ok "--project with --account keeps the rows that match both" \
   "$(fxsid 91ab44ee) $(fxsid e5d1f0a7)" "$(tsv session --account work --project web $W | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
out=$(fx --by session --account personal --project billing $W); rc=$?
ok "nothing left after the filters is an empty window, not a missing index" "no data in this window|1" "$out|$rc"
ok "--project with no text exits 2" "2" "$(fxrc --by day --project '')"
ok "--account with no name exits 2" "2" "$(fxrc --by day --account '')"

# The summary and --burn read the clock, so they get rows of their own: one
# work session and one personal session, spent half an hour ago.
F4="$ROOT/fx4"; mkdir -p "$F4/usage" "$F4/projects/-h-x" "$F4/projects/-h-y"
now4=$(( $(date +%s) / 300 * 300 - 1800 ))
{ printf '%s\t-h-x\t%s\t-\t-\t-\tclaude-opus-5\t5\t1000000\t0\t0\t0\t0\t100\t100\n' "$now4" "$(fxsid 3f9a1c20)"
  printf '%s\t-h-y\t%s\t-\t-\t-\tclaude-opus-5\t5\t1000000\t0\t0\t0\t0\t100\t100\n' "$now4" "$(fxsid d8c3b615)"
} >"$F4/usage/facts.tsv"
printf -- '-h-x\t%s/git/x\n-h-y\t%s/git/y\n' "$FXH" "$FXH" >"$F4/usage/projects.tsv"
fx4() { FX_STATE="$F4/usage" fx "$@"; }
both=$(fx4 --burn)
contains "--burn adds both accounts" "5h " "$both"
ok "--burn --account work,personal is the five hours of every account" "$(fx4 --burn)" "$(fx4 --burn --account work,personal)"
ok "--burn --account personal is not what both spent" "1" "$([ "$(fx4 --burn --account personal)" != "$both" ] && echo 1 || echo 0)"
ok "--burn for an account that spent nothing prints nothing" "" "$(fx4 --burn --account '?')"
out=$(fx4)
contains "the summary names both projects" "~/git/y" "$out"
out=$(fx4 --account work)
contains "the summary of one account keeps its project" "~/git/x" "$out"
lacks "...and drops the other's" "~/git/y" "$out"

# ---------------------------------------------------------------------------
t "20. sessions are named: a typed name, a title, or the eight characters"
# ---------------------------------------------------------------------------
# The names are the dashboard's: labels.tsv holds what was typed, title.tsv the
# titles read from transcripts. A scratch state directory holds both, so nothing
# of the real machine is read and no other section sees these files.

TA20="$ROOT/ta20"; mkdir -p "$TA20"
printf '%s\t%s\n' \
  "$(fxsid 3f9a1c20)" "refactor-billing" \
  "$(fxsid d8c3b615)" "tagents-core" \
  "$(fxsid d8c3b615)" "a second line is ignored" \
  "$(fxsid 91ab44ee)" "" \
  "$(fxsid 7c3f4e55)" "tagents-site" \
  "$(fxsid 0a6f7e92)" "$(printf 'ev\033[31mil')" \
  "%12" "a pane, not a session" >"$TA20/labels.tsv"
printf '%s\t%s\t%s\n' \
  "$(fxsid 91ab44ee)" "Fix the webapp login" 1234 \
  "$(fxsid 3f9a1c20)" "Billing title" 900 >"$TA20/title.tsv"
tjson() {  # <project dir> <title> <sid first 8>
  printf '%s\n%s\n' '{"type":"user","message":{"content":"hello"}}' "{\"type\":\"ai-title\",\"aiTitle\":\"$2\"}" \
    >"$FX/projects/$1/$(fxsid "$3").jsonl"
}
cp "$FX/usage/projects.tsv" "$ROOT/projects.keep"
tjson -h-billing "Add invoice export" c04d7be1
tjson -h-billing "Transcript title" 3f9a1c20
tjson -h-tagents "Hidden title" d8c3b615
tjson -h-probe "Probe title" 7b2c5d33
touch "$FX/usage/projects.tsv"
export FX_TA="$TA20"
labels_sum=$(cksum <"$TA20/labels.tsv")

names_of() {  # stdin: a --by session table; the label of each of its rows
  sed -n '4,$p' | sed '/^total/,$d' | sed -E 's/  +[0-9]+  .*$//; s/ +$//'
}

out=$(fx --by session --top 3 $W)
ok "a session cut by --top has its transcript left unread" 0 "$(grep -c "^$(fxsid 7b2c5d33)" "$TA20/title.tsv")"

out=$(fx --by session --top 0 $W)
rows=$(names_of <<<"$out")
row() { printf '%s\n' "$rows" | grep -- "$1"; }
ok "a typed name, then the eight characters of the id" "refactor-billing  3f9a1c20" "$(row 3f9a1c20)"
ok "the first line for an id wins" "tagents-core  d8c3b615" "$(row d8c3b615)"
ok "an empty name is no name: the cached title shows" "Fix the webapp login  91ab44ee" "$(row 91ab44ee)"
ok "a title from the transcript when there is no name" "Add invoice export  c04d7be1" "$(row c04d7be1)"
ok "no name and no title: the eight characters alone" "b72e90d4" "$(row b72e90d4)"
ok "a title read from a transcript names its session" "Probe title  7b2c5d33" "$(row 7b2c5d33)"
lacks "a typed name beats a cached title" "Billing title" "$out"
lacks "...and a title in the transcript" "Transcript title" "$out"
ok "a typed name leaves the transcript unread" 0 "$(grep -c "^$(fxsid d8c3b615)" "$TA20/title.tsv")"
ok "a title read from a transcript is cached" "Add invoice export" \
   "$(awk -F'\t' -v s="$(fxsid c04d7be1)" '$1 == s { print $2 }' "$TA20/title.tsv")"
rm -f "$FX/projects/-h-billing/$(fxsid c04d7be1).jsonl"
cp "$ROOT/projects.keep" "$FX/usage/projects.tsv"   # a changed project dir would have the map rebuilt from transcripts with no cwd
ok "the next run reads the cache, not the transcript" "Add invoice export  c04d7be1" \
   "$(fx --by session --top 0 $W | names_of | grep c04d7be1)"
ok "a cached title is left as it was" "1" "$(grep -c 'Billing title' "$TA20/title.tsv")"
ok "the writes leave no temporary file beside the cache" "labels.tsv title.tsv" "$(ls "$TA20" | tr '\n' ' ' | sed 's/ $//')"
ok "tusage never writes labels.tsv" "$labels_sum" "$(cksum <"$TA20/labels.tsv")"

ok "a name carrying an escape sequence prints without the escape" "ev[31mil  0a6f7e92" "$(row 0a6f7e92)"
ok "...and the table holds no escape byte" 0 "$(printf '%s' "$out" | LC_ALL=C grep -c "$(printf '\033')")"
contains "names reach the sessions of a nested table" "    refactor-billing  3f9a1c20" "$(fx --by account,project,session --top 0 $W)"
lacks "a table of projects names no session" "refactor-billing" "$(fx --by project $W)"
lacks "--tsv prints ids" "refactor-billing" "$(fx --by session --tsv $W)"
lacks "--sessions prints ids" "refactor-billing" "$(fx --sessions --since 1000d)"
lacks "--daily prints no names" "refactor-billing" "$(fx --daily --since 1000d)"

# Without the modules the ids are all there is, and the report still runs.
mkdir -p "$ROOT/nolib"; cp "$TU" "$ROOT/nolib/tusage"
out=$(FX_TU="$ROOT/nolib/tusage" fx --by session --top 0 $W); rc=$?
ok "with the modules unfindable the report exits 0" 0 "$rc"
ok "...and prints the ids alone" 0 "$(names_of <<<"$out" | grep -vcE '^[0-9a-f]{8}$')"

# The modules are found beside the real file, through any chain of symlinks.
mkdir -p "$ROOT/ln"; ln -s "$TU" "$ROOT/ln/two"; ln -s two "$ROOT/ln/one"
contains "run through two symlinks the names still resolve" "refactor-billing  3f9a1c20" \
         "$(FX_TU="$ROOT/ln/one" fx --by session --top 0 $W)"

# The walk is a copy of the one in ./tagents, and the two must not drift.
walk() { awk -v a='  ta_real=${BASH_SOURCE[0]}' -v z='    *)   TA_LIB=lib/tagents ;;' '$0 == a { p = 1 } p { print } p && $0 == z { exit }' "$1"; }
ok "the symlink walk is the text of the one in ./tagents" "$(walk "$HERE/../tagents")" "$(walk "$TU")"
ok "...and it is a whole loop, not an empty match" 1 "$([ "$(walk "$TU" | wc -l | tr -d ' ')" -ge 14 ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
t "20b. --session finds a session by its id, a prefix of it or its name"
# ---------------------------------------------------------------------------

SID3=$(fxsid 3f9a1c20)
detail=$(fx --session "$SID3"); rc=$?
ok "a full id prints the detail" 0 "$rc"
contains "...headed by the full id" "$SID3" "$detail"
ok "a unique prefix prints the same detail" "$detail" "$(fx --session 3f9a1c)"
ok "a name, whole, prints the same" "$detail" "$(fx --session refactor-billing)"
ok "...ignoring case" "$detail" "$(fx --session REFACTOR-Billing)"
ok "a part of a name prints the same" "$detail" "$(fx --session factor-bil)"
ok "a title in the cache is a name too" "$(fx --session "$(fxsid c04d7be1)")" "$(fx --session 'invoice export')"

out=$(fxe --session tagents); rc=$?
ok "two names holding the text exit 3" 3 "$rc"
ok "...with nothing on standard output" "" "$(fxo --session tagents)"
contains "...and the first candidate on standard error: id, name, account, days" \
         "  $(fxsid d8c3b615)  tagents-core  personal  2 days" "$out"
contains "...and the second" "  $(fxsid 7c3f4e55)  tagents-site  personal  2 days" "$out"
out=$(fxe --session 7); rc=$?
ok "a prefix of two ids exits 3" 3 "$rc"
contains "...listing the session of one day" "  $(fxsid 7b2c5d33)  Probe title  ?  1 day" "$out"
contains "...and the other" "  $(fxsid 7c3f4e55)  tagents-site  personal  2 days" "$out"

out=$(fx --session nothing-like-it); rc=$?
ok "a value that names nothing exits 1" 1 "$rc"
ok "...and says so" "tusage: no session called nothing-like-it" "$out"
out=$(fx --session deadbeef); rc=$?
ok "an id-shaped value that names nothing keeps its empty detail and exits 0" 0 "$rc"
contains "...the empty detail" "(no usage recorded in the retained window)" "$out"

out=$(fx --session 7 --account personal); rc=$?
ok "--account narrows a prefix to one session" 0 "$rc"
contains "...the one of that account" "$(fxsid 7c3f4e55)" "$out"
ok "--account narrows a name: the other account has no such session" 1 "$(fxrc --session refactor-billing --account personal)"
ok "...and one that has it finds it" 0 "$(fxrc --session tagents-core --account personal)"
ok "...two names of the other account are no match" 1 "$(fxrc --session tagents --account work)"
unset FX_TA

# ---------------------------------------------------------------------------
t "21. account names in a terminal: the tagents config, then discovery"
# ---------------------------------------------------------------------------
# TU_ACCOUNTS is unset in these runs (FX_ACCOUNTS empty). The configs are files
# of a scratch directory named by TA_CONFIG; the home has a default account and
# one more, discovered the way a terminal with no config would find them.

C21="$ROOT/cfg21"; mkdir -p "$C21"
cat >"$C21/profiles.toml" <<EOF
[claude.profiles.work]
config_dir = "$FX/acct/work"

[claude.profiles.personal]
config_dir = "$FX/acct/personal"
EOF
{ cat "$C21/profiles.toml"; printf '\n[[claude.rules]]\ndir = "%s/scratch"\nprofile = "work"\n' "$FXH"; } >"$C21/rules.toml"
printf '[usage]\nwatch = "work"\n' >"$C21/noprofiles.toml"
printf '[[[ nope\nkey = = =\n"""unterminated\n' >"$C21/bad.toml"

H21="$ROOT/home21"; mkdir -p "$H21/.claude" "$H21/.claude-extra"
hist21() { printf '{"display":"x","pastedContents":{},"timestamp":1000,"project":"%s","sessionId":"%s"}\n' "$H21" "$(fxsid "$2")" >>"$1/history.jsonl"; }
for s in 3f9a1c20 b72e90d4 c04d7be1 91ab44ee e5d1f0a7 5a1d2c33 6b2e3d44; do hist21 "$H21/.claude" $s; done
for s in d8c3b615 0a6f7e92 7c3f4e55 8d4a5f66; do hist21 "$H21/.claude-extra" $s; done

fxc() { FX_HOME="$H21" FX_ACCOUNTS= fx "$@"; }   # a terminal: no TU_ACCOUNTS
keys() { cut -f1 | tr '\n' ' ' | sed 's/ $//'; }
ctsv() { FX_HOME="$H21" FX_ACCOUNTS= fx --by "$@" --tsv; }

ok "a config names the accounts" "work personal ?" "$(FX_CONFIG="$C21/profiles.toml" ctsv account $W | keys)"
ok "...with the figures of the same accounts named by TU_ACCOUNTS" "$(tsv account $W)" "$(FX_CONFIG="$C21/profiles.toml" ctsv account $W)"
ok "--account names one of them" "$(tsv session --account work $W)" "$(FX_CONFIG="$C21/profiles.toml" ctsv session --account work $W)"
ok "...and one the config does not name is unknown" 2 "$(FX_CONFIG="$C21/profiles.toml" fxc --by account --account extra $W >/dev/null; echo $?)"
ok "a rule of the config places a session by its directory" "work personal" "$(FX_CONFIG="$C21/rules.toml" ctsv account $W | keys)"
ok "...and adds its requests to the account" 830 "$(FX_CONFIG="$C21/rules.toml" ctsv account $W | awk -F'\t' '$1 == "work" { print $2 }')"

ok "no config: the default account and the one that keeps a history" "default extra ?" "$(FX_CONFIG="$ROOT/none.toml" ctsv account $W | keys)"
ok "a config with no profiles: the same" "default extra ?" "$(FX_CONFIG="$C21/noprofiles.toml" ctsv account $W | keys)"
ok "--account extra is known when the accounts are discovered" 0 "$(FX_CONFIG="$ROOT/none.toml" fxc --by account --account extra $W >/dev/null; echo $?)"

ok "TU_ACCOUNTS set by hand wins over the config" "a ?" \
   "$(FX_ACCOUNTS="a=$FX/acct/work" FX_HOME="$H21" FX_CONFIG="$C21/profiles.toml" fx --by account $W --tsv | keys)"
ok "...and the rules of the config are not read either" 18 \
   "$(FX_ACCOUNTS="work=$FX/acct/work;personal=$FX/acct/personal" FX_HOME="$H21" FX_CONFIG="$C21/rules.toml" fx --by account $W --tsv | awk -F'\t' '$1 == "?" { print $2 }')"
ok "TU_ACCOUNT_RULES set by hand wins over the rules of the config" "336" \
   "$(FX_RULES="$FXH/scratch=personal" FX_CONFIG="$C21/rules.toml" ctsv account $W | awk -F'\t' '$1 == "personal" { print $2 }')"

# A broken config is the config's business: tusage prints nothing of it.
ok "the parser does complain about the broken config" 1 \
   "$([ -n "$(HOME="$FXH" TA_CONFIG="$C21/bad.toml" TA_STATE_DIR="$ROOT/ta-none" bash -c '. "$1/core.sh"; . "$1/config.sh"; . "$1/accounts.sh"; . "$1/usage.sh"; usage_env' _ "$HERE/../lib/tagents" 2>&1)" ] && echo 1 || echo 0)"
ok "a malformed config adds nothing to standard error" "$(FX_CONFIG="$ROOT/none.toml" fxc --by account $W)" "$(FX_CONFIG="$C21/bad.toml" fxc --by account $W)"

ok "with no lib/tagents beside the file the discovery stays" "default extra ?" \
   "$(FX_TU="$ROOT/nolib/tusage" FX_CONFIG="$C21/profiles.toml" ctsv account $W | keys)"
ok "a run through a symlink finds the config" "work personal ?" \
   "$(FX_TU="$ROOT/ln/one" FX_CONFIG="$C21/profiles.toml" ctsv account $W | keys)"
ok "--daily splits by the accounts of the config" "? personal work" \
   "$(FX_CONFIG="$C21/profiles.toml" fxc --daily --since 1000d | cut -f2 | sort -u | tr '\n' ' ' | sed 's/ $//')"

# Only the reports that split by account look at the config, and never when
# TU_ACCOUNTS says what the accounts are: the dashboard reads --sessions on every
# refresh. bash -x prints the calls, so a call that was not made is a count of 0.
traced() { FX_SH='bash -x' FX_HOME="$H21" FX_CONFIG="$C21/profiles.toml" "$@" | grep -c 'ensure_accounts$'; }
ok "--by account looks at the config" 1 "$([ "$(FX_ACCOUNTS= traced fx --by account $W)" -ge 1 ] && echo 1 || echo 0)"
ok "the summary does too: it has a block by account" 1 "$([ "$(FX_ACCOUNTS= traced fx)" -ge 1 ] && echo 1 || echo 0)"
ok "--sessions does not" 0 "$(FX_ACCOUNTS= traced fx --sessions --since 1000d)"
ok "--burn does not" 0 "$(FX_ACCOUNTS= traced fx --burn)"
ok "--json does not" 0 "$(FX_ACCOUNTS= traced fx --json --since 1000d)"
ok "--session <id> does not" 0 "$(FX_ACCOUNTS= traced fx --session "$(fxsid 3f9a1c20)")"

# The dashboard calls these four on every refresh, so each reads the clock as few
# times as the work needs: a report with a window reads it once for the window and
# for the rows that count the last hour and five, and one with no window reads it
# for nothing else.
datecalls() { FX_SH='bash -x' "$@" | grep -c 'date +%s$'; }
ok "--sessions reads the clock once" 1 "$(datecalls fx --sessions --since 1000d)"
ok "--burn reads it once, for its own five hours" 1 "$(datecalls fx --burn)"
ok "--session <id> reads it not at all" 0 "$(datecalls fx --session "$(fxsid 3f9a1c20)")"

# ---------------------------------------------------------------------------
t "22. one session by day"
# ---------------------------------------------------------------------------
# --session names the rows; --by names the table. Neither flag decides on its
# own which report runs, so they mean the same in either order.

export FX_TA="$TA20"
SD_HEAD="refactor-billing  $SID3
work  ·  ~/git/work/billing-api  ·  3 days, 10-29..11-01
"
SD_TABLE='             reqs   input  output  cwrite   cread   total         $   share
2026-10-29    180    430k    137k    2.3M   24.5M   27.4M     $28.8   33.5%
  opus-5      142    310k     96k    1.9M   21.4M   23.7M     $26.5   30.8%
  sonnet-5     38    120k     41k    410k    3.1M    3.7M     $2.29    2.7%
2026-10-31    210    440k    150k    2.6M   33.0M   36.2M     $38.7   45.0%
  opus-5      210    440k    150k    2.6M   33.0M   36.2M     $38.7   45.0%
2026-11-01    112    290k    100k    1.4M   16.8M   18.6M     $18.6   21.6%
  opus-5       88    200k     70k    1.1M   14.8M   16.2M     $17.0   19.8%
  sonnet-5     24     90k     30k    260k    2.0M    2.4M     $1.53    1.8%
total         502    1.2M    387k    6.3M   74.3M   82.1M     $86.1  100.0%'
out=$(fx --session refactor-billing --by day,model --color never); rc=$?
ok "--session <name> --by day,model: the heading, then the table" "$SD_HEAD
$SD_TABLE" "$out"
ok "...and exits 0" 0 "$rc"
ok "--by first and --session second print the same" "$out" "$(fx --by day,model --session refactor-billing --color never)"
ok "a prefix of the id prints the same" "$out" "$(fx --session 3f9a1c --by day,model --color never)"
ok "the whole id prints the same" "$out" "$(fx --session "$SID3" --by day,model --color never)"
ok "a part of the name prints the same" "$out" "$(fx --session factor-bil --by day,model --color never)"

out=$(fx --session refactor-billing --by day --color never)
ok "--by day: one row per day and the total" "2026-10-29 2026-10-31 2026-11-01 total" \
   "$(printf '%s\n' "$out" | LC_ALL=C awk '/^(2026|total)/ { print $1 }' | paste -sd' ' -)"
ok "...with the heading above it" "$SD_HEAD" "$(printf '%s\n' "$out" | sed -n 1,2p)
"
ok "...and the days add up to the dollars of the table's total" "86.1" \
   "$(fx --session refactor-billing --by day --tsv | LC_ALL=C awk -F'\t' '{ s += $7 } END { printf "%.1f", s }')"
ok "--since narrows the window of a session: two days" "2026-10-31 2026-11-01 total" \
   "$(fx --session refactor-billing --by day --since 2026-10-31 --color never | LC_ALL=C awk '/^(2026|total)/ { print $1 }' | paste -sd' ' -)"
contains "...and the heading counts those days" "2 days, 10-31..11-01" "$(fx --session refactor-billing --by day --since 2026-10-31 --color never)"

out=$(fx --session "$(fxsid e5d1f0a7)" --by day --color never)
ok "a session with no name is headed by its id alone, and a one-day span is one date" "$(fxsid e5d1f0a7)
work  ·  ~/git/work/web-app  ·  1 day, 10-31
" "$(printf '%s\n' "$out" | sed -n 1,2p)
"
out=$(fx --session 7b2c5d33 --by day --color never)
contains "a session no account claims is in no account" "? unplaced  ·  " "$out"
out=$(fx --session 0a6f7e92 --by day --color never)
lacks "no escape sequence of a name reaches the heading" "$(printf '\033')" "$out"

ok "the session is a filter of --by session: one row" 1 "$(fx --session refactor-billing --by session --color never | grep -c '3f9a1c20 ')"
ok "...and of --by account: its account alone" "work" "$(fx --session refactor-billing --by account --color never | LC_ALL=C awk 'NR > 3 && /^(work|personal)/ { print $1 }')"
ok "a --tsv table has no heading: its lines are the three days" "3 3" \
   "$(fx --session refactor-billing --by day --tsv | LC_ALL=C awk '/^2026-/ { d++ } END { print d, NR }')"
ok "--session --sessions lists that session alone, 14 fields" "1 14" \
   "$(fx --session refactor-billing --sessions --since 1000d | LC_ALL=C awk -F'\t' 'END { print NR, NF }')"
ok "--account narrows the lookup of --by too" 1 "$(fxrc --session refactor-billing --by day --account personal)"
ok "a name that fits two sessions exits 3 with --by as it does without" 3 "$(fxrc --session tagents --by day)"
ok "a value that names nothing exits 1 with --by" 1 "$(fxrc --session nothing-like-it --by day)"
unset FX_TA

# ---------------------------------------------------------------------------
t "23. the table fits the terminal"
# ---------------------------------------------------------------------------
# The width is COLUMNS when that is a number, else the terminal's, else 120.
# Columns go in a fixed order until the label has 24 characters; the label,
# total, dollars and share stay. Lengths are counted in characters.

maxlen() {  # the longest line of standard input, in characters
  LC_ALL=C awk '{ n = 0; for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (c < "\200" || c > "\277") n++ }
                 if (n > m) m = n } END { print m + 0 }'
}
header() { grep -m1 ' share' | tr -s ' ' | sed 's/^ //'; }  # the column names of a table
cols() { FX_COLUMNS=$1 fx --by "$2" --color never $W | header; }

ok "80 columns: no line is longer than 80, the closing lines included" 1 \
   "$([ "$(FX_COLUMNS=80 fx --by account --color never $W | maxlen)" -le 80 ] && echo 1 || echo 0)"
T_AT80='usage  2026-10-26 .. 2026-11-01  by account

             reqs  output   cread   total         $   share
work          812    584k  110.2M  121.7M      $118   72.5%
personal      318    231k   42.9M   47.3M     $44.3   27.3%
? unplaced     18      9k    700k    829k     $0.26    0.2%
total        1148    824k  153.8M  169.9M      $162  100.0%'
ok "80 columns drop models, span, days, input and cwrite" "$T_AT80" "$(FX_COLUMNS=80 fx --by account --color never $W | table)"
T_AT72='                           reqs  output   total         $   share
work                        812    584k  121.7M      $118   72.5%
  ~/git/work/billing-api    659    483k  102.0M      $101   62.3%
  ~/git/work/web-app        153    101k   19.8M     $16.7   10.3%
personal                    318    231k   47.3M     $44.3   27.3%
  ~/git/personal/tagents    215    162k   35.4M     $38.8   23.9%
  ~/git/personal/site       103     69k   11.9M     $5.51    3.4%
? unplaced                   18      9k    829k     $0.26    0.2%
  ~/scratch/probe            18      9k    829k     $0.26    0.2%
total                      1148    824k  169.9M      $162  100.0%'
ok "72 columns leave 24 for the labels by dropping cread as well" "$T_AT72" \
   "$(FX_COLUMNS=72 fx --by account,project --color never $W | table | sed 1,2d)"
T_COMPACT='                           total         $   share
work                      121.7M      $118   72.5%
  ~/git/work/billing-api  102.0M      $101   62.3%
  ~/git/work/web-app       19.8M     $16.7   10.3%
personal                   47.3M     $44.3   27.3%
  ~/git/personal/tagents   35.4M     $38.8   23.9%
  ~/git/personal/site      11.9M     $5.51    3.4%
? unplaced                  829k     $0.26    0.2%
  ~/scratch/probe           829k     $0.26    0.2%
total                     169.9M      $162  100.0%'
ok "--compact keeps the label, total, dollars and share" "$T_COMPACT" \
   "$(fx --by account,project --compact --color never $W | table | sed 1,2d)"
ok "--compact does the same at any width" "$T_COMPACT" \
   "$(FX_COLUMNS=200 fx --by account,project --compact --color never $W | table | sed 1,2d)"

ok "the columns of a table with room for them all" "reqs input output cwrite cread total \$ share days span models" "$(cols 200 account,project)"
ok "120 columns: models go first" "reqs input output cwrite cread total \$ share days span" "$(cols 120 account,project)"
ok "100: span goes next" "reqs input output cwrite cread total \$ share days" "$(cols 100 account,project)"
ok "90: then days" "reqs input output cwrite cread total \$ share" "$(cols 90 account,project)"
ok "80: then input and cwrite" "reqs output cread total \$ share" "$(cols 80 account,project)"
ok "72: then cread" "reqs output total \$ share" "$(cols 72 account,project)"
ok "60: then output" "reqs total \$ share" "$(cols 60 account,project)"
ok "45: then reqs; the label, total, dollars and share are never dropped" "total \$ share" "$(cols 45 account,project)"
ok "a width that is not a number is 120" "$(FX_COLUMNS=120 fx --by account,project --color never $W)" \
   "$(FX_COLUMNS=wide fx --by account,project --color never $W)"
ok "no COLUMNS and no terminal is 120 too" "$(FX_COLUMNS=120 fx --by account,project --color never $W)" \
   "$(FX_COLUMNS= fx --by account,project --color never $W)"
ok "a table by day has the days and span columns of no time dimension left out, at any width" "reqs input output cwrite cread total \$ share models" "$(cols 200 day)"

# A label that does not fit ends in an ellipsis; a session keeps its id.
export FX_TA="$TA20"
out=$(FX_COLUMNS=60 fx --by session --top 0 --color never $W)
ok "60 columns: no line of a session table is longer" 1 "$([ "$(printf '%s\n' "$out" | maxlen)" -le 60 ] && echo 1 || echo 0)"
contains "a named session is cut in its name and keeps its eight characters" "Fix the webapp l…  91ab44ee" "$out"
contains "a name that fits is whole" "refactor-billing  3f9a1c20" "$out"
contains "a session with no name keeps all eight characters" "e5d1f0a7" "$out"
out=$(FX_COLUMNS=40 fx --by project --color never $W)
ok "40 columns: no line is longer, the title included" 1 "$([ "$(printf '%s\n' "$out" | maxlen)" -le 40 ] && echo 1 || echo 0)"
contains "a directory is cut with an ellipsis" "~/git/persona…" "$out"
unset FX_TA

# The closing lines wrap at the width and lose no word.
notes() { sed '1,/^total/d' | sed '/^$/d' | sed 's/^  //' | tr '\n' ' '; }
ok "the closing lines wrapped at 80 hold the same words as at 140" "$(fx --by account --color never $W | notes)" \
   "$(FX_COLUMNS=80 fx --by account --color never $W | notes)"
ok "...and are cut into more lines" 1 "$([ "$(FX_COLUMNS=80 fx --by account --color never $W | sed '1,/^total/d' | grep -c .)" -gt "$(fx --by account --color never $W | sed '1,/^total/d' | grep -c .)" ] && echo 1 || echo 0)"

# Names are measured in characters: Cyrillic is two bytes a letter.
TA23="$ROOT/ta23"; mkdir -p "$TA23"
printf '%s\t%s\n' "$(fxsid 3f9a1c20)" "Счёт-фактура для клиента" "$(fxsid d8c3b615)" "ядро" >"$TA23/labels.tsv"
out=$(FX_TA="$TA23" fx --by session --compact --top 0 --color never $W)
contains "a Cyrillic name is shown" "Счёт-фактура для клиента  3f9a1c20" "$out"
ok "...and every row has the same length in characters" 1 "$(printf '%s\n' "$out" | sed '1,2d' | sed '/^$/,$d' |
   LC_ALL=C awk '{ n = 0; for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (c < "\200" || c > "\277") n++ }; print n }' | sort -u | wc -l | tr -d ' ')"
out=$(FX_TA="$TA23" FX_COLUMNS=50 fx --by session --top 0 --color never $W)
contains "a Cyrillic name is cut by characters, and keeps its id" "Счёт-фактура …  3f9a1c20" "$out"
ok "...so the output is still valid UTF-8" 0 "$(printf '%s\n' "$out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
t "24. colour only where it helps"
# ---------------------------------------------------------------------------
ESC=$(printf '\033')
ok "a pipe has no escape sequence" 0 "$(fx --by account $W | grep -c "$ESC")"
ok "--color never has none" 0 "$(fx --by account --color never $W | grep -c "$ESC")"
ok "--color always has them" 1 "$([ "$(fx --by account --color always $W | grep -c "$ESC")" -gt 0 ] && echo 1 || echo 0)"
ok "--color always wins over NO_COLOR" 1 "$([ "$(FX_NO_COLOR=1 fx --by account --color always $W | grep -c "$ESC")" -gt 0 ] && echo 1 || echo 0)"
ok "--tsv has no colour, whatever --color says" 0 "$(fx --by account --tsv --color always $W | grep -c "$ESC")"
ok "colour is only escape sequences: the table is the same without them" "$(fx --by account,project --color never $W)" \
   "$(fx --by account,project --color always $W | sed "s/${ESC}\\[[0-9;]*m//g")"
ok "...also for a session's heading and for --top rows" "$(fx --session refactor-billing --by day,model --color never; fx --by session --top 3 --color never $W)" \
   "$({ fx --session refactor-billing --by day,model --color always; fx --by session --top 3 --color always $W; } | sed "s/${ESC}\\[[0-9;]*m//g")"
out=$(fx --by account,project --color always $W)
ok "a row with rows under it is bold" 1 "$(printf '%s\n' "$out" | grep -c "^${ESC}\[1mwork ")"
ok "the total is bold" 1 "$(printf '%s\n' "$out" | grep -c "^${ESC}\[1mtotal ")"
ok "a row with nothing under it is plain" 1 "$(printf '%s\n' "$out" | grep -c "^  ~/git/work/web-app ")"
ok "the column names are dim" 1 "$(printf '%s\n' "$out" | grep -c "^${ESC}\[90m  *reqs")"
ok "a row that sums the rest is dim" 1 "$(fx --by session --top 3 --color always $W | grep -c "^${ESC}\[90m… 5 more")"
ok "--color bad exits 2" 2 "$(fxrc --by account --color purple)"

if [ -z "$PTY" ]; then
  printf '  skip the checks on a pseudo-terminal: no script that makes one\n'
else
  ptyn() { FX_PTY=1 "$@" | grep -c "$ESC"; }
  ok "on a terminal, auto colours" 1 "$([ "$(ptyn fx --by account $W)" -gt 0 ] && echo 1 || echo 0)"
  ok "...unless --color never" 0 "$(ptyn fx --by account --color never $W)"
  ok "...or NO_COLOR is set" 0 "$(FX_NO_COLOR=1 ptyn fx --by account $W)"
  ok "...but an empty NO_COLOR is not set" 1 "$([ "$(FX_NO_COLOR= ptyn fx --by account $W)" -gt 0 ] && echo 1 || echo 0)"
  ok "...or TERM is dumb" 0 "$(FX_TERM=dumb ptyn fx --by account $W)"
  ok "...and --color always still colours with NO_COLOR" 1 "$([ "$(FX_NO_COLOR=1 ptyn fx --by account --color always $W)" -gt 0 ] && echo 1 || echo 0)"
  cat >"$ROOT/narrow.sh" <<NARROW
stty cols 70
exec bash "$TU" "\$@"
NARROW
  out=$(FX_PTY=1 FX_COLUMNS= FX_TU="$ROOT/narrow.sh" fx --by account,project --color never $W)
  ok "with no COLUMNS the width of the terminal is used" "$(FX_COLUMNS=70 fx --by account,project --color never $W)" "$out"
fi

# ---------------------------------------------------------------------------
t "25. the summary: dollars, the accounts, named sessions"
# ---------------------------------------------------------------------------
# The summary reads the clock, so its rows are placed by their age: half an hour
# (inside five hours), twenty hours (inside 24), five days (inside seven) and
# ten days (outside). Dollars by hand: opus-5 is 5/25 and sonnet-5 2/10 per
# million, haiku-4-5 1/5. work: 1M in and 100k out on opus is 7.50, then 2M in
# on opus is 10.00. personal: 1M in and 400k out on sonnet is 6.00. The session
# no account claims: 1M in on haiku is 1.00.

F5="$ROOT/fx5"; mkdir -p "$F5/usage"
now5=$(( $(date +%s) / 300 * 300 ))
f5row() {  # <age in seconds> <project> <sid first 8> <model> <requests> <input> <output> <context>
  printf '%s\t-h-%s\t%s\t-\t-\t-\tclaude-%s\t%s\t%s\t0\t0\t0\t%s\t%s\t%s\n' \
    "$(( now5 - $1 ))" "$2" "$(fxsid "$3")" "$4" "$5" "$6" "$7" "$8" "$8"
}
{ f5row 1800   x 3f9a1c20 opus-5    5 1000000 100000 612000
  f5row 72000  y d8c3b615 sonnet-5  7 1000000 400000 388000
  f5row 432000 x 3f9a1c20 opus-5   11 2000000 0      612000
  f5row 432000 z 7b2c5d33 haiku-4-5 3 1000000 0      50000
  f5row 864000 x 3f9a1c20 opus-5   13 10000000 0     612000
} >"$F5/usage/facts.tsv"
printf -- '-h-x\t%s/git/work/billing-api\n-h-y\t%s/git/personal/tagents\n-h-z\t%s/scratch/probe\n' "$FXH" "$FXH" "$FXH" >"$F5/usage/projects.tsv"
printf '%s\t%s\n' "$(fxsid 3f9a1c20)" "$FXH/git/work/billing-api" "$(fxsid d8c3b615)" "$FXH/git/personal/tagents" \
  "$(fxsid 7b2c5d33)" "$FXH/scratch/probe" >"$F5/usage/origin.tsv"
TA25="$ROOT/ta25"; mkdir -p "$TA25"
printf '%s\t%s\n' "$(fxsid 3f9a1c20)" "refactor-billing" >"$TA25/labels.tsv"
fx5() { FX_STATE="$F5/usage" FX_TA="$TA25" fx "$@" | sed "s/${ESC}\\[[0-9;]*m//g"; }
squash() { awk '{ $1 = $1; print }'; }  # one space between the words of a line

out=$(fx5)
ok "the five hours: cost units, dollars and requests" "1.5M \$7.50 5" "$(printf '%s\n' "$out" | awk '/^last 5 h/ { print $4, $5, $6 }')"
ok "the 24 hours" "4.5M \$13.5 12" "$(printf '%s\n' "$out" | awk '/^last 24 h/ { print $4, $5, $6 }')"
ok "the seven days: the ten-day-old row is not in it" "7.5M \$24.5 26" "$(printf '%s\n' "$out" | awk '/^last 7 d/ { print $4, $5, $6 }')"
ok "the five hours keep the peak context" "peak ctx 612k" "$(printf '%s\n' "$out" | awk '/^last 5 h/ { print $8, $9, $10 }')"
ok "the seven days by account: dollars and share, the dearest first, the unplaced one named" \
   "work \$17.5 71.4%
personal \$6.00 24.5%
? unplaced \$1.00 4.1%" \
   "$(printf '%s\n' "$out" | awk '/^by account/ { f = 1; next } f && /^$/ { exit } f' | squash)"
lineof() { printf '%s\n' "$out" | grep -n "^$1" | head -1 | cut -d: -f1; }
ok "...between the windows and where it goes" 1 \
   "$([ "$(lineof 'last 7 d')" -lt "$(lineof 'by account')" ] && [ "$(lineof 'by account')" -lt "$(lineof 'where it goes')" ] && echo 1 || echo 0)"

out=$(fx5 --account work)
lacks "one account has no account block" "by account" "$out"
ok "--account work narrows the windows" "\$17.5 16" "$(printf '%s\n' "$out" | awk '/^last 7 d/ { print $5, $6 }')"
out=$(fx5 --account personal)
ok "--account personal narrows them too" "\$6.00 7" "$(printf '%s\n' "$out" | awk '/^last 7 d/ { print $5, $6 }')"
ok "--account ? is the sessions no account claims" "\$1.00 3" "$(fx5 --account '?' | awk '/^last 7 d/ { print $5, $6 }')"
ok "two accounts named is two accounts in the block" "work|personal" \
   "$(fx5 --account work,personal | awk '/^by account/ { f = 1; next } f && /^$/ { exit } f { printf "%s%s", (n++ ? "|" : ""), $1 }')"

# An account whose only usage is older than seven days is not in the week.
F5B="$ROOT/fx5b"; mkdir -p "$F5B/usage"
{ f5row 1800 x 3f9a1c20 opus-5 5 1000000 100000 612000
  f5row 864000 y d8c3b615 sonnet-5 7 1000000 400000 388000
} >"$F5B/usage/facts.tsv"
cp "$F5/usage/projects.tsv" "$F5B/usage/projects.tsv"
out=$(FX_STATE="$F5B/usage" FX_TA="$TA25" fx)
lacks "an account with no usage in the week is no second account" "by account" "$out"

# A request on a model with no rate is a floor, and the summary says so.
F5C="$ROOT/fx5c"; mkdir -p "$F5C/usage"
{ f5row 1800 x 3f9a1c20 opus-5 5 1000000 100000 612000
  f5row 72000 y d8c3b615 mystery-9 2 1000000 0 100
} >"$F5C/usage/facts.tsv"
cp "$F5/usage/projects.tsv" "$F5C/usage/projects.tsv"
out=$(FX_STATE="$F5C/usage" FX_TA="$TA25" fx | sed "s/${ESC}\\[[0-9;]*m//g")
ok "a window with an unrated request marks its dollars" "\$7.50 5|\$7.50* 7" \
   "$(printf '%s\n' "$out" | awk '/^last 5 h/ { a = $5 " " $6 } /^last 24 h/ { b = $5 " " $6 } END { print a "|" b }')"
contains "...and says the figure is a floor" "* marks dollars that are a floor" "$out"
lacks "a summary with every model rated has no such note" "marks dollars that are a floor" "$(fx5)"

# The heaviest sessions: the name, then eight characters of the id.
ok "a named session shows its name and eight characters of its id, a plain one its id alone" \
   "refactor-billing 3f9a1c20 3.5M 16 req ctx 612k sub 0 ~/git/work/billing-api
d8c3b615 3.0M 7 req ctx 388k sub 0 ~/git/personal/tagents
7b2c5d33 1.0M 3 req ctx 50k sub 0 ~/scratch/probe" \
   "$(fx5 | sed '1,/^heaviest sessions/d' | squash)"
lacks "an id is cut at eight characters" "d8c3b615-" "$(fx5)"
idcol() {  # <id>: the column, in characters, where the id starts on each line that holds it
  LC_ALL=C awk -v id="$1" 'index($0, id) { p = substr($0, 1, index($0, id) - 1); n = 0
    for (i = 1; i <= length(p); i++) { c = substr(p, i, 1); if (c < "\200" || c > "\277") n++ }; print n }'
}
printf '%s\t%s\n' "$(fxsid 3f9a1c20)" "refactor-billing" "$(fxsid 7b2c5d33)" "Счёт для клиента" >"$TA25/labels.tsv"
rows=$(fx5 | sed '1,/^heaviest sessions/d')
ok "the ids of the heaviest sessions start in one column, names in Cyrillic included" "1" \
   "$({ printf '%s\n' "$rows" | idcol 3f9a1c20; printf '%s\n' "$rows" | idcol d8c3b615; printf '%s\n' "$rows" | idcol 7b2c5d33; } | sort -u | wc -l | tr -d ' ')"
contains "a Cyrillic name is whole" "Счёт для клиента  7b2c5d33" "$rows"
printf '%s\t%s\n' "$(fxsid 3f9a1c20)" "$(printf 'a%.0s' $(seq 1 60))" >"$TA25/labels.tsv"
ok "a name longer than 28 characters is cut with an ellipsis" "$(printf 'a%.0s' $(seq 1 27))…" \
   "$(fx5 | sed '1,/^heaviest sessions/d' | sed -n 1p | squash | cut -d' ' -f1)"
printf '%s\t%s\n' "$(fxsid 3f9a1c20)" "refactor-billing" >"$TA25/labels.tsv"

# What stays as it is.
ok "no index at all still exits 1 with the old words" "tusage: no data yet — run 'tusage --rebuild'|1" \
   "$(FX_STATE="$ROOT/fx5-none" fx 2>&1 | tr -d '\n')|$(FX_STATE="$ROOT/fx5-none" fxrc)"
F5D="$ROOT/fx5d"; mkdir -p "$F5D/usage"
f5row 864000 x 3f9a1c20 opus-5 5 1000000 100000 612000 >"$F5D/usage/facts.tsv"
cp "$F5/usage/projects.tsv" "$F5D/usage/projects.tsv"
out=$(FX_STATE="$F5D/usage" FX_TA="$TA25" fx | sed "s/${ESC}\\[[0-9;]*m//g")
contains "an empty week still says so" "nothing in the last 7 days" "$out"
lacks "...and has no account block" "by account" "$out"
ok "...and a dollar figure of nothing" "\$0 0" "$(printf '%s\n' "$out" | awk '/^last 7 d/ { print $5, $6 }')"


# ---------------------------------------------------------------------------
t "26. a name is text: no control character reaches the terminal"
# ---------------------------------------------------------------------------
# A name comes from three places (a typed label, the cached title, the title in the
# transcript) and every one of them can hold an escape sequence. The summary, the
# listing on standard error and a table all print it, so the name is scrubbed once,
# where it is produced.

F26="$ROOT/fx26"; mkdir -p "$F26/usage" "$FX/projects/-h-z"
cp "$F5/usage/facts.tsv" "$F5/usage/projects.tsv" "$F5/usage/origin.tsv" "$F26/usage/"
LC_ALL=C awk -F'\t' -v OFS='\t' '{ if (!($3 in F) || $1 < F[$3]) F[$3] = $1; if ($1 > L[$3]) L[$3] = $1; S[$3] = $2; M[$3] = $7 }
  END { for (s in F) print s, S[s], F[s], L[s], M[s] }' "$F26/usage/facts.tsv" >"$F26/usage/sessions.tsv"
EVIL=$(printf '\033[2J\033]0;x\007')
TA26="$ROOT/ta26"; mkdir -p "$TA26"
printf '%s\t%s\n' "$(fxsid 3f9a1c20)" "typed${EVIL}label" >"$TA26/labels.tsv"
printf '%s\t%s\t%s\n' "$(fxsid d8c3b615)" "cached${EVIL}title" 1 >"$TA26/title.tsv"
printf '%s\n' '{"type":"ai-title","aiTitle":"from\u001b[2J\u001b]0;x\u0007transcript"}' >"$FX/projects/-h-z/$(fxsid 7b2c5d33).jsonl"
touch "$F26/usage/projects.tsv"
fx26() { FX_STATE="$F26/usage" FX_TA="$TA26" fx "$@" | sed "s/${ESC}\\[[0-9;]*m//g"; }
ncntrl() { LC_ALL=C tr -d '\n' | LC_ALL=C tr -cd '\001-\037\177' | wc -c | tr -d ' '; }

out=$(fx26)
ok "the summary prints no control character from a typed, a cached or a transcript title" 0 "$(printf '%s\n' "$out" | ncntrl)"
contains "...and the name is kept without them" "typed[2J]0;xlabel" "$out"
contains "...in the cached title too" "cached[2J]0;xtitle" "$out"
contains "...and in the title read from the transcript" "from[2J]0;xtranscript" "$out"

out=$(fx26 --session '0;x')
ok "an ambiguous --session lists the sessions on standard error and exits 3" 3 "$(FX_STATE="$F26/usage" FX_TA="$TA26" fxrc --session '0;x')"
ok "...the list has no control character either" 0 "$(printf '%s\n' "$out" | ncntrl)"
ok "...and three sessions are in it" 3 "$(printf '%s\n' "$out" | grep -c -- '-6d4e-4b0a')"

out=$(fx26 --by session --top 0 --since 1000d)
ok "a --by session table prints none" 0 "$(printf '%s\n' "$out" | ncntrl)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
