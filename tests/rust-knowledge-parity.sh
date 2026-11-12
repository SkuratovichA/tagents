#!/usr/bin/env bash
#
# tests/rust-knowledge-parity.sh — `okb` answers what the node knowledge package answered: the seven verbs that read the folder (`index`, `search`, `show`, `list`, `lint`, `toc`, `usage`), and `mcp`, `serve` and `join`.
#
# Every scenario runs twice, once against `node packages/knowledge/dist/cli/main.js` of the oracle and once against `target/debug/okb` (or $OKB_BIN), each on its own copy of one corpus in scratch directories, with a scratch HOME, TMPDIR, config directory, index and usage store, and compares what the client sees byte for byte. The MCP scenarios go through tests/rust-mcp-parity-driver.mts, which speaks to any stdio MCP server; tests/rust-knowledge-parity-driver.mts writes the documents and the sweep they search.
# The daemon scenarios compare facts (how many daemons run, what the socket directory is, what a session was told) read from outside, because the two programs name their sockets differently. The `join` scenarios have no node counterpart in the daemon's own right (the session of the node arrangement is `nc`), so they assert the outcome of the Rust relay and compare what its client sees with what the node server's stdio says.
# Tripwires assert on the node transcript alone, so a scenario that stopped provoking what it exists for fails here instead of passing for nothing. The suite prints how many scenarios it skipped (PARITY_ONLY).
# Differences that are known and listed in docs/architecture/rust-core.md are not scenarios.
#
# No real knowledge folder, config or daemon is touched: every program runs under `env -i` with paths in one scratch directory, and a daemon is signalled only by the pid its own pid file names, only when its command line holds that directory.
#
# PARITY_ONLY=<text> runs only the scenarios whose label holds the text, and PARITY_SHOW=<n> prints both transcripts of each, cut at n characters a line. Needs a built node package (pnpm build).
#   env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/rust-knowledge-parity.sh

set -o pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd -P)
ORACLE=$(bash "$HERE/parity-oracle.sh") || { echo "rust-knowledge-parity: no node oracle (tests/parity-oracle.sh)" >&2; exit 2; }
NODE=${TAGENTS_NODE:-$(command -v node)}
KJS="$ORACLE/packages/knowledge/dist/cli/main.js"
# The seven verbs that read the folder are compared with v0.7.0, the last tag whose node program words them as the tree did before it left: v0.6.7 still has `mcp` and `serve` in the usage text, which the binary serves in its place. `mcp`, `serve` and `join` are compared with v0.6.7, which still has their node implementations.
CLI_ORACLE=$(PARITY_ORACLE_TAG=v0.7.0 bash "$HERE/parity-oracle.sh") || { echo "rust-knowledge-parity: no node oracle for the verbs (tests/parity-oracle.sh at v0.7.0)" >&2; exit 2; }
KJS_CLI="$CLI_ORACLE/packages/knowledge/dist/cli/main.js"
MCP_DRIVER="$HERE/rust-mcp-parity-driver.mts"
GEN="$HERE/rust-knowledge-parity-driver.mts"
# A process that has not ended after 30 seconds is killed by its own alarm, which a relay test then reports as exit 142.
# PERL_BADLANG keeps perl quiet about a locale the system does not have: the program environment names en_US.UTF-8, and the join scenarios read stderr.
ALARMED=(env PERL_BADLANG=0 perl -e 'alarm 30; exec @ARGV')
RUST=${OKB_BIN:-$REPO/target/debug/okb}

[ -n "$NODE" ] && [ -x "$NODE" ] || { echo "rust-knowledge-parity: no node to run (set TAGENTS_NODE)" >&2; exit 2; }
[ -f "$KJS_CLI" ] || { echo "rust-knowledge-parity: $KJS_CLI is not built; run: PARITY_ORACLE_TAG=v0.7.0 bash tests/parity-oracle.sh" >&2; exit 2; }
[ -f "$KJS" ] || { echo "rust-knowledge-parity: $KJS is not built; run: bash tests/parity-oracle.sh" >&2; exit 2; }
if [ ! -x "$RUST" ]; then
  if [ -n "${OKB_BIN:-}" ]; then echo "rust-knowledge-parity: $RUST is not an executable" >&2; exit 2; fi
  (cd "$REPO" && cargo build -p okb >&2) || { echo "rust-knowledge-parity: cargo build failed" >&2; exit 2; }
fi
command -v sqlite3 > /dev/null || { echo "rust-knowledge-parity: no sqlite3 to read the stores with" >&2; exit 2; }
RUST_ABS=$(cd "$(dirname "$RUST")" && pwd -P)/$(basename "$RUST")

# A socket address holds about 100 bytes, so everything lives in a short directory.
TMP=$(mktemp -d /tmp/kpar.XXXXXX) || exit 2
TMP=$(cd "$TMP" && pwd -P) || exit 2
W=$TMP/w            # the pids and markers a run leaves; one path for both programs
mkdir "$W" "$TMP/scripts" "$TMP/cfg" "$TMP/seed"
cleanup() {
  local pid
  for pid in $(daemon_pids_everywhere); do kill -TERM "$pid" 2>/dev/null; done
  chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"
}
# Every pid named by a pid file below the scratch directory whose command line holds the directory: the daemons this run started.
daemon_pids_everywhere() {
  local file pid
  for file in $(find "$TMP" -name '*.pid' -type f 2>/dev/null); do
    pid=$(cat "$file" 2>/dev/null); case $pid in ''|*[!0-9]*) continue ;; esac
    ps -o command= -p "$pid" 2>/dev/null | grep -qF "$TMP" && { echo "$pid"; } 2>/dev/null
  done
}
trap cleanup EXIT INT TERM

pass=0; fail=0
. "$HERE/lib/parity.sh"
. "$HERE/lib/mcp-parity.sh"

"$NODE" "$HERE/rust-parity-seed.mts" "$TMP/seed" || { echo "rust-knowledge-parity: seeding the sessions failed" >&2; exit 2; }
SESSIONS_HOME=$TMP/seed/fixture

# The first check: the program compared with node is Rust. A launcher script or the node CLI itself would make every scenario below compare node with node and pass.
t "the program under test is Rust"
if [ "$(head -c 2 "$RUST_ABS")" = '#!' ]; then bad "the program under test is a script" "$RUST_ABS starts with #!"; else ok; fi
# `okb mcp` is served by the binary itself: with no node on the PATH and no input it still ends with exit 0 and says nothing.
nothing_said=$(env -i PATH=/nonexistent HOME="$TMP" TAGENTS_CONFIG_DIR="$TMP/cfg" TAGENTS_KNOWLEDGE_DIR="$TMP/none" TAGENTS_KNOWLEDGE_DB="$TMP/none.sqlite" "$RUST_ABS" mcp < /dev/null 2>&1); code=$?
if [ "$code" -eq 0 ] && [ -z "$nothing_said" ]; then ok; else bad "the program under test does not serve mcp by itself" "exit $code: $nothing_said"; fi

