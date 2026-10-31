#!/usr/bin/env bash
#
# tests/config.sh — the config parser, the rules and the command builder.
#
# No tmux, no fzf, no Claude: everything here goes through the three debugging
# entry points (--config, --profile-for, --agent-cmd), which is also how a user
# is meant to find out why a rule is not firing. Fixtures are written into a
# mktemp dir and pointed at with $TA_CONFIG, so nothing touches the real one.
#
# bash 3.2, runnable from any cwd, non-zero exit when any check fails.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# A suite that is not run against a scratch default server aborts here, before it can reach the live one (tests/scratch-guard.sh).
. "$HERE/scratch-guard.sh" && scratch_guard config.sh || exit 1
TA="$HERE/../tagents"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tagents-cfg.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

TAB=$(printf '\t')
pass=0; fail=0

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

t() { printf '\n%s\n' "$1"; }

# ---------------------------------------------------------------------------
t "1. the example, and what is not a config"
# ---------------------------------------------------------------------------

# The shipped example is the parser reference: if it stops flattening to this,
# every rule in every real config is suspect. The reader's own constructs
# (quotes, comments, arrays, tables, refusals) are tests/config-toml.sh.
want=$(cat <<'EOF'
claude.args	--dangerously-skip-permissions
claude.profiles.personal.config_dir	~/.claude-personal
claude.profiles.work	
claude.rules.0.dir	~/git/personal
claude.rules.0.profile	personal
claude.rules.1.dir	~/git/work
claude.rules.1.profile	work
claude.rules.2.session	personal
claude.rules.2.profile	personal
claude.rules.3.session	work
claude.rules.3.profile	work
usage.monthly_limit_usd	850
usage.safety_margin_pct	5
usage.workdays	true
usage.meter	2026-09-10 15:30 = 684.66
notes.send	reference
resurrect.auto	true
resurrect.every	300
resurrect.notes	reopen
keys.closed	ctrl-y
EOF
)
EX="$HERE/../config.example.toml"
got=$(TA_CONFIG="$EX" bash "$TA" --config 2>&1)
ok "the TOML example flattens as documented" "$want" "$got"

# A directory is readable, so -r alone called it a config and handed it to awk.
mkdir -p "$TMP/adir"
out=$(TA_CONFIG="$TMP/adir" bash "$TA" --config 2>/dev/null); rc=$?
ok "a directory is not a config: exits 1" 1 "$rc"
ok "...and prints nothing"                "" "$out"
err=$(TA_CONFIG="$TMP/adir" bash "$TA" --config 2>&1 >/dev/null)
case "$err" in
  *"i/o error"*) fail=$((fail + 1)); printf '  FAIL raw awk error leaked to stderr\n' ;;
  *) pass=$((pass + 1)); printf '  ok   ...without a raw awk error\n' ;;
esac

# A per-host overlay: config.<host>.toml replaces the a.b subtrees it names and
# inherits the rest. TA_HOST stands in for `hostname -s`.
mkdir -p "$TMP/ov"
cp "$EX" "$TMP/ov/config.toml"
cat >"$TMP/ov/config.mbp.toml" <<'EOF'
[claude.profiles.sam]
badge = "s"
[claude.profiles.client]
config_dir = "~/.claude-client"
[[claude.rules]]
dir = "~/git"
profile = "sam"
EOF
got=$(TA_HOST=mbp TA_CONFIG="$TMP/ov/config.toml" bash "$TA" --config 2>&1)
contains "overlay: its profiles are there" "claude.profiles.client.config_dir	~/.claude-client" "$got"
case "$got" in *"claude.profiles.personal"*|*"claude.profiles.work"*) ov_base=kept ;; *) ov_base=gone ;; esac
ok "overlay: the base laptop's profiles are NOT (replaced, not merged)" gone "$ov_base"
ok "overlay: one rule, the overlay's" 1 "$(printf '%s\n' "$got" | grep -c '^claude\.rules\.[0-9]*\.dir')"
contains "overlay: claude.args is inherited from the base" "claude.args	--dangerously-skip-permissions" "$got"
contains "overlay: notes.send is inherited from the base" "notes.send	reference" "$got"
contains "overlay: so is usage" "usage.monthly_limit_usd	850" "$got"
ok "overlay: the overlay's profile is what a dir resolves to" sam \
   "$(TA_HOST=mbp TA_CONFIG="$TMP/ov/config.toml" bash "$TA" --profile-for "$HOME/git/x" 2>/dev/null)"
