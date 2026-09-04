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
t "1. parser"
# ---------------------------------------------------------------------------

# The shipped example is the parser reference: if it stops flattening to this,
# every rule in every real config is suspect.
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
EOF
)
got=$(TA_CONFIG="$HERE/../config.example.yaml" bash "$TA" --config 2>&1)
ok "config.example.yaml flattens as documented" "$want" "$got"

# Everything the subset promises, in one file, indented four spaces: end-of-line
# comments, a # that is inside quotes and therefore not one, blank lines, a
# scalar list, an env map, an escaped quote, and a key with nothing under it.
cat >"$TMP/odd.yaml" <<'EOF'
# leading comment
claude:
    args:
        - --dangerously-skip-permissions
        - --append-system-prompt
        - "a \"quoted\" word"

    profiles:
        proxy:                       # trailing comment on a mapping
            command: /opt/bin/wrap
            config_dir: ~/.claude-proxy   # and on a value
            args: --model opus --foo "a b"
            env:
                ANTHROPIC_BASE_URL: https://proxy.example.com#frag
                QUOTED: "it is # not a comment"
        bare:
    note: 'single # quoted'
EOF
want=$(cat <<'EOF'
claude.args.0	--dangerously-skip-permissions
claude.args.1	--append-system-prompt
claude.args.2	a "quoted" word
claude.profiles.proxy.command	/opt/bin/wrap
claude.profiles.proxy.config_dir	~/.claude-proxy
claude.profiles.proxy.args	--model opus --foo "a b"
claude.profiles.proxy.env.ANTHROPIC_BASE_URL	https://proxy.example.com#frag
claude.profiles.proxy.env.QUOTED	it is # not a comment
claude.profiles.bare	
claude.note	single # quoted
EOF
)
got=$(TA_CONFIG="$TMP/odd.yaml" bash "$TA" --config 2>&1)
ok "quotes, comments, lists, env map, 4-space indent, empty key" "$want" "$got"

# A line the subset refuses must cost that line and nothing else.
printf 'claude:\n  args: fine\n\tbad: tabbed\n  profiles:\n    p:\n      config_dir: ~/x\n' \
  >"$TMP/tabs.yaml"
got=$(TA_CONFIG="$TMP/tabs.yaml" bash "$TA" --config 2>/dev/null)
err=$(TA_CONFIG="$TMP/tabs.yaml" bash "$TA" --config 2>&1 >/dev/null)
ok "a tab-indented line does not stop the parse" \
   "claude.args${TAB}fine
claude.profiles.p.config_dir${TAB}~/x" "$got"
contains "a tab-indented line is named on stderr" "tabs.yaml:3" "$err"
contains "...and says what was wrong with it" "tab indentation" "$err"

# A sequence item written as a bare dash, its keys on the lines below. Parsed as
# the scalar "-" once, which threw away every key under it and took the whole
# rule with it — silently, since the warnings go to stderr and the dashboard
# runs this behind execute-silent.
cat >"$TMP/baredash.yaml" <<'EOF'
claude:
  profiles:
    work:
  rules:
    -
      dir: /tmp
      profile: work
EOF
got=$(TA_CONFIG="$TMP/baredash.yaml" bash "$TA" --config 2>&1)
ok "a bare dash opens a mapping item" \
   "claude.profiles.work${TAB}
claude.rules.0.dir${TAB}/tmp
claude.rules.0.profile${TAB}work" "$got"

# CRLF is not refused, it is MIS-parsed: the \r sits between the colon and the
# end of the line, so `key:` stops being a key while `key: value` keeps the \r.
printf 'claude:\r\n  profiles:\r\n    personal:\r\n      config_dir: ~/.claude-personal\r\n' \
  >"$TMP/crlf.yaml"
got=$(TA_CONFIG="$TMP/crlf.yaml" bash "$TA" --config 2>&1)
ok "a CRLF file parses as its LF twin" \
   "claude.profiles.personal.config_dir${TAB}~/.claude-personal" "$got"

