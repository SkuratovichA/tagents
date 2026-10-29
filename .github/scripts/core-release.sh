#!/bin/sh
#
# core-release.sh — the CI side of releasing the Rust `tagents-core`: what version the workspace holds, what a release archive is, which pull requests must bump the version, and whether a tag may be released.
#
#   core-release.sh version [Cargo.toml|-]               print the workspace version, from the file (default: Cargo.toml) or from stdin
#   core-release.sh package <version> <triple> <binary> <license-file> <outdir>
#                                                       write tagents-core-<version>-<triple>.tar.gz and its .sha256 into <outdir>, print both names
#   core-release.sh gate <base-ref>                      exit 1 when the pull request changes an input of the binary and does not raise the workspace version above the one at the merge base
#   core-release.sh verify <tag> <main-ref>              exit 1 unless <tag> is v<workspace version> and HEAD is on <main-ref>
#
# Every command works on the current directory, the root of a checkout. The version is the identity of the binary: `Cargo.toml` is the only place that holds it, a release is the tag `v<version>`, and install.sh fetches the archive of the version its checkout holds (docs/architecture/rust-core.md). install.sh keeps a second copy of the version reader (`core_version`) because it must stay one standalone file; tests/release.sh runs both over the same Cargo.toml shapes.
#
# POSIX sh: it runs on the macOS and Ubuntu runners and on a contributor's machine.

set -eu