ok "overlay: a base profile is unknown here" 1 \
   "$(TA_HOST=mbp TA_CONFIG="$TMP/ov/config.toml" bash "$TA" --agent-cmd personal new >/dev/null 2>&1; echo $?)"
ok "overlay: another host sees only the base" "" \
   "$(TA_HOST=other TA_CONFIG="$TMP/ov/config.toml" bash "$TA" --config 2>/dev/null | grep -c client | sed 's/^0$//')"
ok "overlay: a missing overlay changes nothing" "$(TA_CONFIG="$EX" bash "$TA" --config 2>&1)" \
   "$(TA_HOST=nowhere TA_CONFIG="$EX" bash "$TA" --config 2>&1)"

# A machine answers to more than one name. On a Mac whose HostName was never set, `hostname -s` is whatever macOS derived last, and the overlay has to be found under the name that stays put (the LocalHostName) 
HB="$TMP/hostbin"; mkdir -p "$HB"
host_stub() {  # <what `hostname -s` says> <what `scutil --get LocalHostName` says; empty = scutil fails>
  printf '#!/bin/sh\ncase "${1:-}" in -s) echo %s ;; *) echo %s.local ;; esac\n' "$1" "$1" >"$HB/hostname"
  if [ -n "$2" ]; then printf '#!/bin/sh\n[ "$*" = "--get LocalHostName" ] && echo %s\n' "$2" >"$HB/scutil"
  else printf '#!/bin/sh\necho "scutil: nothing to say" >&2\nexit 1\n' >"$HB/scutil"; fi
  chmod +x "$HB/hostname" "$HB/scutil"
}
ov_named() { env -u TA_HOST PATH="$HB:$PATH" TA_CONFIG="$TMP/ov/config.toml" bash "$TA" --config; }  # the overlay fixture, under the stubbed names
ov_plain=$(TA_HOST=nowhere TA_CONFIG="$TMP/ov/config.toml" bash "$TA" --config 2>&1)  # the fixture with no overlay laid over it
cat >"$TMP/ov/config.second.toml" <<'EOF'
[claude.profiles.elsewhere]
badge = "e"
EOF
host_stub flaky mbp
contains "overlay: found under the LocalHostName when hostname -s names no file" \
  "claude.profiles.client.config_dir	~/.claude-client" "$(ov_named 2>&1)"
host_stub mbp second
got=$(ov_named 2>&1)
case "$got" in *"claude.profiles.elsewhere"*) ov_first=localhostname ;; *"claude.profiles.client"*) ov_first=hostname ;; *) ov_first=neither ;; esac
ok "overlay: the name hostname -s reports is looked under first" hostname "$ov_first"
host_stub flaky mbp
ok "overlay: TA_HOST is the only name looked under" "$ov_plain" \
   "$(env PATH="$HB:$PATH" TA_HOST=nowhere TA_CONFIG="$TMP/ov/config.toml" bash "$TA" --config 2>&1)"
host_stub flaky ""
ok "overlay: a machine with no LocalHostName is its hostname, and says nothing about it" "$ov_plain" "$(ov_named 2>&1)"

# ---------------------------------------------------------------------------
t "2. rules"
# ---------------------------------------------------------------------------

pf() { TA_CONFIG="${CFG:-$EX}" bash "$TA" --profile-for "$@" 2>/dev/null; }

