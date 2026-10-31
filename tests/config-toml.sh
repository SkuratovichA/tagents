#!/usr/bin/env bash
#
# tests/config-toml.sh — config.toml: the awk reader, which file is read and what --check and the status bar say about it.
#
# No tmux, no fzf, no Claude. Everything goes through --config, --check, --counts and --profile-for, with fixtures written into a mktemp dir and found through $TA_CONFIG or $XDG_CONFIG_HOME, so nothing touches a real config.
#
# bash 3.2, runnable from any cwd, non-zero exit when any check fails.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/scratch-guard.sh" && scratch_guard config-toml.sh || exit 1
TA="$HERE/../tagents"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tagents-toml.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

TAB=$(printf '\t')
unset TA_CONFIG XDG_CONFIG_HOME TA_HOST
pass=0; fail=0
mkdir -p "$TMP/state" "$TMP/home"

ok() {  # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
  fi
}

contains() {  # <name> <needle> <haystack>
  case "$3" in
    *"$2"*) pass=$((pass + 1)); printf '  ok   %s\n' "$1" ;;
    *) fail=$((fail + 1))
       printf '  FAIL %s\n       expected to contain: %s\n       actual: %s\n' "$1" "$2" "$3" ;;
  esac
}

lacks() {  # <name> <needle> <haystack>
  case "$3" in
    *"$2"*) fail=$((fail + 1))
            printf '  FAIL %s\n       expected NOT to contain: %s\n       actual: %s\n' "$1" "$2" "$3" ;;
    *) pass=$((pass + 1)); printf '  ok   %s\n' "$1" ;;
  esac
}

t() { printf '\n%s\n' "$1"; }

# Every call runs with its own state dir and HOME, and under a host name no overlay is written for, unless the case sets TA_HOST itself.
tg() { env -u XDG_CONFIG_HOME HOME="$TMP/home" TA_STATE_DIR="$TMP/state" TA_HOST="${TA_HOST:-nohost}" bash "$TA" "$@"; }
dump()  { TA_CONFIG="$1" tg --config 2>&1; }
dumpo() { TA_CONFIG="$1" tg --config 2>/dev/null; }
nlines() { printf '%s' "$1" | awk 'END { print NR }'; }

# ---------------------------------------------------------------------------
t "1. the reader: the subset flattens to one path<TAB>value line per leaf"
# ---------------------------------------------------------------------------

cat >"$TMP/subset.toml" <<'EOF'
# a comment
top = "x"                      # trailing comment
"quoted key" = 'literal \ string'
dotted.key.here = true
n = 42
neg = -7
big = 1_000
f = 7.5
s = "a # not a comment"
esc = "say \"hi\" \\ done"
empty = ""

[claude]
args = ["--a", "--b c"]
more = [
  "x",   # first
  "y",
]
env = { A = "1", B = 2 }
none = []
nobody = {}

[claude.profiles."my.profile"]
config_dir = '~/.claude-x'

[claude.profiles.work]

[[claude.rules]]
dir = "~/git/a"
profile = "a"

[[claude.rules]]

[[claude.rules]]
session = "s"
EOF
want=$(cat <<EOF
top${TAB}x
quoted key${TAB}literal \\ string
dotted.key.here${TAB}true
n${TAB}42
neg${TAB}-7
big${TAB}1000
f${TAB}7.5
s${TAB}a # not a comment
esc${TAB}say "hi" \\ done
empty${TAB}
claude.args.0${TAB}--a
claude.args.1${TAB}--b c
claude.more.0${TAB}x
claude.more.1${TAB}y
claude.env.A${TAB}1
claude.env.B${TAB}2
claude.none${TAB}
claude.nobody${TAB}
claude.profiles.my.profile.config_dir${TAB}~/.claude-x
claude.profiles.work${TAB}
claude.rules.0.dir${TAB}~/git/a
claude.rules.0.profile${TAB}a
claude.rules.1${TAB}
claude.rules.2.session${TAB}s
EOF
)
ok "every construct of the subset" "$want" "$(dump "$TMP/subset.toml")"

