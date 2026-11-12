#!/usr/bin/env bash
#
# tests/knowledge-launcher.sh — bin/knowledge-mcp, the entry the plugin registers for the knowledge server: which program replaces it, and what reaches stderr.
#
# Part one runs the launcher with a stub `tagents-knowledge` (and a stub `nc`) on a PATH of its own in a scratch directory, whose `join` exits with the code a case sets, and checks which program the launcher became and what it wrote to stderr. Part two installs the real wrapper with install.sh into a scratch HOME, TAGENTS_HOME and TAGENTS_BIN around the real binary (target/debug/tagents-core, or $TAGENTS_CORE_BIN) and the real node server, and looks at the processes a session starts. Every server, daemon and join runs under a scratch HOME, TMPDIR and knowledge folder: nothing of the person's is touched, and no real Claude Code is started.
#
# bash 3.2, runnable from any cwd, non-zero exit when any check fails.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
LAUNCHER=${TAGENTS_LAUNCHER:-$ROOT/bin/knowledge-mcp}
TMP=$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/tagents-launcher.XXXXXX")" && pwd -P) || exit 1
# The daemons of this run keep their sockets in a directory of their own under the system temp directory (/tmp/tagents-<uid>), not under TMPDIR, so the scratch directory does not hold them. What names the run is the environment they were started with (TAGENTS_HOME, the knowledge folder and the databases are under $TMP), and for the Rust daemon its command line too. Only a process whose environment or command holds this run's directory is signalled, and never the suite itself. /proc/<pid>/environ where there is a /proc (Linux), `ps -E` where there is not (macOS).
scratch_pids() {
  if [ -d /proc/self ]; then
    for e in /proc/[0-9]*/environ; do
      pid=${e#/proc/}; pid=${pid%/environ}
      { tr '\0' '\n' < "$e"; tr '\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null | grep -F "$TMP/" > /dev/null && echo "$pid"  # no -q: grep leaving early would SIGPIPE tr and, under pipefail, lose the match
    done
  else
    ps -A -E -ww -o pid=,command= | grep -F "$TMP/" | grep -v grep | awk '{print $1}'
  fi | awk -v me=$$ '$1 != me'
}
# a process that has exited but is not yet reaped (its parent is a shell that never waits, such as pid 1 of a container) is gone for this suite
alive() { st=$(ps -o stat= -p "$1" 2>/dev/null); [ -n "$st" ] && [ "${st#Z}" = "$st" ]; }
stop_scratch_daemons() {
  for p in $(scratch_pids); do kill "$p" 2>/dev/null; done
  sleep 0.3
  for p in $(scratch_pids); do kill -9 "$p" 2>/dev/null; done
  for _ in $(seq 1 20); do [ -z "$(scratch_pids)" ] && break; sleep 0.1; done
}
cleanup() {
  stop_scratch_daemons
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

pass=0; fail=0
ok() {  # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else fail=$((fail + 1)); printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fi
}
t() { printf '\n%s\n' "$1"; }

# ---------------------------------------------------------------------------
t "1. which program replaces the launcher, and what it says"
# ---------------------------------------------------------------------------
# The stubs use shell builtins only, so a PATH that holds nothing but the stubs is enough. `tagents-knowledge` writes its arguments to $STUB_LOG and its stdin to a file named after the call, answers `join` with $JOIN_CODE, and prints a socket for `serve` when $SERVE_SOCKET is set. Each stub prints what it is, on stdout, so the last program the launcher became shows in the launcher's own output. `nc` is a stub too, so the case without one is a PATH that holds none.
STUBS=$TMP/stubs; mkdir -p "$STUBS"
cat > "$STUBS/tagents-knowledge" <<'STUB'
#!/bin/sh
n=0
if [ -f "$STUB_LOG" ]; then while read -r _; do n=$((n + 1)); done < "$STUB_LOG"; fi
echo "$*" >> "$STUB_LOG"
echo "$1=${TAGENTS_NO_NATIVE-unset}" >> "$STUB_DIR/envlog"
input=
while IFS= read -r line || [ -n "$line" ]; do input="$input$line"; done
printf '%s' "$input" > "$STUB_DIR/stdin.$n"
case $1 in
  join) if [ "${JOIN_CODE:-0}" = 0 ]; then printf 'stub: join <%s>\n' "$input"; exit 0; fi
        [ "${JOIN_CODE:-0}" = 127 ] && exit 127
        exit "$JOIN_CODE" ;;
  serve) [ -z "${SERVE_SOCKET-}" ] || printf '%s\n' "$SERVE_SOCKET"; exit "${SERVE_CODE:-0}" ;;
  mcp) printf 'stub: mcp\n' ;;
