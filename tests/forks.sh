#!/usr/bin/env bash
#
# tests/forks.sh — how many programs one repaint starts, and that it does not
# grow with the amount of state on disk.
#
# The status bar runs `tagents --counts` about once a second and the refresher
# runs `tagents --list` every two, so the number of processes one run starts is
# paid for hundreds of times a minute, and the endpoint security agent inspects
# every one of them. What used to happen is that each record in model/, sub/ and
# the state directory got an awk of its own, and each cfg_get another, so the bill
# grew with the number of sessions and of config keys. What is asserted here is
# the shape of it rather than a number: the same count of awk with 2 records as
# with 40, and the same with 3 config keys as with 30.
#
# Programs are counted through shims first on $PATH: each appends one line to a
# counter file and then execs the real program, found on the PATH as it was
# before the shim went on. The shims are on the PATH of the measured runs ONLY.
#
# NOTHING HERE MAY TOUCH THE USER'S TMUX SERVER: $TMUX names a socket that does
# not exist, so every tmux call tagents makes fails at once (the same safety net
# tests/headless.sh puts under its hook half), and $HOME is moved into the temp
# root.
#
# bash 3.2, runnable from any cwd, non-zero exit on any failing check.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# A suite that is not run against a scratch default server aborts here, before it can reach the live one (tests/scratch-guard.sh).
. "$HERE/scratch-guard.sh" && scratch_guard forks.sh || exit 1
TA="$HERE/../tagents"

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tagents-forks.XXXXXX") || exit 1
ROOT=$(cd "$ROOT" && pwd -P) || exit 1
trap 'rm -rf "$ROOT"' EXIT INT TERM

pass=0; fail=0
ok()   { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
         else fail=$((fail+1)); printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"; fi; }
has()  { case "$3" in *"$2"*) pass=$((pass+1)); printf '  ok   %s\n' "$1" ;;
         *) fail=$((fail+1)); printf '  FAIL %s\n       expected to contain: %s\n       actual: %s\n' "$1" "$2" "$3" ;; esac; }
