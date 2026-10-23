#!/bin/sh
#
# install.sh — put tagents on this machine as ONE managed copy, and keep it there.
#
# The copy lives in $TAGENTS_HOME (~/.local/share/tagents). It is a clone that
# always stands on origin/main, detached, and nobody develops in it: the work
# goes on in a checkout of its own. Everything the machine actually runs is a
# small real file that execs into the copy, so no symlink leads anywhere and
# there is no path that quietly ends in somebody's working branch:
#
#   ~/.local/bin/tagents tusage tnotes      exec $TAGENTS_HOME/<name>
#   ~/.local/bin/tagents-core               exec <node> $TAGENTS_HOME/packages/core/dist/cli/main.js
#   ~/.local/bin/tagents-knowledge          exec <node> $TAGENTS_HOME/packages/knowledge/dist/cli/main.js
#   <hooks dir>/<name>.sh                   exec sh $TAGENTS_HOME/hooks/<name>.sh, one per hooks/*.sh
#   <node> is the node the install found on PATH, or node on the caller's PATH once that file is gone.
#
# Running it again IS the update: it fetches origin/main, moves the copy there and hands the rest of the run to the install.sh the copy now holds, which rebuilds and rewrites the wrappers, so a change to this file is in force from the update that brings it. A build that fails puts the copy back on the commit it was on, so a bad main costs one failed run and not the dashboard. `tagents update` runs this file from the copy it belongs to.
#
#   sh install.sh                       install or update
#   sh install.sh --check               say whether main has moved; change nothing
#   sh install.sh --hooks-dir DIR       put the hook wrappers into DIR (repeatable;
#                                       without it: ~/.claude/hooks). One per
#                                       Claude config directory on the machine
#   sh install.sh --launchd             also install a LaunchAgent that runs this
#                                       once a day (macOS); it remembers the
#                                       --hooks-dir list and the PATH of this shell
#   sh install.sh --quiet               print only warnings and errors
#
# A wrapper is only ever written over a symlink or over a file that carries the
# marker line below. Any other file with the name is somebody's own and is
# left alone, with a warning and exit status 1 at the end.
#
# Environment, for tests and for the unusual machine:
#   TAGENTS_HOME   the managed copy                     ~/.local/share/tagents
#   TAGENTS_BIN    where the command wrappers go        ~/.local/bin
#   TAGENTS_REPO   what to clone                        https://github.com/SkuratovichA/tagents.git
#   TAGENTS_REF    the branch to follow                 main
#   TAGENTS_BUILD_CMD  run in the copy after a move     pnpm install --frozen-lockfile && pnpm build
#   TAGENTS_LAUNCHD_DIR, TAGENTS_NO_LAUNCHCTL=1         where the plist goes, and not loading it
#   TAGENTS_MOVED_FROM  internal: the commit the copy left, set by the run that moved it for the run it hands over to
#
# POSIX sh. The whole program is the function at the bottom, called on the last line with an `exit` in the same breath: the copy this file lives in is rewritten by the update it performs, and a shell that is still reading a file which has just changed under it executes whatever now sits at its old offset. The program the shell parsed is still the old commit's after the move, which is why the move is followed by an exec of the new file.

set -eu

MARK='managed by tagents install.sh'
LAUNCHD_LABEL='io.github.skuratovicha.tagents-update'

say()  { [ "$QUIET" = 1 ] || printf 'tagents install: %s\n' "$*"; }
warn() { printf 'tagents install: %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

usage() {
  awk 'NR > 2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

short() { printf '%s' "$1" | cut -c1-7; }

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# A wrapper names the one file to run and passes everything through, stdin included, which is what a hook is fed on; an interpreter given by its absolute path is pinned, so the wrapper runs that file while it is executable and otherwise the interpreter of the same name on the caller's PATH.
write_wrapper() {  # <dest> <path to exec> [interpreter]
  dest=$1; target=$2; interp=${3:-}
  if [ -L "$dest" ]; then
    rm -f "$dest"
  elif [ -e "$dest" ] && ! grep -q "$MARK" "$dest" 2>/dev/null; then
    warn "$dest exists and is not a tagents wrapper, left alone"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  tmp=$dest.tmp.$$
  case $interp in
    /*) printf '#!/bin/sh\n# %s, rewritten on every update: do not edit\nn="%s"\n[ -x "$n" ] || n=%s\nexec "$n" "%s" "$@"\n' "$MARK" "$interp" "${interp##*/}" "$target" ;;
    *) printf '#!/bin/sh\n# %s, rewritten on every update: do not edit\nexec %s"%s" "$@"\n' "$MARK" "${interp:+$interp }" "$target" ;;
  esac > "$tmp"
  chmod 755 "$tmp"
  mv -f "$tmp" "$dest"
}

