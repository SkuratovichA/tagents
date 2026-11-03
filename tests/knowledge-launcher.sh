#!/usr/bin/env bash
#
# tests/knowledge-launcher.sh — packages/knowledge/bin/knowledge-mcp, the entry the plugin registers for the knowledge server: which program replaces it, and what reaches stderr.
#
# Part one runs the launcher with a stub `tagents-knowledge` (and a stub `nc`) on a PATH of its own in a scratch directory, whose `join` exits with the code a case sets, and checks which program the launcher became and what it wrote to stderr. Part two installs the real wrapper with install.sh into a scratch HOME, TAGENTS_HOME and TAGENTS_BIN around the real binary (target/debug/tagents-core, or $TAGENTS_CORE_BIN) and the real node server, and looks at the processes a session starts. Every server, daemon and join runs under a scratch HOME, TMPDIR and knowledge folder: nothing of the person's is touched, and no real Claude Code is started.
#
# bash 3.2, runnable from any cwd, non-zero exit when any check fails.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
LAUNCHER=${TAGENTS_LAUNCHER:-$ROOT/packages/knowledge/bin/knowledge-mcp}
TMP=$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/tagents-launcher.XXXXXX")" && pwd -P) || exit 1
# The daemons of this run keep their sockets in a directory of their own under the system temp directory (/tmp/tagents-<uid>), not under TMPDIR, so the scratch directory does not hold them. What names the run is the environment they were started with (TAGENTS_HOME, the knowledge folder and the databases are under $TMP), and for the Rust daemon its command line too. Only a process whose environment or command holds this run's directory is signalled, and never the suite itself. /proc/<pid>/environ where there is a /proc (Linux), `ps -E` where there is not (macOS).
scratch_pids() {
  if [ -d /proc/self ]; then
    for e in /proc/[0-9]*/environ; do
      pid=${e#/proc/}; pid=${pid%/environ}
      { tr '\0' '\n' < "$e"; tr '\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null | grep -qF "$TMP/" && echo "$pid"
    done
  else
    ps -A -E -ww -o pid=,command= | grep -F "$TMP/" | grep -v grep | awk '{print $1}'
  fi | awk -v me=$$ '$1 != me'
}
stop_scratch_daemons() {
  for p in $(scratch_pids); do kill "$p" 2>/dev/null; done
  sleep 0.3
  for p in $(scratch_pids); do kill -9 "$p" 2>/dev/null; done
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
  : > "$TMP/calls"; rm -f "$TMP"/stdin.*
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
  ok "...with exactly one line on stderr, naming the code" "knowledge-mcp: tagents-knowledge join exited $code, using the node server (tagents-knowledge join </dev/null shows why)" "$ERR"
  launch "exit$code-nosock" "$STUBS" "$code" ""
  ok "join exits $code, no socket: the node server, with the same one line" "stub: mcp|knowledge-mcp: tagents-knowledge join exited $code, using the node server (tagents-knowledge join </dev/null shows why)" "$OUT|$ERR"
done

# No tagents-knowledge at all: the shell's 127 is a code like any other.
OUT=$(env -i PATH="$NO_NC/none" /bin/sh "$LAUNCHER" 2> "$TMP/err" </dev/null); RC=$?
ok "no tagents-knowledge on PATH: the first line of stderr names 127" "knowledge-mcp: tagents-knowledge join exited 127, using the node server (tagents-knowledge join </dev/null shows why)" "$(head -n 1 "$TMP/err")"

# ---------------------------------------------------------------------------
t "2. over a scratch install: the program a session starts"
# ---------------------------------------------------------------------------
CORE=${TAGENTS_CORE_BIN:-$ROOT/target/debug/tagents-core}
REAL_NODE=$(command -v node || true)
if [ ! -x "$CORE" ] || [ -z "$REAL_NODE" ]; then
  printf '  skip no built tagents-core (%s) or no node\n' "$CORE"
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
    mkdir -p hooks packages/core/dist/cli packages/notify/dist packages/mcp/dist packages/knowledge
    for f in tagents tusage tnotes; do printf '#!/bin/sh\nexit 0\n' > "$f"; chmod +x "$f"; done
    cp "$ROOT/hooks/claude-settings.json" hooks/claude-settings.json
    printf '#!/usr/bin/env node\n' > packages/core/dist/cli/main.js
    printf '#!/usr/bin/env node\n' > packages/notify/dist/main.js
    printf '#!/usr/bin/env node\n' > packages/mcp/dist/main.js
    # The real node server, reached through the copy: node resolves the link, so its modules are the ones of this tree.
    ln -s "$ROOT/packages/knowledge/dist" packages/knowledge/dist
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
  cp -R "$ROOT/packages/knowledge/test/fixtures/knowledge" "$TMP/docs"
  mkdir -p "$TMP/tmp" "$TMP/cfg"
  SENV=(env -i PATH="$TAGENTS_BIN:/usr/bin:/bin" HOME="$HOME" TMPDIR="$TMP/tmp" TAGENTS_CONFIG_DIR="$TMP/cfg" TAGENTS_KNOWLEDGE_DIR="$TMP/docs" TAGENTS_KNOWLEDGE_DB="$TMP/index.sqlite" TAGENTS_KNOWLEDGE_USAGE_DB="$TMP/usage.sqlite" TAGENTS_LOCALE=en)
  senv() { "${SENV[@]}" "$@"; }
  INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"launcher-test","version":"0"}}}'

  # <label> — starts the launcher as a session does: its stdin is a pipe that stays open for four seconds after the request; SPID is its pid
  session() {
    { printf '%s\n' "$INIT"; sleep 4; } | "${SENV[@]}" /bin/sh "$LAUNCHER" > "$TMP/out.$1" 2> "$TMP/err.$1" &
    SPID=$!
    for _ in $(seq 1 100); do grep -q '"result"' "$TMP/out.$1" 2>/dev/null && break; sleep 0.1; done
  }
  # the session ends by itself when its input closes
  end_session() {
    for _ in $(seq 1 100); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$SPID" 2>/dev/null; then echo gone=no; kill "$SPID" 2>/dev/null; else echo gone=yes; fi
    wait 2>/dev/null
  }

  # --- no binary ------------------------------------------------------------
  senv "$TAGENTS_BIN/tagents-knowledge" join </dev/null >/dev/null 2>&1; rc=$?
  ok "no binary: the probe is answered with 69" 69 "$rc"
  ok "...and starts no node" 0 "$(starts)"
  session nobin
  ok "no binary: the session got an initialize reply" yes "$(grep -q '"result"' "$TMP/out.nobin" && echo yes || echo no)"
  cmd=$(ps -o command= -p "$SPID" 2>/dev/null)
  case $cmd in "nc -U "*) got=nc ;; *) got="$cmd" ;; esac
  ok "...through nc -U, which is the process the session started" nc "$got"
  ok "...after a serve that the wrapper handed to node" yes "$(grep -q ' serve' "$TMP/node-starts" && echo yes || echo no)"
  ok "...and no join was started" 0 "$(grep -c ' join' "$TMP/node-starts")"
  ok "...nothing on stderr" "" "$(cat "$TMP/err.nobin")"
  ok "...and ends when its input closes" gone=yes "$(end_session)"
  stop_scratch_daemons
  sleep 0.5

  # --- the binary -------------------------------------------------------------
  mkdir -p "$TAGENTS_HOME/target/release"; cp "$CORE" "$TAGENTS_HOME/target/release/tagents-core"; chmod 755 "$TAGENTS_HOME/target/release/tagents-core"
  out=$(install); rc=$?
  ok "the install over a binary exits 0" 0 "$rc"
  rm -f "$TMP/node-starts"
  senv "$TAGENTS_BIN/tagents-knowledge" join </dev/null >/dev/null 2>&1; rc=$?
  ok "with the binary: the probe is answered with 0" 0 "$rc"
  session bin
  ok "with the binary: the session got an initialize reply" yes "$(grep -q '"result"' "$TMP/out.bin" && echo yes || echo no)"
  cmd=$(ps -o command= -p "$SPID" 2>/dev/null)
  case $cmd in *"tagents-core knowledge join") got="tagents-core knowledge join" ;; *) got="$cmd" ;; esac
  ok "...the process the session started is tagents-core knowledge join" "tagents-core knowledge join" "$got"
  ok "...no node was started" 0 "$(starts)"
  ok "...no process under it: no node, no nc" "" "$(pgrep -P "$SPID" | tr -d '\n')"
  ok "...nothing on stderr" "" "$(cat "$TMP/err.bin")"
  ok "...and ends when its input closes" gone=yes "$(end_session)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