le()   { if [ "$3" -le "$2" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
         else fail=$((fail+1)); printf '  FAIL %s\n       expected at most: %s\n       actual:   %s\n' "$1" "$2" "$3"; fi; }
t()    { printf '\n%s\n' "$1"; }

TAB=$(printf '\t')

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------
SHIM="$ROOT/shim";   mkdir -p "$SHIM"
CNT="$ROOT/cnt";     mkdir -p "$CNT"
STATE="$ROOT/state"
HOMED="$ROOT/home";  mkdir -p "$HOMED"
PROJ="$ROOT/proj";   mkdir -p "$PROJ"

for p in awk hostname; do
  real=$(command -v "$p") || { echo "forks.sh: no $p"; exit 1; }
  printf '#!/bin/sh\necho x >>"%s/%s"\nexec "%s" "$@"\n' "$CNT" "$p" "$real" >"$SHIM/$p"
  chmod +x "$SHIM/$p"
done

export HOME="$HOMED"
export TMUX="$ROOT/no-such-socket,1,0"
export TA_STATE_DIR="$STATE"
export TA_CONFIG="$ROOT/absent.yaml"
export TA_COLS=120
export TA_COUNTS_EVERY=0   # measure the uncached --counts; the cache has its own check below
unset TA_HOST FZF_COLUMNS TMUX_PANE

NOW=$(date +%s)

fresh() { rm -rf "$STATE"; mkdir -p "$STATE/model" "$STATE/sub" "$STATE/prompt"; : >"$STATE/origin.tsv"; }
add_models() {  # <n>
  local i
  for i in $(seq 1 "$1"); do
    printf 'x\tclaude-opus-%s\ty\tOpus %s\n' "$i" "$i" >"$STATE/model/sid-$i.tsv"
  done
}
# Pane-less records, with the session ids in origin.tsv so that the cached path
# is the one measured.
add_states() {  # <n>
  local i
  for i in $(seq 1 "$1"); do
    printf '%s\tworking\tsid-%s\t%s\t\t\t\t0\t\tlabel %s\n' "$NOW" "$i" "$PROJ" "$i" \
      >"$STATE/s-sid-$i.tsv"
    printf 'sid-%s\t%s\n' "$i" "$PROJ" >>"$STATE/origin.tsv"
  done
}
add_subs() {  # <n>
  local i
  for i in $(seq 1 "$1"); do
    printf 'worker\tworking\n' >"$STATE/sub/$((100 + i))"
  done
}
config_of() {  # <n keys> -> path
  local f="$ROOT/config-$1.yaml" i
  : >"$f"
  for i in $(seq 1 "$1"); do printf 'key%s: value%s\n' "$i" "$i" >>"$f"; done
  printf '%s' "$f"
}

# How many times <prog> was started by one run of tagents <verb>.
starts() {  # <prog> <verb…>
  local prog=$1; shift
  : >"$CNT/awk"; : >"$CNT/hostname"
  PATH="$SHIM:$PATH" "$TA" "$@" >/dev/null 2>&1
  wc -l <"$CNT/$prog" | tr -d ' '
}
# The throttles in --counts (window names, resurrect, the config verdict) fire on
# the first run and rest on the next, so one run is spent on them before the
# measured one, and the background jobs they start are given a moment to end.
settle() { PATH="$SHIM:$PATH" "$TA" "$@" >/dev/null 2>&1; sleep 1; }

# ---------------------------------------------------------------------------
t "--list: awk starts do not grow with the records in model/"
fresh; add_models 2;  settle --list; a=$(starts awk --list)
fresh; add_models 40; settle --list; b=$(starts awk --list)
ok "40 model records start as many awk as 2" "$a" "$b"

t "--list: awk starts do not grow with the state records"
fresh; add_states 2; settle --list; a=$(starts awk --list)
fresh; add_states 6; settle --list; b=$(starts awk --list)
ok "6 state records start as many awk as 2" "$a" "$b"

t "--list: awk starts do not grow with the files in sub/"
fresh; add_subs 2; settle --list; a=$(starts awk --list)
fresh; add_subs 6; settle --list; b=$(starts awk --list)
ok "6 sub files start as many awk as 2" "$a" "$b"

# ---------------------------------------------------------------------------
t "--counts: the config is read once per process"
# One hostname belongs to list itself (its own host column); the overlay lookup
# in cfg_overlay is the other, and only that one is the config's.
fresh; add_states 2
export TA_CONFIG; TA_CONFIG=$(config_of 3)
settle --counts; a=$(starts awk --counts); h=$(starts hostname --counts)
TA_CONFIG=$(config_of 30)
settle --counts; b=$(starts awk --counts)
ok "30 config keys start as many awk as 3" "$a" "$b"
le "hostname is started once for the whole process (list and overlay share it)" 1 "$h"

# ---------------------------------------------------------------------------
t "the records still come out"
export TA_CONFIG="$ROOT/absent.yaml"
fresh; add_models 2; add_states 2
out=$("$TA" --flat 2>&1)
n=1
for n in 1 2; do
  row=$(printf '%s\n' "$out" | grep "^%s-sid-$n$TAB" | head -1)
  # Captured from the code as it was before the fork count was cut: the S record
  # (pane key, label, directory taken from the origin cache, session id) and the
  # M record (the model normalised to opus<n>) both reach the row.
  has "record $n: row of the pane-less session" "%s-sid-$n$TAB" "$row"
  has "record $n: label from the state record" "label $n" "$row"
  has "record $n: model from model/" "opus$n" "$row"
  has "record $n: headless, ended" "headless, ended" "$row"
  has "record $n: session id and origin directory" "sid-$n$TAB$PROJ" "$row"
done

# ---------------------------------------------------------------------------
t "--counts: reused for COUNTS_EVERY seconds, recomputed once the stamp is gone"
unset TA_COUNTS_EVERY
fresh; add_states 2
settle --counts
c1=$(PATH="$SHIM:$PATH" "$TA" --counts 2>/dev/null)
a=$(starts awk --counts)
c2=$(PATH="$SHIM:$PATH" "$TA" --counts 2>/dev/null)
ok "two runs inside the interval print the same bytes" "$c1" "$c2"
le "the cached run starts at most 3 awk" 3 "$a"
rm -f "$STATE/.counts.ts"
b=$(starts awk --counts)
ok "after the stamp is removed the run recomputes (starts more awk than the cached one)" 1 "$(( b > a ? 1 : 0 ))"
export TA_COUNTS_EVERY=0

# ---------------------------------------------------------------------------
t "a record that cannot be read does not take the ones after it down"
export TA_CONFIG="$ROOT/absent.yaml"
fresh; add_models 3; add_states 3; add_subs 3
chmod 000 "$STATE/model/sid-2.tsv" "$STATE/s-sid-2.tsv" "$STATE/sub/102"
out=$("$TA" --flat 2>&1)
chmod 600 "$STATE/model/sid-2.tsv" "$STATE/s-sid-2.tsv" "$STATE/sub/102"
row=$(printf '%s\n' "$out" | grep "^%s-sid-3$TAB" | head -1)
has "record 3: row of the pane-less session" "%s-sid-3$TAB" "$row"
has "record 3: model from model/" "opus3" "$row"
ok "no awk error reaches the output" 0 "$(printf '%s\n' "$out" | grep -c "can't open")"
export TA_CONFIG="$ROOT/absent.yaml"
export TA_COUNTS_EVERY=0

# ---------------------------------------------------------------------------
t "--counts: an interval that is not a number falls back to the default, not to never"
export TA_CONFIG="$ROOT/absent.yaml"
fresh; add_states 2
want=$(TA_COUNTS_EVERY=0 "$TA" --counts 2>/dev/null)
rm -f "$STATE/.counts.ts" "$STATE/.counts.out"
got=$(TA_COUNTS_EVERY=abc "$TA" --counts 2>/dev/null)
ok "the counts are not empty" 1 "$([ -n "$want" ] && echo 1 || echo 0)"
ok "TA_COUNTS_EVERY=abc still prints the counts" "$want" "$got"
export TA_CONFIG="$ROOT/absent.yaml"
export TA_COUNTS_EVERY=0

# ---------------------------------------------------------------------------
t "--list: repo_root is not a command substitution per directory"
# A $(...) is a fork even when it calls only a function. Measured on an xtrace of
# the whole run: bash doubles the leading + of a line that runs inside $(...), so
# the lines of dir_roots that begin with ++ are the forks dir_roots makes.
fresh
for i in 1 2 3; do
  mkdir -p "$ROOT/rr$i/.git" "$ROOT/rr$i/pkg"
  printf '%s\tworking\tsid-%s\t%s\t\t\t\t0\t\tlabel %s\n' "$NOW" "$i" "$ROOT/rr$i/pkg" "$i" >"$STATE/s-sid-$i.tsv"
  printf 'sid-%s\t%s\n' "$i" "$ROOT/rr$i/pkg" >>"$STATE/origin.tsv"
done
xt="$ROOT/xtrace.log"
PS4='+${BASH_SUBSHELL}|${FUNCNAME[0]:-}| ' bash -x "$TA" --list >/dev/null 2>"$xt"
ok "dir_roots forks nothing for 3 directories" 0 "$(grep -c '^++[0-9]*|dir_roots| repo_root' "$xt")"
ok "dir_roots still walked 3 directories" 3 "$(grep -c '^+[0-9]*|dir_roots| repo_root' "$xt")"

# The modules are loaded the way the entry point loads them, because that is the only way to reach a function.
LIBD="$HERE/../lib/tagents"
FN_MODS=$(sed -n '/for ta_mod in/,/; do/p' "$TA" | sed 's/.*for ta_mod in//; s/; do.*//' | tr -d '\\' | tr -s ' \n' '  ')
fn() {  # <code> — runs it with the modules loaded and the config read
  SELF="$TA" FN_LIB="$LIBD" FN_MODS="$FN_MODS" /bin/bash -c \
    'set -uo pipefail; for m in $FN_MODS; do . "$FN_LIB/$m.sh"; done; cfg_load; eval "$1"' fn "$1"
}

# ---------------------------------------------------------------------------
t "--list: names that differ only in a Cyrillic letter are different names"
# ---------------------------------------------------------------------------
# Under a UTF-8 locale macOS awk and sort weigh every Cyrillic letter alike, so "я" and "ю" were one name to them and two directories shared a line of `sort -u`: the second was never found under its repository. A group is a session now (tests/window-rows.sh L9 pins two sessions named that way); what is left of the rule here is the directory scan that feeds the subdirectory drawn before a row's detail.
cy_fn() { ( unset LC_ALL; export LANG=en_US.UTF-8; fn "$1" ) 2>/dev/null; }
fresh
mkdir -p "$ROOT/dr/я/.git" "$ROOT/dr/я/src" "$ROOT/dr/ю/.git" "$ROOT/dr/ю/src"
for i in 1 2; do
  case $i in 1) d="$ROOT/dr/я/src" ;; *) d="$ROOT/dr/ю/src" ;; esac
  printf '%s\tworking\tdr-%s\t%s\t\t\t\t0\t\tlabel %s\n' "$NOW" "$i" "$d" "$i" >"$STATE/s-dr-$i.tsv"
  printf 'dr-%s\t%s\n' "$i" "$d" >>"$STATE/origin.tsv"
