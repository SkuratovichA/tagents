#!/usr/bin/env bash
#
# tests/parity-oracle.sh — the node CLI the parity suites compare the Rust binary with, built once from a tag.
#
# The node implementations of the verbs the binary serves are deleted from the tree (OpenSpec change `rust-retire-node`), and the parity suites keep comparing with them, so node's side is the tree of one tag: `git archive` unpacks it under target/parity-oracle/<tag>, `pnpm install --frozen-lockfile` and `pnpm build` run there once, and the path is printed on stdout (everything else goes to stderr). A built oracle is reused: its `.built` file is written last. The tag is v0.6.7, the last release whose packages hold the verbs the binary serves; v0.6.8 changed nothing under packages/. PARITY_ORACLE_TAG names another one.
#
# A tag the clone lacks is fetched from origin, so CI, which checks out one commit, needs no step of its own for it. The install runs below a ceiling for git, so the `prepare` script of the unpacked tree does not find this repository and set its hooks path.
#   bash tests/parity-oracle.sh        # prints /…/target/parity-oracle/v0.6.7
#
# bash 3.2.

set -eo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd -P)
TAG=${PARITY_ORACLE_TAG:-v0.6.7}
ROOT=$REPO/target/parity-oracle
OUT=$ROOT/$TAG

if [ -f "$OUT/.built" ]; then printf '%s\n' "$OUT"; exit 0; fi

if ! git -C "$REPO" rev-parse -q --verify "refs/tags/$TAG^{commit}" > /dev/null; then
  git -C "$REPO" fetch --quiet --depth=1 origin "refs/tags/$TAG:refs/tags/$TAG" >&2 \
    || { echo "parity-oracle: tag $TAG is neither here nor on origin" >&2; exit 2; }
fi

mkdir -p "$ROOT"
WORK=$(mktemp -d "$ROOT/.tmp.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
git -C "$REPO" archive "$TAG" | tar -x -C "$WORK"
(
  cd "$WORK"
  export GIT_CEILING_DIRECTORIES=$ROOT
  pnpm install --frozen-lockfile >&2
  pnpm build >&2
) || { echo "parity-oracle: the install or the build of $TAG failed" >&2; exit 2; }
touch "$WORK/.built"

# Two runs at once leave one oracle: the loser's tree is dropped by the trap.
rm -rf "$OUT.old"
if [ -d "$OUT" ]; then mv "$OUT" "$OUT.old"; fi
mv "$WORK" "$OUT" 2> /dev/null || { [ -f "$OUT/.built" ] || exit 2; }
rm -rf "$OUT.old"
printf '%s\n' "$OUT"
