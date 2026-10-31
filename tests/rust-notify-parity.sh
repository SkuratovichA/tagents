#!/usr/bin/env bash
#
# tests/rust-notify-parity.sh — `tagents-core notify run` leaves what the node notify daemon (packages/notify) leaves.
#
# Every scenario runs twice through tests/rust-notify-parity-driver.mts, once against `node packages/notify/dist/main.js run` and once against `target/debug/tagents-core notify run` (or $TAGENTS_CORE_BIN), under the same `env -i` environment and on the same scratch state, and passes only when the two transcripts are byte for byte the same once the timestamps and the pids are replaced. A transcript is the daemon's stderr lines (the notify service writes everything there, and nothing to stdout), how it ended, what the stub helper app recorded (its arguments and its stdin, in order), what the tmux shim was asked, and what is left in the state directory (the names in it, the size of the events file, whose the lock is).
# No real program runs: the scratch has its own HOME, TA_STATE_DIR, TAGENTS_CONFIG_DIR, TAGENTS_LOCALE and TMUX_TMPDIR (and TAGENTS_NODE, which is how a Rust daemon that hands over to the node service finds node under `env -i`), PATH is a directory of stubs followed by /usr/bin:/bin (a `tmux` shim that answers what the scenario sets and never starts a server, and a `tagents`), and TA_NOTIFY_APP is a stub helper app that records its arguments and its stdin and answers what the scenario sets. The click action a notice carries is never run. Nothing under the real $HOME, no tmux server, no LaunchAgent, no real helper app and no network is reached, and nothing is started through launchd.
# The notices go to the `log` backend (`backend = "log"` in the options file) wherever the scenario is about the engine, so that a scenario runs on both systems; the scenarios about the helper (`backend = "macos"`) run on macOS only, because `pickPlatform` returns the helper only on darwin, and the suite counts them as skipped elsewhere.
# Every wait is for a condition (the `started` line, a line the daemon writes, a file) and is bounded: a wait that runs out is a `timeout` line of the transcript, and in the node transcript it fails the scenario as a defect of the suite. A fixed pause is used only where the point is that nothing happens, and the scenario says so.
# Differences that are known and listed in docs/architecture/rust-core.md are not scenarios: a file that is not TOML (the reason after `Invalid TOML document:` is the parser's own, so the documents here are all TOML the schema refuses), a document one TOML parser accepts and the other refuses, a symlinked options file whose target is edited (issue #39: node's own test of it is flaky on macOS), a prompt that arrives during a post after the deadline of the same session passed during that post, a stop during a failing start, a failed watch, an options file without read permission, `plugins` being a regular file, the operating system's text inside a line for an error number the two systems do not share, the spawn failure text of the helper for an error other than ENOENT and EACCES, a SIGKILL at a deadline reaching the whole group, and a helper that writes more than 1 MiB. The one known difference that cannot be left out of a scenario, the `handing over to the node service: <why>` line the Rust daemon writes before it becomes node when its start fails, is dropped from the transcript of the scenario about a start that cannot take the state directory (HANDOVER=1), with a comment there.
# Tripwires assert on the node transcript alone, so a scenario that stopped provoking what it exists for fails here instead of passing for nothing.
#
# The first check, before any scenario: the process `<rust> notify run` starts must say it has started and must be the Rust binary. A binary with no `notify` arm hands the verb to the node CLI (front_door.rs, the `None => exec_node` arm), whose process is `node` and which writes no `started` line of the notify service, so the suite would compare node with node. It fails, with that said, and runs no scenario.
# After the last scenario one more run starts the Rust daemon alone and checks its resource use (the processor time of an idle daemon, its threads, the descriptors of its watch and their number across repeated reloads of the options file), because node's numbers are not the reference for those; PARITY_ONLY=resources picks it.
# PARITY_SELF_TEST=1 skips the first check and the resource checks and runs node on both sides: it proves the suite and node's determinism, not the Rust daemon. It is how the suite is proven before the Rust daemon exists and how a change to a scenario is checked for flakiness.
# PARITY_ONLY=<text> runs only the scenarios whose label holds the text, and PARITY_SHOW=<n> prints both transcripts of each, cut at n characters a line. TAGENTS_NODE names the node program. Needs a built node daemon (pnpm build). Exit codes: 0 all passed, 1 a scenario or the first check failed, 2 a prerequisite is missing. bash 3.2.
#   env -u TMUX -u TMUX_PANE bash tests/rust-notify-parity.sh

set -o pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd -P)
NODE=${TAGENTS_NODE:-$(command -v node)}
NOTIFY_JS="$REPO/packages/notify/dist/main.js"
DRIVER="$HERE/rust-notify-parity-driver.mts"
RUST=${TAGENTS_CORE_BIN:-$REPO/target/debug/tagents-core}
SELF_TEST=${PARITY_SELF_TEST:-}
OS=$(uname -s)

[ -n "$NODE" ] && [ -x "$NODE" ] || { echo "rust-notify-parity: no node to run (set TAGENTS_NODE)" >&2; exit 2; }
[ -f "$NOTIFY_JS" ] || { echo "rust-notify-parity: $NOTIFY_JS is not built; run: pnpm install && pnpm build" >&2; exit 2; }
[ -x /bin/ps ] || { echo "rust-notify-parity: no /bin/ps, which the node service reads its lock with" >&2; exit 2; }
if [ -z "$SELF_TEST" ] && [ ! -x "$RUST" ]; then
  if [ -n "${TAGENTS_CORE_BIN:-}" ]; then echo "rust-notify-parity: $RUST is not an executable" >&2; exit 2; fi
  (cd "$REPO" && cargo build -p tagents-core >&2) || { echo "rust-notify-parity: cargo build failed" >&2; exit 2; }
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/tagents-notify-parity.XXXXXX") || exit 2
TMP=$(cd "$TMP" && pwd -P) || exit 2
RUN=$TMP/run        # what a run works in and leaves. One path for both daemons, so no transcript can tell them apart by it.
SHIM=$TMP/shim
APP=$TMP/app/TagentsNotify.app
mkdir "$SHIM" "$TMP/scripts" "$TMP/bin" "$TMP/fixtures" || exit 2
# A run that failed halfway must not leave a daemon or a stub's `sleep` behind: every pid the driver and the stubs noted is killed.
cleanup() {
  local file pid
  for file in "$RUN/daemon.pids" "$RUN/rec/stub.pids"; do
    [ -f "$file" ] || continue
    while read -r pid; do
      case $pid in ''|*[!0-9]*) continue ;; esac
      kill -9 "$pid" 2>/dev/null
    done < "$file"
  done
  chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

pass=0; fail=0; ran=0; skipped=0
ok() { pass=$((pass + 1)); }
bad() {  # <label> <detail...>
  fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; shift
  [ $# -gt 0 ] && printf '       %s\n' "$@"
}
t() { printf '\n%s\n' "$1"; }
TAB=$(printf '\t')

# ----------------------------------------------------------------- stubs ---
# The tmux shim: the daemon's one question is the probe (`display`, `list-clients`, `display`), answered the way rec/tmux.mode says (hidden when it is not there): the pane is in front of a client (shown), in a window no client shows (hidden), with no client at all (noclient), in a nested viewport (viewport), tmux fails (fail), says there is no such pane the old way (nopane) or the tmux 3.7 way (nopane37), prints something that is no answer (garbage), prints what rec/tmux.answer holds, as it is (answer), fails with that on stderr (error), does not answer within the probe's deadline (slow), or answers when rec/release exists (hold). The pane's title is the content of rec/title.<pane>. Every call is recorded in rec/tmux.log.
cat > "$SHIM/tmux" <<'STUB'
#!/bin/sh
R=$PARITY_REC
printf '%s\n' "$*" >> "$R/tmux.log"
[ "$1" = display ] || exit 0
pane=$4
mode=hidden; [ -f "$R/tmux.mode" ] && mode=$(cat "$R/tmux.mode")
title=; [ -f "$R/title.$pane" ] && title=$(cat "$R/title.$pane")
answer() {  # <window of the pane> <window the client shows>
  printf 'P|@|%s|@|%s\n' "$1" "$title"
  [ -n "$2" ] && printf 'C|@|100|@|4242|@|%s|@|/dev/ttys001|@|main\n' "$2"
  printf 'V|@|\n'
}
case $mode in
  shown) answer @1 @1 ;;
  hidden) answer @1 @2 ;;
  noclient) answer @1 '' ;;
  viewport)
    printf 'P|@|@1|@|%s\n' "$title"
    printf 'C|@|100|@|4242|@|@2|@|/dev/ttys001|@|tagents\n'
    printf 'C|@|200|@|4343|@|@1|@|/dev/ttys002|@|other\n'
    printf 'V|@|/dev/ttys002\n' ;;
  fail) echo "no server running on /tmp/parity/default" >&2; exit 1 ;;
  nopane) echo "can't find pane: $pane" >&2; exit 1 ;;
  nopane37) printf 'P|@||@|\n'; printf 'V|@|\n' ;;
  garbage) echo "this is not an answer to the probe" ;;
  answer) cat "$R/tmux.answer" ;;
  error) cat "$R/tmux.answer" >&2; exit 1 ;;
  slow) echo $$ >> "$R/stub.pids"; exec sleep 30 ;;
  hold)
    : > "$R/tmux.held"
    i=0; while [ ! -e "$R/release" ] && [ $i -lt 500 ]; do sleep 0.02; i=$((i + 1)); done
    answer @1 @2 ;;
esac
STUB
# The stub helper app: records the arguments of every call and, for `post`, its stdin, in rec/h.<n>/, and answers what rec/helper.mode says (ok when it is not there): ok, hidden (not shown, and why), noshown (ok and nothing else), extra (fields nobody reads), failed (ok false and an error), failed-bare (ok false and no error), garbage, notanobject, empty, exit3, exit3ok (the right answer and a non-zero exit), badtype, twolines, padded, longgarbage and astral (more than the 200 characters an error quotes, the second of 16-bit pairs) and slow (past the deadline).
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/MacOS/tagents-notify" <<'STUB'
#!/bin/sh
R=$PARITY_REC
n=1; while ! mkdir "$R/h.$n" 2>/dev/null; do n=$((n + 1)); done
printf '%s\n' "$@" > "$R/h.$n/args"
[ "$1" = post ] && cat > "$R/h.$n/stdin"
mode=ok; [ -f "$R/helper.mode" ] && mode=$(cat "$R/helper.mode")
if [ -f "$R/helper.modes" ]; then m=$(sed -n "${n}p" "$R/helper.modes"); [ -z "$m" ] || mode=$m; fi
case $mode in
  ok) printf '{"ok":true,"shown":true}\n' ;;
  hidden) printf '{"ok":true,"shown":false,"why":"the terminal is in front"}\n' ;;
  noshown) printf '{"ok":true}\n' ;;
  extra) printf '{"ok":true,"shown":true,"why":"also","extra":{"a":[1,2]}}\n' ;;
  failed) printf '{"ok":false,"error":"notifications are denied"}\n' ;;
  failed-bare) printf '{"ok":false}\n' ;;
  garbage) printf 'this is not json\n'; echo "and this is stderr" >&2 ;;
  notanobject) printf '[1,2]\n' ;;
  empty) ;;
  exit3) echo "crashed" >&2; exit 3 ;;
  exit3ok) printf '{"ok":true,"shown":true}\n'; exit 3 ;;
  badtype) printf '{"ok":true,"shown":"yes"}\n' ;;
  twolines) printf '{"ok":true,"shown":true}\n{"ok":true,"shown":true}\n' ;;
  padded) printf '  \n {"ok":true,"shown":true} \n\n' ;;
  longgarbage)
    s=; i=0; while [ $i -lt 300 ]; do s="${s}g"; i=$((i + 1)); done
    printf '%s\n' "$s"; printf '%s\n' "$s" | tr g e >&2 ;;
  astral)
    s=a; i=0; while [ $i -lt 150 ]; do s="${s}😀"; i=$((i + 1)); done
    printf '%s\n' "$s"; printf '%s\n' "$s" >&2 ;;
  slow) echo $$ >> "$R/stub.pids"; exec sleep 30 ;;
