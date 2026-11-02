#!/usr/bin/env bash
#
# tests/rust-session-parity.sh — `tagents-core session open`, `session list`, `session last` and `session prompt` print and leave what the node CLI prints and leaves, and `session prompt` starts what it starts.
#
# Every scenario runs twice, `node packages/core/dist/cli/main.js <args>` and `target/debug/tagents-core <args>` (or $TAGENTS_CORE_BIN), each on its own pristine copy of the same tree at the same path (so no output can tell the two apart by where it ran), under `env -i` with a scratch HOME, TMPDIR, state directory and config directory, and a PATH that holds nothing but a symbolic link to the real node, a stub `claude` and a stub `caffeinate`. It passes only when stdout, stderr, the exit code and the whole tree afterwards (every path, its mode, its link target or the checksum of its bytes) are the same. What is normalised is the `id` that `session open` makes, which must be a version 4 UUID to be normalised at all.
# The stub `claude` is the fakeClaude of packages/core/src/testkit.ts, written by tests/rust-session-parity-driver.mts, and records what it was started with into rec/ of the tree; the stub `caffeinate` records its arguments there too. The three verbs of this suite start no process, so a scenario also fails when anything was recorded.
# A scenario of `prompt` writes a stub of its own (`STUB`, the JSON of a FakeScript, or `STUB_SH`, a shell script), which has to run as often as `STARTS` says (once by default, and no scenario without a stub of its own may start anything). Its record is compared as `rec/argv.json`: the argv, the working directory, the kind of stdin and the environment as a sorted list, with the first entry of PATH read as `<node-dir>` only when it is the directory this run must have. stdout is compared once the `id` of a new reference and `durationMs` are normalised. `HAS` and `HAS_NOT` are tripwires on what node's child recorded. `MODE` chooses how a scenario is run: `merged` gives stdout and stderr one pipe, so their order counts, `stamp` notes when each line of stdout arrived and when the process ended, `signal` sends `SIGNAL` to the CLI once the stub has started and notes whether the stub lived through it, and `stall` leaves stdout unread for as long as it takes the stub to die.
# Who answered is checked too. The Rust side runs with $TAGENTS_NODE pointing at a shim that notes it was started and then runs the real node: a scenario marked `rust` fails when the binary handed the call to node (a binary that forwarded everything would otherwise pass every comparison), and one marked `node` fails when the binary answered it itself (the call is one the design hands over, and answering it would be a second implementation of node's error text).
# Tripwires assert on the node run alone: its exit code, and a text it must print, so a scenario that stopped provoking what it exists for fails here instead of passing for nothing.
#
# The helpers the parity suites share are in tests/lib/parity.sh. `reset`, `norm`, `side` and `sc` stay here because they differ from those of tests/rust-plugin-parity.sh: `reset` knows no config directory, since it is always `cfg`, `norm` takes out the id of a new reference and leaves stderr alone, `side` adds TMPDIR, TA_STATE_DIR and PARITY_REC to the environment, closes stdin and counts what rec/ holds, and `sc` prints under PARITY_SHOW, fails a scenario that started something and has no sweep. `row` stays because it writes a setup command, where the `row` of tests/rust-notify-parity.sh writes a step for the driver.
#
# PARITY_SELF_TEST=1 runs node on both sides and skips the checks of who answered: it proves the suite and node's determinism, not the Rust binary. PARITY_ONLY=<text> runs only the scenarios whose label holds the text, and PARITY_SHOW=<n> prints both transcripts of each, cut at n characters a line. TAGENTS_NODE names the node program.
# Needs a built node CLI (pnpm build), a node that runs .mts files, and nothing else: no network, no real home, no tmux, no real claude (the suite stops if one could be reached). bash 3.2.
#   env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/rust-session-parity.sh

set -o pipefail
umask 022

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd -P)
NODE=${TAGENTS_NODE:-$(command -v node)}
CORE_JS="$REPO/packages/core/dist/cli/main.js"
RUST=${TAGENTS_CORE_BIN:-$REPO/target/debug/tagents-core}
DRIVER="$HERE/rust-session-parity-driver.mts"
SELF_TEST=${PARITY_SELF_TEST:-}
ONLY=${PARITY_ONLY:-}
SHOW=${PARITY_SHOW:-}

[ -n "$NODE" ] && [ -x "$NODE" ] || { echo "rust-session-parity: no node to run (set TAGENTS_NODE)" >&2; exit 2; }
[ -f "$CORE_JS" ] || { echo "rust-session-parity: $CORE_JS is not built; run: pnpm install && pnpm build" >&2; exit 2; }
if [ -z "$SELF_TEST" ] && [ ! -x "$RUST" ]; then
  if [ -n "${TAGENTS_CORE_BIN:-}" ]; then echo "rust-session-parity: $RUST is not an executable" >&2; exit 2; fi
  (cd "$REPO" && cargo build -p tagents-core >&2) || { echo "rust-session-parity: cargo build failed" >&2; exit 2; }
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/tagents-session-parity.XXXXXX") || exit 2
TMP=$(cd "$TMP" && pwd -P) || exit 2
LIVE_STUB=
trap '[ -n "$LIVE_STUB" ] && kill -9 "$LIVE_STUB" 2>/dev/null; chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM

RUN=$TMP/run                # what a run works in and leaves: one path for both programs
TEMPLATE=$TMP/template      # the pristine tree, copied to $RUN before each run
SHIM=$TMP/shim
BIN=$TMP/bin                # the only directory of PATH: node, the stub claude, the stub caffeinate
MARK=$TMP/handed-over       # the shim writes it when the binary hands a call to node
mkdir "$SHIM" "$BIN" || exit 2
ln -s "$NODE" "$BIN/node"
# The shell of the shim leaves its own variables in the environment, and node's child would record them: `env` takes them out, by its full path because a scenario can set any PATH.
printf '#!/bin/sh\n: > "$PARITY_MARK"\nexec /usr/bin/env -u PWD -u SHLVL -u _ "$PARITY_REAL_NODE" "$@"\n' > "$SHIM/node"
# The stub of caffeinate says how it was started and what its three streams are, stays until it is told to leave, and says so.
cat > "$BIN/caffeinate" <<'CAFFEINATE'
#!/bin/sh
waiting=
trap '[ -n "$waiting" ] && kill "$waiting" 2> /dev/null; printf "released\n" >> "$PARITY_REC/caffeinate"; exit 0' TERM
printf "%s\n" "$*" >> "$PARITY_REC/caffeinate"
stat -L -f "%HT" /dev/fd/0 /dev/fd/1 /dev/fd/2 2> /dev/null | tr "\n" "," >> "$PARITY_REC/caffeinate"
printf "\n" >> "$PARITY_REC/caffeinate"
sleep 30 &
waiting=$!
wait "$waiting"
CAFFEINATE
chmod +x "$SHIM/node" "$BIN/caffeinate"
"$NODE" "$DRIVER" tree "$TEMPLATE" || { echo "rust-session-parity: cannot write the tree" >&2; exit 2; }
mkdir "$TMP/default-stub" || exit 2
"$NODE" "$DRIVER" stub "$TMP/default-stub" '{"text":"stub"}' "$RUN/rec" || { echo "rust-session-parity: cannot write the stub claude" >&2; exit 2; }
cp "$TMP/default-stub/claude" "$BIN/claude" || exit 2

# The directory of the real node comes first on the PATH of node's child, so a `claude` beside it would be started by every scenario. No scenario may start a real one, here or from /usr/bin and /bin, where a scenario with no stub on its PATH looks.
NODE_DIR=$("$NODE" -p 'require("path").dirname(process.execPath)') || exit 2
if [ -n "$(PATH="$NODE_DIR:/usr/bin:/bin" command -v claude)" ]; then
  echo "rust-session-parity: a claude is reachable from $NODE_DIR, /usr/bin or /bin, and the scenarios of session prompt would start it" >&2; exit 2
fi

# The harness itself: the program called `claude` or `caffeinate` on this PATH is the stub, so no scenario can reach a real one.
for program in claude caffeinate node; do
  [ "$(env -i "PATH=$BIN:/usr/bin:/bin" sh -c "command -v $program")" = "$BIN/$program" ] \
    || { echo "rust-session-parity: $program on the PATH of a run is not the one of $BIN" >&2; exit 2; }
done

if [ -z "$SELF_TEST" ]; then
  # The first check, before any scenario: the binary says it serves the four verbs. A build with no `session` verb would hand every scenario to node and pass them all.
  "$RUST" --spec | "$NODE" -e 'const s = JSON.parse(require("fs").readFileSync(0, "utf8")); const has = (p) => s.commands.some((c) => c.path.join(" ") === p); process.exit(has("session open") && has("session prompt") && has("session list") && has("session last") ? 0 : 1)' \
    || { echo "rust-session-parity: $RUST does not serve session open, session prompt, session list and session last (--spec)" >&2; exit 2; }
fi

pass=0; fail=0; skipped=0; rust_served=0; handed_over=0
. "$HERE/lib/parity.sh"

# --------------------------------------------------------------- scenario state ---
# Set before a scenario, cleared after it by `reset`: the directory to run in (relative to the run), the locale, a setup run in the run's directory before the program (a shell command), the environment to add, the arguments, the stream whose reader went away (stdout or stderr), and whether what the stub left is out of the comparison.
CWD=; LOCALE=en; SETUP=; EXTRA=(); UNDER=(); ARGS=(); CLOSED=; STUB=; STUB_SH=; STARTS=; HAS=; HAS_NOT=; AWAKE=; WAIT_FOR=; CHILD_NODE_DIR=; MODE=; SIGNAL=; KILL_RACES_STUB=; RAN=
reset() { CWD=; LOCALE=en; SETUP=; EXTRA=(); UNDER=(); ARGS=(); CLOSED=; STUB=; STUB_SH=; STARTS=; HAS=; HAS_NOT=; AWAKE=; WAIT_FOR=; CHILD_NODE_DIR=; MODE=; SIGNAL=; KILL_RACES_STUB=; }

# The only differences allowed between the two programs: the id of a new reference, as long as it is a version 4 UUID, and how long a turn took.
norm() { LC_ALL=C sed -E 's/"id": "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"/"id": "UUID4"/; s/"durationMs":( ?)[0-9]+/"durationMs":\1N/'; }

# The program under the environment of a run; ends in `exec`, so a subshell calls it.
program() {
  local awake=("TA_KEEP_AWAKE=0")
  [ -n "$AWAKE" ] && awake=()
  cd "$RUN/$CWD" && exec env -i "PATH=$BIN:/usr/bin:/bin" "HOME=$RUN/home" "TMPDIR=$RUN/tmp" "TA_STATE_DIR=$RUN/st" "TAGENTS_CONFIG_DIR=$RUN/cfg" "TAGENTS_LOCALE=$LOCALE" \
    "TAGENTS_NODE=$SHIM/node" "PARITY_MARK=$MARK" "PARITY_REAL_NODE=$NODE" "PARITY_REC=$RUN/rec" "${awake[@]}" "${EXTRA[@]}" "${UNDER[@]}" "$@" "${ARGS[@]}" < /dev/null
}

# Waits, bounded, for a test to hold; it says whether it did. The bound is the failure of a scenario, not its pace.
until_true() {  # <tenths of a second> <command...>
  local left=$1; shift
  until "$@"; do
    [ "$left" -gt 0 ] || return 1
    left=$((left - 1)); sleep 0.1
  done
}
has_content() { [ -s "$1" ]; }
stub_gone_and_line_written() { ! kill -0 "$(cat "$RUN/rec/pid")" 2> /dev/null && [ -s "$1" ]; }

# The time of the first line that holds a text, among the lines of a side's stdout; `end` is when its stdout closed.
stamped() {  # <tag> <text>
  if [ "$2" = end ]; then tail -n 1 "$TMP/stamps.$1" | cut -d' ' -f1; else LC_ALL=C awk -v text="$2" 'index($0, text) { print $1; exit }' "$TMP/stamps.$1"; fi
}

# The run in each of its forms: the words of the program come in, and out.$tag, err.$tag and code.$tag come out.
run_it() {  # <tag> <program words...>
  local tag=$1; shift
  case "$MODE" in
    merged)
      ( program "$@" ) 2>&1 | norm > "$TMP/out.$tag"
      echo "${PIPESTATUS[0]}" > "$TMP/code.$tag"; : > "$TMP/err.$tag"
      ;;
    stamp)
      ( program "$@" ) 2> "$TMP/err.$tag" | "$NODE" "$DRIVER" stamp "$TMP/stamps.$tag" | norm > "$TMP/out.$tag"
      echo "${PIPESTATUS[0]}" > "$TMP/code.$tag"
      ;;
    signal)
      ( program "$@" ) > "$TMP/raw.$tag" 2> "$TMP/err.$tag" &
      local cli=$!
      until_true 300 has_content "$RUN/rec/pid"
      LIVE_STUB=$(cat "$RUN/rec/pid")
      kill "-$SIGNAL" "$cli"
      wait "$cli"; echo $? > "$TMP/code.$tag"
      if until_true 10 stub_stopped "$LIVE_STUB"; then echo gone; else echo alive; fi > "$TMP/stub.$tag"
      kill -9 "$LIVE_STUB" 2> /dev/null; LIVE_STUB=
      norm < "$TMP/raw.$tag" > "$TMP/out.$tag"
      ;;
    stall)
      rm -f "$TMP/fifo"; mkfifo "$TMP/fifo"
      ( program "$@" ) > "$TMP/fifo" 2> "$TMP/err.$tag" &
      local cli=$!
      exec 7< "$TMP/fifo"
      until_true 300 has_content "$RUN/rec/pid"
      LIVE_STUB=$(cat "$RUN/rec/pid")
      if until_true 200 stub_gone_and_line_written "$TMP/err.$tag"; then echo "gone with its line on stderr"; else echo "stub alive: $(kill -0 "$LIVE_STUB" 2> /dev/null && echo yes || echo no), stderr holds $(wc -c < "$TMP/err.$tag") bytes"; fi > "$TMP/stub.$tag"
      norm <&7 > "$TMP/out.$tag"; exec 7<&-
      wait "$cli"; echo $? > "$TMP/code.$tag"
      kill -9 "$LIVE_STUB" 2> /dev/null; LIVE_STUB=
      ;;
    *)
      ( program "$@" ) 2> "$TMP/err.$tag" | norm > "$TMP/out.$tag"
      echo "${PIPESTATUS[0]}" > "$TMP/code.$tag"
      ;;
  esac
}

