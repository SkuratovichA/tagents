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

# ---------------------------------------------------------------------------
t "--list: the seats are asked once"
TSHIM="$ROOT/tshim"; mkdir -p "$TSHIM"
cat >"$TSHIM/tmux" <<EOF
#!/bin/sh
echo "\$*" >>"$CNT/tmux"
case "\$*" in
  *@tagents_dash*) echo "%1 1 $$" ;;
  "display -p -t %1 #{window_id}") echo @1 ;;
  *tagents_docked*) printf '%%1 - -\n%%2 docked -\n%%3 - free\n' ;;
esac
EOF
chmod +x "$TSHIM/tmux"
fresh; add_states 2
: >"$CNT/tmux"
PATH="$TSHIM:$PATH" "$TA" --list >/dev/null 2>&1
ok "list() starts one list-panes for the seats" 1 "$(grep -c "^list-panes -t .*tagents_slot" "$CNT/tmux")"

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