# ----------------------------------------------------------------- the world of one run ---
# docs, index and usage store of the run, in one directory the run starts from scratch.
DOCS=$TMP/world/docs; INDEX=$TMP/world/index.sqlite; USAGE=$TMP/world/usage.sqlite
CORPUS=knowledge   # the fixture folder the run copies: knowledge, okf or both
BAD=               # whether the documents of the driver's `bad` are added
EXTRAS=            # whether the documents of the driver's `extras` are added
# the permission bits of a path, the same on macOS and Linux
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

reset_world() {
  rm -rf "$TMP/world" "$TMP/tmp"; mkdir -p "$DOCS" "$TMP/tmp"
  case $CORPUS in
    knowledge|both) cp "$REPO"/crates/okb/tests/fixtures/knowledge/*.md "$DOCS/" ;;
  esac
  case $CORPUS in
    okf|both) cp "$REPO"/crates/okb/tests/fixtures/okf/*.md "$DOCS/" ;;
  esac
  [ -z "$EXTRAS" ] || "$NODE" "$GEN" extras "$DOCS"
  [ -z "$BAD" ] || "$NODE" "$GEN" bad "$DOCS"
  # The same modification time in every world, with a fraction of a millisecond that rounding would carry over: the index records it.
  perl -MTime::HiRes=utime -e 'utime(1767225600.7896, 1767225600.7896, @ARGV)' "$DOCS"/*.md
}
# The environment of a program: exactly these variables.
program_env() {
  PENV=(PATH=/usr/bin:/bin HOME="$SESSIONS_HOME" CLAUDE_HOMES="$SESSIONS_HOME/.claude" TAGENTS_CONFIG_DIR="$TMP/cfg" TAGENTS_KNOWLEDGE_DIR="$DOCS" TAGENTS_KNOWLEDGE_DB="$INDEX" TAGENTS_KNOWLEDGE_USAGE_DB="$USAGE" TMPDIR="$TMP/tmp" TZ=UTC LANG=en_US.UTF-8 TAGENTS_LOCALE=en)
}
server_command() {  # <side> <verb> [args...]: the program of a side
  local side=$1; shift
  if [ "$side" = node ]; then SERVER=("$NODE" "$KJS" "$@"); else SERVER=("$RUST_ABS" "$@"); fi
}

# ----------------------------------------------------------------- comparing ---
expect() {  # <label> <got> <want>
  [ -n "$RAN" ] || return 0
  if [ "$2" = "$3" ]; then ok; else bad "$1" "got:    $2
       wanted: $3"; fi
}
norm() {  # <file>: the version a server reports is its own
  sed -e 's/"serverInfo":{"name":"tagents-knowledge","version":"[^"]*"}/"serverInfo":{"name":"tagents-knowledge","version":"-"}/' "$1"
}
RAN=1
SKIPPED=0
# Compares the two transcripts of a scenario that ran.
compare() {  # <label>
  if [ -n "${PARITY_SHOW:-}" ]; then
    local side
    for side in node rust; do printf '  --- %s, %s\n' "$1" "$side"; cut -c1-"$PARITY_SHOW" "$TMP/transcript.$side" | sed 's/^/  | /'; done
  fi
  if cmp -s "$TMP/transcript.node" "$TMP/transcript.rust"; then ok; return 0; fi
  bad "$1: the transcripts differ" "$(first_difference "$TMP/transcript.node" "$TMP/transcript.rust" | sed '2,$s/^/       /')"
  return 1
}
wanted() {  # <label>: whether the scenario is selected
  case $1 in *"${PARITY_ONLY:-}"*) RAN=1; return 0 ;; esac
  RAN=; SKIPPED=$((SKIPPED + 1)); return 1
}

# One MCP session of a side against a stdio server, its transcript in $TMP/transcript.<side>.
run_session() {  # <side> <script file> <server verb and arguments...>
  local side=$1 script=$2 code
  shift 2
  server_command "$side" "$@"
  program_env
  env -i "${PENV[@]}" PARITY_DIR="$W" "$NODE" "$MCP_DRIVER" run "$script" "$W" -- "${SERVER[@]}" > "$TMP/raw.$side" 2> "$TMP/driver.$side"
  code=$?
  norm "$TMP/raw.$side" > "$TMP/transcript.$side"
  return $code
}

# play <label> <script>: the script is run by each side on a world of its own, from scratch.
play() {
  local label=$1 script=$2 side
  wanted "$label" || return 0
  printf '%s\n' "$script" > "$TMP/scripts/current.json"
  for side in node rust; do
    reset_world
    run_session "$side" "$TMP/scripts/current.json" mcp || { bad "$label: the driver failed on the $side server" "$(head -c 400 "$TMP/driver.$side" | tr '\n' '|')"; return 0; }
  done
  compare "$label"
}

# An initialize request for a protocol version, built in a function body because bash 3.2 brace-expands the commas of JSON in a double-quoted command substitution.
init_request() {  # <protocol version>
  local params="{\"protocolVersion\":\"$1\",\"capabilities\":{},\"clientInfo\":{\"name\":\"parity\",\"version\":\"0\"}}"
  req 1 initialize "$params"
}
kcall() { call "$1" "$2" "${3:-}"; }   # <id> <tool> [arguments JSON]
ksession() { session "$@"; }

# ------------------------------------------------------------ the checks ---
t "handshake, listing and the refusals of the protocol"
VERSIONS=$("$NODE" "$MCP_DRIVER" versions "$ORACLE") || { echo "rust-knowledge-parity: cannot read the protocol versions of the SDK" >&2; exit 2; }
for v in $VERSIONS 2099-01-01 ""; do
  play "handshake and list: initialize ${v:-(empty version)}" "$(steps "$(init_request "$v")" "$(await 1)")"
done
must "initialize: the server's name" '"serverInfo":{"name":"tagents-knowledge"'
play "handshake and list: tools/list, ping, an unknown method, an unknown tool, a malformed line" "$(ksession "$(req 2 tools/list)" "$(await 2)" "$(req 3 ping)" "$(await 3)" "$(req 4 nope/method)" "$(await 4)" "$(kcall 5 nope_tool '{}')" '{"raw":"{not json\n"}' "$(req 6 tools/list)" "$(await 6)")"
for tool in knowledge_search knowledge_get knowledge_list knowledge_usage sessions_recent sessions_search; do must "tools/list: $tool" "\"name\":\"$tool\""; done
must "ping" '"result":{}'
must "unknown method" 'Method not found'
must "unknown tool" 'nope_tool'
must "a malformed line leaves the session alive" "$(printf 'answer 6\t')"

t "search"
EXTRAS=1; CORPUS=both
play "search diacritics and ties" "$(ksession \
  "$(kcall 2 knowledge_search '{"query":"cafe"}')" \
  "$(kcall 3 knowledge_search '{"query":"CAFÉ"}')" \
  "$(kcall 4 knowledge_search '{"query":"naive resume zoe"}')" \
  "$(kcall 5 knowledge_search '{"query":"strasse"}')" \
  "$(kcall 6 knowledge_search '{"query":"marmalade"}')" \
  "$(kcall 7 knowledge_search '{"query":"диски"}')" \
  "$(kcall 8 knowledge_search '{"query":"Карта машины"}')" \
  "$(kcall 9 knowledge_search '{"query":"sqlite*"}')" \
  "$(kcall 10 knowledge_search '{"query":"depl*"}')")"
must "search: a diacritic is folded" 'cafe-notes'
must "search: ties" 'tie-one'
must_before "search: deprecated documents come last" 'tie-three' 'old-marmalade'
must "search: Cyrillic" 'mashina-karta'
play "search filters and limit" "$(ksession \
  "$(kcall 2 knowledge_search '{"query":"runbook","tag":"ops"}')" \
  "$(kcall 3 knowledge_search '{"query":"runbook","type":"Runbook"}')" \
  "$(kcall 4 knowledge_search '{"query":"runbook","type":"runbook"}')" \
  "$(kcall 5 knowledge_search '{"query":"runbook","kind":"runbook"}')" \
  "$(kcall 6 knowledge_search '{"query":"the","limit":2}')" \
  "$(kcall 7 knowledge_search '{"query":"the","limit":50}')" \
  "$(kcall 8 knowledge_search '{"query":"the","limit":51}')" \
  "$(kcall 9 knowledge_search '{"query":"the","limit":0}')" \
  "$(kcall 10 knowledge_search '{"query":"the","limit":-1}')" \
  "$(kcall 11 knowledge_search '{"query":"the","limit":1e300}')" \
  "$(kcall 12 knowledge_search '{"query":"the","limit":2.5}')" \
  "$(kcall 13 knowledge_search '{"query":"\"unterminated"}')" \
  "$(kcall 14 knowledge_search '{"query":"a AND OR"}')" \
  "$(kcall 15 knowledge_search '{"query":"nothing-matches-this-zzz"}')" \
  "$(kcall 16 knowledge_search '{"query":""}')")"
must "search filters: the tag" 'legacy-kind'
must "search filters: the limit is checked" 'Too small: expected number to be >0 at limit'
EXTRAS=; CORPUS=knowledge

t "get, list, usage and the session tools"
EXTRAS=1; CORPUS=both
play "get a document and a section" "$(ksession \
  "$(kcall 2 knowledge_get '{"id":"deploy-runbook"}')" \
  "$(kcall 3 knowledge_get '{"id":"deploy-runbook","heading":"Deploy"}')" \
  "$(kcall 4 knowledge_get '{"id":"mashina-karta","heading":"Диски"}')" \
  "$(kcall 5 knowledge_get '{"id":"no-such-doc"}')" \
  "$(kcall 6 knowledge_get '{"id":"deploy-runbook","heading":"No such heading"}')" \
  "$(kcall 7 knowledge_get '{"id":"cafe-notes","heading":"Ünïcode heading"}')" \
  "$(kcall 8 knowledge_get '{"id":"cache-policy"}')")"
must "get: a missing document" 'no document with id'
must "get: a missing section lists the sections" 'No such heading'
play "list" "$(ksession \
  "$(kcall 2 knowledge_list '{}')" \
  "$(kcall 3 knowledge_list '{"type":"runbook"}')" \
  "$(kcall 4 knowledge_list '{"kind":"note"}')" \
  "$(kcall 5 knowledge_list '{"tag":"deploy"}')" \
  "$(kcall 6 knowledge_list '{"type":"Decision"}')")"
must "list: a document" '\"id\": \"deploy-runbook\",\n    \"title\": \"Deploying the demo service\"'
play "usage with every argument" "$(ksession \
  "$(kcall 2 knowledge_get '{"id":"deploy-runbook"}')" \
  "$(kcall 3 knowledge_get '{"id":"deploy-runbook"}')" \
  "$(kcall 4 knowledge_get '{"id":"tmux-cheatsheet"}')" \
  "$(kcall 5 knowledge_usage '{}')" \
  "$(kcall 6 knowledge_usage '{"since":"7d","top":1}')" \
  "$(kcall 7 knowledge_usage '{"type":"runbook"}')" \
  "$(kcall 8 knowledge_usage '{"all":true}')" \
  "$(kcall 9 knowledge_usage '{"candidates":true,"min_gets":1,"min_days":1}')" \
  "$(kcall 10 knowledge_usage '{"since":"0d"}')" \
  "$(kcall 11 knowledge_usage '{"since":"soon"}')" \
  "$(kcall 12 knowledge_usage '{"top":0}')" \
  "$(kcall 13 knowledge_usage '{"top":1e300}')" \
  "$(kcall 14 knowledge_usage '{"top":-1}')" \
  "$(kcall 15 knowledge_usage '{"min_gets":0}')")"
must "usage: a count" '\"id\": \"deploy-runbook\",\n    \"type\": \"Runbook\",\n    \"status\": \"stable\",\n    \"gets\": 2,'
must "usage: a bad window" 'since must be'
play "the two session tools" "$(ksession \
  "$(kcall 2 sessions_recent '{}')" \
  "$(kcall 3 sessions_recent '{"limit":1}')" \
  "$(kcall 4 sessions_recent '{"limit":200}')" \
  "$(kcall 5 sessions_search '{"words":"nothing here"}')" \
  "$(kcall 6 sessions_search '{"words":"fixture"}')" \
  "$(kcall 7 sessions_search '{"words":"   "}')")"
must "sessions: the recent list names a session" 'Fix the deploy script for the staging cluster'
must "sessions: a search that finds nothing says so" 'nothing matches \"nothing here\" in the last 400 sessions'
EXTRAS=; CORPUS=knowledge

t "argument errors"
play "argument errors" "$(ksession \
  "$(kcall 2 knowledge_search '{}')" \
  "$(kcall 3 knowledge_search '{"query":5}')" \
  "$(kcall 4 knowledge_search '{"query":"x","limit":"3"}')" \
  "$(kcall 5 knowledge_search '{"query":"x","tag":["a"]}')" \
  "$(kcall 6 knowledge_search '{"query":"x","extra":1}')" \
  "$(kcall 7 knowledge_get '{"id":""}')" \
  "$(kcall 8 knowledge_get '{"id":null}')" \
  "$(kcall 9 knowledge_list '{"type":3}')" \
  "$(kcall 10 knowledge_usage '{"all":"yes"}')" \
  "$(kcall 11 sessions_recent '{"limit":0}')" \
  "$(kcall 12 sessions_search '{"words":5}')" \
  "$(kcall 13 knowledge_search '[]')" \
  "$(kcall 14 knowledge_search 'null')")"
must "argument errors: a required argument" 'Invalid arguments'

t "the tokenizer, live, naming the code point"
if wanted "tokenizer sweep"; then
  for side in node rust; do
    reset_world
    "$NODE" "$GEN" sweep "$DOCS" "$TMP/scripts/sweep-steps.json" "$TMP/scripts/sweep-map.json" || { echo "rust-knowledge-parity: the sweep cannot be written" >&2; exit 2; }
    printf '[%s,%s]' "$(handshake)" "$(cat "$TMP/scripts/sweep-steps.json")" > "$TMP/scripts/sweep.json"
    run_session "$side" "$TMP/scripts/sweep.json" mcp || bad "tokenizer sweep: the driver failed on the $side server" "$(head -c 400 "$TMP/driver.$side" | tr '\n' '|')"
  done
  if ! cmp -s "$TMP/transcript.node" "$TMP/transcript.rust"; then
    request=$(diff "$TMP/transcript.node" "$TMP/transcript.rust" | grep -m1 -o '^[<>] answer [0-9]*' | grep -o '[0-9]*$')
    bad "tokenizer sweep: the transcripts differ at code point $("$NODE" "$GEN" locate "$TMP/scripts/sweep-map.json" "$request")" "$(first_difference "$TMP/transcript.node" "$TMP/transcript.rust" | sed '2,$s/^/       /')"
  else ok; fi
  must "tokenizer sweep: a code point is found" 'sweep'
  must "tokenizer sweep: a request per code point" "$(printf 'answer 1000\t')"
fi

# ------------------------------------------------------- one engine builds, the other reads ---
# cross <label> <mutator> <script A> <script B>: the reference is node building with script A and node reading with script B after the mutator changed the documents; each other pairing must read exactly what the reference read.
init_named() {  # <client name>
  local params="{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"$1\",\"version\":\"0\"}}"
  printf '%s,%s,%s' "$(req 1 initialize "$params")" "$(notify notifications/initialized)" "$(await 1)"
}
# What the programs left in the stores, read from outside: the rows of the index that say what was indexed, and the events of the usage store.
index_counter() { od -An -tu1 -j24 -N4 "$INDEX" 2>/dev/null | tr -d ' '; }
state_dump() {
  echo "index rows:"; sqlite3 -readonly "$INDEX" 'select id, mtime, hash from docs order by id' 2>&1
  echo "usage events:"; sqlite3 -readonly "$USAGE" 'select doc_id, kind, caller from usage_events order by doc_id, kind, caller, ts' 2>&1
}
cross() {
  local label=$1 mutator=$2 first=$3 second=$4 builder reader before
  wanted "$label" || return 0
  printf '[%s]\n' "$first" > "$TMP/scripts/first.json"; printf '[%s]\n' "$second" > "$TMP/scripts/second.json"
  for pair in "node node" "rust node" "node rust"; do
    set -- $pair; builder=$1; reader=$2
    reset_world
    run_session "$builder" "$TMP/scripts/first.json" mcp || { bad "$label: the driver failed on the $builder server" "$(head -c 300 "$TMP/driver.$builder" | tr '\n' '|')"; return 0; }
    $mutator
    run_session "$reader" "$TMP/scripts/second.json" mcp || { bad "$label: the driver failed on the $reader server" "$(head -c 300 "$TMP/driver.$reader" | tr '\n' '|')"; return 0; }
    state_dump >> "$TMP/transcript.$reader"
    cp "$TMP/transcript.$reader" "$TMP/read.$builder-$reader"
  done
  cp "$TMP/read.node-node" "$TMP/transcript.node"
  cp "$TMP/read.rust-node" "$TMP/transcript.rust"
  compare "$label: rust builds, node reads" || true
  cp "$TMP/read.node-rust" "$TMP/transcript.rust"
  compare "$label: node builds, rust reads"
}
edit_doc()   { printf '\nZyzzyva appended later.\n' >> "$DOCS/deploy-runbook.md"; touch -t 203001010000 "$DOCS/deploy-runbook.md"; }
touch_doc()  { touch -t 203001010000 "$DOCS/deploy-runbook.md"; }
delete_doc() { rm -f "$DOCS/deploy-runbook.md"; }
break_doc()  { printf -- '---\nid: [unclosed\n---\n' > "$DOCS/deploy-runbook.md"; }
nothing()    { :; }
old_usage()  { sqlite3 "$USAGE" "insert into usage_events (ts, doc_id, heading, kind, caller) values (1000, 'ancient-doc', '', 'get', 'old')"; }

t "one engine builds the index, the other reads it"
S1="$(handshake)"
SEARCHES="$(kcall 2 knowledge_search '{"query":"deploy"}'),$(kcall 3 knowledge_search '{"query":"zyzzyva"}'),$(kcall 4 knowledge_list '{}'),$(kcall 5 knowledge_get '{"id":"deploy-runbook"}')"
cross "cross-engine: an index nobody changed" nothing "$S1,$(kcall 2 knowledge_search '{"query":"deploy"}')" "$S1,$SEARCHES"
cross "cross-engine: an edited document" edit_doc "$S1,$(kcall 2 knowledge_search '{"query":"deploy"}')" "$S1,$SEARCHES"
must "cross-engine: the edit is found" '[Zyzzyva]'
cross "cross-engine: a touched document" touch_doc "$S1,$(kcall 2 knowledge_search '{"query":"deploy"}')" "$S1,$SEARCHES"
cross "cross-engine: a deleted document" delete_doc "$S1,$(kcall 2 knowledge_search '{"query":"deploy"}')" "$S1,$SEARCHES"
cross "cross-engine: a document broken" break_doc "$S1,$(kcall 2 knowledge_search '{"query":"deploy"}')" "$S1,$SEARCHES"
A="$(init_named alpha),$(kcall 2 knowledge_get '{"id":"deploy-runbook"}'),$(kcall 3 knowledge_get '{"id":"deploy-runbook"}')"
B="$(init_named beta),$(kcall 2 knowledge_get '{"id":"deploy-runbook"}'),$(kcall 3 knowledge_usage '{"all":true}')"
cross "cross-engine: usage recorded by one engine and counted by the other, two client names" nothing "$A" "$B"
must "usage: both client names count" '\"id\": \"deploy-runbook\",\n    \"type\": \"Runbook\",\n    \"status\": \"stable\",\n    \"gets\": 3,'
cross "cross-engine: events past the retention go when the next event is recorded" old_usage "$S1,$(kcall 2 knowledge_search '{"query":"deploy"}')" "$S1,$(kcall 2 knowledge_get '{"id":"deploy-runbook"}')"
must "retention: the new event is there" 'deploy-runbook|get|'
# The node server writes the schema version on every open; this one writes it only when it differs, so that a reader never waits for a write lock. The difference is listed in docs/architecture/rust-core.md, which is why this is asserted on the Rust side alone.
r_reader_writes_nothing() {
  local first second
  reset_world
  printf '[%s]\n' "$S1,$(kcall 2 knowledge_search '{"query":"deploy"}')" > "$TMP/scripts/first.json"
  printf '[%s]\n' "$S1,$(kcall 2 knowledge_list '{}')" > "$TMP/scripts/second.json"
  run_session rust "$TMP/scripts/first.json" mcp; first=$(index_counter)
  run_session rust "$TMP/scripts/second.json" mcp; second=$(index_counter)
  expect "a Rust reader of an index nobody changed writes nothing to it" "$first" "$second"
  [ -n "$first" ] && ok || bad "the index counter can be read" "no index at $INDEX"
}
if wanted "a Rust reader writes nothing"; then r_reader_writes_nothing; fi

# ------------------------------------------------------------------ the daemon ---
# A daemon scenario is a function that prints facts, read from outside: how many daemons run, which sockets exist, whether two serves were told the same socket. The sockets are named by a hash that differs between the programs, so the hash is masked.
DEXTRA=
dserve() {  # <side> <VAR=value ...> <serve arguments...>: `serve` of a side, in the world's environment with these variables set over it
  local side=$1 over=$2; shift 2
  server_command "$side" serve "$@"
  program_env
  env -i "${PENV[@]}" $over "${SERVER[@]}"
}
pidfiles() { find "$TMP" -name '*.pid' -type f 2>/dev/null; }
alive_daemons() {  # the pids of the pid files below the scratch directory that name a living daemon of this run
  local file pid
  for file in $(pidfiles); do
    pid=$(cat "$file" 2>/dev/null); case $pid in ''|*[!0-9]*) continue ;; esac
    ps -o command= -p "$pid" 2>/dev/null | grep -qF "$TMP" && echo "$pid"
  done
}
count_daemons() { alive_daemons | wc -l | tr -d ' '; }
count_sockets() { find "$TMP" -name '*.sock' 2>/dev/null | wc -l | tr -d ' '; }
count_pidfiles() { pidfiles | wc -l | tr -d ' '; }
wait_no_daemon() {  # up to 12 seconds
  local i=0
  while [ "$i" -lt 60 ]; do [ "$(count_daemons)" = 0 ] && return 0; sleep 0.2; i=$((i + 1)); done
  return 1
}
stop_all() {
  local pid
  for pid in $(alive_daemons); do kill -TERM "$pid" 2>/dev/null; done
  wait_no_daemon || for pid in $(alive_daemons); do kill -KILL "$pid" 2>/dev/null; done
  rm -rf "$TMP/tmp2" "$TMP/world2"
}
mask() { sed -e 's/knowledge-[0-9a-f]\{12\}/knowledge-H/g'; }
socket_client() { "${ALARMED[@]}" "$NODE" "$GEN" client "$@"; }  # <socket> [connected file]
# daemon_scenario <label> <function>: the function runs for each side with $SIDE set, in a world from scratch; its output is the transcript.
daemon_scenario() {
  local label=$1 fn=$2
  wanted "$label" || return 0
  for SIDE in node rust; do
    stop_all; reset_world; mkdir -p "$TMP/world2/docs"; cp "$DOCS"/*.md "$TMP/world2/docs/"
    "$fn" 2>&1 | mask > "$TMP/transcript.$SIDE"
    stop_all
  done
  compare "$label"
}
same() { [ "$1" = "$2" ] && echo yes || echo no; }

d_one_daemon() {
  local a b
  a=$(dserve "$SIDE" ""); b=$(dserve "$SIDE" "")
  echo "same socket: $(same "$a" "$b")"; echo "daemons: $(count_daemons)"; echo "sockets: $(count_sockets)"
  echo "socket directory mode: $(mode_of "$(dirname "$a")")"
  echo "socket: $a"
}
d_two_folders() {
  local a b
  a=$(dserve "$SIDE" ""); b=$(dserve "$SIDE" "TAGENTS_KNOWLEDGE_DIR=$TMP/world2/docs")
  echo "same socket: $(same "$a" "$b")"; echo "daemons: $(count_daemons)"
}
d_two_usage_stores() {
  local a b
  a=$(dserve "$SIDE" ""); b=$(dserve "$SIDE" "TAGENTS_KNOWLEDGE_USAGE_DB=$TMP/world2/usage.sqlite")
  echo "same socket: $(same "$a" "$b")"; echo "daemons: $(count_daemons)"
}
d_relative_usage_store() {
  local a b c
  mkdir -p "$TMP/cwd-a" "$TMP/cwd-b"
  a=$(cd "$TMP/cwd-a" && dserve "$SIDE" "TAGENTS_KNOWLEDGE_USAGE_DB=rel.sqlite")
  b=$(cd "$TMP/cwd-a" && dserve "$SIDE" "TAGENTS_KNOWLEDGE_USAGE_DB=rel.sqlite")
  c=$(cd "$TMP/cwd-b" && dserve "$SIDE" "TAGENTS_KNOWLEDGE_USAGE_DB=rel.sqlite")
  echo "same folder, same socket: $(same "$a" "$b")"; echo "other folder, same socket: $(same "$a" "$c")"; echo "daemons: $(count_daemons)"
  rm -rf "$TMP/cwd-a" "$TMP/cwd-b"
}
d_other_tmpdir() {
  local a b
  mkdir -p "$TMP/tmp2"
  a=$(dserve "$SIDE" ""); b=$(dserve "$SIDE" "TMPDIR=$TMP/tmp2")
  echo "same socket: $(same "$a" "$b")"; echo "daemons: $(count_daemons)"
  echo "second socket under: ${b#"$TMP"/}" | sed -e 's#/tagents-[0-9]*/.*##'
}
d_variable_not_read() {
  local a b
  a=$(dserve "$SIDE" ""); b=$(dserve "$SIDE" "SOMETHING_THE_SERVER_NEVER_READS=1")
  echo "same socket: $(same "$a" "$b")"; echo "daemons: $(count_daemons)"
}
d_dead_socket_four_proxies() {
  local sock pid i
  sock=$(dserve "$SIDE" "")
  pid=$(alive_daemons | head -1)
  kill -KILL "$pid"; wait_no_daemon
  echo "socket file left behind: $([ -S "$sock" ] && echo yes || echo no)"
  for i in 1 2 3 4; do dserve "$SIDE" "" > "$TMP/proxy.$i" & done
  wait
  echo "the four were told the same socket: $(same "$(cat "$TMP/proxy.1")" "$(cat "$TMP/proxy.2")")$(same "$(cat "$TMP/proxy.1")" "$(cat "$TMP/proxy.3")")$(same "$(cat "$TMP/proxy.1")" "$(cat "$TMP/proxy.4")")"
  echo "daemons: $(count_daemons)"
  echo "the socket answers: $(printf '' | socket_client "$(cat "$TMP/proxy.1")" >/dev/null 2>&1 && echo yes || echo no)"
}
d_held_client_idle() {
  local sock
  sock=$(dserve "$SIDE" "" --idle 2)
  (sleep 5 | socket_client "$sock" > /dev/null 2>&1) &
  sleep 4
  echo "while a client is connected: $(count_daemons)"
  wait
  wait_no_daemon
  echo "after it left: $(count_daemons) daemons, $(count_pidfiles) pid files"
}
# A session that reaches the socket while the daemon cannot run waits in the backlog, and the daemon runs again past its idle time with a connection it has not counted. The connection is counted before the decision to leave, so the session is served and the daemon stays for it.
d_backlog_past_idle() {
  local sock pid i=0
  # The idle time is what a loaded machine has to reach the daemon before it leaves; the stop runs past it whenever the stop began.
  sock=$(dserve "$SIDE" "" --idle 5)
  sleep 0.3  # the connection of `serve` itself has ended
  pid=$(alive_daemons)
  if [ -z "$pid" ]; then echo "the daemon left before it could be stopped"; return 1; fi
  kill -STOP "$pid"
  sleep 6
  ({ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"parity","version":"1"}}}'; while [ ! -e "$TMP/leave.$SIDE" ]; do sleep 0.1; done; } | socket_client "$sock" "$TMP/connected.$SIDE" > "$TMP/answer.$SIDE" 2> /dev/null) &
  while [ ! -e "$TMP/connected.$SIDE" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  kill -CONT "$pid"
  i=0
  while ! grep -q '"id":1' "$TMP/answer.$SIDE" && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
  echo "answered: $(grep -c '"id":1' "$TMP/answer.$SIDE")"
  echo "while it is connected: $(count_daemons)"
  : > "$TMP/leave.$SIDE"
  wait
  wait_no_daemon
  echo "after it left: $(count_daemons) daemons, $(count_pidfiles) pid files"
}
d_nobody_connects() {
  dserve "$SIDE" "" --idle 1 > /dev/null
  echo "at the start: $(count_daemons)"
  wait_no_daemon
  echo "later: $(count_daemons) daemons, $(count_pidfiles) pid files"
}
d_clean_exit() {
  local sock pid
  sock=$(dserve "$SIDE" "")
  pid=$(alive_daemons | head -1)
  kill -TERM "$pid"; wait_no_daemon
  echo "daemons: $(count_daemons), sockets: $(count_sockets), pid files: $(count_pidfiles)"
  echo "socket directory kept: $([ -d "$(dirname "$sock")" ] && echo yes || echo no)"
}
d_start_after_clean_exit() {
  local a b
  a=$(dserve "$SIDE" ""); kill -TERM "$(alive_daemons | head -1)"; wait_no_daemon
  b=$(dserve "$SIDE" "")
  echo "same socket: $(same "$a" "$b")"; echo "daemons: $(count_daemons)"
}