# Whether a child has stopped running: `kill -0` also answers for a zombie, and a child the CLI killed on its way out is one until init has reaped it, so the answer has to come from its state and be given time to arrive.
stub_stopped() {  # <pid>
  local state
  state=$(ps -o state= -p "$1" 2> /dev/null)
  [ -z "$state" ] || [ "${state#Z}" != "$state" ]
}

# What a stub left in rec/, in the form two runs are compared in: how often it ran, the record with its volatile parts settled and no pid. The node directory this run must have is the real node's, or on the binary's side that of $TAGENTS_NODE, the shim, unless a scenario says otherwise.
settle_record() {  # <tag>
  local tag=$1 node_dir=$NODE_DIR pid=
  if [ -n "$KILL_RACES_STUB" ]; then
    rm -rf "$RUN/rec"; mkdir "$RUN/rec"
    return
  fi
  # The binary names the directory of $TAGENTS_NODE, the shim. A call it handed to node is started by the real node, which names its own.
  if [ "$tag" = rust ] && [ -z "$SELF_TEST" ] && [ ! -e "$MARK" ]; then node_dir=${CHILD_NODE_DIR:-$SHIM}; fi
  if [ -f "$RUN/rec/count" ]; then wc -l < "$RUN/rec/count" | tr -d ' '; else ls -A "$RUN/rec" | wc -l | tr -d ' '; fi > "$TMP/started.$tag"
  if [ -f "$RUN/rec/argv.json" ]; then
    "$NODE" "$DRIVER" record "$RUN/rec/argv.json" "$node_dir" || { echo "rust-session-parity: cannot read the record of the stub" >&2; exit 2; }
    cp "$RUN/rec/argv.json" "$TMP/argv.$tag"
  fi
  if [ -f "$RUN/rec/pid" ]; then pid=$(cat "$RUN/rec/pid"); rm -f "$RUN/rec/pid"; fi
  if [ -f "$RUN/rec/caffeinate" ]; then
    [ -z "$WAIT_FOR" ] || until_true 100 grep -qF "$WAIT_FOR" "$RUN/rec/caffeinate"
    sed "s/^-i -w $pid\$/-i -w <child>/" "$RUN/rec/caffeinate" > "$TMP/caffeinate.$tag"
    cp "$TMP/caffeinate.$tag" "$RUN/rec/caffeinate"
  fi
}

side() {  # <tag> <program words...>
  local tag=$1; shift
  rm -rf "$RUN"; chmod -R u+rwx "$RUN" 2> /dev/null
  cp -RPp "$TEMPLATE" "$RUN" || { echo "rust-session-parity: cannot copy the tree" >&2; exit 2; }
  if [ -n "$SETUP" ]; then ( cd "$RUN" && eval "$SETUP" ) || { echo "rust-session-parity: setup failed: $SETUP" >&2; exit 2; }; fi
  rm -f "$MARK" "$TMP/argv.$tag" "$TMP/stamps.$tag" "$TMP/stub.$tag"; : > "$TMP/caffeinate.$tag"
  date +%s > "$TMP/t0.$tag"
  if [ -n "$CLOSED" ]; then
    # A FIFO opened on both ends with its reading end closed again: nobody reads it, and no reader can still be on its way out.
    rm -f "$TMP/fifo"; mkfifo "$TMP/fifo"; exec 3<> "$TMP/fifo" 4> "$TMP/fifo" 3<&-
    if [ "$CLOSED" = stdout ]; then
      ( program "$@" ) >&4 2> "$TMP/err.$tag"; echo $? > "$TMP/code.$tag"; : > "$TMP/out.$tag"
    else
      ( program "$@" ) 2>&4 | norm > "$TMP/out.$tag"; echo "${PIPESTATUS[0]}" > "$TMP/code.$tag"; : > "$TMP/err.$tag"
    fi
    exec 4>&-
  else
    run_it "$tag" "$@"
  fi
  if [ -e "$MARK" ]; then echo node > "$TMP/via.$tag"; else echo own > "$TMP/via.$tag"; fi
  settle_record "$tag"
  snapshot | norm > "$TMP/tree.$tag"
  chmod -R u+rwx "$RUN" 2> /dev/null
}

# A scenario: `sc <label> <via> <node's exit code, or - for any> <text node prints, or -> -- <the words after the program name>`.
# <via> is who must answer on the Rust side: rust or node, or any where the harness has no way to tell.
sc() {
  local label=$1 via=$2 want=$3 needle=$4; shift 5
  ARGS=("$@")
  RAN=
  if [ -n "$ONLY" ] && [[ $label != *"$ONLY"* ]]; then reset; return; fi
  RAN=1
  if [ -n "$STUB" ]; then
    "$NODE" "$DRIVER" stub "$BIN" "$STUB" "$RUN/rec" || { echo "rust-session-parity: cannot write the stub of $label" >&2; exit 2; }
  elif [ -n "$STUB_SH" ]; then
    # Every stub records that it ran, first of all, and its pid.
    printf '#!/bin/sh\nprintf "run\\n" >> "$PARITY_REC/count"\nprintf "%%s\\n" "$$" > "$PARITY_REC/pid"\n%s\n' "$STUB_SH" > "$BIN/claude"
    chmod +x "$BIN/claude"
  fi
  side node "$NODE" "$CORE_JS"
  if [ -n "$SELF_TEST" ]; then side rust "$NODE" "$CORE_JS"; else side rust "$RUST"; fi

  local what=()
  cmp -s "$TMP/out.node" "$TMP/out.rust" || what+=(stdout)
  cmp -s "$TMP/err.node" "$TMP/err.rust" || what+=(stderr)
  cmp -s "$TMP/code.node" "$TMP/code.rust" || what+=("exit code")
  cmp -s "$TMP/tree.node" "$TMP/tree.rust" || what+=(tree)
  if [ ${#what[@]} -ne 0 ]; then
    bad "$label: differs in ${what[*]}" \
      "args: $(printf '%q ' "${ARGS[@]}")" \
      "exit node=$(cat "$TMP/code.node") rust=$(cat "$TMP/code.rust")" \
      "stdout node: $(head -c 300 "$TMP/out.node" | tr '\n' '|')" \
      "stdout rust: $(head -c 300 "$TMP/out.rust" | tr '\n' '|')" \
      "stderr node: $(head -c 300 "$TMP/err.node" | tr '\n' '|')" \
      "stderr rust: $(head -c 300 "$TMP/err.rust" | tr '\n' '|')" \
      "tree: $(diff "$TMP/tree.node" "$TMP/tree.rust" | head -4 | tr '\n' '|')" \
      "record: $(diff "$TMP/argv.node" "$TMP/argv.rust" 2>&1 | head -6 | cut -c1-200 | tr '\n' '|')" \
      "caffeinate: $(diff "$TMP/caffeinate.node" "$TMP/caffeinate.rust" | head -4 | tr '\n' '|')"
  else
    ok
  fi
  if [ -n "$SHOW" ]; then
    local side_name
    for side_name in node rust; do
      printf '  --- %s, %s: exit %s\n' "$label" "$side_name" "$(cat "$TMP/code.$side_name")"
      { printf 'stdout\n'; cut -c1-"$SHOW" "$TMP/out.$side_name"; printf 'stderr\n'; cut -c1-"$SHOW" "$TMP/err.$side_name"; } | sed 's/^/  | /'
    done
  fi

  if [ "$want" != - ] && [ "$(cat "$TMP/code.node")" != "$want" ]; then
    bad "tripwire $label: node exited $(cat "$TMP/code.node"), this scenario exists to provoke $want" "stderr: $(head -c 200 "$TMP/err.node" | tr '\n' '|')"
  fi
  if [ "$needle" != - ] && ! grep -qF -- "$needle" "$TMP/out.node" "$TMP/err.node"; then
    bad "tripwire $label: node did not print what this scenario exists to provoke" "wanted: $needle" "stdout: $(head -c 200 "$TMP/out.node" | tr '\n' '|')" "stderr: $(head -c 200 "$TMP/err.node" | tr '\n' '|')"
  fi
  local starts=$STARTS
  if [ -z "$starts" ]; then if [ -n "$STUB$STUB_SH" ]; then starts=1; else starts=0; fi; fi
  if [ "$starts" != - ] && { [ "$(cat "$TMP/started.node")" != "$starts" ] || [ "$(cat "$TMP/started.rust")" != "$starts" ]; }; then
    bad "$label: the stub was to start $starts times, it left $(cat "$TMP/started.node") after node and $(cat "$TMP/started.rust") after the binary"
  fi
  if [ -n "$HAS" ] && ! grep -qF -- "$HAS" "$TMP/argv.node" 2> /dev/null; then
    bad "tripwire $label: node's child did not record what this scenario exists to provoke" "wanted: $HAS" "record: $(head -c 600 "$TMP/argv.node" 2>&1 | tr '\n' ' ')"
  fi
  if [ -n "$HAS_NOT" ] && grep -qF -- "$HAS_NOT" "$TMP/argv.node" 2> /dev/null; then
    bad "tripwire $label: node's child recorded what this scenario exists to keep out" "found: $HAS_NOT"
  fi

  if [ -z "$SELF_TEST" ]; then
    local answered; answered=$(cat "$TMP/via.rust")
    if [ "$answered" = node ]; then handed_over=$((handed_over + 1)); else rust_served=$((rust_served + 1)); fi
    case "$via:$answered" in
      rust:node) bad "$label: the binary handed this call to node, it should answer it" ;;
      node:own) bad "$label: the binary answered this call, the design hands it to node" ;;
    esac
  fi
  if [ -n "$STUB$STUB_SH" ]; then cp "$TMP/default-stub/claude" "$BIN/claude" || exit 2; fi
  reset
}

# ------------------------------------------------------------------- setups ---
# Run in the run's directory, before the program. A setup is built from these, and what it writes is the tree the program sees.
# A state record: st/<key>.tsv holds these tab separated fields (the first six are what the reader needs, more are the account, the pid, ...).
row() {  # <key> <fields...>
  local key=$1; shift
  local line; line=$(IFS=$'\t'; printf '%s' "$*")
  printf 'printf "%%s\\n" %q > st/%s.tsv; ' "$line" "$key"
}
# The same, with a text that is written as it is: no newline added, so a record may be cut anywhere.
rowraw() {  # <key> <text, printf's escapes understood>
  printf 'printf %q > st/%s.tsv; ' "$2" "$1"
}
# A line of history.tsv: at, kind, session id, pane, label, cwd.
hist() {  # <fields...>
  local line; line=$(IFS=$'\t'; printf '%s' "$*")
  printf 'printf "%%s\\n" %q >> st/history.tsv; ' "$line"
}
# The text of a reference that names a transcript of the tree, and the one that names a Claude session.
ref_transcript() { printf '{"id":"r1","claudeSessionId":null,"transcript":"%s/tr/%s","spec":{"kind":"claude","cwd":"%s/work","skipPermissions":false}}' "$RUN" "$1" "$RUN"; }
ref_session() { printf '{"id":"r1","claudeSessionId":"%s","transcript":null,"spec":{"kind":"claude","cwd":"%s/work","skipPermissions":false}}' "$1" "$RUN"; }
PLAIN="$RUN/tr/plain.jsonl"

# ------------------------------------------------------------------- open ---
t "open: every option"
sc "open-all-options" rust 0 '"skipPermissions": true' -- session open --cwd "$RUN/work" --resume sid-1 --label L --model opus --effort high --system-prompt-file /p/sys.md --mcp-config /p/mcp.json --config-dir /acct --skip-permissions
sc "open-minimal" rust 0 "\"cwd\": \"$RUN/work\"" -- session open --cwd "$RUN/work"
sc "open-inline-values" rust 0 '"model": "opus"' -- session open --cwd="$RUN/work" --model=opus --effort=high --label=a=b --system-prompt-file=/p/s.md --mcp-config=/p/m.json
sc "open-inline-empty-value" rust 0 '"label": ""' -- session open --cwd "$RUN/work" --label=
sc "open-empty-value" rust 0 '"model": ""' -- session open --cwd "$RUN/work" --model ""
sc "open-inline-cwd-and-a-repeated-label" rust 0 '"label": "b"' -- session open --cwd=/x --label a --label=b
sc "open-repeated-option-last-wins" rust 0 '"label": "b"' -- session open --cwd /a --cwd "$RUN/work" --label a --label=b
sc "open-option-order" rust 0 '"effort": "low"' -- session open --effort low --skip-permissions --cwd "$RUN/work" --model m
sc "open-skip-permissions-first" rust 0 '"skipPermissions": true' -- session open --skip-permissions --cwd "$RUN/work"
sc "open-config-dir-empty" rust 0 '"configDir": ""' -- session open --cwd "$RUN/work" --config-dir ""
sc "open-config-dir-inline-empty" rust 0 '"configDir": ""' -- session open --cwd "$RUN/work" --config-dir=
sc "open-resume-empty" rust 0 '"claudeSessionId": ""' -- session open --cwd "$RUN/work" --resume ""
sc "open-value-with-spaces" rust 0 'two words' -- session open --cwd "$RUN/work" --label "two words" --model " padded "
sc "open-value-with-unicode" rust 0 'é😀' -- session open --cwd "$RUN/work" --label 'é😀 привет'
sc "open-value-with-quote-and-backslash" rust 0 '\"' -- session open --cwd "$RUN/work" --label 'say "x" \ y'
sc "open-value-with-control-characters" rust 0 '\u0007' -- session open --cwd "$RUN/work" --label $'tab\there\nnewline\a bell\x7f'
sc "open-value-with-separator" rust 0 $'\xe2\x80\xa8' -- session open --cwd "$RUN/work" --label $'a\xe2\x80\xa8b'
sc "open-value-looks-like-id" rust 0 '"label": "123"' -- session open --cwd "$RUN/work" --label 123
sc "open-value-starts-with-dash-inline" rust 0 '"label": "-x"' -- session open --cwd "$RUN/work" --label=-x
sc "open-value-is-a-lone-dash" node 0 '"label": "-"' -- session open --cwd "$RUN/work" --label -
sc "open-value-is-double-dash-inline" rust 0 '"label": "--"' -- session open --cwd "$RUN/work" --label=--

