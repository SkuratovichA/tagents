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
# The stub tagents of the origin answers the setup verb by writing down how it was called (section 15), which is all install.sh's hook-up to `tagents setup` needs proving here; the verb itself is tests/setup.sh.
#
# The prebuilt Rust tagents-core (section 14) is fetched from a directory of release files built by the real .github/scripts/core-release.sh around a stub binary, through a file:// TAGENTS_CORE_BASE_URL; no case reaches the network.
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
    mkdir -p hooks packages/core/dist/cli packages/knowledge/dist/cli packages/notify/dist packages/mcp/dist
    for f in tagents tusage tnotes; do printf '#!/bin/sh\necho "%s v1 $*"\n' "$f" > "$f"; chmod +x "$f"; done
    # install.sh calls `tagents setup` when a fresh install or an update needs it. The stub says nothing, writes down its arguments and what the first hooks directory held at that moment, and exits with the status a case leaves in $HOME/setup.status.
    cat > tagents <<'STUB'
#!/bin/sh
if [ "${1:-}" = setup ]; then
  shift
  printf '%s\n' "$*" >> "$HOME/setup.calls"
  ls "$HOOKS_A" 2>/dev/null | tr '\n' ' ' | sed 's/ $//' >> "$HOME/setup.hooks"; echo >> "$HOME/setup.hooks"
  exit "$(cat "$HOME/setup.status" 2>/dev/null || echo 0)"
fi
echo "tagents v1 $*"
STUB
    chmod +x tagents
    # The registration `tagents setup` reads. install_hooks wraps hooks/*.sh and nothing else, so the file has to be inert to it.
    cp "$ROOT/hooks/claude-settings.json" hooks/claude-settings.json
    # The hook echoes its stdin: a wrapper that dropped it would break every hook.
    printf '#!/bin/sh\necho "state v1 $* <$(cat)>"\n' > hooks/tmux-agent-state.sh
    printf '#!/bin/sh\necho "notes v1"\n' > hooks/notes-context.sh
    printf '#!/usr/bin/env node\n' > packages/core/dist/cli/main.js
    printf '#!/usr/bin/env node\n' > packages/knowledge/dist/cli/main.js
    printf '#!/usr/bin/env node\n' > packages/notify/dist/main.js
    printf '#!/usr/bin/env node\n' > packages/mcp/dist/main.js
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
  # A directory that holds no release: a case that has not set up one must never reach GitHub, and finds the Rust tagents-core nowhere.
  export TAGENTS_CORE_BASE_URL=file://$TMP/no-release
  unset TAGENTS_REF TAGENTS_CORE_TARGET TAGENTS_NO_NATIVE
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
         "$TAGENTS_BIN/tagents-knowledge" "$TAGENTS_BIN/tagents-notify" "$TAGENTS_BIN/tagents-mcp" \
         "$HOOKS_A/tmux-agent-state.sh" "$HOOKS_B/notes-context.sh"; do
  if [ -f "$f" ] && [ ! -L "$f" ] && [ -x "$f" ]; then
    pass=$((pass + 1)); printf '  ok   %s is an executable regular file\n' "${f#$HOME_DIR/}"
  else
    fail=$((fail + 1)); printf '  FAIL %s is not an executable regular file\n' "${f#$HOME_DIR/}"
  fi
done
ok "a command wrapper reaches the copy and passes its arguments" "tagents v1 a b" "$("$TAGENTS_BIN/tagents" a b)"
ok "a hook wrapper passes stdin and arguments through" "state v1 x <payload>" "$(printf payload | "$HOOKS_A/tmux-agent-state.sh" x)"
contains "the node CLI wrapper execs the copy's cli file with all arguments" '"'"$TAGENTS_HOME"'/packages/core/dist/cli/main.js" "$@"' "$(cat "$TAGENTS_BIN/tagents-core")"
contains "tagents-notify execs the notifier's entry, which the plugin's notification tool runs" '"'"$TAGENTS_HOME"'/packages/notify/dist/main.js" "$@"' "$(cat "$TAGENTS_BIN/tagents-notify")"
contains "tagents-mcp execs the plugin's tool server" '"'"$TAGENTS_HOME"'/packages/mcp/dist/main.js" "$@"' "$(cat "$TAGENTS_BIN/tagents-mcp")"
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
contains "tagents-notify and tagents-mcp pin it too" 'n="'"$TMP"'/node-a/node"' "$(cat "$TAGENTS_BIN/tagents-notify" "$TAGENTS_BIN/tagents-mcp")"
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
wrapper_bytes "$TMP/node-c/node" "$TAGENTS_HOME/packages/mcp/dist/main.js" > "$TMP/expected-mcp"
printf '#!/bin/sh\n# managed by tagents install.sh, rewritten on every update: do not edit\nexec sh "%s" "$@"\n' "$TAGENTS_HOME/hooks/tmux-agent-state.sh" > "$TMP/expected-hook"
same_bytes "with no binary, tagents-core is byte for byte what it always was" "$TMP/expected-core" "$TAGENTS_BIN/tagents-core"
same_bytes "tagents-knowledge too" "$TMP/expected-knowledge" "$TAGENTS_BIN/tagents-knowledge"
same_bytes "and tagents-mcp, which names no binary either" "$TMP/expected-mcp" "$TAGENTS_BIN/tagents-mcp"
same_bytes "and a hook wrapper" "$TMP/expected-hook" "$HOOKS_A/tmux-agent-state.sh"
ok "the node CLI answers" "node-c $TAGENTS_HOME/packages/core/dist/cli/main.js a b" "$("$TAGENTS_BIN/tagents-core" a b)"
ok "the node server answers through tagents-mcp" "node-c $TAGENTS_HOME/packages/mcp/dist/main.js a b" "$("$TAGENTS_BIN/tagents-mcp" a b)"

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
contains "tagents-mcp names the same binary" 'r="'"$RUST_BIN"'"' "$(cat "$TAGENTS_BIN/tagents-mcp")"
contains "...and hands it the word mcp before the arguments, with the pinned node" 'TAGENTS_NODE="$n"; export TAGENTS_NODE; exec "$r" mcp "$@"' "$(cat "$TAGENTS_BIN/tagents-mcp")"
contains "...and still names the node server as the way out" 'exec "$n" "'"$TAGENTS_HOME"'/packages/mcp/dist/main.js" "$@"' "$(cat "$TAGENTS_BIN/tagents-mcp")"
lacks "tagents-core hands its binary no word" 'exec "$r" mcp' "$(cat "$TAGENTS_BIN/tagents-core")"
ok "tagents-mcp runs the binary with the word, then every argument" "rust node=$TMP/node-c/node mcp a b" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-mcp" a b)"
env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-mcp" a >/dev/null; rc=$?
ok "...and its exit code comes through untouched" 7 "$rc"
same_bytes "tagents-knowledge does not change" "$TMP/expected-knowledge" "$TAGENTS_BIN/tagents-knowledge"
same_bytes "nor does a hook wrapper" "$TMP/expected-hook" "$HOOKS_A/tmux-agent-state.sh"
# The wrapper's two guards are each pinned by a case only that guard catches, on the wrapper written for the real binary and without a reinstall.
node_answer="node-c $TAGENTS_HOME/packages/core/dist/cli/main.js a b"
mcp_answer="node-c $TAGENTS_HOME/packages/mcp/dist/main.js a b"
rm -f "$RUST_BIN"; mkdir "$RUST_BIN"
ok "...and tagents-mcp falls through to the node server" "$mcp_answer" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-mcp" a b)"
ok "a directory where the binary was (it passes -x, so only the -f guard stops it) falls through to the node CLI" "$node_answer" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a b)"
rmdir "$RUST_BIN"
printf '#!/bin/sh\necho "rust"\n' > "$RUST_BIN"; chmod 644 "$RUST_BIN"
ok "a file without the executable bit (only the -x guard stops it) falls through to the node CLI" "$node_answer" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a b)"
ok "...and tagents-mcp falls through to the node server" "$mcp_answer" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-mcp" a b)"
rm -f "$RUST_BIN"
ok "once the binary is gone tagents-mcp runs the node server" "$mcp_answer" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-mcp" a b)"
ok "once the binary is gone the same wrapper runs the node CLI" "node-c $TAGENTS_HOME/packages/core/dist/cli/main.js a b" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a b)"
printf '#!/bin/sh\necho "rust"\n' > "$RUST_BIN"; chmod 644 "$RUST_BIN"
out=$(PATH="$TMP/node-c:$PATH" run); rc=$?
same_bytes "a binary that is not executable is not named" "$TMP/expected-core" "$TAGENTS_BIN/tagents-core"
same_bytes "...by tagents-mcp either" "$TMP/expected-mcp" "$TAGENTS_BIN/tagents-mcp"
rm -f "$RUST_BIN"
out=$(PATH="$TMP/node-c:$PATH" run); rc=$?
same_bytes "after the binary is removed, the next update writes the old bytes back" "$TMP/expected-core" "$TAGENTS_BIN/tagents-core"
same_bytes "...for tagents-mcp too" "$TMP/expected-mcp" "$TAGENTS_BIN/tagents-mcp"

