#!/usr/bin/env bash
#
# tests/rust-parity.sh — the Rust front door prints what the node CLI prints.
#
# Every case runs twice, `node packages/core/dist/cli/main.js <args>` and `target/debug/tagents-core <args>` (or $TAGENTS_CORE_BIN), under the same
# `env -i` environment pointed at scratch homes, and passes only when stdout, stderr and the exit code are byte for byte the same.
# The homes come from tests/rust-parity-seed.mts: the two sessions of the checked-in fixtures, and about 600 more built so that
# JavaScript and a naive port disagree (UTF-16 lengths, white space, JSON.parse, rounding, sort order, case folding, windows, file kinds).
# A few "tripwire" cases assert on the node output alone, so a seed that silently stopped provoking a divergence fails here instead of passing for nothing.
#
# Needs a built node CLI (pnpm build) and python3 (the seed sets exact mtimes). Uses no real home, no tmux, no network. bash 3.2.

set -o pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd -P)
NODE=${TAGENTS_NODE:-$(command -v node)}
CORE_JS="$REPO/packages/core/dist/cli/main.js"
RUST=${TAGENTS_CORE_BIN:-$REPO/target/debug/tagents-core}
FIXTURES="$REPO/packages/core/test/fixtures/sessions"

[ -n "$NODE" ] && [ -x "$NODE" ] || { echo "rust-parity: no node to run (set TAGENTS_NODE)" >&2; exit 2; }
[ -f "$CORE_JS" ] || { echo "rust-parity: $CORE_JS is not built; run: pnpm install && pnpm build" >&2; exit 2; }
if [ ! -x "$RUST" ]; then
  if [ -n "${TAGENTS_CORE_BIN:-}" ]; then echo "rust-parity: $RUST is not an executable" >&2; exit 2; fi
  (cd "$REPO" && cargo build -p tagents-core >&2) || { echo "rust-parity: cargo build failed" >&2; exit 2; }
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/tagents-parity.XXXXXX") || exit 2
TMP=$(cd "$TMP" && pwd -P) || exit 2
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM

mkdir "$TMP/seed" "$TMP/state" "$TMP/config" "$TMP/empty-home"
"$NODE" "$HERE/rust-parity-seed.mts" "$TMP/seed" || { echo "rust-parity: seeding failed" >&2; exit 2; }
SEED="$TMP/seed"
ADV="$SEED/adversarial"

pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() {  # <label> <detail...>
  fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; shift
  [ $# -gt 0 ] && printf '       %s\n' "$@"
}

# The environment of one run. Nothing of the caller's shell is inherited.
ENVV=()
CWD=
use() {  # <home-name>
  CWD=
  local base="PATH=$(dirname "$NODE"):/usr/bin:/bin" lang="LANG=en_US.UTF-8" tz="TZ=UTC"
  ENVV=("$base" "$lang" "$tz" "TA_STATE_DIR=$TMP/state" "TAGENTS_CONFIG_DIR=$TMP/config")
  case $1 in
    fixture) ENVV+=("HOME=$SEED/fixture" "CLAUDE_HOMES=$SEED/fixture/.claude") ;;
    adv) ENVV+=("HOME=$ADV" "CLAUDE_HOMES=$ADV/.claude,$ADV/.claude-work/,$ADV/.claude-averyverylongaccountname,$ADV/.claude-😀x,$ADV/.claude-a.b_c") ;;
    disc) ENVV+=("HOME=$ADV") ;;
    commas) ENVV+=("HOME=$ADV" "CLAUDE_HOMES=,") ;;
    blank) ENVV+=("HOME=$ADV" "CLAUDE_HOMES=") ;;
    spaces) ENVV+=("HOME=$ADV" "CLAUDE_HOMES= ,,  $(printf '\xc2\xa0')$ADV/.claude$(printf '\xef\xbb\xbf') , ") ;;
    dots) ENVV+=("HOME=$ADV" "CLAUDE_HOMES=$ADV/x/../.claude,$ADV//.claude-work/./") ;;
    nohome) ENVV+=("HOME=" "CLAUDE_HOMES=$ADV/.claude") ;;
    empty) ENVV+=("HOME=$TMP/empty-home") ;;
    missing) ENVV+=("HOME=$TMP/does-not-exist") ;;
    locked) ENVV+=("HOME=$SEED/locked" "CLAUDE_HOMES=$SEED/locked/.claude") ;;
    rel) ENVV+=("HOME=$ADV" "CLAUDE_HOMES=$(printf '\xc2\x85')"); CWD=$SEED/relative ;;
    tz) ENVV+=("HOME=$ADV" "CLAUDE_HOMES=$ADV/.claude" "TZ=Asia/Kolkata" "LANG=C" "LC_ALL=C") ;;
    *) echo "rust-parity: no home called $1" >&2; exit 2 ;;
  esac
}

