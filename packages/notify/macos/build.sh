#!/bin/sh
# Build the tagents notification helper app: build.sh <app path>.
# Prints the app path on stdout and progress on stderr. Rebuilds only when the sources changed.
#
# build.sh --check <app path> builds nothing and writes nothing: it prints
# `up to date`, `stale` or `missing` on stdout and exits 0 for up to date, 1 otherwise.
#
# --icon <png> (in both modes) makes the app's icon from that picture: the helper's `icon` verb draws it onto
# the rounded-square plate macOS expects, and sips and iconutil turn the result into Contents/Resources/AppIcon.icns.
# The picture's digest is part of the one `--check` compares, so a changed, added or removed icon is stale.
# An icon also gives the app its own bundle id, <base>.i<first 8 hex of the digest>, because macOS keeps an app's icon
# from its first notification-permission request: a changed icon needs a fresh registration to show.
# TA_NOTIFY_NO_LSREGISTER=1 skips registering the built app with LaunchServices: a build in a scratch directory
# (the tests) carries the real app's bundle id and must not become the app a notification click opens.
set -eu

check=0
icon=
while [ $# -gt 0 ]; do
  case $1 in
    --check) check=1; shift ;;
    --icon)
      [ $# -ge 2 ] || { echo "--icon needs a PNG path" >&2; exit 2; }
      icon=$2
      shift 2
      ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] || { echo "usage: build.sh [--check] [--icon <png>] <app path>" >&2; exit 2; }
[ -z "$icon" ] || { [ -f "$icon" ] && [ -r "$icon" ]; } || { echo "cannot read the icon: $icon" >&2; exit 2; }
app=${1%/}
here=$(cd "$(dirname "$0")" && pwd)
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

icon_digest=
[ -z "$icon" ] || icon_digest=$(shasum -a 256 < "$icon" | cut -d ' ' -f 1)
hash=$({
  cat "$here/TagentsNotify.swift" "$here/Info.plist" "$here/build.sh"
  if [ -n "$icon" ]; then printf 'icon %s\n' "$icon_digest"; else printf 'no icon\n'; fi
} | shasum -a 256 | cut -d ' ' -f 1)

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
# The trap comes before the first mktemp, so whichever directory exists when the script stops is removed.
tmp=
work=
cleanup() {
  [ -z "$tmp" ] || rm -rf "$tmp"
  [ -z "$work" ] || rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
mkdir -p "$(dirname "$app")"
tmp=$(mktemp -d "$app.build.XXXXXX")

echo "building $app" >&2
mkdir -p "$tmp/Contents/MacOS" "$tmp/Contents/Resources"
swiftc -O -target "$(uname -m)-apple-macosx13.0" -framework AppKit -framework UserNotifications \
  -o "$tmp/Contents/MacOS/tagents-notify" "$here/TagentsNotify.swift" >&2
cp "$here/Info.plist" "$tmp/Contents/Info.plist"
if [ -n "$icon" ]; then
  work=$(mktemp -d "${TMPDIR:-/tmp}/tagents-notify-icon.XXXXXX")
  # The iconset's ten sizes are cut from one 1024 px drawing; sips -z takes height then width.
  "$tmp/Contents/MacOS/tagents-notify" icon "$icon" "$work/plate.png" >&2
  mkdir "$work/AppIcon.iconset"
  for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$work/plate.png" --out "$work/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$double" "$double" "$work/plate.png" --out "$work/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns -o "$tmp/Contents/Resources/AppIcon.icns" "$work/AppIcon.iconset" >&2
  plutil -replace CFBundleIconFile -string AppIcon "$tmp/Contents/Info.plist"
  base_id=$(plutil -extract CFBundleIdentifier raw "$here/Info.plist")
  plutil -replace CFBundleIdentifier -string "$base_id.i$(printf '%s' "$icon_digest" | cut -c 1-8)" "$tmp/Contents/Info.plist"
fi
printf '%s\n' "$hash" > "$tmp/Contents/Resources/source.sha256"
codesign --force --sign - "$tmp" >&2

rm -rf "$app"
mv "$tmp" "$app"
[ "${TA_NOTIFY_NO_LSREGISTER:-}" = 1 ] || "$lsregister" -f "$app" >&2

printf '%s\n' "$app"