t "the daemon"
daemon_scenario "daemon: two serves, one daemon, a private socket directory" d_one_daemon
must "daemon: one daemon" 'daemons: 1'
must "daemon: the directory is private" 'socket directory mode: 700'
daemon_scenario "daemon: two folders, two daemons" d_two_folders
must "daemon: two daemons" 'daemons: 2'
daemon_scenario "daemon: two usage stores, two daemons" d_two_usage_stores
must "daemon: two usage stores" 'daemons: 2'
daemon_scenario "daemon: a relative usage store belongs to the folder it was named from" d_relative_usage_store
must "daemon: a relative store" 'other folder, same socket: no'
daemon_scenario "daemon: another TMPDIR, another daemon" d_other_tmpdir
must "daemon: another TMPDIR" 'daemons: 2'
daemon_scenario "daemon: a variable the server does not read changes nothing" d_variable_not_read
must "daemon: an unread variable" 'same socket: yes'
daemon_scenario "daemon: four proxies meeting a dead socket start one daemon" d_dead_socket_four_proxies
must "daemon: a dead socket" 'socket file left behind: yes'
must "daemon: four proxies, one daemon" 'daemons: 1'
daemon_scenario "daemon: a held-open client keeps it past its idle time" d_held_client_idle
must "daemon: held open" 'while a client is connected: 1'
# Asserted on the Rust side alone: the node daemon closes such a session with no reply (the difference is listed in docs/architecture/rust-core.md).
if wanted "daemon: a session in the backlog past the idle time is served"; then
  SIDE=rust; stop_all; reset_world
  expect "daemon: a session in the backlog past the idle time is served" "$(d_backlog_past_idle 2>&1)" 'answered: 1