# CRLF is the same file.
sed 's/$/\r/' "$TMP/subset.toml" >"$TMP/subset-crlf.toml"
ok "a CRLF file reads as its LF twin" "$want" "$(dump "$TMP/subset-crlf.toml")"

# The shipped example reads without one refusal, and its leaves are the ones the file documents.
contains "config.example.toml reads: the account rules are there" "claude.rules.0.dir${TAB}~/git/personal" "$(dump "$HERE/../config.example.toml")"
lacks    "...and no line of it is refused" "not a key = value line" "$(dump "$HERE/../config.example.toml")"

# A table owns the plain keys under it; the empty ones still count.
printf '[a]\n[a.b]\n[c]\n' >"$TMP/empties.toml"
ok "a table holding only a table is no leaf, an empty one is" "a.b${TAB}
c${TAB}" "$(dump "$TMP/empties.toml")"

# ---------------------------------------------------------------------------
t "2. the reader: what is outside the subset costs only its line"
# ---------------------------------------------------------------------------

refuse() {  # <name> <line text> <why>   — line 2 of a three-line file, the others stay readable
  local f="$TMP/refuse.toml" out
  printf 'before = 1\n%s\nafter = 2\n' "$2" >"$f"
  out=$(TA_CONFIG="$f" tg --config 2>&1)
  contains "$1: named with file and line" "refuse.toml:2: $3" "$out"
  contains "$1: the lines around it still read" "before${TAB}1
after${TAB}2" "$out"
}
refuse "a date"             'when = 1979-05-27'           'not a string, a decimal number or a boolean: 1979-05-27'
refuse "a hex integer"      'mask = 0xFF'                 'not a string, a decimal number or a boolean: 0xFF'
refuse "an exponent"        'big = 1e3'                   'not a string, a decimal number or a boolean: 1e3'
refuse "a bare word"        'mode = reference'            'not a string, a decimal number or a boolean: reference'
refuse "an unsupported escape" 'text = "a\nb"'            'the escape \n is not supported'
refuse "a multi-line string" 'text = """a b"""'           'multi-line strings are not supported'
refuse "an array in an array" 'rules = [["a"]]'           'nested arrays and tables inside an array are not supported'
refuse "inline tables in an array" 'rules = [{ dir = "a" }]' 'nested arrays and tables inside an array are not supported'
refuse "an inline table of tables" 'e = { a = { b = 1 } }' 'only plain values are supported inside an inline table'
refuse "a trailing comma in an inline table" 'e = { a = 1, }' 'a trailing comma is not allowed in an inline table'
refuse "text after a value" 'a = 1 2'                     'unexpected text after the value'
refuse "a line that is not key = value" 'just words'       'not a key = value line'
refuse "a key with nothing" '= 5'                          'not a valid key'

printf 'a = 1\na = 2\nb = 3\n' >"$TMP/dup.toml"
out=$(dump "$TMP/dup.toml")
contains "a key twice: refused at the second" "dup.toml:2: duplicate key a" "$out"
contains "...the first one stays" "a${TAB}1" "$out"
lacks    "...and the second is not read" "a${TAB}2" "$out"

printf '[t]\nx = 1\n[t]\ny = 2\n' >"$TMP/duptable.toml"
contains "a table twice: refused at the second header" "duptable.toml:3: table [t] is defined twice" "$(dump "$TMP/duptable.toml")"
lacks    "...and its keys are not taken for the first table's" "t.y${TAB}2" "$(dump "$TMP/duptable.toml")"

printf 'a = 1\nlist = [\n  "x",\n' >"$TMP/open.toml"
contains "an array that never closes: refused where it began" "open.toml:2: unterminated array or inline table" "$(dump "$TMP/open.toml")"

