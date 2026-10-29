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
#                                           or $TAGENTS_HOME/target/release/tagents-core when that binary exists at install time (the node CLI stays the fallback)
#                                           the binary is the prebuilt one of this checkout's version when a release has it (below), or one built by hand
#   ~/.local/bin/tagents-knowledge          exec <node> $TAGENTS_HOME/packages/knowledge/dist/cli/main.js
#   <hooks dir>/<name>.sh                   exec sh $TAGENTS_HOME/hooks/<name>.sh, one per hooks/*.sh
#   <node> is the node the install found on PATH, or node on the caller's PATH once that file is gone.
#
# The Rust tagents-core: after the build, the installer fetches the binary of the version in $TAGENTS_HOME/Cargo.toml from the GitHub release v<version>, checks it (SHA-256, the archive's members, `tagents-core --version`) and installs it with a marker file, target/release/tagents-core.release, that names the version, the target and the SHA-256 of the binary. A binary with no marker was built by hand and is never touched. A marked binary of another version, another target or another hash is deleted before anything is downloaded. No release for the version, no network, an unsupported machine: the node CLI stays in use and the run still succeeds; a download that fails its checks is installed nowhere and makes the run end with status 1. docs/architecture/rust-core.md has the rules in one table.
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
#   TAGENTS_NO_NATIVE=1   do not fetch the Rust tagents-core, and remove a prebuilt one (a hand-built one stays)
#   TAGENTS_CORE_BASE_URL where the release files are (a directory URL that starts with https:// or file://; any other scheme is refused with a warning)   https://github.com/SkuratovichA/tagents/releases/download/v<version>
#   TAGENTS_CORE_TARGET   the target to fetch for: x86_64-unknown-linux-musl, x86_64-apple-darwin or aarch64-apple-darwin   from uname
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

# A wrapper names the one file to run and passes everything through, stdin included, which is what a hook is fed on; an interpreter given by its absolute path is pinned, so the wrapper runs that file while it is executable and otherwise the interpreter of the same name on the caller's PATH. A native binary, when one is given, is run in place of the file, with the interpreter handed to it as TAGENTS_NODE.
# A native binary is looked up in the tree and the wrapper cannot tell which source it was built from; fetch_native keeps the one it installed to the version of the checkout, and a binary built by hand goes stale after `tagents update` until the next `cargo build --release`.
write_wrapper() {  # <dest> <path to exec> [interpreter] [native binary]
  dest=$1; target=$2; interp=${3:-}; native=${4:-}
  if [ -L "$dest" ]; then
    rm -f "$dest"
  elif [ -e "$dest" ] && ! grep -q "$MARK" "$dest" 2>/dev/null; then
    warn "$dest exists and is not a tagents wrapper, left alone"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  tmp=$dest.tmp.$$
  {
    printf '#!/bin/sh\n# %s, rewritten on every update: do not edit\n' "$MARK"
    case $interp in
      /*) printf 'n="%s"\n[ -x "$n" ] || n=%s\n' "$interp" "${interp##*/}"; runner='"$n" '; pin='TAGENTS_NODE="$n"; export TAGENTS_NODE; ' ;;
      *) runner=${interp:+$interp }; pin= ;;
    esac
    # Only a binary that exists now is named, so with none the file is the one this function always wrote. A binary that is gone by run time falls through to the node CLI below.
    if [ -n "$native" ]; then printf 'r="%s"\n[ ! -f "$r" ] || [ ! -x "$r" ] || { %sexec "$r" "$@"; }\n' "$native" "$pin"; fi
    printf 'exec %s"%s" "$@"\n' "$runner" "$target"
  } > "$tmp"
  chmod 755 "$tmp"
  mv -f "$tmp" "$dest"
}

# The Rust tagents-core. The managed copy follows main every day, and a binary is only worth running when it is built from the source of the checkout, so the identity of a binary is the workspace version in Cargo.toml: .github/workflows/release.yml publishes v<version> and the gate in rust.yml makes every change to what the binary is built from change that version.