while it is connected: 1
after it left: 0 daemons, 0 pid files'
  stop_all
fi
daemon_scenario "daemon: nobody connects and it leaves" d_nobody_connects
must "daemon: starts" 'at the start: 1'
daemon_scenario "daemon: a clean exit removes the socket and the pid file" d_clean_exit
must "daemon: clean exit" 'daemons: 0, sockets: 0, pid files: 0'
daemon_scenario "daemon: started again after a clean exit" d_start_after_clean_exit
must "daemon: again" 'daemons: 1'

# A connection that sends garbage, then a session through the socket as a proxy runs it.
d_garbage_then_a_client() {
  local sock
  sock=$(dserve "$SIDE" "")
  printf 'garbage\n{{{\n\0\377' | socket_client "$sock" > /dev/null 2>&1
  echo "daemons after the garbage: $(count_daemons)"
  printf '%s\n' "$sock" > "$TMP/sock.$SIDE"
}
if wanted "daemon: garbage, then a real client"; then
  printf '[%s,%s,%s,%s]\n' "$(handshake | sed 's/^\[//; s/\]$//')" "$(kcall 2 knowledge_search '{"query":"deploy"}')" "$(kcall 3 knowledge_list '{}')" "$(kcall 4 sessions_recent '{}')" > "$TMP/scripts/socket.json"
  for SIDE in node rust; do
    stop_all; reset_world
    d_garbage_then_a_client 2>&1 | mask > "$TMP/facts.$SIDE"
    program_env
    env -i "${PENV[@]}" PARITY_DIR="$W" "$NODE" "$MCP_DRIVER" run "$TMP/scripts/socket.json" "$W" -- "$NODE" "$GEN" client "$(cat "$TMP/sock.$SIDE")" > "$TMP/raw.$SIDE" 2> "$TMP/driver.$SIDE" || bad "daemon: garbage, then a real client: the driver failed on the $SIDE socket" "$(head -c 300 "$TMP/driver.$SIDE" | tr '\n' '|')"
    { cat "$TMP/facts.$SIDE"; norm "$TMP/raw.$SIDE" | sed -e "s#$TMP/world/#WORLD/#g"; echo "daemons at the end: $(count_daemons)"; } > "$TMP/transcript.$SIDE"
    stop_all
  done
  compare "daemon: garbage, then a real client"
  must "daemon: the client is answered after the garbage" "$(printf 'answer 2\t')"
  must "daemon: the garbage ended nothing" 'daemons after the garbage: 1'
