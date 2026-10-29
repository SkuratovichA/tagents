#!/usr/bin/env bash
#
# tests/setup.sh — `tagents setup`: the hooks and the status line, registered in Claude Code's settings.json.
#
# The whole point of the verb is what it does NOT do, so most cases here are a settings file with something in it and the question of whether all of it comes out the other side: every key, every group of somebody else's, in its place, with tagents' own appended after. The rest are the ways a write can go wrong without anybody noticing: through a link, under a mode, twice, while Claude Code is writing the same file, into a directory with a quote in its name.
#
# Nothing here reaches the real ~/.claude* or ~/.config/tagents: HOME is a scratch directory before the first case, CLAUDE_CONFIG_DIR is unset, the config and the verb's temp directory are inside the scratch tree, every run goes through env -i, and the suite refuses to start when HOME still resolves to the real home. No tmux, no fzf, no Claude. bash 3.2, runnable from any cwd, non-zero exit when any check fails.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# A suite that is not run against a scratch default server aborts here, before it can reach the live one (tests/scratch-guard.sh).
. "$HERE/scratch-guard.sh" && scratch_guard setup.sh || exit 1
ROOT=$(cd "$HERE/.." && pwd -P)
TA=$ROOT/tagents
TPL=$ROOT/hooks/claude-settings.json
BASH_BIN=$(command -v bash)
REAL_HOME=$(cd "$HOME" 2>/dev/null && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tagents-setup.XXXXXX") || exit 1
TMP=$(cd "$TMP" && pwd -P) || exit 1
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM

# THE HOME GUARD. From here on this shell's HOME is inside the scratch tree, whatever it was when the suite started, and the suite stops if that did not take.
unset CLAUDE_CONFIG_DIR
HOME=$TMP/home; mkdir -p "$HOME"; export HOME
XDG_CONFIG_HOME=$HOME/.config; TA_CONFIG=$HOME/.config/tagents/config.toml; export XDG_CONFIG_HOME TA_CONFIG
here=$(cd "$HOME" 2>/dev/null && pwd -P)
if [ -z "$here" ] || [ "$here" = "$REAL_HOME" ]; then
  echo "setup.sh: HOME ($HOME) is the real home; refusing to run" >&2; exit 1
fi
case $here in "$TMP"/*) ;; *) echo "setup.sh: HOME ($HOME) is not inside the scratch tree; refusing to run" >&2; exit 1 ;; esac

pass=0; fail=0

ok() {  # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
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

EVENTS='SessionStart UserPromptSubmit PreToolUse PostToolUse Notification Stop SubagentStop SessionEnd'
OUT=''; ERR=''; RC=0; XENV=''; E=''; H=''; TMPD=''; CASE=''

# ---------------------------------------------------------------------------
# the fixtures
# ---------------------------------------------------------------------------
sum_of()   { cksum <"$1" | cut -d' ' -f1,2; }
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
mode_of()  { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
baks()     { ls "$1".tagents-*.bak 2>/dev/null | wc -l | tr -d ' '; }
bak_of()   { ls "$1".tagents-*.bak 2>/dev/null | head -n 1; }
bak_holds() {  # <settings file> <file> -> yes when one of the backups of the first is byte for byte the second
  local b
  for b in "$1".tagents-*.bak; do
    if cmp -s "$b" "$2"; then echo yes; return 0; fi
  done
  echo no
}
listing()  { ls -A "$1" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
past()     { touch -t 202001010000 "$1"; }

stub_hooks() {  # <dir> — the two scripts the registration names, as stubs that say they ran
  mkdir -p "$1"
  printf '#!/bin/sh\necho hook-ran\n' >"$1/tmux-agent-state.sh"
  printf '#!/bin/sh\necho line-ran\n' >"$1/claude-statusline.sh"
}

# A scratch home for one case: the default config dir with the hook scripts in it, the config directory, and the temp directory the verb is given (it must be empty again when the verb is done).
mkenv() {  # <case name>
  CASE=$1; E=$TMP/$1; H=$E/home; TMPD=$E/tmp
  rm -rf "$E"
  mkdir -p "$H/.config/tagents" "$TMPD"
  stub_hooks "$H/.claude/hooks"
  XENV=''
}

# One run of the verb in the case's home, through env -i so nothing of the real environment gets in. The files it must never leave behind are checked on every run, not once.
run() {
  case $H in "$TMP"/*) ;; *) echo "setup.sh: refusing to run against $H" >&2; exit 1 ;; esac
  OUT=$(env -i PATH="$PATH" HOME="$H" XDG_CONFIG_HOME="$H/.config" TA_CONFIG="$H/.config/tagents/config.toml" \
          TMPDIR="$TMPD" LANG="${LANG:-en_US.UTF-8}" TERM=dumb ${CLAUDE_CONFIG_DIR:+CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR} \
          $XENV "$BASH_BIN" "$TA" setup "$@" 2>"$TMP/err"); RC=$?
  ERR=$(cat "$TMP/err")
  local left scratch
  left=$(find "$E" -name '*.tagents-tmp.*' 2>/dev/null | sed "s|^$E/||" | tr '\n' ' ')
  scratch=$(listing "$TMPD")
  if [ -n "$left$scratch" ]; then
    fail=$((fail + 1)); printf '  FAIL %s: files left behind: [%s] [%s]\n' "$CASE" "$left" "$scratch"
  fi
}

# Every key, group and event of the file before is still in the file after, in its place, and what is new was only appended: a key at the end of the file, an event at the end of "hooks", a group at the end of an event's array.
kept_all() {  # <before> <after> -> yes|no
  jq -n --slurpfile o "$1" --slurpfile n "$2" '
    $o[0] as $o | $n[0] as $n
    | ($o | keys_unsorted) as $ok | ($n | keys_unsorted) as $nk
    | ($nk[0:($ok | length)] == $ok)
      and ([ $ok[] | select(. != "hooks") | . as $k | $o[$k] == $n[$k] ] | all)
      and (($o.hooks // {}) as $oh | ($n.hooks // {}) as $nh
           | ($oh | keys_unsorted) as $ohk | ($nh | keys_unsorted) as $nhk
           | ($nhk[0:($ohk | length)] == $ohk)
             and ([ $ohk[] | . as $e | ($nh[$e][0:($oh[$e] | length)]) == $oh[$e] ] | all))' 2>&1 |
    sed 's/^true$/yes/; s/^false$/no/'
}

# The registration with the hooks directory filled in, written by sed so that it does not share a mechanism with the code under test.
oracle() {  # <what @HOOKS@ becomes>
  sed "s|@HOOKS@|$1|g" "$TPL" | jq -S .
}

# A settings.json that already holds tagents' hooks, in the form asked for: single (sh '/abs/x.sh'), double (sh "$HOME/.../x.sh") or bare.
present() {  # <single|double|bare> <hooks dir as written> [event…]
  local form=$1 dir=$2; shift 2
  [ $# -gt 0 ] || set -- $EVENTS
  jq -n --arg form "$form" --arg dir "$dir" --argjson events "$(printf '%s\n' "$@" | jq -R . | jq -sc .)" '
    def c($n): if $form == "single" then "sh \u0027\($dir)/\($n)\u0027"
               elif $form == "double" then "sh \"\($dir)/\($n)\""
               else "\($dir)/\($n)" end;
    {hooks: ([ $events[] | {key: ., value: [{hooks: [{type: "command", command: c("tmux-agent-state.sh")}]}]} ] | from_entries),
     statusLine: {type: "command", command: c("claude-statusline.sh")}}'
}

# A file that must be refused, and everything a refusal owes: the verb fails, the file keeps its bytes and its mtime, nothing is left beside it, and the message names the file and the reason.
refused() {  # <case name> <file content> <what the message says>
  mkenv "$1"; F=$H/.claude/settings.json
  printf '%s' "$2" >"$F"; past "$F"
  local s0 m0; s0=$(sum_of "$F"); m0=$(mtime_of "$F")
  run
  ok "$1: refused" 1 "$RC"
  ok "$1: the bytes are the same" "$s0" "$(sum_of "$F")"
  ok "$1: the mtime is the same" "$m0" "$(mtime_of "$F")"
  ok "$1: nothing is left beside it" "hooks settings.json" "$(listing "$H/.claude")"
  contains "$1: the message names the file" "~/.claude/settings.json" "$ERR"
  contains "$1: ...and says why" "$3" "$ERR"
}

# ---------------------------------------------------------------------------
t "0. the registration the verb reads"
# ---------------------------------------------------------------------------
ok "hooks/claude-settings.json names the eight events, in this order" "$EVENTS" "$(jq -r '.hooks | keys_unsorted | join(" ")' "$TPL")"
ok "...each with one group of one command" 1 "$(jq -r '[.hooks[] | (length, (.[0].hooks | length))] | unique | join(" ")' "$TPL")"
ok "...the three that run on every tool call or subagent are async" "PreToolUse PostToolUse SubagentStop" \
   "$(jq -r '[.hooks | to_entries[] | select(.value[0].hooks[0].async == true) | .key] | join(" ")' "$TPL")"
ok "...and a status line that runs claude-statusline.sh" 'sh "@HOOKS@/claude-statusline.sh"' "$(jq -r '.statusLine.command' "$TPL")"
named=$(grep -o '@HOOKS@/[^"\\ ]*' "$TPL" | sed 's|^@HOOKS@/||' | sort -u | tr '\n' ' ' | sed 's/ $//')
ok "it names exactly the two scripts the hooks directory holds" "claude-statusline.sh tmux-agent-state.sh" "$named"
missing=''; for n in $named; do [ -f "$ROOT/hooks/$n" ] || missing="$missing $n"; done
ok "...and every one of them is in hooks/" "" "$missing"

# ---------------------------------------------------------------------------
t "1. a file that is not there, or has nothing in it"
# ---------------------------------------------------------------------------
mkenv missing; F=$H/.claude/settings.json
run
ok "a missing settings.json: exit 0" 0 "$RC"
ok "...is created with the whole registration, the hooks directory as \$HOME/..." "$(oracle '$HOME/.claude/hooks')" "$(jq -S . "$F")"
ok "...with no backup, there was nothing to keep" 0 "$(baks "$F")"
ok "...with nothing else beside it" "hooks settings.json" "$(listing "$H/.claude")"
ok "...with the mode the umask gives a new file" "$(printf '%o' $((0666 & ~0$(umask))))" "$(mode_of "$F")"
ok "...and no noise on stderr" "" "$ERR"
contains "...and a line that names the file and what went into it" "~/.claude/settings.json: added the hooks for SessionStart, UserPromptSubmit, PreToolUse" "$OUT"
contains "...and the status line" "added the status line" "$OUT"

mkenv empty; F=$H/.claude/settings.json; : >"$F"
run
ok "an empty file: exit 0" 0 "$RC"
ok "...is read as {} and gets the whole registration" "$(oracle '$HOME/.claude/hooks')" "$(jq -S . "$F")"
ok "...and the old (empty) file is kept" 1 "$(baks "$F")"
ok "...as it was" yes "$(cmp -s "$(bak_of "$F")" /dev/null && echo yes || echo no)"

mkenv blank; F=$H/.claude/settings.json; printf ' \n\t\n' >"$F"
run
ok "a whitespace-only file: exit 0" 0 "$RC"
ok "...gets the whole registration" "$(oracle '$HOME/.claude/hooks')" "$(jq -S . "$F")"
ok "...and its bytes are in the backup" "$(printf ' \n\t\n' | cksum | cut -d' ' -f1,2)" "$(sum_of "$(bak_of "$F")")"

# ---------------------------------------------------------------------------
t "2. other hooks on the same events, and every other setting: all of it stays"
# ---------------------------------------------------------------------------
mkenv others; F=$H/.claude/settings.json
cat >"$F" <<'EOF'
{
    "permissions": { "allow": ["Bash(git status)", "Read(~/notes/**)"], "deny": [] },
  "env": {"FOO": "bar baz", "N": "1"},
      "model": "opus",
  "note": "café ✓ \"quoted\" \\ back",
  "ratio": 1.5, "count": 3, "flag": false, "nothing": null,
  "hooks": {
    "Stop": [ { "matcher": "", "hooks": [ { "type": "command", "command": "echo user stop" } ] } ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "~/bin/guard.sh" } ] },
      { "matcher": "Write|Edit", "hooks": [ { "type": "command", "command": "~/bin/fmt.sh", "timeout": 5 } ] }
    ],
    "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "my-tmux-agent-state.sh" } ] } ],
    "Notification": [ { "hooks": [ { "type": "command", "command": "sh /x/tmux-agent-state.sh.bak" } ] } ],
    "MyCustomEvent": [ { "hooks": [] } ]
  },
  "zzz": [1, 2, { "a": null }]
}
EOF
cp -p "$F" "$E/before.json"
run
ok "exit 0" 0 "$RC"
ok "the result minus what was appended is the input: keys, order, groups" yes "$(kept_all "$E/before.json" "$F")"
ok "Stop: the user's group first, tagents' group after it" "echo user stop|tmux-agent-state.sh" \
   "$(jq -r '.hooks.Stop | [.[0].hooks[0].command, (.[1].hooks[0].command | capture("(?<n>[a-z-]+\\.sh)").n)] | join("|")' "$F")"
ok "PreToolUse: both matcher groups stay, tagents' async group is third" "Bash|Write|Edit|true" \
   "$(jq -r '.hooks.PreToolUse | [.[0].matcher, .[1].matcher, (.[2].hooks[0].async | tostring)] | join("|")' "$F")"
ok "PreToolUse: the group with a timeout is untouched" '{"matcher":"Write|Edit","hooks":[{"type":"command","command":"~/bin/fmt.sh","timeout":5}]}' "$(jq -c '.hooks.PreToolUse[1]' "$F")"
ok "a lookalike (my-tmux-agent-state.sh) is not tagents' hook, so the event still gets its own group" 2 "$(jq '.hooks.UserPromptSubmit | length' "$F")"
ok "a copy (tmux-agent-state.sh.bak) is not tagents' hook either" 2 "$(jq '.hooks.Notification | length' "$F")"
ok "an event nobody here knows is left alone" '[{"hooks":[]}]' "$(jq -c '.hooks.MyCustomEvent' "$F")"
ok "the old events keep their place, the new ones follow in the registration's order" \
   "Stop PreToolUse UserPromptSubmit Notification MyCustomEvent SessionStart PostToolUse SubagentStop SessionEnd" "$(jq -r '.hooks | keys_unsorted | join(" ")' "$F")"
ok "the keys outside hooks stay where they were, the status line comes last" \
   "permissions env model note ratio count flag nothing hooks zzz statusLine" "$(jq -r 'keys_unsorted | join(" ")' "$F")"
ok "the old file is kept, byte for byte" yes "$(cmp -s "$(bak_of "$F")" "$E/before.json" && echo yes || echo no)"
ok "...once" 1 "$(baks "$F")"
contains "the backup is named in the output" "$(basename "$(bak_of "$F")")" "$OUT"

# The edge of a script's name is anything that cannot belong to a longer file name: a letter, a digit, ., _, + or - touching it makes it another file's name. my-... and ....bak are above; these are the rest of that class.
mkenv lookalikes; F=$H/.claude/settings.json
cat >"$F" <<'EOF'
{"hooks": {
  "Stop":         [ { "hooks": [ { "type": "command", "command": "sh /x/old_tmux-agent-state.sh" } ] } ],
  "SessionEnd":   [ { "hooks": [ { "type": "command", "command": "sh /x/tmux-agent-state.sh_old" } ] } ],
  "Notification": [ { "hooks": [ { "type": "command", "command": "sh /x/tmux-agent-state.sh2" } ] } ],
  "SubagentStop": [ { "hooks": [ { "type": "command", "command": "sh /x/tmux-agent-state.sh+x" } ] } ],
  "SessionStart": [ { "hooks": [ { "type": "command", "command": "sh /x/tmux-agent-state.shx" } ] } ]
}}
EOF
run
ok "names that only begin or end like tagents' script: exit 0" 0 "$RC"
ok "...a _ before, a _ after, a digit, a + and a letter after: none is tagents' hook, so each event gets a group of its own" "2 2 2 2 2" \
   "$(jq -r '[.hooks.Stop, .hooks.SessionEnd, .hooks.Notification, .hooks.SubagentStop, .hooks.SessionStart | length] | join(" ")' "$F")"

# ---------------------------------------------------------------------------
t "3. tagents is already there, in the forms a real file has: nothing is written"
# ---------------------------------------------------------------------------
for form in single double bare; do
  mkenv "there-$form"; F=$H/.claude/settings.json
  case $form in single) dir=/Users/x/.claude/hooks ;; double) dir='$HOME/.claude/hooks' ;; bare) dir='~/.claude/hooks' ;; esac
  present "$form" "$dir" >"$F"; past "$F"
  s0=$(sum_of "$F"); m0=$(mtime_of "$F"); l0=$(listing "$H/.claude")
  run
  ok "$form quotes: exit 0" 0 "$RC"
  ok "$form quotes: the verb says it is already set up" "~/.claude/settings.json: already set up" "$OUT"
  ok "$form quotes: same bytes" "$s0" "$(sum_of "$F")"
  ok "$form quotes: same mtime" "$m0" "$(mtime_of "$F")"
  ok "$form quotes: no backup, no temp file, nothing new" "$l0" "$(listing "$H/.claude")"
done

# A redirection after the command and a bracket around it are no reason to add a second registration: what is looked for is the script's name with nothing of a longer file name touching it.
mkenv there-redirect; F=$H/.claude/settings.json
jq -n --arg ev "$EVENTS" --arg hook '$HOME/.claude/hooks/tmux-agent-state.sh>/dev/null 2>&1' --arg sl '(sh ~/.claude/hooks/claude-statusline.sh)' '
  {hooks: ([ $ev | split(" ")[] | {key: ., value: [{hooks: [{type: "command", command: $hook}]}]} ] | from_entries),
   statusLine: {type: "command", command: $sl}}' >"$F"; past "$F"
s0=$(sum_of "$F"); m0=$(mtime_of "$F"); l0=$(listing "$H/.claude")
run
ok "a redirection after each hook and a bracket around the status line: exit 0" 0 "$RC"
ok "...the verb says it is already set up" "~/.claude/settings.json: already set up" "$OUT"
ok "...same bytes" "$s0" "$(sum_of "$F")"
ok "...same mtime" "$m0" "$(mtime_of "$F")"
ok "...no backup, no temp file, nothing new" "$l0" "$(listing "$H/.claude")"

# ---------------------------------------------------------------------------
t "4. hooks on some events only: the missing ones are appended, the others are not touched"
# ---------------------------------------------------------------------------
mkenv some; F=$H/.claude/settings.json
present double '$HOME/.claude/hooks' Stop SessionEnd >"$F"
cp -p "$F" "$E/before.json"
run
ok "exit 0" 0 "$RC"
ok "everything that was there is still there" yes "$(kept_all "$E/before.json" "$F")"
ok "Stop and SessionEnd still have their one group" "1 1" "$(jq -r '[.hooks.Stop, .hooks.SessionEnd | length] | join(" ")' "$F")"
ok "the six others follow, in the registration's order, one group each" "Stop SessionEnd SessionStart UserPromptSubmit PreToolUse PostToolUse Notification SubagentStop" \
   "$(jq -r '.hooks | keys_unsorted | join(" ")' "$F")"
contains "the line names only the missing ones" "added the hooks for SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Notification, SubagentStop" "$OUT"
lacks "...not the ones it found" "Stop," "$OUT"
lacks "...and says nothing of the status line, which is tagents' own" "status line" "$OUT"

# ---------------------------------------------------------------------------
t "5. the status line: added when there is none, kept when it is somebody else's, left alone when it is ours"
# ---------------------------------------------------------------------------
mkenv foreign; F=$H/.claude/settings.json
printf '{"statusLine":{"type":"command","command":"my-line.sh"}}' >"$F"
cp -p "$F" "$E/before.json"
run
ok "a foreign status line: exit 0" 0 "$RC"
ok "...is kept" "my-line.sh" "$(jq -r '.statusLine.command' "$F")"
ok "...while the hooks are added" "$EVENTS" "$(jq -r '.hooks | keys_unsorted | join(" ")' "$F")"
contains "...and the line says it kept it, and what it runs" "my-line.sh" "$OUT"
contains "...and how to switch" "tagents setup --statusline" "$OUT"
run --statusline
ok "--statusline: exit 0" 0 "$RC"
ok "...replaces it with tagents' own" 'sh "$HOME/.claude/hooks/claude-statusline.sh"' "$(jq -r '.statusLine.command' "$F")"
ok "...keeps what it replaced: two backups now, the first of the original" 2 "$(baks "$F")"
ok "...the original among them" yes "$(bak_holds "$F" "$E/before.json")"
ok "...and the hooks are still there once each" "1" "$(jq -r '[.hooks[] | length] | unique | join(" ")' "$F")"
run
ok "a run after that has nothing left to do" "~/.claude/settings.json: already set up" "$OUT"

mkenv foreign-string; F=$H/.claude/settings.json
printf '{"statusLine":"echo hi"}' >"$F"
run
ok "a status line that is not an object: exit 0" 0 "$RC"
ok "...is kept as it is" '"echo hi"' "$(jq -c '.statusLine' "$F")"
contains "...and shown" '"echo hi"' "$OUT"

mkenv lookalike; F=$H/.claude/settings.json
printf '{"statusLine":{"type":"command","command":"sh /x/my-claude-statusline.sh"}}' >"$F"
run
ok "my-claude-statusline.sh is not tagents' status line" "sh /x/my-claude-statusline.sh" "$(jq -r '.statusLine.command' "$F")"
contains "...so it is reported as somebody else's" "tagents setup --statusline" "$OUT"

mkenv own-form; F=$H/.claude/settings.json
printf '{"statusLine":{"type":"command","command":"/opt/x/claude-statusline.sh --compact"}}' >"$F"
run
ok "tagents' own status line in another form: exit 0" 0 "$RC"
ok "...is left as it is" "/opt/x/claude-statusline.sh --compact" "$(jq -r '.statusLine.command' "$F")"
lacks "...without a word about a status line" "tagents setup --statusline" "$OUT"
past "$F"; s0=$(sum_of "$F"); m0=$(mtime_of "$F")
run --statusline
ok "--statusline does not replace what is already tagents' own" "$s0 $m0" "$(sum_of "$F") $(mtime_of "$F")"
ok "...it is already set up" "~/.claude/settings.json: already set up" "$OUT"

# ---------------------------------------------------------------------------
t "6. a file that is not safe to edit is left exactly as it is, and says why"
# ---------------------------------------------------------------------------
refused invalid-truncated '{"hooks": ' "not valid JSON"
refused invalid-comma '{"a": 1,}' "not valid JSON"
refused invalid-comment '// my settings
{}' "not valid JSON"
refused two-values '{} {}' "2 JSON values"
refused top-array '[]' "top level is array"
refused top-null 'null' "top level is null"
refused hooks-string '{"hooks": "none"}' '"hooks" is string'
refused hooks-null '{"hooks": null}' '"hooks" is null'
refused event-object '{"hooks": {"Stop": {"hooks": []}}}' '"hooks.Stop" is object'
refused event-string '{"hooks": {"SessionEnd": "x"}}' '"hooks.SessionEnd" is string'

mkenv others-go-on
mkdir -p "$H/.claude-a" "$H/.claude-b"; printf '{"hooks": ' >"$H/.claude-a/settings.json"; printf '{"model":"opus"}' >"$H/.claude-b/settings.json"
past "$H/.claude-a/settings.json"; s0=$(sum_of "$H/.claude-a/settings.json")
run --config-dir "$H/.claude-a" --config-dir "$H/.claude-b"
ok "one refused file does not stop the next: exit 1 at the end" 1 "$RC"
ok "...the refused file is as it was" "$s0" "$(sum_of "$H/.claude-a/settings.json")"
ok "...the next one is set up" "$EVENTS" "$(jq -r '.hooks | keys_unsorted | join(" ")' "$H/.claude-b/settings.json")"
contains "...and the refusal names the first file" "~/.claude-a/settings.json" "$ERR"

mkenv readonly; F=$H/.claude/settings.json; printf '{"model":"opus"}' >"$F"; chmod 444 "$F"; s0=$(sum_of "$F")
run
if [ "$(id -u)" != 0 ]; then
  ok "a read-only file is refused" 1 "$RC"
  ok "...and keeps its bytes" "$s0" "$(sum_of "$F")"
  contains "...with the reason" "read-only" "$ERR"
  run --check
  ok "--check says the run would refuse it: exit 1" 1 "$RC"
  contains "...with the reason" "read-only" "$ERR"
fi
chmod 644 "$F"

# A file a dotfiles manager keeps read-only (a link into a read-only store) that already has everything is set up, not refused: it is only asked whether it can be written when something has to be added.
mkenv readonly-done; F=$H/.claude/settings.json; present double '$HOME/.claude/hooks' >"$F"; chmod 444 "$F"; s0=$(sum_of "$F")
chmod 555 "$H/.claude"
run
ok "a read-only file in a read-only directory that has everything: exit 0" 0 "$RC"
ok "...says it is already set up" "~/.claude/settings.json: already set up" "$OUT"
ok "...and keeps its bytes" "$s0" "$(sum_of "$F")"
chmod 755 "$H/.claude"; chmod 644 "$F"

# Branches that are reached by a settings.json that is not a file, a directory that cannot be written to, and a hook script that cannot be read.
mkenv notafile; F=$H/.claude/settings.json; mkdir "$F"
run
ok "a settings.json that is a directory: exit 1" 1 "$RC"
contains "...says it is not a regular file" "is not a regular file" "$ERR"
ok "...and the directory is as it was" "" "$(listing "$F")"

if [ "$(id -u)" != 0 ]; then
  mkenv rodir; F=$H/.claude/settings.json; printf '{"model":"opus"}' >"$F"; s0=$(sum_of "$F"); chmod 555 "$H/.claude"
  run
  ok "a read-only config dir whose settings.json needs something: exit 1" 1 "$RC"
  contains "...says the directory cannot be written to" "its directory cannot be written to" "$ERR"
  ok "...the file has the bytes it had" "$s0" "$(sum_of "$F")"
  ok "...and nothing is beside it" "hooks settings.json" "$(listing "$H/.claude")"
  chmod 755 "$H/.claude"

  mkenv rodir-new; F=$H/.claude/settings.json; chmod 555 "$H/.claude"
  run
  ok "a read-only config dir with no settings.json: exit 1" 1 "$RC"
  contains "...says the directory cannot be written to" "its directory cannot be written to" "$ERR"
  ok "...and no file is made" no "$([ -e "$F" ] && echo yes || echo no)"
  chmod 755 "$H/.claude"

  mkenv unreadable-script; F=$H/.claude/settings.json; chmod 000 "$H/.claude/hooks/claude-statusline.sh"
  run
  ok "a hook script that cannot be read, in the only hooks directory: exit 1" 1 "$RC"
  contains "...so no hooks directory holds the scripts" "no hooks directory holds" "$ERR"
  ok "...and no settings.json is made" "hooks" "$(listing "$H/.claude")"
  chmod 644 "$H/.claude/hooks/claude-statusline.sh"
fi

# ---------------------------------------------------------------------------
t "7. a second run writes nothing"
# ---------------------------------------------------------------------------
mkenv twice; F=$H/.claude/settings.json; printf '{"model":"opus"}' >"$F"
run
ok "the first run writes: exit 0" 0 "$RC"
past "$F"; s0=$(sum_of "$F"); m0=$(mtime_of "$F"); l0=$(listing "$H/.claude")
run
ok "the second run: exit 0" 0 "$RC"
ok "...says it is already set up" "~/.claude/settings.json: already set up" "$OUT"
ok "...the same bytes" "$s0" "$(sum_of "$F")"
ok "...the same mtime" "$m0" "$(mtime_of "$F")"
ok "...no new backup, no new file" "$l0" "$(listing "$H/.claude")"

# ---------------------------------------------------------------------------
t "8. a link stays a link, and it is the file at the end of it that changes"
# ---------------------------------------------------------------------------
# A profile whose settings.json is a link to ~/.claude/settings.json is a common layout, and a link to a link is as common: dotfiles managers make them. The entry point of ./tagents follows its own link by hand with the same loop, so the same four shapes are walked here and the two copies of the rule are compared below.
mkenv links; F=$H/.claude/settings.json
mkdir -p "$H/dotfiles/real"; printf '{"model":"opus"}' >"$H/dotfiles/real/settings.json"
ln -s real/settings.json "$H/dotfiles/mid.json"; ln -s ../dotfiles/mid.json "$F"
run
ok "a relative link to a relative link: exit 0" 0 "$RC"
ok "...the first link is still that link" "../dotfiles/mid.json" "$(readlink "$F")"
ok "...and so is the second" "real/settings.json" "$(readlink "$H/dotfiles/mid.json")"
ok "...the real file has the registration" "$EVENTS" "$(jq -r '.hooks | keys_unsorted | join(" ")' "$H/dotfiles/real/settings.json")"
ok "...and the model it had" opus "$(jq -r '.model' "$H/dotfiles/real/settings.json")"
ok "...its backup sits beside the real file" 1 "$(baks "$H/dotfiles/real/settings.json")"
ok "...and nothing was left beside the links" "hooks settings.json" "$(listing "$H/.claude")"
ok "...nor between them" "mid.json real" "$(listing "$H/dotfiles")"
contains "...the line says where the file really is" "(a link to ~/dotfiles/real/settings.json)" "$OUT"

for shape in abs rel chain absrel; do
  mkenv "shape-$shape"; F=$H/.claude/settings.json
  mkdir -p "$H/real" "$H/mid"; printf '{"model":"opus"}' >"$H/real/settings.json"
  case $shape in
    abs)    ln -s "$H/real/settings.json" "$F" ;;
    rel)    ln -s ../real/settings.json "$F" ;;
    chain)  ln -s settings.json.2 "$F"; ln -s ../real/settings.json "$H/.claude/settings.json.2" ;;
    absrel) ln -s "$H/mid/settings.json" "$F"; ln -s ../real/settings.json "$H/mid/settings.json" ;;
  esac
  run
  ok "link shape $shape: exit 0" 0 "$RC"
  ok "link shape $shape: still a link" yes "$([ -L "$F" ] && echo yes || echo no)"
  ok "link shape $shape: the real file has the registration" "$EVENTS" "$(jq -r '.hooks | keys_unsorted | join(" ")' "$H/real/settings.json")"
  ok "link shape $shape: the backup is beside it" 1 "$(baks "$H/real/settings.json")"
  ok "link shape $shape: and not beside the link" 0 "$(baks "$F")"
done

# The two loops that follow a link by hand are the same text but for the names and the bound; if one of them is taught a new kind of link the other has to be, and this is where that is noticed. The block compared is the case that turns a link into the path it points at, with its two variables renamed.
arms() {  # <file> <the line that opens the case> <sed script that renames the link and the path variables>
  awk -v sel="$2" 'index($0, sel) { grab = 1 } grab { print } grab && /^    esac$/ { exit }' "$1" | sed -e "$3"
}
entry_arms=$(arms "$TA" 'case $ta_link in' 's/ta_link/LINK/g; s/ta_real/PATH_/g')
setup_arms=$(arms "$ROOT/lib/tagents/setup.sh" 'case $l in' 's/\$l\([^A-Za-z0-9_]\)/$LINK\1/g; s/\$f\([^A-Za-z0-9_]\)/$PATH_\1/g; s/{f%/{PATH_%/g; s/ f=/ PATH_=/g')
ok "the entry point's case that follows a link is found (7 lines)" 7 "$(printf '%s\n' "$entry_arms" | wc -l | tr -d ' ')"
ok "the arms that resolve a link in setup.sh are the ones in the entry point" "$entry_arms" "$setup_arms"

mkenv dangling; F=$H/.claude/settings.json; ln -s nowhere.json "$F"
run
ok "a link to nothing is refused" 1 "$RC"
contains "...with the reason" "is a link to nothing" "$ERR"
ok "...and nothing is created at the end of it, or beside it" "hooks settings.json" "$(listing "$H/.claude")"
ok "...the link is as it was" nowhere.json "$(readlink "$F")"

mkenv loop; F=$H/.claude/settings.json; ln -s b "$F"; ln -s settings.json "$H/.claude/b"
run
ok "a loop of links is refused, not followed for ever" 1 "$RC"
contains "...with the reason" "is a loop of links" "$ERR"

# ~/.claude is a link to dotfiles/claude and its settings.json links to ../shared/settings.json. The kernel opens ~/dotfiles/shared/settings.json; taking .. off the name ~/.claude/../shared leads to ~/shared, which holds a file of its own here.
mkenv dotdot-dirlink; rm -rf "$H/.claude"
mkdir -p "$H/dotfiles/claude" "$H/dotfiles/shared" "$H/shared"
stub_hooks "$H/dotfiles/claude/hooks"; ln -s dotfiles/claude "$H/.claude"
printf '{"model":"opus"}' >"$H/dotfiles/shared/settings.json"
ln -s ../shared/settings.json "$H/dotfiles/claude/settings.json"
printf '{"decoy":1}' >"$H/shared/settings.json"; d0=$(sum_of "$H/shared/settings.json")
run
ok "a config dir that is a link, holding a link with a .. in it: exit 0" 0 "$RC"
ok "...the file the kernel opens, ~/dotfiles/shared/settings.json, has the registration" "$EVENTS" "$(jq -r '.hooks | keys_unsorted | join(" ")' "$H/dotfiles/shared/settings.json")"
ok "...and the model it had" opus "$(jq -r '.model' "$H/dotfiles/shared/settings.json")"
ok "...its backup sits beside it" 1 "$(baks "$H/dotfiles/shared/settings.json")"
ok "...~/shared/settings.json, where the name without its .. leads, keeps its bytes" "$d0" "$(sum_of "$H/shared/settings.json")"
ok "...and nothing is put beside it" "settings.json" "$(listing "$H/shared")"
ok "...the link keeps its target" "../shared/settings.json" "$(readlink "$H/dotfiles/claude/settings.json")"

# ---------------------------------------------------------------------------
t "9. each file once, however many ways lead to it"
# ---------------------------------------------------------------------------
mkenv once-slash; F=$H/.claude/settings.json; printf '{"model":"opus"}' >"$F"
CLAUDE_CONFIG_DIR="$H/.claude/"; run; unset CLAUDE_CONFIG_DIR
ok "CLAUDE_CONFIG_DIR is ~/.claude with a slash: exit 0" 0 "$RC"
ok "...one line for the file" 1 "$(printf '%s\n' "$OUT" | grep -c 'settings.json:')"
ok "...one backup" 1 "$(baks "$F")"

mkenv once-link; F=$H/.claude/settings.json; printf '{"model":"opus"}' >"$F"
mkdir -p "$H/.claude-linked"; ln -s ../.claude/settings.json "$H/.claude-linked/settings.json"
CLAUDE_CONFIG_DIR="$H/.claude-linked"; run; unset CLAUDE_CONFIG_DIR
ok "two config dirs whose files are one file: exit 0" 0 "$RC"
ok "...the file is written once" 1 "$(baks "$F")"
contains "...and the second says it was the same file" "~/.claude-linked/settings.json: the same file as one handled above" "$OUT"
ok "...the link is still a link" ../.claude/settings.json "$(readlink "$H/.claude-linked/settings.json")"
ok "...with no backup beside it" 0 "$(baks "$H/.claude-linked/settings.json")"

mkenv once-reverse; F=$H/.claude/settings.json; printf '{"model":"opus"}' >"$F"
mkdir -p "$H/.claude-linked"; ln -s ../.claude/settings.json "$H/.claude-linked/settings.json"
run --config-dir "$H/.claude-linked" --config-dir "$H/.claude"
ok "reached through the link first: exit 0" 0 "$RC"
ok "...the real file is written once" 1 "$(baks "$F")"
contains "...and labelled as a link" "(a link to ~/.claude/settings.json)" "$OUT"
contains "...the other way round is the same file" "~/.claude/settings.json: the same file as one handled above" "$OUT"
ok "...and the commands name the hooks directory that has the scripts" 'sh "$HOME/.claude/hooks/tmux-agent-state.sh"' "$(jq -r '.hooks.Stop[0].hooks[0].command' "$F")"

mkenv once-dirlink; F=$H/.claude/settings.json
ln -s .claude "$H/dirlink"
run --config-dir "$H/.claude" --config-dir "$H/dirlink"
ok "a directory and a link to it: one line" 1 "$(printf '%s\n' "$OUT" | grep -c 'settings.json:')"

# The same .. below a link, typed as a --config-dir: it names ~/dotfiles/shared, so ~/shared, where the name without its .. leads, is another directory and is set up too, not skipped as one seen already.
mkenv dotdot-key; rm -rf "$H/.claude"
mkdir -p "$H/dotfiles/claude" "$H/dotfiles/shared" "$H/shared"
stub_hooks "$H/dotfiles/claude/hooks"; ln -s dotfiles/claude "$H/.claude"
printf '{"model":"opus"}' >"$H/dotfiles/shared/settings.json"; printf '{"model":"opus"}' >"$H/shared/settings.json"
run --config-dir "$H/.claude/../shared" --config-dir "$H/shared"
ok "a --config-dir with a .. below a link, and the directory the name without the .. leads to: exit 0" 0 "$RC"
ok "...the directory the kernel takes the first to is set up" "$EVENTS" "$(jq -r '.hooks | keys_unsorted | join(" ")' "$H/dotfiles/shared/settings.json")"
ok "...and so is the second, not skipped as the same one" "$EVENTS" "$(jq -r '.hooks | keys_unsorted | join(" ")' "$H/shared/settings.json")"

# The first of two links to one file has no hooks directory and the second has: the file is set up through the second, not skipped as handled by the first.
mkenv once-nohooks; rm -rf "$H/.claude/hooks"
mkdir -p "$H/.claude-a" "$H/.claude-b"; stub_hooks "$H/.claude-b/hooks"
printf '{"model":"opus"}' >"$H/shared.json"
ln -s ../shared.json "$H/.claude-a/settings.json"; ln -s ../shared.json "$H/.claude-b/settings.json"
run --config-dir "$H/.claude-a" --config-dir "$H/.claude-b"
ok "two links to one file, the first without a hooks directory: exit 1" 1 "$RC"
contains "...the error is for the first" "~/.claude-a/settings.json (a link to ~/shared.json): no hooks directory holds" "$ERR"
ok "...the file is set up through the second" "$EVENTS" "$(jq -r '.hooks | keys_unsorted | join(" ")' "$H/shared.json")"
ok "...with commands that name the second one's hooks directory" 'sh "$HOME/.claude-b/hooks/tmux-agent-state.sh"' "$(jq -r '.hooks.Stop[0].hooks[0].command' "$H/shared.json")"
lacks "...and nothing says the file was handled above" "the same file as one handled above" "$OUT$ERR"

mkenv env-missing
CLAUDE_CONFIG_DIR="$H/.claude-missing"; run; unset CLAUDE_CONFIG_DIR
ok "CLAUDE_CONFIG_DIR names a directory that is not there: exit 0" 0 "$RC"
contains "...it is skipped, with the name it came from" "~/.claude-missing (CLAUDE_CONFIG_DIR): no such directory, skipped" "$OUT"
ok "...and ~/.claude is still set up" "$EVENTS" "$(jq -r '.hooks | keys_unsorted | join(" ")' "$H/.claude/settings.json")"

# ---------------------------------------------------------------------------
t "10. the profiles of the config are config dirs too"
# ---------------------------------------------------------------------------
mkenv profiles
cat >"$H/.config/tagents/config.toml" <<'EOF'
[claude.profiles.work]
config_dir = "~/.claude-work"

[claude.profiles.personal]
config_dir = "~/.claude-personal"

[claude.profiles.ghost]
config_dir = "~/.claude-ghost"

[claude.profiles.plain]
EOF
mkdir -p "$H/.claude-work" "$H/.claude-personal"
run
ok "profiles whose config_dir exists, and one that does not: exit 0" 0 "$RC"
ok "...work is set up" "$EVENTS" "$(jq -r '.hooks | keys_unsorted | join(" ")' "$H/.claude-work/settings.json")"
ok "...personal is set up" "$EVENTS" "$(jq -r '.hooks | keys_unsorted | join(" ")' "$H/.claude-personal/settings.json")"
ok "...so is the default one" "$EVENTS" "$(jq -r '.hooks | keys_unsorted | join(" ")' "$H/.claude/settings.json")"
contains "...ghost is skipped with a note" "~/.claude-ghost (profile ghost): no such directory, skipped" "$OUT"
ok "...and not created" no "$([ -e "$H/.claude-ghost" ] && echo yes || echo no)"
ok "...their commands name the hooks directory that has the scripts" 'sh "$HOME/.claude/hooks/tmux-agent-state.sh"' "$(jq -r '.hooks.Stop[0].hooks[0].command' "$H/.claude-work/settings.json")"
ok "...a profile without a config_dir adds nothing (it is the default account)" 3 "$(printf '%s\n' "$OUT" | grep -c 'settings.json:')"

mkenv config-dir-only
cat >"$H/.config/tagents/config.toml" <<'EOF'
[claude.profiles.work]
config_dir = "~/.claude-work"
EOF
mkdir -p "$H/.claude-work" "$H/.claude-named"
run --config-dir "$H/.claude-named"
ok "--config-dir replaces the default set" "no no yes" "$([ -e "$H/.claude/settings.json" ] && echo -n 'yes ' || echo -n 'no '; [ -e "$H/.claude-work/settings.json" ] && echo -n 'yes ' || echo -n 'no '; [ -e "$H/.claude-named/settings.json" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
t "11. which hooks directory the commands name"
# ---------------------------------------------------------------------------
cmd_of() { jq -r '.hooks.Stop[0].hooks[0].command' "$1"; }
mkenv hd-own
stub_hooks "$H/.claude-b/hooks"; stub_hooks "$H/custom/hooks"
run --config-dir "$H/.claude-b" --hooks-dir "$H/custom/hooks"
ok "D/hooks holds the scripts: the commands name it, through \$HOME" 'sh "$HOME/.claude-b/hooks/tmux-agent-state.sh"' "$(cmd_of "$H/.claude-b/settings.json")"
ok "...and so does the status line" 'sh "$HOME/.claude-b/hooks/claude-statusline.sh"' "$(jq -r '.statusLine.command' "$H/.claude-b/settings.json")"

mkenv hd-arg
mkdir -p "$H/.claude-b"; stub_hooks "$H/custom/hooks"
run --config-dir "$H/.claude-b" --hooks-dir "$H/custom/hooks"
ok "only a --hooks-dir holds them (and ~/.claude/hooks does too): the --hooks-dir wins" 'sh "$HOME/custom/hooks/tmux-agent-state.sh"' "$(cmd_of "$H/.claude-b/settings.json")"

mkenv hd-two
mkdir -p "$H/.claude-b"; stub_hooks "$H/one/hooks"; stub_hooks "$H/two/hooks"
run --config-dir "$H/.claude-b" --hooks-dir "$H/two/hooks" --hooks-dir "$H/one/hooks"
ok "two --hooks-dir: the first one given wins" 'sh "$HOME/two/hooks/tmux-agent-state.sh"' "$(cmd_of "$H/.claude-b/settings.json")"

mkenv hd-default
mkdir -p "$H/.claude-b"
run --config-dir "$H/.claude-b"
ok "nothing else holds them: ~/.claude/hooks does" 'sh "$HOME/.claude/hooks/tmux-agent-state.sh"' "$(cmd_of "$H/.claude-b/settings.json")"

mkenv hd-half
mkdir -p "$H/.claude-b/hooks"; printf '#!/bin/sh\n' >"$H/.claude-b/hooks/tmux-agent-state.sh"
run --config-dir "$H/.claude-b"
ok "a hooks directory with one of the two scripts does not count" 'sh "$HOME/.claude/hooks/tmux-agent-state.sh"' "$(cmd_of "$H/.claude-b/settings.json")"

mkenv hd-none
rm -rf "$H/.claude/hooks"; mkdir -p "$H/.claude-b"
run --config-dir "$H/.claude-b"
ok "no directory holds them: refused" 1 "$RC"
contains "...the message says to run install.sh" "install.sh" "$ERR"
contains "...and names both scripts" "claude-statusline.sh and tmux-agent-state.sh" "$ERR"
ok "...and nothing is created" no "$([ -e "$H/.claude-b/settings.json" ] && echo yes || echo no)"

mkenv hd-relative
mkdir -p "$H/.claude-b" "$H/rel/hooks"; stub_hooks "$H/rel/hooks"
( cd "$H/rel" && env -i PATH="$PATH" HOME="$H" XDG_CONFIG_HOME="$H/.config" TA_CONFIG="$H/.config/tagents/config.toml" TMPDIR="$TMPD" "$BASH_BIN" "$TA" setup --config-dir ../.claude-b --hooks-dir hooks >/dev/null 2>&1 )
ok "a relative --hooks-dir is read from where the verb was run" 'sh "$HOME/rel/hooks/tmux-agent-state.sh"' "$(cmd_of "$H/.claude-b/settings.json")"

# ---------------------------------------------------------------------------
t "12. a hooks directory whose name has a quote, a dollar sign, a backtick, a backslash and a space in it"
# ---------------------------------------------------------------------------
ODD='odd "d" $x `b` \back'
mkenv odd-outside
rm -rf "$H/.claude/hooks"; mkdir -p "$H/.claude-b"
stub_hooks "$TMP/outside/$ODD/hooks"
run --config-dir "$H/.claude-b" --hooks-dir "$TMP/outside/$ODD/hooks"
ok "a hooks directory outside \$HOME: exit 0" 0 "$RC"
want='sh "'$TMP'/outside/odd \"d\" \$x \`b\` \\back/hooks/tmux-agent-state.sh"'
ok "...is written as the absolute path, escaped for the inside of double quotes" "$want" "$(cmd_of "$H/.claude-b/settings.json")"
ok "...and the command, run by sh, runs the script" hook-ran "$(sh -c "$(cmd_of "$H/.claude-b/settings.json")")"
ok "...and so does the status line" line-ran "$(sh -c "$(jq -r '.statusLine.command' "$H/.claude-b/settings.json")")"

mkenv odd-inside
rm -rf "$H/.claude/hooks"; mkdir -p "$H/.claude-b"
stub_hooks "$H/$ODD/hooks"
run --config-dir "$H/.claude-b" --hooks-dir "$H/$ODD/hooks"
ok "a hooks directory under \$HOME: exit 0" 0 "$RC"
want='sh "$HOME/odd \"d\" \$x \`b\` \\back/hooks/tmux-agent-state.sh"'
ok "...keeps a literal \$HOME and escapes the rest" "$want" "$(cmd_of "$H/.claude-b/settings.json")"
ok "...and the command, run by sh with that HOME, runs the script" hook-ran "$(HOME=$H sh -c "$(cmd_of "$H/.claude-b/settings.json")")"

# ---------------------------------------------------------------------------
t "13. --check says what is missing and writes nothing"
# ---------------------------------------------------------------------------
mkenv check-missing; F=$H/.claude/settings.json
run --check
ok "--check with no settings.json: exit 1" 1 "$RC"
contains "...says what would be added" "~/.claude/settings.json: would add the hooks for SessionStart" "$OUT"
ok "...and creates nothing" "hooks" "$(listing "$H/.claude")"

mkenv check-file; F=$H/.claude/settings.json; printf '{"model":"opus"}' >"$F"; past "$F"
s0=$(sum_of "$F"); m0=$(mtime_of "$F"); l0=$(listing "$H/.claude")
run --check
ok "--check with a file that lacks the hooks: exit 1" 1 "$RC"
ok "...writes nothing: same bytes" "$s0" "$(sum_of "$F")"
ok "...same mtime" "$m0" "$(mtime_of "$F")"
ok "...no backup, no temp file" "$l0" "$(listing "$H/.claude")"
run
run --check
ok "--check once everything is in place: exit 0" 0 "$RC"
ok "...says so" "~/.claude/settings.json: already set up" "$OUT"

mkenv check-foreign; F=$H/.claude/settings.json; present double '$HOME/.claude/hooks' >"$F"
jq '.statusLine = {type: "command", command: "my-line.sh"}' "$F" >"$E/x.json" && mv "$E/x.json" "$F"
run --check
ok "--check: a status line of your own that is kept is a choice, not something missing: exit 0" 0 "$RC"
contains "...and it is still mentioned" "tagents setup --statusline" "$OUT"
run --check --statusline
ok "--check --statusline: it would be replaced, so something is missing: exit 1" 1 "$RC"
contains "...and the line says so" "would replace the status line" "$OUT"

mkenv check-invalid; F=$H/.claude/settings.json; printf '{"a":' >"$F"
run --check
ok "--check on a file that would be refused: exit 1" 1 "$RC"
contains "...with the same message" "not valid JSON" "$ERR"

# ---------------------------------------------------------------------------
t "14. modes, quiet, the temp directory"
# ---------------------------------------------------------------------------
mkenv mode600; F=$H/.claude/settings.json; printf '{"env":{"KEY":"secret"}}' >"$F"; chmod 600 "$F"
run
ok "mode 600 survives a write" 600 "$(mode_of "$F")"
ok "...and the backup is not wider than the file was" 600 "$(mode_of "$(bak_of "$F")")"

mkenv mode640; F=$H/.claude/settings.json; printf '{}' >"$F"; chmod 640 "$F"
run
ok "mode 640 survives a write" 640 "$(mode_of "$F")"

mkenv umask077; F=$H/.claude/settings.json
old=$(umask); umask 077; run; umask "$old"
ok "a new file follows the umask: 077 gives 600" 600 "$(mode_of "$F")"

mkenv quiet; F=$H/.claude/settings.json
run --quiet
ok "--quiet: a write says nothing" "" "$OUT"
ok "...and succeeds" 0 "$RC"
mkenv quiet-bad; F=$H/.claude/settings.json; printf '{"a":' >"$F"
run --quiet
ok "--quiet: a refusal is still said" 1 "$RC"
contains "...on stderr" "not valid JSON" "$ERR"
mkenv quiet-foreign; F=$H/.claude/settings.json; printf '{"statusLine":"x"}' >"$F"
run --quiet
ok "--quiet: the note about a kept status line is not an error, so it is not said" "" "$OUT$ERR"

# ---------------------------------------------------------------------------
t "15. the command line"
# ---------------------------------------------------------------------------
mkenv usage
run --config-dir "$H/nope"
ok "--config-dir naming a directory that is not there: exit 1" 1 "$RC"
contains "...says so" "~/nope: there is no such directory" "$ERR"
run --config-dir "$H/nope" --config-dir "$H/.claude"
ok "...and the other directories are still done" "$EVENTS" "$(jq -r '.hooks | keys_unsorted | join(" ")' "$H/.claude/settings.json")"
run --bogus
ok "an unknown option: exit 2" 2 "$RC"
contains "...is named" "unknown option --bogus" "$ERR"
contains "...with the usage" "usage: tagents setup" "$ERR"
run extra
ok "an argument that is not an option: exit 2" 2 "$RC"
run --config-dir
ok "--config-dir without a directory: exit 2" 2 "$RC"
run --hooks-dir
ok "--hooks-dir without a directory: exit 2" 2 "$RC"
run --help
ok "--help: exit 0" 0 "$RC"
contains "...prints the usage" "usage: tagents setup [--check] [--statusline]" "$OUT"
mkenv nodefault
rm -rf "$H/.claude"
run
ok "no config directory at all: exit 0, there was nothing to do" 0 "$RC"
contains "...and it says so" "~/.claude: no such directory, skipped" "$OUT"
contains "...and what to do once Claude Code has made it" "start Claude Code once, then run tagents setup" "$OUT"

# ---------------------------------------------------------------------------
t "16. Claude Code writes the file too: a change between the read and the rename is not lost"
# ---------------------------------------------------------------------------
# A cmp that, for the first N calls, changes the settings file the way a running Claude Code would, and then compares. The verb compares the real file with the bytes it read just before it renames, so that is where the change has to land.
mkdir -p "$TMP/shim"
cat >"$TMP/shim/cmp" <<'EOF'
#!/bin/sh
n=$(cat "$SHIM_DIR/n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$SHIM_DIR/n"
if [ "$n" -le "$SHIM_TIMES" ]; then
  jq --argjson n "$n" '.concurrent = $n' "$SHIM_TARGET" >"$SHIM_TARGET.x" && mv "$SHIM_TARGET.x" "$SHIM_TARGET"
fi
if [ -n "${SHIM_SIGNAL:-}" ]; then kill -"$SHIM_SIGNAL" "$PPID"; fi
exec "$SHIM_CMP" "$@"
EOF
chmod +x "$TMP/shim/cmp"

mkenv race-once; F=$H/.claude/settings.json; printf '{"model":"opus"}' >"$F"; mkdir -p "$E/shim"
XENV="PATH=$TMP/shim:$PATH SHIM_DIR=$E/shim SHIM_TARGET=$F SHIM_TIMES=1 SHIM_CMP=$(command -v cmp)"
run
ok "a change in between: exit 0, the plan is made again" 0 "$RC"
ok "...what the other writer wrote is in the file" 1 "$(jq -r '.concurrent' "$F")"
ok "...and so is the registration" "$EVENTS" "$(jq -r '.hooks | keys_unsorted | join(" ")' "$F")"
ok "...one backup, of the version that was replaced" 1 "$(baks "$F")"
ok "...and it holds what the other writer wrote" 1 "$(jq -r '.concurrent' "$(bak_of "$F")")"
XENV=''

mkenv race-always; F=$H/.claude/settings.json; printf '{"model":"opus"}' >"$F"; mkdir -p "$E/shim"
XENV="PATH=$TMP/shim:$PATH SHIM_DIR=$E/shim SHIM_TARGET=$F SHIM_TIMES=99 SHIM_CMP=$(command -v cmp)"
run
ok "a file that changes every time: refused after three tries" 1 "$RC"
contains "...with the reason" "kept changing" "$ERR"
ok "...three tries were made and no more" 3 "$(jq -r '.concurrent' "$F")"
ok "...and the file is the other writer's, with nothing of ours in it" null "$(jq -r '.hooks | tostring' "$F")"
ok "...no backup is left of a write that did not happen" 0 "$(baks "$F")"
XENV=''

# A signal in the middle of a write: the shim sends it to the verb from inside the compare, which is after the backup is made and before the rename, and bash runs the trap when the shim returns. The trap has to take the temp file, the backup of a write that did not happen and the scratch directory with it, and the verb answers 128 plus the signal. TERM, because an INT that arrives while a child runs is treated differently by bash 3.2 and 5.
mkenv killed; F=$H/.claude/settings.json; printf '{"model":"opus"}' >"$F"; mkdir -p "$E/shim"; past "$F"
s0=$(sum_of "$F"); m0=$(mtime_of "$F")
XENV="PATH=$TMP/shim:$PATH SHIM_DIR=$E/shim SHIM_TARGET=$F SHIM_TIMES=0 SHIM_SIGNAL=TERM SHIM_CMP=$(command -v cmp)"
run
XENV=''
ok "TERM in the middle of a write: the verb answers 143" 143 "$RC"
ok "...the file keeps its bytes" "$s0" "$(sum_of "$F")"
ok "...and its mtime" "$m0" "$(mtime_of "$F")"
ok "...no backup is left of a write that did not happen" 0 "$(baks "$F")"
ok "...no temp file is left beside it" "hooks settings.json" "$(listing "$H/.claude")"
ok "...and the scratch directory is gone" "" "$(listing "$TMPD")"

# ---------------------------------------------------------------------------
t "17. how the verb is reached"
# ---------------------------------------------------------------------------
help=$("$BASH_BIN" "$TA" --help 2>&1)
contains "tagents --help lists the verb" "tagents setup [--check] [--statusline]" "$help"
contains "...and the update entry says it runs it" "then run \`tagents setup\`" "$help"

mkenv notcore
mkdir -p "$TMP/corebin"; printf '#!/bin/sh\n: >"$CORE_CALLED"\nexit 97\n' >"$TMP/corebin/tagents-core"; chmod +x "$TMP/corebin/tagents-core"
XENV="PATH=$TMP/corebin:$PATH CORE_CALLED=$TMP/core.called"
run --check
ok "setup is the dashboard's own verb: it is not handed to tagents-core" no "$([ -e "$TMP/core.called" ] && echo yes || echo no)"
ok "...and answers with its own exit code" 1 "$RC"
XENV=''

mkenv via-link
mkdir -p "$TMP/lk"; ln -sf "$TA" "$TMP/lk/a"; ln -sf "$TMP/lk/a" "$TMP/lk/b"
OUT=$(env -i PATH="$PATH" HOME="$H" XDG_CONFIG_HOME="$H/.config" TA_CONFIG="$H/.config/tagents/config.toml" TMPDIR="$TMPD" "$BASH_BIN" "$TMP/lk/b" setup --check 2>&1); RC=$?
ok "reached through a link to a link, it finds the registration beside the real file" 1 "$RC"
contains "...and reads it" "would add the hooks for SessionStart" "$OUT"

OUT=$(cd "$ROOT" && env -i PATH="$PATH" HOME="$H" XDG_CONFIG_HOME="$H/.config" TA_CONFIG="$H/.config/tagents/config.toml" TMPDIR="$TMPD" "$BASH_BIN" tagents setup --check 2>&1); RC=$?
ok "run as 'bash tagents' from the checkout's root, it finds the registration too" 1 "$RC"
contains "...and reads it" "would add the hooks for SessionStart" "$OUT"

mkenv lonely
mkdir -p "$TMP/lonely"; cp -R "$ROOT/lib" "$TMP/lonely/lib"; cp "$TA" "$TMP/lonely/tagents"
OUT=$(env -i PATH="$PATH" HOME="$H" XDG_CONFIG_HOME="$H/.config" TA_CONFIG="$H/.config/tagents/config.toml" TMPDIR="$TMPD" "$BASH_BIN" "$TMP/lonely/tagents" setup --check 2>&1); RC=$?
ok "a checkout without hooks/claude-settings.json: exit 1" 1 "$RC"
contains "...says what is missing" "cannot read $TMP/lonely/hooks/claude-settings.json" "$OUT"
ok "...and touches nothing" "hooks" "$(listing "$H/.claude")"

mkenv nojq
mkdir -p "$TMP/empty-bin"
OUT=$(env -i PATH="$TMP/empty-bin" HOME="$H" XDG_CONFIG_HOME="$H/.config" TA_CONFIG="$H/.config/tagents/config.toml" TMPDIR="$TMPD" "$BASH_BIN" "$TA" setup 2>&1); RC=$?
ok "without jq: exit 1" 1 "$RC"
contains "...says what to install" "jq is not installed" "$OUT"
ok "...and touches nothing" "hooks" "$(listing "$H/.claude")"

# A jq that cannot run the program (one without walk/1, say) is reported once, as what it is, and not as a fault of every file. The shim fails the way such a jq does when it is given the merge program's --slurpfile, and is the real jq for everything else.
mkenv oldjq
mkdir -p "$TMP/jqshim"
cat >"$TMP/jqshim/jq" <<'EOF'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = --slurpfile ]; then echo 'jq: error: walk/1 is not defined' >&2; exit 3; fi
done
exec "$REAL_JQ" "$@"
EOF
chmod +x "$TMP/jqshim/jq"
mkdir -p "$H/.claude-a" "$H/.claude-b"; printf '{"model":"opus"}' >"$H/.claude-a/settings.json"; printf '{"model":"opus"}' >"$H/.claude-b/settings.json"
sa=$(sum_of "$H/.claude-a/settings.json"); sb=$(sum_of "$H/.claude-b/settings.json")
XENV="PATH=$TMP/jqshim:$PATH REAL_JQ=$(command -v jq)"
run --config-dir "$H/.claude-a" --config-dir "$H/.claude-b"
XENV=''
ok "a jq that cannot run the program: exit 1" 1 "$RC"
ok "...says so once, for the whole run" 1 "$(printf '%s\n' "$ERR" | grep -c 'cannot run setup')"
contains "...with the words jq used" "walk/1 is not defined" "$ERR"
lacks "...and does not blame the files" "not valid JSON" "$ERR"
ok "...both files keep their bytes" "$sa $sb" "$(sum_of "$H/.claude-a/settings.json") $(sum_of "$H/.claude-b/settings.json")"
ok "...and nothing is beside them" "settings.json settings.json" "$(listing "$H/.claude-a") $(listing "$H/.claude-b")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
