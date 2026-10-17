#!/bin/sh
# Build the tagents notification helper app: build.sh <app path>.
# Prints the app path on stdout and progress on stderr. Rebuilds only when the sources changed.
#
# build.sh --check <app path> builds nothing and writes nothing: it prints
# `up to date`, `stale` or `missing` on stdout and exits 0 for up to date, 1 otherwise.
set -eu

check=0
if [ "${1:-}" = "--check" ]; then
  check=1
  shift
fi
[ $# -eq 1 ] || { echo "usage: build.sh [--check] <app path>" >&2; exit 2; }
app=${1%/}
here=$(cd "$(dirname "$0")" && pwd)
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

hash=$(cat "$here/TagentsNotify.swift" "$here/Info.plist" "$here/build.sh" | shasum -a 256 | cut -d ' ' -f 1)

if [ -x "$app/Contents/MacOS/tagents-notify" ] && [ "$(cat "$app/Contents/Resources/source.sha256" 2>/dev/null)" = "$hash" ]; then
  state="up to date"
elif [ -e "$app" ]; then
  state="stale"
else
  state="missing"
fi

if [ "$check" = 1 ]; then
  echo "$state"
  [ "$state" = "up to date" ]
  exit $?
fi

if [ "$state" = "up to date" ]; then
  echo "up to date: $app" >&2
  printf '%s\n' "$app"
  exit 0
fi

# Build next to the real path and move into place, so a half-built app never sits there.
mkdir -p "$(dirname "$app")"
tmp=$(mktemp -d "$app.build.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM

echo "building $app" >&2
mkdir -p "$tmp/Contents/MacOS" "$tmp/Contents/Resources"
swiftc -O -target "$(uname -m)-apple-macosx13.0" -framework AppKit -framework UserNotifications \
  -o "$tmp/Contents/MacOS/tagents-notify" "$here/TagentsNotify.swift" >&2
cp "$here/Info.plist" "$tmp/Contents/Info.plist"
printf '%s\n' "$hash" > "$tmp/Contents/Resources/source.sha256"
codesign --force --sign - "$tmp" >&2

rm -rf "$app"
mv "$tmp" "$app"
"$lsregister" -f "$app" >&2

printf '%s\n' "$app"