printf '[claude.profiles.a\nconfig_dir = "x"\n[claude.profiles.b]\nconfig_dir = "y"\n' >"$TMP/badhead.toml"
out=$(dump "$TMP/badhead.toml")
contains "a bad header: refused" "badhead.toml:1: " "$out"
lacks    "...and the keys that were meant for it are not given to another table" "config_dir${TAB}x" "$out"
contains "...while the next table reads" "claude.profiles.b.config_dir${TAB}y" "$out"

# The refusals reach --check.
out=$(TA_CONFIG="$TMP/refuse.toml" tg --check 2>/dev/null)
contains "--check lists a refusal as file:line: why" "refuse.toml:2: " "$out"

# A multi-line string is refused at its opening line and its body is skipped, not read as config.
for q in '"""' "'''"; do
  printf '[usage]\na = %s\nb = 1\n[fake]\nc = 2\n%s\nd = 3\n' "$q" "$q" >"$TMP/multi.toml"
  out=$(dump "$TMP/multi.toml")
  contains "a $q string: refused at its opening line" "multi.toml:2: multi-line strings are not supported" "$out"
  contains "...the key after its end reads" "usage.d${TAB}3" "$out"
  lacks    "...a key in its body is not read" "usage.b" "$out"
  lacks    "...a table in its body is not read" "fake.c" "$out"
  ok       "...and --check lists it once" 1 "$(TA_CONFIG="$TMP/multi.toml" tg --check 2>/dev/null | grep -c 'multi-line strings')"
done
printf '[usage]\na = """x"""\nd = 3\n' >"$TMP/multi1.toml"
out=$(dump "$TMP/multi1.toml")
contains "a multi-line string closed on its own line: refused" "multi1.toml:2: multi-line strings are not supported" "$out"
contains "...and the next line reads" "usage.d${TAB}3" "$out"
printf '[usage]\na = """x \\""" y\nb = 1\n"""\nd = 3\n' >"$TMP/multi2.toml"
out=$(dump "$TMP/multi2.toml")
lacks    "an escaped quote does not close a basic multi-line string" "usage.b" "$out"
contains "...the closing one does" "usage.d${TAB}3" "$out"
# ...also when the opening sits in a table that is skipped: a duplicate table's body is not read, but a multi-line string opened in it must still swallow its body.
printf '[t]\n[t]\na = \"\"\"\n[fake]\nb = 1\n\"\"\"\n[usage]\nd = 3\n' >"$TMP/multi3.toml"
out=$(dump "$TMP/multi3.toml")
lacks    "a multi-line string opened in a skipped table: no table from its body" "fake" "$out"
lacks    "...and no key from its body" "b${TAB}1" "$out"
contains "...the table after its end reads" "usage.d${TAB}3" "$out"
# ...and when the line that opens it is the one refused: a key that is not valid, or a key that is not followed by =, still has a body to swallow.
for opener in '"""' "'''"; do
  for key in '$x' 'a b'; do
    printf '%s = %s\n[fake]\nx = 1\n%s\n[usage]\nd = 3\n' "$key" "$opener" "$opener" >"$TMP/multi4.toml"
    out=$(dump "$TMP/multi4.toml")
    ok       "a multi-line string opened on the refused line \"$key = $opener\": one warning" 1 "$(printf '%s\n' "$out" | grep -c 'multi4.toml:')"
    lacks    "...no table from its body" "fake" "$out"
    contains "...the table after its end reads" "usage.d${TAB}3" "$out"
  done
done
# ...and inside a skipped table: the second [t] is refused once, its lines are not read, and the body of the string belongs to neither.
for opener in '"""' "'''"; do
  for key in '$x' 'a b'; do
    printf '[t]\n[t]\n%s = %s\n[fake]\nc = 2\n%s\n[usage]\nd = 3\n' "$key" "$opener" "$opener" >"$TMP/multi5.toml"
    out=$(dump "$TMP/multi5.toml")
    ok       "a refused line \"$key = $opener\" in a skipped table: one warning, for the table, none for its lines" 1 "$(printf '%s\n' "$out" | grep -c 'multi5.toml:')"
    lacks    "...no table from its body" "fake" "$out"
    lacks    "...no key from its body" "c${TAB}2" "$out"
    contains "...the table after its end reads" "usage.d${TAB}3" "$out"
  done