mkdir -p "$TMP/home/git/personal/x" "$TMP/home/git/work/y/z" "$TMP/home/git/personalx"
# The example config talks about ~/git/..., so the fixture has to be under the
# real $HOME to be the thing it names.
cat >"$TMP/rules.toml" <<EOF
[claude.profiles.personal]
config_dir = "~/.claude-personal"
[claude.profiles.work]
[[claude.rules]]
dir = "$TMP/home/git/personal"
profile = "personal"
[[claude.rules]]
dir = "$TMP/home/git/work"
profile = "work"
[[claude.rules]]
session = "personal"
profile = "personal"
[[claude.rules]]
session = "work"
profile = "work"
EOF
CFG="$TMP/rules.toml"
ok "a directory under a dir rule"        personal "$(pf "$TMP/home/git/personal/x")"
ok "...however deep"                     work     "$(pf "$TMP/home/git/work/y/z")"
ok "a session name that contains the text" work   "$(pf /tmp work/foo)"
ok "a session name that matches nothing"  ask     "$(pf /tmp agents)"
ok "the parent of a matching directory"   ask     "$(pf "$TMP/home/git")"
# The prefix has to end on a path component, or ~/git/personalx quietly becomes
# a personal repo.
ok "a sibling that merely starts the same" ask    "$(pf "$TMP/home/git/personalx")"

ln -s "$TMP/home/git/personal/x" "$TMP/linked"
ok "a symlink resolves to what it points at" personal "$(pf "$TMP/linked")"

cat >"$TMP/unknown.toml" <<EOF
[claude.profiles.work]
[[claude.rules]]
dir = "$TMP/home/git/personal"
profile = "nosuch"
[[claude.rules]]
dir = "$TMP/home/git/personal"
profile = "work"
EOF
CFG="$TMP/unknown.toml"
ok "a rule naming an unknown profile is skipped" work "$(pf "$TMP/home/git/personal/x")"
err=$(TA_CONFIG="$TMP/unknown.toml" bash "$TA" --profile-for "$TMP/home/git/personal/x" 2>&1 >/dev/null)
contains "...loudly" 'rule 0 names unknown profile "nosuch"' "$err"

# A rule with no profile at all — what a forgotten `profile` line leaves behind.
# Skipped either way; the point is that it says so.
cat >"$TMP/noprofile.toml" <<EOF
[claude.profiles.work]
[[claude.rules]]
dir = "$TMP/home/git/personal"
[[claude.rules]]
dir = "$TMP/home/git/personal"
profile = "work"
EOF
CFG="$TMP/noprofile.toml"
ok "a rule naming no profile is skipped" work "$(pf "$TMP/home/git/personal/x")"
err=$(TA_CONFIG="$TMP/noprofile.toml" bash "$TA" --profile-for "$TMP/home/git/personal/x" 2>&1 >/dev/null)
contains "...loudly, and in its own words" "rule 0 names no profile" "$err"

cat >"$TMP/default.toml" <<EOF
[claude]
default = "work"
[claude.profiles.personal]
config_dir = "~/.claude-personal"
[claude.profiles.work]
[[claude.rules]]
dir = "$TMP/home/git/personal"
profile = "personal"
EOF
CFG="$TMP/default.toml"
ok "default catches what no rule does" work "$(pf "$TMP/home/git")"
ok "...without overriding a rule"      personal "$(pf "$TMP/home/git/personal/x")"

printf '[claude]\nargs = "--dangerously-skip-permissions"\n' >"$TMP/noprof.toml"
out=$(TA_CONFIG="$TMP/noprof.toml" bash "$TA" --profile-for /tmp 2>/dev/null); rc=$?
ok "no profiles: nothing to say"  "" "$out"
ok "no profiles: and it says so"  1  "$rc"