fi

# ------------------------------------------------------------------ join ---
# `join` is what a session runs in place of `knowledge mcp`: the client sees what the node server's stdio says, whether a daemon serves it or the relay serves in process. The node counterpart of the relay is `nc`, which does not retry, so what the relay does around a daemon that goes away is asserted on the Rust side alone.
join_session() {  # <label> <VAR=value ...>: node's `mcp` against Rust's `join`, the second in an environment with these variables set over the world's
  local label=$1 over=$2 side
  wanted "$label" || return 0
  printf '[%s]\n' "$(handshake),$(kcall 2 knowledge_search '{"query":"deploy"}'),$(kcall 3 knowledge_get '{"id":"deploy-runbook"}'),$(kcall 4 knowledge_list '{}')" > "$TMP/scripts/join.json"
  for side in node rust; do
    stop_all; reset_world; mkdir -p "$TMP/tmp"
    program_env
    if [ "$side" = node ]; then SERVER=("$NODE" "$KJS" mcp); else SERVER=("$RUST_ABS" join); fi
    env -i "${PENV[@]}" $( [ "$side" = rust ] && echo "$over" ) PARITY_DIR="$W" "$NODE" "$MCP_DRIVER" run "$TMP/scripts/join.json" "$W" -- "${SERVER[@]}" > "$TMP/raw.$side" 2> "$TMP/driver.$side" || { bad "$label: the driver failed on the $side server" "$(head -c 300 "$TMP/driver.$side" | tr '\n' '|')"; stop_all; return 0; }
    norm "$TMP/raw.$side" > "$TMP/transcript.$side"
    JOIN_LEFT="daemons: $(count_daemons), pid files: $(count_pidfiles)"  # the last side is Rust
    stop_all
  done
  compare "$label"
}
t "join"
join_session "join: a session through a daemon answers what mcp answers" ""
must "join: answered" "$(printf 'answer 4\t')"
expect "join: a daemon served it and stays" "${JOIN_LEFT:-}" "daemons: 1, pid files: 1"
# A directory below a regular file cannot be made, so no socket directory exists and the relay serves the session itself. A missing directory would not do: `ensure_private_dir` makes every parent.
: > "$TMP/not-a-directory"
join_session "join: no daemon can start, the relay serves in process" "TMPDIR=$TMP/not-a-directory/below"
must "join without a daemon: answered" "$(printf 'answer 4\t')"
expect "join without a daemon: none was started" "${JOIN_LEFT:-}" "daemons: 0, pid files: 0"

