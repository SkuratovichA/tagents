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

lacks() {  # <name> <needle> <haystack>
  case "$3" in
    *"$2"*) fail=$((fail + 1))
            printf '  FAIL %s\n       expected NOT to contain: %s\n       actual: %s\n' "$1" "$2" "$3" ;;
    *) pass=$((pass + 1)); printf '  ok   %s\n' "$1" ;;
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
    # The tree's own installer, so an update that moves the copy hands over to the install.sh of the commit it lands on, as on a real machine.
    cp "$INSTALL" install.sh
    git add -A && git commit -q -m v1
  )
}

HOME_DIR=$TMP/home
fresh_env() {
  rm -rf "$HOME_DIR"; mkdir -p "$HOME_DIR"
  # A run handed over across an exec gets its arguments from the run before it, and one that lost them would put hooks into $HOME/.claude/hooks.
  export HOME=$HOME_DIR
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
contains "the node CLI wrapper execs the copy's cli file with all arguments" '"'"$TAGENTS_HOME"'/packages/core/dist/cli/main.js" "$@"' "$(cat "$TAGENTS_BIN/tagents-core")"
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
ok "no lock left behind" "no" "$([ -e "$TAGENTS_HOME.lock" ] && echo yes || echo no)"
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

# ---------------------------------------------------------------------------
t "10. the node commands run the node that installed them"
# ---------------------------------------------------------------------------
mkdir -p "$TMP/node-a" "$TMP/node-b"
printf '#!/bin/sh\necho "node-a $*"\n' > "$TMP/node-a/node"; chmod 755 "$TMP/node-a/node"
printf '#!/bin/sh\necho "node-b $*"\n' > "$TMP/node-b/node"; chmod 755 "$TMP/node-b/node"
mkorigin; fresh_env
out=$(PATH="$TMP/node-a:$PATH" run); rc=$?
ok "an install with a node on PATH exits 0" 0 "$rc"
contains "tagents-core pins the node found at install" 'n="'"$TMP"'/node-a/node"' "$(cat "$TAGENTS_BIN/tagents-core")"
contains "tagents-knowledge pins it too" 'n="'"$TMP"'/node-a/node"' "$(cat "$TAGENTS_BIN/tagents-knowledge")"
ok "tagents-core runs the pinned node with no node on the caller's PATH" "node-a $TAGENTS_HOME/packages/core/dist/cli/main.js a b" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a b)"
rm -f "$TMP/node-a/node"
ok "tagents-knowledge falls back to the node on the caller's PATH once the pinned file is gone" "node-b $TAGENTS_HOME/packages/knowledge/dist/cli/main.js x" "$(env PATH="$TMP/node-b:/usr/bin:/bin" "$TAGENTS_BIN/tagents-knowledge" x)"
out=$(PATH="$TMP/node-b:$PATH" run); rc=$?
ok "an install from a shell finding the second node exits 0" 0 "$rc"
contains "tagents-core now pins the second node" 'n="'"$TMP"'/node-b/node"' "$(cat "$TAGENTS_BIN/tagents-core")"
if [ -n "$(env PATH=/usr/bin:/bin sh -c 'command -v node' 2>/dev/null)" ]; then
  printf '  skip /usr/bin or /bin holds a node\n'
else
  out=$(PATH=/usr/bin:/bin run); rc=$?
  ok "an install from a shell finding no node exits 0" 0 "$rc"
  contains "the wrapper then looks node up on the caller's PATH" 'exec node "'"$TAGENTS_HOME"'/packages/core/dist/cli/main.js" "$@"' "$(cat "$TAGENTS_BIN/tagents-core")"
fi