out=$(TA_CONFIG=/nonexistent/config.toml bash "$TA" --profile-for /tmp 2>/dev/null); rc=$?
ok "no config file: nothing to say" "" "$out"
ok "no config file: and it says so"  1 "$rc"

out=$(TA_CONFIG=/nonexistent/config.toml bash "$TA" --config 2>/dev/null); rc=$?
ok "--config on a missing file exits 1" 1 "$rc"
err=$(TA_CONFIG=/nonexistent/config.toml bash "$TA" --config 2>&1 >/dev/null)
contains "...naming the path it looked at" "/nonexistent/config.toml" "$err"

# ---------------------------------------------------------------------------
t "3. command builder"
# ---------------------------------------------------------------------------

cat >"$TMP/build.toml" <<'EOF'
[claude]
args = "--dangerously-skip-permissions"
[claude.profiles.personal]
config_dir = "~/.claude-personal"
[claude.profiles.work]
[claude.profiles.proxy]
command = "/opt/bin/claude-wrap"
args = ["--model", "opus", "--append-system-prompt", "be brief"]
[claude.profiles.proxy.env]
ANTHROPIC_BASE_URL = "https://proxy.example.com"
GREETING = "it is fine"
EOF
ac() { TA_CONFIG="$TMP/build.toml" bash "$TA" --agent-cmd "$@" 2>/dev/null; }
ok "a profile with a config_dir exports the expanded path" \
   "env -u CLAUDE_CONFIG_DIR CLAUDE_CONFIG_DIR='$HOME/.claude-personal' claude --dangerously-skip-permissions" \
   "$(ac personal new)"
# Omitted config_dir means UNSET, which is a different login from empty — hence
# env -u with nothing after it rather than CLAUDE_CONFIG_DIR=.
ok "a profile without one only unsets it" \
   "env -u CLAUDE_CONFIG_DIR claude --dangerously-skip-permissions" \
   "$(ac work new)"
case "$(ac work new)" in
  *CLAUDE_CONFIG_DIR=*) fail=$((fail + 1)); printf '  FAIL default account must not assign CLAUDE_CONFIG_DIR\n' ;;
  *) pass=$((pass + 1)); printf '  ok   default account assigns nothing\n' ;;
esac

ok "resume appends the session id" \
   "env -u CLAUDE_CONFIG_DIR CLAUDE_CONFIG_DIR='$HOME/.claude-personal' claude --dangerously-skip-permissions --resume abc-123" \
   "$(ac personal resume abc-123)"

ok "command, arg list and env all render, quoted" \
   "env -u CLAUDE_CONFIG_DIR ANTHROPIC_BASE_URL='https://proxy.example.com' GREETING='it is fine' /opt/bin/claude-wrap '--model' 'opus' '--append-system-prompt' 'be brief'" \
   "$(ac proxy new)"

# An apostrophe in a value is the one thing that can end the command string
# early, so it gets a check of its own.
cat >"$TMP/quote.toml" <<'EOF'
[claude.profiles.odd]
config_dir = "/tmp/it's here"
[claude.profiles.odd.env]
WHO = "it's me"
EOF
ok "an apostrophe is quoted, not escaped out of the string" \
   "env -u CLAUDE_CONFIG_DIR CLAUDE_CONFIG_DIR='/tmp/it'\\''s here' WHO='it'\\''s me' claude --dangerously-skip-permissions" \
   "$(TA_CONFIG="$TMP/quote.toml" bash "$TA" --agent-cmd odd new 2>/dev/null)"

ok "TA_NEW_CMD replaces the binary but keeps the account" \
   "env -u CLAUDE_CONFIG_DIR foo --bar" \
   "$(TA_NEW_CMD='foo --bar' TA_CONFIG="$TMP/build.toml" bash "$TA" --agent-cmd work new 2>/dev/null)"