# A binary that is present and executable but cannot run (its interpreter is missing) is an error: the wrapper must not fall back to the node CLI, which would print the marker.
mkdir -p "$(dirname "$RUST_BIN")"
printf '#!/nonexistent/interpreter\n' > "$RUST_BIN"; chmod 755 "$RUST_BIN"
PATH="$TMP/node-c:$PATH" run >/dev/null
contains "an install with a binary that cannot run still names it" 'r="'"$RUST_BIN"'"' "$(cat "$TAGENTS_BIN/tagents-core")"
out=$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-mcp" a b 2>/dev/null); rc=$?
if [ "$rc" -ne 0 ]; then rc_state=nonzero; else rc_state=zero; fi
ok "tagents-mcp over a binary that cannot run fails too" nonzero "$rc_state"
lacks "...without starting the node server" "node-c" "$out"
out=$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a b 2>"$TMP/cannot-run.err"); rc=$?
if [ "$rc" -ne 0 ]; then rc_state=nonzero; else rc_state=zero; fi
ok "a binary that cannot run fails with a non-zero exit" nonzero "$rc_state"
ok "...with a message on stderr" yes "$([ -s "$TMP/cannot-run.err" ] && echo yes || echo no)"
lacks "...and the node CLI was not run" "node-c" "$out"
# A directory at the binary's path is not a binary: the plain wrapper is written, which goes straight to the node CLI.
rm -f "$RUST_BIN"; mkdir "$RUST_BIN"
out=$(PATH="$TMP/node-c:$PATH" run); rc=$?
lacks "an install with a directory at the binary's path does not name it" 'r="'"$RUST_BIN"'"' "$(cat "$TAGENTS_BIN/tagents-core")"
lacks "...nor does tagents-mcp" 'r="'"$RUST_BIN"'"' "$(cat "$TAGENTS_BIN/tagents-mcp")"
ok "...and the wrapper runs the node CLI" "node-c $TAGENTS_HOME/packages/core/dist/cli/main.js a b" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a b)"
rmdir "$RUST_BIN"
out=$(PATH="$TMP/node-c:$PATH" run); rc=$?

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
  contains "tagents-mcp names the binary and the word, and pins no node" 'r="'"$RUST_BIN"'"' "$(cat "$TAGENTS_BIN/tagents-mcp")"
  contains "...with the word right before the arguments" '{ exec "$r" mcp "$@"; }' "$(cat "$TAGENTS_BIN/tagents-mcp")"
  ok "...and it runs the binary with the word" "rust node=unset mcp a" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-mcp" a)"
  rm -f "$RUST_BIN"
  out=$(PATH=/usr/bin:/bin run); rc=$?
  wrapper_bytes "" "$TAGENTS_HOME/packages/core/dist/cli/main.js" > "$TMP/expected-core-unpinned"
  same_bytes "without the binary it is the old unpinned wrapper" "$TMP/expected-core-unpinned" "$TAGENTS_BIN/tagents-core"
  wrapper_bytes "" "$TAGENTS_HOME/packages/mcp/dist/main.js" > "$TMP/expected-mcp-unpinned"
  same_bytes "...and so is tagents-mcp" "$TMP/expected-mcp-unpinned" "$TAGENTS_BIN/tagents-mcp"
fi

