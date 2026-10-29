#!/usr/bin/env bash
#
# tests/config-toml.sh — config.toml: the awk reader, which file is read, the
# YAML fallback and what --check and the status bar say about it.
#
# No tmux, no fzf, no Claude. Everything goes through --config, --check,
# --counts and --profile-for, with fixtures written into a mktemp dir and found
# through $TA_CONFIG or $XDG_CONFIG_HOME, so nothing touches a real config.
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
t "1. the reader: the subset flattens like the YAML reader's stream"
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

# The shipped pair: the TOML example is the YAML example, leaf for leaf and byte for byte.
ok "config.example.toml flattens exactly like the YAML example it replaces" \
   "$(dump "$HERE/fixtures/config.example.yaml")" "$(dump "$HERE/../config.example.toml")"

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

# The refusals reach --check like the YAML reader's do.
out=$(TA_CONFIG="$TMP/refuse.toml" tg --check 2>/dev/null)
contains "--check lists a refusal as file:line: why" "refuse.toml:2: " "$out"

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
ok "only config.yaml: read exactly as before" "notes.send${TAB}submit" "$(lookup "$TMP/only-yaml" --config 2>&1)"
out=$(lookup "$TMP/only-yaml" --check 2>&1); rc=$?
contains "...and --check says it is deprecated, naming the file" "only-yaml/tagents/config.yaml: YAML config is deprecated" "$out"
contains "...and what to run" "tagents config convert" "$out"
ok "...which is a problem: exit 1" 1 "$rc"
ok "...one line for it" 1 "$(nlines "$out")"

mk "$TMP/both"; printf '[notes]\nsend = "paste"\n' >"$TMP/both/tagents/config.toml"; printf 'notes:\n  send: submit\n' >"$TMP/both/tagents/config.yaml"
ok "both files: the TOML one wins" "notes.send${TAB}paste" "$(lookup "$TMP/both" --config 2>/dev/null)"
out=$(lookup "$TMP/both" --check 2>&1); rc=$?
contains "...and --check names the TOML file" "both/tagents/config.toml: " "$out"
contains "...and the YAML file it ignores, by name" "config.yaml is also there" "$out"
contains "...saying which one is read" "config.toml is read" "$out"
ok "...exit 1" 1 "$rc"
lacks "...and the YAML file is not called deprecated: it is not being read" "YAML config is deprecated" "$out"

mk "$TMP/none"
out=$(lookup "$TMP/none" --config 2>&1 >/dev/null); rc=$?
contains "no file: the message names config.toml, the format to write" "tagents: no config at $TMP/none/tagents/config.toml" "$out"
ok "...and --check is quiet, exit 0" "0" "$(lookup "$TMP/none" --check >/dev/null 2>&1; echo $?)"

# $TA_CONFIG: the extension picks the reader.
cp "$TMP/only-toml/tagents/config.toml" "$TMP/named.toml"
cp "$TMP/only-yaml/tagents/config.yaml" "$TMP/named.yaml"
cp "$TMP/only-yaml/tagents/config.yaml" "$TMP/named.yml"
cp "$TMP/only-yaml/tagents/config.yaml" "$TMP/named-no-extension"
ok "TA_CONFIG ending in .toml is read as TOML" "notes.send${TAB}paste" "$(dump "$TMP/named.toml")"
ok "...in .yaml as YAML" "notes.send${TAB}submit" "$(dump "$TMP/named.yaml")"
ok "...in .yml as YAML" "notes.send${TAB}submit" "$(dump "$TMP/named.yml")"
ok "...in anything else as YAML, as it always was" "notes.send${TAB}submit" "$(dump "$TMP/named-no-extension")"
printf 'notes:\n  send: submit\n' >"$TMP/looks-yaml.toml"
contains "a .toml file holding YAML is refused as TOML, not guessed at" "looks-yaml.toml:1: " "$(dump "$TMP/looks-yaml.toml")"

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
t "4. the per-machine overlay, in either format"
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
[claude.profiles.sasha]
config_dir = "~/.claude-sasha"
EOF
ovl() { TA_HOST=$1 lookup "$TMP/ov" "${@:2}"; }
ok "a TOML overlay replaces the subtree it names wholesale, and its lines come first" "claude.profiles.sasha.config_dir${TAB}~/.claude-sasha
claude.args${TAB}--base
notes.send${TAB}reference" "$(ovl mbp --config 2>&1)"
ok "another host: the base alone" 0 "$(ovl other --config 2>&1 | grep -c sasha)"