# ---------------------------------------------------------------------------
t "11. one update installs with the installer of the commit it moves to"
# ---------------------------------------------------------------------------
mkorigin; fresh_env
run >/dev/null
# The next commit's install.sh writes its wrappers with another comment line.
advance sh -c 'sed "s/rewritten on every update: do not edit/rewritten on every update, v2: do not edit/" install.sh > install.sh.new && mv install.sh.new install.sh'
# Run by the copy's own installer, as `tagents update` and the LaunchAgent run it.
out=$(sh "$TAGENTS_HOME/install.sh" --hooks-dir "$HOOKS_A" --hooks-dir "$HOOKS_B" 2>&1); rc=$?
ok "exit status" 0 "$rc"
ok "the copy follows origin/main" "$(git -C "$ORIGIN" rev-parse HEAD)" "$(git -C "$TAGENTS_HOME" rev-parse HEAD)"
contains "a command wrapper is written by the new installer" "v2: do not edit" "$(cat "$TAGENTS_BIN/tagents")"
contains "a node command wrapper too" "v2: do not edit" "$(cat "$TAGENTS_BIN/tagents-core")"
ok "and the hook wrappers in both dirs" 2 "$(cat "$HOOKS_A/tmux-agent-state.sh" "$HOOKS_B/tmux-agent-state.sh" | grep -c 'v2: do not edit')"
ok "the wrappers work" "tagents v1 a" "$("$TAGENTS_BIN/tagents" a)"
ok "the move is reported once" 1 "$(printf '%s\n' "$out" | grep -c 'install: moved ')"
ok "the install is reported once" 1 "$(printf '%s\n' "$out" | grep -c 'install: installed ')"
lacks "the run handed over does not take itself for another install" "another install is running" "$out"
ok "no lock left behind" "no" "$([ -e "$TAGENTS_HOME.lock" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
t "12. a commit whose install.sh cannot take the hand-over is finished by the running installer"
# ---------------------------------------------------------------------------
mkorigin; fresh_env
run >/dev/null
advance sh -c 'printf "#!/bin/sh\necho \"the old installer ran\"\n" > install.sh'
out=$(run); rc=$?
ok "exit status" 0 "$rc"
ok "the copy follows origin/main" "$(git -C "$ORIGIN" rev-parse HEAD)" "$(git -C "$TAGENTS_HOME" rev-parse HEAD)"
lacks "the commit's own installer did not run" "the old installer ran" "$out"
contains "the running installer installed" "install: installed " "$out"
ok "no lock left behind" "no" "$([ -e "$TAGENTS_HOME.lock" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
t "13. a Rust tagents-core next to the node CLI is used when it is there, and changes nothing when it is not"
# ---------------------------------------------------------------------------
# What this installer wrote before a Rust binary existed, spelled out: with no binary the wrapper files must stay these exact bytes.
wrapper_bytes() {  # <node or empty> <target> — the pinned form when a node path is given
  if [ -n "$1" ]; then
    printf '#!/bin/sh\n# managed by tagents install.sh, rewritten on every update: do not edit\nn="%s"\n[ -x "$n" ] || n=node\nexec "$n" "%s" "$@"\n' "$1" "$2"
  else
    printf '#!/bin/sh\n# managed by tagents install.sh, rewritten on every update: do not edit\nexec node "%s" "$@"\n' "$2"
  fi
}
same_bytes() {  # <name> <expected file> <actual file>
  if cmp -s "$2" "$3"; then pass=$((pass + 1)); printf '  ok   %s\n' "$1"; else
    fail=$((fail + 1)); printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$(cat "$2")" "$(cat "$3")"; fi
}
mkdir -p "$TMP/node-c"
printf '#!/bin/sh\necho "node-c $*"\n' > "$TMP/node-c/node"; chmod 755 "$TMP/node-c/node"
mkorigin; fresh_env
out=$(PATH="$TMP/node-c:$PATH" run); rc=$?
ok "an install with no Rust binary exits 0" 0 "$rc"
wrapper_bytes "$TMP/node-c/node" "$TAGENTS_HOME/packages/core/dist/cli/main.js" > "$TMP/expected-core"
wrapper_bytes "$TMP/node-c/node" "$TAGENTS_HOME/packages/knowledge/dist/cli/main.js" > "$TMP/expected-knowledge"
printf '#!/bin/sh\n# managed by tagents install.sh, rewritten on every update: do not edit\nexec sh "%s" "$@"\n' "$TAGENTS_HOME/hooks/tmux-agent-state.sh" > "$TMP/expected-hook"
same_bytes "with no binary, tagents-core is byte for byte what it always was" "$TMP/expected-core" "$TAGENTS_BIN/tagents-core"
same_bytes "tagents-knowledge too" "$TMP/expected-knowledge" "$TAGENTS_BIN/tagents-knowledge"
same_bytes "and a hook wrapper" "$TMP/expected-hook" "$HOOKS_A/tmux-agent-state.sh"
ok "the node CLI answers" "node-c $TAGENTS_HOME/packages/core/dist/cli/main.js a b" "$("$TAGENTS_BIN/tagents-core" a b)"