# A managed copy whose path holds a space: the wrapper must name the binary and run it with its arguments whole.
mkorigin; fresh_env
export TAGENTS_HOME="$HOME_DIR/share/a b/tagents"
out=$(PATH="$TMP/node-c:$PATH" run); rc=$?
ok "an install into a home with a space exits 0" 0 "$rc"
RUST_BIN=$TAGENTS_HOME/target/release/tagents-core
mkdir -p "$(dirname "$RUST_BIN")"
printf '#!/bin/sh\necho "rust $# $*"\n' > "$RUST_BIN"; chmod 755 "$RUST_BIN"
out=$(PATH="$TMP/node-c:$PATH" run); rc=$?
contains "the wrapper names the binary under the spaced home" 'r="'"$RUST_BIN"'"' "$(cat "$TAGENTS_BIN/tagents-core")"
ok "...and runs it with every argument" "rust 2 a b" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a b)"
contains "tagents-mcp names the binary under the spaced home" 'r="'"$RUST_BIN"'"' "$(cat "$TAGENTS_BIN/tagents-mcp")"
ok "...and passes the word and each argument whole, an argument with a space and an empty one included" "rust 4 mcp a b  c" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-mcp" "a b" "" c)"

# ---------------------------------------------------------------------------
t "14. the prebuilt Rust tagents-core: fetched for the version of the checkout, checked, and never kept when it is another version"
# ---------------------------------------------------------------------------
RELEASES=$TMP/releases
TRIPLE=aarch64-apple-darwin
CURL_LOG=$TMP/curl.log
REAL_CURL=$(command -v curl || true)
mkdir -p "$TMP/curlspy" "$TMP/curlfail" "$TMP/fetch-tmp"
# Passes every request on to the real curl and writes down its arguments; a file:// URL is all it is ever given here.
printf '#!/bin/sh\necho "$*" >> "%s"\nexec "%s" "$@"\n' "$CURL_LOG" "$REAL_CURL" > "$TMP/curlspy/curl"; chmod 755 "$TMP/curlspy/curl"
# Writes down its arguments and fails: the stand-in for GitHub being unreachable.
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 22\n' "$CURL_LOG" > "$TMP/curlfail/curl"; chmod 755 "$TMP/curlfail/curl"

sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1; else shasum -a 256 "$1" | cut -d ' ' -f 1; fi; }
exists() { if [ -e "$1" ] || [ -L "$1" ]; then echo yes; else echo no; fi; }
calls() { if [ -f "$CURL_LOG" ]; then wc -l < "$CURL_LOG" | tr -d ' '; else echo 0; fi; }
inodes() { ls -i "$RUST_BIN" "$RUST_BIN.release" 2>/dev/null | cut -d ' ' -f 1 | tr '\n' ' '; }
# Every run here goes through the spy, with the fake node of section 13 first, and its calls counted from zero.
run_native() { rm -f "$CURL_LOG"; PATH="$TMP/curlspy:$TMP/node-c:$PATH" run "$@"; }

set_version() {  # <version> — origin/main moves to a Cargo.toml with that workspace version
  advance sh -c 'printf "[workspace.package]\nversion = \"%s\"\n" "$1" > Cargo.toml' sh "$1"
}
make_release() {  # <version> <triple> [<version the binary claims>] — the two files of the release, made by the real packager around a stub binary
  local v=$1 tr=$2 said=${3:-$1} src=$TMP/stub-$1-$2
  rm -rf "$src"; mkdir -p "$src"
  printf '#!/bin/sh\nif [ "${1:-}" = --version ]; then echo "tagents-core %s"; exit 0; fi\necho "native-core %s $*"\n' "$said" "$v" > "$src/tagents-core"
  chmod 755 "$src/tagents-core"; printf 'license\n' > "$src/LICENSE"
  sh "$ROOT/.github/scripts/core-release.sh" package "$v" "$tr" "$src/tagents-core" "$src/LICENSE" "$RELEASES/v$v" >/dev/null
}
use_release() { export TAGENTS_CORE_BASE_URL=file://$RELEASES/v$1; }  # <version>
fresh_native() {  # <version> — origin at that version, its release made, nothing installed
  mkorigin; fresh_env; rm -rf "$RELEASES" "$TMP/fetch-tmp"; mkdir -p "$TMP/fetch-tmp"
  set_version "$1"; export TAGENTS_CORE_TARGET=$TRIPLE
  make_release "$1" "$TRIPLE"; use_release "$1"
  RUST_BIN=$TAGENTS_HOME/target/release/tagents-core
  ARCHIVE=tagents-core-$1-$TRIPLE.tar.gz
}
nothing_installed() {  # <name> — neither the binary nor its marker, and nothing else in target/release
  ok "$1: no binary" no "$(exists "$RUST_BIN")"
  ok "$1: no marker" no "$(exists "$RUST_BIN.release")"
  ok "$1: nothing left in target/release" "" "$(ls -A "$TAGENTS_HOME/target/release" 2>/dev/null)"
}
node_cli_answers() {  # <name>
  ok "$1: the wrapper runs the node CLI" "node-c $TAGENTS_HOME/packages/core/dist/cli/main.js a b" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a b)"
  ok "$1: tagents-mcp runs the node server" "node-c $TAGENTS_HOME/packages/mcp/dist/main.js a b" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-mcp" a b)"
}

# --- the first install fetches, checks and installs --------------------------
fresh_native 0.1.0
out=$(TMPDIR=$TMP/fetch-tmp run_native); rc=$?
ok "a first install exits 0" 0 "$rc"
contains "it says what it installed" "installed the prebuilt tagents-core 0.1.0 ($TRIPLE)" "$out"
ok "the binary is an executable regular file" yes "$([ -f "$RUST_BIN" ] && [ ! -L "$RUST_BIN" ] && [ -x "$RUST_BIN" ] && echo yes || echo no)"
ok "the marker is one line: version, target, SHA-256 of the binary" "0.1.0 $TRIPLE $(sha_of "$RUST_BIN")" "$(cat "$RUST_BIN.release")"
ok "target/release holds those two and nothing else" "tagents-core
tagents-core.release" "$(ls -A "$TAGENTS_HOME/target/release")"
contains "the wrapper names the binary" 'r="'"$RUST_BIN"'"' "$(cat "$TAGENTS_BIN/tagents-core")"
ok "the binary answers through the wrapper, with every argument" "native-core 0.1.0 a b" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a b)"
contains "tagents-mcp names the binary too" 'r="'"$RUST_BIN"'"' "$(cat "$TAGENTS_BIN/tagents-mcp")"
ok "...and the binary answers through it with the word mcp first" "native-core 0.1.0 mcp a b" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-mcp" a b)"
ok "two files were requested: the checksum, then the archive" "2" "$(calls)"
contains "the checksum was asked for first" "$ARCHIVE.sha256" "$(head -n 1 "$CURL_LOG")"
contains "every wait is bounded, whatever the URL" "--connect-timeout 15 --max-time 120" "$(cat "$CURL_LOG")"
contains "a file:// base is held to files" "--proto =file" "$(cat "$CURL_LOG")"
lacks "...and not allowed anything else" "--proto =https" "$(cat "$CURL_LOG")"
contains "the override is announced, once" "fetching the prebuilt tagents-core from file://$RELEASES/v0.1.0" "$out"
ok "...exactly once" 1 "$(printf '%s\n' "$out" | grep -c 'fetching the prebuilt tagents-core')"
# The binary is run once to read its version before it is placed, so the download lives where the binary will, and not in a TMPDIR that may be mounted noexec.
contains "the download goes to a directory under target/ of the copy" "-o $TAGENTS_HOME/target/tagents-core." "$(cat "$CURL_LOG")"
lacks "...and not to TMPDIR" "$TMP/fetch-tmp" "$(cat "$CURL_LOG")"
ok "the temporary directory is removed: target/ holds only release" "release" "$(ls -A "$TAGENTS_HOME/target")"