# What the binary is built from. A pull request that changes one of these must also change the workspace version (the gate). Tests under crates/*/tests/, docs and workflows are not inputs. The CLI spec data file is compiled in by include_str! (crates/tagents-spec/src/lib.rs), so spec/cli/* counts, the schema file beside it included. `*` in a case pattern also matches `/`, so crates/*/src/* covers nested modules.
is_input() {
  case $1 in
    Cargo.toml | Cargo.lock | rust-toolchain.toml | crates/*/Cargo.toml | crates/*/build.rs | crates/*/src/* | spec/cli/*) return 0 ;;
    *) return 1 ;;
  esac
}

fail() {
  printf 'core-release: %s\n' "$*" >&2
  exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

sha256_of() {
  if have sha256sum; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# The value of `version` in the [workspace.package] table of the Cargo.toml on stdin, quotes taken off; nothing when there is none. A `version` of [package], of a dependency table or of an inline table is in another section, and a comment is not a key.
workspace_version() {
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
  '
}

# Prints the version of the Cargo.toml named by $1, or of the one on stdin for "-".
version() {
  src=${1:-Cargo.toml}
  if [ "$src" = - ]; then
    src='the Cargo.toml on stdin'
    found=$(workspace_version) || found=
  else
    [ -f "$src" ] || fail "$src does not exist"
    found=$(workspace_version < "$src") || found=
  fi
  [ -n "$found" ] || fail "$src has no version = \"…\" in its [workspace.package] table"
  printf '%s\n' "$found" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "the workspace version of $src is '$found', not <digits>.<digits>.<digits>"
  printf '%s\n' "$found"
}

package() {
  [ $# -eq 5 ] || fail "usage: package <version> <triple> <binary> <license-file> <outdir>"
  pkg_version=$1; pkg_triple=$2; pkg_binary=$3; pkg_license=$4; pkg_out=$5
  printf '%s\n' "$pkg_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "the version '$pkg_version' is not <digits>.<digits>.<digits>"
  printf '%s\n' "$pkg_triple" | grep -Eq '^[A-Za-z0-9_]+(-[A-Za-z0-9_]+)+$' || fail "the target '$pkg_triple' is not a target triple"
  [ -f "$pkg_binary" ] && [ -x "$pkg_binary" ] || fail "$pkg_binary is not an executable file"
  [ -f "$pkg_license" ] || fail "$pkg_license is not a file"
  name=tagents-core-$pkg_version-$pkg_triple.tar.gz
  mkdir -p "$pkg_out"
  stage=$(mktemp -d "${TMPDIR:-/tmp}/core-release.XXXXXX")
  # shellcheck disable=SC2064 # the directory is known now, which is the point
  trap "rm -rf '$stage'" EXIT
  cp "$pkg_binary" "$stage/tagents-core"
  cp "$pkg_license" "$stage/LICENSE"
  chmod 755 "$stage/tagents-core"
  chmod 644 "$stage/LICENSE"
  # COPYFILE_DISABLE keeps macOS tar from adding ._tagents-core for the extended attributes of the copy: an archive holds exactly the two members install.sh accepts.
  COPYFILE_DISABLE=1 tar -czf "$pkg_out/$name" -C "$stage" tagents-core LICENSE
  printf '%s  %s\n' "$(sha256_of "$pkg_out/$name")" "$name" > "$pkg_out/$name.sha256"
  printf '%s\n%s\n' "$name" "$name.sha256"
}

# 0 when the version $1 is strictly greater than $2, both <digits>.<digits>.<digits>, comparing the three numbers one by one (sort -V is not on every macOS).
newer() {
  old_ifs=$IFS
  IFS=.
  # shellcheck disable=SC2086 # split on the dots on purpose
  set -- $1 $2
  IFS=$old_ifs
  if [ "$1" -ne "$4" ]; then
    if [ "$1" -gt "$4" ]; then return 0; fi
    return 1
  fi
  if [ "$2" -ne "$5" ]; then
    if [ "$2" -gt "$5" ]; then return 0; fi
    return 1
  fi
  if [ "$3" -gt "$6" ]; then return 0; fi
  return 1
}

gate() {
  [ $# -eq 1 ] || fail "usage: gate <base-ref>"
  base=$1
  # --no-renames: a file moved out of an input path is a change to an input, and a rename would show only its new name.
  changed=$(git -c core.quotePath=false diff --no-renames --name-only "$base"...HEAD) || fail "cannot compare HEAD with $base (is the history deep enough? a shallow checkout has no merge base)"
  inputs=
  for file in $changed; do
    if is_input "$file"; then inputs="$inputs  $file
"; fi
  done
  if [ -z "$inputs" ]; then
    echo "core-release: no input of the tagents-core binary changed since $base"
    return 0
  fi
  # The version to beat is the one where the branch left the base, not the base's tip: a bump that landed on the base since then is not this branch's.
  fork=$(git merge-base "$base" HEAD) || fail "$base and HEAD have no merge base"
  before=$(git show "$fork:Cargo.toml" | version -) || fail "$fork, where HEAD left $base, has no workspace version to compare with"
  after=$(version Cargo.toml)
  if ! newer "$after" "$before"; then
    if [ "$before" = "$after" ]; then
      what="it is still $after at the merge base with $base and here"
    else
      what="it went down from $before at the merge base with $base to $after here"
    fi
    {
      printf 'core-release: this change touches what the tagents-core binary is built from, so the workspace version in Cargo.toml has to go up with it (%s). Changed inputs:\n' "$what"
      printf '%s' "$inputs"
      echo 'A binary of version V must come from the source of version V: raise [workspace.package] version above the merge base'"'"'s, and run cargo update --workspace so Cargo.lock follows.'
    } >&2
    return 1
  fi
  echo "core-release: inputs of the binary changed and the workspace version moved from $before to $after"
}

verify() {
  [ $# -eq 2 ] || fail "usage: verify <tag> <main-ref>"
  tag=$1; main=$2
  want=v$(version Cargo.toml)
  [ "$tag" = "$want" ] || fail "the tag is $tag but the workspace version of this commit says $want"
  git rev-parse --verify --quiet "$main^{commit}" >/dev/null || fail "$main does not exist here (the checkout needs the full history)"
  git merge-base --is-ancestor HEAD "$main" || fail "this commit is not on $main: only a commit of main is released"
  echo "core-release: $tag is the version of this commit, and the commit is on $main"
}

main() {
  [ $# -ge 1 ] || fail "usage: core-release.sh version|package|gate|verify (see the top of the file)"
  cmd=$1
  shift
  case $cmd in
    version) version "$@" ;;
    package) package "$@" ;;
    gate) gate "$@" ;;
    verify) verify "$@" ;;
    *) fail "unknown command $cmd (version, package, gate, verify)" ;;
  esac
}

main "$@"