esac
STUB
cat > "$STUBS/nc" <<'STUB'
#!/bin/sh
printf 'stub: nc %s\n' "$*"
STUB
chmod 755 "$STUBS/tagents-knowledge" "$STUBS/nc"
NO_NC=$TMP/no-nc; mkdir -p "$NO_NC"; cp "$STUBS/tagents-knowledge" "$NO_NC/"
# A real unix socket for `serve` to print: the launcher tests it with -S.
SOCK=$TMP/s.sock
python3 -I - "$SOCK" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(600)
PY
SOCK_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCK" ] && break; sleep 0.1; done
trap 'kill $SOCK_PID 2>/dev/null; cleanup' EXIT INT TERM

# <name> <path dir> <join code> <socket or empty> -> sets OUT, ERR, CALLS
launch() {
  : > "$TMP/calls"; : > "$TMP/envlog"; rm -f "$TMP"/stdin.*
  OUT=$(printf 'hello' | env -i PATH="$2" STUB_LOG="$TMP/calls" STUB_DIR="$TMP" JOIN_CODE="$3" SERVE_SOCKET="$4" /bin/sh "$LAUNCHER" 2> "$TMP/err"); RC=$?
  ERR=$(cat "$TMP/err"); CALLS=$(tr '\n' '|' < "$TMP/calls")
}

launch exit0 "$STUBS" 0 "$SOCK"
ok "join exits 0: the launcher becomes join, with the session's input" "stub: join <hello>" "$OUT"
ok "...the probe was handed nothing" "" "$(cat "$TMP/stdin.0")"
ok "...and the calls are the probe and the real join, no serve" "join|join|" "$CALLS"
ok "...nothing on stderr" "" "$ERR"

for code in 69 2; do
  launch "exit$code" "$STUBS" "$code" "$SOCK"
  ok "join exits $code, a socket printed, nc present: nc -U on the socket" "stub: nc -U $SOCK" "$OUT"
  ok "...nothing on stderr" "" "$ERR"
  ok "...the calls are the probe and serve" "join|serve|" "$CALLS"
  ok "...and TAGENTS_NO_NATIVE is not set: this is not a failure" "join=unset|serve=unset|" "$(tr '\n' '|' < "$TMP/envlog")"
  launch "exit$code-nonc" "$NO_NC" "$code" "$SOCK"
  ok "join exits $code, no nc: the node server" "stub: mcp" "$OUT"
  ok "...nothing on stderr" "" "$ERR"
  launch "exit$code-nosock" "$STUBS" "$code" ""
  ok "join exits $code, serve prints nothing: the node server" "stub: mcp" "$OUT"
  ok "...nothing on stderr" "" "$ERR"
  launch "exit$code-notasock" "$STUBS" "$code" "$TMP/calls"
  ok "join exits $code, serve prints a file that is not a socket: the node server" "stub: mcp" "$OUT"
  ok "...nothing on stderr" "" "$ERR"
done

for code in 1 3 127 126 130; do
  launch "exit$code" "$STUBS" "$code" "$SOCK"
  ok "join exits $code: the old arrangement runs" "stub: nc -U $SOCK" "$OUT"
  ok "...with exactly one line on stderr, naming the code" "knowledge-mcp: tagents-knowledge join exited $code, using a server of its own (tagents-knowledge join </dev/null shows why)" "$ERR"
  ok "...and the launcher sets no TAGENTS_NO_NATIVE: serve goes to the binary, a server that needs no daemon" "join=unset|serve=unset|" "$(tr '\n' '|' < "$TMP/envlog")"
  launch "exit$code-nosock" "$STUBS" "$code" ""
  ok "join exits $code, no socket: the node server, with the same one line" "stub: mcp|knowledge-mcp: tagents-knowledge join exited $code, using a server of its own (tagents-knowledge join </dev/null shows why)" "$OUT|$ERR"
  ok "...and mcp sees no TAGENTS_NO_NATIVE either" "join=unset|serve=unset|mcp=unset|" "$(tr '\n' '|' < "$TMP/envlog")"
done

# No tagents-knowledge at all: the shell's 127 is a code like any other.
OUT=$(env -i PATH="$NO_NC/none" /bin/sh "$LAUNCHER" 2> "$TMP/err" </dev/null); RC=$?
ok "no tagents-knowledge on PATH: the first line of stderr names 127" "knowledge-mcp: tagents-knowledge join exited 127, using a server of its own (tagents-knowledge join </dev/null shows why)" "$(head -n 1 "$TMP/err")"