done
roots=$(cy_fn dir_roots)
ok "two directories that differ only in a Cyrillic letter are both found" 2 "$(printf '%s\n' "$roots" | grep -c '^R')"
has "...the first under its own repository"  "$ROOT/dr/я/src$TAB$ROOT/dr/я" "$roots"
has "...and the second under its own"        "$ROOT/dr/ю/src$TAB$ROOT/dr/ю" "$roots"

# ---------------------------------------------------------------------------
t "--list: the questions to tmux do not grow with the chats"
TSHIM="$ROOT/tshim"; mkdir -p "$TSHIM"
printf '#!/bin/sh\necho "$*" >>"%s/tmux"\n' "$CNT" >"$TSHIM/tmux"; chmod +x "$TSHIM/tmux"
fresh; add_states 2;  : >"$CNT/tmux"
PATH="$TSHIM:$PATH" "$TA" --list >/dev/null 2>&1; n2=$(wc -l <"$CNT/tmux" | tr -d ' ')
fresh; add_states 20; : >"$CNT/tmux"
PATH="$TSHIM:$PATH" "$TA" --list >/dev/null 2>&1; n20=$(wc -l <"$CNT/tmux" | tr -d ' ')
ok "twenty chats ask tmux as often as two" "$n2" "$n20"
ok "...and nothing is asked about seats" 0 "$(grep -c -E 'tagents_slot|tagents_docked|tagents_parked' "$CNT/tmux")"