printf 'claude:\n  profiles:\n    nuzhin:\n      config_dir: ~/.claude-nuzhin\n' >"$TMP/ov/tagents/config.mac.yaml"
ok "a YAML overlay on a TOML base: each file read by its own reader" "claude.profiles.nuzhin.config_dir${TAB}~/.claude-nuzhin" "$(ovl mac --config 2>&1 | head -1)"
out=$(ovl mac --check 2>&1)
contains "...and the overlay is named deprecated, not the base" "ov/tagents/config.mac.yaml: YAML config is deprecated" "$out"
lacks    "...the TOML base is not" "config.toml: YAML config is deprecated" "$out"

printf '[claude.profiles.toml]\nconfig_dir = "~/.claude-toml"\n' >"$TMP/ov/tagents/config.mac.toml"
ok "both overlays for one host: the TOML one wins" "claude.profiles.toml.config_dir${TAB}~/.claude-toml" "$(ovl mac --config 2>/dev/null | head -1)"
out=$(ovl mac --check 2>&1)
contains "...with a note naming both overlay files" "config.mac.toml: " "$out"
contains "...and the YAML one it ignores" "config.mac.yaml is also there" "$out"

# A base in YAML, its overlay in TOML.
mk "$TMP/ov2"
printf 'notes:\n  send: paste\n' >"$TMP/ov2/tagents/config.yaml"
printf '[notes]\nsend = "submit"\n' >"$TMP/ov2/tagents/config.mbp.toml"
ok "a TOML overlay on a YAML base" "notes.send${TAB}submit" "$(TA_HOST=mbp lookup "$TMP/ov2" --config 2>&1)"

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
printf 'usage:\n  workdays: true\n' >"$TMP/good.yaml"
counts() { rm -f "$TMP/state/.cfg-check"; env -u XDG_CONFIG_HOME TA_COUNTS_EVERY=0 HOME="$TMP/home" TA_STATE_DIR="$TMP/state" TA_HOST=nohost TA_CONFIG="$1" bash "$TA" --counts 2>/dev/null; }
lacks    "the status bar shows nothing for a good TOML config" "cfg!" "$(counts "$TMP/good.toml")"
contains "...and the YAML fallback is one problem in it" "cfg!1" "$(counts "$TMP/good.yaml")"
contains "...like any other problem: a bad TOML value adds to it" "cfg!4" "$(counts "$TMP/bad.toml")"
contains "...and a YAML config with a problem counts the deprecation too" "cfg!2" \
         "$(printf 'usage:\n  workdays: sometimes\n' >"$TMP/bad.yaml"; counts "$TMP/bad.yaml")"

# Writing config.toml beside a YAML config clears the marker at the next redraw: the stamp names the file it described.
mk "$TMP/bar"; printf 'usage:\n  workdays: true\n' >"$TMP/bar/tagents/config.yaml"
bar() { env -u TA_CONFIG TA_COUNTS_EVERY=0 XDG_CONFIG_HOME="$TMP/bar" HOME="$TMP/home" TA_STATE_DIR="$TMP/state" TA_HOST=nohost bash "$TA" --counts 2>/dev/null; }
rm -f "$TMP/state/.cfg-check"
contains "a YAML-only config: the marker" "cfg!1" "$(bar)"
printf '[usage]\nworkdays = true\n' >"$TMP/bar/tagents/config.toml"
contains "...with a TOML file beside it, the same two files are named in one problem" "cfg!1" "$(bar)"
rm -f "$TMP/bar/tagents/config.yaml"
lacks    "...and with the YAML gone the marker clears on the very next redraw" "cfg!" "$(bar)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