t "open: the account"
sc "open-no-config-dir" rust 0 '"configDir": null' -- session open --cwd "$RUN/work" --no-config-dir
sc "open-config-dir" rust 0 '"configDir": "/acct"' -- session open --cwd "$RUN/work" --config-dir /acct
sc "open-both-account-flags" rust 2 '--config-dir + --no-config-dir' -- session open --cwd "$RUN/work" --config-dir /acct --no-config-dir
sc "open-both-account-flags-flag-first" rust 2 '--config-dir + --no-config-dir' -- session open --no-config-dir --cwd "$RUN/work" --config-dir=/acct
sc "open-both-account-flags-empty-dir" rust 2 '--config-dir + --no-config-dir' -- session open --cwd "$RUN/work" --config-dir "" --no-config-dir
LOCALE=ru; sc "open-both-account-flags-ru" rust 2 'неизвестный параметр --config-dir + --no-config-dir' -- session open --cwd "$RUN/work" --config-dir /acct --no-config-dir

t "open: the working directory"
sc "open-missing-cwd" rust 2 'missing required option --cwd' -- session open
sc "open-missing-cwd-with-other-options" rust 2 'missing required option --cwd' -- session open --label a --skip-permissions
sc "open-empty-cwd" rust 2 'missing required option --cwd' -- session open --cwd ""
sc "open-inline-empty-cwd" rust 2 'missing required option --cwd' -- session open --cwd=
sc "open-account-flags-before-cwd-check" rust 2 'missing required option --cwd' -- session open --config-dir /a --no-config-dir
LOCALE=ru; sc "open-missing-cwd-ru" rust 2 'не хватает обязательного параметра --cwd' -- session open
EXTRA=("TAGENTS_LOCALE=de"); sc "open-missing-cwd-other-locale" rust 2 'missing required option --cwd' -- session open
EXTRA=("TAGENTS_LOCALE="); sc "open-missing-cwd-empty-locale" rust 2 'missing required option --cwd' -- session open
EXTRA=($'TAGENTS_LOCALE=\xff'); sc "open-missing-cwd-locale-is-not-utf8" rust 2 'missing required option --cwd' -- session open
CWD=work; sc "open-relative-cwd" rust 0 "$RUN/work/x" -- session open --cwd ./x
CWD=work; sc "open-relative-cwd-bare" rust 0 "$RUN/work/x" -- session open --cwd x
CWD=work; sc "open-relative-cwd-parent" rust 0 "\"cwd\": \"$RUN\"" -- session open --cwd ..
CWD=work; sc "open-relative-cwd-dot" rust 0 "\"cwd\": \"$RUN/work\"" -- session open --cwd .
CWD=work; sc "open-relative-cwd-dot-segments" rust 0 "$RUN/y" -- session open --cwd ./a/../../y/./
CWD=work; sc "open-relative-cwd-above-root" rust 0 '"cwd": "/tmp-does-not-exist"' -- session open --cwd "$(printf '../%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)tmp-does-not-exist"
sc "open-absolute-cwd-trailing-slash" rust 0 "\"cwd\": \"$RUN/work\"" -- session open --cwd "$RUN/work/"
sc "open-absolute-cwd-double-slash" rust 0 "\"cwd\": \"$RUN/work\"" -- session open --cwd "$RUN//work///"
sc "open-absolute-cwd-dot-segments" rust 0 "\"cwd\": \"$RUN/work\"" -- session open --cwd "$RUN/work/./x/.."
sc "open-cwd-root" rust 0 '"cwd": "/"' -- session open --cwd /
sc "open-cwd-double-slash-root" rust 0 '"cwd": "/"' -- session open --cwd //
sc "open-cwd-does-not-exist" rust 0 '/nowhere/at/all' -- session open --cwd /nowhere/at/all
sc "open-cwd-tilde-is-a-name" rust 0 "$RUN/~" -- session open --cwd '~'
sc "open-cwd-with-spaces" rust 0 'a b' -- session open --cwd "a b"
sc "open-cwd-with-unicode" rust 0 'é😀' -- session open --cwd 'é😀'

t "open: --resume and the state"
ROW_T=$(row 5 1700000100 working sid-1 "$RUN/work" "$PLAIN" detail)
SETUP=$ROW_T; sc "open-resume-with-state" rust 0 "\"transcript\": \"$PLAIN\"" -- session open --cwd "$RUN/work" --resume sid-1
sc "open-resume-without-state" rust 0 '"claudeSessionId": "sid-1"' -- session open --cwd "$RUN/work" --resume sid-1
SETUP=$ROW_T; sc "open-resume-other-session" rust 0 '"claudeSessionId": "sid-2"' -- session open --cwd "$RUN/work" --resume sid-2
SETUP=$ROW_T; sc "open-resume-prefix-is-not-a-session" rust 0 '"claudeSessionId": "sid"' -- session open --cwd "$RUN/work" --resume sid
SETUP=$(row 5 1700000100 working sid-1 "$RUN/work" "" detail); sc "open-resume-row-without-transcript" rust 0 '"claudeSessionId": "sid-1"' -- session open --cwd "$RUN/work" --resume sid-1
SETUP="$(row 5 1700000100 working sid-1 "$RUN/work" "" detail)$(row 6 1700000200 done sid-1 "$RUN/work" "$RUN/tr/ru.jsonl" detail)"; sc "open-resume-newest-row-wins" rust 0 "ru.jsonl" -- session open --cwd "$RUN/work" --resume sid-1
SETUP="$(row 5 1700000300 working sid-1 "$RUN/work" "" detail)$(row 6 1700000200 done sid-1 "$RUN/work" "$RUN/tr/ru.jsonl" detail)"; sc "open-resume-skips-a-newer-row-without-transcript" rust 0 "ru.jsonl" -- session open --cwd "$RUN/work" --resume sid-1
SETUP="$(row s-sid-1 1700000100 done sid-1 "$RUN/work" "$PLAIN" detail)"; sc "open-resume-headless-row" rust 0 "plain.jsonl" -- session open --cwd "$RUN/work" --resume sid-1
SETUP="$(row 5 1700000100 subdone sid-1 "$RUN/work" "$PLAIN" detail)"; sc "open-resume-subdone-row" rust 0 "plain.jsonl" -- session open --cwd "$RUN/work" --resume sid-1
SETUP="$(row 5 junk working sid-1 "$RUN/work" "$PLAIN" detail)"; sc "open-resume-broken-row" rust 0 '"claudeSessionId": "sid-1"' -- session open --cwd "$RUN/work" --resume sid-1
SETUP="$(row 5 1700000100 working '' "$RUN/work" "$PLAIN" detail)"; sc "open-resume-empty-session-in-a-row" rust 0 '"claudeSessionId": ""' -- session open --cwd "$RUN/work" --resume ''
LOCALE=ru; SETUP=$ROW_T; sc "open-ru" rust 0 "\"transcript\": \"$PLAIN\"" -- session open --cwd "$RUN/work" --resume sid-1

t "open: what node answers itself"
sc "open-unknown-option" node 2 - -- session open --cwd "$RUN/work" --bogus
sc "open-unknown-option-with-value" node 2 - -- session open --cwd "$RUN/work" --bogus value
sc "open-unknown-inline-option" node 2 - -- session open --cwd "$RUN/work" --bogus=1
sc "open-option-without-value" node 2 - -- session open --cwd
sc "open-option-without-value-last" node 2 - -- session open --cwd "$RUN/work" --label
sc "open-value-starts-with-dash" node 2 - -- session open --cwd -x
sc "open-value-starts-with-dashes" node 2 - -- session open --cwd "$RUN/work" --label --model
sc "open-short-option" node 2 - -- session open -c "$RUN/work"
sc "open-short-flag" node 2 - -- session open --cwd "$RUN/work" -s
sc "open-positional" node 2 - -- session open "$RUN/work"
sc "open-positional-after-options" node 2 - -- session open --cwd "$RUN/work" extra
sc "open-flag-with-value" node 2 - -- session open --cwd "$RUN/work" --skip-permissions=1
sc "open-no-config-dir-with-value" node 2 - -- session open --cwd "$RUN/work" --no-config-dir=x
sc "open-negated-flag" node 2 - -- session open --cwd "$RUN/work" --no-skip-permissions
sc "open-help" node 2 - -- session open --help
sc "open-double-dash-ends-the-options" rust 0 "\"cwd\": \"$RUN/work\"" -- session open --cwd "$RUN/work" --
sc "open-double-dash-positional" node 2 - -- session open --cwd "$RUN/work" -- x
sc "open-lone-dash-is-a-positional" node 2 - -- session open --cwd "$RUN/work" -
sc "open-an-argument-that-is-not-utf8" node - - -- session open --cwd "$RUN/work" --label $'\xff'
sc "open-a-cwd-that-is-not-utf8" node - - -- session open --cwd $'/x\xff'
sc "session" node 2 - -- session
sc "session-unknown-verb" node 2 'unknown command: session bogus' -- session bogus
sc "session-unknown-verb-empty" node 2 - -- session ""
sc "session-help" node 2 - -- session --help
sc "session-abort" node 2 - -- session abort
sc "session-open-uppercase" node 2 - -- session OPEN --cwd "$RUN/work"

# ------------------------------------------------------------------- list ---
t "list: the state"
sc "list-empty" rust 0 '[]' -- session list
SETUP='rm -rf st'; sc "list-no-state-directory" rust 0 '[]' -- session list
SETUP='rm -rf st; : > st'; sc "list-state-directory-is-a-file" rust 0 '[]' -- session list
SETUP='rm -rf st; ln -s nowhere st'; sc "list-state-directory-is-a-broken-link" rust 0 '[]' -- session list
SETUP='mkdir -p st/sub st/events.d; : > st/history.tsv; : > st/events.tsv'; sc "list-state-directory-with-no-records" rust 0 '[]' -- session list
STATES="$(row 1 1700000600 new sid-new "$RUN/work" "" "")$(row 2 1700000500 working sid-working "$RUN/work" "" "")$(row 3 1700000400 blocked sid-blocked "$RUN/work" "" "")$(row 4 1700000300 done sid-done "$RUN/work" "" "")$(row 5 1700000200 gone sid-gone "$RUN/work" "" "")$(row 6 1700000100 subdone sid-subdone "$RUN/work" "" "")"
SETUP=$STATES; sc "list-states" rust 0 'sid-working' -- session list
SETUP=$STATES; sc "list-subdone-is-left-out" rust 0 '"claudeSessionId": "sid-gone"' -- session list
SETUP=$STATES; sc "list-state-working" rust 0 'sid-working' -- session list --state working
SETUP=$STATES; sc "list-state-inline" rust 0 'sid-new' -- session list --state=new
SETUP=$STATES; sc "list-state-two" rust 0 'sid-done' -- session list --state done --state=gone
SETUP=$STATES; sc "list-state-repeated" rust 0 'sid-blocked' -- session list --state working --state blocked --state working
SETUP=$STATES; sc "list-state-all-five" rust 0 'sid-gone' -- session list --state new --state working --state blocked --state done --state gone
SETUP=$STATES; sc "list-state-none-match" rust 0 '[]' -- session list --state working --label nobody
SETUP=$STATES; sc "list-state-and-label" rust 0 '[]' -- session list --state new --label x
SETUP=$STATES; sc "list-key-order-and-layout" rust 0 '    "claudeSessionId": "sid-new",' -- session list
SETUP=$STATES; sc "list-state-new-only" rust 0 '"claudeSessionId": "sid-new"' -- session list --state new

t "list: an unknown state"
SETUP=$STATES; sc "list-bad-state" rust 2 'unknown option --state a,b' -- session list --state a,b
SETUP=$STATES; sc "list-bad-states-two" rust 2 'unknown option --state a,b' -- session list --state a --state b
SETUP=$STATES; sc "list-bad-state-among-good" rust 2 'unknown option --state bogus' -- session list --state working --state bogus
SETUP=$STATES; sc "list-bad-state-subdone" rust 2 'unknown option --state subdone' -- session list --state subdone
SETUP=$STATES; sc "list-bad-state-empty" rust 2 'unknown option --state ' -- session list --state ""
SETUP=$STATES; sc "list-bad-state-uppercase" rust 2 'unknown option --state Working' -- session list --state Working
SETUP=$STATES; sc "list-bad-state-padded" rust 2 'unknown option --state  working' -- session list --state " working"
SETUP=$STATES; sc "list-bad-state-comma-list-of-good" rust 2 'unknown option --state working,done' -- session list --state working,done
SETUP=$STATES; sc "list-bad-state-before-label" rust 2 'unknown option --state x' -- session list --label a --state x
SETUP=$STATES; sc "list-bad-state-with-unicode" rust 2 'unknown option --state é😀' -- session list --state 'é😀'
LOCALE=ru; SETUP=$STATES; sc "list-ru" rust 2 'неизвестный параметр --state a,b' -- session list --state a,b
LOCALE=ru; SETUP=$STATES; sc "list-ru-ok" rust 0 'sid-working' -- session list --state working
EXTRA=("TAGENTS_LOCALE=RU"); SETUP=$STATES; sc "list-bad-state-locale-is-exact" rust 2 'unknown option --state a,b' -- session list --state a,b