# An apostrophe in the middle of a plain value is not an opening quote, so the
# trailing comment after it is still a comment.
printf 'claude:\n  note: it is a dir   # and this goes\n  odd: do not   # this too\n' \
  | sed "s/do not/don't/" >"$TMP/apos.yaml"
got=$(TA_CONFIG="$TMP/apos.yaml" bash "$TA" --config 2>&1)
contains "an apostrophe mid-value does not swallow the comment" \
   "claude.odd${TAB}don" "$got"
case "$got" in
  *"# this too"*) fail=$((fail + 1)); printf '  FAIL the comment ended up in the value\n' ;;
  *) pass=$((pass + 1)); printf '  ok   ...the comment is gone\n' ;;
esac

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

# ---------------------------------------------------------------------------
t "2. rules"
# ---------------------------------------------------------------------------

EX="$HERE/../config.example.yaml"
pf() { TA_CONFIG="${CFG:-$EX}" bash "$TA" --profile-for "$@" 2>/dev/null; }

mkdir -p "$TMP/home/git/personal/x" "$TMP/home/git/work/y/z" "$TMP/home/git/personalx"
# The example config talks about ~/git/..., so the fixture has to be under the
# real $HOME to be the thing it names.
cat >"$TMP/rules.yaml" <<EOF
claude:
  profiles:
    personal:
      config_dir: ~/.claude-personal
    work:
  rules:
    - dir: $TMP/home/git/personal
      profile: personal
    - dir: $TMP/home/git/work
      profile: work
    - session: personal
      profile: personal
    - session: work
      profile: work
EOF
CFG="$TMP/rules.yaml"
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

cat >"$TMP/unknown.yaml" <<EOF
claude:
  profiles:
    work:
  rules:
    - dir: $TMP/home/git/personal
      profile: nosuch
    - dir: $TMP/home/git/personal
      profile: work
EOF
CFG="$TMP/unknown.yaml"
ok "a rule naming an unknown profile is skipped" work "$(pf "$TMP/home/git/personal/x")"
err=$(TA_CONFIG="$TMP/unknown.yaml" bash "$TA" --profile-for "$TMP/home/git/personal/x" 2>&1 >/dev/null)
contains "...loudly" 'rule 0 names unknown profile "nosuch"' "$err"

# A rule with no profile at all — what a `profile:` line indented one column
# short of its `- dir:` item leaves behind. Skipped either way; the point is
# that it says so.
cat >"$TMP/noprofile.yaml" <<EOF
claude:
  profiles:
    work:
  rules:
    - dir: $TMP/home/git/personal
    - dir: $TMP/home/git/personal
      profile: work
EOF
CFG="$TMP/noprofile.yaml"
ok "a rule naming no profile is skipped" work "$(pf "$TMP/home/git/personal/x")"
err=$(TA_CONFIG="$TMP/noprofile.yaml" bash "$TA" --profile-for "$TMP/home/git/personal/x" 2>&1 >/dev/null)
contains "...loudly, and in its own words" "rule 0 names no profile" "$err"

cat >"$TMP/default.yaml" <<EOF
claude:
  profiles:
    personal:
      config_dir: ~/.claude-personal
    work:
  rules:
    - dir: $TMP/home/git/personal
      profile: personal
  default: work
EOF
CFG="$TMP/default.yaml"
ok "default catches what no rule does" work "$(pf "$TMP/home/git")"
ok "...without overriding a rule"      personal "$(pf "$TMP/home/git/personal/x")"

printf 'claude:\n  args: --dangerously-skip-permissions\n' >"$TMP/noprof.yaml"
out=$(TA_CONFIG="$TMP/noprof.yaml" bash "$TA" --profile-for /tmp 2>/dev/null); rc=$?
ok "no profiles: nothing to say"  "" "$out"
ok "no profiles: and it says so"  1  "$rc"

out=$(TA_CONFIG=/nonexistent/config.yaml bash "$TA" --profile-for /tmp 2>/dev/null); rc=$?
ok "no config file: nothing to say" "" "$out"
ok "no config file: and it says so"  1 "$rc"