# ---------------------------------------------------------------------------
t "2. over a scratch install: the program a session starts"
# ---------------------------------------------------------------------------
OKB=${OKB_BIN:-$ROOT/target/debug/okb}
REAL_NODE=$(command -v node || true)
if [ ! -x "$OKB" ] || [ -z "$REAL_NODE" ]; then
  # Part two is the part that runs the real binary: in CI a machine that cannot run it is a failure, not a skip that reads as a pass.
  if [ -n "${CI:-}" ]; then
    fail=$((fail + 1)); printf '  FAIL part two cannot run: no built okb (%s) or no node, and CI is set\n' "$OKB"
  else
    printf '  skip no built okb (%s) or no node\n' "$OKB"
  fi
else
  # A node that writes down every start and then is the real one: a probe or a join that starts node shows in the log.
  mkdir -p "$TMP/rec"
  printf '#!/bin/sh\necho "$*" >> "%s/node-starts"\nexec "%s" "$@"\n' "$TMP" "$REAL_NODE" > "$TMP/rec/node"; chmod 755 "$TMP/rec/node"
  starts() { if [ -f "$TMP/node-starts" ]; then wc -l < "$TMP/node-starts" | tr -d ' '; else echo 0; fi; }

  ORIGIN=$TMP/origin
  mkdir -p "$ORIGIN"
  (
    cd "$ORIGIN" || exit 1
    git init -q -b main . && git config user.email t@example.com && git config user.name t
    mkdir -p hooks packages/core/dist/cli packages/notify/dist
    for f in tagents tusage tnotes; do printf '#!/bin/sh\nexit 0\n' > "$f"; chmod +x "$f"; done
    cp "$ROOT/hooks/claude-settings.json" hooks/claude-settings.json
    printf '#!/usr/bin/env node\n' > packages/core/dist/cli/main.js
    printf '#!/usr/bin/env node\n' > packages/notify/dist/main.js
    cp "$ROOT/Cargo.toml" Cargo.toml
    cp "$ROOT/install.sh" install.sh
    git add -A && git commit -q -m v1
  )
  export HOME=$TMP/home TAGENTS_HOME=$TMP/home/share/tagents TAGENTS_BIN=$TMP/home/bin TAGENTS_REPO=$ORIGIN TAGENTS_BUILD_CMD=true
  export TAGENTS_CORE_BASE_URL=file://$TMP/no-release TAGENTS_NO_NATIVE=1
  mkdir -p "$HOME"
  install() { PATH="$TMP/rec:$PATH" sh "$ROOT/install.sh" --quiet --hooks-dir "$TMP/hooks" 2>&1; }
  out=$(install); rc=$?
  ok "the scratch install exits 0" 0 "$rc"
  cp -R "$ROOT/crates/okb/tests/fixtures/knowledge" "$TMP/docs"
  mkdir -p "$TMP/tmp" "$TMP/cfg"
  SENV=(env -i PATH="$TAGENTS_BIN:/usr/bin:/bin" HOME="$HOME" TMPDIR="$TMP/tmp" TAGENTS_CONFIG_DIR="$TMP/cfg" TAGENTS_KNOWLEDGE_DIR="$TMP/docs" TAGENTS_KNOWLEDGE_DB="$TMP/index.sqlite" TAGENTS_KNOWLEDGE_USAGE_DB="$TMP/usage.sqlite" TAGENTS_LOCALE=en)
  senv() { "${SENV[@]}" "$@"; }
  INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"launcher-test","version":"0"}}}'

  # <label> [more request lines] — starts the launcher as a session does: its stdin is a pipe fed the initialize request and the lines given, which stays open until end_session closes it (or 60 s pass), so the input cannot end before the replies are read; SPID is the launcher's pid. It returns when every request has its reply.
  session() {
    lab=$1; shift
    want=$(( $# + 1 ))
    { printf '%s\n' "$INIT"; for l in "$@"; do printf '%s\n' "$l"; done; for _ in $(seq 1 600); do [ -e "$TMP/close.$lab" ] && break; sleep 0.1; done; } | "${SENV[@]}" /bin/sh "${SESSION_LAUNCHER:-$LAUNCHER}" > "$TMP/out.$lab" 2> "$TMP/err.$lab" &
    SPID=$!
    for _ in $(seq 1 100); do [ "$(grep -c '"result"' "$TMP/out.$lab" 2>/dev/null)" -ge "$want" ] && break; sleep 0.1; done
  }
  # Does this nc end when its input closes? Asked of nc itself, not of the system's name: a closed input against a listening unix socket either ends it within a bound or does not. netcat-openbsd of Debian does not without -N; the nc of macOS does.
  NC_ENDS=unknown
  if command -v nc >/dev/null 2>&1; then
    nc -lU "$TMP/ncprobe.sock" >/dev/null 2>&1 &
    lpid=$!
    for _ in $(seq 1 30); do [ -S "$TMP/ncprobe.sock" ] && break; sleep 0.1; done
    ( : | nc -U "$TMP/ncprobe.sock" >/dev/null 2>&1 ) &
    ppid=$!
    for _ in $(seq 1 20); do kill -0 "$ppid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$ppid" 2>/dev/null; then NC_ENDS=no; else NC_ENDS=yes; fi
    kill "$ppid" "$lpid" 2>/dev/null; pkill -P "$ppid" 2>/dev/null; wait "$ppid" "$lpid" 2>/dev/null
    rm -f "$TMP/ncprobe.sock"
  fi
  # the session ends by itself when its input closes: `join` does on every system
  end_session() {  # <label>
    : > "$TMP/close.$1"
    for _ in $(seq 1 100); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$SPID" 2>/dev/null; then echo gone=no; kill "$SPID" 2>/dev/null; else echo gone=yes; fi
    wait "$SPID" 2>/dev/null
  }
  # a session whose last program is nc: where nc ends at end of input it is gone, and where it does not (netcat-openbsd without -N) it is still there until the signal a client sends after closing stdin, SIGTERM, and then gone. Prints what happened, and ncexpect is what NC_ENDS says should happen.
  end_nc_session() {  # <label>
    : > "$TMP/close.$1"
    for i in $(seq 1 100); do kill -0 "$SPID" 2>/dev/null || break; [ "$NC_ENDS" = no ] && [ "$i" -ge 20 ] && break; sleep 0.1; done
    if kill -0 "$SPID" 2>/dev/null; then
      printf 'there'; kill -TERM "$SPID" 2>/dev/null
      for _ in $(seq 1 50); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.1; done
      if kill -0 "$SPID" 2>/dev/null; then printf ',survived-TERM'; kill -9 "$SPID" 2>/dev/null; else printf ',gone-after-TERM'; fi
    else printf 'gone'; fi
    wait "$SPID" 2>/dev/null
  }
  ncexpect() { if [ "$NC_ENDS" = no ]; then echo "there,gone-after-TERM"; else echo gone; fi; }

  # --- no binary ------------------------------------------------------------
  senv "$TAGENTS_BIN/tagents-knowledge" join </dev/null >/dev/null 2>&1; rc=$?
  ok "no binary: the probe is answered with 69" 69 "$rc"
  ok "...and starts no node" 0 "$(starts)"
  # There is no program behind the wrapper: the launcher goes on from the failed probe to `serve` and `mcp`, which answer the needs-binary line and exit 69.
  senv /bin/sh "$LAUNCHER" </dev/null >"$TMP/out.nobin" 2>"$TMP/err.nobin"; rc=$?
  ok "no binary: the launcher ends with 69" 69 "$rc"
  ok "...with nothing on stdout" "" "$(cat "$TMP/out.nobin")"
  ok "...and the needs-binary line on stderr, naming tagents update and the cargo build" yes "$(grep -q 'tagents update.*cargo build --release -p okb' "$TMP/err.nobin" && echo yes || echo no)"
  ok "...and no node was started" 0 "$(starts)"

  # --- the binary -------------------------------------------------------------
  mkdir -p "$TAGENTS_HOME/target/release"; cp "$OKB" "$TAGENTS_HOME/target/release/okb"; chmod 755 "$TAGENTS_HOME/target/release/okb"
  unset TAGENTS_NO_NATIVE
  out=$(install); rc=$?
  ok "the install over a binary exits 0" 0 "$rc"
  rm -f "$TMP/node-starts"
  senv "$TAGENTS_BIN/tagents-knowledge" join </dev/null >/dev/null 2>&1; rc=$?
  ok "with the binary: the probe is answered with 0" 0 "$rc"
  session bin
  ok "with the binary: the session got an initialize reply" yes "$(grep -q '"result"' "$TMP/out.bin" && echo yes || echo no)"
  cmd=$(ps -o command= -p "$SPID" 2>/dev/null)
  case $cmd in *"/okb join") got="okb join" ;; *) got="$cmd" ;; esac
  ok "...the process the session started is okb join" "okb join" "$got"
  ok "...no node was started" 0 "$(starts)"
  ok "...no process under it: no node, no nc" "" "$(pgrep -P "$SPID" | tr -d '\n')"
  ok "...nothing on stderr" "" "$(cat "$TMP/err.bin")"
  ok "...and ends when its input closes" gone=yes "$(end_session bin)"
  stop_scratch_daemons
  sleep 0.5

  # --- the launcher of the plugin cache: the old two lines over the new wrapper ----
  # A machine meets this first: the plugin cache keeps the old launcher until the plugin updates, and the wrapper is rewritten at the next `tagents update`. The two commands are those of 9af0ac1:bin/knowledge-mcp, verbatim; `serve` now reaches the Rust daemon and `nc -U` connects to it.
  cat > "$TMP/old-launcher" <<'OLD'