t "list: the label"
HIST="$(hist 1700000001 start sid-working %1 build "$RUN/work")$(hist 1700000002 turn sid-working %1 build "$RUN/work")$(hist 1700000003 start sid-done %2 review "$RUN/work")$(hist 1700000004 start sid-new %3 '' "$RUN/work")"
SETUP="$STATES$HIST"; sc "list-label" rust 0 '"label": "build"' -- session list
SETUP="$STATES$HIST"; sc "list-label-filter" rust 0 '"label": "build"' -- session list --label build
SETUP="$STATES$HIST"; sc "list-label-filter-inline" rust 0 '"label": "review"' -- session list --label=review
SETUP="$STATES$HIST"; sc "list-label-filter-none" rust 0 '[]' -- session list --label Build
SETUP="$STATES$HIST"; sc "list-label-filter-empty" rust 0 'sid-new' -- session list --label ""
SETUP="$STATES$HIST"; sc "list-label-filter-repeated" rust 0 '"label": "build"' -- session list --label review --label build
SETUP="$STATES$HIST"; sc "list-label-and-state" rust 0 '"label": "review"' -- session list --label review --state done
SETUP="$STATES$HIST"; sc "list-label-and-state-disjoint" rust 0 '[]' -- session list --label review --state working
SETUP="$STATES$(hist 1 start sid-working %1 first "$RUN/work")$(hist 2 start sid-working %1 second "$RUN/work")"; sc "list-label-last-history-line-wins" rust 0 'second' -- session list
SETUP="$STATES$(hist 1 start sid-working %1 'a b' "$RUN/work")"; sc "list-label-with-space" rust 0 'a b' -- session list --label 'a b'
SETUP="$STATES$(hist 1 start sid-working %1 'é😀' "$RUN/work")"; sc "list-label-with-unicode" rust 0 'é😀' -- session list --label 'é😀'
SETUP="$STATES$(hist 1 start sid-working %1 'say "x"' "$RUN/work")"; sc "list-label-with-quotes" rust 0 'say \"x\"' -- session list
SETUP="$STATES$(hist 1 kind sid-working %1 bad "$RUN/work")"; sc "list-label-history-line-with-a-bad-kind" rust 0 'sid-working' -- session list
SETUP="$STATES$(hist 1 start sid-working %1 bad "$RUN/work")"; sc "list-label-history-line-with-a-good-kind" rust 0 '"label": "bad"' -- session list
SETUP="$STATES$(hist 1700000001 start sid-working %1)"; sc "list-label-history-line-too-short" rust 0 'sid-working' -- session list
SETUP="$STATES$(hist 1700000001 start sid-working %1 five)"; sc "list-label-history-line-of-five-fields" rust 0 'sid-working' -- session list
SETUP="$STATES$(hist 1700000001 start sid-working %1 six '')"; sc "list-label-history-line-of-six-fields" rust 0 '"label": "six"' -- session list
SETUP="$STATES$(hist x start sid-working %1 build "$RUN/work")"; sc "list-label-history-line-with-a-bad-time" rust 0 'sid-working' -- session list
SETUP="$STATES$(hist 1 start sid-working %1 timed "$RUN/work")"; sc "list-label-history-line-with-a-good-time" rust 0 '"label": "timed"' -- session list
SETUP="$STATES"'printf "1700000001\tstart\tsid-working\t%%1\tcrlf\t/w\r\n" >> st/history.tsv'; sc "list-label-history-with-crlf" rust 0 '"label": "crlf"' -- session list
SETUP="$STATES"'mkdir -p st/history.tsv'; sc "list-label-history-is-a-directory" rust 0 'sid-working' -- session list
SETUP="$STATES$(hist 1 start sid-working %1 filed "$RUN/work")"; sc "list-label-history-is-a-file" rust 0 '"label": "filed"' -- session list
SETUP="$STATES$(hist 1 start sid-working %1 build "$RUN/work")"; sc "list-label-filter-with-lookalike" rust 0 '[]' -- session list --label 'build '

t "list: broken records and the columns"
SETUP="$(row 1 1700000100 working sid-1 /w '' d)$(rowraw 2 'garbage')$(rowraw 3 '')$(row 4 nan working sid-4 /w '' d)$(row 5 1700000100 bogus sid-5 /w '' d)$(row 6 1700000100 working sid-6 /w)$(row 7 1700000100 working sid-7 /w '' d)"
sc "list-broken-record" rust 0 'sid-7' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d)$(rowraw 2 '1700000100\tworking\tsid-2\t/w\t\td')"; sc "list-record-without-a-newline" rust 0 'sid-2' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d)$(rowraw 2 '1700000100\tworking\tsid-2\t/w\t\td\r\n')"; sc "list-record-with-crlf" rust 0 'sid-2' -- session list
SETUP="$(rowraw 1 '1700000100\tworking\tsid-1\t/w\t\td\nsecond line\n')"; sc "list-record-with-two-lines" rust 0 'sid-1' -- session list
SETUP="$(rowraw 1 '\n1700000100\tworking\tsid-1\t/w\t\td\n')"; sc "list-record-starting-with-an-empty-line" rust 0 '[]' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d)"; sc "list-six-columns" rust 0 '"claudeSessionId": "sid-1"' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d '')"; sc "list-seven-columns-account-empty" rust 0 '"configDir": null' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d /acct)"; sc "list-seven-columns-account-set" rust 0 '"configDir": "/acct"' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d /acct 4242 /log build 2 psid)"; sc "list-twelve-columns" rust 0 '"configDir": "/acct"' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d /acct 4242 /log build)$(hist 1 start sid-1 %1 history "$RUN/work")"; sc "list-label-of-the-record-is-not-used" rust 0 'history' -- session list
SETUP="$(row 1 1700000100 working '' /w '' d)"; sc "list-record-with-no-session" rust 0 '"claudeSessionId": null' -- session list
SETUP="$(row 1 1700000100 working sid-1 '' '' d)"; sc "list-record-with-no-cwd" rust 0 '"cwd": ""' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w "$PLAIN" d)"; sc "list-record-with-a-transcript" rust 0 "$PLAIN" -- session list
SETUP="$(row s-abc.def_1 1700000100 working sid-1 /w '' d)"; sc "list-headless-key" rust 0 '"id": "s-abc.def_1"' -- session list
SETUP="$(row 007 1700000100 working sid-1 /w '' d)"; sc "list-key-with-leading-zeros" rust 0 '"id": "007"' -- session list
SETUP="$(row s-é 1700000100 working sid-1 /w '' d)$(row 1x 1700000100 working sid-2 /w '' d)$(row s- 1700000100 working sid-3 /w '' d)$(row S-a 1700000100 working sid-4 /w '' d)"; sc "list-keys-that-are-not-keys" rust 0 '[]' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d)"'cp st/1.tsv st/2.tsv.bak; cp st/1.tsv st/3'; sc "list-files-that-are-not-records" rust 0 'sid-1' -- session list
SETUP="$(row 1 1700000100.5 working sid-1 /w '' d)$(row 2 1.7e9 working sid-2 /w '' d)$(row 3 ' 1700000000' working sid-3 /w '' d)"; sc "list-times-that-are-numbers" rust 0 '"claudeSessionId": "sid-3"' -- session list
SETUP="$(row 1 1700000100 working 'é😀' '/w é' '/t é' 'd é' '/a é')"; sc "list-unicode" rust 0 'é😀' -- session list
SETUP="$(row 1 1700000100 working 'a"b' '/w\x' '' d)"; sc "list-escapes" rust 0 'a\"b' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d)$(row 2 1700000200 working sid-2 /w '' d)$(row 3 1700000300 working sid-3 /w '' d)"; sc "list-newest-first" rust 0 'sid-3' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d)"'chmod 000 st/1.tsv'; sc_user "list-unreadable-record" rust 0 '[]' -- session list
SETUP="$STATES"'chmod 000 st'; sc_user "list-unreadable-state-directory" rust 0 '[]' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d)"'ln -s ../outside st/2.tsv; ln -s 1.tsv st/3.tsv'; sc "list-links" rust 0 'sid-1' -- session list
sc "list-positional" node 2 - -- session list x
sc "list-unknown-option" node 2 - -- session list --bogus
sc "list-option-without-value" node 2 - -- session list --label
sc "list-state-without-value" node 2 - -- session list --state
sc "list-value-starts-with-dash" node 2 - -- session list --label -x
sc "list-short-option" node 2 - -- session list -l x
SETUP="$(row 1 1700000100 working sid-1 /w '' d)"; sc "list-double-dash-ends-the-options" rust 0 'sid-1' -- session list --
sc "list-double-dash-positional" node 2 - -- session list -- x
sc "list-an-argument-that-is-not-utf8" node - - -- session list --label $'\xff'
EXTRA=("TA_STATE_DIR="); SETUP="mkdir -p home/.claude/agent-state; $(row 1 1700000100 working sid-1 /w '' d | sed 's#st/#home/.claude/agent-state/#')"; sc "list-empty-state-variable-means-the-default" rust 0 'sid-1' -- session list
EXTRA=("TA_STATE_DIR=   "); SETUP="mkdir -p home/.claude/agent-state; $(row 1 1700000100 working sid-1 /w '' d | sed 's#st/#home/.claude/agent-state/#')"; sc "list-blank-state-variable-means-the-default" rust 0 'sid-1' -- session list
EXTRA=("TA_STATE_DIR=st"); SETUP="$(row 1 1700000100 working sid-1 /w '' d)"; sc "list-relative-state-directory" rust 0 'sid-1' -- session list
REPLACED=$'\xef\xbf\xbd'
EXTRA=($'TA_STATE_DIR=st\xff'); SETUP="$(row 1 1700000100 working sid-1 /w '' d)mv st st$REPLACED"; sc "list-state-variable-is-not-utf8" rust 0 'sid-1' -- session list
EXTRA=("HOME=$RUN/home"$'\xff' "TA_STATE_DIR="); SETUP="$(row 1 1700000100 working sid-1 /w '' d)mkdir -p home$REPLACED/.claude; mv st home$REPLACED/.claude/agent-state"; sc "list-home-is-not-utf8" rust 0 'sid-1' -- session list

# ------------------------------------------------------------------- last ---
t "last: the transcript of a reference"
sc "last-transcript" rust 0 'the last reply' -- session last "$(ref_transcript plain.jsonl)"
sc "last-transcript-ru" rust 0 'ответ: привет, мир 😀' -- session last "$(ref_transcript ru.jsonl)"
sc "last-transcript-no-newline" rust 0 'no final newline' -- session last "$(ref_transcript no-newline.jsonl)"
sc "last-transcript-two-blocks" rust 0 'two' -- session last "$(ref_transcript two-blocks.jsonl)"
sc "last-transcript-junk-lines" rust 0 'after junk' -- session last "$(ref_transcript junk.jsonl)"
sc "last-transcript-controls" rust 0 '\u0007' -- session last "$(ref_transcript controls.jsonl)"
sc "last-transcript-pair-and-escapes" rust 0 '\u0000' -- session last "$(ref_transcript pair.jsonl)"
sc "last-transcript-inside-the-window" rust 0 'inside the window' -- session last "$(ref_transcript at-window.jsonl)"
sc "last-transcript-cut-in-a-character" rust 0 'after a cut' -- session last "$(ref_transcript cut-char.jsonl)"
sc "last-transcript-invalid-utf8" rust 0 $'a\xef\xbf\xbd\xef\xbf\xbdb' -- session last "$(ref_transcript bad-utf8.jsonl)"
sc "last-reference-with-spaces-before" rust 0 'the last reply' -- session last "  $(ref_transcript plain.jsonl)"
sc "last-reference-with-newline-before" rust 0 'the last reply' -- session last "$(printf '\n\t')$(ref_transcript plain.jsonl)"
sc "last-reference-with-trailing-text" rust 1 '}} trailing' -- session last "$(ref_transcript plain.jsonl) trailing"
LOCALE=ru; sc "last-transcript-and-ru" rust 0 'the last reply' -- session last "$(ref_transcript plain.jsonl)"

t "last: no reply"
sc "last-no-transcript" rust 0 'null' -- session last "$(ref_session nobody)"
sc "last-transcript-is-missing" rust 0 'null' -- session last "$(ref_transcript missing.jsonl)"
sc "last-transcript-is-empty" rust 0 'null' -- session last "$(ref_transcript empty.jsonl)"
sc "last-transcript-without-assistant" rust 0 'null' -- session last "$(ref_transcript no-assistant.jsonl)"
sc "last-transcript-blank-text" rust 0 'null' -- session last "$(ref_transcript blank-text.jsonl)"
sc "last-transcript-before-the-window" rust 0 'null' -- session last "$(ref_transcript before-window.jsonl)"
sc "last-transcript-empty-path" rust 0 'null' -- session last '{"id":"r1","claudeSessionId":null,"transcript":"","spec":{"kind":"claude","cwd":"/w","skipPermissions":false}}'
sc "last-transcript-relative-path" rust 0 'the last reply' -- session last '{"id":"r1","claudeSessionId":null,"transcript":"tr/plain.jsonl","spec":{"kind":"claude","cwd":"/w","skipPermissions":false}}'
sc "last-transcript-is-null-and-no-session" rust 0 'null' -- session last '{"id":"r1","claudeSessionId":null,"transcript":null,"spec":{"kind":"claude","cwd":"/w","skipPermissions":false}}'
sc "last-transcript-is-null-and-empty-session" rust 0 'null' -- session last '{"id":"r1","claudeSessionId":"","transcript":null,"spec":{"kind":"claude","cwd":"/w","skipPermissions":false}}'

t "last: a lone surrogate"
sc "last-lone-surrogate-high" rust 0 '\ud83d' -- session last "$(ref_transcript lone-high.jsonl)"
sc "last-lone-surrogate-low" rust 0 '\ude00' -- session last "$(ref_transcript lone-low.jsonl)"
sc "last-lone-surrogate-trimmed" rust 0 '\ud83d' -- session last "$(ref_transcript lone-and-trim.jsonl)"

t "last: a transcript that cannot be read"
SETUP='chmod 000 tr/plain.jsonl'; sc_user "last-unreadable" rust 1 'EACCES' -- session last "$(ref_transcript plain.jsonl)"
sc "last-transcript-is-a-directory" rust 1 'EISDIR' -- session last "$(ref_transcript a-directory.jsonl)"
SETUP='chmod 000 tr'; sc_user "last-unreadable-directory" rust 0 'null' -- session last "$(ref_transcript plain.jsonl)"
SETUP='ln -s nowhere tr/broken.jsonl'; sc "last-transcript-is-a-broken-link" rust 0 'null' -- session last "$(ref_transcript broken.jsonl)"
SETUP='ln -s plain.jsonl tr/link.jsonl'; sc "last-transcript-is-a-link" rust 0 'the last reply' -- session last "$(ref_transcript link.jsonl)"

t "last: the transcript of a state record"
ROWS="$(row 5 1700000100 working sid-1 "$RUN/work" "$PLAIN" detail)$(row s-sid-2 1700000200 done sid-2 "$RUN/work" "$RUN/tr/ru.jsonl" detail)"
SETUP=$ROWS; sc "last-by-state-row" rust 0 'the last reply' -- session last "$(ref_session sid-1)"
SETUP=$ROWS; sc "last-by-state-row-headless" rust 0 'ответ' -- session last "$(ref_session sid-2)"
SETUP=$ROWS; sc "last-by-state-row-without-a-session" rust 0 'null' -- session last "$(ref_session sid-3)"
SETUP=$ROWS; sc "last-by-state-row-the-prefix-is-not-a-session" rust 0 'null' -- session last "$(ref_session sid)"
SETUP=$ROWS; sc "last-by-state-row-transcript-of-the-reference-wins" rust 0 'ответ' -- session last "$(printf '{"id":"r1","claudeSessionId":"sid-1","transcript":"%s/tr/ru.jsonl","spec":{"kind":"claude","cwd":"/w","skipPermissions":false}}' "$RUN")"
SETUP="$(row 5 1700000100 working sid-1 "$RUN/work" "" detail)"; sc "last-by-state-row-without-transcript" rust 0 'null' -- session last "$(ref_session sid-1)"
SETUP="$(row 5 1700000300 working sid-1 "$RUN/work" "" detail)$(row 6 1700000200 done sid-1 "$RUN/work" "$PLAIN" detail)"; sc "last-by-state-row-skips-a-newer-row-without-transcript" rust 0 'the last reply' -- session last "$(ref_session sid-1)"
SETUP="$(row 5 1700000100 subdone sid-1 "$RUN/work" "$PLAIN" detail)"; sc "last-by-state-row-subdone" rust 0 'the last reply' -- session last "$(ref_session sid-1)"
SETUP="$(row 5 1700000100 working sid-1 "$RUN/work" "$RUN/tr/missing.jsonl" detail)"; sc "last-by-state-row-transcript-is-missing" rust 0 'null' -- session last "$(ref_session sid-1)"