esac
STUB
mkdir -p "$TMP/no-exec/TagentsNotify.app/Contents/MacOS"
printf '#!/bin/sh\nexit 0\n' > "$TMP/no-exec/TagentsNotify.app/Contents/MacOS/tagents-notify"
printf '#!/bin/sh\nexit 0\n' > "$SHIM/tagents"
chmod +x "$SHIM"/* "$APP/Contents/MacOS/tagents-notify"

# ----------------------------------------------------------- the scenario ---
# What a scenario sets before `play` and `play` puts back: the options file, whether there is a config directory and a plugins directory, whether the options file is there, whether the state directory can be made, the locale (`-` leaves TAGENTS_LOCALE unset), the extra environment, the script `tagents` of a click, whether the helper app is there and whether it can be run.
DEFAULT_OPTS='backend = "log"'
reset_scenario() {
  OPTS=$DEFAULT_OPTS; NOCONFIG=; NOPLUGINS=; NOFILE=; BLOCKSTATE=; HANDOVER=; LOCALE=en; NOAPP=; NOEXEC=
  CLICK_SCRIPT=/parity/bin/tagents
  EXTRA_ENV=()
}
reset_scenario

# The steps of a script, as JSON the driver reads.
steps() { local out= s; for s in "$@"; do out=${out:+$out,}$s; done; printf '[%s]' "$out"; }
# The text as the inside of a JSON string: the backslash, the quote and the newline, tab and carriage return (turned into control bytes the sed can see and back, so a text with a line break in it is one line of the script).
C1=$(printf '\001'); C2=$(printf '\002'); C3=$(printf '\003')
jstr() { printf '%s' "$1" | LC_ALL=C tr '\n\t\r' '\001\002\003' | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$C1/\\\\n/g" -e "s/$C2/\\\\t/g" -e "s/$C3/\\\\r/g"; }
# bash 3.2 brace-expands the comma list of a double-quoted JSON object inside a command substitution inside double quotes, so JSON with braces and commas is built in a function body or written in single quotes, never as "{\"a\":1,\"b\":2}" inside $( ).
start() { printf '{"do":"start","wait":"%s"}' "${1:-started}"; }    # [started | settled | exit]
second() { printf '{"do":"second"}'; }
exited() { printf '{"do":"exited"}'; }
signal_() { printf '{"do":"signal","name":"%s"}' "$1"; }
expect() { printf '{"do":"expect","text":"%s","n":%s,"ms":%s}' "$(jstr "$1")" "${2:-1}" "${3:-10000}"; }   # <text> [n [ms]]: n lines of stderr hold the text
file() { printf '{"do":"file","path":"%s"}' "$(jstr "$1")"; }
gone() { printf '{"do":"gone","path":"%s"}' "$(jstr "$1")"; }
quiet() { printf '{"do":"quiet","ms":%s}' "$1"; }
mkdir_() { printf '{"do":"mkdir","path":"%s"}' "$(jstr "$1")"; }
put() { printf '{"do":"put","to":"%s","text":"%s"}' "$(jstr "$1")" "$(jstr "$2")"; }    # the text as the shell holds it, line breaks and tabs included
putfile() { printf '{"do":"put","to":"%s","from":"%s"}' "$(jstr "$1")" "$(jstr "$2")"; }
rename_() { printf '{"do":"rename","from":"%s","to":"%s"}' "$(jstr "$1")" "$(jstr "$2")"; }
remove_() { printf '{"do":"remove","path":"%s"}' "$(jstr "$1")"; }
trunc_() { printf '{"do":"truncate","path":"%s"}' "$(jstr "$1")"; }
symlink_() { printf '{"do":"symlink","target":"%s","link":"%s"}' "$(jstr "$1")" "$(jstr "$2")"; }
lock_() { printf '{"do":"lock","as":"%s"}' "$1"; }
# <name>=<value> words as the JSON object of the fields of an event or a row.
fields() {
  local out= kv
  for kv in "$@"; do out="${out:+$out,}\"${kv%%=*}\":\"$(jstr "${kv#*=}")\""; done
  printf '{%s}' "$out"
}
ev() {  # <event> <key> [name=value]...: one event, appended to events.tsv with one write
  local event=$1 key=$2
  shift 2
  printf '{"do":"ev","f":%s}' "$(fields "ev=$event" "key=$key" "$@")"
}
row() {  # <key> <state> [name=value]...: a state row; at is seconds from the start of the run (negative: ago)
  local key=$1
  shift
  printf '{"do":"row","key":"%s","f":%s}' "$key" "$(fields "state=$1" "${@:2}")"
}
burst() {  # <count> <one write | many> <pad> <event> <key> [name=value]...: events, {n} in a field is the number of the event
  local count=$1 one=false pad=$3 event=$4 key=$5
  [ "$2" = one ] && one=true
  shift 5
  printf '{"do":"burst","count":%s,"one":%s,"pad":%s,"f":%s}' "$count" "$one" "$pad" "$(fields "ev=$event" "key=$key" "$@")"
}
tmuxmode() { put rec/tmux.mode "$1"; }
helpermode() { put rec/helper.mode "$1"; }
# The mode of each call of the helper in turn, the first mode for the first call: a scenario that needs the helper to answer differently from one call to the next sets them all before the daemon starts, so that no answer depends on how far the daemon has got when the driver writes the next one. After the last, the mode of helpermode, or ok.
helpermodes() { put rec/helper.modes "$(printf '%s\n' "$@")"; }
# A sentinel: an event the daemon turns into a notice line of its own, so that a scenario about an event that gives no line has something to wait for.
SENTINEL_KEY=99
sentinel() { printf '%s,%s' "$(ev Stop $SENTINEL_KEY)" "$(expect "notice turn_done $SENTINEL_KEY ")"; }
# The same for a scenario that switches turn_done off, and for one that switches off all three kinds that are on: a kind of its own that the scenario leaves on.
sentinel_permission() { printf '%s,%s' "$(ev Notification $SENTINEL_KEY sub=permission_prompt text=sentinel)" "$(expect "notice permission $SENTINEL_KEY ")"; }
sentinel_end() { printf '%s,%s' "$(ev SessionEnd $SENTINEL_KEY)" "$(expect "notice session_end $SENTINEL_KEY ")"; }

# What a transcript is compared after: the time of a line, the pid a service names itself by (the holder of a lock is said as its role by the driver), the scratch directory (the one path both daemons work in, which differs from run to run), and in the scenario about a start that cannot take the state directory (HANDOVER) the one line only the Rust daemon writes: it hands over to node, and from there on the lines are node's own (design.md, "Where the two are known to differ", the third item).
HANDOVER=
norm() {  # <file>
  local ts='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z' drop=()
  [ -z "$HANDOVER" ] || drop+=(-e "/^stderr${TAB}TS handing over to the node service: /d")
  sed -E -e "s/^((second-)?stderr${TAB})$ts /\\1TS /" -e 's/ started pid [0-9]+ backend / started pid PID backend /' -e "s#$TMP#TMP#g" ${drop[@]+"${drop[@]}"} "$1"
}

# The first line the two transcripts differ at and a window of 160 characters at the first differing character.
first_difference() {  # <node transcript> <rust transcript>
  LC_ALL=C awk '
    NR == FNR { node[FNR] = $0; nodes = FNR; next }
    FNR > nodes && !shown { shown = 1; print "line " FNR " only in rust: " substr($0, 1, 160); next }
    !shown && node[FNR] != $0 {
      shown = 1
      a = node[FNR]; b = $0
      m = length(a) < length(b) ? length(a) : length(b)
      for (i = 1; i <= m; i++) if (substr(a, i, 1) != substr(b, i, 1)) break
      from = i > 60 ? i - 60 : 1
      print "line " FNR ", first difference at character " i
      print "node: " (from > 1 ? "..." : "") substr(a, from, 160)
      print "rust: " (from > 1 ? "..." : "") substr(b, from, 160)
    }
    END { if (!shown && FNR < nodes) print "line " (FNR + 1) " only in node: " substr(node[FNR + 1], 1, 160) }
  ' "$1" "$2"
}

# The command of each kind of daemon. The self-test puts node on both sides.
NODE_CMD=("$NODE" "$NOTIFY_JS" run)
if [ -n "$SELF_TEST" ]; then RUST_CMD=("${NODE_CMD[@]}"); else RUST_CMD=("$RUST" notify run); fi

# A fresh scratch, the environment of a daemon, and the driver on a script. $1 is the side, node or rust; the daemon of the other kind is the one a `second` step starts.
run_side() {  # <side> <script>
  local side=$1 script=$2 state=$RUN/state config=$RUN/config app=$APP
  rm -rf "$RUN"; mkdir -p "$RUN/home" "$RUN/rec" "$RUN/tmux"
  [ -z "$BLOCKSTATE" ] || { printf 'x' > "$RUN/blocker"; state=$RUN/blocker/state; }
  [ -z "$NOAPP" ] || app=$TMP/no-app/TagentsNotify.app
  [ -z "$NOEXEC" ] || app=$TMP/no-exec/TagentsNotify.app
  if [ -z "$NOCONFIG" ]; then
    mkdir "$config"
    if [ -z "$NOPLUGINS" ]; then
      mkdir "$config/plugins"
      [ -n "$NOFILE" ] || printf '%s\n' "$OPTS" > "$config/plugins/notify.toml"
    fi
  fi
  local envv=(PATH="$SHIM:/usr/bin:/bin" HOME="$RUN/home" LANG=en_US.UTF-8 TA_STATE_DIR="$state" TAGENTS_CONFIG_DIR="$config" TMUX_TMPDIR="$RUN/tmux" TA_NOTIFY_APP="$app" PARITY_REC="$RUN/rec" TAGENTS_NODE="$NODE")
  [ "$LOCALE" = - ] || envv+=(TAGENTS_LOCALE="$LOCALE")
  [ -z "$CLICK_SCRIPT" ] || envv+=(TA_NOTIFY_TAGENTS="$CLICK_SCRIPT")
  if [ "$side" = node ]; then
    env -i "${envv[@]}" ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} "$NODE" "$DRIVER" run "$script" "$RUN" -- "${NODE_CMD[@]}" --other "${RUST_CMD[@]}"
  else
    env -i "${envv[@]}" ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} "$NODE" "$DRIVER" run "$script" "$RUN" -- "${RUST_CMD[@]}" --other "${NODE_CMD[@]}"
  fi
}

# Whether a scenario is one the filter picked.
selected() { case $1 in *"${PARITY_ONLY:-}"*) return 0 ;; *) return 1 ;; esac; }

# play <label> <script>: a scenario, on both sides. $OPTS, $NOCONFIG and the other variables of reset_scenario are the scenario's setup and are put back after it.
RAN=1   # whether the last play ran its scenario: the tripwires of one that did not are skipped
play() {
  local label=$1 script=$2 side code
  RAN=
  if ! selected "$label"; then reset_scenario; return; fi
  RAN=1; ran=$((ran + 1))
  printf '%s\n' "$script" > "$TMP/scripts/current.json"
  for side in node rust; do
    run_side "$side" "$TMP/scripts/current.json" > "$TMP/raw.$side" 2> "$TMP/driver.$side"
    code=$?
    if [ "$code" -ne 0 ]; then bad "$label: the driver failed on the $side side (exit $code)" "$(head -c 400 "$TMP/driver.$side" | tr '\n' '|')"; RAN=; reset_scenario; return; fi
    norm "$TMP/raw.$side" > "$TMP/transcript.$side"
    if [ -n "${PARITY_SHOW:-}" ]; then printf '  --- %s, %s\n' "$label" "$side"; cut -c1-"$PARITY_SHOW" "$TMP/transcript.$side" | sed 's/^/  | /'; fi
  done
  reset_scenario
  # The node run never ends in a timeout: a wait that ran out is a scenario that does not provoke what it exists for, or a driver that waits for the wrong thing.
  if grep -q '^timeout ' "$TMP/transcript.node"; then bad "$label: a wait ran out in the node run" "$(grep '^timeout ' "$TMP/transcript.node" | head -3 | tr '\n' '|')"; RAN=; return; fi
  if cmp -s "$TMP/transcript.node" "$TMP/transcript.rust"; then ok; return; fi
  bad "$label: the transcripts differ" "$(first_difference "$TMP/transcript.node" "$TMP/transcript.rust" | sed '2,$s/^/       /')"
}
# A scenario that needs the helper app runs on macOS only: elsewhere it is counted as skipped.
play_mac() {
  if [ "$OS" = Darwin ] || ! selected "$1"; then play "$@"; return; fi
  RAN=; skipped=$((skipped + 1)); reset_scenario
}

# A tripwire: the node transcript of the last scenario must hold the string (fixed, not a pattern).
must() {  # <label> <needle>
  [ -n "$RAN" ] || return 0
  if grep -qF -- "$2" "$TMP/transcript.node"; then ok; else bad "tripwire $1: node did not say what this scenario exists to provoke" "wanted: $2"; fi
}
# The reverse: the string is not in it.
must_not() {  # <label> <needle>
  [ -n "$RAN" ] || return 0
  if grep -qF -- "$2" "$TMP/transcript.node"; then bad "tripwire $1: node said what this scenario expects it not to say" "found: $2"; else ok; fi
}
# The string is on exactly n lines of the node transcript.
must_count() {  # <label> <needle> <n>
  local found
  [ -n "$RAN" ] || return 0
  found=$(grep -cF -- "$2" "$TMP/transcript.node")
  if [ "$found" = "$3" ]; then ok; else bad "tripwire $1: node said it on $found lines, not $3" "string: $2"; fi
}
# The first string comes before the second in the node transcript.
must_before() {  # <label> <first> <second>
  [ -n "$RAN" ] || return 0
  if [ "$(grep -o -F -e "$2" -e "$3" "$TMP/transcript.node" | head -1)" = "$2" ]; then ok; else bad "tripwire $1: node did not say them in this order" "wanted $2 before $3"; fi
}

# ------------------------------------------------------------ first check ---
# A daemon that is only the front door's forward to the node CLI would pass every scenario by being node. So before any scenario the Rust side is started once: it must say `started pid <its own pid>` (the node CLI, with no notify plugin in the scratch config, never writes that line) and the process must be the Rust binary, not `node` (what exec_node leaves, and what a hand-over to node leaves too).
# The Rust daemon on a scratch of its own, started by the driver's verb with no node daemon beside it, and the driver's report: the first check and the resource checks, where node's numbers are not the reference.
alone() {  # <driver verb>
  rm -rf "$RUN"; mkdir -p "$RUN/home" "$RUN/rec" "$RUN/tmux" "$RUN/config/plugins"
  printf '%s\n' "$DEFAULT_OPTS" > "$RUN/config/plugins/notify.toml"
  env -i PATH="$SHIM:/usr/bin:/bin" HOME="$RUN/home" LANG=en_US.UTF-8 TA_STATE_DIR="$RUN/state" TAGENTS_CONFIG_DIR="$RUN/config" TAGENTS_LOCALE=en TMUX_TMPDIR="$RUN/tmux" TA_NOTIFY_APP="$APP" PARITY_REC="$RUN/rec" TAGENTS_NODE="$NODE" TA_NOTIFY_TAGENTS="$CLICK_SCRIPT" \
    "$NODE" "$DRIVER" "$1" "$RUN" -- "${RUST_CMD[@]}"
}
first_check() {
  local report want image claimed pid started
  report=$(alone probe 2> "$TMP/probe.err") || { echo "rust-notify-parity: the first check could not run the driver: $(head -c 300 "$TMP/probe.err")" >&2; exit 2; }
  started=$(printf '%s\n' "$report" | sed -n 's/^started //p')
  pid=$(printf '%s\n' "$report" | sed -n 's/^pid //p')
  claimed=$(printf '%s\n' "$report" | sed -n 's/^claimed //p')
  image=$(printf '%s\n' "$report" | sed -n 's/^image //p')
  # What `ps -o comm=` prints is the whole path on macOS and the name cut to 15 characters on Linux, and the driver takes its basename.
  want=$(basename "$RUST")
  [ "$OS" = Linux ] && want=${want:0:15}
  if [ "$started" != yes ]; then
    printf "rust-notify-parity: FIRST CHECK FAILED: \`%s notify run\` never said it had started.\n" "$RUST"
    printf "  The front door hands a verb with no arm to the node CLI (crates/tagents-core/src/front_door.rs, the \`None => exec_node\` arm), so a binary without the \`notify\` arm ends here, and so does a daemon that fails to start. What it did:\n"
    printf '%s\n' "$report" | sed 's/^/    /'
    return 1
  fi
  if [ "$image" != "$want" ] || [ "$claimed" != "$pid" ]; then
    printf "rust-notify-parity: FIRST CHECK FAILED: the process \`%s notify run\` started is \`%s\` and says it is pid %s (it was started as pid %s), not the Rust binary \`%s\`.\n" "$RUST" "$image" "$claimed" "$pid" "$want"
    printf "  That is the node CLI the front door forwards to when the \`notify\` arm is missing, or a hand-over to the node service: comparing it with the node daemon would compare node with node.\n"
    printf '%s\n' "$report" | sed 's/^/    /'
    return 1
  fi
}
if [ -n "$SELF_TEST" ]; then
  echo "rust-notify-parity: SELF TEST: node runs on both sides and the first check is skipped; this run proves the suite and node's determinism, not the Rust daemon."
else
  first_check || exit 1
fi

# ------------------------------------------------------------- scenarios ---
# A scenario about one event: the daemon starts, takes the events, and the sentinel gives the wait that proves the events before it were taken. The notice of a question or a permission prompt is up first for the rows that withdraw it.
verdict() {  # <label> <step>...
  local label=$1
  shift
  play "verdict: $label" "$(steps "$(start)" "$@" "$(sentinel)")"
}
withdraws() {  # <label> <step>...: a question is up (key 1), then the steps
  local label=$1
  shift
  play "verdict: $label" "$(steps "$(start)" "$(ev PreToolUse 1 tool=AskUserQuestion text='Which colour?')" "$(expect 'notice question 1 ')" "$@" "$(sentinel)")"
}

t "the verdicts: every row of the table"
verdict "PreToolUse AskUserQuestion is a question" "$(ev PreToolUse 1 tool=AskUserQuestion text='Which colour?')" "$(expect 'notice question 1 ')"
must "AskUserQuestion" 'notice question 1 '
verdict "PreToolUse ExitPlanMode is a plan question" "$(ev PreToolUse 1 tool=ExitPlanMode text='Plan: do it')" "$(expect 'notice question 1 ')"
must "ExitPlanMode" 'notice question 1 '
verdict "PreToolUse Bash is nothing" "$(ev PreToolUse 1 tool=Bash text=ls)"
must_count "PreToolUse Bash: only the sentinel has a notice" 'notice ' 1
withdraws "PostToolUse AskUserQuestion withdraws" "$(ev PostToolUse 1 tool=AskUserQuestion)" "$(expect 'withdraw tagents-1')"
must "PostToolUse AskUserQuestion" 'withdraw tagents-1'
withdraws "PostToolUse ExitPlanMode withdraws" "$(ev PostToolUse 1 tool=ExitPlanMode)" "$(expect 'withdraw tagents-1')"
must "PostToolUse ExitPlanMode" 'withdraw tagents-1'
withdraws "PostToolUse Bash leaves the question up" "$(ev PostToolUse 1 tool=Bash)"
must_not "PostToolUse Bash" 'withdraw'
must_count "PostToolUse Bash: the question and the sentinel" 'notice ' 2
verdict "Notification elicitation_dialog is a question" "$(ev Notification 1 sub=elicitation_dialog text='Pick one')" "$(expect 'notice question 1 ')"
must "elicitation_dialog" 'notice question 1 '
verdict "Notification permission_prompt is a permission" "$(ev Notification 1 sub=permission_prompt text='Claude needs your permission to use Bash')" "$(expect 'notice permission 1 ')"
must "permission_prompt" 'notice permission 1 '
verdict "Notification idle_prompt is nothing" "$(ev Notification 1 sub=idle_prompt text='Claude is waiting for your input')"
must_count "idle_prompt: only the sentinel has a notice" 'notice ' 1
verdict "Notification auth_success is nothing" "$(ev Notification 1 sub=auth_success text='Authenticated')"
must_count "auth_success: only the sentinel has a notice" 'notice ' 1
verdict "Notification with no subtype and the waiting text is nothing" "$(ev Notification 1 text='Claude is Waiting For Your Input now')"
must_count "waiting text: only the sentinel has a notice" 'notice ' 1
verdict "Notification of a subtype nobody has met, with words, is a permission" "$(ev Notification 1 sub=future_kind text='Something needs you')" "$(expect 'notice permission 1 ')"
must "unknown subtype" 'notice permission 1 '
verdict "Notification of a subtype nobody has met, with blank words, is nothing" "$(ev Notification 1 sub=future_kind 'text=   ')"
must_count "blank words: only the sentinel has a notice" 'notice ' 1
verdict "Notification with no subtype and no words is nothing" "$(ev Notification 1)"
must_count "no words: only the sentinel has a notice" 'notice ' 1
verdict "Stop is turn_done" "$(ev Stop 1 text='All done')" "$(expect 'notice turn_done 1 ')"
must "Stop" 'notice turn_done 1 '
verdict "Stop of a subagent is nothing" "$(ev Stop 1 agent=sub-1)"
must_count "subagent Stop: only the sentinel has a notice" 'notice ' 1
verdict "SubagentStop is nothing" "$(ev SubagentStop 1 agent=sub-1)"
must_count "SubagentStop: only the sentinel has a notice" 'notice ' 1
withdraws "SessionEnd with session_end off only withdraws" "$(ev SessionEnd 1)" "$(expect 'withdraw tagents-1')"
must "SessionEnd off: the notice that stands is withdrawn" 'withdraw tagents-1'
must_count "SessionEnd off: the question and the sentinel have a notice, the end none" 'notice ' 2
OPTS='backend = "log"
[events.session_end]
enabled = true'
verdict "SessionEnd with session_end on is a notice" "$(ev SessionEnd 1)" "$(expect 'notice session_end 1 ')"
must "SessionEnd on" 'notice session_end 1 '
withdraws "UserPromptSubmit withdraws" "$(ev UserPromptSubmit 1)" "$(expect 'withdraw tagents-1')"
must "UserPromptSubmit" 'withdraw tagents-1'
withdraws "SessionStart withdraws" "$(ev SessionStart 1)" "$(expect 'withdraw tagents-1')"
must "SessionStart" 'withdraw tagents-1'
verdict "a session with no pane of its own (s-<id>) is never counted" "$(ev Stop s-abc pane= text=done)" "$(ev Notification s-abc pane= sub=permission_prompt text=x)" "$(ev PreToolUse s-abc pane= tool=AskUserQuestion)"
must_count "s- key: only the sentinel has a notice" 'notice ' 1
verdict "an event nobody knows" "$(ev Frobnicate 1)"
must_count "unknown event: only the sentinel has a notice" 'notice ' 1


t "the question-then-permission window"
# QUESTION_PROMPT_WINDOW_MS is 20 s, counted on the `at` of the events, and `<=` is held: Claude Code follows a question with a prompt of its own about six seconds later.
window() {  # <label> <step>...: a question on key 1 at second 0, then the steps
  local label=$1
  shift
  play "window: $label" "$(steps "$(start)" "$(ev PreToolUse 1 at=0 tool=AskUserQuestion text='Which colour?')" "$(expect 'notice question 1 ')" "$@" "$(sentinel)")"
}
window "a permission 6 s later is held back" "$(ev Notification 1 at=6 sub=permission_prompt text='May I?')" "$(expect 'held back')"
must "held back" 'permission prompt held back by the question on screen'
must_count "held back: no permission notice" 'notice permission' 0
window "a permission 19 s later is held back" "$(ev Notification 1 at=19 sub=permission_prompt text='May I?')" "$(expect 'held back')"
must "19 s" 'held back'
window "a permission exactly 20 s later is held back" "$(ev Notification 1 at=20 sub=permission_prompt text='May I?')" "$(expect 'held back')"
must "20 s" 'held back'
window "a permission 21 s later replaces the question" "$(ev Notification 1 at=21 sub=permission_prompt text='May I?')" "$(expect 'notice permission 1 ')"
must "21 s: posted" 'notice permission 1 '
must_before "21 s: after the question" 'notice question 1 ' 'notice permission 1 '
must_count "21 s: the same id is posted twice" 'post tagents-1 ' 2
window "a permission of another session is not held back" "$(ev Notification 2 at=6 sub=permission_prompt text='May I?')" "$(expect 'notice permission 2 ')"
must "another key" 'notice permission 2 '
window "a second permission inside the window is held back as well" "$(ev Notification 1 at=5 sub=permission_prompt text='May I?')" "$(ev Notification 1 at=10 sub=permission_prompt text='May I?')" "$(expect 'held back' 2)"
must_count "two held" 'held back' 2
window "a permission after the answer is posted" "$(ev PostToolUse 1 at=3 tool=AskUserQuestion)" "$(expect 'withdraw tagents-1')" "$(ev Notification 1 at=6 sub=permission_prompt text='May I?')" "$(expect 'notice permission 1 ')"
must "answered first" 'notice permission 1 '
must_count "answered first: not held" 'held back' 0
play "window: a plan question holds a permission back" "$(steps "$(start)" "$(ev PreToolUse 1 at=0 tool=ExitPlanMode text='Plan: do it')" "$(expect 'notice question 1 ')" "$(ev Notification 1 at=6 sub=permission_prompt text='May I?')" "$(expect 'held back')" "$(sentinel)")"
must "plan" 'held back'
play "window: an elicitation dialog does not register the window" "$(steps "$(start)" "$(ev Notification 1 at=0 sub=elicitation_dialog text='Pick one')" "$(expect 'notice question 1 ')" "$(ev Notification 1 at=6 sub=permission_prompt text='May I?')" "$(expect 'notice permission 1 ')" "$(sentinel)")"
must_count "elicitation: not held" 'held back' 0
OPTS='backend = "log"
[events.question]
enabled = false'
play "window: a switched-off question and a permission 6 s later" "$(steps "$(start)" "$(ev PreToolUse 1 at=0 tool=AskUserQuestion text='Which colour?')" "$(ev Notification 1 at=6 sub=permission_prompt text='May I?')" "$(sentinel)")"
must "window: a switched-off question holds nothing back" 'notice permission 1 '
must_count "window: a switched-off question: no permission is held back" 'held back' 0

t "kinds switched off"
# The kinds that are on by default. A cache_expiring switched off is the cache group's (nothing is armed, or the deadline is armed all the same), and session_end is off by default and on in the last scenario here.
for kind in question permission turn_done; do
  OPTS="backend = \"log\"
[events.$kind]
enabled = false"
  sent=sentinel; [ $kind != turn_done ] || sent=sentinel_permission
  play "off: $kind" "$(steps "$(start)" "$(ev PreToolUse 1 tool=AskUserQuestion text=q)" "$(ev Notification 2 sub=permission_prompt text=p)" "$(ev Stop 3 text=s)" "$(ev SessionEnd 4)" "$($sent)")"
  must_not "off: $kind" "notice $kind"
done
OPTS='backend = "log"
[events.question]
enabled = false
[events.permission]
enabled = false
[events.turn_done]
enabled = false
[events.session_end]
enabled = true'
play "off: all three kinds that are on by default" "$(steps "$(start)" "$(ev PreToolUse 1 tool=AskUserQuestion text=q)" "$(ev Notification 2 sub=permission_prompt text=p)" "$(ev Stop 3 text=s)" "$(sentinel_end)")"
must_count "off: all three: only the sentinel has a notice" 'notice ' 1
OPTS='backend = "log"
[events.question]
enabled = false'
play "off: a withdraw still reaches the notice of another kind" "$(steps "$(start)" "$(ev Notification 1 sub=permission_prompt text=p)" "$(expect 'notice permission 1 ')" "$(ev PreToolUse 1 tool=AskUserQuestion text=q)" "$(ev PostToolUse 1 tool=AskUserQuestion)" "$(sentinel)")"
must_count "off: a withdraw still reaches the notice of another kind, once for each event" 'withdraw tagents-1' 2

t "skip_visible: a pane in front of a client, and every way the probe can answer"
# The probe runs for every notice, whatever skip_visible says: skip_visible only decides whether a notice of a pane in front of a client is left to the helper to drop (skip-if-frontmost) or is always shown, and the pid after `pid=` is the client the probe found.
probed() {  # <tmux mode> <pid and policy of the post line of a turn_done> [more steps...]
  local mode=$1 how=$2
  play "skip_visible: tmux says $mode" "$(steps "$(tmuxmode "$mode")" "$(start)" "$(ev Stop 1 text=done)" "$(sentinel)")"
  must_count "tmux says $mode" "pid=$how" 2
}
probed shown '4242 skip-if-frontmost'
probed hidden '4242 always'
probed noclient 'none always'
probed viewport '4242 skip-if-frontmost'
probed fail 'none always'
probed nopane 'none always'
probed nopane37 'none always'
probed garbage 'none always'
# The probe's deadline is two seconds: a tmux that answers later gives the same as no answer.
play "skip_visible: the probe takes longer than its deadline" "$(steps "$(tmuxmode slow)" "$(start)" "$(ev Stop 1 text=done)" "$(expect 'notice turn_done 1 ' 1 20000)")"
must "slow probe" 'pid=none always'
OPTS='backend = "log"
[events.turn_done]
skip_visible = false'
play "skip_visible: off, a pane in front is still posted, always" "$(steps "$(tmuxmode shown)" "$(start)" "$(ev Stop 1 text=done)" "$(expect 'notice turn_done 1 ')")"
must "skip_visible off" 'pid=4242 always'
OPTS='backend = "log"
[events.question]
skip_visible = false'
play "skip_visible: per kind" "$(steps "$(tmuxmode shown)" "$(start)" "$(ev PreToolUse 1 tool=AskUserQuestion text=q)" "$(expect 'notice question 1 ')" "$(ev Stop 2 text=s)" "$(sentinel)")"
must_count "per kind: the question is posted always" 'pid=4242 always' 1
must_count "per kind: the turn_done and the sentinel are left to the helper" 'pid=4242 skip-if-frontmost' 2

t "replace and withdraw"
# A notice has the id of its session, so the next one of that session replaces it, and a prompt, an answer, a new session or the end of the session takes it down: only when the daemon knows it is up.
play "replace: the next notice of a session has the same id" "$(steps "$(start)" "$(ev Stop 1 text=first)" "$(expect 'notice turn_done 1 ')" "$(ev Stop 1 text=second)" "$(sentinel)")"
must_count "replace: one id, twice" 'post tagents-1 ' 2
must_not "replace: nothing is withdrawn" 'withdraw'
play "replace: another session is another id" "$(steps "$(start)" "$(ev Stop 1 text=first)" "$(ev Stop 2 text=second)" "$(sentinel)")"
must_count "replace: two ids" 'post tagents-' 3
play "withdraw: nothing is up for the session" "$(steps "$(start)" "$(ev UserPromptSubmit 1)" "$(sentinel)")"
must_not "withdraw: nothing up" 'withdraw'
play "withdraw: a finished turn is taken down by the next prompt" "$(steps "$(start)" "$(ev Stop 1 text=done)" "$(expect 'notice turn_done 1 ')" "$(ev UserPromptSubmit 1)" "$(expect 'withdraw tagents-1')" "$(sentinel)")"
must "withdraw: a turn_done" 'withdraw tagents-1'
play "withdraw: a second prompt finds nothing up" "$(steps "$(start)" "$(ev Stop 1 text=done)" "$(expect 'notice turn_done 1 ')" "$(ev UserPromptSubmit 1)" "$(ev UserPromptSubmit 1)" "$(sentinel)")"
must_count "withdraw: once" 'withdraw tagents-1' 2
OPTS='backend = "log"
[events.session_end]
enabled = true'
play "withdraw: a session that ends takes its notice down, then says so" "$(steps "$(start)" "$(ev Stop 1 text=done)" "$(expect 'notice turn_done 1 ')" "$(ev SessionEnd 1 sub=clear)" "$(expect 'notice session_end 1 ')" "$(sentinel)")"
must_before "withdraw: before the end notice" 'withdraw tagents-1' 'notice session_end 1 '
must "withdraw: the reason is the body" '"clear"'
withdraws "a notice of one session is not taken down by another" "$(ev UserPromptSubmit 2)"
must_not "withdraw: another key" 'withdraw'

t "cache deadlines from events"
# A deadline is armed by an event that leaves the person waiting (a question, a permission prompt, the end of a turn) at that event's own time, and falls due `after` later; the daemon posts only when the state row of the session says it is still waiting, and only while the cache (`ttl`) is alive. Short `after` and `ttl` make one fall due in seconds; a past `at` makes it fall due at once.
SHORT='backend = "log"
[events.cache_expiring]
after = "1s"
ttl = "10s"'
OPTS=$SHORT
play "cache: a Stop arms a deadline that falls due" "$(steps "$(start)" "$(row 1 'done' at=0)" "$(ev Stop 1 at=0 text=done)" "$(expect 'notice cache_expiring 1 ')")"
must "cache: the notice" 'Prompt cache expiring'
must "cache: the body at under a minute" 'Idle 0 min — send anything within a minute to keep the prompt cache'
must_before "cache: after the turn" 'notice turn_done 1 ' 'notice cache_expiring 1 '
OPTS=$SHORT
# at=4 puts the deadline of a session 5 seconds after the second the run began in, so the prompt that cancels it is written long before it falls due; a machine so slow that it falls due first makes the node run notice the session that was answered, and the tripwire fails instead of the scenario passing for nothing.
play "cache: a prompt before the deadline cancels it" "$(steps "$(start)" "$(row 1 'done' at=0)" "$(row 2 'done' at=0)" "$(ev Stop 1 at=4 text=a)" "$(ev Stop 2 at=4 text=b)" "$(ev UserPromptSubmit 1 at=4)" "$(expect 'notice cache_expiring 2 ')")"
must_count "cache: only the session that was not answered" 'notice cache_expiring' 1
OPTS=$SHORT
play "cache: a question arms a deadline" "$(steps "$(start)" "$(row 1 working at=0 detail=AskUserQuestion)" "$(ev PreToolUse 1 at=0 tool=AskUserQuestion text=q)" "$(expect 'notice cache_expiring 1 ')")"
must "cache: a question" 'notice cache_expiring 1 '
OPTS=$SHORT
play "cache: a permission prompt arms a deadline" "$(steps "$(start)" "$(row 1 blocked at=0 detail=p)" "$(ev Notification 1 at=0 sub=permission_prompt text=p)" "$(expect 'notice cache_expiring 1 ')")"
must "cache: a permission" 'notice cache_expiring 1 '
OPTS='backend = "log"
[events.turn_done]
enabled = false
[events.cache_expiring]
after = "1s"
ttl = "10s"'
play "cache: a kind that is switched off still arms the deadline" "$(steps "$(start)" "$(row 1 'done' at=0)" "$(ev Stop 1 at=0 text=done)" "$(expect 'notice cache_expiring 1 ')")"
must_not "cache: no turn_done notice" 'notice turn_done'
OPTS=$SHORT
# at=4 puts the deadline of a session 5 seconds after the second the run began in, so the prompt that cancels it is written long before it falls due; a machine so slow that it falls due first makes the node run notice the session that was answered, and the tripwire fails instead of the scenario passing for nothing.
play "cache: a question answered is not waiting" "$(steps "$(start)" "$(row 1 working at=0 detail=AskUserQuestion)" "$(ev PreToolUse 1 at=4 tool=AskUserQuestion text=q)" "$(ev PostToolUse 1 at=4 tool=AskUserQuestion)" "$(row 2 'done' at=0)" "$(ev Stop 2 at=4 text=other)" "$(expect 'notice cache_expiring 2 ')")"
must_count "cache: only the other session" 'notice cache_expiring' 1
OPTS=$SHORT
play "cache: a session that ended is not warned about" "$(steps "$(start)" "$(row 1 gone at=0)" "$(row 2 'done' at=0)" "$(ev Stop 1 at=2 text=a)" "$(ev Stop 2 at=2 text=b)" "$(expect 'notice cache_expiring 2 ')" "$(quiet 600)")"
must_count "cache: gone: only the other" 'notice cache_expiring' 1
OPTS=$SHORT
play "cache: a turn that is running is not warned about" "$(steps "$(start)" "$(row 1 working at=3 detail=Bash)" "$(row 2 'done' at=0)" "$(ev Stop 1 at=2 text=a)" "$(ev Stop 2 at=2 text=b)" "$(expect 'notice cache_expiring 2 ')")"
must_count "cache: working: only the other" 'notice cache_expiring' 1
OPTS=$SHORT
play "cache: a session with no state row is not warned about" "$(steps "$(start)" "$(row 2 'done' at=0)" "$(ev Stop 1 at=2 text=a)" "$(ev Stop 2 at=2 text=b)" "$(expect 'notice cache_expiring 2 ')")"
must_count "cache: no row: only the other" 'notice cache_expiring' 1
play "cache: 55 minutes idle, 5 left" "$(steps "$(start)" "$(row 1 'done' at=-3300)" "$(ev Stop 1 at=-3300 text=done)" "$(expect 'notice cache_expiring 1 ')")"
must "cache: 55 and 5" 'Idle 55 min — send anything within ~5 min to keep the prompt cache'
play "cache: 59 minutes idle, within a minute left" "$(steps "$(start)" "$(row 1 'done' at=-3575)" "$(ev Stop 1 at=-3575 text=done)" "$(expect 'notice cache_expiring 1 ')")"
must "cache: within a minute" 'Idle 60 min — send anything within a minute to keep the prompt cache'
play "cache: the cache is gone already" "$(steps "$(start)" "$(row 1 'done' at=-3700)" "$(ev Stop 1 at=-3700 text=done)" "$(quiet 600)" "$(sentinel)")"
must_count "cache: gone already: no warning" 'notice cache_expiring' 0
OPTS='backend = "log"
[events.cache_expiring]
enabled = false'
play "cache: switched off, nothing is armed" "$(steps "$(start)" "$(row 1 'done' at=-3300)" "$(ev Stop 1 at=-3300 text=done)" "$(quiet 600)" "$(sentinel)")"
must_count "cache: off" 'notice cache_expiring' 0
OPTS='backend = "log"
[events.cache_expiring]
after = "40m"'
play "cache: a longer after moves the deadline" "$(steps "$(start)" "$(row 1 'done' at=-2700)" "$(ev Stop 1 at=-2700 text=done)" "$(expect 'notice cache_expiring 1 ')")"
must "cache: 45 and 15" 'Idle 45 min — send anything within ~15 min to keep the prompt cache'

t "cache deadlines from state rows, at start"
# A daemon that starts arms a deadline for every session whose row says it is waiting (done, blocked, or working on a question nobody has answered) and whose cache is alive, from the time of the row. The rows are in the state directory before the daemon starts.
play "rows: the sessions that are waiting are armed, the others are not" "$(steps "$(row 1 'done' at=-3300)" "$(row 2 blocked at=-3301)" "$(row 3 working at=-3302 detail=AskUserQuestion)" "$(row 4 working at=-3303 detail=Bash)" "$(row 5 working at=-3304 'detail=AskUserQuestion ✓')" "$(row 6 new at=-3305)" "$(row 7 gone at=-3306)" "$(row 8 subdone at=-3307)" "$(row 9 working at=-3308 'detail=ExitPlanMode which plan')" "$(row s-abc 'done' at=-3309)" "$(row 10 working at=-3310 detail=AskUserQuestionary)" "$(start)" "$(expect 'notice cache_expiring ' 4)" "$(sentinel)")"
must_count "rows: four are armed" 'notice cache_expiring ' 4
must_before "rows: the newest first" 'notice cache_expiring 1 ' 'notice cache_expiring 2 '
must "rows: an open question" 'notice cache_expiring 3 '
must "rows: a plan question" 'notice cache_expiring 9 '
play "rows: the newest first, and the order of the names for the same time" "$(steps "$(row 1 'done' at=-3300)" "$(row 10 'done' at=-3300)" "$(row 2 'done' at=-3300)" "$(row 3 'done' at=-3200)" "$(start)" "$(expect 'notice cache_expiring ' 4)")"
must_before "rows: 3 first" 'notice cache_expiring 3 ' 'notice cache_expiring 1 '
must_before "rows: 1 before 10" 'notice cache_expiring 1 ' 'notice cache_expiring 10 '
must_before "rows: 10 before 2" 'notice cache_expiring 10 ' 'notice cache_expiring 2 '
play "rows: a cache that is over is not armed" "$(steps "$(row 1 'done' at=-3700)" "$(start)" "$(quiet 600)" "$(sentinel)")"
must_count "rows: over: no warning" 'notice cache_expiring' 0
OPTS='backend = "log"
[events.cache_expiring]
enabled = false'
play "rows: switched off, nothing is armed" "$(steps "$(row 1 'done' at=-3300)" "$(start)" "$(quiet 600)" "$(sentinel)")"
must_count "rows: off" 'notice cache_expiring' 0
OPTS=$SHORT
play "rows: a deadline in the future falls due when it is time" "$(steps "$(row 1 'done' at=0)" "$(start)" "$(expect 'notice cache_expiring 1 ')")"
must "rows: later" 'Idle 0 min — send anything within a minute'
play "rows: composed from the row: its session, its directory, the name it was started under" "$(steps "$(row 1 'done' at=-3300 sid=abc cwd=/srv/app)" "$(put state/history.tsv $'1\tstart\tabc\t%1\tNightly\t/srv/app\n')" "$(start)" "$(expect 'notice cache_expiring 1 ')")"
must "rows: the click" '--act open %1 live abc /srv/app'
must "rows: the name" '"Nightly" "Prompt cache expiring · app"'

t "the body of a notice: the event's words, the transcript's last answer, the phrase"
# Fixtures of the transcripts the body of a turn_done is read from (the last 48 KiB of the file, a window that starts in the middle of a line when the file is longer, whose first line is dropped).
rep() { local out= i; for ((i = 0; i < $2; i++)); do out+=$1; done; printf '%s' "$out"; }   # <text> <times>
assistant() { printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$(jstr "$1")"; }
user() { printf '{"type":"user","message":{"content":"%s"}}\n' "$(jstr "$1")"; }
fixture() { local name=$1; shift; printf '%s\n' "$@" > "$TMP/fixtures/$name.jsonl"; }   # <name> <line>...
fixture last "$(user 'the assistant said hello')" "$(assistant 'old answer')" "$(user 'again')" "$(assistant 'new answer')"
fixture blocks '{"type":"assistant","message":{"content":[{"type":"text","text":"a"},{"type":"tool_use","id":"t","name":"Bash","input":{}},{"type":"text","text":"b"}]}}' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"u","name":"Bash","input":{}}]}}'
fixture blank "$(assistant 'real answer')" "$(assistant $'   \n  ')"
fixture lines "$(assistant $'\n\n   first line  \nsecond line')"
fixture crlf "$(assistant $'only line\r\nnext')"
fixture bad '{"type":"assistant"' 'not json at all "assistant"' '[1,2,"assistant"]' '{"type":"assistant","message":{"content":"a plain string"}}' '{"type":"assistant","message":"no content"}' '{"type":"user","message":{"content":[{"type":"text","text":"the person, saying assistant"}]}}' "$(assistant 'the answer')" '{"type":"assistant","message":{"content":[{"type":"text","text":42},{"type":"image"}]}}'
fixture nothing "$(user 'one')" "$(user 'two')"
fixture plain '{"type":"assistant","message":{"content":"a plain string"}}'
fixture exact200 "$(assistant "$(rep x 200)")"
fixture long201 "$(assistant "$(rep x 201)")"
fixture multibyte "$(assistant "$(rep ж 150)$(rep 😀 100)")"
# The window: the answer line begins <back> bytes before the end of the file, after a line of the person's, and a line of the person's pads the file to that. 49152 is the window, so the first line of the window is the answer's own line when back is 49152 and the answer is dropped with it; with 49151 the window starts on the newline before it and it is kept.
window_fixture() {  # <name> <back>
  local answer pad
  answer=$(assistant 'the answer at the edge')
  pad=$(( $2 - $(printf '%s\n' "$answer" | wc -c) - $(user '' | wc -c) ))
  { user first; printf '%s\n' "$answer"; user "$(rep x $pad)"; } > "$TMP/fixtures/$1.jsonl"
}
window_fixture edge49151 49151
window_fixture edge49152 49152
window_fixture edge49153 49153
window_fixture edge40000 40000
# An answer that is a whole line longer than the window: the fragment of it that the window holds is dropped with the line, and the short answer after it is kept.
{ assistant "$(rep y 60000)"; assistant 'after the long one'; } > "$TMP/fixtures/longline.jsonl"
assistant "$(rep y 60000)" > "$TMP/fixtures/onlylong.jsonl"
{ assistant 'far back'; user "$(rep x 60000)"; } > "$TMP/fixtures/farback.jsonl"
body() {  # <label> <fixture> [name=value]...: the Stop of session 1 with no words of its own, naming the transcript of the fixture
  local label=$1 fixture=$2
  shift 2
  play "body: $label" "$(steps "$(putfile transcripts/t.jsonl "$TMP/fixtures/$fixture.jsonl")" "$(start)" "$(ev Stop 1 transcript=transcripts/t.jsonl "$@")" "$(sentinel)")"
}
body "the last answer wins" last
must "last" '"Answer ready" "new answer"'
body "the last text block of the last answer with text" blocks
must "blocks" '"Answer ready" "b"'
body "a blank answer after a real one is passed over" blank
must "blank" '"Answer ready" "real answer"'
body "the first line that is not blank, trimmed" lines
must "lines" '"Answer ready" "first line"'
body "a line that ends in a carriage return" crlf
must "crlf" '"Answer ready" "only line"'
body "lines that are not records, and records that are not answers" bad
must "bad" '"Answer ready" "the answer"'
body "no answer in the transcript" nothing
must "nothing" '"Answer ready" "Your move"'
body "an answer whose content is a plain string is no answer" plain
must "plain" '"Answer ready" "Your move"'
body "the event's own words come first" last text='from the hook'
must "text" '"Answer ready" "from the hook"'
body "200 characters are not clipped" exact200
must "200" "\"$(rep x 200)\""
body "201 characters are clipped to 199 and an ellipsis" long201
must "201" "\"$(rep x 199)…\""
body "a clip counts characters, not bytes" multibyte
must "multibyte" "$(rep 😀 49)…\""
body "the answer line starts on the first byte of the window: it is dropped with the fragment" edge49152
must "edge 49152" '"Your move"'
body "the window starts on the newline before the answer: it is kept" edge49151
must "edge 49151" '"the answer at the edge"'
body "the window starts inside the answer: it is dropped" edge49153
must "edge 49153" '"Your move"'
body "the answer is well inside the window" edge40000
must "edge 40000" '"the answer at the edge"'
body "a line longer than the window, then a short answer" longline
must "longline" '"after the long one"'
body "one line longer than the window" onlylong
must "onlylong" '"Your move"'
body "an answer before the window" farback
must "farback" '"Your move"'
play "body: a transcript that is not there" "$(steps "$(start)" "$(ev Stop 1 transcript=transcripts/missing.jsonl)" "$(sentinel)")"
must "missing" '"Answer ready" "Your move"'
play "body: a transcript that is a directory" "$(steps "$(mkdir_ transcripts/dir)" "$(start)" "$(ev Stop 1 transcript=transcripts/dir)" "$(sentinel)")"
must "directory" '"Answer ready" "Your move"'
play "body: the event's own words are clipped as well" "$(steps "$(start)" "$(ev Stop 1 text="$(rep x 201)")" "$(sentinel)")"
must "own words" "\"$(rep x 199)…\""
play "body: a question is not clipped" "$(steps "$(start)" "$(ev PreToolUse 1 tool=AskUserQuestion text="$(rep x 300)")" "$(sentinel)")"
must "question" "\"$(rep x 300)\""
play "body: a question and a permission with no words have a phrase" "$(steps "$(start)" "$(ev PreToolUse 1 tool=AskUserQuestion)" "$(ev Notification 2 sub=permission_prompt)" "$(ev Notification 3 sub=elicitation_dialog)" "$(ev PreToolUse 4 tool=ExitPlanMode)" "$(sentinel)")"
must "question phrase" '"Asking you something"'
must "permission phrase" '"Waiting for your permission"'
must "plan subtitle" '"Plan ready for review"'
OPTS='backend = "log"
[events.session_end]
enabled = true'
play "body: a session end says why, or that no reason was given" "$(steps "$(start)" "$(ev SessionEnd 1 sub=logout)" "$(ev SessionEnd 2)" "$(sentinel)")"
must "reason" '"Session ended" "logout"'
must "no reason" '"Session ended" "No reason given"'

t "the probe's answer, read the way node reads it"
# The shim says what rec/tmux.answer holds, as it is. A notice shows what the probe found in its pid and its policy (skip-if-frontmost when the pane is in front of a client and the kind has skip_visible on) and, in its title, the pane's title.
answered() {  # <label> <what tmux prints> <what the post line of the notice must hold>
  play "probe: $1" "$(steps "$(tmuxmode answer)" "$(put rec/tmux.answer "$2")" "$(start)" "$(ev Stop 1 text=done)" "$(expect 'notice turn_done 1 ')")"
  must "probe: $1" "$3"
}
answered "a title that holds the separator" $'P|@|@1|@|a|@|b\n' '"a|@|b" "Answer ready · project"'
answered "the first pane line is the one" $'P|@|@1|@|first\nP|@|@2|@|second\n' '"first" "Answer ready · project"'
answered "no pane line" $'C|@|100|@|4242|@|@1|@|/dev/ttys001|@|main\n' 'pid=none always'
answered "no output at all" '' 'pid=none always'
answered "a pane line of two fields" $'P|@|@1\nC|@|100|@|4242|@|@1|@|/dev/ttys001|@|main\n' 'pid=none always'
answered "a pane in a window no client shows, with no title" $'P|@|@1|@|\nC|@|100|@|4242|@|@2|@|/dev/ttys001|@|main\n' '"project" "Answer ready" "done" click=/parity/bin/tagents --act open %1 live sid-1 /work/project pid=4242 always'
answered "a client whose activity is not a number" $'P|@|@1|@|t\nC|@|x|@|4242|@|@1|@|/dev/ttys001|@|main\n' 'pid=none always'
answered "a client whose pid is not a number" $'P|@|@1|@|t\nC|@|100|@|4x|@|@1|@|/dev/ttys001|@|main\n' 'pid=none always'
answered "a client line of four fields counts" $'P|@|@1|@|t\nC|@|100|@|4242|@|@1\n' 'pid=4242 skip-if-frontmost'
answered "a client line of five fields does not" $'P|@|@1|@|t\nC|@|100|@|4242|@|@1|@|/dev/ttys001\n' 'pid=none always'
answered "a client line of seven fields does not" $'P|@|@1|@|t\nC|@|100|@|4242|@|@1|@|/dev/ttys001|@|main|@|x\n' 'pid=none always'
answered "the client that shows the pane, though another is more active" $'P|@|@1|@|t\nC|@|900|@|1111|@|@2|@|/dev/ttys001|@|main\nC|@|100|@|3333|@|@1|@|/dev/ttys002|@|main\n' 'pid=3333 skip-if-frontmost'
answered "of two that show it, the more active" $'P|@|@1|@|t\nC|@|100|@|1111|@|@1|@|/dev/ttys001|@|main\nC|@|200|@|2222|@|@1|@|/dev/ttys002|@|main\n' 'pid=2222 skip-if-frontmost'
answered "none shows it: the most active client" $'P|@|@1|@|t\nC|@|100|@|1111|@|@2|@|/dev/ttys001|@|main\nC|@|300|@|2222|@|@3|@|/dev/ttys002|@|main\nC|@|200|@|3333|@|@4|@|/dev/ttys003|@|main\n' 'pid=2222 always'
answered "equally active: the first" $'P|@|@1|@|t\nC|@|100|@|1111|@|@2|@|/dev/ttys001|@|main\nC|@|100|@|2222|@|@3|@|/dev/ttys002|@|main\n' 'pid=1111 always'
answered "a viewport whose window holds the pane and a dashboard client behind it" $'P|@|@1|@|t\nC|@|100|@|4242|@|@2|@|/dev/ttys001|@|tagents\nC|@|200|@|4343|@|@1|@|/dev/ttys002|@|other\nV|@|/dev/ttys002\n' 'pid=4242 skip-if-frontmost'
answered "a viewport whose window holds the pane and no dashboard client" $'P|@|@1|@|t\nC|@|100|@|4242|@|@2|@|/dev/ttys001|@|main\nC|@|200|@|4343|@|@1|@|/dev/ttys002|@|other\nV|@|/dev/ttys002\n' 'pid=4242 always'
answered "a viewport that no client has" $'P|@|@1|@|t\nC|@|100|@|4242|@|@1|@|/dev/ttys001|@|main\nV|@|/dev/ttys009\n' 'pid=4242 skip-if-frontmost'
answered "a viewport line with a field too many" $'P|@|@1|@|t\nC|@|100|@|4242|@|@2|@|/dev/ttys001|@|tagents\nC|@|200|@|4343|@|@1|@|/dev/ttys002|@|other\nV|@|/dev/ttys002|@|x\n' 'pid=4343 skip-if-frontmost'
answered "output with no newline at the end" $'P|@|@1|@|t\nC|@|100|@|4242|@|@1|@|/dev/ttys001|@|main' 'pid=4242 skip-if-frontmost'
answered "a title with a trailing space" $'P|@|@1|@|spaced \n' '"spaced " "Answer ready · project"'
answered "carriage returns" $'P|@|@1|@|crlf\r\nC|@|100|@|4242|@|@1|@|/dev/ttys001|@|main\r\n' '"crlf\r" "Answer ready · project"'
# Whether the pane is gone or the probe merely failed shows in the cache warning: a pane that is gone is not warned about, and a probe that failed is.
gone_or_failed() {  # <label> <tmux mode> <what rec/tmux.answer holds> <what the cache notice says>
  play "probe: $1" "$(steps "$(tmuxmode "$2")" "$(put rec/tmux.answer "$3")" "$(start)" "$(row 1 'done' at=-3300)" "$(ev Stop 1 at=-3300 text=done)" "$(expect 'notice cache_expiring 1 ')")"
  must "probe: $1" "$4"
}
gone_or_failed "tmux fails with a message about the pane among others" error $'warning: something\ncan\'t find pane: %1\n' 'notice cache_expiring 1 skipped: tmux has no pane %1'
gone_or_failed "tmux fails with another message" error 'no server running' 'notice cache_expiring 1 "project" shown'
gone_or_failed "tmux says the pane is not there, the old way" nopane '' 'notice cache_expiring 1 skipped: tmux has no pane %1'
gone_or_failed "tmux 3.7 says the pane is not there, with exit 0" nopane37 '' 'notice cache_expiring 1 skipped: tmux has no pane %1'
gone_or_failed "tmux answers with nothing to read" answer '' 'notice cache_expiring 1 "project" shown'
# The deadline of the Stop falls due at once and the daemon runs it after the Stop's own post. The sentinel waits for both lines: written at once, it is read about as fast as the timer fires, and the skipped line would land before or after the sentinel's notice from one run to the next.
play "probe: a pane that is gone gets no cache warning, and its question is forgotten" "$(steps "$(tmuxmode nopane)" "$(start)" "$(row 1 'done' at=-3300)" "$(row 2 'done' at=-3300)" "$(ev PreToolUse 3 at=0 tool=AskUserQuestion text=q)" "$(ev Notification 3 at=6 sub=permission_prompt text=p)" "$(expect 'notice permission 3 ')" "$(ev Stop 1 at=-3300 text=d)" "$(expect 'notice turn_done 1 ')" "$(expect 'notice cache_expiring 1 skipped')" "$(quiet 600)" "$(sentinel)")"
must "probe: gone: a prompt is not held back" 'notice permission 3 '
must "probe: gone: skipped" 'notice cache_expiring 1 skipped: tmux has no pane %1'
must_count "probe: gone: no cache post" 'cache_expiring "' 0

t "the name of a notice: who is it about"
# The dashboard's order: the name typed for the session (labels.tsv, by session id), else for the pane, else the pane's title without its status glyph, else the name the session was started under, else the directory; the subtitle names the directory too unless the name already is it.
LABELS=state/labels.tsv
named() {  # <label> <what the name of session 1 comes from, as steps> <what the post line must hold>
  local label=$1 needle=$3
  play "name: $label" "$(steps "$2" "$(start)" "$(ev Stop 1 text=done)" "$(expect 'notice turn_done 1 ')")"
  must "name: $label" "$needle"
}
named "the directory when nothing else is known" "$(mkdir_ state)" '"project" "Answer ready" "done"'
named "typed for the session" "$(put $LABELS $'sid-1\tBy session\n')" '"By session" "Answer ready · project"'
named "typed for the pane" "$(put $LABELS $'%1\tBy pane\n')" '"By pane" "Answer ready · project"'
named "the session before the pane" "$(put $LABELS $'%1\tBy pane\nsid-1\tBy session\n')" '"By session" "Answer ready · project"'
named "the first line of a key" "$(put $LABELS $'sid-1\tFirst\nsid-1\tSecond\n')" '"First" "Answer ready · project"'
named "an empty name typed for the session is the answer, and the pane's name is not asked" "$(put $LABELS $'sid-1\t\n%1\tBy pane\n')" '"project" "Answer ready" "done"'
named "a line with no tab" "$(put $LABELS $'sid-1\n%1\tBy pane\n')" '"project" "Answer ready" "done"'
named "a file with carriage returns keeps them in the name" "$(put $LABELS $'sid-1\tCarriage\r\n')" '"Carriage\r" "Answer ready · project"'
named "a name that is the directory's" "$(put $LABELS $'sid-1\tproject\n')" '"project" "Answer ready" "done"'
named "a name in two scripts" "$(put $LABELS $'sid-1\tМой агент 🙂\n')" '"Мой агент 🙂" "Answer ready · project"'
named "an unrelated line before, and no final newline" "$(put $LABELS $'other\tOther\n\nsid-1\tLast')" '"Last" "Answer ready · project"'
named "the pane's title" "$(put 'rec/title.%1' 'Search index rebuild')" '"Search index rebuild" "Answer ready · project"'
named "the name typed beats the title" "$(put 'rec/title.%1' 'A title'),$(put $LABELS $'sid-1\tTyped\n')" '"Typed" "Answer ready · project"'
named "a title that is the machine's name is the directory" "$(put 'rec/title.%1' '@hostname@')" '"project" "Answer ready" "done"'
named "a title that is the short name of the machine" "$(put 'rec/title.%1' '@shorthost@')" '"project" "Answer ready" "done"'
play "name: the name the session was started under, when no title" "$(steps "$(start)" "$(ev Stop 1 text=done label=Nightly)" "$(expect 'notice turn_done 1 ')")"
must "name: the label" '"Nightly" "Answer ready · project"'
play "name: the title before the name it was started under" "$(steps "$(put 'rec/title.%1' 'Title')" "$(start)" "$(ev Stop 1 text=done label=Nightly)" "$(expect 'notice turn_done 1 ')")"
must "name: title over label" '"Title" "Answer ready · project"'
play "name: the directory, in the three shapes of a path" "$(steps "$(start)" "$(ev Stop 1 text=a cwd=/work/deep/dir/)" "$(ev Stop 2 text=b cwd=/)" "$(ev Stop 3 text=c cwd=)" "$(ev Stop 4 text=d cwd=relative/dir)" "$(ev Stop 5 text=e cwd=/work/a.b)" "$(expect 'notice turn_done 5 ')")"
must "cwd: a trailing slash" '"dir" "Answer ready" "a"'
must "cwd: the root" 'post tagents-2 turn_done "" "Answer ready" "b"'
must "cwd: none" 'post tagents-3 turn_done "" "Answer ready" "c"'
must "cwd: relative" '"dir" "Answer ready" "d"'
must "cwd: dotted" '"a.b" "Answer ready" "e"'
# Every title of a status glyph that is dropped, and the ones that are not: the first word, when it is one character and that is not a letter or a digit of ASCII, one of U+2000-U+2BFF or one of U+1F000-U+1FFFF.
UNTITLE=(
  '✳ Fix the bug' '⠂ Braille glyph' '🚀 Launch' '* Star' '1 Digit' 'x Letter' 'я иду' '✳' '✳✳ Two glyphs' 'Search index rebuild'
  '✳ ' '→ Arrow' '· Middle dot' '— Em dash' '# Heading' '#hash tag' '  Leading space' 'é Accent' '_ Underscore' '✳   Many spaces'
)
steps_titles=()
n=0
for title in "${UNTITLE[@]}"; do
  n=$((n + 1))
  steps_titles+=("$(put "rec/title.%$n" "$title")")
done
play "name: the glyphs of a pane's title" "$(steps "${steps_titles[@]}" "$(start)" "$(ev Stop 1 text=1)" "$(ev Stop 2 text=2)" "$(ev Stop 3 text=3)" "$(ev Stop 4 text=4)" "$(ev Stop 5 text=5)" "$(ev Stop 6 text=6)" "$(ev Stop 7 text=7)" "$(ev Stop 8 text=8)" "$(ev Stop 9 text=9)" "$(ev Stop 10 text=10)" "$(ev Stop 11 text=11)" "$(ev Stop 12 text=12)" "$(ev Stop 13 text=13)" "$(ev Stop 14 text=14)" "$(ev Stop 15 text=15)" "$(ev Stop 16 text=16)" "$(ev Stop 17 text=17)" "$(ev Stop 18 text=18)" "$(ev Stop 19 text=19)" "$(ev Stop 20 text=20)" "$(expect 'notice turn_done 20 ')")"
must "glyph: dingbat" '"Fix the bug" "Answer ready · project" "1"'
must "glyph: braille" '"Braille glyph" "Answer ready · project" "2"'
must "glyph: astral" '"Launch" "Answer ready · project" "3"'
must "glyph: ascii" '"Star" "Answer ready · project" "4"'
must "glyph: a digit is kept" '"1 Digit" "Answer ready · project" "5"'
must "glyph: a letter is kept" '"x Letter" "Answer ready · project" "6"'
must "glyph: a Cyrillic letter is kept" '"я иду" "Answer ready · project" "7"'
must "glyph: alone" '"✳" "Answer ready · project" "8"'
must "glyph: two" '"✳✳ Two glyphs" "Answer ready · project" "9"'
must "glyph: nothing left" '"project" "Answer ready" "11"'
must "glyph: latin-1" '"· Middle dot" "Answer ready · project" "13"'
must "glyph: a hash tag" '"#hash tag" "Answer ready · project" "16"'
must "glyph: leading space" '"  Leading space" "Answer ready · project" "17"'
must "glyph: many spaces" '"Many spaces" "Answer ready · project" "20"'

t "both locales"
# Every phrase of a banner, in the language TAGENTS_LOCALE names; `en` and `ru` exist, and anything else (another language, another case, a value with an encoding, an empty one, none) is English.
OPTS_ALL='backend = "log"
[events.session_end]
enabled = true'
every_phrase() {  # <label> <locale>: an event of every kind with no words, and the two cache warnings of the state rows
  LOCALE=$2
  OPTS=$OPTS_ALL
  play "locale: $1" "$(steps "$(row 7 'done' at=-3300)" "$(row 8 'done' at=-3575)" "$(start)" "$(expect 'notice cache_expiring ' 2)" "$(ev PreToolUse 1 tool=AskUserQuestion)" "$(ev PreToolUse 2 tool=ExitPlanMode)" "$(ev Notification 3 sub=permission_prompt)" "$(ev Stop 4)" "$(ev SessionEnd 5)" "$(ev SessionEnd 6 sub=logout)" "$(expect 'notice session_end 6 ')")"
}
every_phrase "Russian" ru
must "ru: question" '"project" "Задаёт вопрос" "Хочет что-то спросить"'
must "ru: plan" '"project" "План готов к проверке" "Хочет что-то спросить"'
must "ru: permission" '"project" "Нужно ваше разрешение" "Ждёт вашего разрешения"'
must "ru: turn" '"project" "Ответ готов" "Ваш ход"'
must "ru: end" '"project" "Сессия завершена" "Причина не указана"'
must "ru: end with a reason" '"project" "Сессия завершена" "logout"'
must "ru: cache" '"project" "Кэш промпта истекает" "Простой 55 мин — отправьте что угодно в течение ~5 мин, чтобы сохранить кэш промпта"'
must "ru: cache, within a minute" '"project" "Кэш промпта истекает" "Простой 60 мин — отправьте что угодно в течение минуты, чтобы сохранить кэш промпта"'
every_phrase "English" en
must "en: question" '"project" "Asks you something" "Asking you something"'
must "en: plan" '"project" "Plan ready for review" "Asking you something"'
must "en: permission" '"project" "Needs your permission" "Waiting for your permission"'
must "en: end" '"project" "Session ended" "No reason given"'
must "en: cache" '"project" "Prompt cache expiring" "Idle 55 min — send anything within ~5 min to keep the prompt cache"'
must "en: cache, within a minute" '"project" "Prompt cache expiring" "Idle 60 min — send anything within a minute to keep the prompt cache"'
for other in fr RU ru_RU.UTF-8 ' ru' '' -; do
  every_phrase "not a locale we speak: '$other'" "$other"
  must "locale '$other': English" '"project" "Asks you something" "Asking you something"'
done

t "the click a notice carries"
# `dock` (the default) opens the session's pane, `goto` goes to it, `focus` only raises the terminal, and so does a notice with no pane to go to; the script is TA_NOTIFY_TAGENTS, else the first `tagents` on PATH.
clicks() {  # <label> <click option> <what the post line must hold> [event field]...
  local label=$1 mode=$2 needle=$3
  shift 3
  OPTS="backend = \"log\"
click = \"$mode\""
  play "click: $label" "$(steps "$(start)" "$(ev Stop 1 text=done "$@")" "$(expect 'notice turn_done 1 ')")"
  must "click: $label" "$needle"
}
clicks "dock" dock 'click=/parity/bin/tagents --act open %1 live sid-1 /work/project pid='
clicks "goto" goto 'click=/parity/bin/tagents --goto %1 pid='
clicks "focus" focus 'click=terminal pid='
clicks "dock, with no pane" dock 'click=terminal pid=' pane=
clicks "goto, with no pane" goto 'click=terminal pid=' pane=
clicks "dock, a pane that is not the key's" dock 'click=/parity/bin/tagents --act open %7 live sid-1 /work/project pid=' pane=%7
clicks "dock, with no session id and no directory" dock 'click=/parity/bin/tagents --act open %1 live   pid=' sid= cwd=
clicks "dock, a directory with a space" dock 'click=/parity/bin/tagents --act open %1 live sid-1 /work/my project pid=' 'cwd=/work/my project'
CLICK_SCRIPT=
play "click: the first tagents on PATH" "$(steps "$(start)" "$(ev Stop 1 text=done)" "$(expect 'notice turn_done 1 ')")"
must "click: PATH" "click=TMP/shim/tagents --act open %1"
CLICK_SCRIPT=
EXTRA_ENV=(TA_NOTIFY_TAGENTS=)
play "click: an empty TA_NOTIFY_TAGENTS is none" "$(steps "$(start)" "$(ev Stop 1 text=done)" "$(expect 'notice turn_done 1 ')")"
must "click: empty" "click=TMP/shim/tagents --act open %1"
CLICK_SCRIPT='/a b/tagents'
play "click: a script whose path has a space" "$(steps "$(start)" "$(ev Stop 1 text=done)" "$(expect 'notice turn_done 1 ')")"
must "click: a space" 'click=/a b/tagents --act open %1'

t "the helper app (macOS)"
# What the daemon says to the helper is the whole of the macOS backend: `post` with the notice as JSON on stdin, `withdraw <id>`, and a line of JSON back. The stub helper records every call (helper <n> args, helper <n> stdin).
MAC='backend = "macos"'
OPTS=$MAC
play_mac "helper: a notice, and the withdraw of it" "$(steps "$(tmuxmode shown)" "$(start)" "$(ev PreToolUse 1 tool=AskUserQuestion text='Which colour?')" "$(expect 'notice question 1 ')" "$(ev UserPromptSubmit 1)" "$(sentinel)")"
must "helper: calls" 'helper 1 args ["post"]'
must "helper: the notice" '{"id":"tagents-1","thread":"sid-1","kind":"question","title":"project","subtitle":"Asks you something","body":"Which colour?","click":{"argv":["/parity/bin/tagents","--act","open","%1","live","sid-1","/work/project"],"env":{'
must "helper: the environment a click runs in" '"TAGENTS_CONFIG_DIR":"TMP/run/config"}},"terminalPid":4242,"skipIfFrontmost":true}'
must "helper: the withdraw" 'helper 2 args ["withdraw","tagents-1"]'
must "helper: the sentinel is the third call" 'helper 3 args ["post"]'
must_count "helper: one withdraw" '"withdraw"' 1
OPTS=$MAC
play_mac "helper: no pid and no policy when no client is found" "$(steps "$(tmuxmode noclient)" "$(start)" "$(ev Stop 1 text=done)" "$(expect 'notice turn_done 1 ')")"
must "helper: no pid" '"body":"done","click":{'
must_not "helper: no pid" 'terminalPid'
OPTS=$MAC
play_mac "helper: a pane behind another window carries its pid and no policy" "$(steps "$(tmuxmode hidden)" "$(start)" "$(ev Stop 1 text=done)" "$(expect 'notice turn_done 1 ')")"
must "helper: hidden" '"terminalPid":4242}'
OPTS="$MAC
click = \"focus\""
play_mac "helper: a click that only raises the terminal" "$(steps "$(start)" "$(ev Stop 1 text=done)" "$(expect 'notice turn_done 1 ')")"
must "helper: focus" '"click":{"argv":[],"env":{'
OPTS=$MAC
play_mac "helper: a withdraw of a notice that was never up calls nothing" "$(steps "$(start)" "$(ev PreToolUse 1 tool=AskUserQuestion text=q)" "$(expect 'notice question 1 ')" "$(ev UserPromptSubmit 2)" "$(sentinel)")"
must "helper: a withdraw of another key" 'helper 2 args ["post"]'
must_count "helper: no withdraw call" '"withdraw"' 0
OPTS=$MAC
fixture words "$(printf '{"type":"assistant","message":{"content":[{"type":"text","text":"bell \\u0007 escape \\u001b[31m line \\u2028 separator \\u00e9 \\ud83d\\ude00 slash \\\\ quote \\" tab \\t end"}]}}')"
play_mac "helper: the body and the name are JSON, whatever they hold" "$(steps "$(putfile transcripts/t.jsonl "$TMP/fixtures/words.jsonl")" "$(start)" "$(ev Stop 1 transcript=transcripts/t.jsonl 'cwd=/work/ünï "q" \b 😀')" "$(expect 'notice turn_done 1 ')")"
must "helper: escapes" '\u0007'

failing() {  # <label> <helper mode> <what the post line must hold>: the helper answers so for a turn_done, and ok for the next one
  OPTS=$MAC
  play_mac "helper: $1" "$(steps "$(helpermodes "$2" ok)" "$(start)" "$(ev Stop 1 text=done)" "$(ev Stop 2 text=done)" "$(expect 'notice turn_done 2 ')")"
  must "helper: $1" "$3"
}
failing "ok, shown" ok 'notice turn_done 1 "project" shown'
failing "failed" failed 'post failed turn_done 1 notifications are denied'
failing "failed, no reason" failed-bare 'post failed turn_done 1 the notification helper failed'
failing "not JSON" garbage 'unreadable output from the notification helper: stdout "this is not json\n", stderr "and this is stderr\n"'
failing "not an object" notanobject 'unreadable output from the notification helper: stdout "[1,2]\n", stderr ""'
failing "nothing said" empty 'unreadable output from the notification helper: stdout "", stderr ""'
failing "exit 3, nothing said" exit3 'unreadable output from the notification helper: stdout "", stderr "crashed\n"'
failing "exit 3, but ok said" exit3ok 'notice turn_done 1 "project" shown'
failing "shown of the wrong type" badtype 'unreadable output from the notification helper: stdout "{\"ok\":true,\"shown\":\"yes\"}\n", stderr ""'
failing "two lines" twolines 'unreadable output from the notification helper: stdout "{\"ok\":true,\"shown\":true}\n{\"ok\":true,\"shown\":true}\n", stderr ""'
failing "blank lines around it" padded 'notice turn_done 1 "project" shown'
failing "ok and no shown" noshown 'notice turn_done 1 "project" dropped'
failing "ok and fields nobody reads" extra 'notice turn_done 1 "project" shown'
failing "hidden, and why" hidden 'notice turn_done 1 "project" dropped: the terminal is in front'
# The first 200 characters of what the helper wrote are quoted, in UTF-16 units: a pair of surrogates that the 200th unit cuts in two is quoted as a lone surrogate, which JSON writes as an escape.
failing "300 characters of garbage" longgarbage "stdout \"$(rep g 200)\", stderr \"$(rep e 200)\""
failing "emoji garbage, cut in half of a pair" astral "stdout \"a$(rep 😀 99)"'\ud83d", stderr "a'

# A failed post is told once per message until a post works again; a failed withdraw is told each time.
OPTS=$MAC
play_mac "helper: a failure is told once per message, until posting works again" "$(steps "$(helpermodes failed failed failed-bare ok failed)" "$(start)" "$(ev Stop 1 text=a)" "$(ev Stop 2 text=b)" "$(ev Stop 3 text=c)" "$(ev Stop 4 text=d)" "$(ev Stop 5 text=e)" "$(sentinel)")"
must_count "helper once: the first message" 'post failed turn_done' 3
must_count "helper once: the second message was told" 'post failed turn_done 3 the notification helper failed' 1
must_count "helper once: told again after posting worked" 'post failed turn_done 5 notifications are denied' 1
must_count "helper once: worked again, twice" 'posting works again' 2
OPTS=$MAC
play_mac "helper: a failed withdraw is told" "$(steps "$(helpermodes ok failed)" "$(start)" "$(ev PreToolUse 1 tool=AskUserQuestion text=q)" "$(expect 'notice question 1 ')" "$(ev UserPromptSubmit 1)" "$(expect 'withdraw failed tagents-1 ')")"
must "helper: the withdraw failed" 'withdraw failed tagents-1 notifications are denied'
# A post that is dropped takes the old notice with the same id down, when it was up; one that failed leaves it up; one that was never up has nothing to take down.
OPTS=$MAC
play_mac "helper: a dropped post takes the old notice down" "$(steps "$(helpermodes ok hidden)" "$(start)" "$(ev Stop 1 text=a)" "$(ev Stop 1 text=b)" "$(expect 'withdraw tagents-1')")"
must "helper: dropped, then withdrawn" 'helper 3 args ["withdraw","tagents-1"]'
OPTS=$MAC
play_mac "helper: a dropped post of a notice that was never up takes nothing down" "$(steps "$(helpermodes hidden)" "$(start)" "$(ev Stop 1 text=a)" "$(sentinel)")"
must "helper: dropped" 'notice turn_done 1 "project" dropped'
must_count "helper: no withdraw" '"withdraw"' 0
OPTS=$MAC
play_mac "helper: a post that failed leaves the old notice up" "$(steps "$(helpermodes ok failed)" "$(start)" "$(ev Stop 1 text=a)" "$(ev Stop 1 text=b)" "$(expect 'post failed turn_done 1 ')" "$(ev UserPromptSubmit 1)" "$(expect 'withdraw tagents-1')")"
must "helper: failed, then withdrawn" 'helper 3 args ["withdraw","tagents-1"]'
# What a question that did not reach the screen holds back: nothing.
OPTS=$MAC
play_mac "helper: a question on screen holds a permission prompt back" "$(steps "$(start)" "$(ev PreToolUse 1 tool=AskUserQuestion text=q)" "$(expect 'notice question 1 ')" "$(ev Notification 1 sub=permission_prompt text=p)" "$(sentinel)")"
must "helper: held" 'permission prompt held back by the question on screen 1'
OPTS=$MAC
play_mac "helper: a question that was dropped holds nothing back" "$(steps "$(helpermodes hidden)" "$(start)" "$(ev PreToolUse 1 tool=AskUserQuestion text=q)" "$(expect 'notice question 1 ')" "$(ev Notification 1 sub=permission_prompt text=p)" "$(expect 'notice permission 1 ')")"
must_not "helper: not held" 'held back'
OPTS=$MAC
play_mac "helper: a question whose post failed holds nothing back" "$(steps "$(helpermodes failed)" "$(start)" "$(ev PreToolUse 1 tool=AskUserQuestion text=q)" "$(expect 'post failed question 1 ')" "$(ev Notification 1 sub=permission_prompt text=p)" "$(expect 'notice permission 1 ')")"
must_not "helper: not held" 'held back'
# The helper that is not there, one that cannot be run, and one that does not answer in five seconds (the helper is killed then, and the next notice is posted after it).
NOAPP=1
OPTS=$MAC
play_mac "helper: the app is not there" "$(steps "$(start)" "$(ev Stop 1 text=a)" "$(expect 'post failed turn_done 1 ')")"
must "helper: no app" "post failed turn_done 1 cannot start the notification helper at TMP/no-app/TagentsNotify.app (spawn TMP/no-app/TagentsNotify.app/Contents/MacOS/tagents-notify ENOENT); run \`tagents notify install\`"
NOEXEC=1
OPTS=$MAC
play_mac "helper: the app cannot be run" "$(steps "$(start)" "$(ev Stop 1 text=a)" "$(expect 'post failed turn_done 1 ')")"
must "helper: not executable" "post failed turn_done 1 cannot start the notification helper at TMP/no-exec/TagentsNotify.app (spawn TMP/no-exec/TagentsNotify.app/Contents/MacOS/tagents-notify EACCES); run \`tagents notify install\`"
OPTS=$MAC
play_mac "helper: no answer in five seconds" "$(steps "$(helpermodes slow ok)" "$(start)" "$(ev Stop 1 text=a)" "$(ev Stop 2 text=b)" "$(expect 'notice turn_done 2 ' 1 30000)")"
must "helper: timed out" 'post failed turn_done 1 the notification helper timed out after 5 s'
must_before "helper: the second after the first" 'post failed turn_done 1 ' 'notice turn_done 2 '


t "the options file: bad documents, at start and at reload"
# Documents that are TOML and that the schema refuses. The daemon logs each problem (`options: <where>: <what>`), runs on the defaults, and says `invalid` in its started line; a document that is not TOML is a known difference (the parser's own words). The backend is then `auto`, which is the helper on macOS and no backend at all elsewhere: there the daemon leaves after the problems, and the scenario waits for either. The same document is then put into the file of a daemon that started on a valid one: it logs the same problems, and a good document after them is a reload.
CFG=config/plugins/notify.toml
LOGB='backend = "log"'
bad_options() {  # <label> <document> <the first problem line it must give> [how many problem lines there are]
  OPTS=$2
  play "options at start: $1" "$(steps "$(start settled)")"
  must "options at start: $1" "options: $3"
  must_count "options at start: $1, the problems" 'options: ' "${4:-1}"
  if [ "$OS" = Darwin ]; then must "options at start: $1, invalid in the started line" 'config/plugins/notify.toml (invalid)'; fi
  play "options at reload: $1" "$(steps "$(start)" "$(put $CFG "$2")" "$(expect "options: $3")" "$(put $CFG "$LOGB
click = \"goto\"")" "$(expect 'options reloaded')" "$(sentinel)")"
  must "options at reload: $1" "options: $3"
  must_count "options at reload: $1, the problems" 'options: ' "${4:-1}"
  must "options at reload: $1, the good one" 'click=/parity/bin/tagents --goto %99'
}
bad_options "an unknown key" 'colour = "red"' 'Unrecognized key: "colour"'
bad_options "several unknown keys, the array indexes first" 'zeta = 1
10 = 1
alpha = 1
2 = 1' 'Unrecognized keys: "2", "10", "zeta", "alpha"'
bad_options "an unknown backend" 'backend = "telepathy"' 'backend: Invalid option: expected one of "auto"|"macos"|"log"|"none"'
bad_options "an unknown click" 'click = "bounce"' 'click: Invalid option: expected one of "dock"|"goto"|"focus"'
bad_options "a backend that is not a string" 'backend = 3' 'backend: Invalid option: expected one of "auto"|"macos"|"log"|"none"'
bad_options "an unknown kind of event" '[events.sneeze]
enabled = true' 'events: Unrecognized key: "sneeze"'
bad_options "an unknown key of an event" '[events.question]
skip_visble = true' 'events.question: Unrecognized key: "skip_visble"'
bad_options "a flag that is not a boolean" '[events.turn_done]
enabled = "yes"' 'events.turn_done.enabled: Invalid input: expected boolean, received string'
bad_options "events that are not a table" 'events = 3' 'events: Invalid input: expected object, received number'
bad_options "a duration that is not one" '[events.cache_expiring]
after = "1.5h"' 'events.cache_expiring.after: not a duration: "1.5h" (use 90, 45s, 50m, 2h or 1h30m)'
bad_options "a duration that is negative" '[events.cache_expiring]
ttl = -5' 'events.cache_expiring.ttl: not a duration: -5 (use 90, 45s, 50m, 2h or 1h30m)'
bad_options "a duration that is a boolean" '[events.cache_expiring]
after = true' 'events.cache_expiring.after: Invalid input'
bad_options "after not below ttl" '[events.cache_expiring]
after = "60m"
ttl = "60m"' 'events.cache_expiring.after: after must be below ttl: a notice about a cache that already expired helps nobody'
bad_options "an empty icon" 'icon = ""' 'icon: Too small: expected string to have >=1 characters'
bad_options "several problems at once, in the order of the schema" 'backend = "x"
click = "y"
[events.cache_expiring]
after = "2h"
[events.nothing]
enabled = false' 'backend: Invalid option: expected one of "auto"|"macos"|"log"|"none"' 4

t "the options file: reloads"
# The options file is watched while the daemon runs: a change to what it says is `options reloaded`, a problem is told once however often the file is read, and the same document again is nothing. The daemon is started on a valid document so that it runs on every OS. A write is waited for through the line it gives; the ones that give none are followed by one that does.
play "options reload: a bad document is told once, a good one is taken" "$(steps "$(start)" "$(put $CFG 'click = "bounce"')" "$(expect 'options: click: ')" "$(put $CFG 'click = "bounce"
# the same problem again')" "$(put $CFG 'backend = "telepathy"')" "$(expect 'options: backend: ')" "$(put $CFG "$LOGB
click = \"goto\"")" "$(expect 'options reloaded')" "$(sentinel)")"
must_count "reload: the problems" 'options: ' 2
must "reload: the good one" 'click=/parity/bin/tagents --goto %99'
play "options reload: the same document is not a reload" "$(steps "$(start)" "$(put $CFG "$LOGB
# a comment")" "$(put $CFG "$LOGB
click = \"focus\"")" "$(expect 'options reloaded')" "$(sentinel)")"
must_count "reload: once" 'options reloaded' 1
must "reload: the change" 'click=terminal'
play "options reload: a kind switched off takes effect" "$(steps "$(start)" "$(put $CFG "$LOGB
[events.turn_done]
enabled = false")" "$(expect 'options reloaded')" "$(ev Stop 1 text=done)" "$(sentinel_permission)")"
must_not "reload: no turn_done" 'notice turn_done'
must "reload: the permission sentinel" 'notice permission 99 '
play "options reload: a backend change waits for a restart" "$(steps "$(start)" "$(put $CFG 'backend = "none"')" "$(expect 'backend changes take effect after a restart')" "$(sentinel)")"
must "reload: the line" 'options reloaded'
must "reload: the notice still goes where it went" 'notice turn_done 99 '
play "options reload: the file removed is the defaults" "$(steps "$(start)" "$(remove_ $CFG)" "$(expect 'options reloaded')" "$(sentinel)")"
must "reload: removed" 'backend changes take effect after a restart'
play "options reload: the file removed and put back" "$(steps "$(start)" "$(remove_ $CFG)" "$(expect 'options reloaded')" "$(put $CFG "$LOGB")" "$(expect 'options reloaded' 2)" "$(sentinel)")"
must_count "reload: twice" 'options reloaded' 2

t "the options file: where it lives"
# A symlinked file whose link is replaced is a reload (the directory changes); an edited target is not a scenario (issue #39: the node watcher does not see it on every system).
NOFILE=1
play "options file: a symlink, replaced by another" "$(steps "$(put config/plugins/a.toml "$LOGB
click = \"goto\"")" "$(put config/plugins/b.toml "$LOGB
click = \"focus\"")" "$(symlink_ a.toml config/plugins/notify.toml)" "$(start)" "$(ev Stop 1 text=a)" "$(expect 'notice turn_done 1 ')" "$(symlink_ b.toml config/plugins/notify.toml)" "$(expect 'options reloaded')" "$(ev Stop 2 text=b)" "$(expect 'notice turn_done 2 ')")"
must "symlink: the first target" 'click=/parity/bin/tagents --goto %1'
must "symlink: the second target" 'click=terminal'
NOFILE=1
play "options file: a symlink into another directory, replaced by another" "$(steps "$(put dotfiles/a.toml "$LOGB
click = \"goto\"")" "$(put dotfiles/b.toml "$LOGB
click = \"focus\"")" "$(symlink_ ../../dotfiles/a.toml config/plugins/notify.toml)" "$(start)" "$(ev Stop 1 text=a)" "$(expect 'notice turn_done 1 ')" "$(symlink_ ../../dotfiles/b.toml config/plugins/notify.toml)" "$(expect 'options reloaded')" "$(ev Stop 2 text=b)" "$(expect 'notice turn_done 2 ')")"
must "symlink elsewhere: the first target" 'click=/parity/bin/tagents --goto %1'
must "symlink elsewhere: the second target" 'click=terminal'
play "options file: the plugins directory is a symlink" "$(steps "$(put dotfiles/plugins/notify.toml "$LOGB")" "$(remove_ config/plugins)" "$(symlink_ ../dotfiles/plugins config/plugins)" "$(start)" "$(put dotfiles/plugins/notify.toml "$LOGB
click = \"goto\"")" "$(expect 'options reloaded')" "$(sentinel)")"
must "plugins symlink: the change" 'click=/parity/bin/tagents --goto %99'
play "options file: another file in the directory is not a reload" "$(steps "$(start)" "$(put config/plugins/other.toml 'click = "bounce"')" "$(put config/plugins/notify.toml.bak 'click = "bounce"')" "$(put config/plugins/knowledge.toml 'backend = "none"')" "$(put $CFG "$LOGB
click = \"goto\"")" "$(expect 'options reloaded')" "$(sentinel)")"
must_count "other files: one reload" 'options reloaded' 1
must_count "other files: no problem" 'options: ' 0
# A daemon that starts with no options file, no plugins directory or no config directory runs on the defaults, whose backend is `auto`: the helper on macOS, and on every other system no backend at all, where the daemon leaves. So the scenarios that go on from there run on macOS only, the helper's calls telling what the notice carried, and the start itself is a scenario everywhere.
not_found_at_start() {  # <label> [<what the log says on macOS>]: the log says it, where there is a log to say it
  if [ "$OS" = Darwin ]; then must "$1: told" "${2:-notify.toml (not found)}"; elif [ "$OS" = Linux ]; then must "$1: no backend on linux" 'no notification backend for linux yet; exiting'; fi
}
NOFILE=1
play "options file: not found at start" "$(steps "$(start settled)")"
not_found_at_start "options file: not found"
NOPLUGINS=1
play "options file: no plugins directory at start" "$(steps "$(start settled)")"
not_found_at_start "options file: no plugins directory"
NOCONFIG=1
play "options file: no config directory at start" "$(steps "$(start settled)")"
not_found_at_start "options file: no config directory" 'options reload is off: TMP/run/config does not exist'
GOTO='"argv":["/parity/bin/tagents","--goto","%99"]'
NOPLUGINS=1
play_mac "options file: a plugins directory that is made later" "$(steps "$(start)" "$(mkdir_ config/plugins)" "$(put $CFG "$MAC
click = \"goto\"")" "$(expect 'options reloaded')" "$(sentinel)")"
must "late plugins: not found at start" 'notify.toml (not found)'
must "late plugins: the change" "$GOTO"
NOFILE=1
play_mac "options file: a file that is made later" "$(steps "$(start)" "$(put $CFG "$MAC
click = \"goto\"")" "$(expect 'options reloaded')" "$(sentinel)")"
must "late file: not found at start" 'notify.toml (not found)'
must "late file: the change" "$GOTO"
NOCONFIG=1
# The pause is the point: with no config directory there is nothing to watch, and the file made now must not be read.
play_mac "options file: no config directory, so no reload" "$(steps "$(start)" "$(mkdir_ config/plugins)" "$(put $CFG "$MAC
click = \"goto\"")" "$(quiet 600)" "$(sentinel)")"
must "no config: not found at start" 'notify.toml (not found)'
must "no config: the click is the default" '"argv":["/parity/bin/tagents","--act","open","%99","live","sid-99","/work/project"]'
OPTS=''
play "options file: an empty document is the defaults" "$(steps "$(start settled)")"
if [ "$OS" = Darwin ]; then must "empty document: the helper is the default backend" 'backend macos options'; elif [ "$OS" = Linux ]; then must "empty document: no backend on linux" 'no notification backend for linux yet; exiting'; fi
OPTS='backend = "log"'
play "options file: the log backend, named" "$(steps "$(start settled)")"
must "log backend: the started line" 'started pid PID backend log options TMP/run/config/plugins/notify.toml (found)'

t "the lock, the backend none, a start that fails"
# One notify daemon per state directory, whichever kind: the second one says who holds the lock and leaves with 0. The scenario runs once per kind of first, because the daemon of the other kind is the second (node first and rust second in the node transcript, the other way round in the rust one), and the two transcripts must be the same.
play "lock: a second daemon leaves, whoever the first is" "$(steps "$(start)" "$(second)" "$(ev Stop 1 text=done)" "$(expect 'notice turn_done 1 ')")"
HELD='another notify service holds TMP/run/state/notify.lock (pid daemon); exiting'
must "lock: the second said who holds it" "second-stderr	TS $HELD"
must "lock: it left" 'second-exit 0'
must_count "lock: the first one posted" 'notice turn_done 1 ' 1
# A lock that is not held is taken: the process it names is gone, or is another process that has that pid now (its start time differs), or the file is a bare pid that is dead or older than the boot, and a file that says nothing sensible is taken too. The proof that it was taken is a second daemon, which finds it held. A bare pid that is alive is held, and the daemon leaves.
lock_taken() {  # <kind>
  play "lock: $1 is taken" "$(steps "$(lock_ "$1")" "$(start)" "$(second)" "$(ev Stop 1 text=done)" "$(expect 'notice turn_done 1 ')")"
  must "lock $1: the daemon started" 'started pid PID'
  must "lock $1: and holds it now" "second-stderr	TS $HELD"
}
for kind in dead reused bare-dead bare-old junk empty; do lock_taken $kind; done
play "lock: a bare pid that is alive is held" "$(steps "$(lock_ bare-live)" "$(start exit)")"
must "lock bare-live: held" "stderr	TS another notify service holds TMP/run/state/notify.lock (pid driver); exiting"
must "lock bare-live: it left" 'exit 0'
must "lock bare-live: the file is the script's" 'lock as the script wrote it (bare-live)'
OPTS='backend = "none"'
play "backend none: nothing to post, and the daemon leaves" "$(steps "$(start exit)")"
must "none" 'backend none: nothing to post; exiting'
BLOCKSTATE=1
HANDOVER=1
# A start that fails is the node CLI's own message and exit code 1. The Rust daemon hands such a start over to the node service, and says so on a line only it writes (the HANDOVER line, taken out of the transcripts), so the node service's message is what the scenario compares.
play "start: the state directory cannot be made" "$(steps "$(start exit)")"
must "state: the message" "stderr	the notify service stopped: ENOTDIR: not a directory, mkdir 'TMP/run/blocker/state'"
must "state: the exit code" 'exit 1'
must_not "state: no started line" 'started'

t "signals"
# SIGTERM, SIGINT and SIGHUP stop the daemon the same way: `stopping (<signal>)`, the posts in flight finished, the lock released, exit 0. The post in flight is held in the tmux shim (`hold`: the probe answers when rec/release exists), so the signal arrives while the notice is half posted; an event written after the signal is not taken.
for sig in SIGTERM SIGINT SIGHUP; do
  play "signal: $sig, idle" "$(steps "$(start)" "$(signal_ $sig)" "$(exited)")"
  must "$sig: idle" "stopping ($sig)"
  must "$sig: exit" 'exit 0'
  play "signal: $sig, with a post in flight" "$(steps "$(tmuxmode hold)" "$(start)" "$(ev Stop 1 text=done)" "$(file rec/tmux.held)" "$(signal_ $sig)" "$(expect "stopping ($sig)")" "$(ev Stop 2 text=late)" "$(put rec/release '')" "$(exited)")"
  must_before "$sig: the post after the signal" "stopping ($sig)" 'notice turn_done 1 '
  must_not "$sig: the event written after the signal is not taken" 'turn_done 2'
  must "$sig: the lock is released" 'lock absent'
done
OPTS=$MAC
play_mac "signal: SIGTERM, with the helper not answering" "$(steps "$(helpermodes slow)" "$(start)" "$(ev Stop 1 text=done)" "$(file rec/h.1)" "$(signal_ SIGTERM)" "$(expect 'post failed turn_done 1 the notification helper timed out after 5 s' 1 30000)" "$(exited)")"
must_before "signal: the helper's deadline is waited for" 'stopping (SIGTERM)' 'post failed turn_done 1 '

t "the event file: rotation, truncation, a file that is replaced, lines that are not events"
# The follower rotates the file itself at 1 MiB (events.tsv becomes events.tsv.1, a fresh events.tsv is followed), reads again from 0 when the file got shorter or is another file, and takes a line only when it is whole and has the 13 fields. SubagentStop is an event that gives no notice, so a megabyte of them says nothing but the rotation, and the Stop after it proves that the events after the rotation are taken. Rotation is waited for by the file it makes.
# 1024 identical lines of 1025 bytes (57 bytes of a SubagentStop of key 1 as eventLine writes it, and 968 of padding) are 1,049,600 bytes, of which all but the last are 1,048,575: one byte under the rotation size, so the follower can only rotate after the last line, and the fresh file is empty however the writes and the reads interleave.
LINE_PAD=968
rotation() {  # <label> <one write | many>
  play "events: rotation at 1 MiB, $1" "$(steps "$(start)" "$(burst 1024 "$2" $LINE_PAD SubagentStop 1 agent=a)" "$(file state/events.tsv.1)" "$(ev Stop 1 text=after)" "$(expect 'notice turn_done 1 ')")"
  must "rotation $1: the file" 'state events.tsv events.tsv.1'
  must "rotation $1: the fresh file holds the event after it and nothing else" 'size events.tsv 53'
  must "rotation $1: the old file holds all the lines" 'size events.tsv.1 1049600'
}
rotation "in one write" one
rotation "in a tight loop of writes" many
# The follower rotates again only on a wake after the grace of 2 s the first rotation left the old file open for, so the pause is the point: it is longer than the grace by a margin a slow machine does not eat.
play "events: a second rotation replaces the first file" "$(steps "$(start)" "$(burst 1024 one $LINE_PAD SubagentStop 1 agent=a)" "$(file state/events.tsv.1)" "$(remove_ state/events.tsv.1)" "$(burst 1024 one $LINE_PAD SubagentStop 1 agent=a)" "$(quiet 3500)" "$(ev SubagentStop 1 agent=a)" "$(file state/events.tsv.1)" "$(ev Stop 1 text=after)" "$(expect 'notice turn_done 1 ')")"
must "second rotation: the file" 'state events.tsv events.tsv.1'
must "second rotation: the fresh file holds the event after it and nothing else" 'size events.tsv 53'
must "second rotation: the old file holds the burst and the wake" 'size events.tsv.1 1049657'
play "events: one line longer than the rotation size and the read chunk" "$(steps "$(start)" "$(burst 1 one 1100000 Stop 1 text=big)" "$(expect 'notice turn_done 1 ' 1 30000)" "$(file state/events.tsv.1)" "$(ev Stop 2 text=after)" "$(expect 'notice turn_done 2 ')")"
must "long line: the body is the first 200 characters" '"Answer ready" "big'
play "events: the hook moves the file away" "$(steps "$(start)" "$(ev Stop 1 text=a)" "$(expect 'notice turn_done 1 ')" "$(rename_ state/events.tsv state/events.tsv.1)" "$(ev Stop 2 text=b)" "$(expect 'notice turn_done 2 ')")"
must "moved: the file" 'state events.tsv events.tsv.1'
play "events: the file is removed" "$(steps "$(start)" "$(ev Stop 1 text=a)" "$(expect 'notice turn_done 1 ')" "$(remove_ state/events.tsv)" "$(ev Stop 2 text=b)" "$(expect 'notice turn_done 2 ')")"
printf '4102444800\tStop\t2\tsid-2\t\t%%2\t/work/project\t\t\t\t\tfrom another file\t\n' > "$TMP/fixtures/replacing.tsv"
play "events: another file takes its place, and is read from its start" "$(steps "$(start)" "$(ev Stop 1 text=a)" "$(expect 'notice turn_done 1 ')" "$(putfile state/events.new "$TMP/fixtures/replacing.tsv")" "$(rename_ state/events.new state/events.tsv)" "$(expect 'notice turn_done 2 ')")"
must "replaced: the new file's line" '"Answer ready" "from another file"'
play "events: the file is cut to nothing, and what is written after is taken" "$(steps "$(start)" "$(ev Stop 1 text='a long first line to be cut away')" "$(ev Stop 2 text='and a second one that is just as long')" "$(expect 'notice turn_done 2 ')" "$(trunc_ state/events.tsv)" "$(ev Stop 3 text=c)" "$(expect 'notice turn_done 3 ')")"
must "truncated: the event after the cut" '"Answer ready" "c"'
must_count "truncated: three notices" 'notice turn_done' 3

raw_() { printf '{"do":"raw","text":"%s"}' "$(jstr "$1")"; }   # the text as it is: the newline, or the lack of one, is the caller's
evl() { printf '%s\tStop\t%s\tsid-%s\t\t%%%s\t/work/project\t\t\t\t\t%s\t' "$1" "$2" "$2" "$2" "$3"; }   # <at> <key> <text>: a whole line of 13 fields, with no newline
short=$(evl @now@ 13 bad13)
play "events: lines that are not events are passed over" "$(steps "$(start)" "$(raw_ "$(evl @now@ 12 ok12)"$'\n')" "$(raw_ "${short%$'\t'}"$'\n')" "$(raw_ "$(evl @now@ 14 ok14)"$'\textra\n')" "$(raw_ "$(evl @now@ 15 ok15)"$'\r\n')" "$(raw_ "$(evl @now@ 16 bad16 | sed 's/Stop/Stopp/')"$'\n')" "$(raw_ "$(evl soon 17 bad17)"$'\n')" "$(raw_ "$(evl '' 18 bad18)"$'\n')" "$(raw_ "$(evl @now@ 19 bad19 | tr '\t' ' ')"$'\n')" "$(raw_ "$(evl @now@ 20 bad20 | sed 's/Stop/stop/')"$'\n')" "$(raw_ $'\n   \n\t\t\t\t\t\t\t\t\t\t\t\t\n')" "$(raw_ "$(evl @now@ '' ok-no-key)"$'\n')" "$(sentinel)")"
must_count "lines: the accepted ones and the sentinel" 'notice turn_done' 5
must "lines: ok12" 'notice turn_done 12 '
must "lines: 14 fields" 'notice turn_done 14 '
must "lines: CRLF" 'notice turn_done 15 '
must "lines: no key" 'notice turn_done  '
must_not "lines: 12 fields" 'turn_done 13 '
# The `at` of an event is read the way JavaScript's Number reads a string: hexadecimal, binary, octal, an exponent, a sign, a leading or trailing point and spaces around are numbers, and underscores, a comma, Infinity (and what overflows to it), NaN and half a prefix are not.
play "events: the time of an event is read as a JavaScript number" "$(steps "$(start)" "$(raw_ "$(evl 0x1F 31 hex)"$'\n')" "$(raw_ "$(evl 0b11 32 binary)"$'\n')" "$(raw_ "$(evl 0o7 33 octal)"$'\n')" "$(raw_ "$(evl 1e1 34 exponent)"$'\n')" "$(raw_ "$(evl .5 35 point)"$'\n')" "$(raw_ "$(evl '5.' 36 trailing)"$'\n')" "$(raw_ "$(evl +5 37 plus)"$'\n')" "$(raw_ "$(evl -3 38 minus)"$'\n')" "$(raw_ "$(evl ' 7 ' 39 spaces)"$'\n')" "$(raw_ "$(evl 1_0 41 underscore)"$'\n')" "$(raw_ "$(evl Infinity 42 infinity)"$'\n')" "$(raw_ "$(evl NaN 43 nan)"$'\n')" "$(raw_ "$(evl 0x 44 prefix)"$'\n')" "$(raw_ "$(evl 1e 45 half-exponent)"$'\n')" "$(raw_ "$(evl --1 46 two-signs)"$'\n')" "$(raw_ "$(evl 1,5 47 comma)"$'\n')" "$(raw_ "$(evl 1e400 48 overflow)"$'\n')" "$(sentinel)")"
must_count "at: nine accepted and the sentinel" 'notice turn_done' 10
must "at: spaces" 'notice turn_done 39 '
must_not "at: underscore" 'turn_done 41 '
must_not "at: overflow" 'turn_done 48 '
# A line is an event once its newline is there: the whole of it with no newline is waited for (the pause is the point), and one that is written in two parts is one event.
play "events: a last line with no newline is not taken" "$(steps "$(start)" "$(raw_ "$(evl @now@ 51 held)")" "$(quiet 500)")"
must_not "unterminated: not taken" 'turn_done 51 '
line=$(evl @now@ 52 split)
play "events: a line written in two parts is one event" "$(steps "$(start)" "$(raw_ "${line:0:30}")" "$(raw_ "${line:30}"$'\n')" "$(expect 'notice turn_done 52 ')")"
must "split: taken" '"Answer ready" "split"'

t "two thousand events"
# Every event of a burst gives one notice, in the order they were written, whether the burst is one write or a tight loop of writes.
for mode in many one; do
  play "events: two thousand events, $mode" "$(steps "$(start)" "$(burst 2000 $mode 0 Stop '{n}' text='n{n}')" "$(expect 'notice turn_done 2000 ' 1 240000)")"
  must_count "2000 $mode: all of them" 'notice turn_done' 2000
  must_before "2000 $mode: in order" 'notice turn_done 1 ' 'notice turn_done 2000 '
done

t "resource use: the Rust daemon alone"
# Task 7.4, against the Rust daemon only (node's numbers are not the reference). The driver starts it on a scratch, lets it idle for ten seconds, reads its processor time, its threads and its descriptors, then rewrites the options file twelve times by replacing it and twelve times in place, and reads the descriptors again; each line of its report is one fact, judged here against the requirement "Resource use" of the notify-service spec. Linux counts what /proc says, macOS what `ps -M` and `lsof` say. Under PARITY_SELF_TEST there is no Rust daemon and nothing is checked.
# The descriptors of the report from number 3 up (0, 1 and 2 are the driver's stdio) of one kind that name something holding the text.
fds_of() {  # <report> <kind> [text]
  printf '%s\n' "$1" | awk -v kind="$2" -v text="${3:-}" '$1 == "fd" && $2 >= 3 && $3 == kind && (text == "" || index($4, text) > 0) { n++ } END { print n + 0 }'
}
# The report's descriptors of a kind are as many as wanted.
want_fds() {  # <report> <what it is> <wanted> <kind> [text]
  local found
  found=$(fds_of "$1" "$4" "${5:-}")
  if [ "$found" = "$3" ]; then ok; else bad "resources: $2: $found descriptors, wanted $3" "descriptors at rest: $(printf '%s\n' "$1" | grep '^fd ' | tr '\n' '|')"; fi
}
resource_checks() {
  local label="resources: the Rust daemon at rest, and through reloads" report growth threads after rest reloads
  [ -z "$SELF_TEST" ] && selected "$label" || return 0
  ran=$((ran + 1))
  report=$(alone resources 2> "$TMP/resources.err") || { bad "$label: the driver failed (exit $?)" "$(head -c 400 "$TMP/resources.err" | tr '\n' '|')"; return; }
  if ! printf '%s\n' "$report" | grep -q '^started yes$'; then bad "$label: the daemon never said it had started" "$(printf '%s\n' "$report" | tr '\n' '|' | head -c 400)"; return; fi
  if printf '%s\n' "$report" | grep -q '^timeout '; then bad "$label: a wait ran out" "$(printf '%s\n' "$report" | grep '^timeout ' | head -3 | tr '\n' '|')"; return; fi
  growth=$(printf '%s\n' "$report" | awk '$1 == "cpu" { print $3 - $2 }')
  if [ "${growth:-x}" -le 1 ] 2>/dev/null; then ok; else bad "resources: idle processor time grew by ${growth:-?} ticks in ten seconds, at most 1" "$(printf '%s\n' "$report" | grep '^cpu ')"; fi
  threads=$(printf '%s\n' "$report" | awk '$1 == "threads" { print $2 }')
  if [ "$threads" = 3 ]; then ok; else bad "resources: ${threads:-?} threads, wanted 3 (the engine, the watch, the signals)"; fi
  # The wake pipe is the two pipes that are not stdout and stderr; the follower's own read of the events file is one more descriptor of it.
  if [ "$OS" = Darwin ]; then
    want_fds "$report" "the kqueue" 1 KQUEUE
    want_fds "$report" "the wake pipe" 2 PIPE
    want_fds "$report" "the events file: the watch's and the follower's" 2 REG /state/events.tsv
    want_fds "$report" "the state directory, which the events file's watch holds with it" 1 DIR /state
    want_fds "$report" "the options directory" 1 DIR /config/plugins
    want_fds "$report" "the options file" 1 REG /config/plugins/notify.toml
  else
    want_fds "$report" "the inotify instance" 1 INOTIFY
    want_fds "$report" "the wake pipe" 2 PIPE
    want_fds "$report" "the events file: the follower's, since an inotify watch holds none" 1 REG /state/events.tsv
  fi
  reloads=$(printf '%s\n' "$report" | awk '$1 == "reloads" { print $2 }')
  if [ "${reloads:-0}" -ge 24 ] 2>/dev/null; then ok; else bad "resources: the daemon reloaded ${reloads:-no} times, wanted 24 or more, so the descriptors below say nothing" "$(printf '%s\n' "$report" | grep '^reloads ')"; fi
  rest=$(printf '%s\n' "$report" | grep -c '^fd ')
  after=$(printf '%s\n' "$report" | awk '$1 == "fds-after-reloads" { print $2 }')
  if [ "${after:-x}" -le "$rest" ] 2>/dev/null; then ok; else bad "resources: $rest descriptors at rest and ${after:-?} after the reloads, which must not be more" "$(printf '%s\n' "$report" | grep '^fds-after-reloads')"; fi
}
resource_checks

if [ -n "${PARITY_ONLY:-}" ] && [ "$ran" -eq 0 ] && [ "$skipped" -eq 0 ]; then
  echo "rust-notify-parity: PARITY_ONLY=$PARITY_ONLY matches no scenario" >&2
  exit 2
fi
printf '\nrust-notify-parity: %d scenarios ran, %d skipped (macOS only); %d checks passed, %d failed\n' "$ran" "$skipped" "$pass" "$fail"
[ "$fail" -eq 0 ]