install_commands() {
  for name in tagents tusage tnotes; do
    write_wrapper "$TAGENTS_BIN/$name" "$TAGENTS_HOME/$name"
  done
  # The node CLIs pin the node this install found; none on PATH leaves them looking node up at run time.
  node_bin=$(command -v node || true)
  case $node_bin in /*) ;; *) node_bin=node ;; esac
  for pair in tagents-core:core tagents-knowledge:knowledge; do
    cli=$TAGENTS_HOME/packages/${pair#*:}/dist/cli/main.js
    if [ -f "$cli" ]; then
      write_wrapper "$TAGENTS_BIN/${pair%%:*}" "$cli" "$node_bin"
    else
      warn "no $cli after the build, so ${pair%%:*} was not installed"
      SKIPPED=$((SKIPPED + 1))
    fi
  done
}

install_hooks() {
  old_ifs=$IFS
  IFS='
'
  for dir in $HOOK_DIRS; do
    IFS=$old_ifs
    [ -n "$dir" ] || continue
    for src in "$TAGENTS_HOME"/hooks/*.sh; do
      [ -e "$src" ] || continue
      write_wrapper "$dir/${src##*/}" "$src" sh
    done
    # A hook the project dropped must stop being registered somewhere that
    # still points at it: the wrapper is ours, so it is ours to remove.
    for wrapper in "$dir"/*.sh; do
      [ -f "$wrapper" ] && [ ! -L "$wrapper" ] || continue
      grep -q "$MARK" "$wrapper" 2>/dev/null || continue
      if [ ! -e "$TAGENTS_HOME/hooks/${wrapper##*/}" ]; then
        rm -f "$wrapper"
        say "removed $wrapper: the project no longer ships that hook"
      fi
    done
  done
  IFS=$old_ifs
}

install_launchd() {
  if [ "$(uname -s)" != Darwin ]; then
    warn "--launchd is macOS only, skipped"
    return 0
  fi
  dir=${TAGENTS_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}
  plist=$dir/$LAUNCHD_LABEL.plist
  logdir=$HOME/Library/Logs/tagents
  mkdir -p "$dir" "$logdir"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n'
    printf '  <key>Label</key><string>%s</string>\n' "$LAUNCHD_LABEL"
    printf '  <key>ProgramArguments</key>\n  <array>\n'
    printf '    <string>/bin/sh</string>\n    <string>%s</string>\n    <string>--quiet</string>\n' "$(xml "$TAGENTS_HOME/install.sh")"
    old_ifs=$IFS
    IFS='
'
    for hdir in $HOOK_DIRS; do
      IFS=$old_ifs
      if [ -n "$hdir" ]; then
        printf '    <string>--hooks-dir</string>\n    <string>%s</string>\n' "$(xml "$hdir")"
      fi
    done
    IFS=$old_ifs
    printf '  </array>\n'
    # The PATH of the shell that installed: node and pnpm are found by it, and
    # a LaunchAgent starts with /usr/bin:/bin only.
    printf '  <key>EnvironmentVariables</key>\n  <dict>\n'
    printf '    <key>PATH</key><string>%s</string>\n' "$(xml "$PATH")"
    printf '    <key>HOME</key><string>%s</string>\n' "$(xml "$HOME")"
    printf '    <key>TAGENTS_HOME</key><string>%s</string>\n' "$(xml "$TAGENTS_HOME")"
    printf '    <key>TAGENTS_BIN</key><string>%s</string>\n' "$(xml "$TAGENTS_BIN")"
    printf '  </dict>\n'
    printf '  <key>StartCalendarInterval</key>\n  <dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>17</integer></dict>\n'
    printf '  <key>StandardOutPath</key><string>%s</string>\n' "$(xml "$logdir/update.log")"
    printf '  <key>StandardErrorPath</key><string>%s</string>\n' "$(xml "$logdir/update.log")"
    printf '</dict>\n</plist>\n'
  } > "$plist"
  if command -v plutil >/dev/null 2>&1 && ! plutil -lint "$plist" >/dev/null 2>&1; then
    rm -f "$plist"
    die "the LaunchAgent plist did not lint, removed"
  fi
  if [ "${TAGENTS_NO_LAUNCHCTL:-}" != 1 ]; then
    launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$plist" || warn "launchctl could not load $plist"
  fi
  say "daily update: $plist"
}