# ---------------------------------------------------------------------------
t "--sync-names: awk starts do not grow with the state files"
export TA_CONFIG="$ROOT/absent.yaml"
fresh; add_states 2; a=$(starts awk --sync-names)
fresh; add_states 6; b=$(starts awk --sync-names)
ok "6 state files start as many awk as 2" "$a" "$b"

# ---------------------------------------------------------------------------
t "--counts: a cached run does not parse the config"
unset TA_COUNTS_EVERY
export TA_CONFIG
TA_CONFIG=$(config_of 3)
fresh; add_states 2
settle --counts
h=$(starts hostname --counts)
ok "the cached run starts no hostname" 0 "$h"
export TA_CONFIG="$ROOT/absent.yaml"
export TA_COUNTS_EVERY=0

# ---------------------------------------------------------------------------
t "the tally: list() counts it once, by the rule the status bar used to apply"
# THE ORACLE IS THE OLD PIPELINE, kept here word for word: `TA_MARKS=0 list`
# through an awk of its own that skipped every row with the header marker in its
# second field and counted the third. The rule now lives in list()'s last awk,
# and what comes out of it has to be what this prints.
ORACLE='
  index($2, "\342\226\276") > 0 { next }
  { n[$3]++ }
  END {
    out = ""
    if (n["blocked"]) out = out sprintf("#[fg=yellow]⚠%d ", n["blocked"])
    if (n["done"])    out = out sprintf("#[fg=cyan]✓%d ",   n["done"])
    if (n["working"]) out = out sprintf("#[fg=green]●%d ",  n["working"])
    printf "%s#[default]", out
  }'