sock=$(tagents-knowledge serve 2>/dev/null) && [ -S "$sock" ] && command -v nc >/dev/null 2>&1 && exec nc -U "$sock"
exec tagents-knowledge mcp
OLD
  SEARCH='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"knowledge_search","arguments":{"query":"sqlite"}}}'
  if ! command -v nc >/dev/null 2>&1; then
    printf '  skip the old launcher over the new wrapper: this machine has no nc\n'
  else
    rm -f "$TMP/node-starts"
    # one daemon serves the environment whichever argument list started it: this one is started with a short idle time, so that it leaving shows the session was counted out
    osock=$(senv "$TAGENTS_BIN/tagents-knowledge" serve --idle 4 2>/dev/null)
    ok "the Rust daemon is up and serve printed its socket" yes "$([ -S "$osock" ] && echo yes || echo no)"
    odpid=$(cat "$osock.pid" 2>/dev/null)
    SESSION_LAUNCHER=$TMP/old-launcher session old "$SEARCH"
    ok "the old launcher: initialize and knowledge_search both got a reply" 2 "$(grep -c '"result"' "$TMP/out.old")"
    ok "...and the search found a document of the fixtures" yes "$(grep -q 'deploy-runbook' "$TMP/out.old" && echo yes || echo no)"
    cmd=$(ps -o command= -p "$SPID" 2>/dev/null)
    case $cmd in "nc -U "*) got=nc ;; *) got="$cmd" ;; esac
    ok "...through nc -U, the process the session started" nc "$got"
    ok "...to the daemon the wrapper started in Rust, and no node was started" 0 "$(starts)"
    ok "...which is alive while the session is connected" yes "$(alive "$odpid" && echo yes || echo no)"
    ok "...nothing on stderr" "" "$(cat "$TMP/err.old")"
    ok "...and the session ends: at end of input where nc does (here: $NC_ENDS), at SIGTERM where it does not" "$(ncexpect)" "$(end_nc_session old)"
    for _ in $(seq 1 120); do alive "$odpid" || break; sleep 0.2; done
    ok "...and the daemon, with nobody connected, leaves after its idle time" no "$(alive "$odpid" && echo yes || echo no)"
    stop_scratch_daemons
  fi

  # --- a binary that fails the probe: the launcher goes on to serve and mcp of the binary ---------
  # The wrapper is the real one and the binary a stub that fails join and serve, and answers mcp.
  want=$(sed -n 's/^version = "\(.*\)"/\1/p' "$ORIGIN/Cargo.toml" | head -n 1)
  printf '#!/bin/sh\nif [ "${1:-}" = --version ]; then echo "okb %s"; exit 0; fi\necho "$*" >> "%s/stub-core-calls"\ncase "${1:-}" in mcp) echo mcp-served ;; *) exit 1 ;; esac\n' "$want" "$TMP" > "$TAGENTS_HOME/target/release/okb"
  chmod 755 "$TAGENTS_HOME/target/release/okb"
  out=$(install); rc=$?
  ok "the install over a stub binary exits 0" 0 "$rc"
  rm -f "$TMP/node-starts" "$TMP/stub-core-calls"
  senv /bin/sh "$LAUNCHER" </dev/null >"$TMP/out.failing" 2>"$TMP/err.failing"; rc=$?
  ok "a binary that fails the probe: the launcher ends in the binary's mcp, exit 0" "0 mcp-served" "$rc $(cat "$TMP/out.failing")"
  ok "...the binary was asked join, serve and mcp, in this order" "join
serve
mcp" "$(cat "$TMP/stub-core-calls")"
  ok "...no node was started" 0 "$(starts)"
  ok "...one line on stderr, naming the code" "knowledge-mcp: tagents-knowledge join exited 1, using a server of its own (tagents-knowledge join </dev/null shows why)" "$(cat "$TMP/err.failing")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
