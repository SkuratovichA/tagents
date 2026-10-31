#!/bin/bash
# docs/demo/notify.sh — regenerate docs/images/notify.png: three real macOS notices of tagents, stacked.
#
# Each notice is posted with `tagents notify test --kind <kind>` from a directory named storefront (the notice is titled after it), and the window that draws it is captured alone (screencapture -l), so nothing else on screen ends up in the picture. The window covers the whole screen and is transparent around the banner: the banner is cut out by its alpha, its shadow dropped, and the three are stacked.
#
# Needs: macOS, the notify plugin installed and allowed (`tagents notify status` says `permission: authorized`), Screen Recording allowed for the terminal (System Settings → Privacy & Security → Screen & System Audio Recording), and ImageMagick (`brew install imagemagick`). Focus and Do Not Disturb must be off, or the banners never show. The icon is whatever `icon` in notify.toml names on this machine.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
out="$here/../images/notify.png"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

command -v magick >/dev/null 2>&1 || { echo "notify.sh: ImageMagick is not installed (brew install imagemagick)" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || { echo "notify.sh: the banners are macOS notices" >&2; exit 1; }

# The window that draws banners belongs to "Notification Center" (or "Centre", by the system locale).
banner_window() {
  osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0))).filter(w => /^Notification Cent/.test(w.kCGWindowOwnerName || "")).map(w => w.kCGWindowNumber)[0]'
}

mkdir -p "$work/storefront"
parts=()
for kind in question permission turn_done; do
  ( cd "$work/storefront" && env -u TMUX -u TMUX_PANE tagents notify test --kind "$kind" >/dev/null )
  id=""
  for _ in $(seq 1 30); do id=$(banner_window 2>/dev/null || true); [ -n "$id" ] && break; sleep 0.1; done
  [ -n "$id" ] || { echo "notify.sh: no banner appeared for $kind (Focus on? notifications not allowed?)" >&2; exit 1; }
  sleep 0.8   # the slide-in animation
  screencapture -x -o -l"$id" "$work/$kind.png"
  # The banner is where the window is at least half opaque; everything fainter around it is shadow.
  read -r w h x y < <(magick "$work/$kind.png" -alpha extract -threshold 50% -format '%@\n' info: | tr 'x+' '  ')
  magick "$work/$kind.png" -crop "$((w + 2))x$((h + 2))+$((x - 1))+$((y - 1))" +repage -channel A -level 40%,100% +channel "$work/c-$kind.png"
  parts+=("$work/c-$kind.png")
  sleep 6   # let this banner leave before the next one replaces it
done

magick "${parts[0]}" \( -size 1x24 xc:none \) "${parts[1]}" \( -size 1x24 xc:none \) "${parts[2]}" -background none -gravity center -append -strip "$out"
echo "notify.sh: wrote docs/images/notify.png ($(magick identify -format '%wx%h' "$out"))"