t "last: a session id in place of a reference"
SETUP=$ROWS; sc "last-id-is-a-claude-session" rust 0 'the last reply' -- session last sid-1
SETUP=$ROWS; sc "last-id-is-a-key" rust 0 'the last reply' -- session last 5
SETUP=$ROWS; sc "last-id-is-a-headless-key" rust 0 'ответ' -- session last s-sid-2
SETUP=$ROWS; sc "last-id-is-a-prefix" rust 0 'ответ' -- session last sid-
SETUP="$(row 5 1700000100 working abc1 "$RUN/work" "$PLAIN" d)$(row 6 1700000200 working abc2 "$RUN/work" "$RUN/tr/ru.jsonl" d)"; sc "last-prefix-first-in-order" rust 0 'ответ' -- session last abc
SETUP="$(row 5 1700000100 working abc1 "$RUN/work" "$PLAIN" d)$(row 6 1700000200 working abc2 "$RUN/work" "$RUN/tr/ru.jsonl" d)"; sc "last-prefix-that-is-unique" rust 0 'the last reply' -- session last abc1
SETUP="$(row 5 1700000100 working abc "$RUN/work" "$PLAIN" d)$(row 6 1700000200 working abcdef "$RUN/work" "$RUN/tr/ru.jsonl" d)"; sc "last-exact-beats-a-prefix-of-an-earlier-row" rust 0 'the last reply' -- session last abc
SETUP="$(row 5 1700000100 working abcdef "$RUN/work" "$PLAIN" d)$(row 6 1700000200 working abc "$RUN/work" "$RUN/tr/ru.jsonl" d)"; sc "last-exact-beats-a-prefix-of-a-later-row" rust 0 'ответ' -- session last abc
SETUP="$(row 7 1700000100 working 7 "$RUN/work" "$PLAIN" d)$(row 8 1700000200 working sid-8 "$RUN/work" "$RUN/tr/ru.jsonl" d)"; sc "last-key-matches-exactly" rust 0 'ответ' -- session last 8
SETUP="$(row 7 1700000100 working sid-7 "$RUN/work" "$PLAIN" d)$(row 8 1700000200 working 7 "$RUN/work" "$RUN/tr/ru.jsonl" d)"; sc "last-id-matches-a-key-or-a-session-first-in-order" rust 0 'ответ' -- session last 7
SETUP="$(row 5 1700000100 working '' "$RUN/work" "$PLAIN" d)"; sc "last-a-row-with-no-session-has-no-prefix" rust 1 'no session matches s' -- session last s
SETUP="$(row 5 1700000100 subdone sid-1 "$RUN/work" "$PLAIN" d)"; sc "last-a-subdone-row-is-not-listed" rust 1 'no session matches sid-1' -- session last sid-1
SETUP="$(row 5 1700000100 working sid-1 "$RUN/work" "$PLAIN" d)"; sc "last-id-is-case-sensitive" rust 1 'no session matches SID-1' -- session last SID-1
SETUP="$(row 5 1700000100 working sid-1 "$RUN/work" "$PLAIN" d)"; sc "last-id-with-a-trailing-space" rust 1 'no session matches sid-1 ' -- session last 'sid-1 '
SETUP="$(row 5 1700000100 working 'é😀x' "$RUN/work" "$PLAIN" d)"; sc "last-prefix-is-unicode" rust 0 'the last reply' -- session last 'é😀'
SETUP="$(row 5 1700000100 working 'é😀x' "$RUN/work" "$PLAIN" d)"; sc "last-prefix-is-half-an-emoji" node 1 $'no session matches \xef\xbf\xbd' -- session last $'\xf0\x9f'
SETUP="$(row 5 1700000100 working sid-1 "$RUN/work" "$PLAIN" d)"; sc "last-id-looks-like-an-option" rust 0 'the last reply' -- session last sid-1 --bogus
SETUP="$(row 5 1700000100 working -x "$RUN/work" "$PLAIN" d)"; sc "last-id-is-an-option-looking-session" rust 0 'the last reply' -- session last -x
SETUP="$(row 5 1700000100 working sid-1 "$RUN/work" "$PLAIN" d)"; sc "last-id-and-more-words" rust 0 'the last reply' -- session last sid-1 more words
SETUP="$(row 5 1700000100 working -- "$RUN/work" "$PLAIN" d)"; sc "last-double-dash-is-the-reference" rust 0 'the last reply' -- session last --
SETUP="$(row 5 1700000100 working sid-1 "$RUN/work" "$PLAIN" d)"; sc "last-id-from-a-unicode-argument" rust 1 'no session matches é' -- session last 'é'

t "last: a reference that does not name a session"
sc "last-bad-ref" rust 1 'no session matches {bad' -- session last '{bad'
sc "last-bad-ref-schema" rust 1 'no session matches {"id":1}' -- session last '{"id":1}'
sc "last-bad-ref-empty-object" rust 1 'no session matches {}' -- session last '{}'
sc "last-bad-ref-kind" rust 1 '"kind":"other"' -- session last '{"id":"r1","claudeSessionId":null,"transcript":null,"spec":{"kind":"other","cwd":"/w","skipPermissions":false}}'
sc "last-bad-ref-missing-spec" rust 1 'no session matches {"id":"r1","claudeSessionId":null,"transcript":null}' -- session last '{"id":"r1","claudeSessionId":null,"transcript":null}'
sc "last-bad-ref-trailing-comma" rust 1 '"skipPermissions":false},}' -- session last '{"id":"r1","claudeSessionId":null,"transcript":null,"spec":{"kind":"claude","cwd":"/w","skipPermissions":false},}'
sc "last-bad-ref-array" rust 1 'no session matches [' -- session last '[]'
sc "last-bad-ref-not-an-object-after-spaces" rust 1 'no session matches    {' -- session last '   {'
sc "last-bad-ref-spaces-only-is-a-session-id" rust 1 'no session matches    ' -- session last '   '
sc "last-bad-ref-with-unicode" rust 1 'no session matches {é😀' -- session last '{é😀'
sc "last-bad-ref-with-a-newline" rust 1 'no session matches {' -- session last $'{\n}'
LOCALE=ru; sc "last-bad-ref-ru" rust 1 'сессия не найдена: {bad' -- session last '{bad'
LOCALE=ru; sc "last-missing-ref-ru" rust 2 'не хватает обязательного параметра <ref>' -- session last
sc "last-missing-ref" rust 2 'missing required option <ref>' -- session last
sc "last-empty-ref" rust 2 'missing required option <ref>' -- session last ""
sc "last-unknown-ref" rust 1 'no session matches nobody' -- session last nobody
sc "last-an-argument-that-is-not-utf8" node - - -- session last $'\xff'
sc "last-a-reference-with-a-lone-surrogate-escape" node - - -- session last '{"id":"\ud83d","claudeSessionId":null,"transcript":null,"spec":{"kind":"claude","cwd":"/w","skipPermissions":false}}'
sc "last-a-reference-with-a-lone-surrogate-escape-in-a-key" node - - -- session last '{"id":"r1","claudeSessionId":null,"transcript":null,"spec":{"kind":"claude","cwd":"/w","skipPermissions":false},"\ud83d":1}'
sc "last-a-reference-with-a-lone-surrogate-in-the-transcript" node - - -- session last '{"id":"r1","claudeSessionId":null,"transcript":"/t\ud83d.jsonl","spec":{"kind":"claude","cwd":"/w","skipPermissions":false}}'
sc "last-a-reference-with-a-nul" node - - -- session last '{"id":"r1","claudeSessionId":null,"transcript":null,"spec":{"kind":"claude","cwd":"/w\u0000","skipPermissions":false}}'
sc "last-a-reference-with-an-empty-bin" node - - -- session last '{"id":"r1","claudeSessionId":null,"transcript":null,"spec":{"kind":"claude","cwd":"/w","skipPermissions":false,"bin":""}}'
sc "last-a-reference-with-a-bad-env-name" node - - -- session last '{"id":"r1","claudeSessionId":null,"transcript":null,"spec":{"kind":"claude","cwd":"/w","skipPermissions":false,"env":{"A=B":"1"}}}'

# ------------------------------------------------------------ prompt: the helpers ---
# The reference of a turn in `work`, with more keys of the spec when given, and the same with a working directory of its own.
ref_spec() {  # [,"key":value...] [skipPermissions]
  printf '{"id":"r1","claudeSessionId":null,"transcript":null,"spec":{"kind":"claude","cwd":"%s/work","skipPermissions":%s%s}}' "$RUN" "${2:-false}" "${1:-}"
}
ref_cwd() { printf '{"id":"r1","claudeSessionId":null,"transcript":null,"spec":{"kind":"claude","cwd":"%s","skipPermissions":false}}' "$1"; }
# One write of the stub, of exactly these bytes, as `rawWrites` wants it.
piece() { printf '{"hex":"%s"%s}' "$(printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n')" "${2:+,\"to\":\"$2\"}"; }
# A whole line of the stream: `$(...)` would drop a newline at the end of the text.
line() { piece "$1"$'\n'; }
text_event() { printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}' "$1"; }
RESULT='{"type":"result","is_error":false,"result":"done","session_id":"s-9","total_cost_usd":0.5,"num_turns":2,"duration_ms":7}'
ANSWER='{"text":"hi","result":{"text":"done"}}'
# Who answers on this platform when the program is reached through a relative path: macOS's posix_spawn has its own rules for it, so the binary leaves it to node, and elsewhere both programs end in the same execvp.
if [ "$(uname)" = Darwin ]; then ONLY_NODE_HERE=node; else ONLY_NODE_HERE=rust; fi
# Who answers a file with no `#!`: macOS refuses to run it and the binary hands that errno over. Elsewhere it depends on the libc of the binary: glibc's execvp runs it through /bin/sh as node's does, the release's musl refuses and hands over. The bytes are the same either way.
if [ "$(uname)" = Darwin ]; then NO_SHEBANG=node; else NO_SHEBANG=any; fi

# ------------------------------------------------------------- prompt: the words ---
t "prompt: the arguments of the child"
STUB=$ANSWER; HAS='"say hi"'; sc "prompt-minimal" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" "say hi"
STUB=$ANSWER; HAS='"--dangerously-skip-permissions"'; sc "prompt-each-option" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec ',"label":"L","configDir":"/cfg/a","model":"opus","effort":"high","systemPromptFile":"/p/s.md","mcpConfig":"/p/m.json","disallowedTools":["Bash","Read"],"env":{"X_ONE":"1","X_TWO":"two"},"logFile":"/p/turn.log"' true)" "go"
STUB=$ANSWER; HAS='"--model"'; sc "prompt-option-model" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec ',"model":"opus"')" go
STUB=$ANSWER; HAS_NOT='"--model"'; sc "prompt-option-empty-model" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec ',"model":""')" go
STUB=$ANSWER; HAS='"--effort"'; sc "prompt-option-effort" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec ',"effort":"high"')" go
STUB=$ANSWER; HAS='"Bash,Read"'; sc "prompt-option-disallowed" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec ',"disallowedTools":["Bash","Read"]')" go
STUB=$ANSWER; HAS_NOT='"--disallowedTools"'; sc "prompt-option-disallowed-empty" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec ',"disallowedTools":[]')" go
STUB=$ANSWER; HAS='"--strict-mcp-config"'; sc "prompt-option-mcp" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec ',"mcpConfig":"/p/m.json"')" go
STUB=$ANSWER; HAS='"--append-system-prompt-file"'; sc "prompt-option-system-prompt" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec ',"systemPromptFile":"/p/s.md"')" go
STUB=$ANSWER; HAS='"--dangerously-skip-permissions"'; sc "prompt-option-skip" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec '' true)" go
STUB=$ANSWER; HAS='"sid-9"'; sc "prompt-resume" rust 0 '"kind": "ok"' -- session prompt "$(ref_session sid-9)" go
STUB=$ANSWER; HAS_NOT='"--resume"'; sc "prompt-resume-empty" rust 0 '"kind": "ok"' -- session prompt "$(ref_session '')" go
SETUP="$(row 5 1700000100 working sid-1 "$RUN/work" "$PLAIN" d)"; STUB=$ANSWER; HAS='"sid-1"'; sc "prompt-id-from-a-state-row" rust 0 '"kind": "ok"' -- session prompt sid-1 go
SETUP="$(row 5 1700000100 working sid-12 "$RUN/work" "$PLAIN" d)"; STUB=$ANSWER; HAS='"sid-12"'; sc "prompt-id-prefix-from-a-state-row" rust 0 '"kind": "ok"' -- session prompt sid-1 go
STUB=$ANSWER; HAS='"-x go"'; sc "prompt-dash-text" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" -- "-x go"
STUB=$ANSWER; HAS='"-"'; sc "prompt-lone-dash-text" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" -
STUB=$ANSWER; HAS='"  go  "'; sc "prompt-text-keeps-its-spaces" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" "  go  "
STUB=$ANSWER; HAS='"привет 😀"'; sc "prompt-text-unicode" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" "привет 😀"
STUB=$ANSWER; HAS='"two\nlines"'; sc "prompt-text-with-a-newline" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" $'two\nlines'
STUB=$ANSWER; HAS='"last wins"'; sc "prompt-extra-words-are-ignored" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" "last wins" and more words
STUB=$ANSWER; sc "prompt-options-before-the-words" rust 0 '{"kind":"ok"' -- session prompt --events --timeout 60000 --warn-before 1 "$(ref_spec)" go
STUB=$ANSWER; sc "prompt-options-after-the-words" rust 0 '{"kind":"ok"' -- session prompt "$(ref_spec)" go --events --timeout=60000
STUB=$ANSWER; sc "prompt-warn-before-prints-nothing" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go --warn-before abc
sc "prompt-unknown-option" node 2 'Unknown option' -- session prompt "$(ref_spec)" go --bogus
sc "prompt-dash-text-without-the-separator" node 2 - -- session prompt "$(ref_spec)" "-x go"
sc "prompt-events-with-a-value" node 2 '--events' -- session prompt "$(ref_spec)" go --events=x
sc "prompt-timeout-with-no-value" node 2 '--timeout' -- session prompt "$(ref_spec)" go --timeout
sc "prompt-timeout-that-looks-like-an-option" node 2 '--timeout' -- session prompt "$(ref_spec)" go --timeout -5
STUB=$ANSWER; HAS=$'"a\xef\xbf\xbdb"'; STARTS=1; sc "prompt-argument-not-utf8" node 0 '"kind": "ok"' -- session prompt "$(ref_spec)" $'a\xffb'
sc "prompt-reference-not-utf8" node 1 $'no session matches \xef\xbf\xbd' -- session prompt $'\xff' go