# --- the same version again: nothing happens, and the network is not touched --
before=$(inodes); marker_before=$(cat "$RUST_BIN.release")
export TAGENTS_CORE_BASE_URL=file://$TMP/does-not-exist
out=$(run_native); rc=$?
ok "a second run exits 0" 0 "$rc"
ok "it made no request" 0 "$(calls)"
ok "the binary and the marker are the same files" "$before" "$(inodes)"
ok "and the marker says the same" "$marker_before" "$(cat "$RUST_BIN.release")"
lacks "it says nothing about a binary" "prebuilt" "$out"

# --- the version moves: the old binary is replaced ----------------------------
set_version 0.1.1; make_release 0.1.1 "$TRIPLE"; use_release 0.1.1
out=$(run_native); rc=$?
ok "an update to a version with a release exits 0" 0 "$rc"
ok "the marker moved to the new version" "0.1.1 $TRIPLE $(sha_of "$RUST_BIN")" "$(cat "$RUST_BIN.release")"
ok "and the binary is the new one" "native-core 0.1.1 a" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a)"
ok "...also through tagents-mcp" "native-core 0.1.1 mcp a" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-mcp" a)"

# --- the version moves and its release is missing: the old binary goes ---------
set_version 0.1.2; use_release 0.1.2
out=$(run_native); rc=$?
ok "an update to a version with no release exits 0" 0 "$rc"
contains "it says there is no release, with the URL it tried" "no prebuilt tagents-core 0.1.2 for $TRIPLE (file://$RELEASES/v0.1.2/tagents-core-0.1.2-$TRIPLE.tar.gz.sha256), using the node CLI" "$out"
nothing_installed "the old binary of 0.1.1 is not kept"
same_bytes "the wrapper is the plain node one" <(wrapper_bytes "$TMP/node-c/node" "$TAGENTS_HOME/packages/core/dist/cli/main.js") "$TAGENTS_BIN/tagents-core"
same_bytes "...and so is the tagents-mcp one" <(wrapper_bytes "$TMP/node-c/node" "$TAGENTS_HOME/packages/mcp/dist/main.js") "$TAGENTS_BIN/tagents-mcp"
node_cli_answers "an install with no release"
out=$(run_native --quiet); rc=$?
ok "--quiet exits 0 too" 0 "$rc"
lacks "and hides the line" "no prebuilt" "$out"

# --- a download that fails its checks installs nothing, and fails the run -----
fresh_native 0.1.0; run_native >/dev/null
set_version 0.1.1; make_release 0.1.1 "$TRIPLE"; use_release 0.1.1
printf 'x' >> "$RELEASES/v0.1.1/tagents-core-0.1.1-$TRIPLE.tar.gz"
out=$(TMPDIR=$TMP/fetch-tmp run_native); rc=$?
ok "an archive that is not the one the checksum is of exits 1" 1 "$rc"
contains "the warning names the archive and both hashes" "the SHA-256 of tagents-core-0.1.1-$TRIPLE.tar.gz is" "$out"
contains "and says what the run came to" "the prebuilt tagents-core was not installed, see above, so the node CLI is in use" "$out"
nothing_installed "the 0.1.0 binary does not stay beside a failed 0.1.1"
ok "the wrappers were written all the same" "tagents v1 " "$("$TAGENTS_BIN/tagents")"
node_cli_answers "after a failed check"
ok "the temporary directory is removed after a failed check as well" 0 "$(ls -A "$TAGENTS_HOME/target" | grep -c '^tagents-core\.' || true)"
ok "...and nothing was made in TMPDIR for it" "" "$(ls -A "$TMP/fetch-tmp")"
make_release 0.1.1 "$TRIPLE"
printf '%s  %s\n' "$(printf 0%.0s $(seq 1 64))" "tagents-core-0.1.1-$TRIPLE.tar.gz" > "$RELEASES/v0.1.1/tagents-core-0.1.1-$TRIPLE.tar.gz.sha256"
out=$(run_native); rc=$?
ok "a checksum file naming another hash exits 1" 1 "$rc"
contains "...and says so" "the SHA-256 of tagents-core-0.1.1-$TRIPLE.tar.gz is" "$out"
nothing_installed "nothing is installed for it"
make_release 0.1.1 "$TRIPLE"
out=$(run_native); rc=$?
ok "the next run, with a release that checks out, installs it and exits 0" 0 "$rc"
ok "...and the binary is there" "native-core 0.1.1 a" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a)"

# --- a checksum file that is not a SHA-256 -------------------------------------
fresh_native 0.1.0
good=$(cut -d ' ' -f 1 "$RELEASES/v0.1.0/$ARCHIVE.sha256")
for bad in "not-a-hash  $ARCHIVE" "${good%????}  $ARCHIVE" "${good}00  $ARCHIVE" "$(printf '%s' "$good" | tr a-f A-F)  $ARCHIVE" ""; do
  printf '%s\n' "$bad" > "$RELEASES/v0.1.0/$ARCHIVE.sha256"
  out=$(run_native); rc=$?
  ok "a checksum file reading '${bad%%  *}' exits 1" 1 "$rc"
  contains "...with the reason" "$ARCHIVE.sha256 does not start with a SHA-256" "$out"
  nothing_installed "...and nothing is installed"