ok "TA_RESUME_CMD likewise, session id still appended" \
   "env -u CLAUDE_CONFIG_DIR CLAUDE_CONFIG_DIR='$HOME/.claude-personal' myclaude --resume zz" \
   "$(TA_RESUME_CMD='myclaude --resume' TA_CONFIG="$TMP/build.toml" bash "$TA" --agent-cmd personal resume zz 2>/dev/null)"

# NO CONFIG MEANS NO CHANGE. Byte for byte what tagents ran before any of this.
ok "no profile: exactly the old new command" \
   "claude --dangerously-skip-permissions" \
   "$(TA_CONFIG=/nonexistent/config.toml bash "$TA" --agent-cmd '' new 2>/dev/null)"
ok "no profile: exactly the old resume command" \
   "claude --dangerously-skip-permissions --resume X" \
   "$(TA_CONFIG=/nonexistent/config.toml bash "$TA" --agent-cmd '' resume X 2>/dev/null)"

# A config dir no profile claims — what a closed session recorded before the
# profile was renamed. Resume still has to land on that login.
ok "a raw config dir builds as itself" \
   "env -u CLAUDE_CONFIG_DIR CLAUDE_CONFIG_DIR='/tmp/other-login' claude --dangerously-skip-permissions --resume q" \
   "$(TA_CONFIG="$TMP/build.toml" bash "$TA" --agent-cmd 'dir:/tmp/other-login' resume q 2>/dev/null)"

# A PROFILE NAME A HUMAN TYPED IS NOT A PROFILE. Unvalidated, a typo rendered
# as a plain `env -u CLAUDE_CONFIG_DIR claude …` — the default login, silently,
# which is the whole failure this config exists to end.
out=$(ac nosuchprofile new); rc=$?
ok "an unknown profile is refused" 1 "$rc"
ok "...with nothing to run"        "" "$out"
err=$(TA_CONFIG="$TMP/build.toml" bash "$TA" --agent-cmd nosuchprofile new 2>&1 >/dev/null)
contains "...and it says which name"   'no claude profile "nosuchprofile"' "$err"

out=$(ac ask new); rc=$?
ok "ask is an instruction, not an account" 1 "$rc"
ok "...and builds nothing"                 "" "$out"

# ---------------------------------------------------------------------------
t "4. the checker: a wrong config says so"
# ---------------------------------------------------------------------------
# The reported bug: a profile whose config_dir is not on this machine started a
# logged-out Claude from a picker that looked fine, and the problems that WERE
# detected went to a stderr nothing under fzf shows. --check is the list, and
# --header is the line the dashboard draws; a good config produces nothing on
# either, so every case here is a fixture with exactly one kind of thing wrong.
ck() { TA_CONFIG="$1" bash "$TA" --check 2>/dev/null; }
hd() { TA_CONFIG="$1" bash "$TA" --header 120 'open here' 'ctrl-q quit' 2>/dev/null; }
nlines() { printf '%s' "$1" | awk 'END { print NR }'; }

# Logins that exist and have been used, for the profiles that are meant to pass.
mkdir -p "$TMP/logins/personal" "$TMP/logins/work"
: >"$TMP/logins/personal/.claude.json"
: >"$TMP/logins/work/.claude.json"

# The checker's fixtures are TOML; the reader's own refusals are the last cases of this section and tests/config-toml.sh.
cat >"$TMP/good.toml" <<EOF
[claude]
default = "ask"
[claude.profiles.personal]
config_dir = "$TMP/logins/personal"
[claude.profiles.work]
config_dir = "$TMP/logins/work"
[claude.profiles.main]
[[claude.rules]]
dir = "$TMP/home/git/personal"
profile = "personal"
[[claude.rules]]
session = "work"
profile = "ask"
[usage]
watch = "work"
monthly_limit_usd = 850
safety_margin_pct = 5.5
workdays = false
[notes]
send = "submit"
[keys]
closed = "ctrl-y"
[something_newer]
this_version_does_not_read = "it"
EOF
out=$(ck "$TMP/good.toml"); rc=$?
ok "a good config: nothing to say" "" "$out"
ok "...and exit 0"                 0  "$rc"
ok "...and a header of keys alone" "enter open here · ? keys · ctrl-q quit" "$(hd "$TMP/good.toml")"
out=$(TA_CONFIG=/nonexistent/config.toml bash "$TA" --check 2>/dev/null); rc=$?
ok "no config at all is not a problem: nothing, exit 0" "0" "$rc$out"

