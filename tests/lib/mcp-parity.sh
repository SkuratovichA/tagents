# tests/lib/mcp-parity.sh — what the parity suites of the two MCP servers (tests/rust-mcp-parity.sh and tests/rust-knowledge-parity.sh) share beside tests/lib/parity.sh: the steps of a script for tests/rust-mcp-parity-driver.mts, the comparison of two transcripts and the tripwires that look at the node transcript.
#
# These stay out of tests/lib/parity.sh because they differ from those of tests/rust-notify-parity.sh: `file`, `gone` and `quiet` write this driver's shape of a step, `jstr` leaves a newline, a tab and a carriage return as they are, `first_difference` names the key of the line, and `must` and `must_before` word their failures in their own way.
# A suite sets $TMP (where transcripts are written) and $W (the directory of the pids and markers), and sources tests/lib/parity.sh and then this file.
#
# bash 3.2.

# The steps of a script (`steps` is in tests/lib/parity.sh). Ids are plain numbers or strings written the way JSON writes them.
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
session() { steps "$(handshake)" "$@"; }   # a handshake, then the steps
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