done

# The first line of the checksum file and its first field are all that count.
fresh_native 0.1.0
good=$(cut -d ' ' -f 1 "$RELEASES/v0.1.0/$ARCHIVE.sha256")
: > "$RELEASES/v0.1.0/$ARCHIVE.sha256"
out=$(run_native); rc=$?
ok "a checksum file of 0 bytes exits 1" 1 "$rc"
contains "...with the reason" "$ARCHIVE.sha256 does not start with a SHA-256" "$out"
nothing_installed "...and nothing is installed"
printf 'garbage here\n%s  %s\n' "$good" "$ARCHIVE" > "$RELEASES/v0.1.0/$ARCHIVE.sha256"
out=$(run_native); rc=$?
ok "a checksum file whose first line is garbage and whose second line is the right hash exits 1" 1 "$rc"
contains "...with the reason" "$ARCHIVE.sha256 does not start with a SHA-256" "$out"
nothing_installed "...and nothing is installed"
printf '%s  %s' "$good" "$ARCHIVE" > "$RELEASES/v0.1.0/$ARCHIVE.sha256"
out=$(run_native); rc=$?
ok "a checksum file with the right hash and no newline at the end exits 0" 0 "$rc"
ok "...and installs the binary" "native-core 0.1.0 a" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a)"
fresh_native 0.1.0
printf 'this is not a tarball\n' > "$RELEASES/v0.1.0/$ARCHIVE"
printf '%s  %s\n' "$(sha_of "$RELEASES/v0.1.0/$ARCHIVE")" "$ARCHIVE" > "$RELEASES/v0.1.0/$ARCHIVE.sha256"
out=$(run_native); rc=$?
ok "a file that is not an archive, whose checksum matches it, exits 1" 1 "$rc"
contains "...with the reason" "does not hold exactly tagents-core and LICENSE" "$out"
nothing_installed "...and nothing is installed"

# --- an archive that is not exactly tagents-core and LICENSE ---------------------
STAGE=$TMP/stage
stage_files() {
  rm -rf "$STAGE" "$TMP/stage-link" "$TMP/outside"; mkdir -p "$STAGE" "$TMP/stage-link"
  printf '#!/bin/sh\nif [ "${1:-}" = --version ]; then echo "tagents-core 0.1.0"; exit 0; fi\n' > "$STAGE/tagents-core"; chmod 755 "$STAGE/tagents-core"
  printf 'license\n' > "$STAGE/LICENSE"; printf 'extra\n' > "$STAGE/extra"; printf 'outside\n' > "$TMP/outside"
  cp "$STAGE/LICENSE" "$TMP/stage-link/LICENSE"; ln -s "$STAGE/tagents-core" "$TMP/stage-link/tagents-core"
}
custom_archive() {  # <stage dir> <member…> — the release archive replaced by one with exactly those members and a checksum that matches it
  local dir=$1; shift
  ( cd "$dir" && tar -czPf "$RELEASES/v0.1.0/$ARCHIVE" "$@" )
  printf '%s  %s\n' "$(sha_of "$RELEASES/v0.1.0/$ARCHIVE")" "$ARCHIVE" > "$RELEASES/v0.1.0/$ARCHIVE.sha256"
}
fresh_native 0.1.0; stage_files
custom_archive "$STAGE" tagents-core LICENSE extra
out=$(run_native); rc=$?
ok "an archive with a third member exits 1" 1 "$rc"
contains "...with the reason" "does not hold exactly tagents-core and LICENSE" "$out"
nothing_installed "...and nothing is installed"
custom_archive "$STAGE" tagents-core
out=$(run_native); rc=$?
ok "an archive without the LICENSE exits 1" 1 "$rc"
nothing_installed "...and nothing is installed"
custom_archive "$STAGE" tagents-core LICENSE ../outside
out=$(run_native); rc=$?
ok "an archive with a member outside its own directory exits 1" 1 "$rc"
contains "...with the reason" "does not hold exactly tagents-core and LICENSE" "$out"
nothing_installed "...and nothing is installed"
custom_archive "$TMP/stage-link" tagents-core LICENSE
out=$(run_native); rc=$?
ok "an archive whose tagents-core is a symlink exits 1" 1 "$rc"
contains "...with the reason" "does not unpack to a tagents-core file" "$out"
nothing_installed "...and nothing is installed"
custom_archive "$STAGE" tagents-core LICENSE
out=$(run_native); rc=$?
ok "the same stage with the right members installs" 0 "$rc"

# --- a binary that does not say it is this version ------------------------------
fresh_native 0.1.0
make_release 0.1.0 "$TRIPLE" 9.9.9
out=$(run_native); rc=$?
ok "a binary whose --version says another version exits 1" 1 "$rc"
contains "...and the warning quotes what it said" "says 'tagents-core 9.9.9' for --version, not 'tagents-core 0.1.0'" "$out"
nothing_installed "...and nothing is installed"
stage_files; printf '#!/bin/sh\nexit 1\n' > "$STAGE/tagents-core"
custom_archive "$STAGE" tagents-core LICENSE
out=$(run_native); rc=$?
ok "a binary that fails --version exits 1" 1 "$rc"
contains "...and the warning says it said nothing" "says '' for --version" "$out"
nothing_installed "...and nothing is installed"

# --- a binary built by hand is not ours ----------------------------------------
fresh_native 0.1.0
TAGENTS_NO_NATIVE=1 run_native >/dev/null
mkdir -p "$(dirname "$RUST_BIN")"
printf '#!/bin/sh\nif [ "${1:-}" = --version ]; then echo "tagents-core 0.1.0"; exit 0; fi\necho handbuilt\n' > "$RUST_BIN"; chmod 755 "$RUST_BIN"
out=$(run_native); rc=$?
ok "an install over a hand-built binary exits 0" 0 "$rc"
ok "it made no request" 0 "$(calls)"
ok "the binary is as it was" "handbuilt" "$("$RUST_BIN")"
ok "and gained no marker" no "$(exists "$RUST_BIN.release")"
ok "the wrapper names it" "handbuilt" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core")"
ok "...and tagents-mcp runs it too" "handbuilt" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-mcp")"
out=$(TAGENTS_NO_NATIVE=1 run_native); rc=$?
ok "TAGENTS_NO_NATIVE=1 leaves it alone as well" "handbuilt" "$("$RUST_BIN")"
chmod 644 "$RUST_BIN"
out=$(run_native); rc=$?
ok "a hand-built file that is not executable is left alone too" yes "$(grep -q handbuilt "$RUST_BIN" && echo yes || echo no)"
ok "...with no request" 0 "$(calls)"

