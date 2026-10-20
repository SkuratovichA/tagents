#!/usr/bin/env bash
#
# tests/install.sh — install.sh and `tagents update`: the managed copy, the
# wrappers that replace symlinks, and what an update does when it goes wrong.
#
# "origin" is a throwaway repo in a mktemp dir holding stubs where the real
# project has its entry points, so no network, no pnpm and no node are needed:
# the build step is TAGENTS_BUILD_CMD, a shell command each case sets to what it
# wants to prove. Nothing outside the mktemp dir is written.
#
# bash 3.2, runnable from any cwd, non-zero exit when any check fails.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
INSTALL="$ROOT/install.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tagents-install.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

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

# A fresh sandbox per case: origin, and the three places install.sh writes to.
ORIGIN=$TMP/origin
mkorigin() {
  rm -rf "$ORIGIN"; mkdir -p "$ORIGIN"
  (
    cd "$ORIGIN" || exit 1
    git init -q -b main . && git config user.email t@example.com && git config user.name t
    mkdir -p hooks packages/core/dist/cli packages/knowledge/dist/cli
    for f in tagents tusage tnotes; do printf '#!/bin/sh\necho "%s v1 $*"\n' "$f" > "$f"; chmod +x "$f"; done
    # The hook echoes its stdin: a wrapper that dropped it would break every hook.
    printf '#!/bin/sh\necho "state v1 $* <$(cat)>"\n' > hooks/tmux-agent-state.sh
    printf '#!/bin/sh\necho "notes v1"\n' > hooks/notes-context.sh
    printf '#!/usr/bin/env node\n' > packages/core/dist/cli/main.js
    printf '#!/usr/bin/env node\n' > packages/knowledge/dist/cli/main.js
    git add -A && git commit -q -m v1
  )
}

HOME_DIR=$TMP/home
fresh_env() {
  rm -rf "$HOME_DIR"; mkdir -p "$HOME_DIR"
  export TAGENTS_HOME=$HOME_DIR/share/tagents
  export TAGENTS_BIN=$HOME_DIR/bin
  export TAGENTS_REPO=$ORIGIN
  export TAGENTS_BUILD_CMD=true
  export HOOKS_A=$HOME_DIR/claude-a/hooks
  export HOOKS_B=$HOME_DIR/claude-b/hooks
  unset TAGENTS_REF
}

run() { sh "$INSTALL" --hooks-dir "$HOOKS_A" --hooks-dir "$HOOKS_B" "$@" 2>&1; }

advance() {  # <message> — a new commit on origin/main
  ( cd "$ORIGIN" && "$@" && git add -A && git commit -q -m "$*" )
}

# ---------------------------------------------------------------------------
t "1. a fresh install"
# ---------------------------------------------------------------------------
mkorigin; fresh_env
out=$(run); rc=$?
ok "exit status" 0 "$rc"
ok "the copy stands on origin/main" "$(git -C "$ORIGIN" rev-parse HEAD)" "$(git -C "$TAGENTS_HOME" rev-parse HEAD)"
ok "detached, not on a branch" "HEAD" "$(git -C "$TAGENTS_HOME" rev-parse --abbrev-ref HEAD)"
for f in "$TAGENTS_BIN/tagents" "$TAGENTS_BIN/tusage" "$TAGENTS_BIN/tnotes" "$TAGENTS_BIN/tagents-core" \
         "$TAGENTS_BIN/tagents-knowledge" "$HOOKS_A/tmux-agent-state.sh" "$HOOKS_B/notes-context.sh"; do
  if [ -f "$f" ] && [ ! -L "$f" ] && [ -x "$f" ]; then
    pass=$((pass + 1)); printf '  ok   %s is an executable regular file\n' "${f#$HOME_DIR/}"
  else
    fail=$((fail + 1)); printf '  FAIL %s is not an executable regular file\n' "${f#$HOME_DIR/}"
  fi