# ------------------------------------------------------- prompt: the environment ---
t "prompt: the environment of the child"
EXTRA=("CLAUDE_CONFIG_DIR=/a" "CLAUDE_X=1"); STUB=$ANSWER; HAS='"CLAUDE_CONFIG_DIR": "/a"'; HAS_NOT='"CLAUDE_X"'; sc "prompt-config-dir-inherited" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
EXTRA=("CLAUDE_CONFIG_DIR=/a"); STUB=$ANSWER; HAS_NOT='"CLAUDE_CONFIG_DIR"'; sc "prompt-config-dir-null-drops-it" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec ',"configDir":null')" go
EXTRA=("CLAUDE_CONFIG_DIR=/a"); STUB=$ANSWER; HAS_NOT='"CLAUDE_CONFIG_DIR"'; sc "prompt-config-dir-empty-drops-it" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec ',"configDir":""')" go
EXTRA=("CLAUDE_CONFIG_DIR=/a"); STUB=$ANSWER; HAS='"CLAUDE_CONFIG_DIR": "/b"'; sc "prompt-config-dir-of-the-spec-wins" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec ',"configDir":"/b"')" go
EXTRA=("CLAUDE_X=1" "CLAUDECODE=1" "CLAUDE_CODE_ENTRYPOINT=cli" "ANTHROPIC_KEEPS=1"); STUB=$ANSWER; HAS='"ANTHROPIC_KEEPS": "1"'; HAS_NOT='"CLAUDE'; sc "prompt-claude-vars-dropped" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
EXTRA=("CLAUDE_X=1"); STUB=$ANSWER; HAS='"CLAUDE_X": "spec"'; sc "prompt-env-wins" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec ',"label":"L","logFile":"/p/l.log","env":{"CLAUDE_X":"spec","TA_LABEL":"spec-label","TA_LOG":"spec-log","HOME":"/spec/home","NEW_ONE":"1","__proto__":"x"}')" go
STUB=$ANSWER; HAS='"TA_LABEL": "L"'; sc "prompt-label-log" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec ",\"label\":\"L\",\"logFile\":\"$RUN/tmp/turn.log\"")" go
STUB=$ANSWER; HAS_NOT='"TA_LABEL"'; sc "prompt-empty-label-sets-nothing" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec ',"label":"","logFile":""')" go
EXTRA=("PATH=/a:/b:/a::$BIN:/usr/bin:/bin:"); STUB=$ANSWER; HAS="\"PATH\": \"<node-dir>:$RUN/home/.local/bin:/a:/b:$BIN:/usr/bin:/bin\""; sc "prompt-path-order" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
EXTRA=("PATH=$BIN:$RUN/home/.local/bin:/usr/bin:/bin"); STUB=$ANSWER; HAS="\"PATH\": \"<node-dir>:$RUN/home/.local/bin:$BIN:/usr/bin:/bin\""; sc "prompt-path-local-bin-comes-once" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
SETUP='mkdir -p home/.local/bin && cp "$BIN/claude" home/.local/bin/claude'; EXTRA=("PATH=/usr/bin:/bin"); STUB=$ANSWER; sc "prompt-stub-in-local-bin" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
SETUP='mkdir tmp/p && cp "$BIN/claude" tmp/p/claude'; EXTRA=("PATH=/usr/bin:/bin"); STUB=$ANSWER; HAS="\"PATH\": \"$RUN/tmp/p\""; sc "prompt-path-of-the-spec-finds-the-stub" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec ",\"env\":{\"PATH\":\"$RUN/tmp/p\"}")" go
EXTRA=("PATH=$BIN:/usr/bin:/bin"); sc "prompt-path-of-the-spec-does-not" rust 1 'spawn claude ENOENT' -- session prompt "$(ref_spec ',"env":{"PATH":"/nowhere"}')" go
SETUP='ln -s "$SHIM/node" tmp/node-link'; EXTRA=("TAGENTS_NODE=$RUN/tmp/node-link"); STUB=$ANSWER; sc "prompt-node-by-a-symlink" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
SETUP='mkdir tmp/nodes && ln -s "$SHIM/node" tmp/nodes/node'; EXTRA=("TAGENTS_NODE=" "PATH=$RUN/tmp/nodes:$BIN:/usr/bin:/bin"); STUB=$ANSWER; HAS="\"PATH\": \"<node-dir>:$RUN/home/.local/bin:$RUN/tmp/nodes:$BIN:/usr/bin:/bin\""; sc "prompt-node-from-path" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
# The way the binary runs on a machine: node is found on PATH through a link, and the directory of its real path comes first. No shim can stand in here, so who answered cannot be told.
EXTRA=("TAGENTS_NODE=" "PATH=$NODE_DIR:$BIN:/usr/bin:/bin"); CHILD_NODE_DIR=$NODE_DIR; STUB=$ANSWER; HAS="\"PATH\": \"<node-dir>:$RUN/home/.local/bin:$BIN:/usr/bin:/bin\""; sc "prompt-node-real-directory-comes-once" any 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
EXTRA=("TAGENTS_NODE="); CHILD_NODE_DIR=$NODE_DIR; STUB=$ANSWER; HAS="\"PATH\": \"<node-dir>:$RUN/home/.local/bin:$BIN:/usr/bin:/bin\""; sc "prompt-node-real-through-a-link" any 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
EXTRA=($'BAD=\xff'); STUB=$ANSWER; HAS=$'"BAD": "\xef\xbf\xbd"'; sc "prompt-env-not-utf8" node 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
EXTRA=($'B\xffD=1'); STUB=$ANSWER; sc "prompt-env-name-not-utf8" node 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
STUB=$ANSWER; HAS='"A": "B=1"'; sc "prompt-bad-env-name" node 0 '"kind": "ok"' -- session prompt "$(ref_spec ',"env":{"A=B":"1"}')" go
STUB=$ANSWER; sc "prompt-lone-surrogate-in-the-reference" node 0 '"kind": "ok"' -- session prompt "$(ref_spec ',"model":"\ud83d"')" go
sc "prompt-nul-in-the-cwd" node 1 'null bytes' -- session prompt "$(ref_cwd '/w\u0000')" go
sc "prompt-nul-in-an-env-value" node 1 'null bytes' -- session prompt "$(ref_spec ',"env":{"A":"x\u0000y"}')" go
sc "prompt-empty-bin" node 1 'empty' -- session prompt "$(ref_spec ',"bin":""')" go

t "prompt: the working directory of the child"
STUB=$ANSWER; HAS="\"cwd\": \"$RUN/work\""; sc "prompt-cwd-of-the-spec" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
CWD=work; STUB=$ANSWER; HAS="\"cwd\": \"$RUN/work\""; sc "prompt-cwd-empty-is-the-cli-s" rust 0 '"kind": "ok"' -- session prompt "$(ref_cwd '')" go
STUB=$ANSWER; HAS="\"cwd\": \"$RUN/work\""; sc "prompt-cwd-relative" rust 0 '"kind": "ok"' -- session prompt "$(ref_cwd 'work')" go

if [ "$(uname)" = Darwin ]; then
  t "prompt: keeping the machine awake"
  # The stub of caffeinate says how it was started and what its streams are, and that it was asked to leave.
  AWAKE=1; WAIT_FOR=released; STUB='{"sleepMs":1500,"result":{}}'; HAS_NOT=; sc "prompt-keep-awake" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
  if [ -n "$RAN" ] && ! grep -qF -- '-i -w <child>' "$TMP/caffeinate.node"; then bad "tripwire prompt-keep-awake: node did not start caffeinate for the child" "$(tr '\n' '|' < "$TMP/caffeinate.node")"; fi
  if [ -n "$RAN" ] && ! grep -qF released "$TMP/caffeinate.node"; then bad "tripwire prompt-keep-awake: node did not release caffeinate"; fi
  STUB=$ANSWER; sc "prompt-keep-awake-off" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
  if [ -n "$RAN" ] && [ -s "$TMP/caffeinate.node" ]; then bad "tripwire prompt-keep-awake-off: node started caffeinate"; fi
  AWAKE=1; SETUP='mkdir tmp/p && cp "$BIN/claude" tmp/p/claude'; EXTRA=("PATH=$RUN/tmp/p"); STUB=$ANSWER; sc "prompt-keep-awake-with-no-caffeinate" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
  AWAKE=1; EXTRA=("TA_KEEP_AWAKE=1"); WAIT_FOR=released; STUB='{"sleepMs":1500,"result":{}}'; sc "prompt-keep-awake-any-other-value" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
fi