# A binary of another version hands the word mcp to the node CLI, which does not know it: tagents-mcp leaves such a binary and runs the node server, where tagents-core still names it because every verb it lacks goes to the node CLI.
printf '#!/bin/sh\nif [ "${1:-}" = --version ]; then echo "tagents-core 0.0.9"; exit 0; fi\necho handbuilt\n' > "$RUST_BIN"; chmod 755 "$RUST_BIN"
out=$(run_native); rc=$?
ok "an install over a hand-built binary of another version exits 0" 0 "$rc"
ok "tagents-core still names it" "handbuilt" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core")"
lacks "tagents-mcp does not name it" 'r="'"$RUST_BIN"'"' "$(cat "$TAGENTS_BIN/tagents-mcp")"
ok "...so a session gets the node server" "node-c $TAGENTS_HOME/packages/mcp/dist/main.js a b" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-mcp" a b)"
printf '#!/nonexistent/interpreter\n' > "$RUST_BIN"; chmod 755 "$RUST_BIN"
out=$(run_native); rc=$?
lacks "a hand-built binary that cannot say its version is not named by tagents-mcp either" 'r="'"$RUST_BIN"'"' "$(cat "$TAGENTS_BIN/tagents-mcp")"
contains "...while tagents-core names it" 'r="'"$RUST_BIN"'"' "$(cat "$TAGENTS_BIN/tagents-core")"
printf '#!/bin/sh\nif [ "${1:-}" = --version ]; then echo "tagents-core 0.1.0"; exit 0; fi\necho handbuilt\n' > "$RUST_BIN"; chmod 755 "$RUST_BIN"
out=$(run_native); rc=$?
contains "a hand-built binary of the checkout's version is named again" 'r="'"$RUST_BIN"'"' "$(cat "$TAGENTS_BIN/tagents-mcp")"

# --- TAGENTS_NO_NATIVE=1 --------------------------------------------------------
fresh_native 0.1.0
out=$(TAGENTS_NO_NATIVE=1 run_native); rc=$?
ok "TAGENTS_NO_NATIVE=1 on a fresh install exits 0" 0 "$rc"
ok "...fetches nothing" 0 "$(calls)"
nothing_installed "...and installs nothing"
run_native >/dev/null
ok "without it the binary is installed" yes "$(exists "$RUST_BIN.release")"
out=$(TAGENTS_NO_NATIVE=1 run_native); rc=$?
ok "with it, a prebuilt binary is removed" 0 "$rc"
contains "...and the line says why" "removed the prebuilt tagents-core: TAGENTS_NO_NATIVE=1" "$out"
nothing_installed "...with its marker"
node_cli_answers "after the removal"

# --- a machine with no prebuilt binary -----------------------------------------
fresh_native 0.1.0; run_native >/dev/null
export TAGENTS_CORE_TARGET=riscv-nothing
out=$(run_native); rc=$?
ok "an unsupported target exits 0" 0 "$rc"
contains "it says so and names the target" "no prebuilt tagents-core for riscv-nothing, using the node CLI" "$out"
ok "...with no request" 0 "$(calls)"
nothing_installed "...and the binary of another target does not stay"
unset TAGENTS_CORE_TARGET
fresh_native 0.1.0; unset TAGENTS_CORE_TARGET
export TAGENTS_CORE_BASE_URL=file://$TMP/no-release
for row in "Linux x86_64 0|x86_64-unknown-linux-musl" "Darwin x86_64 0|x86_64-apple-darwin" "Darwin x86_64 1|aarch64-apple-darwin" \
           "Darwin arm64 0|aarch64-apple-darwin" "Linux aarch64 0|none"; do
  read -r os arch translated <<< "${row%%|*}"; want=${row##*|}
  shim=$TMP/uname-shim; rm -rf "$shim"; mkdir -p "$shim"
  printf '#!/bin/sh\ncase "$1" in -m) echo %s ;; *) echo %s ;; esac\n' "$arch" "$os" > "$shim/uname"
  printf '#!/bin/sh\necho %s\n' "$translated" > "$shim/sysctl"; chmod 755 "$shim/uname" "$shim/sysctl"
  out=$(PATH="$shim:$PATH" run_native); rc=$?
  ok "$os $arch (translated=$translated) exits 0" 0 "$rc"
  if [ "$want" = none ]; then
    contains "...and has no binary to fetch" "no prebuilt tagents-core for $os $arch, using the node CLI" "$out"
  else
    contains "...and asks for $want" "no prebuilt tagents-core 0.1.0 for $want (" "$out"
  fi
done

# --- no curl, no tool for a SHA-256 ---------------------------------------------
farm() {  # <dir> <names to leave out…> — a PATH of /usr/bin and /bin without those names, plus git
  local d=$1 src n x skip; shift
  rm -rf "$d"; mkdir -p "$d"
  for src in /usr/bin/* /bin/*; do
    n=${src##*/}; skip=0
    for x in "$@"; do [ "$n" = "$x" ] && skip=1; done
    if [ "$skip" = 0 ] && [ ! -e "$d/$n" ]; then ln -s "$src" "$d/$n"; fi
  done
  if [ ! -e "$d/git" ]; then ln -s "$(command -v git)" "$d/git"; fi
}
fresh_native 0.1.0
farm "$TMP/farm-no-curl" curl
out=$(PATH=$TMP/farm-no-curl run); rc=$?
ok "an install with no curl exits 0" 0 "$rc"
contains "...and says why there is no binary" "curl is not here to fetch the prebuilt tagents-core with, using the node CLI" "$out"
nothing_installed "...and installs none"
run_native >/dev/null
before=$(inodes)
out=$(PATH=$TMP/farm-no-curl run); rc=$?
ok "a run with no curl keeps a binary that is the right one" "$before" "$(inodes)"
farm "$TMP/farm-no-sha" sha256sum shasum
out=$(PATH=$TMP/farm-no-sha run); rc=$?
ok "an install with no SHA-256 tool exits 0" 0 "$rc"
contains "...and says why" "neither sha256sum nor shasum is here" "$out"
nothing_installed "...and a binary it cannot check is not kept"