# The version in the [workspace.package] table of the Cargo.toml $1, or nothing when there is none or it is not <digits>.<digits>.<digits>. This is a second copy of `version` in .github/scripts/core-release.sh, because this file has to stay one standalone file (the copy it lives in is rewritten by the update it performs); tests/release.sh runs both over the same Cargo.toml shapes and compares them.
core_version() {
  awk '
    { sub(/\r$/, "") }
    /^[ \t]*\[\[?[A-Za-z0-9_."\047 \t-]*\]\]?[ \t]*(#.*)?$/ {
      header = $0
      sub(/^[ \t]*/, "", header)
      in_workspace_package = (header ~ /^\[[ \t]*workspace[ \t]*\.[ \t]*package[ \t]*\]/)
      next
    }
    in_workspace_package && /^[ \t]*version[ \t]*=/ {
      value = $0
      sub(/^[ \t]*version[ \t]*=[ \t]*/, "", value)
      quote = substr(value, 1, 1)
      if (quote != "\"" && quote != "\047") exit
      value = substr(value, 2)
      end = index(value, quote)
      if (end == 0) exit
      print substr(value, 1, end - 1)
      exit
    }
  ' "$1" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true
}

# The target the prebuilt binary of this machine is built for, or nothing when there is none. Under Rosetta uname says x86_64 on an Apple Silicon Mac, and the arm64 package runs there natively: sysctl.proc_translated is 1 only for a translated process.
core_triple() {
  triple=${TAGENTS_CORE_TARGET:-}
  if [ -z "$triple" ]; then
    os=$(uname -s)
    arch=$(uname -m)
    if [ "$os" = Darwin ] && [ "$arch" = x86_64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = 1 ]; then
      arch=arm64
    fi
    case $os/$arch in
      Linux/x86_64) triple=x86_64-unknown-linux-musl ;;
      Darwin/x86_64) triple=x86_64-apple-darwin ;;
      Darwin/arm64) triple=aarch64-apple-darwin ;;
    esac
  fi
  case $triple in
    x86_64-unknown-linux-musl | x86_64-apple-darwin | aarch64-apple-darwin) printf '%s\n' "$triple" ;;
  esac
}

# The SHA-256 of the file $1. This is a second copy of `sha256_of` in .github/scripts/core-release.sh, because the installer has to stay one standalone file (`curl | sh`); the third is the inline `sha256sum -c` / `shasum -c` step of .github/workflows/release.yml. tests/release.sh runs both functions over one file and compares what they print.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# One file of the release into $2, over the one protocol its URL names: https:// is held to HTTPS, TLS 1.2 or newer, with a retry of a transient failure, and file:// to files. fetch_native lets no other scheme through. Every wait is bounded, because a daily run must not hang on a night without a network.
download() {
  case $1 in
    file://*) curl -fsSL --proto '=file' --connect-timeout 15 --max-time 120 -o "$2" "$1" ;;
    *) curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 --retry 2 -o "$2" "$1" ;;
  esac
}

# The binary and the marker that vouches for it. Only called where the marker exists or nothing does, so what it removes is ours.
drop_native() {
  rm -rf "$NATIVE_BIN" "$NATIVE_BIN.release"
}