# Live pane-less sessions: the recorded pid is this shell, which is alive, so the
# rows are blocked, done and working and not ended. <state>:<project> each.
add_live() {
  local spec i=0 st d
  for spec in "$@"; do
    i=$((i + 1)); st=${spec%%:*}; d="$ROOT/proj-${spec#*:}"; mkdir -p "$d"
    printf '%s\t%s\tsid-%s\t%s\t\t\t\t%s\t\tlabel %s\n' "$NOW" "$st" "$i" "$d" "$$" "$i" \
      >"$STATE/s-sid-$i.tsv"
    printf 'sid-%s\t%s\n' "$i" "$d" >>"$STATE/origin.tsv"
  done
}
export TA_CONFIG="$ROOT/absent.yaml"
for mode in grouped flat; do
  fresh; add_live blocked:1 done:1 working:2 working:2 blocked:3 done:3 working:3
  if [ "$mode" = flat ]; then export TA_FLAT=1; else unset TA_FLAT; fi
  TA_MARKS=0 "$TA" --list 2>/dev/null | awk -F"$TAB" "$ORACLE" >"$ROOT/old.tally"
  TA_MARKS=0 TA_TALLY=1 "$TA" --list >"$ROOT/new.tally" 2>/dev/null
  has "$mode: the fixture has blocked, done and working rows" "⚠2 " "$(cat "$ROOT/old.tally")"
  if [ "$mode" = grouped ]; then
    has "grouped: the fixture has group headers" "▾" "$(TA_MARKS=0 "$TA" --list 2>/dev/null)"
  fi
  cmp -s "$ROOT/old.tally" "$ROOT/new.tally"
  ok "$mode: TA_TALLY=1 prints exactly what the old awk printed" 0 "$?"
  rm -f "$STATE/.counts.tally"
  "$TA" --list >/dev/null 2>&1
  cmp -s "$ROOT/old.tally" "$STATE/.counts.tally"
  ok "$mode: a marks-on --list leaves the same bytes in .counts.tally" 0 "$?"
  ok "$mode: ...and no temp file behind it" 0 "$(ls -A "$STATE" | grep -c '^\.counts\.tally\.')"
  rm -f "$STATE/.counts.tally"
  TA_MARKS=0 "$TA" --list >/dev/null 2>&1
  ok "$mode: a list without marks (the status bar's) leaves no tally" no "$([ -e "$STATE/.counts.tally" ] && echo yes || echo no)"
  TA_TALLY=1 "$TA" --list >/dev/null 2>&1
  ok "$mode: nor does one that only wants the tally" no "$([ -e "$STATE/.counts.tally" ] && echo yes || echo no)"
done
unset TA_FLAT
fresh
TA_MARKS=0 "$TA" --list 2>/dev/null | awk -F"$TAB" "$ORACLE" >"$ROOT/old.tally"
TA_MARKS=0 TA_TALLY=1 "$TA" --list >"$ROOT/new.tally" 2>/dev/null
cmp -s "$ROOT/old.tally" "$ROOT/new.tally"
ok "no sessions: both print the bare reset" 0 "$?"
"$TA" --list >/dev/null 2>&1
ok "...and the marks-on list leaves it in .counts.tally" "#[default]" "$(cat "$STATE/.counts.tally" 2>/dev/null)"

# ---------------------------------------------------------------------------
t "--counts: the pieces the refresher keeps compose to exactly what counts_now prints"
# The two functions are called in a bash that has loaded the modules the way the
# entry point loads them, because that is the only way to reach a function.
printf 'usage:\n  monthly_limit_usd: abc\n' >"$ROOT/cfgbad.yaml"
for cf in "$ROOT/absent.yaml" "$ROOT/cfgbad.yaml"; do
  export TA_CONFIG=$cf
  fresh; add_live blocked:1 done:1 working:2
  fn 'counts_now' >"$ROOT/now.out" 2>/dev/null
  fn 'counts_parts; tl=$(TA_MARKS=0 TA_TALLY=1 list; printf .); counts_compose "${tl%.}"' \
    >"$ROOT/compose.out" 2>/dev/null
  cmp -s "$ROOT/now.out" "$ROOT/compose.out"
  ok "${cf##*/}: counts_compose of counts_parts and the tally is counts_now, byte for byte" 0 "$?"
  has "${cf##*/}: ...and it is not empty" "⚠1 " "$(cat "$ROOT/now.out")"
