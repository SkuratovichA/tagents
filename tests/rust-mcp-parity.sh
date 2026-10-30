#!/usr/bin/env bash
#
# tests/rust-mcp-parity.sh — `tagents-core mcp` answers what the node MCP server (packages/mcp) answers.
#
# Every scenario runs twice through tests/rust-mcp-parity-driver.mts, once against `node packages/mcp/dist/main.js --contract F` and once against `target/debug/tagents-core mcp --contract F` (or $TAGENTS_CORE_BIN), under the same `env -i` environment, and passes only when the two transcripts are byte for byte the same once `serverInfo.version` is dropped. A transcript is every answer the server wrote keyed by request id, the order the answers came in, how the server ended, and which processes of the call were still there at the end.
# No real tagents program runs: PATH is a scratch directory of stubs followed by /usr/bin:/bin, and HOME is a scratch directory. The stubs print what a real program could (JSON the way JavaScript writes it, text, nothing, more than the cap, a character across the cap, each exit code), and `emit` keeps the pids of what it started in $PARITY_DIR, which the driver checks at the end.
# Calls that end by a timeout or by the grace period are not here: the servers take both from constants, and the Rust tests for `run` take them as arguments (crates/tagents-core/tests/mcp_run.rs).
# Differences that are known and listed in docs/architecture/rust-core.md are not scenarios: the parameter-validation errors, a lone surrogate in a program's JSON, the echo of a request string with a lone surrogate (`unknown tool <name>` and the `id` of a request: Rust writes U+FFFD, node the escape), a second signal during the ending, objects and requests nested deeper than 128 levels, and the wording of start-up failures (only their exit codes are compared). The answers of calls that an ending stopped (stdin closed, a signal) are not compared either: node races its exit against writing them, the Rust server always writes them, and `rust_answers` pins that.
# Tripwires assert on the node transcript alone, so a scenario that stopped provoking what it exists for fails here instead of passing for nothing.
#
# PARITY_ONLY=<text> runs only the scenarios whose label holds the text, and PARITY_SHOW=<n> prints both transcripts of each, cut at n characters a line. Needs a built node server (pnpm build). Uses no real home, no tmux server, no network. bash 3.2.
#   env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/rust-mcp-parity.sh

set -o pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd -P)
NODE=${TAGENTS_NODE:-$(command -v node)}
MCP_JS="$REPO/packages/mcp/dist/main.js"
DRIVER="$HERE/rust-mcp-parity-driver.mts"
RUST=${TAGENTS_CORE_BIN:-$REPO/target/debug/tagents-core}