# Checks the download in $1 and puts it in place; 1 after a warning, with nothing installed, when any check fails. The order is the order of trust: the hash of the archive, then the archive's members, then what the binary says it is, and only then the marker (first) and the binary (second, renamed into place), so an interruption between the two leaves a marker that does not match, which the next run removes, and never a binary that looks hand-built.
check_and_place() {  # <dir> <archive> <version> <triple>
  dir=$1; archive=$2; version=$3; triple=$4
  expected=''
  read -r expected _ < "$dir/$archive.sha256" || true
  case $expected in
    '' | *[!0-9a-f]*) warn "$archive.sha256 does not start with a SHA-256, so the prebuilt tagents-core was not installed"; return 1 ;;
  esac
  [ "${#expected}" -eq 64 ] || { warn "$archive.sha256 does not start with a SHA-256, so the prebuilt tagents-core was not installed"; return 1; }
  actual=$(sha256_of "$dir/$archive")
  if [ "$actual" != "$expected" ]; then
    warn "the SHA-256 of $archive is $actual but $archive.sha256 says $expected, so the prebuilt tagents-core was not installed"
    return 1
  fi
  members=$(tar -tzf "$dir/$archive" 2>/dev/null | sort) || true
  if [ "$members" != "LICENSE
tagents-core" ]; then
    warn "$archive does not hold exactly tagents-core and LICENSE, so the prebuilt tagents-core was not installed"
    return 1
  fi
  unpacked=$dir/unpacked/tagents-core
  mkdir "$dir/unpacked" && tar -xzf "$dir/$archive" -C "$dir/unpacked" tagents-core 2>/dev/null || true
  if [ ! -f "$unpacked" ] || [ -L "$unpacked" ] || ! chmod 755 "$unpacked"; then
    warn "$archive does not unpack to a tagents-core file, so the prebuilt tagents-core was not installed"
    return 1
  fi
  said=$("$unpacked" --version </dev/null 2>/dev/null) || said=
  if [ "$said" != "tagents-core $version" ]; then
    warn "the tagents-core in $archive says '$said' for --version, not 'tagents-core $version', so it was not installed"
    return 1
  fi
  sha=$(sha256_of "$unpacked")
  tmp=$NATIVE_BIN.tmp.$$
  if ! { mkdir -p "$(dirname "$NATIVE_BIN")" \
    && printf '%s %s %s\n' "$version" "$triple" "$sha" > "$NATIVE_BIN.release.tmp.$$" && mv -f "$NATIVE_BIN.release.tmp.$$" "$NATIVE_BIN.release" \
    && cp "$unpacked" "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$NATIVE_BIN"; }; then
    rm -f "$NATIVE_BIN.release.tmp.$$" "$tmp"
    drop_native
    warn "could not put the prebuilt tagents-core into $(dirname "$NATIVE_BIN")"
    return 1
  fi
  say "installed the prebuilt tagents-core $version ($triple)"
}