done
has "a config with a problem keeps its marker in front" "cfg!1 " "$(cat "$ROOT/now.out")"
export TA_CONFIG="$ROOT/absent.yaml"

# ---------------------------------------------------------------------------
t "--counts: a cached run starts one program, date, and prints the cache as it is"
ALLSHIM="$ROOT/allshim"; mkdir -p "$ALLSHIM"
for p in awk basename cat chmod cp cut date dirname env find grep head hostname id kill ln ls \
         mkdir mktemp mv ps readlink rm sed sleep sort stat tail tee touch tr tmux uname wc xargs tusage; do
  real=$(command -v "$p" 2>/dev/null) || continue
  printf '#!/bin/sh\necho %s >>"%s/all"\nexec "%s" "$@"\n' "$p" "$CNT" "$real" >"$ALLSHIM/$p"
  chmod +x "$ALLSHIM/$p"
done
unset TA_COUNTS_EVERY
fresh
# Trailing newlines on purpose: the bar's text can end in them (a usage line does).
printf '#[fg=green]●3 #[default]\n\n' >"$STATE/.counts.out"
printf '%s\n' "$(date +%s)" >"$STATE/.counts.ts"
: >"$CNT/all"
PATH="$ALLSHIM:$PATH" /bin/bash "$TA" --counts >"$ROOT/cached.out" 2>/dev/null
ok "the programs one cached --counts starts" "date" "$(tr '\n' ' ' <"$CNT/all" | sed 's/ $//')"
cmp -s "$STATE/.counts.out" "$ROOT/cached.out"
ok "...and what it prints is the cache, byte for byte" 0 "$?"

# WHILE A REFRESHER IS ALIVE THE CACHE IS TRUSTED, whatever the stamp says: the
# refresher waits for events and no longer stamps every few seconds, so an old stamp
# is a quiet dashboard and not a dead one (see counts in list.sh). A bar still running
# the old status-right line would otherwise count the whole list again every
# COUNTS_EVERY seconds. The marker is the refresher's own start file, named by its pid.
t "--counts: with a refresher alive the cache is printed whatever its age, and nothing is started"
printf '%s\n' 1000 >"$STATE/.counts.ts"
sleep 300 & LIVE=$!
: >"$STATE/.refresher.$LIVE.start"
: >"$CNT/all"
PATH="$ALLSHIM:$PATH" /bin/bash "$TA" --counts >"$ROOT/alive.out" 2>/dev/null
ok "no program at all, though the stamp is from 1970" "" "$(tr '\n' ' ' <"$CNT/all" | sed 's/ $//')"
cmp -s "$STATE/.counts.out" "$ROOT/alive.out"
ok "...and what it prints is the cache, byte for byte" 0 "$?"
ok "...and the stamp is left where it was" "1000" "$(cat "$STATE/.counts.ts")"
# The marker of a refresher that is gone is not one: the age test is what applies.
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
: >"$CNT/all"
PATH="$ALLSHIM:$PATH" /bin/bash "$TA" --counts >/dev/null 2>&1
has "a marker whose pid is dead does not count: the bar counts for itself again" "date" "$(tr '\n' ' ' <"$CNT/all")"
rm -f "$STATE"/.refresher.*
export TA_COUNTS_EVERY=0