[ -n "$NODE" ] && [ -x "$NODE" ] || { echo "rust-mcp-parity: no node to run (set TAGENTS_NODE)" >&2; exit 2; }
[ -f "$MCP_JS" ] || { echo "rust-mcp-parity: $MCP_JS is not built; run: pnpm install && pnpm build" >&2; exit 2; }
if [ ! -x "$RUST" ]; then
  if [ -n "${TAGENTS_CORE_BIN:-}" ]; then echo "rust-mcp-parity: $RUST is not an executable" >&2; exit 2; fi
  (cd "$REPO" && cargo build -p tagents-core >&2) || { echo "rust-mcp-parity: cargo build failed" >&2; exit 2; }
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/tagents-mcp-parity.XXXXXX") || exit 2
TMP=$(cd "$TMP" && pwd -P) || exit 2
W=$TMP/w            # what a run leaves: the pids and the markers of the stubs. One path for both servers, so no transcript can tell them apart by it.
STUBS=$TMP/stubs
mkdir "$STUBS" "$TMP/home" "$TMP/scripts" "$W"
# A run that failed halfway must not leave a `sleep` behind: whatever the pid files still name is killed.
cleanup() {
  local file pid
  for file in "$W"/*.pid; do
    [ -f "$file" ] || continue
    pid=$(cat "$file" 2>/dev/null); case $pid in ''|*[!0-9]*) continue ;; esac
    kill -9 "$pid" 2>/dev/null
  done
  chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() {  # <label> <detail...>
  fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; shift
  [ $# -gt 0 ] && printf '       %s\n' "$@"
}
t() { printf '\n%s\n' "$1"; }

# ----------------------------------------------------------------- stubs ---
# `tagents-fake` is the program of the fixture contract. Any verb but `emit` prints its argv, one word to a line, which is how a call shows the command line it stood for. `emit <kind> ...` does what the kind says.
cat > "$STUBS/tagents-fake" <<'STUB'
#!/bin/sh
D=$PARITY_DIR
[ "$1" = emit ] || { printf '%s\n' "$@"; exit 0; }
shift; kind=$1; shift
case $kind in
  exit) echo "stdout of exit $1"; echo "stderr of exit $1" >&2; exit "$1" ;;
  kill) kill -9 $$ ;;
  term) kill -15 $$ ;;
  json) printf '%s\n' '{"b":1,"a":[1,2.5,1e+21,0.000001,-3,1.5e-7,123456789012345680000,1e+100,5e-324,0.1],"s":"caf\u00e9 \ud83d\ude00 \u0001 \"q\" \\ \/ \b\f\n\r\t \u2028 \u007f <&>","n":null,"t":true,"f":false,"e":{},"l":[],"dup":1,"dup":2,"nested":{"z":{"y":[{"x":1}]}},"k\u00e9y":"v","":"empty key","a1":1}' ;;
  array) printf '%s\n' ' [ 1, {"a": null}, "x", [ ], { } ] ' ;;
  prefixed) printf "$1"; printf '{"a":1}\n' ;;
  text) printf 'plain text\n  with  spaces\r\nand a tab\t.\n'; printf 'h\303\251llo w\303\266rld \360\237\230\200 \342\202\254\n' ;;
  scalar) printf '%s\n' "$1" ;;
  bare) printf '%s' "$1" ;;
  empty) ;;
  blank) printf '  \n\n' ;;
  bad) printf 'ok \377\376 mid \303 end \343\202' ;;
  nul) printf 'a\0b\n' ;;
  both) echo out; echo err >&2 ;;
  err) head -c "$1" /dev/zero | tr '\0' e >&2 ;;
  flood) head -c "$1" /dev/zero | tr '\0' x ;;
  floods) head -c "$1" /dev/zero | tr '\0' x; head -c "$1" /dev/zero | tr '\0' y >&2 ;;
  mb) head -c "$1" /dev/zero | tr '\0' a; i=0; while [ $i -lt 4 ]; do printf "$2"; i=$((i + 1)); done ;;
  bigjson) printf '{"k":"'; head -c "$1" /dev/zero | tr '\0' x; printf '"}\n' ;;
  env) env | sort ;;
  stdin) cat; echo "stdin gave nothing"; [ -t 0 ] && echo "stdin is a terminal" ;;
  hang) echo $$ > "$D/main.$1.pid"; sleep 30 & echo $! > "$D/grand.$1.pid"; : > "$D/started.$1"; wait ;;
  gate) echo $$ > "$D/gate.$1.pid"; : > "$D/started.$1"; while [ ! -e "$D/go.$1" ]; do sleep 0.02; done; echo "gate $1 opened" ;;
  leave) sleep 30 & echo $! > "$D/grand.leave.pid"; echo "left a child behind" ;;
  args) printf '%s\n' "$@" ;;
  *) echo "no such kind: $kind" >&2; exit 9 ;;
esac
STUB
# The two programs of the bundled contract.json answer with their argv, so a call of the real contract can be made without the real programs.
printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$STUBS/tagents-core"
cp "$STUBS/tagents-core" "$STUBS/tagents"
chmod +x "$STUBS"/*

# ------------------------------------------------------------- contracts ---
# Every feature of a spec that decides what a client sees. The programs are in this order in the file; the tools come out sorted.
FIXTURE=$TMP/fixture.json
cat > "$FIXTURE" <<'JSON'
{"unknown-top-level-key":true,"cli":{
"tagents-fake":{"exit":{"ok":0,"error":1,"usage":2,"refused":3,"timeout":4},"commands":[
{"path":["say"],"positionals":["<name>","[words…]"],"options":{"loud":{"type":"boolean"},"tag":{"type":"string","multiple":true},"label":{"type":"string"},"verbose":{"type":"boolean"}},"required":["label"],"summary":"print the arguments it was given","effect":"read","toolDefaults":{"verbose":true}},
{"path":["emit"],"positionals":["<kind>","[a]","[b]"],"options":{},"required":[],"summary":"print what the kind says","effect":"read"},
{"path":["find"],"positionals":["<query…>"],"options":{"limit":{"type":"string"},"dry-run":{"type":"boolean"}},"required":[],"summary":"search for words","effect":"read","toolDefaults":{"dry-run":false}},
{"path":["window"],"positionals":[],"options":{},"required":[],"summary":"open a window","effect":"spawn","requires":"tmux"},
{"path":["note","add"],"positionals":["<Session ID>","[text]"],"options":{"pin":{"type":"boolean"}},"required":[],"summary":"already a sentence.","effect":"write"},
{"path":["note","drop-all"],"positionals":["<session-id>"],"options":{"force":{"type":"boolean"}},"required":["force"],"summary":"remove them all!","effect":"destructive"},
{"path":["serve"],"positionals":[],"options":{},"required":[],"summary":"serves until it is stopped","effect":"serve"},
{"path":["hidden"],"positionals":[],"options":{},"required":[],"summary":"not offered as a tool","effect":"read","tool":false},
{"path":["new-effect"],"positionals":[],"options":{},"required":[],"summary":"an effect nobody has heard of","effect":"teleport","futureKey":{"x":1}},
{"path":["plain"],"positionals":[],"options":{},"required":[],"summary":"has no effect at all"},
{"path":["--odd","é","a b--c"],"positionals":["[ünï…]","[x_y]"],"options":{"a.b":{"type":"string"}},"required":[],"summary":"how odd names are made into names?","effect":"read"},
{"path":["sharp"],"positionals":[],"options":{},"required":[],"summary":"ßharp first letter","effect":"read"},
{"path":["astral"],"positionals":[],"options":{},"required":[],"summary":"𐐨 an astral first letter","effect":"read"},
{"path":["nothing"],"positionals":[],"options":{},"required":[],"summary":"","effect":"read"}]},
"tagents":{"exit":{"ok":0,"fine":0,"fail":1,"error":1},"commands":[
{"path":["--new"],"positionals":["[dir]"],"options":{"name":{"type":"string"}},"required":[],"summary":"start a session","effect":"spawn","requires":"tmux"},
{"path":["status"],"positionals":[],"options":{},"required":[],"summary":"say how it stands","effect":"read"}]},
"tagents-absent":{"exit":{},"commands":[
{"path":["go"],"positionals":[],"options":{},"required":[],"summary":"a program that is not on PATH","effect":"read"}]},
"tagents-｜":{"exit":{},"commands":[{"path":["go"],"positionals":[],"options":{},"required":[],"summary":"sorts after the astral one","effect":"read"}]},
"tagents-😀":{"exit":{},"commands":[{"path":["go"],"positionals":[],"options":{},"required":[],"summary":"sorts before the fullwidth one","effect":"read"}]}
}}
JSON
EMPTY=$TMP/empty.json
printf '{"cli":{}}\n' > "$EMPTY"

# -------------------------------------------------------------- scenarios ---
# The steps of a script, as JSON the driver reads. Ids are plain numbers or strings written the way JSON writes them.
steps() { local out= s; for s in "$@"; do out=${out:+$out,}$s; done; printf '[%s]' "$out"; }
req() { printf '{"send":{"jsonrpc":"2.0","id":%s,"method":"%s"%s}}' "$1" "$2" "${3:+,\"params\":$3}"; }          # <id> <method> [params]
notify() { printf '{"send":{"jsonrpc":"2.0","method":"%s"%s}}' "$1" "${2:+,\"params\":$2}"; }                    # <method> [params]
# A call is followed by the wait for its answer, so that the order of the answers does not depend on how two threads race: node answers calls that need no process in the order they came, the Rust server in the order their threads end. ASYNC=1 leaves the wait out, for the scenarios about calls in flight.
call() {  # <id> <tool> [arguments]
  printf '{"send":{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s"%s}}}' "$1" "$2" "${3:+,\"arguments\":$3}"
  [ -n "${ASYNC:-}" ] || printf ',{"answered":[%s]}' "$1"
}
await() { local ids= i; for i in "$@"; do ids=${ids:+$ids,}$i; done; printf '{"answered":[%s]}' "$ids"; }
file() { printf '{"file":"%s/%s"}' "$W" "$1"; }
gone() { printf '{"gone":"%s/%s"}' "$W" "$1"; }
touch_() { printf '{"touch":"%s/%s"}' "$W" "$1"; }
quiet() { printf '{"quiet":%s}' "$1"; }
close_() { printf '{"close":true}'; }
signal() { printf '{"signal":"%s"}' "$1"; }
jstr() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }   # the text as the inside of a JSON string
# bash 3.2 brace-expands the comma list of a double-quoted JSON object inside a command substitution inside double quotes, so JSON with braces and commas is built in a function body or written in single quotes, never as "{\"a\":1,\"b\":2}" inside $( ).
handshake() {
  local version=${1:-2025-11-25} params
  params="{\"protocolVersion\":\"$version\",\"capabilities\":{},\"clientInfo\":{\"name\":\"parity\",\"version\":\"0\"}}"
  printf '%s,%s,%s' "$(req 1 initialize "$params")" "$(notify notifications/initialized)" "$(await 1)"
}
initialize_with_roots() {  # <protocol version>
  local params="{\"protocolVersion\":\"$1\",\"capabilities\":{\"roots\":{\"listChanged\":true}},\"clientInfo\":{\"name\":\"parity\",\"version\":\"0\"}}"
  req 1 initialize "$params"
}
ecall() {  # <id> <kind> [<a> [<b>]]: a call of fake_emit, its arguments as the stub reads them
  local args="{\"kind\":\"$2\""
  [ $# -ge 3 ] && args="$args,\"a\":\"$(jstr "$3")\""
  [ $# -ge 4 ] && args="$args,\"b\":\"$(jstr "$4")\""
  call "$1" fake_emit "$args}"
}
session() { steps "$(handshake)" "$@"; }   # a handshake, then the steps

# What a transcript is compared after: the version a server reports is its own, in the start-up scenarios (LOOSE) the wording of stderr is too, and in the scenarios that end the server with calls in flight (ENDING) the answers of those calls are left out: node leaves as soon as the groups it stopped are gone, and whether the answer of a stopped call has been written by then depends on the order its promises settle in, so it answers some of them, none or all, from run to run. The Rust server writes every answer before it leaves, and `rust_answers` pins that.
LOOSE=
ENDING=
norm() {  # <file>
  local drop=()
  [ -z "$LOOSE" ] || drop+=(-e 's/^stderr [0-9][0-9]*$/stderr -/')
  [ -z "$ENDING" ] || drop+=(-e '/^answer [2-9]/d' -e '/^no-answer [2-9]/d' -e '/^order /d')
  sed -e 's/"serverInfo":{"name":"tagents","version":"[^"]*"}/"serverInfo":{"name":"tagents","version":"-"}/' ${drop[@]+"${drop[@]}"} "$1"
}

# The first line the two transcripts differ at, the request it answers and a window of 160 characters at the first differing one.
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
      split(a, key, "\t")
      print "line " FNR " (" key[1] "), first difference at character " i
      print "node: " (from > 1 ? "..." : "") substr(a, from, 160)
      print "rust: " (from > 1 ? "..." : "") substr(b, from, 160)
    }
    END { if (!shown && FNR < nodes) print "line " (FNR + 1) " only in node: " substr(node[FNR + 1], 1, 160) }
  ' "$1" "$2"
}

# play <label> <script> [-- <server arguments>]; $EXTRA_ENV holds extra VAR=value words for the environment of the servers.
EXTRA_ENV=()
RAN=1   # whether the last play ran its scenario: the tripwires of one that did not are skipped
play() {
  local label=$1 script=$2 side code
  shift 2
  # PARITY_ONLY=<text> runs the scenarios whose label holds the text, for working on one (the tripwires then look at whatever ran last).
  RAN=
  case $label in *"${PARITY_ONLY:-}"*) ;; *) return ;; esac
  RAN=1
  if [ "${1:-}" = -- ]; then shift; else set -- --contract "$FIXTURE"; fi
  printf '%s\n' "$script" > "$TMP/scripts/current.json"
  for side in node rust; do
    rm -rf "$W"; mkdir "$W"
    if [ $side = node ]; then
      env -i PATH="$STUBS:/usr/bin:/bin" HOME="$TMP/home" LANG=en_US.UTF-8 PARITY_DIR="$W" ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
        "$NODE" "$DRIVER" run "$TMP/scripts/current.json" "$W" -- "$NODE" "$MCP_JS" "$@" > "$TMP/raw.$side" 2> "$TMP/driver.$side"
    else
      env -i PATH="$STUBS:/usr/bin:/bin" HOME="$TMP/home" LANG=en_US.UTF-8 PARITY_DIR="$W" ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
        "$NODE" "$DRIVER" run "$TMP/scripts/current.json" "$W" -- "$RUST" mcp "$@" > "$TMP/raw.$side" 2> "$TMP/driver.$side"
    fi
    code=$?
    if [ "$code" -ne 0 ]; then bad "$label: the driver failed on the $side server (exit $code)" "$(head -c 400 "$TMP/driver.$side" | tr '\n' '|')"; return; fi
    norm "$TMP/raw.$side" > "$TMP/transcript.$side"
    if [ -n "${PARITY_SHOW:-}" ]; then printf '  --- %s, %s\n' "$label" "$side"; cut -c1-"$PARITY_SHOW" "$TMP/transcript.$side" | sed 's/^/  | /'; fi
  done
  if cmp -s "$TMP/transcript.node" "$TMP/transcript.rust"; then ok; return; fi
  bad "$label: the transcripts differ" "$(first_difference "$TMP/transcript.node" "$TMP/transcript.rust" | sed '2,$s/^/       /')"
}

# A tripwire: the node transcript of the last scenario must hold the string (fixed, not a pattern).
must() {  # <label> <needle>
  [ -n "$RAN" ] || return 0
  if grep -qF -- "$2" "$TMP/transcript.node"; then ok; else bad "tripwire $1: node did not say the string this scenario exists to provoke" "wanted: $2"; fi
}
# The first string comes before the second in the node transcript.
must_before() {  # <label> <first> <second>
  [ -n "$RAN" ] || return 0
  if [ "$(grep -o -F -e "$2" -e "$3" "$TMP/transcript.node" | head -1)" = "$2" ]; then ok; else bad "tripwire $1: node did not list them in this order" "wanted $2 before $3"; fi
}
# The Rust server answered each of these requests.
rust_answers() {  # <label> <id>...
  local label=$1 id
  shift
  [ -n "$RAN" ] || return 0
  for id in "$@"; do
    if grep -q "^answer $id$(printf '\t')" "$TMP/raw.rust"; then ok; else bad "tripwire $label: the Rust server did not answer request $id" "the answers of calls stopped by the ending are written before it leaves"; fi
  done
}
# The request text of the last scenario is ASCII only: an escape in it that was decoded would put the same literal text in front of both servers, and they would agree for nothing.
ascii_only() {  # <label> <request text>
  [ -n "$RAN" ] || return 0
  if [ -z "$(printf '%s' "$2" | LC_ALL=C tr -d '\000-\177')" ]; then ok; else bad "tripwire $1: the request text holds a non-ASCII byte, so an escape in it was decoded" ""; fi
}
# The reverse: the string is not in it.
must_not() {  # <label> <needle>
  [ -n "$RAN" ] || return 0
  if grep -qF -- "$2" "$TMP/transcript.node"; then bad "tripwire $1: node said what this scenario expects it not to say" "found: $2"; else ok; fi
}

# ------------------------------------------------------------ the checks ---
t "initialize: every protocol version the SDK lists, and two it does not"
VERSIONS=$("$NODE" "$DRIVER" versions "$REPO") || { echo "rust-mcp-parity: cannot read the protocol versions of the SDK" >&2; exit 2; }
[ -n "$VERSIONS" ] || { echo "rust-mcp-parity: the SDK lists no protocol version" >&2; exit 2; }
for v in $VERSIONS 2099-01-01 1999-01-01 ""; do
  play "initialize ${v:-(empty version)}" "$(steps "$(initialize_with_roots "$v")" "$(await 1)")"
  must "initialize $v" '"capabilities":{"tools":{'
done
play "initialize, then a second initialize" "$(steps "$(handshake 2024-11-05)" "$(req 2 initialize '{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"again","version":"1"}}')" "$(await 2)")"

t "ping, with the ids JSON-RPC allows"
play "ping" "$(session "$(req 2 ping)" "$(req '"s-1"' ping '{}')" "$(req 0 ping '{"_meta":{"progressToken":1}}')" "$(req '"é😀"' ping)" "$(await 2 '"s-1"' 0 '"é😀"')")"
must ping '"result":{}'
play "ping before any initialize" "$(steps "$(req 1 ping)" "$(await 1)")"

t "unknown methods, and notifications nobody answers"
play "unknown methods" "$(session "$(req 2 nope/nothing)" "$(req 3 resources/list)" "$(req 4 prompts/list)" "$(req 5 resources/templates/list)" "$(req 6 completion/complete '{"ref":{"type":"ref/prompt","name":"x"},"argument":{"name":"a","value":"b"}}')" "$(req 7 logging/setLevel '{"level":"info"}')" "$(req 8 resources/subscribe '{"uri":"x://y"}')" "$(req 9 tasks/list)" "$(req 10 '')" "$(await 2 3 4 5 6 7 8 9 10)")"
must "unknown methods" 'Method not found'
play "notifications get no answer" "$(session "$(notify notifications/cancelled '{"requestId":99}')" "$(notify notifications/roots/list_changed)" "$(notify nope/nothing)" "$(notify ping)" "$(notify tools/list)" "$(req 2 ping)" "$(await 2)" "$(quiet 150)")"

t "tools/list: a fixture with every feature of a spec, an empty contract, the bundled contract.json"
play "tools/list (fixture)" "$(session "$(req 2 tools/list)" "$(req 3 tools/list '{}')" "$(req 4 tools/list '{"_meta":{"progressToken":"t"}}')" "$(await 2 3 4)")"
must "tools/list" '"name":"fake_say"'
must "tools/list: the unclassified verb" '"name":"fake_new_effect","description":"An effect nobody has heard of.","inputSchema":{"type":"object","properties":{},"required":[],"additionalProperties":false},"annotations":{"readOnlyHint":false}}'
must "tools/list: toolDefaults" '"verbose":{"type":"boolean","default":true}'
must "tools/list: a default of false" '"dry-run":{"type":"boolean","default":false}'
must "tools/list: words" '"minItems":1'
must "tools/list: a multiple option" '"tag":{"type":"array","items":{"type":"string"}}'
must "tools/list: the script keeps its name" '"name":"tagents_new"'
must "tools/list: odd names" '"name":"fake_odd___a_b_c"'
must "tools/list: ß" '"description":"SSharp first letter."'
must "tools/list: an empty summary" '"name":"fake_nothing","description":"."'
# JavaScript sorts by UTF-16 code unit: U+1F600 (a surrogate pair, 0xD83D first) comes before U+FF5C, and a sort by scalar value would put them the other way round.
must_before "tools/list: the astral tool name sorts before the fullwidth one" '"name":"😀_go"' '"name":"｜_go"'
must_not "tools/list: serve is no tool" '"name":"fake_serve"'
must_not "tools/list: tool false is no tool" '"name":"fake_hidden"'
play "tools/list (empty contract)" "$(session "$(req 2 tools/list)" "$(await 2)")" -- --contract "$EMPTY"
play "tools/list (bundled contract.json)" "$(session "$(req 2 tools/list)" "$(await 2)")" -- --contract "$REPO/contract.json"
must "bundled contract" '"name":"core_session_list"'
play "tools/list (--contract=FILE)" "$(session "$(req 2 tools/list)" "$(await 2)")" -- "--contract=$FIXTURE"

t "tools/call: the command line a call stands for"
SAY='fake_say'
play "argv: every argument" "$(session "$(call 2 $SAY '{"name":"n","words":["w1","w 2","x-"],"loud":true,"tag":["a","b"],"label":"L","verbose":false}')" "$(await 2)")"
must "argv" 'say\\n--loud\\n--tag=a\\n--tag=b\\n--label=L\\nn\\nw1\\nw 2\\nx-'
play "argv: a flag-like word in a list is refused" "$(session "$(call 2 $SAY '{"name":"n","words":["ok","--no"],"label":"L"}')" "$(await 2)")"
play "argv: only what is required, the default of a boolean" "$(session "$(call 2 $SAY '{"name":"n","label":"L"}')" "$(call 3 $SAY '{"name":"n","label":"L","verbose":false,"loud":false}')" "$(call 4 $SAY '{"name":"n","label":"L","verbose":true}')" "$(await 2 3 4)")"
must "argv: the default" '--verbose\\nn'
play "argv: values that start with a dash or are empty" "$(session "$(call 2 $SAY '{"name":"n","label":"--x"}')" "$(call 3 $SAY '{"name":"","label":""}')" "$(call 4 $SAY '{"name":"n","label":"L","tag":[],"words":[]}')" "$(call 5 $SAY '{"name":"n","label":"L","tag":["","--"]}')" "$(await 2 3 4 5)")"
play "argv: arguments left out altogether" "$(session "$(call 2 fake_emit)" "$(call 3 tagents_status)" "$(await 2 3)")"
play "argv: the words of a verb whose path has dashes and spaces" "$(session "$(call 2 fake_odd___a_b_c '{"a.b":"v","n":["u"],"x_y":"y"}')" "$(await 2)")"
play "argv: the verbs of other programs" "$(session "$(call 2 tagents_status)" "$(call 3 fake_note_add '{"session_id":"s","text":"t","pin":true}')" "$(call 4 fake_find '{"query":["a","b"],"limit":"3"}')" "$(call 5 fake_find '{"query":[]}')" "$(await 2 3 4 5)")"
for case in \
  'unknown argument|{"name":"n","label":"L","zzz":1}' \
  'unknown argument before a missing one|{"zzz":1}' \
  'missing required option|{"name":"n"}' \
  'missing required positional|{"label":"L"}' \
  'null for a required|{"name":"n","label":null}' \
  'NUL in a string|{"name":"a\u0000b","label":"L"}' \
  'NUL in a list|{"name":"n","label":"L","tag":["ok","a\u0000"]}' \
  'a boolean given a string|{"name":"n","label":"L","loud":"yes"}' \
  'a boolean given a number|{"name":"n","label":"L","verbose":1}' \
  'a multiple option given a string|{"name":"n","label":"L","tag":"a"}' \
  'a multiple option given numbers|{"name":"n","label":"L","tag":[1]}' \
  'a string option given a number|{"name":"n","label":5}' \
  'a string option given a list|{"name":"n","label":["a"]}' \
  'a positional given a number|{"name":5,"label":"L"}' \
  'a positional given a list|{"name":["a"],"label":"L"}' \
  'words given a string|{"name":"n","words":"x","label":"L"}' \
  'words given numbers|{"name":"n","words":[1],"label":"L"}' \
  'a flag-like positional|{"name":"-x","label":"L"}' \
  'a dash alone|{"name":"-","label":"L"}' \
  'a positional after a skipped one|{"kind":"args","b":"b"}' \
  'arguments that are an empty object|{}'; do
  label=${case%%|*}; args=${case#*|}
  tool=$SAY; case $args in '{"kind"'*) tool=fake_emit ;; esac
  play "argv refused: $label" "$(session "$(call 2 "$tool" "$args")" "$(await 2)")"
done
play "argv refused: one tripwire" "$(session "$(call 2 $SAY '{"name":"n","label":"L","zzz":1}')" "$(call 3 $SAY '{"name":"-x","label":"L"}')" "$(call 4 fake_emit '{"kind":"args","b":"b"}')" "$(await 2 3 4)")"
must "refused: unknown argument" 'unknown argument'
must "refused: a dash" 'starts with a dash'
must "refused: a skipped positional" 'before it'

t "tools/call: an unknown tool, and a program that is not there"
play "unknown tool" "$(session "$(call 2 fake_nope)" "$(call 3 constructor)" "$(call 4 toString '{}')" "$(call 5 '')" "$(call 6 FAKE_SAY '{}')" "$(await 2 3 4 5 6)")"
must "unknown tool" 'unknown tool fake_nope'
play "program missing" "$(session "$(call 2 absent_go)" "$(call 3 absent_go '{}')" "$(await 2 3)")"
must "program missing" 'tagents-absent is not on PATH'
play "tools of the sorted-last programs are listed and called" "$(session "$(call 2 '😀_go')" "$(call 3 '｜_go')" "$(await 2 3)")"

t "tools/call: every way a call ends"
for code in 0 1 2 3 4 5 7 42 126 127 255; do
  play "exit $code" "$(session "$(ecall 2 exit "$code")" "$(call 3 tagents_status)" "$(await 2 3)")"
  case $code in
    0) must "exit 0" 'outcome\": \"ok\"' ;;
    3) must "exit 3" 'outcome\": \"refused\"' ;;
    7) must "exit 7" 'outcome\": \"exit 7\"' ;;
  esac
done
play "exit codes of a table with two names for a code" "$(session "$(call 2 tagents_status)" "$(await 2)")"
play "killed by a signal" "$(session "$(ecall 2 kill)" "$(ecall 3 term)" "$(await 2 3)")"
play "JSON and text output" "$(session "$(ecall 2 json)" "$(ecall 3 array)" "$(ecall 4 text)" "$(ecall 5 both)" "$(ecall 6 empty)" "$(ecall 7 blank)" "$(await 2 3 4 5 6 7)")"
must "JSON output is parsed" '\"a\": [\n      1,\n      2.5,\n      1e+21,\n      0.000001,'
must "JSON duplicate key" '\"dup\": 2'
for prefix in '\n\t ' '\302\240' '\357\273\277' '\342\200\250' '\343\200\200' '\302\205' '\342\200\213' '\341\240\216' ''; do
  play "JSON after a prefix [$prefix]" "$(session "$(ecall 2 prefixed "$prefix")" "$(await 2)")"
  # The node server looks past JavaScript white space to see a `{`, and then hands JSON.parse the output as it is: only the white space of JSON (space, tab, line feed, carriage return) leaves a parsed value, any other leaves the text.
  case $prefix in
    '\n\t '|'') must "prefix [$prefix] is white space to JSON" '\"a\": 1' ;;
    *) must_not "prefix [$prefix] is not white space to JSON" '\"a\": 1' ;;
  esac
done
for text in '42' '"str"' 'true' 'null' '{not json' '[1,2' '{"a":1} trailing' '{"a":1}{"b":2}' '[]' '{}' '{ }' '[ ]' '{"a":[]}' '{"a":{"b":{}}}' '[[[[[[[[[[1]]]]]]]]]]' '{"a":1,"a":2,"b":3,"a":4}' '{"__proto__":1,"x":2}' '{"a":"\ud83d\ude00"}' '{"a":"\u00e9\u0000\u001f"}'; do
  play "JSON text [$text]" "$(session "$(ecall 2 bare "$text")" "$(await 2)")"
done
# A number comes back the way JavaScript prints the double it reads as (JSON.parse, then JSON.stringify): 1.0 is 1, 1E2 is 100, -0 is 0, and a number past the double is null.
for numbers in '[1.0,1E2,0.10,-0,-0.0,0e5]' '[123456789012345678901234567890,100000000000000000000000,1e21,1e-7,0.000001,1.5E+3,0.1e1]' '[9007199254740993,9007199254740992,-9007199254740993,18446744073709551615,18446744073709551616]' '[1e400,-1e400,1e-400,5e-324,4.9e-324,2.4e-324,2.5e-324,1.7976931348623157e308,1.7976931348623159e308]' '[0.1,0.2,0.30000000000000004,1.0000000000000002,123.456,4.35,0.000123,1234567890123456789012,1e22,1e23]' '[270348394056782.125,0.125,0.375,4503599627370497.5,1.0000000000000002,2.2250738585072014e-308]' '{"n":1.0,"e":1E2,"x":[2.50]}'; do
  play "JSON numbers [$numbers]" "$(session "$(ecall 2 bare "$numbers")" "$(await 2)")"
  case $numbers in
    '[1.0,1E2,'*) must "numbers are printed as JavaScript prints them" '\"stdout\": [\n    1,\n    100,\n    0.1,\n    0,\n    0,\n    0\n  ]' ;;
    '[1e400,'*) must "numbers past the double are null" '\"stdout\": [\n    null,\n    null,\n    0,\n    5e-324,' ;;
  esac
done
play "output that is not UTF-8, and a NUL" "$(session "$(ecall 2 bad)" "$(ecall 3 nul)" "$(await 2 3)")"
play "stdin of the program is empty, the environment is the server's" "$(session "$(ecall 2 stdin)" "$(ecall 3 env)" "$(await 2 3)")"
must "stdin" 'stdin gave nothing'

t "tools/call: the cap on what a call returns"
CAP=262144
for n in $((CAP - 1)) $CAP $((CAP + 1)) $((CAP * 2 + 5000)); do
  play "stdout of $n bytes" "$(session "$(ecall 2 flood "$n")" "$(await 2)")"
  if [ "$n" -gt "$CAP" ]; then must "stdout of $n bytes is cut" '[output cut at 262144 bytes]'; must "stdout of $n bytes is truncated" 'truncated\": true'; else must_not "stdout of $n bytes is not cut" 'truncated\": true'; fi
done
play "stderr of $((CAP + 1)) bytes" "$(session "$(ecall 2 err "$((CAP + 1))")" "$(await 2)")"
must "stderr over the cap" '[output cut at 262144 bytes]'
play "both streams over the cap" "$(session "$(ecall 2 floods "$((CAP + 100))")" "$(await 2)")"
for pad in $((CAP - 1)) $((CAP - 2)) $((CAP - 3)) $((CAP - 4)) $((CAP - 5)); do
  play "a character across the cap, $pad bytes before it" "$(session "$(ecall 2 mb "$pad" '\342\202\254')" "$(ecall 3 mb "$pad" '\360\237\230\200')" "$(await 2 3)")"
  must "cut across a character, $pad" '[output cut at 262144 bytes]'
done
play "JSON under the cap and JSON cut by it" "$(session "$(ecall 2 bigjson 100000)" "$(ecall 3 bigjson "$((CAP + 1000))")" "$(await 2 3)")"

t "tools/call: a verb that needs tmux"
play "tmux required, no TMUX" "$(session "$(call 2 fake_window)" "$(call 3 tagents_new '{"name":"n"}')" "$(await 2 3)")"
must "tmux refused" 'tmux'
EXTRA_ENV=(TMUX=/tmp/parity-tmux,1,0)
play "tmux required, TMUX set" "$(session "$(call 2 fake_window)" "$(call 3 tagents_new '{"name":"n","dir":"d"}')" "$(await 2 3)")"
EXTRA_ENV=()
EXTRA_ENV=(TMUX=)
play "tmux required, TMUX empty" "$(session "$(call 2 fake_window)" "$(await 2)")"
EXTRA_ENV=()

t "a call against the real contract.json, with the stubs for its programs"
play "core_plugin_list" "$(session "$(call 2 core_plugin_list '{"json":true}')" "$(call 3 core_session_list '{}')" "$(await 2 3)")" -- --contract "$REPO/contract.json"

t "processes: cancel, two calls in flight, stdin closed, signals, a child left behind"
play "a cancelled call is not answered and leaves nothing running" "$(session "$(ASYNC=1 ecall 2 hang 1)" "$(file started.1)" "$(notify notifications/cancelled '{"requestId":2,"reason":"changed my mind"}')" "$(gone grand.1.pid)" "$(gone main.1.pid)" "$(req 3 ping)" "$(await 3)" "$(quiet 300)")"
must "cancel: no answer" 'no-answer 2'
must "cancel: nothing left" 'pids gone'
play "a cancel for a request that is not in flight is ignored" "$(session "$(notify notifications/cancelled '{"requestId":99}')" "$(notify notifications/cancelled '{"requestId":"2"}')" "$(notify notifications/cancelled '{}')" "$(req 2 ping)" "$(await 2)")"
play "two calls in flight answer in the order they finish (b first)" "$(session "$(ASYNC=1 ecall 2 gate a)" "$(ASYNC=1 ecall 3 gate b)" "$(file started.a)" "$(file started.b)" "$(touch_ go.b)" "$(await 3)" "$(touch_ go.a)" "$(await 2)")"
must "two calls: b first" 'order 1 3 2'
play "two calls in flight answer in the order they finish (a first)" "$(session "$(ASYNC=1 ecall 2 gate a)" "$(ASYNC=1 ecall 3 gate b)" "$(file started.a)" "$(file started.b)" "$(touch_ go.a)" "$(await 2)" "$(touch_ go.b)" "$(await 3)")"
must "two calls: a first" 'order 1 2 3'
play "a call in flight does not hold up a ping" "$(session "$(ASYNC=1 ecall 2 gate a)" "$(file started.a)" "$(req 3 ping)" "$(await 3)" "$(touch_ go.a)" "$(await 2)")"
must "ping first" 'order 1 3 2'
ENDING=1
play "stdin closed with a call in flight" "$(session "$(ASYNC=1 ecall 2 hang 1)" "$(file started.1)" "$(close_)")"
must "stdin closed: the group is gone" 'pids gone'
rust_answers "stdin closed" 2
play "stdin closed with two calls in flight" "$(session "$(ASYNC=1 ecall 2 hang 1)" "$(ASYNC=1 ecall 3 hang 2)" "$(file started.1)" "$(file started.2)" "$(close_)")"
rust_answers "stdin closed, two calls" 2 3
for sig in SIGTERM SIGINT SIGHUP; do
  play "$sig with a call in flight" "$(session "$(ASYNC=1 ecall 2 hang 1)" "$(file started.1)" "$(signal $sig)")"
  rust_answers "$sig" 2
done
ENDING=
play "a program that exits and leaves a child holding its pipes" "$(session "$(ecall 2 leave)" "$(await 2)" "$(gone grand.leave.pid)")"
must "a child left behind: the group is killed" 'pids gone'
must "a child left behind: the answer" 'left a child behind'

t "the wire: what a client may send that is not a plain request"
play "split across writes" "$(session '{"raw":"{\"jsonrpc\":\"2.0\",\"id\":2,\"meth"}' "$(quiet 80)" '{"raw":"od\":\"ping\"}\n"}' "$(await 2)")"
play "CRLF line ends, empty lines, two requests in one write" "$(session '{"raw":"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\r\n\n\r\n{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}\n{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"ping\"}\n"}' "$(await 2 3 4)")"
play "lines that are not requests are ignored" "$(session '{"raw":"not json\n"}' '{"raw":"[]\n"}' '{"raw":"5\n"}' '{"raw":"{}\n"}' '{"raw":"{\"jsonrpc\":\"1.0\",\"id\":8,\"method\":\"ping\"}\n"}' '{"raw":"{\"jsonrpc\":\"2.0\",\"id\":9}\n"}' '{"raw":"{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"ping\"}\n"}' '{"raw":"{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"ping\"}\n"}' '{"raw":"{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"ping\"}\n"}' '{"raw":"{\"jsonrpc\":\"2.0\",\"id\":77,\"result\":{}}\n"}' "$(req 2 ping)" "$(await 2)" "$(quiet 150)")"
req_unicode='{"name":"caf\u00e9 \ud83d\ude00","label":"\u00e9\n\t\"\\","words":["\u2028","\u0001"]}'
play "a request with unicode and escapes in its strings" "$(session "$(call 2 fake_say "$req_unicode")" "$(await 2)")"
ascii_only "unicode and escapes" "$req_unicode"
req_surrogates='{"name":"a\ud83db","label":"\ude00\ud83d\ud83d\ude00","words":["x\\ud83d","\ud83dA"]}'
play "a request with lone surrogate escapes in its strings, a pair beside them and an escaped backslash" "$(session "$(call 2 fake_say "$req_surrogates")" "$(await 2)")"
ascii_only "lone surrogate escapes" "$req_surrogates"
must "lone surrogate escapes" "$(printf '\357\277\275')"
play "an empty request line and an end of input with no newline" "$(session '{"raw":"\n"}' '{"raw":"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}"}' "$(quiet 100)")"

t "start-up: only the exit codes are compared, the words of the messages are the servers' own"
LOOSE=1
play "no arguments" "$(steps "$(close_)")" --
play "--contract without a value" "$(steps "$(close_)")" -- --contract
play "an unknown option" "$(steps "$(close_)")" -- --contract "$FIXTURE" --nope
play "a positional argument" "$(steps "$(close_)")" -- --contract "$FIXTURE" extra
play "a contract that is not there" "$(steps "$(close_)")" -- --contract "$TMP/does-not-exist.json"
printf 'not json' > "$TMP/c-notjson.json"
play "a contract that is not JSON" "$(steps "$(close_)")" -- --contract "$TMP/c-notjson.json"
printf '{"nope":1}' > "$TMP/c-nocli.json"
play "a contract without a cli section" "$(steps "$(close_)")" -- --contract "$TMP/c-nocli.json"
printf '{"cli":{"p":{"exit":{},"commands":[{"path":["a"],"positionals":["bad"],"options":{},"required":[],"summary":"s"}]}}}' > "$TMP/c-positional.json"
play "a positional that is neither <required> nor [optional]" "$(steps "$(close_)")" -- --contract "$TMP/c-positional.json"
printf '{"cli":{"p":{"exit":{},"commands":[{"path":["a"],"positionals":[],"options":{},"required":[],"summary":"s"},{"path":["a"],"positionals":[],"options":{},"required":[],"summary":"s"}]}}}' > "$TMP/c-twice.json"
play "two verbs that would be one tool" "$(steps "$(close_)")" -- --contract "$TMP/c-twice.json"
printf '{"cli":{"p":{"exit":{},"commands":[{"path":["a"],"positionals":[],"options":{"x":{"type":"string"}},"required":[],"summary":"s","toolDefaults":{"x":true}}]}}}' > "$TMP/c-default.json"
play "a default for an option that takes a string" "$(steps "$(close_)")" -- --contract "$TMP/c-default.json"
printf '{"cli":{"p":{"exit":{},"commands":[{"path":["a"],"positionals":["<x>"],"options":{"x":{"type":"string"}},"required":[],"summary":"s"}]}}}' > "$TMP/c-shared.json"
play "an option and a positional with one name" "$(steps "$(close_)")" -- --contract "$TMP/c-shared.json"
LOOSE=

printf '\nrust-mcp-parity: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