# Puts the prebuilt Rust tagents-core of the checkout's version at target/release/tagents-core, or leaves the node CLI in use. It never fails the run for a reason that is the machine's or the network's (no release yet, no network, an unsupported machine): the node CLI works, and a daily run must not fail on a night without a connection. A download that fails its checks is different, and sets NATIVE_FAILED.
fetch_native() {
  NATIVE_BIN=$TAGENTS_HOME/target/release/tagents-core
  marker=$NATIVE_BIN.release
  if [ "${TAGENTS_NO_NATIVE:-}" = 1 ]; then
    if [ -f "$marker" ]; then
      drop_native
      say "removed the prebuilt tagents-core: TAGENTS_NO_NATIVE=1"
    fi
    return 0
  fi
  [ -f "$TAGENTS_HOME/Cargo.toml" ] || return 0
  # A binary with no marker was built by hand: it is not ours to replace or delete, and a download next to it would only be shadowed by it.
  if [ ! -f "$marker" ] && { [ -e "$NATIVE_BIN" ] || [ -L "$NATIVE_BIN" ]; }; then return 0; fi

  version=$(core_version "$TAGENTS_HOME/Cargo.toml")
  triple=$(core_triple)
  if [ -z "$version" ]; then
    drop_native; say "no workspace version in $TAGENTS_HOME/Cargo.toml, using the node CLI"; return 0
  fi
  if [ -z "$triple" ]; then
    drop_native; say "no prebuilt tagents-core for ${TAGENTS_CORE_TARGET:-$(uname -s) $(uname -m)}, using the node CLI"; return 0
  fi
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    drop_native; say "neither sha256sum nor shasum is here to check a prebuilt tagents-core with, using the node CLI"; return 0
  fi

  # Fast path: the binary of this version and this machine, unchanged since it was installed. Nothing else happens and the network is not touched.
  if [ -f "$NATIVE_BIN" ] && [ -x "$NATIVE_BIN" ] && [ -f "$marker" ]; then
    read -r marked_version marked_triple marked_sha marked_rest < "$marker" || true
    if [ "$marked_version" = "$version" ] && [ "$marked_triple" = "$triple" ] && [ -z "$marked_rest" ] && [ "$marked_sha" = "$(sha256_of "$NATIVE_BIN")" ]; then
      return 0
    fi
  fi
  # Any other state of a marked binary goes before anything is downloaded, so a download that fails leaves the node CLI in use and never a binary of another version.
  drop_native

  if ! command -v curl >/dev/null 2>&1; then
    say "curl is not here to fetch the prebuilt tagents-core with, using the node CLI"; return 0
  fi
  base=${TAGENTS_CORE_BASE_URL:-https://github.com/SkuratovichA/tagents/releases/download/v$version}
  base=${base%/}
  case $base in
    https://* | file://*) ;;
    *) warn "TAGENTS_CORE_BASE_URL has to start with https:// or file://, so the prebuilt tagents-core was not fetched"; NATIVE_FAILED=1; return 0 ;;
  esac
  if [ -n "${TAGENTS_CORE_BASE_URL:-}" ]; then say "fetching the prebuilt tagents-core from $base"; fi
  archive=tagents-core-$version-$triple.tar.gz
  # In the tree and not in /tmp: the binary is run once to read its version before it is placed, and a /tmp mounted noexec would fail that on every daily run.
  if ! mkdir -p "$TAGENTS_HOME/target" || ! FETCH_DIR=$(mktemp -d "$TAGENTS_HOME/target/tagents-core.XXXXXX"); then
    FETCH_DIR=''; warn "cannot make a temporary directory in $TAGENTS_HOME/target, so the prebuilt tagents-core was not fetched"; NATIVE_FAILED=1; return 0
  fi
  for file in "$archive.sha256" "$archive"; do
    if ! download "$base/$file" "$FETCH_DIR/$file"; then
      say "no prebuilt tagents-core $version for $triple ($base/$file), using the node CLI"
      rm -rf "$FETCH_DIR"; FETCH_DIR=''
      return 0
    fi
  done
  check_and_place "$FETCH_DIR" "$archive" "$version" "$triple" || NATIVE_FAILED=1
  rm -rf "$FETCH_DIR"; FETCH_DIR=''
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
    native=
    # tagents-core has a Rust front door that serves the verbs ported so far and hands every other word to the node CLI. It is named here when fetch_native or a `cargo build --release` has put an executable binary in the tree; this function builds and fetches nothing.
    if [ "${pair%%:*}" = tagents-core ]; then
      rust_bin=$TAGENTS_HOME/target/release/tagents-core
      if [ -f "$rust_bin" ] && [ -x "$rust_bin" ]; then native=$rust_bin; fi
    fi
    if [ -f "$cli" ]; then
      write_wrapper "$TAGENTS_BIN/${pair%%:*}" "$cli" "$node_bin" "$native"
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
  trap 'rm -rf "$lock" "$BUILD_LOG" ${FETCH_DIR:+"$FETCH_DIR"}' EXIT
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
  QUIET=0; CHECK=0; LAUNCHD=0; SKIPPED=0; NATIVE_FAILED=0; FETCH_DIR=''; HOOK_DIRS=''
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

  fetch_native

  mkdir -p "$TAGENTS_BIN"
  install_commands
  install_hooks
  if [ "$LAUNCHD" = 1 ]; then install_launchd; fi

  if [ "$SKIPPED" -gt 0 ]; then
    die "$SKIPPED file(s) were left alone, see above"
  fi
  if [ "$NATIVE_FAILED" = 1 ]; then
    die "the prebuilt tagents-core was not installed, see above, so the node CLI is in use"
  fi
  say "installed $(short "$(git -C "$TAGENTS_HOME" rev-parse HEAD)") from $TAGENTS_REF into $TAGENTS_HOME"
}

main "$@"; exit $?