done
ok "a command wrapper reaches the copy and passes its arguments" "tagents v1 a b" "$("$TAGENTS_BIN/tagents" a b)"
ok "a hook wrapper passes stdin and arguments through" "state v1 x <payload>" "$(printf payload | "$HOOKS_A/tmux-agent-state.sh" x)"
contains "the node CLIs go through node" 'exec node "'"$TAGENTS_HOME"'/packages/core/dist/cli/main.js"' "$(cat "$TAGENTS_BIN/tagents-core")"
contains "the wrapper says whose it is" "managed by tagents install.sh" "$(cat "$TAGENTS_BIN/tusage")"
ok "no lock left behind" "no" "$([ -e "$TAGENTS_HOME.lock" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
t "2. a symlink in the way is replaced, never written through"
# ---------------------------------------------------------------------------
mkorigin; fresh_env
mkdir -p "$TAGENTS_BIN" "$HOOKS_A" "$TMP/precious"
printf 'the old checkout\n' > "$TMP/precious/tusage"
printf 'the old hook\n' > "$TMP/precious/tmux-agent-state.sh"
ln -s "$TMP/precious/tusage" "$TAGENTS_BIN/tusage"
ln -s "$TMP/precious/tmux-agent-state.sh" "$HOOKS_A/tmux-agent-state.sh"
out=$(run); rc=$?
ok "exit status" 0 "$rc"
ok "the command is no longer a symlink" "no" "$([ -L "$TAGENTS_BIN/tusage" ] && echo yes || echo no)"
ok "the hook is no longer a symlink" "no" "$([ -L "$HOOKS_A/tmux-agent-state.sh" ] && echo yes || echo no)"
ok "what the command link pointed at is untouched" "the old checkout" "$(cat "$TMP/precious/tusage")"
ok "what the hook link pointed at is untouched" "the old hook" "$(cat "$TMP/precious/tmux-agent-state.sh")"
ok "the replacement works" "tusage v1 q" "$("$TAGENTS_BIN/tusage" q)"

# ---------------------------------------------------------------------------
t "3. somebody else's file with our name is left alone"
# ---------------------------------------------------------------------------
mkorigin; fresh_env
mkdir -p "$TAGENTS_BIN" "$HOOKS_A"
printf '#!/bin/sh\necho mine\n' > "$TAGENTS_BIN/tnotes"; chmod +x "$TAGENTS_BIN/tnotes"
printf '#!/bin/sh\necho unrelated\n' > "$HOOKS_A/herdr-agent-state.sh"
out=$(run); rc=$?
ok "exit status says something was skipped" 1 "$rc"
contains "the warning names the file" "$TAGENTS_BIN/tnotes exists and is not a tagents wrapper" "$out"
ok "the foreign file is as it was" "mine" "$("$TAGENTS_BIN/tnotes")"
ok "the rest was installed" "tagents v1 " "$("$TAGENTS_BIN/tagents")"
ok "a foreign hook that is not ours is not pruned" "yes" "$([ -f "$HOOKS_A/herdr-agent-state.sh" ] && grep -q unrelated "$HOOKS_A/herdr-agent-state.sh" && echo yes || echo no)"

# ---------------------------------------------------------------------------
t "4. an update moves the copy, adds hooks, prunes the ones the project dropped"
# ---------------------------------------------------------------------------
mkorigin; fresh_env
run >/dev/null
v1=$(git -C "$TAGENTS_HOME" rev-parse HEAD)
out=$(run --check)
contains "--check at the same commit" "up to date" "$out"
advance sh -c 'printf "#!/bin/sh\necho \"tagents v2 \$*\"\n" > tagents; printf "#!/bin/sh\necho \"extra\"\n" > hooks/ticket-ledger.sh; git rm -q hooks/notes-context.sh'
out=$(run --check)
contains "--check after origin moved" "behind: ${v1:0:7} -> " "$out"
ok "--check changed nothing" "$v1" "$(git -C "$TAGENTS_HOME" rev-parse HEAD)"
out=$(run); rc=$?
ok "exit status" 0 "$rc"
ok "the copy follows origin/main" "$(git -C "$ORIGIN" rev-parse HEAD)" "$(git -C "$TAGENTS_HOME" rev-parse HEAD)"
ok "the new version runs through the same wrapper" "tagents v2 z" "$("$TAGENTS_BIN/tagents" z)"
ok "a new hook got its wrapper in both config dirs" "extra extra" "$("$HOOKS_A/ticket-ledger.sh") $("$HOOKS_B/ticket-ledger.sh")"
ok "the dropped hook's wrapper is gone from the first dir" "no" "$([ -e "$HOOKS_A/notes-context.sh" ] && echo yes || echo no)"
ok "and from the second" "no" "$([ -e "$HOOKS_B/notes-context.sh" ] && echo yes || echo no)"
out=$(run --quiet)
ok "a quiet run with nothing to do prints nothing" "" "$out"