# ---------------------------------------------------------------------------
t "due_every: the stamp is read without a program, and a bad stamp reads as old"
fresh
printf '%s\n' "$(date +%s)" >"$STATE/.names.ts"
: >"$CNT/all"
PATH="$ALLSHIM:$PATH" fn 'due_every "$STATE_DIR/.names.ts" 30; echo "rc=$?"' >"$ROOT/due.out" 2>/dev/null
ok "a fresh stamp is not due" "rc=1" "$(cat "$ROOT/due.out")"
printf 'junk\n' >"$STATE/.names.ts"
PATH="$ALLSHIM:$PATH" fn 'due_every "$STATE_DIR/.names.ts" 30; echo "rc=$?"' >"$ROOT/due.out" 2>/dev/null
ok "a stamp that is not a number is due" "rc=0" "$(cat "$ROOT/due.out")"
rm -f "$STATE/.names.ts"
PATH="$ALLSHIM:$PATH" fn 'due_every "$STATE_DIR/.names.ts" 30; echo "rc=$?"' >"$ROOT/due.out" 2>&1
ok "no stamp at all is due, with nothing on stderr" "rc=0" "$(cat "$ROOT/due.out")"
ok "...and none of those started a cat" 0 "$(grep -c '^cat$' "$CNT/all")"
ok "...while the shim did log the date calls (so a silent shim cannot pass)" 1 "$([ "$(grep -c '^date$' "$CNT/all")" -ge 1 ] && echo 1 || echo 0)"


# ---------------------------------------------------------------------------
t "dash_pane chooses the list pane by one rule"
# The panes and windows tmux answers with are read from files, so each case sets them. A watcher
# kills the run after 20 seconds, so a wrong answer fails instead of hanging; macOS has no timeout(1).
SL2="$ROOT/sl2"; mkdir -p "$SL2"
cat >"$SL2/tmux" <<'EOF'
#!/bin/sh
echo "$*" >>"$SLDIR/tmux.log"
case "$*" in
  list-panes*) cat "$SLDIR/panes3" ;;
esac
EOF
chmod +x "$SL2/tmux"
export SLDIR="$ROOT/sldir"; mkdir -p "$SLDIR"
sl_run() {  # <code> — runs it as pane %2 under the shim, killed after 20 seconds
  : >"$SLDIR/tmux.log"; : >"$SLDIR/out"
  ( TMUX_PANE=%2 PATH="$SL2:$PATH" fn "$1" >"$SLDIR/out" 2>/dev/null ) &
  sl_pid=$!
  ( sleep 20; pkill -P "$sl_pid" 2>/dev/null; kill "$sl_pid" 2>/dev/null ) >/dev/null 2>&1 &
  sl_wd=$!
  wait "$sl_pid" 2>/dev/null
  kill "$sl_wd" 2>/dev/null; wait "$sl_wd" 2>/dev/null
  return 0
}
printf '%%8 1 2147483000\n%%9 1 %s\n' "$$" >"$SLDIR/panes3"
sl_run 'dash_pane'
ok "dash_pane picks the live pane" "%9" "$(cat "$SLDIR/out")"
ok "...and clears the dead one's marker" 1 "$(grep -c '^set -up -t %8 @tagents_dash' "$SLDIR/tmux.log")"

# ---------------------------------------------------------------------------
t "hostname is started once per process without a config file, even when it fails"
# No config file means cfg_load returns before cfg_overlay, so HOST_S was never set, and a failing
# hostname left HOST_S empty for the ":-" at each use to run it again.
HNSHIM="$ROOT/hnshim"; mkdir -p "$HNSHIM"
printf '#!/bin/sh\necho x >>"%s/hn.count"\nexit 1\n' "$CNT" >"$HNSHIM/hostname"
chmod +x "$HNSHIM/hostname"
fresh; add_states 2
: >"$CNT/hn.count"
TA_CONFIG="$ROOT/absent.yaml" PATH="$HNSHIM:$PATH" fn 'list; list' >/dev/null 2>&1
le "two lists in one process start hostname at most once" 1 "$(wc -l <"$CNT/hn.count" | tr -d ' ')"
: >"$CNT/hn.count"
TA_CONFIG="$ROOT/absent.yaml" PATH="$HNSHIM:$PATH" fn 'sync_window_names; sync_window_names' >/dev/null 2>&1
le "two names sweeps in one process start hostname at most once" 1 "$(wc -l <"$CNT/hn.count" | tr -d ' ')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