j_input_ends() {
  local err code
  stop_all; reset_world; program_env
  err=$(env -i "${PENV[@]}" "${ALARMED[@]}" "$RUST_ABS" join < /dev/null 2>&1 > /dev/null); code=$?
  expect "join: input that ends at once is exit 0 and silence" "$code:$err" "0:"
}
j_daemon_dies_mid_session() {
  local code err
  stop_all; reset_world; program_env
  : > "$TMP/out"
  {
    echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"parity","version":"0"}}}'
    i=0; while [ ! -s "$TMP/out" ] && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
    for pid in $(alive_daemons); do kill -KILL "$pid"; done
    wait_no_daemon
    echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    sleep 5
  } | env -i "${PENV[@]}" "${ALARMED[@]}" "$RUST_ABS" join > "$TMP/out" 2> "$TMP/err"
  code=${PIPESTATUS[1]}
  err=$(cat "$TMP/err")
  expect "join: a daemon that dies after the first reply ends the session with exit 1" "$code" "1"
  case $err in *"went away"*) ok ;; *) bad "join: the daemon's departure is said on stderr" "stderr: $err" ;; esac
  stop_all
}
if wanted "join: input ends"; then j_input_ends; fi
if wanted "join: the daemon dies mid-session"; then j_daemon_dies_mid_session; fi