# THE REPORTED BUG: a profile pointing at a directory this machine does not have.
cat >"$TMP/nodir.toml" <<EOF
[claude.profiles.personal]
config_dir = "$TMP/logins/does-not-exist"
[claude.profiles.work]
EOF
out=$(ck "$TMP/nodir.toml"); rc=$?
ok       "a config_dir that does not exist: exit 1" 1 "$rc"
contains "...naming the file"    "nodir.toml: "                          "$out"
contains "...and the key"        "claude.profiles.personal.config_dir: " "$out"
contains "...and what it means"  "does not exist on this machine — an agent on it starts logged out" "$out"
ok       "...one line for one problem" 1 "$(nlines "$out")"
contains "the dashboard header carries the count, and where to look" \
         "config: 1 problem (tagents --check)" "$(hd "$TMP/nodir.toml")"
ok "--config keeps its contract: the leaves, exit 0" 0 \
   "$(TA_CONFIG="$TMP/nodir.toml" bash "$TA" --config >/dev/null 2>&1; echo $?)"
contains "...with the leaves on stdout" \
   "claude.profiles.personal.config_dir${TAB}$TMP/logins/does-not-exist" \
   "$(TA_CONFIG="$TMP/nodir.toml" bash "$TA" --config 2>/dev/null)"
# Logging in once on a fresh directory is how a new login is set up, so the
# launch is warned about, not refused.
contains "--agent-cmd still builds the launch" "CLAUDE_CONFIG_DIR='$TMP/logins/does-not-exist'" \
   "$(TA_CONFIG="$TMP/nodir.toml" bash "$TA" --agent-cmd personal new 2>/dev/null)"

# Every other shape a config_dir can be wrong in. ~/.claude is what the example
# says not to write; HOME is moved so the test owns the directory it names.
: >"$TMP/logins/afile"
mkdir -p "$TMP/logins/empty" "$TMP/home/.claude"
cat >"$TMP/kinds.toml" <<EOF
[claude.profiles.filed]
config_dir = "$TMP/logins/afile"
[claude.profiles.fresh]
config_dir = "$TMP/logins/empty"
[claude.profiles.blank]
config_dir = ""
[claude.profiles.home]
config_dir = "~/.claude"
[claude.profiles.ask]
config_dir = "$TMP/logins/personal"
EOF
out=$(HOME="$TMP/home" TA_CONFIG="$TMP/kinds.toml" bash "$TA" --check 2>/dev/null)
contains "a file where a directory should be" \
   "claude.profiles.filed.config_dir: $TMP/logins/afile is not a directory" "$out"
contains "a directory nothing has written into gets the softer note" \
   "claude.profiles.fresh.config_dir: $TMP/logins/empty has never been used by Claude" "$out"
contains "...saying what will happen instead" "will ask you to log in" "$out"
contains "an empty config_dir is the default login by accident" \
   "claude.profiles.blank.config_dir: is empty" "$out"
contains "~/.claude written out is not the default account" \
   "claude.profiles.home.config_dir: ~/.claude set explicitly is a different login" "$out"
contains "a profile called ask can never be launched" \
   "claude.profiles.ask: ask is the word that opens the dialog" "$out"
ok "five problems, five lines" 5 "$(nlines "$out")"
contains "...and the header counts the same five" "config: 5 problems (tagents --check)" \
   "$(HOME="$TMP/home" TA_CONFIG="$TMP/kinds.toml" bash "$TA" --header 120 'open here' 'ctrl-q quit' 2>/dev/null)"

