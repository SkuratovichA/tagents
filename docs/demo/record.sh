#!/bin/bash
# docs/demo/record.sh — regenerate every picture in docs/images/ that comes from the demo machine.
#
#   docs/demo/record.sh            all recordings
#   docs/demo/record.sh hero timeline   only these (the names of the .tape files)
#
# For each tape it builds the made-up machine (world.sh up), records it with VHS, and tears it down again. Nothing of the real machine is read: see env.sh for what is moved.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
cache="$here/.cache"
logs="$cache/logs"
cd "$repo"
mkdir -p "$logs"

for tool in vhs ttyd ffmpeg tmux jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "record.sh: $tool is not installed (brew install vhs jq tmux; vhs brings ttyd and ffmpeg)" >&2; exit 1; }
done

# The list's footer needs fzf --footer (0.63 and later). An older fzf is not touched: a newer one is unpacked from the Homebrew bottle into the cache and put first on the demo's PATH only.
fzf_help=$(fzf --help 2>&1 || true)
if ! grep -q -- '--footer' <<<"$fzf_help"; then
  if [ ! -x "$cache/fzf/bin/fzf" ]; then
    echo "record.sh: fzf $(fzf --version | cut -d' ' -f1) has no --footer, unpacking a newer bottle into $cache/fzf"
    brew fetch --force-bottle fzf >"$logs/fzf.fetch.log" 2>&1 || { tail -5 "$logs/fzf.fetch.log" >&2; exit 1; }
    bottle=$(brew --cache --force-bottle fzf 2>/dev/null | tail -1)
    [ -n "$bottle" ] && [ -r "$bottle" ] || { echo "record.sh: could not find the fzf bottle brew fetched" >&2; exit 1; }
    unpack=$(mktemp -d)
    tar -xzf "$bottle" -C "$unpack"
    mkdir -p "$cache/fzf/bin"
    cp "$(ls "$unpack"/fzf/*/bin/fzf | tail -1)" "$cache/fzf/bin/fzf"
    rm -rf "$unpack"
  fi
  export DEMO_FZF_DIR="$cache/fzf/bin"
fi

tapes=("$@")
if [ ${#tapes[@]} -eq 0 ]; then tapes=(hero resurrect new-chat closed timeline statusbar dashboard); fi

# Every VHS and tmux process runs in the demo environment: HOME, the tmux socket directory, the state directory and the config all live under $DEMO_ROOT.
run_in_demo() { bash -c '. "$1"; shift; exec "$@"' _ "$here/env.sh" "$@"; }

cleanup() {
  run_in_demo "$here/world.sh" down >/dev/null 2>&1 || true
  rm -f "$here"/.*.gif "$here"/.*.png
}
trap cleanup EXIT

for name in "${tapes[@]}"; do
  [ -r "$here/$name.tape" ] || { echo "record.sh: no docs/demo/$name.tape" >&2; exit 1; }
  echo "== $name"
  run_in_demo "$here/world.sh" up >"$logs/$name.world.log" 2>&1 || { tail -20 "$logs/$name.world.log" >&2; exit 1; }
  run_in_demo vhs "docs/demo/$name.tape" >"$logs/$name.vhs.log" 2>&1 || { tail -20 "$logs/$name.vhs.log" >&2; exit 1; }
  run_in_demo "$here/world.sh" down >/dev/null 2>&1 || true
done

# A GIF over 4 MB would slow the README down: squeeze it, never touch the others.
if command -v gifsicle >/dev/null 2>&1; then
  for f in docs/images/hero.gif docs/images/resurrect.gif docs/images/new-chat.gif; do
    [ -f "$f" ] && [ "$(wc -c <"$f")" -gt 4000000 ] && gifsicle -O3 --lossy=80 -b "$f"
  done
fi
echo "done: $(ls docs/images | tr '\n' ' ')"