run() {  # <tag> <program words...> -- the arguments are in ARGS
  local tag=$1; shift
  ( [ -z "$CWD" ] || cd "$CWD" || exit 2; exec env -i "${ENVV[@]}" "$@" "${ARGS[@]}" ) > "$TMP/out.$tag" 2> "$TMP/err.$tag"
  echo $? > "$TMP/code.$tag"
}

parity() {  # <label> <home-name> <args...>
  local label=$1 home=$2; shift 2
  use "$home"; ARGS=("$@")
  run node "$NODE" "$CORE_JS"
  run rust "$RUST"
  compare "$label ($home)"
}

compare() {  # <label>
  local what=()
  cmp -s "$TMP/out.node" "$TMP/out.rust" || what+=("stdout")
  cmp -s "$TMP/err.node" "$TMP/err.rust" || what+=("stderr")
  cmp -s "$TMP/code.node" "$TMP/code.rust" || what+=("exit code")
  if [ ${#what[@]} -eq 0 ]; then ok; return; fi
  bad "$1: differs in ${what[*]}" \
    "args: $(printf '%q ' "${ARGS[@]}")" \
    "exit node=$(cat "$TMP/code.node") rust=$(cat "$TMP/code.rust")" \
    "stdout: $(cmp "$TMP/out.node" "$TMP/out.rust" 2>&1 | head -1)" \
    "stderr node: $(head -c 200 "$TMP/err.node" | tr '\n' '|')" \
    "stderr rust: $(head -c 200 "$TMP/err.rust" | tr '\n' '|')"
}

# A tripwire: the node output alone must contain a string (given as printf escapes).
node_says() {  # <label> <home-name> <printf-escaped needle> <args...>
  local label=$1 home=$2 needle needle_esc=$3; shift 3
  needle=$(printf "$needle_esc")
  use "$home"; ARGS=("$@")
  run node "$NODE" "$CORE_JS"
  if grep -qF -- "$needle" "$TMP/out.node" "$TMP/err.node"; then ok; else bad "tripwire $label: node did not print the string this case exists to provoke" "wanted: $needle_esc"; fi
}

t() { printf '\n%s\n' "$1"; }

# ------------------------------------------------------------------ fixtures ---
t "the checked-in fixtures: both programs, and the files themselves"
parity "sessions" fixture sessions
parity "sessions recent" fixture sessions recent
parity "sessions recent 1" fixture sessions recent 1
parity "sessions search deploy" fixture sessions search deploy
parity "sessions search miss" fixture sessions search zzzznothing
parity "sessions search (no words)" fixture sessions search
parity "sessions show prefix" fixture sessions show aaaaaaaa
parity "sessions show (no prefix)" fixture sessions show
parity "sessions show unknown" fixture sessions show nosuchsession
parity "sessions unknown subcommand" fixture sessions bogus
for pair in "recent:sessions recent" "recent-1:sessions recent 1" "search-deploy:sessions search deploy" "search-miss:sessions search zzzznothing" "show:sessions show aaaaaaaa"; do
  name=${pair%%:*}; words=${pair#*:}
  use fixture; ARGS=($words)
  run rust "$RUST"
  if cmp -s "$TMP/out.rust" "$FIXTURES/$name.txt"; then ok; else bad "fixture $name.txt: the Rust output is not the recorded bytes" "$(cmp "$TMP/out.rust" "$FIXTURES/$name.txt" 2>&1 | head -1)"; fi
done

# ------------------------------------------------------------------ tripwires ---
t "tripwires: the seed still provokes what it was written to provoke"
node_says "half a millisecond below zero rounds up in JavaScript" adv '1969-12-31T23:59:59.000Z' sessions show time-neg-half
node_says "half a millisecond above zero rounds up" adv '1970-01-01T00:00:01.001Z' sessions show time-pos-half
node_says "a cut inside a surrogate pair prints U+FFFD (listing, 150)" adv 'a\xef\xbf\xbd\n' sessions search tail
node_says "a cut inside a surrogate pair prints U+FFFD (show, 1500)" adv 'b\xef\xbf\xbd' sessions show emoji-cut-1500
node_says "U+0085 is not white space in JavaScript" adv '\xc2\x85nel lead' sessions show ws-nel
node_says "a number that overflows a float does not stop JSON.parse" adv 'line with 1e999 in it' sessions show json-overflow
node_says "30000 levels of nesting do not stop JSON.parse" adv 'thirty thousand levels' sessions show json-deep
node_says "a lone surrogate escape does not stop JSON.parse" adv 'lone ' sessions show json-lone-surrogate
node_says "the 400th session is searched" adv 'scanlast' sessions search scanlast
node_says "the 401st session is not" adv 'nothing matches "scanbeyond"' sessions search scanbeyond
node_says "a tail window starting on a line drops that line" adv '(none in tail window)' sessions show tail-line-start
node_says "one byte earlier the line is kept" adv 'reply on the tail boundary' sessions show tail-line-start-1
node_says "a prompt ending on the head boundary is read" adv 'prompt ending on the head boundary' sessions show head-exact
node_says "one byte more and it is not" adv '(none)' sessions show head-cut
node_says "a symlinked transcript is not listed" adv 'no session starts with "symlink"' sessions show symlink
node_says "2000 bytes is listed" adv 'size 2000' sessions show size-2000
node_says "1999 bytes is not" adv 'no session starts with "size-1999"' sessions show size-1999

# ------------------------------------------------------------------- listings ---
t "recent, with every way JavaScript reads a count"
for n in 0 -1 -2 -0 0.5 -0.5 1.9 2.5 15 16 100 1000 99999999999999999999 1e1 1e400 -1e400 +2 2. .5 0x2 0X10 0b11 0o7 0x 0xg 1_0 abc NaN Infinity -Infinity +Infinity infinity inf "" " " " 3 " $'\t4\n' $'\xc2\xa05\xc2\xa0' $'\xef\xbb\xbf6' $'\xe2\x80\xa87' ٣ １２ -9999 "3 4" $'\xff'; do
  parity "recent $(printf '%q' "$n")" adv sessions recent "$n"
done
parity "recent 3 extra args" adv sessions recent 3 5 7
parity "sessions (default 15)" adv sessions
parity "recent (default 15)" adv sessions recent
parity "recent 1000 (every session)" adv sessions recent 1000
parity "recent 1000 by discovery" disc sessions recent 1000
parity "recent --json" adv sessions recent --json
t "subcommands"
for sub in "" RECENT Recent --help -h help list " recent" "recent " -- --recent; do parity "sessions $(printf '%q' "$sub")" adv sessions "$sub"; done

# --------------------------------------------------------------------- search ---
t "search"
for q in common capword scanlast scanbeyond COMMON "Capword COMMON" ismeta emoji tie home elsewhere under 'bulk session 4' "οδος" "ΟΔΟΣ" "οδος ΟΔΟΣ" "Σ" "İSTANBUL" $'i\xcc\x87stanbul' istanbul "straße" "STRASSE" "ẞ" "ß" "kelvin k" "kelvin $(printf '\xe2\x84\xaa')" "~" "~/git" "кириллица" "КИРИЛЛИЦА" "привет" "😀" "nbsp" $'\xc2\xa0' "ws-" "lone" "1e999" "thirty" "crlf" "reply cases" "work account" "dotted" "ignored" "account name" "x" "a" "é" "tail boundary" "prompt past"; do
  parity "search $(printf '%q' "$q")" adv sessions search "$q"
done
parity "search two args" adv sessions search common capword
parity "search three words in one arg, runs of space" adv sessions search "  common    capword   bulk  "
parity "search empty arg" adv sessions search ""
parity "search blank arg" adv sessions search " "
parity "search nbsp arg" adv sessions search $'\xc2\xa0'
parity "search empty then word" adv sessions search "" common
parity "search word then empty" adv sessions search common ""
parity "search two empties" adv sessions search "" ""
parity "search tab and newline" adv sessions search $'\t' $'\n'
parity "search invalid utf-8 word" adv sessions search $'caf\xc3\xa9' $'\xff'
parity "search --flag" adv sessions search --flag
parity "search by discovery" disc sessions search common
parity "search work account by discovery" disc sessions search work
parity "search emoji account by discovery" disc sessions search account
parity "search miss with mixed case" adv sessions search "Nothing Here  AT ALL"

# ----------------------------------------------------------------------- show ---
t "show, for every session id the seed wrote (the bulk ones sampled)"
ids=$(find "$ADV" -type f -name '*.jsonl' -exec basename {} .jsonl \; | grep -v '^bulk-' | LC_ALL=C sort -u)
count=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  parity "show $id" adv sessions show "$id"
  count=$((count + 1))
done <<< "$ids"
[ "$count" -ge 100 ] || bad "show: the seed wrote only $count distinct ids, expected at least 100"
for id in bulk-000 bulk-007 bulk-399 bulk-429 bulk-4 b; do parity "show $id" adv sessions show "$id"; done
t "show, prefixes and arguments"
for p in a aa aaaaaaaa- ab 'a😀' 'a😀😀' 'ab😀' 'ab😀😀😀' 't' 'time-' 'ws' 'ws-nbsp' 'json-' 'bad' 'meta' 'skip' 'head' 'tail' 'size' '' '-' '.' '_' 'é' '～' '😀' 'Z' 'z' 'real.' $'\xff' $'a\xc3'; do
  parity "show prefix $(printf '%q' "$p")" adv sessions show "$p"
done
parity "show two prefixes" adv sessions show time-epoch time-1900
parity "show the work account" disc sessions show work-1
parity "show the dotted account" disc sessions show dotted-1
parity "show an ignored account" disc sessions show ignored-1
parity "show a non-ASCII ignored account" disc sessions show ignored-2
parity "show the emoji account by discovery" disc sessions show emoji-account
parity "show the long account name" disc sessions show long-account

# ------------------------------------------------------------ where to look ---
t "accounts, home and the environment"
for h in commas blank spaces dots nohome empty missing tz disc; do
  parity "sessions" "$h" sessions
  parity "recent 3" "$h" sessions recent 3
  parity "search common" "$h" sessions search common
  parity "show work-1" "$h" sessions show work-1
done
parity "recent 1000 under TZ and LANG" tz sessions recent 1000
# A config dir named by a relative path of one character, U+0085: JavaScript's trim keeps it, Rust's would drop it as white space, and it exists only below the working directory.
parity "relative claude dir U+0085" rel sessions recent
parity "show below the relative claude dir" rel sessions show relative-session
node_says "the relative claude dir is read" rel 'prompt of a session below a directory named U+0085' sessions recent

# -------------------------------------------------------------- unreadable ---
t "files and directories nobody may read"
if [ "$(id -u)" = 0 ]; then
  echo "  skip the permission cases: running as root"
else
  parity "sessions" locked sessions
  parity "recent 1" locked sessions recent 1
  parity "recent 2" locked sessions recent 2
  parity "recent 3" locked sessions recent 3
  parity "search anything" locked sessions search prompt
  parity "search the first row only" locked sessions search unlocked-new
  parity "show an unlocked one" locked sessions show unlocked-new
  parity "show the locked one" locked sessions show locked-file
  node_says "reading a locked file fails with EACCES" locked "EACCES: permission denied, open '$SEED/locked/.claude/projects/-locked-a/locked-file.jsonl'" sessions recent
fi

# ------------------------------------------------------------ closed pipe ---
t "a reader that goes away"
for prog in node rust; do
  use adv
  if [ $prog = node ]; then words=("$NODE" "$CORE_JS"); else words=("$RUST"); fi
  # the exit status of the first program of the pipeline: a reader that closes early must not change it, in either program
  env -i "${ENVV[@]}" ERRFILE="$TMP/err.$prog" bash -c '"$@" 2> "$ERRFILE" | head -c 1 > /dev/null; echo "${PIPESTATUS[0]}"' _ "${words[@]}" sessions recent 1000 > "$TMP/code.$prog" 2> /dev/null
  : > "$TMP/out.$prog"
done
ARGS=(sessions recent 1000 '| head -c 1')
compare "recent 1000 into a closed pipe"

# ------------------------------------------------------------ forwarded ---
t "every other word reaches the node CLI untouched"
# `--version` as the only argument is answered by the Rust binary itself and is a known difference (docs/architecture/rust-core.md); with another word after it, it is the node CLI's.
for args in "help" "--help" "-h" "" "bogus" "sessionsx" "Sessions" "session" "session bogus" "session open --nope" "session list --nope" "session prompt" "plugin" "plugin list" "plugin list --json" "plugin bogus" "plugin new" "doctor" "doctor --x" "telegram status" "--version x" "--" "-" "--spec2" "spec"; do
  # shellcheck disable=SC2086
  parity "forward: $args" adv $args
done
parity "forward: an argument with a space and a quote" adv session open --label "a b 'c' \"d\""
parity "forward: an empty argument" adv bogus ""
parity "forward: an argument that is not UTF-8" adv bogus $'\xff'

# ------------------------------------------------------ installer ---
t "the installer accepts the --version of this binary"
# install.sh compares the first line of `tagents-core --version` with the workspace version of the copy it installs, and installs nothing that differs. The binary of this checkout is packaged by the real packager, served as a file:// release,
# and installed by the whole installer in a sandbox: if the Rust side and the installer ever disagree about the shape of that line, the run ends with a warning here and not on a user's machine.
INST=$TMP/installer
ORIGIN=$INST/origin; mkdir -p "$ORIGIN/packages/core/dist/cli" "$ORIGIN/packages/knowledge/dist/cli" "$INST/home"
cp "$REPO/Cargo.toml" "$ORIGIN/Cargo.toml"
printf '#!/usr/bin/env node\n' > "$ORIGIN/packages/core/dist/cli/main.js"; printf '#!/usr/bin/env node\n' > "$ORIGIN/packages/knowledge/dist/cli/main.js"
git -C "$ORIGIN" init -q -b main && git -C "$ORIGIN" config user.email t@example.com && git -C "$ORIGIN" config user.name t && git -C "$ORIGIN" add -A && git -C "$ORIGIN" commit -q -m origin
version=$(sh "$REPO/.github/scripts/core-release.sh" version "$REPO/Cargo.toml")
sh "$REPO/.github/scripts/core-release.sh" package "$version" aarch64-apple-darwin "$RUST" "$REPO/LICENSE" "$INST/release/v$version" > /dev/null
inst_out=$(env -i PATH="$(dirname "$NODE"):/usr/bin:/bin" HOME="$INST/home" TAGENTS_HOME="$INST/home/share/tagents" TAGENTS_BIN="$INST/home/bin" TAGENTS_REPO="$ORIGIN" \
  TAGENTS_BUILD_CMD=true TAGENTS_CORE_BASE_URL="file://$INST/release/v$version" TAGENTS_CORE_TARGET=aarch64-apple-darwin \
  sh "$REPO/install.sh" --hooks-dir "$INST/home/hooks" 2>&1); inst_code=$?
if [ "$inst_code" -eq 0 ]; then ok; else bad "the installer exits 0" "exit $inst_code" "$(printf '%s\n' "$inst_out" | tail -5)"; fi
case $inst_out in
  *"installed the prebuilt tagents-core $version"*) ok ;;
  *) bad "the installer installs the binary of this checkout (version $version)" "$(printf '%s\n' "$inst_out" | tail -5)" ;;
esac
case $inst_out in
  *"for --version"*) bad "the installer finds nothing wrong with the output of --version" "$(printf '%s\n' "$inst_out" | grep 'for --version')" ;;
  *) ok ;;
esac
if cmp -s "$INST/home/share/tagents/target/release/tagents-core" "$RUST"; then ok; else bad "the binary the installer placed is the packaged one"; fi

printf '\nrust-parity: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