# ----------------------------------------------------------------- the verbs that read the folder ---
# A scenario is a function that runs the program of a side (`cli`) on a world of its own. What each call said (the words, the exit code, stdout, stderr) is appended to the transcript of the side, and the two transcripts must be the same bytes.
SIDE=
cli() {  # <words...>
  local out=$TMP/cli.out err=$TMP/cli.err code
  if [ "$SIDE" = node ]; then CMD=("$NODE" "$KJS_CLI" "$@"); else CMD=("$RUST_ABS" "$@"); fi
  env -i "${PENV[@]}" ${CLI_ENV[@]+"${CLI_ENV[@]}"} "${ALARMED[@]}" "${CMD[@]}" > "$out" 2> "$err" < /dev/null
  code=$?
  { printf '$ %s\nexit %s\n--- stdout\n' "$*" "$code"; cat "$out"; printf -- '--- stderr\n'; cat "$err"; printf '\n'; } >> "$TMP/transcript.$SIDE"
}
# The environment of the next calls: extra variables, and the ones of the world to drop.
CLI_ENV=()
without() {  # <name...>: drops the variables from the environment of the next calls
  local keep=() v drop name
  for v in "${PENV[@]}"; do
    drop=
    for name in "$@"; do case $v in "$name="*) drop=1 ;; esac; done
    [ -n "$drop" ] || keep+=("$v")
  done
  PENV=("${keep[@]}")
}
scenario() {  # <label> <function>: the function runs once per side
  local label="verbs: $1" fn=$2
  wanted "$label" || return 0
  for SIDE in node rust; do
    reset_world; program_env; CLI_ENV=(); : > "$TMP/transcript.$SIDE"
    "$fn"
  done
  compare "$label"
}
saw() {  # <label> <needle>: the node transcript holds what the scenario exists to provoke
  [ -n "$RAN" ] || return 0
  if grep -qF -- "$2" "$TMP/transcript.node"; then ok; else bad "tripwire $1: node did not say what this scenario expects" "wanted: $2"; fi
}

t "verbs: usage and the refusals of the command line"
sc_usage() { cli; cli help; cli --help; cli -h; cli bogus; cli index --bogus; cli index extra; cli index --dir; cli search; cli search '  '; cli show; cli show '   '; cli list extra; cli lint --full; cli toc --check=1; cli usage --since; }
scenario "usage text, help, an unknown verb and bad options" sc_usage
saw "usage text" 'usage: tagents-knowledge <command>'
saw "an unknown verb" 'unknown command: bogus'

t "verbs: no folder, a missing folder"
sc_nodir() { without TAGENTS_KNOWLEDGE_DIR; for v in index "search x" "show x" list lint toc usage; do cli $v; done; }
scenario "no knowledge directory" sc_nodir
sc_missingdir() { for v in index "search x" "show x" list lint toc usage; do cli $v --dir "$TMP/not-here"; done; CLI_ENV=(TAGENTS_KNOWLEDGE_DIR="$TMP/also-not-here"); cli list; }
scenario "a missing knowledge directory" sc_missingdir

t "verbs: index"
CORPUS=both; EXTRAS=1
sc_index() { cli index; cli index; cli index --full; touch "$DOCS/cafe-notes.md"; cli index; printf -- '---\ntype: note\n---\n\nnew\n' > "$DOCS/fresh-one.md"; cli index; cli index --db "$TMP/world/other.sqlite"; cli index --dir "$DOCS" --db "$TMP/world/third.sqlite" --full; }
scenario "index: new, changed, unchanged, full, --db" sc_index
BAD=1
sc_index_bad() { cli index; cli index --full; }
scenario "index: files that do not parse" sc_index_bad
BAD=; EXTRAS=

t "verbs: search"
CORPUS=both; EXTRAS=1
sc_search() {
  cli search cafe; cli search naive resume zoe; cli search marmalade; cli search 'depl*'; cli search sqlite
  cli search runbook --tag ops; cli search runbook --type Runbook; cli search runbook --kind runbook
  cli search the --limit 2; cli search the --limit 0; cli search the --limit -1; cli search the --limit abc; cli search the --limit 2.5; cli search the --limit=3
  cli search '"unterminated'; cli search nothing-matches-this-zzz; cli search --json nothing-matches-this-zzz
  cli search --json marmalade; cli search --json cafe --limit 1; cli search --json the --tag ops
  cli search --usage-db "$TMP/world/other-usage.sqlite" cafe --verbose; cli search cafe --db "$TMP/world/other.sqlite"
  cli usage --json; cli usage
}
scenario "search: queries, filters, limits, --json, --usage-db" sc_search
sc_search_usage_broken() { mkdir "$TMP/world/store-dir"; cli search cafe --usage-db "$TMP/world/store-dir" --verbose; cli search cafe --usage-db "$TMP/world/store-dir"; cli show cafe-notes --usage-db "$TMP/world/store-dir" --verbose; }
scenario "search and show: a usage store that cannot take the events" sc_search_usage_broken