done
# ...and a refused line whose quoted key holds an = of its own: the opener is the = after the key, in an ordinary table and in a skipped one.
for opener in '"""' "'''"; do
  printf '[t]\n"a=b" c = %s\n[fake]\nx = 1\n%s\n[usage]\nd = 3\n' "$opener" "$opener" >"$TMP/multi6.toml"
  out=$(dump "$TMP/multi6.toml")
  lacks    "a quoted key with an = in a refused line, $opener: no table from its body" "fake" "$out"
  contains "...the table after its end reads" "usage.d${TAB}3" "$out"
  printf '[t]\n[t]\n"a=b" c = %s\n[fake]\nx = 1\n%s\n[usage]\nd = 3\n' "$opener" "$opener" >"$TMP/multi7.toml"
  out=$(dump "$TMP/multi7.toml")
  lacks    "...and in a skipped table: no table from its body" "fake" "$out"
  contains "...the table after its end reads" "usage.d${TAB}3" "$out"
done

# ---------------------------------------------------------------------------
t "3. which file is read"
# ---------------------------------------------------------------------------

mk() {  # <dir> — an XDG config home with the given files
  mkdir -p "$1/tagents"
}
lookup() {  # <xdg dir> [args...]
  local x=$1; shift
  env -u TA_CONFIG XDG_CONFIG_HOME="$x" HOME="$TMP/home" TA_STATE_DIR="$TMP/state" TA_HOST="${TA_HOST:-nohost}" bash "$TA" "$@"
}

mk "$TMP/only-toml"; printf '[notes]\nsend = "paste"\n' >"$TMP/only-toml/tagents/config.toml"
ok "only config.toml: it is read" "notes.send${TAB}paste" "$(lookup "$TMP/only-toml" --config 2>&1)"
ok "...and a good TOML config has nothing to say" "" "$(lookup "$TMP/only-toml" --check 2>&1)"

mk "$TMP/only-yaml"; printf 'notes:\n  send: submit\n' >"$TMP/only-yaml/tagents/config.yaml"
out=$(lookup "$TMP/only-yaml" --config 2>&1); rc=$?
contains "only a config.yaml: it is not looked at, and the message names config.toml" "tagents: no config at $TMP/only-yaml/tagents/config.toml" "$out"
ok "...exit 1" 1 "$rc"
ok "...and --check is quiet, exit 0" "0" "$(lookup "$TMP/only-yaml" --check >/dev/null 2>&1; echo $?)"

mk "$TMP/both"; printf '[notes]\nsend = "paste"\n' >"$TMP/both/tagents/config.toml"; printf 'notes:\n  send: submit\n' >"$TMP/both/tagents/config.yaml"
ok "both files: the TOML one is read" "notes.send${TAB}paste" "$(lookup "$TMP/both" --config 2>/dev/null)"
ok "...and --check says nothing about the other one" "" "$(lookup "$TMP/both" --check 2>&1)"

mk "$TMP/none"
out=$(lookup "$TMP/none" --config 2>&1 >/dev/null); rc=$?
contains "no file: the message names config.toml, the format to write" "tagents: no config at $TMP/none/tagents/config.toml" "$out"
ok "...and --check is quiet, exit 0" "0" "$(lookup "$TMP/none" --check >/dev/null 2>&1; echo $?)"

# $TA_CONFIG names the file, whatever its extension: the content is read as TOML.
cp "$TMP/only-toml/tagents/config.toml" "$TMP/named.toml"
cp "$TMP/only-toml/tagents/config.toml" "$TMP/named-no-extension"
ok "TA_CONFIG ending in .toml is read" "notes.send${TAB}paste" "$(dump "$TMP/named.toml")"
ok "...and one with any other name is read the same way" "notes.send${TAB}paste" "$(dump "$TMP/named-no-extension")"
printf 'notes:\n  send: submit\n' >"$TMP/looks-yaml.toml"
contains "a file holding YAML is refused as TOML, not guessed at" "looks-yaml.toml:1: " "$(dump "$TMP/looks-yaml.toml")"