# A settings.json alone is not a sign of use: `tagents setup` writes one into a config directory nobody has logged into yet, and the note has to stay for it.
mkdir -p "$TMP/logins/setup-only"; : >"$TMP/logins/setup-only/settings.json"
cat >"$TMP/setup-only.toml" <<EOF
[claude.profiles.setuponly]
config_dir = "$TMP/logins/setup-only"
EOF
contains "a directory that holds only a settings.json has never been used either" \
   "claude.profiles.setuponly.config_dir: $TMP/logins/setup-only has never been used by Claude" \
   "$(HOME="$TMP/home" TA_CONFIG="$TMP/setup-only.toml" bash "$TA" --check 2>/dev/null)"

# The names that have to be profiles: in a rule, as the default, as the watch.
cat >"$TMP/names.toml" <<EOF
[claude]
default = "gone"
[claude.profiles.work]
config_dir = "$TMP/logins/work"
[[claude.rules]]
dir = "$TMP/home/git/personal"
profile = "nosuch"
[[claude.rules]]
dir = "$TMP/home/git/personal"
[[claude.rules]]
dir = "$TMP/home/git/work"
profile = ""
[[claude.rules]]
session = "w"
profile = "ask"
[[claude.rules]]
dir = "$TMP/home/git/work"
profile = "work"
[usage]
watch = "nobody"
EOF
out=$(ck "$TMP/names.toml")
contains "a rule naming an unknown profile" \
   "claude.rules.0.profile: \"nosuch\" is not in claude.profiles — the rule is skipped" "$out"
contains "a rule with no profile line"   "claude.rules.1: names no profile — the rule is skipped" "$out"
contains "a rule with an empty one"      "claude.rules.2: names no profile" "$out"
contains "a default that is not a profile" "claude.default: \"gone\" is not in claude.profiles — falls back to ask" "$out"
contains "a watch that is not a profile"   "usage.watch: \"nobody\" is not in claude.profiles" "$out"
ok "...and ask, and a real profile, pass: five in all" 5 "$(nlines "$out")"

# Rules with no profiles at all are dead text — one note, not one per rule.
cat >"$TMP/deadrules.toml" <<EOF
[claude]
default = "work"
[[claude.rules]]
dir = "/tmp"
profile = "work"
[[claude.rules]]
dir = "/var"
profile = "work"
EOF
out=$(ck "$TMP/deadrules.toml")
contains "rules without profiles: one note" \
   "claude.profiles: none — claude.rules, claude.default and usage.watch do nothing without one" "$out"
ok "...and only one" 1 "$(nlines "$out")"

# Values that cannot be what they claim — and a key fzf would refuse, folded
# into the same list so the count is the whole truth.
cat >"$TMP/values.toml" <<EOF
[claude.profiles.work]
config_dir = "$TMP/logins/work"
[usage]
watch = "work"
monthly_limit_usd = "850 dollars"
safety_margin_pct = 150
workdays = "False"
[notes]
send = "mail"
[keys]
new = "ctrl-1"
EOF
out=$(ck "$TMP/values.toml")
contains "a limit that is not a number" "usage.monthly_limit_usd: \"850 dollars\" is not a number" "$out"
contains "a margin over 100"            "usage.safety_margin_pct: 150 is not a percentage" "$out"
contains "workdays: False reads as true, and says so" \
   "usage.workdays: \"False\" is not true or false — read as true" "$out"
contains "notes.send outside its three words" \
   "notes.send: \"mail\" is not one of reference, paste, submit" "$out"
contains "a key fzf does not know, in the same list" \
   "values.toml: keys.new: 'ctrl-1' is not a key fzf knows" "$out"
ok "five problems, five lines" 5 "$(nlines "$out")"