t "verbs: show"
sc_show() {
  cli show deploy-runbook; cli show deploy-runbook#Deploy; cli show 'deploy-runbook#deploy'; cli show deploy-runbook#; cli show 'deploy-runbook#Nope'; cli show no-such-doc; cli show no-such-doc#x
  cli show okf-none; cli show backup-runbook; printf 'no newline at the end' > "$DOCS/bare.md"; cli index; cli show bare
  rm "$DOCS/cafe-notes.md"; cli show cafe-notes; cli usage --all --json
}
scenario "show: a document, a section, case, misses" sc_show

t "verbs: list"
sc_list() { cli list; cli list --json; cli list --type Runbook; cli list --kind runbook; cli list --tag ops; cli list --tag ops --json; cli list --tag nothing; cli list --tag nothing --json; cli list --db "$TMP/world/other.sqlite"; }
scenario "list: lines, --json, filters, nothing" sc_list
sc_list_stale() { printf -- '---\ntype: note\nstale_after: 2020-01-01T00:00:00Z\ngenerated: {by: me, at: "2026-03-04T05:06:07+03:00"}\ntags: [a, b]\n---\n\nbody\n' > "$DOCS/aged.md"; cli list; cli list --json; cli search aged; cli search --json body; }
scenario "list and search: the stale mark, tags and generated.at" sc_list_stale
sc_list_empty() { rm -f "$DOCS"/*.md; cli list; cli list --json; cli search x; cli usage; cli lint; cli toc; cli show x; }
scenario "an empty folder" sc_list_empty
CORPUS=knowledge; EXTRAS=

t "verbs: lint and toc"
CORPUS=both; EXTRAS=1; BAD=1
sc_lint() { cli lint; cli lint --dir "$DOCS"; cli toc; cli lint; cli toc --check; }
scenario "lint: every rule of the profile, dead links, sources, expired" sc_lint
BAD=
sc_lint_clean() { cli lint; cli toc; cli lint; cli toc --check; printf -- '---\ntype: note\n---\n\nbody\n' > "$DOCS/more.md"; cli lint; cli toc --check; cli toc; cli toc --check; }
scenario "lint and toc: clean, then out of date" sc_lint_clean
sc_lint_git() {
  ( cd "$DOCS" || exit
    git -c init.defaultBranch=main init -q . ; git config user.email a@b.c; git config user.name n
    printf -- '---\ntype: note\ngenerated: {by: me, at: "2020-01-01T00:00:00Z"}\n---\n\nbody\n' > old-claim.md
    git add -A; GIT_COMMITTER_DATE='2030-05-06T07:08:09+00:00' GIT_AUTHOR_DATE='2030-05-06T07:08:09+00:00' git commit -q -m c ) > /dev/null 2>&1
  cli toc; cli lint
}
scenario "lint: generated.at older than the last commit" sc_lint_git
sc_toc() { cli toc --check; cli toc; cat "$DOCS/index.md" >> "$TMP/transcript.$SIDE"; cli toc --check; printf -- '---\ntype: "Weird [type]"\ntitle: "Plan ] draft [x]"\ndescription: "two\n  lines   here"\nstatus: deprecated\n---\n\nbody\n' > "$DOCS/weird.md"; cli toc; cat "$DOCS/index.md" >> "$TMP/transcript.$SIDE"; rm -f "$DOCS"/*.md; cli toc; cat "$DOCS/index.md" >> "$TMP/transcript.$SIDE"; cli toc --check; }
scenario "toc: the file, --check, brackets, an empty folder" sc_toc
BAD=1
sc_toc_bad() { cli toc; cli toc --check; cat "$DOCS/index.md" >> "$TMP/transcript.$SIDE"; }
scenario "toc: files that do not load" sc_toc_bad
BAD=; CORPUS=knowledge; EXTRAS=

t "verbs: usage"
CORPUS=both; EXTRAS=1
sc_usage_report() {
  cli usage; cli usage --json; cli show deploy-runbook; cli show deploy-runbook#Deploy; cli show deploy-runbook#Deploy; cli search deploy; cli search cafe --json
  cli usage; cli usage --json; cli usage --candidates; cli usage --candidates --min-gets 1 --min-days 1; cli usage --candidates --min-gets 1 --min-days 1 --json
  cli usage --type Runbook --json; cli usage --top 2; cli usage --top 1 --json; cli usage --since 1d; cli usage --since 365d --json
  cli usage --all; rm "$DOCS/deploy-runbook.md"; cli usage --all
  cli usage --usage-db "$TMP/world/nothing.sqlite"; cli usage --usage-db "$TMP/world/nothing.sqlite" --json
}
scenario "usage: counts, filters, windows, --all, --candidates" sc_usage_report
sc_usage_bad() {
  cli usage --since 30; cli usage --since d; cli usage --since 0d; cli usage --since -3d; cli usage --since 1.5d
  cli usage --top 0; cli usage --top abc; cli usage --top 1.5; cli usage --min-gets 0; cli usage --min-days x
  cli usage --top 9007199254740993; cli usage --top 9007199254740991
}
scenario "usage: values that are not counts" sc_usage_bad
sc_usage_store() {
  mkdir "$TMP/world/store-dir"; cli usage --usage-db "$TMP/world/store-dir"
  printf 'not a database, not even close to one, at all.' > "$TMP/world/garbage.sqlite"; cli usage --usage-db "$TMP/world/garbage.sqlite"
  sqlite3 "$TMP/world/empty.sqlite" 'create table other (x)'; cli usage --usage-db "$TMP/world/empty.sqlite"
}
scenario "usage: a store that cannot be read or has no table" sc_usage_store
CORPUS=knowledge; EXTRAS=

t "verbs: the locale"
sc_locale() { CLI_ENV=(TAGENTS_LOCALE=ru); cli; cli bogus; cli search; cli show; cli list --tag nothing; cli lint; cli toc --check; cli usage --since 1; }
scenario "the Russian texts" sc_locale


# The text a YAML parser gives for a document it cannot read is the parser's own, so the two sides are held to the shape of the line and the exit code, not to the words after the colon.
if wanted "verbs: a front matter that is not YAML"; then
  for SIDE in node rust; do
    reset_world; program_env; CLI_ENV=(); : > "$TMP/transcript.$SIDE"
    printf -- '---\nfoo: [unclosed\n---\n\nbody\n' > "$DOCS/bad-yaml.md"
    cli lint; cli index; cli toc
    sed -n -e '/^\$ /p' -e '/^exit /p' -e 's/\(bad-yaml.md: [a-z ]*frontmatter is not YAML:\).*/\1/p' "$TMP/transcript.$SIDE" > "$TMP/shape.$SIDE"
  done
  if cmp -s "$TMP/shape.node" "$TMP/shape.rust" && grep -q 'frontmatter is not YAML:' "$TMP/shape.rust"; then ok; else bad "verbs: a front matter that is not YAML" "$(first_difference "$TMP/shape.node" "$TMP/shape.rust")"; fi
fi

printf '\nrust-knowledge-parity: %d passed, %d failed, %d scenarios skipped\n' "$pass" "$fail" "$SKIPPED"
[ "$fail" -eq 0 ]