# The rules a TOML file declares are the rules the launcher follows.
mkdir -p "$TMP/home/git/personal/x"
cat >"$TMP/rules.toml" <<EOF
[claude.profiles.personal]
config_dir = "~/.claude-personal"
[claude.profiles.work]
[[claude.rules]]
dir = "$TMP/home/git/personal"
profile = "personal"
[[claude.rules]]
session = "w"
profile = "work"
EOF
ok "--profile-for follows a [[claude.rules]] table" "personal" "$(TA_CONFIG="$TMP/rules.toml" tg --profile-for "$TMP/home/git/personal/x" 2>/dev/null)"

# ---------------------------------------------------------------------------
t "4. the per-machine overlay"
# ---------------------------------------------------------------------------

mk "$TMP/ov"
cat >"$TMP/ov/tagents/config.toml" <<'EOF'
[claude]
args = "--base"
[claude.profiles.personal]
config_dir = "~/.claude-personal"
[claude.profiles.work]
[notes]
send = "reference"
EOF
cat >"$TMP/ov/tagents/config.mbp.toml" <<'EOF'
[claude.profiles.client]
config_dir = "~/.claude-client"
EOF
ovl() { TA_HOST=$1 lookup "$TMP/ov" "${@:2}"; }
ok "a TOML overlay replaces the subtree it names wholesale, and its lines come first" "claude.profiles.client.config_dir${TAB}~/.claude-client
claude.args${TAB}--base
notes.send${TAB}reference" "$(ovl mbp --config 2>&1)"
ok "another host: the base alone" 0 "$(ovl other --config 2>&1 | grep -c client)"

printf 'claude:\n  profiles:\n    yaml:\n      config_dir: ~/.claude-yaml\n' >"$TMP/ov/tagents/config.mac.yaml"
ok "a config.mac.yaml beside the base is not an overlay" 0 "$(ovl mac --config 2>&1 | grep -c yaml)"

printf '[claude.profiles.toml]\nconfig_dir = "~/.claude-toml"\n' >"$TMP/ov/tagents/config.mac.toml"
ok "a config.mac.toml is the overlay for that host" "claude.profiles.toml.config_dir${TAB}~/.claude-toml" "$(ovl mac --config 2>/dev/null | head -1)"

# ---------------------------------------------------------------------------
t "5. --check on a TOML config, and the status bar"
# ---------------------------------------------------------------------------

cat >"$TMP/bad.toml" <<'EOF'
[usage]
monthly_limit_usd = "850 dollars"
workdays = "False"
[notes]
send = "mail"
[keys]
new = "ctrl-1"
EOF
out=$(TA_CONFIG="$TMP/bad.toml" tg --check 2>&1); rc=$?
contains "a bad number is named by key"  'usage.monthly_limit_usd: "850 dollars" is not a number' "$out"
contains "a bad boolean"                 'usage.workdays: "False" is not true or false' "$out"
contains "a bad notes.send"              'notes.send: "mail" is not one of reference, paste, submit' "$out"
contains "a key fzf does not know"       "keys.new: 'ctrl-1' is not a key fzf knows" "$out"
ok       "exit 1" 1 "$rc"

mkdir -p "$TMP/logins"
printf '[usage]\nworkdays = true\n' >"$TMP/good.toml"
counts() { rm -f "$TMP/state/.cfg-check"; env -u XDG_CONFIG_HOME TA_COUNTS_EVERY=0 HOME="$TMP/home" TA_STATE_DIR="$TMP/state" TA_HOST=nohost TA_CONFIG="$1" bash "$TA" --counts 2>/dev/null; }
lacks    "the status bar shows nothing for a good TOML config" "cfg!" "$(counts "$TMP/good.toml")"
contains "...like any other problem: a bad TOML value adds to it" "cfg!4" "$(counts "$TMP/bad.toml")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