# dashboard.layout: a key an earlier version read, which this one takes like any key it does not read.
printf '[dashboard]\nlayout = "follow"\n' >"$TMP/oldlayout.toml"
ok       "A dashboard.layout an earlier version read: --check has nothing to say" "" "$(ck "$TMP/oldlayout.toml")"
contains "...and --config prints the leaf" "dashboard.layout${TAB}follow" "$(TA_CONFIG="$TMP/oldlayout.toml" bash "$TA" --config 2>/dev/null)"
printf '[dashboard]\nlayout = "ide"\n' >"$TMP/badlayout.toml"
ok       "...and so is a value no version read, with no line about it" "" "$(ck "$TMP/badlayout.toml")"
printf '[usage]\nworkdays = true\n' >"$TMP/nodash.toml"
ok       "No dashboard section: --check has nothing to say" "" "$(ck "$TMP/nodash.toml")"
ok       "...and no dashboard.layout leaf exists" "" \
   "$(TA_CONFIG="$TMP/nodash.toml" bash "$TA" --config 2>/dev/null | grep '^dashboard\.')"

# The docs page on accounts, "The file" section: every top-level key it lists is a section the file carries.
readme_keys=$(awk '/^### The file/ {on=1; next} /^### / {on=0} on && /^\[\[?[a-z_]+[].]/ {sub(/^\[\[?/, ""); sub(/[].].*/, ""); print}' "$HERE/../docs/guide/accounts.md" | awk '!seen[$0]++')
for k in $readme_keys; do
  case $k in
    claude|usage|notes|resurrect|keys|plugins) ok "docs list $k, a section the file carries" 1 1 ;;
    *) ok "docs list $k, a section the file carries" known "$k" ;;
  esac
done
ok "...and dashboard is not among them, the section is gone" "" "$(printf '%s\n' "$readme_keys" | grep -x dashboard)"

# The parser's own refusals, which used to be stderr and nothing else.
printf '[claude.profiles.work]\n[claude.profiles.a\n[usage]\nd = """\n' >"$TMP/refused.toml"
out=$(ck "$TMP/refused.toml")
contains "a header that never closes is in the list" "refused.toml:2: the table header is not closed with ]" "$out"
contains "...and so is a multi-line string"           "refused.toml:4: multi-line strings are not supported" "$out"
err=$(TA_CONFIG="$TMP/refused.toml" bash "$TA" --config 2>&1 >/dev/null)
contains "...while stderr still says it, once, for a script" \
   "tagents: config: $TMP/refused.toml:2: the table header is not closed with ]" "$err"
ok "...once" 1 "$(printf '%s' "$err" | grep -c 'refused.toml:2')"
ok "...and the header counts both" "config: 2 problems (tagents --check)" \
   "$(hd "$TMP/refused.toml" | sed 's/.* · //')"

# A note names the file its key is in: the overlay for what the overlay
# replaced, the base for what was inherited.
mkdir -p "$TMP/ov2"
cat >"$TMP/ov2/config.toml" <<EOF
[claude.profiles.personal]
config_dir = "$TMP/logins/personal"
[notes]
send = "mail"
EOF
cat >"$TMP/ov2/config.mbp.toml" <<EOF
[claude.profiles.client]
config_dir = "$TMP/logins/nowhere"
EOF
out=$(TA_HOST=mbp TA_CONFIG="$TMP/ov2/config.toml" bash "$TA" --check 2>/dev/null)
contains "a problem in the overlay names the overlay" \
   "config.mbp.toml: claude.profiles.client.config_dir: " "$out"
contains "...and one inherited from the base names the base" "ov2/config.toml: notes.send: " "$out"
ok "two files, two problems" 2 "$(nlines "$out")"
out=$(TA_HOST=other TA_CONFIG="$TMP/ov2/config.toml" bash "$TA" --check 2>/dev/null)
ok "another host sees the base alone: its one problem" 1 "$(nlines "$out")"
contains "...which is the base's" "ov2/config.toml: notes.send: " "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