# ---------------------------------------------------------- prompt: the outcomes ---
t "prompt: what a turn ends as"
STUB='{"sessionId":"s-1","tools":["Bash",{"name":"Read","input":{"a":1}}],"text":"hi","result":{"text":"done","costUsd":0.25,"numTurns":7,"durationMs":9}}'; sc "prompt-ok" rust 0 '"sessionId": "s-1"' -- session prompt "$(ref_spec)" go
STUB='{"text":"hi","result":{},"killSelf":"SIGKILL"}'; sc "prompt-killed-after-result" rust 0 '"kind": "killed-after-result"' -- session prompt "$(ref_spec)" go
STUB='{"text":"hi","result":{},"exitCode":3}'; sc "prompt-exit-code-after-result" rust 0 '"code": 3' -- session prompt "$(ref_spec)" go
STUB='{"text":"partial","exitCode":3,"stderr":"boom\n"}'; sc "prompt-exit-code" rust 1 '"code": 3' -- session prompt "$(ref_spec)" go
STUB='{"text":"partial","killSelf":"SIGTERM"}'; sc "prompt-exit-signal" rust 1 '"signal": "SIGTERM"' -- session prompt "$(ref_spec)" go
STUB='{"stderr":"only this\n","exitCode":1}'; sc "prompt-stderr-only" rust 1 'only this' -- session prompt "$(ref_spec)" go
STUB='{"exitCode":0}'; sc "prompt-no-result-and-code-0" rust 1 '"code": 0' -- session prompt "$(ref_spec)" go
STUB='{"result":{"isError":true,"text":"it broke"}}'; sc "prompt-is-error" rust 1 'it broke' -- session prompt "$(ref_spec)" go
STUB='{"result":{"isError":true,"text":""},"stderr":"unused\n"}'; sc "prompt-is-error-with-an-empty-result" rust 1 '"sawResult": true' -- session prompt "$(ref_spec)" go
STUB="{\"rawWrites\":[$(line '{"type":"result","is_error":null}')],\"exitCode\":1}"; sc "prompt-bad-result-schema" rust 1 '{"kind":"other","type":"result"}' -- session prompt "$(ref_spec)" go --events
STUB="{\"rawWrites\":[$(line '{"type":"result","is_error":false,"total_cost_usd":1e999}')],\"exitCode\":0}"; sc "prompt-result-whose-cost-is-infinite" rust 1 '{"kind":"other","type":"result"}' -- session prompt "$(ref_spec)" go --events
STUB='{"plain":true,"result":{"text":"plain"}}'; sc "prompt-plain-payload" rust 0 '"text": ""' -- session prompt "$(ref_spec)" go
STUB='{"noise":["a banner","{broken","[1,2]","{\"no_type\":1}","   "],"text":"hi","result":{}}'; sc "prompt-noise" rust 0 '{"kind":"text","text":"hi"}' -- session prompt "$(ref_spec)" go --events
STUB='{"tools":["Bash",{"name":"Read","input":{"a":[1,{"b":null}]}}],"text":"hi","result":{}}'; sc "prompt-events" rust 0 '{"kind":"tool_use","name":"Bash","input":{}}' -- session prompt "$(ref_spec)" go --events
STUB='{"chunked":true,"tools":["Bash"],"text":"hi","result":{}}'; sc "prompt-chunked" rust 0 '{"kind":"text","text":"hi"}' -- session prompt "$(ref_spec)" go --events
EVENT=$(text_event 'é😀')
STUB="{\"rawWrites\":[$(piece "${EVENT%%😀*}"$'\xf0\x9f'),$(line $'\x98\x80'"${EVENT##*😀}")],\"result\":{}}"; sc "prompt-split-char" rust 0 '{"kind":"text","text":"é😀"}' -- session prompt "$(ref_spec)" go --events
STUB="{\"rawWrites\":[$(line "$(text_event $'a\xff\xc3b')")],\"result\":{}}"; sc "prompt-invalid-utf8" rust 0 $'{"kind":"text","text":"a\xef\xbf\xbd\xef\xbf\xbdb"}' -- session prompt "$(ref_spec)" go --events
STUB="{\"rawWrites\":[$(piece $'bad\xff\xc3' stderr)],\"exitCode\":2}"; sc "prompt-invalid-utf8-in-stderr" rust 1 $'bad\xef\xbf\xbd\xef\xbf\xbd' -- session prompt "$(ref_spec)" go
STUB="{\"rawWrites\":[$(piece $'split\xf0\x9f' stderr),$(piece $'\x98\x80 whole' stderr)],\"exitCode\":2}"; sc "prompt-char-split-in-stderr" rust 1 'split😀 whole' -- session prompt "$(ref_spec)" go
STUB="{\"rawWrites\":[$(line "$(text_event 'a\ud83dz')")],\"result\":{}}"; sc "prompt-lone-surrogate" rust 0 '"text":"a\ud83dz"' -- session prompt "$(ref_spec)" go --events
STUB="{\"rawWrites\":[$(line "$(text_event 'a\ud83dz')")],\"result\":{}}"; sc "prompt-lone-surrogate-in-the-outcome" rust 0 '"text": "a\ud83dz"' -- session prompt "$(ref_spec)" go
STUB="{\"rawWrites\":[$(line "$(text_event '\ud83d')"),$(line "$(text_event '\ude00')")],\"result\":{}}"; sc "prompt-two-halves-join" rust 0 '"text": "😀"' -- session prompt "$(ref_spec)" go
STUB="{\"rawWrites\":[$(line '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"N\ud83d","input":{"\ude00":"\ud83d"}}]}}')],\"result\":{}}"; sc "prompt-lone-surrogate-in-a-tool-input" rust 0 '"input":{"\ude00":"\ud83d"}' -- session prompt "$(ref_spec)" go --events
STUB="{\"rawWrites\":[$(line '{"type":"result","is_error":false,"result":"r","\ud83d":{"\ude00":1,"\ud83e":2}}')],\"result\":null}"; sc "prompt-lone-surrogate-in-a-payload-key" rust 0 '"\ud83d":{"\ude00":1,"\ud83e":2}' -- session prompt "$(ref_spec)" go --events
STUB="{\"rawWrites\":[$(line '{"type":"result","is_error":false,"result":"\ud83d","session_id":"s\ude00"}')]}"; sc "prompt-lone-surrogate-in-a-result" rust 0 '"result":"\ud83d"' -- session prompt "$(ref_spec)" go --events
STUB="{\"rawWrites\":[$(line "$RESULT")],\"result\":{\"text\":\"second\",\"costUsd\":0.75}}"; sc "prompt-two-results" rust 0 '"costUsd": 0.75' -- session prompt "$(ref_spec)" go
STUB="{\"rawWrites\":[$(line '{"type":"result","is_error":true,"result":"first"}')],\"result\":{\"text\":\"second\"}}"; sc "prompt-two-results-an-error-first" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
STUB="{\"rawWrites\":[$(line "$RESULT"),$(line '{"type":"result","is_error":true,"result":"second"}')]}"; sc "prompt-two-results-an-error-last" rust 1 '"sawResult": true' -- session prompt "$(ref_spec)" go
STUB="{\"rawWrites\":[$(piece "$RESULT")]}"; sc "prompt-no-final-newline" rust 0 '"costUsd":0.5' -- session prompt "$(ref_spec)" go --events
STUB="{\"rawWrites\":[$(piece "$(text_event 'cut')")],\"exitCode\":1}"; sc "prompt-no-final-newline-with-no-result" rust 1 '"sawText":true' -- session prompt "$(ref_spec)" go --events
STUB="{\"rawWrites\":[$(line '{"type":"result","is_error":false,"result":"r","session_id":"s","total_cost_usd":1e21,"num_turns":12345678901234567890,"duration_ms":-0}')]}"; sc "prompt-numbers" rust 0 '"total_cost_usd":1e+21' -- session prompt "$(ref_spec)" go --events
STUB="{\"rawWrites\":[$(piece "$(printf 'x%.0s' $(seq 1 60))" stderr)],\"exitCode\":1}"; sc "prompt-detail-under-the-cut" rust 1 'xxx' -- session prompt "$(ref_spec)" go
LETTERS=$(printf 'a%.0s' $(seq 1 299))
STUB="{\"rawWrites\":[$(piece "${LETTERS}😀" stderr)],\"exitCode\":1}"; sc "prompt-detail-cut" rust 1 '\ud83d' -- session prompt "$(ref_spec)" go
STUB="{\"stderr\":\"$(printf 'b%.0s' $(seq 1 400))\",\"result\":{\"isError\":true,\"text\":\"$(printf 'c%.0s' $(seq 1 400))\"}}"; sc "prompt-detail-cut-from-the-result" rust 1 'ccc' -- session prompt "$(ref_spec)" go
STUB_SH='i=0; line=$(printf "{\"type\":\"pad\",\"pad\":\"%02000d\"}" 7); while [ $i -lt 2000 ]; do printf "%s\n" "$line"; i=$((i+1)); done; printf "{\"type\":\"result\",\"is_error\":false,\"result\":\"after 4 MB\"}\n"'; sc "prompt-large-output" rust 0 '"costUsd": null' -- session prompt "$(ref_spec)" go
STUB_SH='printf "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"%0300000d\"}]}}\n" 7; printf "{\"type\":\"result\",\"is_error\":false,\"result\":\"r\"}\n"'; sc "prompt-long-line" rust 0 '{"kind":"ok"' -- session prompt "$(ref_spec)" go --events
STUB_SH='i=0; while [ $i -lt 20000 ]; do printf "0123456789012345678901234567890123456789" >&2; i=$((i+1)); done; exit 1'; sc "prompt-large-stderr" rust 1 '"code": 1' -- session prompt "$(ref_spec)" go

# Every signal node has a name for, by its number on this platform: a default action that does not end the stub leaves it to `exit 5`. A signal that stops a process is left out.
t "prompt: a child that a signal ended"
for entry in $("$NODE" -p 'Object.entries(os.constants.signals).filter(([n]) => !["SIGSTOP","SIGTSTP","SIGTTIN","SIGTTOU"].includes(n)).map(([n, v]) => `${n}:${v}`).join(" ")'); do
  STUB_SH="ulimit -c 0; kill -${entry#*:} \$\$; sleep 1; exit 5"; sc "prompt-exit-signal-${entry%:*}" rust 1 '"kind": "exited"' -- session prompt "$(ref_spec)" go
done
if [ "$(uname)" = Darwin ]; then NAMELESS=7; else NAMELESS=34; fi
STUB_SH="ulimit -c 0; kill -$NAMELESS \$\$; sleep 1; exit 5"; sc "prompt-exit-signal-with-no-name" rust 1 '"code": 0' -- session prompt "$(ref_spec)" go

t "prompt: a caller that left SIGCHLD ignored"
# Under a caller that left SIGCHLD ignored Linux reaps the child itself, and waiting for it finds nothing unless the CLI gives the signal a handler. macOS keeps the disposition through exec but still lets a parent wait, so there these scenarios have nothing to catch. The caller is perl, which is not a program to probe this with: at its own start it forces an inherited ignored SIGCHLD back to the default.
IGNORING_SIGCHLD=(perl -e '$SIG{CHLD}="IGNORE"; exec @ARGV')
UNDER=("${IGNORING_SIGCHLD[@]}"); STUB=$ANSWER; sc "prompt-sigchld-ignored" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
UNDER=("${IGNORING_SIGCHLD[@]}"); STUB_SH='exit 3'; sc "prompt-sigchld-ignored-exit-code" rust 1 '"code": 3' -- session prompt "$(ref_spec)" go
UNDER=("${IGNORING_SIGCHLD[@]}"); SETUP='mkdir tmp/p && ln -s claude tmp/p/claude'; EXTRA=("PATH=$RUN/tmp/p:$BIN:/usr/bin:/bin"); sc "prompt-sigchld-ignored-handed-over" node 1 'spawn ELOOP' -- session prompt "$(ref_spec)" go
# A handler interrupts what blocks: SIGCHLD again and again through a turn, and no line may be lost to it.
STUB_SH="i=0; while [ \"\$i\" -lt 200 ]; do kill -s CHLD \"\$PPID\"; printf '%s\n' '$(text_event word)'; i=\$((i + 1)); done; printf '%s\n' '$RESULT'"; sc "prompt-sigchld-again-and-again" rust 0 '{"kind":"ok"' -- session prompt "$(ref_spec)" go --events

t "prompt: the time limit"
STUB_SH='exec sleep 30'; sc "prompt-timeout" rust 4 '"limitMs": 400' -- session prompt "$(ref_spec)" go --timeout 400
STUB_SH='exec sleep 30'; sc "prompt-timeout-events" rust 4 '{"kind":"timeout","sessionId":null,"toolUses":0,"limitMs":400,"detail":"","sawText":false,"sawResult":false}' -- session prompt "$(ref_spec)" go --timeout 400 --events
STUB='{"sessionId":"s-8","tools":["Bash"],"text":"partial","stderr":"on stderr\n","hang":true}'; sc "prompt-timeout-with-evidence" rust 4 '"sawText": true' -- session prompt "$(ref_spec)" go --timeout 3000
for limit in 1e3 1000.5 .5e3 +1e3 0x400 0b1111101000 ' 1e3 '; do
  STUB_SH='exec sleep 30'; sc "prompt-limit-is-read-as-a-number-$limit" rust 4 '"kind": "timeout"' -- session prompt "$(ref_spec)" go --timeout "$limit"
done
# A kill this early lands before or after the first line of the stub, and on Linux node's comes later than the binary's (its timer is armed after the spawn, and never under 1 ms). What the two print is what is compared.
STUB_SH='exec sleep 30'; STARTS=-; KILL_RACES_STUB=1; sc "prompt-limit-under-a-millisecond" rust 4 '"limitMs": 0.5' -- session prompt "$(ref_spec)" go --timeout 0.5
for limit in abc 0 -1 1_000 Infinity 1e400 ''; do
  STUB=$ANSWER; sc "prompt-limit-falls-back-$limit" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go --timeout="$limit"
done
STUB=$ANSWER; sc "prompt-limit-too-large-for-a-clock" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go --timeout 1e300
STUB_SH='printf "{\"type\":\"result\",\"is_error\":false,\"result\":\"r\"}\n"; sleep 3; exit 0'; sc "prompt-a-result-stops-the-limit" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go --timeout 1500
# A child gets 60 seconds to leave after its result, so one that stays for 8 is no kill. The kill at 60 itself is `a_child_that_stays_60_seconds_after_its_result_is_killed_and_the_turn_succeeded` of `session::turn`: a scenario would hold the suite for two minutes.
STUB_SH='printf "{\"type\":\"result\",\"is_error\":false,\"result\":\"r\"}\n"; sleep 8; exit 0'; sc "prompt-a-slow-child-is-not-killed-by-the-grace" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
STUB_SH='printf "{\"type\":\"system\",\"session_id\":\"s-7\"}\n"; ( sleep 8 ) & exit 0'; sc "prompt-limit-through-the-drain" rust 4 '"sessionId": "s-7"' -- session prompt "$(ref_spec)" go --timeout 1000

# ---------------------------------------------------- prompt: what cannot be started ---
t "prompt: a child that cannot be started"
EXTRA=("PATH=/usr/bin:/bin"); sc "prompt-no-claude" rust 1 'spawn claude ENOENT' -- session prompt "$(ref_spec)" go
sc "prompt-missing-cwd" rust 1 'spawn claude ENOENT' -- session prompt "$(ref_cwd "$RUN/nope")" go
sc "prompt-cwd-is-file" rust 1 'spawn ENOTDIR' -- session prompt "$(ref_cwd "$RUN/tr/plain.jsonl")" go
SETUP='mkdir tmp/locked && chmod 000 tmp/locked'; sc_user "prompt-cwd-with-no-access" rust 1 'spawn claude EACCES' -- session prompt "$(ref_cwd "$RUN/tmp/locked")" go
SETUP='mkdir -p tmp/p/claude'; EXTRA=("PATH=$RUN/tmp/p:$BIN:/usr/bin:/bin"); STUB=$ANSWER; sc "prompt-claude-dir-first" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
SETUP='mkdir -p tmp/p/claude'; EXTRA=("PATH=$RUN/tmp/p:/usr/bin:/bin"); sc "prompt-claude-only-a-dir" rust 1 'spawn claude EACCES' -- session prompt "$(ref_spec)" go
SETUP='mkdir tmp/p && printf x > tmp/p/claude'; EXTRA=("PATH=$RUN/tmp/p:$BIN:/usr/bin:/bin"); STUB=$ANSWER; sc "prompt-claude-not-executable-first" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
SETUP='mkdir tmp/p && printf x > tmp/p/claude'; EXTRA=("PATH=$RUN/tmp/p:/usr/bin:/bin"); sc "prompt-claude-only-not-executable" rust 1 'spawn claude EACCES' -- session prompt "$(ref_spec)" go
sc "prompt-bin-dir" rust 1 "spawn $RUN/work EACCES" -- session prompt "$(ref_spec ",\"bin\":\"$RUN/work\"")" go
sc "prompt-bin-missing" rust 1 "spawn $RUN/nope ENOENT" -- session prompt "$(ref_spec ",\"bin\":\"$RUN/nope\"")" go
EXTRA=("PATH=/usr/bin:/bin"); STUB=$ANSWER; sc "prompt-bin-absolute" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec ",\"bin\":\"$BIN/claude\"")" go
SETUP='mkdir tmp/p && cp "$BIN/claude" tmp/p/claude2'; EXTRA=("PATH=$RUN/tmp/p:/usr/bin:/bin"); STUB=$ANSWER; sc "prompt-bin-bare" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec ',"bin":"claude2"')" go
sc "prompt-bin-bare-missing" rust 1 'spawn nope ENOENT' -- session prompt "$(ref_spec ',"bin":"nope"')" go
# A relative `bin` with a slash is the reader's to hand over on every platform (`reference.rs`), before any of this.
SETUP='cp "$BIN/claude" work/c'; STUB=$ANSWER; STARTS=-; sc "prompt-bin-relative" node - - -- session prompt "$(ref_spec ',"bin":"./c"')" go
SETUP='cp "$BIN/claude" work/claude'; EXTRA=("PATH=.:/usr/bin:/bin"); STUB=$ANSWER; STARTS=-; sc "prompt-path-with-a-relative-entry" "$ONLY_NODE_HERE" - - -- session prompt "$(ref_spec)" go
SETUP='cp "$BIN/claude" work/claude'; STUB=$ANSWER; STARTS=-; sc "prompt-path-of-the-spec-empty" "$ONLY_NODE_HERE" - - -- session prompt "$(ref_spec ',"env":{"PATH":""}')" go
# A text file with the mode of a program.
SETUP='mkdir tmp/p && printf "echo not-a-script\n" > tmp/p/claude && chmod +x tmp/p/claude'; EXTRA=("PATH=$RUN/tmp/p:$BIN:/usr/bin:/bin"); STARTS=-; sc "prompt-no-shebang" "$NO_SHEBANG" - - -- session prompt "$(ref_spec)" go
SETUP='mkdir tmp/p && : > tmp/p/claude && chmod +x tmp/p/claude'; EXTRA=("PATH=$RUN/tmp/p:$BIN:/usr/bin:/bin"); STARTS=-; sc "prompt-empty-program" "$NO_SHEBANG" - - -- session prompt "$(ref_spec)" go
SETUP='mkdir tmp/p && printf "#!\n" > tmp/p/claude && chmod +x tmp/p/claude'; EXTRA=("PATH=$RUN/tmp/p:$BIN:/usr/bin:/bin"); STARTS=-; sc "prompt-interpreter-line-empty" "$NO_SHEBANG" - - -- session prompt "$(ref_spec)" go
SETUP='mkdir tmp/p && printf "#!/bin/sh\necho from-the-script\n" > tmp/p/wrap && printf "#!%s\n" "$RUN/tmp/p/wrap" > tmp/p/claude && chmod +x tmp/p/wrap tmp/p/claude'; EXTRA=("PATH=$RUN/tmp/p:$BIN:/usr/bin:/bin"); STARTS=-; sc "prompt-interpreter-is-a-script" "$NO_SHEBANG" - - -- session prompt "$(ref_spec)" go
SETUP='mkdir tmp/p && printf "#!./nope\n" > tmp/p/claude && chmod +x tmp/p/claude'; EXTRA=("PATH=$RUN/tmp/p:$BIN:/usr/bin:/bin"); STUB=$ANSWER; STARTS=-; sc "prompt-interpreter-relative" "$ONLY_NODE_HERE" - - -- session prompt "$(ref_spec)" go
SETUP='mkdir tmp/p && printf "#!/no/such/program\n" > tmp/p/claude && chmod +x tmp/p/claude'; EXTRA=("PATH=$RUN/tmp/p:/usr/bin:/bin"); sc "prompt-interpreter-missing" rust 1 'spawn claude ENOENT' -- session prompt "$(ref_spec)" go
SETUP='mkdir tmp/p && printf "#!/no/such/program\n" > tmp/p/claude && chmod +x tmp/p/claude'; EXTRA=("PATH=$RUN/tmp/p:$BIN:/usr/bin:/bin"); STUB=$ANSWER; sc "prompt-interpreter-missing-first" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
SETUP='mkdir tmp/p && printf x > tmp/f && printf "#!%s\n" "$RUN/tmp/f/program" > tmp/p/claude && chmod +x tmp/p/claude'; EXTRA=("PATH=/no/such:$RUN/tmp/p"); sc "prompt-interpreter-under-a-file" rust 1 'spawn ENOTDIR' -- session prompt "$(ref_spec)" go
SETUP='mkdir tmp/p && ln -s claude tmp/p/claude'; EXTRA=("PATH=$RUN/tmp/p:$BIN:/usr/bin:/bin"); sc "prompt-symlink-loop-first" node 1 'spawn ELOOP' -- session prompt "$(ref_spec)" go
SETUP='printf x > tmp/f'; EXTRA=("PATH=/usr/bin:/bin:$RUN/tmp/f"); sc "prompt-path-ends-with-a-file" rust 1 'spawn ENOTDIR' -- session prompt "$(ref_spec)" go
SETUP='printf x > tmp/f'; EXTRA=("PATH=$RUN/tmp/f:/usr/bin:/bin"); sc "prompt-path-starts-with-a-file" rust 1 'spawn claude ENOENT' -- session prompt "$(ref_spec)" go
LOCALE=ru; sc "prompt-spawn-failed-in-russian" rust 1 'spawn claude ENOENT' -- session prompt "$(ref_cwd "$RUN/nope")" go