# --- the other states of a marked binary ---------------------------------------
fresh_native 0.1.0; run_native >/dev/null
printf '#!/bin/sh\necho evil\n' > "$RUST_BIN"; chmod 755 "$RUST_BIN"
out=$(run_native); rc=$?
ok "a marked binary changed since it was installed exits 0" 0 "$rc"
ok "...and is replaced by a download" "native-core 0.1.0 a" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a)"
ok "...with a marker for what is there now" "0.1.0 $TRIPLE $(sha_of "$RUST_BIN")" "$(cat "$RUST_BIN.release")"
printf '0.1.0 x86_64-apple-darwin %s\n' "$(sha_of "$RUST_BIN")" > "$RUST_BIN.release"
printf '#!/bin/sh\necho other-target\n' > "$RUST_BIN"; printf '0.1.0 x86_64-apple-darwin %s\n' "$(sha_of "$RUST_BIN")" > "$RUST_BIN.release"
out=$(run_native); rc=$?
ok "a binary installed for another target is replaced" "native-core 0.1.0 a" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a)"
printf '0.1.0 %s %s extra\n' "$TRIPLE" "$(sha_of "$RUST_BIN")" > "$RUST_BIN.release"
before=$(inodes)
out=$(run_native); rc=$?
ok "a marker with a fourth field is no marker of ours: the binary is fetched again" 2 "$(calls)"
: > "$RUST_BIN.release"
out=$(run_native); rc=$?
ok "an empty marker is fetched again" 2 "$(calls)"
ok "...and a good one written" "0.1.0 $TRIPLE $(sha_of "$RUST_BIN")" "$(cat "$RUST_BIN.release")"
rm -f "$RUST_BIN"
use_release 0.1.5
out=$(run_native); rc=$?
ok "a marker without its binary exits 0" 0 "$rc"
nothing_installed "...and is removed when there is no release"
fresh_native 0.1.0; run_native >/dev/null
rm -f "$RUST_BIN"
out=$(run_native); rc=$?
ok "a marker without its binary, with a release, installs again" "native-core 0.1.0 a" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a)"
rm -f "$RUST_BIN"; mkdir "$RUST_BIN"; touch "$RUST_BIN/inside"
use_release 0.1.5
out=$(run_native); rc=$?
ok "a directory where a marked binary was is removed" 0 "$rc"
nothing_installed "...with the marker"
fresh_native 0.1.0; run_native >/dev/null
advance sh -c 'printf "[workspace.package]\nversion = \"1.0\"\n" > Cargo.toml'
out=$(run_native); rc=$?
ok "a Cargo.toml with no usable version exits 0" 0 "$rc"
contains "...says so" "no workspace version in $TAGENTS_HOME/Cargo.toml, using the node CLI" "$out"
nothing_installed "...and keeps no binary"

# --- a base URL that is not https:// or file:// is not fetched from --------------------
fresh_native 0.1.0
for bad in http://mirror.example/tagents ftp://mirror.example/tagents /some/dir/tagents /some/dir/ / mirror.example/tagents; do
  export TAGENTS_CORE_BASE_URL=$bad
  out=$(run_native); rc=$?
  ok "a base URL of '$bad' ends the run with status 1" 1 "$rc"
  contains "...with a warning that names the variable" "TAGENTS_CORE_BASE_URL has to start with https:// or file://, so the prebuilt tagents-core was not fetched" "$out"
  ok "...and no request was made" 0 "$(calls)"
  nothing_installed "...and nothing is installed"
  node_cli_answers "...and the node CLI still runs"
done
# The refusal comes after the old binary was dropped: a binary of 0.1.0 does not stay beside a copy that moved on to 0.1.1, whatever the base is.
fresh_native 0.1.0; run_native >/dev/null
ok "0.1.0 is installed natively, to start from" "native-core 0.1.0 a" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a)"
set_version 0.1.1
export TAGENTS_CORE_BASE_URL=http://example.invalid/x
out=$(run_native); rc=$?
ok "an update to 0.1.1 with a base that is not https or file exits 1" 1 "$rc"
contains "...with the warning that names the variable" "TAGENTS_CORE_BASE_URL has to start with https:// or file://, so the prebuilt tagents-core was not fetched" "$out"
ok "...and no request was made" 0 "$(calls)"
nothing_installed "...and the 0.1.0 binary and its marker are gone"
fresh_native 0.1.0
export TAGENTS_CORE_BASE_URL=https://mirror.example/tagents/v0.1.0/
out=$(PATH="$TMP/curlfail:$TMP/node-c:$PATH" run); rc=$?
ok "an https:// override that cannot be reached exits 0" 0 "$rc"
contains "...it is announced" "fetching the prebuilt tagents-core from https://mirror.example/tagents/v0.1.0" "$out"
contains "...the request goes to the mirror" "https://mirror.example/tagents/v0.1.0/$ARCHIVE.sha256" "$(cat "$CURL_LOG")"
contains "...held to HTTPS, TLS 1.2 or newer" "--proto =https --tlsv1.2" "$(cat "$CURL_LOG")"
contains "...and retried" "--retry 2" "$(cat "$CURL_LOG")"
fresh_native 0.1.0
mkdir -p "$TAGENTS_HOME"; TAGENTS_NO_NATIVE=1 run_native >/dev/null
use_release 0.1.0
touch "$TAGENTS_HOME/target"
out=$(run_native); rc=$?
ok "a target/ that cannot be made a directory exits 1" 1 "$rc"
contains "...with the reason" "cannot make a temporary directory in $TAGENTS_HOME/target" "$out"
ok "...and no request was made" 0 "$(calls)"
rm -f "$TAGENTS_HOME/target"