out=$(TA_CONFIG=/nonexistent/config.yaml bash "$TA" --config 2>/dev/null); rc=$?
ok "--config on a missing file exits 1" 1 "$rc"
err=$(TA_CONFIG=/nonexistent/config.yaml bash "$TA" --config 2>&1 >/dev/null)
contains "...naming the path it looked at" "/nonexistent/config.yaml" "$err"

# ---------------------------------------------------------------------------
t "3. command builder"
# ---------------------------------------------------------------------------

cat >"$TMP/build.yaml" <<'EOF'
claude:
  args: --dangerously-skip-permissions
  profiles:
    personal:
      config_dir: ~/.claude-personal
    work:
    proxy:
      command: /opt/bin/claude-wrap
      args:
        - --model
        - opus
        - --append-system-prompt
        - be brief
      env:
        ANTHROPIC_BASE_URL: https://proxy.example.com
        GREETING: it is fine
EOF
ac() { TA_CONFIG="$TMP/build.yaml" bash "$TA" --agent-cmd "$@" 2>/dev/null; }

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
cat >"$TMP/quote.yaml" <<'EOF'
claude:
  profiles:
    odd:
      config_dir: /tmp/it's here
      env:
        WHO: "it's me"
EOF
ok "an apostrophe is quoted, not escaped out of the string" \
   "env -u CLAUDE_CONFIG_DIR CLAUDE_CONFIG_DIR='/tmp/it'\\''s here' WHO='it'\\''s me' claude --dangerously-skip-permissions" \
   "$(TA_CONFIG="$TMP/quote.yaml" bash "$TA" --agent-cmd odd new 2>/dev/null)"

ok "TA_NEW_CMD replaces the binary but keeps the account" \
   "env -u CLAUDE_CONFIG_DIR foo --bar" \
   "$(TA_NEW_CMD='foo --bar' TA_CONFIG="$TMP/build.yaml" bash "$TA" --agent-cmd work new 2>/dev/null)"
ok "TA_RESUME_CMD likewise, session id still appended" \
   "env -u CLAUDE_CONFIG_DIR CLAUDE_CONFIG_DIR='$HOME/.claude-personal' myclaude --resume zz" \
   "$(TA_RESUME_CMD='myclaude --resume' TA_CONFIG="$TMP/build.yaml" bash "$TA" --agent-cmd personal resume zz 2>/dev/null)"

# NO CONFIG MEANS NO CHANGE. Byte for byte what tagents ran before any of this.
ok "no profile: exactly the old new command" \
   "claude --dangerously-skip-permissions" \
   "$(TA_CONFIG=/nonexistent bash "$TA" --agent-cmd '' new 2>/dev/null)"
ok "no profile: exactly the old resume command" \
   "claude --dangerously-skip-permissions --resume X" \
   "$(TA_CONFIG=/nonexistent bash "$TA" --agent-cmd '' resume X 2>/dev/null)"

# A config dir no profile claims — what a closed session recorded before the
# profile was renamed. Resume still has to land on that login.
ok "a raw config dir builds as itself" \
   "env -u CLAUDE_CONFIG_DIR CLAUDE_CONFIG_DIR='/tmp/other-login' claude --dangerously-skip-permissions --resume q" \
   "$(TA_CONFIG="$TMP/build.yaml" bash "$TA" --agent-cmd 'dir:/tmp/other-login' resume q 2>/dev/null)"

# A PROFILE NAME A HUMAN TYPED IS NOT A PROFILE. Unvalidated, a typo rendered
# as a plain `env -u CLAUDE_CONFIG_DIR claude …` — the default login, silently,
# which is the whole failure this config exists to end.
out=$(ac nosuchprofile new); rc=$?
ok "an unknown profile is refused" 1 "$rc"
ok "...with nothing to run"        "" "$out"
err=$(TA_CONFIG="$TMP/build.yaml" bash "$TA" --agent-cmd nosuchprofile new 2>&1 >/dev/null)
contains "...and it says which name"   'no claude profile "nosuchprofile"' "$err"

out=$(ac ask new); rc=$?
ok "ask is an instruction, not an account" 1 "$rc"
ok "...and builds nothing"                 "" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