# The default build needs node and pnpm; a test or a machine that overrides
# TAGENTS_BUILD_CMD brings its own.
need_toolchain() {
  command -v node >/dev/null 2>&1 || die "node >= 22.18 is required and none is on PATH ($PATH)"
  command -v pnpm >/dev/null 2>&1 || die "pnpm is required and none is on PATH ($PATH)"
  version=$(node -p 'process.versions.node')
  major=${version%%.*}
  rest=${version#*.}
  minor=${rest%%.*}
  if [ "$major" -lt 22 ] || { [ "$major" -eq 22 ] && [ "$minor" -lt 18 ]; }; then
    die "node $version is too old, tagents needs >= 22.18 (this is the node on PATH: $(command -v node))"
  fi
}

build() {
  ( cd "$TAGENTS_HOME" && sh -c "$BUILD_CMD" ) > "$BUILD_LOG" 2>&1
}

acquire_lock() {
  lock=$TAGENTS_HOME.lock
  if ! mkdir "$lock" 2>/dev/null; then
    holder=$(cat "$lock/pid" 2>/dev/null || true)
    # exec keeps the pid and drops the EXIT trap: a lock that holds this pid was taken by the run that handed the update over to this one.
    if [ "$holder" != "$$" ]; then
      if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
        say "another install is running (pid $holder), nothing to do"
        exit 0
      fi
      rm -rf "$lock"
      mkdir "$lock" || die "cannot take $lock"
    fi
  fi
  printf '%s\n' "$$" > "$lock/pid"
  trap 'rm -rf "$lock" "$BUILD_LOG"' EXIT
  trap 'exit 1' INT TERM
}

# A function of its own, so its shifts leave main's arguments whole for the run main may hand over to.
parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
      --hooks-dir)
        [ $# -ge 2 ] || die "--hooks-dir needs a directory"
        HOOK_DIRS="$HOOK_DIRS$2
"
        shift 2 ;;
      --launchd) LAUNCHD=1; shift ;;
      --check)   CHECK=1; shift ;;
      --quiet)   QUIET=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *)         die "unknown option $1 (see --help)" ;;
    esac
  done
  [ -n "$HOOK_DIRS" ] || HOOK_DIRS="$HOME/.claude/hooks
"
}