t "prompt: a call that starts nothing"
sc "prompt-no-session" rust 1 'no session matches nobody' -- session prompt nobody go
LOCALE=ru; sc "prompt-no-session-ru" rust 1 'сессия не найдена: nobody' -- session prompt nobody go
sc "prompt-empty-text" rust 2 'nothing to say: the prompt text is empty' -- session prompt "$(ref_spec)" ""
sc "prompt-blank-text" rust 2 'nothing to say: the prompt text is empty' -- session prompt "$(ref_spec)" $' \n\t '
LOCALE=ru; sc "prompt-empty-text-ru" rust 2 'нечего сказать: пустой текст запроса' -- session prompt "$(ref_spec)" ""
sc "prompt-missing-args" rust 2 'missing required option <ref> <text>' -- session prompt
sc "prompt-missing-text" rust 2 'missing required option <ref> <text>' -- session prompt "$(ref_spec)"
sc "prompt-empty-reference" rust 2 'missing required option <ref> <text>' -- session prompt "" go
LOCALE=ru; sc "prompt-missing-args-ru" rust 2 'не хватает обязательного параметра <ref> <text>' -- session prompt
sc "prompt-the-text-is-checked-before-the-reference" rust 2 'nothing to say: the prompt text is empty' -- session prompt nobody ""
sc "prompt-ref-not-json" rust 1 'no session matches {bad' -- session prompt '{bad' go
sc "prompt-ref-bad-schema" rust 1 'no session matches {"id":1}' -- session prompt '{"id":1}' go

if [ -z "$SELF_TEST" ] && { [ -z "$ONLY" ] || [[ prompt-no-node == *"$ONLY"* ]]; }; then
  # No node at all: the call has to go to node, so the front door says it cannot, with its own words, and the stub is not started. Node has no part to compare with.
  t "prompt: no node on the machine"
  rm -rf "$RUN"; cp -RPp "$TEMPLATE" "$RUN"
  no_node_err=$(cd "$RUN" && env -i "PATH=$RUN/tmp" "HOME=$RUN/home" "TMPDIR=$RUN/tmp" "TA_STATE_DIR=$RUN/st" TA_KEEP_AWAKE=0 "$RUST" session prompt "$(ref_spec ",\"bin\":\"$BIN/claude\"")" go 2>&1 < /dev/null); no_node_code=$?
  if [ "$no_node_code" != 127 ] || [[ $no_node_err != "tagents-core: cannot run node"* ]] || [ -n "$(ls -A "$RUN/rec")" ]; then
    bad "prompt-no-node: no node should give the front door's own error, exit 127, and start nothing" "exit $no_node_code" "$no_node_err" "rec: $(ls -A "$RUN/rec" | tr '\n' ' ')"
  else ok; fi
  no_node_err=$(cd "$RUN" && env -i "PATH=$RUN/tmp" "HOME=$RUN/home" "TMPDIR=$RUN/tmp" "TA_STATE_DIR=$RUN/st" "TAGENTS_NODE=$RUN/tmp/no-such-node" TA_KEEP_AWAKE=0 "$RUST" session prompt "$(ref_spec ",\"bin\":\"$BIN/claude\"")" go 2>&1 < /dev/null); no_node_code=$?
  if [ "$no_node_code" != 127 ] || [[ $no_node_err != "tagents-core: cannot run $RUN/tmp/no-such-node"* ]] || [ -n "$(ls -A "$RUN/rec")" ]; then
    bad "prompt-no-node-pinned: a pinned node that is not there should give the front door's own error, exit 127, and start nothing" "exit $no_node_code" "$no_node_err" "rec: $(ls -A "$RUN/rec" | tr '\n' ' ')"
  else ok; fi
fi

# ------------------------------------------------------------- prompt: over time ---
t "prompt: what happens when, on both programs (these take seconds of real time)"
# Each check takes the time before the run from a clock with a resolution of a second, rounded down, so a lower bound cannot fail for a slow start, and leaves the upper bounds to the comparison of the two programs.
elapsed() { echo $(( $(stamped "$1" "$2") - $(cat "$TMP/t0.$1") * 1000 )); }
late() {  # <label> <detail...>
  bad "$@" "load when this was seen: $(uptime)"
}

MODE=stamp; STUB='{"tools":["Bash"],"sleepMs":1500,"result":{}}'; sc "prompt-event-as-it-is-read" rust 0 '{"kind":"tool_use"' -- session prompt "$(ref_spec)" go --events
if [ -n "$RAN" ]; then for side_name in node rust; do
  gap=$(( $(stamped "$side_name" '"kind":"result"') - $(stamped "$side_name" '"kind":"tool_use"') ))
  [ "$gap" -ge 700 ] && ok || late "prompt-event-as-it-is-read: on $side_name the tool call came only $gap ms before the result, the stub waits 1500 ms between them"
done; fi

MODE=stamp; STUB='{"result":{},"grandchildMs":14000}'; sc "prompt-grandchild-holds-pipe" rust 0 '"kind": "ok"' -- session prompt "$(ref_spec)" go
if [ -n "$RAN" ]; then for side_name in node rust; do
  outcome=$(elapsed "$side_name" '"kind": "ok"'); ended=$(elapsed "$side_name" end)
  [ "$outcome" -ge 4000 ] && ok || late "prompt-grandchild-holds-pipe: on $side_name the outcome came $outcome ms after the start, the turn waits 5 s for the pipes"
  [ "$ended" -ge 14000 ] && ok || late "prompt-grandchild-holds-pipe: on $side_name the process ended $ended ms after the start, the grandchild holds the pipe for 14 s"
  [ $(( ended - outcome )) -ge 4000 ] && ok || late "prompt-grandchild-holds-pipe: on $side_name the outcome came only $(( ended - outcome )) ms before the end"
done
  apart=$(( $(elapsed node end) - $(elapsed rust end) )); [ "$apart" -lt 0 ] && apart=$(( - apart ))
  [ "$apart" -le 4000 ] && ok || late "prompt-grandchild-holds-pipe: the two programs ended $apart ms apart"
fi

# A grandchild that still writes after the outcome: a whole line is an event, and the last one with no newline never is.
MODE=stamp; STUB_SH='( sleep 7; printf "{\"type\":\"late\"}\n{\"type\":\"cut\"}" ) & printf "{\"type\":\"result\",\"is_error\":false,\"result\":\"r\"}\n"; exit 0'; sc "prompt-events-after-the-outcome" rust 0 '{"kind":"other","type":"late"}' -- session prompt "$(ref_spec)" go --events
if [ -n "$RAN" ]; then for side_name in node rust; do
  gap=$(( $(stamped "$side_name" '"type":"late"') - $(stamped "$side_name" '{"kind":"ok"') ))
  [ "$gap" -ge 1000 ] && ok || late "prompt-events-after-the-outcome: on $side_name the late line came $gap ms after the outcome, it is written 2 s after it"
done; fi

# The signals a background job can receive: this shell starts it with SIGINT and SIGQUIT ignored.
for name in TERM HUP; do
  MODE=signal; SIGNAL=$name; STUB='{"hang":true}'; STARTS=-; sc "prompt-signal-to-cli-$name" rust - - -- session prompt "$(ref_spec)" go
  if [ -n "$RAN" ]; then for side_name in node rust; do
    [ "$(cat "$TMP/stub.$side_name")" = alive ] && ok || bad "prompt-signal-to-cli-$name: on $side_name the child did not outlive the CLI: $(cat "$TMP/stub.$side_name")"
  done
    if [ "$name" = TERM ]; then want=143; else want=129; fi
    [ "$(cat "$TMP/code.node")" = "$want" ] && ok || bad "tripwire prompt-signal-to-cli-$name: node ended with $(cat "$TMP/code.node")"
  fi
done

# One pipe for both streams: the outcome comes before the error line, as it does in node.
MODE=merged; STUB='{"exitCode":3,"stderr":"boom\n"}'; sc "prompt-both-streams-in-one-pipe" rust 1 'exit=3 boom' -- session prompt "$(ref_spec)" go
MODE=merged; STUB='{"tools":["Bash"],"exitCode":3,"stderr":"boom\n"}'; sc "prompt-both-streams-in-one-pipe-with-events" rust 1 'exit=3 boom' -- session prompt "$(ref_spec)" go --events

# Nobody reads stdout: the limit still fires, and the error line still comes, while the events wait for a reader. The poll is bounded well above the limit of 2 s and costs its time only when this fails.
MODE=stall; STUB_SH='i=0; line=$(printf "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"%02000d\"}]}}" 7); while [ $i -lt 400 ]; do printf "%s\n" "$line"; i=$((i+1)); done; exec sleep 40'; sc "prompt-stdout-not-read" rust 4 '"kind":"timeout"' -- session prompt "$(ref_spec)" go --events --timeout 2000
if [ -n "$RAN" ]; then for side_name in node rust; do
  [ "$(cat "$TMP/stub.$side_name")" = "gone with its line on stderr" ] && ok || late "prompt-stdout-not-read: on $side_name, with nobody reading stdout: $(cat "$TMP/stub.$side_name")"
done; fi

# ------------------------------------------------------- a reader that went away ---
t "a reader that went away: the exit code and the other stream stay"
CLOSED=stdout; sc "closed-stdout-open" rust 0 - -- session open --cwd "$RUN/work"
CLOSED=stdout; SETUP=$STATES; sc "closed-stdout-list" rust 0 - -- session list
CLOSED=stdout; sc "closed-stdout-last" rust 0 - -- session last "$(ref_transcript plain.jsonl)"
CLOSED=stderr; sc "closed-stderr-open" rust 2 - -- session open
CLOSED=stderr; sc "closed-stderr-list" rust 2 - -- session list --state a,b
CLOSED=stderr; sc "closed-stderr-last" rust 1 - -- session last nobody
CLOSED=stdout; STUB=$ANSWER; sc "closed-stdout-prompt" rust 0 - -- session prompt "$(ref_spec)" go
CLOSED=stdout; STUB='{"tools":["Bash"],"text":"hi","result":{}}'; sc "closed-stdout-prompt-events" rust 0 - -- session prompt "$(ref_spec)" go --events
CLOSED=stdout; STUB='{"exitCode":3,"stderr":"boom\n"}'; sc "closed-stdout-prompt-failed" rust 1 'boom' -- session prompt "$(ref_spec)" go
CLOSED=stderr; STUB='{"exitCode":3,"stderr":"boom\n"}'; sc "closed-stderr-prompt-failed" rust 1 'boom' -- session prompt "$(ref_spec)" go
CLOSED=stderr; sc "closed-stderr-prompt-usage" rust 2 - -- session prompt
CLOSED=stderr; sc "closed-stderr-prompt-enotdir" rust 1 - -- session prompt "$(ref_cwd "$RUN/tr/plain.jsonl")" go

printf '\nrust-session-parity: %d passed, %d failed, %d skipped' "$pass" "$fail" "$skipped"
if [ -z "$SELF_TEST" ]; then
  printf '; answered by the binary: %d, handed to node: %d\n' "$rust_served" "$handed_over"
else
  printf ' (self test: node on both sides)\n'
fi
[ "$fail" -eq 0 ]