# A binary that is executable at install time is named by the wrapper, and gets the pinned node as TAGENTS_NODE.
RUST_BIN=$TAGENTS_HOME/target/release/tagents-core
mkdir -p "$(dirname "$RUST_BIN")"
printf '#!/bin/sh\necho "rust node=${TAGENTS_NODE-unset} $*"\nexit 7\n' > "$RUST_BIN"; chmod 755 "$RUST_BIN"
out=$(PATH="$TMP/node-c:$PATH" run); rc=$?
ok "an install with a Rust binary exits 0" 0 "$rc"
contains "the wrapper names the binary" 'r="'"$RUST_BIN"'"' "$(cat "$TAGENTS_BIN/tagents-core")"
contains "and still names the node CLI as the way out" 'exec "$n" "'"$TAGENTS_HOME"'/packages/core/dist/cli/main.js" "$@"' "$(cat "$TAGENTS_BIN/tagents-core")"
ok "the wrapper runs the binary, with the pinned node and every argument" "rust node=$TMP/node-c/node a b" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a b)"
env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a >/dev/null; rc=$?
ok "its exit code comes through untouched" 7 "$rc"
same_bytes "tagents-knowledge does not change" "$TMP/expected-knowledge" "$TAGENTS_BIN/tagents-knowledge"
same_bytes "nor does a hook wrapper" "$TMP/expected-hook" "$HOOKS_A/tmux-agent-state.sh"
rm -f "$RUST_BIN"
ok "once the binary is gone the same wrapper runs the node CLI" "node-c $TAGENTS_HOME/packages/core/dist/cli/main.js a b" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a b)"
printf '#!/bin/sh\necho "rust"\n' > "$RUST_BIN"; chmod 644 "$RUST_BIN"
out=$(PATH="$TMP/node-c:$PATH" run); rc=$?
same_bytes "a binary that is not executable is not named" "$TMP/expected-core" "$TAGENTS_BIN/tagents-core"
rm -f "$RUST_BIN"
out=$(PATH="$TMP/node-c:$PATH" run); rc=$?
same_bytes "after the binary is removed, the next update writes the old bytes back" "$TMP/expected-core" "$TAGENTS_BIN/tagents-core"

# No node on the installing shell's PATH: the wrapper looks node up at run time and has none to pass on.
if [ -n "$(env PATH=/usr/bin:/bin sh -c 'command -v node' 2>/dev/null)" ]; then
  printf '  skip /usr/bin or /bin holds a node\n'
else
  mkdir -p "$(dirname "$RUST_BIN")"
  printf '#!/bin/sh\necho "rust node=${TAGENTS_NODE-unset} $*"\n' > "$RUST_BIN"; chmod 755 "$RUST_BIN"
  out=$(PATH=/usr/bin:/bin run); rc=$?
  ok "an install from a shell finding no node exits 0" 0 "$rc"
  contains "the wrapper names the binary" 'r="'"$RUST_BIN"'"' "$(cat "$TAGENTS_BIN/tagents-core")"
  lacks "and pins no node" 'TAGENTS_NODE=' "$(cat "$TAGENTS_BIN/tagents-core")"
  ok "the binary is run without a node handed to it" "rust node=unset a" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a)"
  rm -f "$RUST_BIN"
  out=$(PATH=/usr/bin:/bin run); rc=$?
  wrapper_bytes "" "$TAGENTS_HOME/packages/core/dist/cli/main.js" > "$TMP/expected-core-unpinned"
  same_bytes "without the binary it is the old unpinned wrapper" "$TMP/expected-core-unpinned" "$TAGENTS_BIN/tagents-core"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