# --- a base URL with a trailing slash; the real URL and its flags ---------------
fresh_native 0.1.0
export TAGENTS_CORE_BASE_URL=file://$RELEASES/v0.1.0/
out=$(run_native); rc=$?
ok "a base URL ending in a slash works" "native-core 0.1.0 a" "$(env PATH=/usr/bin:/bin "$TAGENTS_BIN/tagents-core" a)"
fresh_native 0.1.0; unset TAGENTS_CORE_BASE_URL
rm -f "$CURL_LOG"
out=$(PATH="$TMP/curlfail:$TMP/node-c:$PATH" run); rc=$?
ok "GitHub being unreachable exits 0" 0 "$rc"
contains "the URL is the release of the version, on GitHub" "(https://github.com/SkuratovichA/tagents/releases/download/v0.1.0/$ARCHIVE.sha256)" "$out"
lacks "the default URL is not announced" "fetching the prebuilt" "$out"
contains "the request is HTTPS only, TLS 1.2 or newer" "--proto =https --tlsv1.2" "$(cat "$CURL_LOG")"
contains "...bounded in time" "--connect-timeout 15 --max-time 120" "$(cat "$CURL_LOG")"
contains "...and retried" "--retry 2" "$(cat "$CURL_LOG")"
nothing_installed "nothing is installed"

# --- --check asks for nothing and touches nothing ------------------------------
fresh_native 0.1.0; run_native >/dev/null
before=$(inodes)
set_version 0.1.1; use_release 0.1.1
out=$(run_native --check); rc=$?
ok "--check exits 0" 0 "$rc"
ok "...makes no request" 0 "$(calls)"
ok "...and leaves the binary and its marker as they are" "$before" "$(inodes)"

# ---------------------------------------------------------------------------
t "15. the Claude Code settings: \`tagents setup\` runs after an install that needs it, and not otherwise"
# ---------------------------------------------------------------------------
setup_argv()  { cat "$HOME_DIR/setup.calls" 2>/dev/null || true; }
setup_count() { if [ -f "$HOME_DIR/setup.calls" ]; then wc -l < "$HOME_DIR/setup.calls" | tr -d ' '; else echo 0; fi; }

mkorigin; fresh_env
out=$(run); rc=$?
ok "a fresh install: exit status" 0 "$rc"
ok "...runs setup once" 1 "$(setup_count)"
ok "...with the hooks directories it installed into, in the order given" "--hooks-dir $HOOKS_A --hooks-dir $HOOKS_B" "$(setup_argv)"
ok "...after the hook wrappers were written" "notes-context.sh tmux-agent-state.sh" "$(cat "$HOME_DIR/setup.hooks")"
ok "...and the registration is not wrapped as a hook, there or in the second directory" "no no" "$([ -e "$HOOKS_A/claude-settings.json" ] && echo yes || echo no) $([ -e "$HOOKS_B/claude-settings.json" ] && echo yes || echo no)"
out=$(run); rc=$?
ok "a run that moves nothing: exit status" 0 "$rc"
ok "...does not run it again" 1 "$(setup_count)"
advance sh -c 'echo v2 > VERSION'
out=$(run); rc=$?
ok "an update that changes some other file: exit status" 0 "$rc"
ok "...does not run it" 1 "$(setup_count)"
advance sh -c 'printf "\n" >> hooks/claude-settings.json'
out=$(run --check); rc=$?
contains "--check after the registration changed says the copy is behind" "behind: " "$out"
ok "...and runs nothing" 1 "$(setup_count)"
out=$(run); rc=$?
ok "an update that changes the registration: exit status" 0 "$rc"
ok "...runs it" 2 "$(setup_count)"
ok "...with the arguments of the first time" 1 "$(setup_argv | sort -u | wc -l | tr -d ' ')"
ok "...and the hand-over to the new installer did not lose the hooks directories" "--hooks-dir $HOOKS_A --hooks-dir $HOOKS_B" "$(setup_argv | tail -n 1)"

mkorigin; fresh_env
out=$(run --quiet); rc=$?
ok "--quiet: exit status" 0 "$rc"
ok "...is passed on" "--quiet --hooks-dir $HOOKS_A --hooks-dir $HOOKS_B" "$(setup_argv)"
ok "...and the installer itself says nothing" "" "$out"

mkorigin; fresh_env
out=$(run --check); rc=$?
ok "--check on a machine with no copy runs nothing" 0 "$(setup_count)"

mkorigin; fresh_env
advance git rm -q hooks/claude-settings.json
out=$(run); rc=$?
ok "a fresh install of a copy that has no registration: exit status" 0 "$rc"
ok "...has nothing to register, so runs nothing" 0 "$(setup_count)"
advance git checkout -q HEAD~1 -- hooks/claude-settings.json
out=$(run); rc=$?
ok "the update that brings the registration: exit status" 0 "$rc"
ok "...runs it" 1 "$(setup_count)"
advance git rm -q hooks/claude-settings.json
out=$(run); rc=$?
ok "the update that takes it away: exit status" 0 "$rc"
ok "...runs nothing" 1 "$(setup_count)"

mkorigin; fresh_env
printf 1 > "$HOME_DIR/setup.status"
out=$(run); rc=$?
ok "a setup that fails: the install ends with status 1" 1 "$rc"
contains "...with the warning" "tagents install: the Claude Code settings were not all set up, see above" "$out"
ok "...said once" 1 "$(printf '%s\n' "$out" | grep -c 'not all set up')"
lacks "...and it does not claim to have installed everything" "install: installed " "$out"
ok "...after the commands were installed" "tagents v1 " "$("$TAGENTS_BIN/tagents")"
ok "...and the hook wrappers in both directories" "yes" "$([ -x "$HOOKS_A/tmux-agent-state.sh" ] && [ -x "$HOOKS_B/tmux-agent-state.sh" ] && echo yes || echo no)"
rm -f "$HOME_DIR/setup.status"
out=$(run); rc=$?
ok "the next run, with nothing moved, does not try again and ends well" "0 1" "$rc $(setup_count)"

# The arguments install.sh builds are the ones the real verb takes: what a quiet install passed to the stub is handed to the verb itself, with --check and a config directory of the sandbox, so that nothing is written whatever the machine holds. A refusal of the options is exit status 2.
mkorigin; fresh_env
run --quiet >/dev/null
# shellcheck disable=SC2046
out=$(env -u CLAUDE_CONFIG_DIR HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" TA_CONFIG="$HOME_DIR/.config/tagents/config.toml" TMPDIR="$TMP" \
        bash "$ROOT/tagents" setup $(setup_argv) --check --config-dir "$HOME_DIR/claude-a" 2>&1); rc=$?
case $rc in 0|1) verdict=accepted ;; *) verdict="refused with status $rc" ;; esac
ok "the real verb takes the arguments install.sh passes" accepted "$verdict"
lacks "...without a word about an option" "option" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