main() {
  QUIET=0; CHECK=0; LAUNCHD=0; SKIPPED=0; HOOK_DIRS=''
  parse_args "$@"

  TAGENTS_HOME=${TAGENTS_HOME:-$HOME/.local/share/tagents}
  TAGENTS_BIN=${TAGENTS_BIN:-$HOME/.local/bin}
  TAGENTS_REPO=${TAGENTS_REPO:-https://github.com/SkuratovichA/tagents.git}
  TAGENTS_REF=${TAGENTS_REF:-main}
  BUILD_CMD=${TAGENTS_BUILD_CMD:-}
  if [ -z "$BUILD_CMD" ]; then
    BUILD_CMD='pnpm install --frozen-lockfile && pnpm build'
    DEFAULT_BUILD=1
  else
    DEFAULT_BUILD=0
  fi
  BUILD_LOG=$(mktemp "${TMPDIR:-/tmp}/tagents-build.XXXXXX")

  command -v git >/dev/null 2>&1 || die "git is required"
  mkdir -p "$(dirname "$TAGENTS_HOME")"
  acquire_lock

  fresh=0
  if [ ! -d "$TAGENTS_HOME/.git" ]; then
    if [ "$CHECK" = 1 ]; then
      say "not installed: $TAGENTS_HOME holds no copy"
      return 0
    fi
    if [ -n "$(ls -A "$TAGENTS_HOME" 2>/dev/null)" ]; then
      die "$TAGENTS_HOME exists and is not a tagents copy, refusing to touch it"
    fi
    say "cloning $TAGENTS_REPO into $TAGENTS_HOME"
    git clone --quiet "$TAGENTS_REPO" "$TAGENTS_HOME" || die "clone failed"
    fresh=1
  fi

  if [ -n "${TAGENTS_MOVED_FROM:-}" ]; then
    # The run that moved the copy handed the rest of the update to this file: no fetch and no move, only what follows them.
    prev=$TAGENTS_MOVED_FROM
    unset TAGENTS_MOVED_FROM
    target=$(git -C "$TAGENTS_HOME" rev-parse HEAD)
  else
    git -C "$TAGENTS_HOME" fetch --quiet origin "+refs/heads/$TAGENTS_REF:refs/remotes/origin/$TAGENTS_REF" \
      || die "cannot fetch $TAGENTS_REF from origin"
    target=$(git -C "$TAGENTS_HOME" rev-parse "refs/remotes/origin/$TAGENTS_REF")
    prev=$(git -C "$TAGENTS_HOME" rev-parse HEAD)

    if [ "$CHECK" = 1 ]; then
      if [ "$prev" = "$target" ]; then
        say "up to date at $(short "$target")"
      else
        say "behind: $(short "$prev") -> $(short "$target") on $TAGENTS_REF"
      fi
      return 0
    fi

    # Detached even when already on the right commit: a fresh clone is on a
    # branch, and a branch is what invites somebody to work in the copy.
    if [ "$prev" != "$target" ] || git -C "$TAGENTS_HOME" symbolic-ref -q HEAD >/dev/null 2>&1; then
      if [ -n "$(git -C "$TAGENTS_HOME" status --porcelain --untracked-files=no)" ]; then
        die "$TAGENTS_HOME has local changes, so it was not moved. It is a managed copy: develop in a clone of your own"
      fi
      git -C "$TAGENTS_HOME" checkout --quiet --detach "$target" || die "cannot move $TAGENTS_HOME to $(short "$target")"
      if [ "$prev" != "$target" ]; then say "moved $(short "$prev") -> $(short "$target")"; fi
    fi

    # From here on this is still the program of the commit the copy left, so the rest of an update goes to the install.sh the copy now holds, unless that one predates the hand-over; a clone is finished here.
    if [ "$prev" != "$target" ] && [ "$fresh" = 0 ] && grep -q TAGENTS_MOVED_FROM "$TAGENTS_HOME/install.sh" 2>/dev/null; then
      rm -f "$BUILD_LOG"
      TAGENTS_MOVED_FROM=$prev; export TAGENTS_MOVED_FROM
      exec sh "$TAGENTS_HOME/install.sh" "$@"
    fi
  fi

  if [ "$fresh" = 1 ] || [ "$prev" != "$target" ] || [ ! -f "$TAGENTS_HOME/packages/core/dist/cli/main.js" ]; then
    if [ "$DEFAULT_BUILD" = 1 ]; then need_toolchain; fi
    say "building"
    if ! build; then
      tail -n 25 "$BUILD_LOG" >&2
      if [ "$prev" != "$target" ] && [ "$fresh" = 0 ]; then
        git -C "$TAGENTS_HOME" checkout --quiet --detach "$prev" || true
        build || true
        die "the build of $(short "$target") failed, the copy is back on $(short "$prev")"
      fi
      die "the build failed"
    fi
  fi
  rm -f "$BUILD_LOG"

  mkdir -p "$TAGENTS_BIN"
  install_commands
  install_hooks
  if [ "$LAUNCHD" = 1 ]; then install_launchd; fi

  if [ "$SKIPPED" -gt 0 ]; then
    die "$SKIPPED file(s) were left alone, see above"
  fi
  say "installed $(short "$(git -C "$TAGENTS_HOME" rev-parse HEAD)") from $TAGENTS_REF into $TAGENTS_HOME"
}

main "$@"; exit $?