# ---------------------------------------------------------------------------
t "5. a copy with local changes is not moved"
# ---------------------------------------------------------------------------
mkorigin; fresh_env
run >/dev/null
v1=$(git -C "$TAGENTS_HOME" rev-parse HEAD)
advance sh -c 'echo v2 > VERSION'
echo scribble >> "$TAGENTS_HOME/tusage"
out=$(run); rc=$?
ok "exit status" 1 "$rc"
contains "it says why" "has local changes" "$out"
ok "the copy stayed" "$v1" "$(git -C "$TAGENTS_HOME" rev-parse HEAD)"

# ---------------------------------------------------------------------------
t "6. a build that fails puts the copy back"
# ---------------------------------------------------------------------------
mkorigin; fresh_env
run >/dev/null
v1=$(git -C "$TAGENTS_HOME" rev-parse HEAD)
advance sh -c 'touch BROKEN'
export TAGENTS_BUILD_CMD='[ ! -e BROKEN ] || { echo "boom: BROKEN is here" >&2; exit 3; }'
out=$(run); rc=$?
ok "exit status" 1 "$rc"
contains "the build's own words are shown" "boom: BROKEN is here" "$out"
contains "it says where the copy is" "back on ${v1:0:7}" "$out"
ok "the copy is on the commit it was on" "$v1" "$(git -C "$TAGENTS_HOME" rev-parse HEAD)"
ok "the wrappers still work" "tagents v1 " "$("$TAGENTS_BIN/tagents")"
# main is fixed upstream: the next run recovers on its own.
advance git rm -q BROKEN
out=$(run); rc=$?
ok "the run after the fix succeeds" 0 "$rc"
ok "and lands on the fix" "$(git -C "$ORIGIN" rev-parse HEAD)" "$(git -C "$TAGENTS_HOME" rev-parse HEAD)"

# ---------------------------------------------------------------------------
t "7. refusals"
# ---------------------------------------------------------------------------
mkorigin; fresh_env
mkdir -p "$TAGENTS_HOME"; echo mine > "$TAGENTS_HOME/notes.txt"
out=$(run); rc=$?
ok "a directory that is not a copy is not cloned into" 1 "$rc"
ok "and is not touched" "mine" "$(cat "$TAGENTS_HOME/notes.txt")"
out=$(sh "$INSTALL" --nonsense 2>&1); rc=$?
ok "an unknown option is an error" 1 "$rc"
out=$(sh "$INSTALL" --help 2>&1)
contains "--help prints the manual" "install.sh — put tagents on this machine" "$out"
fresh_env
out=$(run --check)
contains "--check on a machine with no copy" "not installed" "$out"
ok "and installs nothing" "no" "$([ -e "$TAGENTS_HOME" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
t "8. the daily LaunchAgent"
# ---------------------------------------------------------------------------
if [ "$(uname -s)" = Darwin ]; then
  mkorigin; fresh_env
  export TAGENTS_LAUNCHD_DIR=$HOME_DIR/LaunchAgents TAGENTS_NO_LAUNCHCTL=1
  HOME=$HOME_DIR out=$(run --launchd); rc=$?
  plist=$TAGENTS_LAUNCHD_DIR/io.github.skuratovicha.tagents-update.plist
  ok "exit status" 0 "$rc"
  ok "the plist exists" "yes" "$([ -f "$plist" ] && echo yes || echo no)"
  ok "and lints" "OK" "$(plutil -lint "$plist" | sed 's/^.*: //')"
  contains "it runs the copy's installer" "$TAGENTS_HOME/install.sh" "$(cat "$plist")"
  contains "it remembers the hooks dirs" "$HOOKS_B" "$(cat "$plist")"
  unset TAGENTS_LAUNCHD_DIR TAGENTS_NO_LAUNCHCTL
else
  printf '  skip not macOS\n'
fi

# ---------------------------------------------------------------------------
t "9. \`tagents update\` is the dashboard's own verb"
# ---------------------------------------------------------------------------
out=$(bash "$ROOT/tagents" update --help 2>&1)
contains "it reaches install.sh and not tagents-core" "install.sh — put tagents on this machine" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
