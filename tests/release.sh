#!/usr/bin/env bash
#
# tests/release.sh — the release path of the Rust tagents-core, as far as it can be proved without GitHub: the workspace version reader, the release archive and its checksum, the gate that makes a change to the binary change the version, the rules a tag must meet, and the second copy of the version reader that install.sh keeps.
#
# Everything runs in a mktemp dir: throwaway git repositories for the gate and the tag rules, a stub in place of the binary, and a minimal origin for install.sh, which is run only far enough to read the version out of a Cargo.toml (see section 5). No network (a curl shim refuses anything that is not a file:// URL), no tmux, no node.
#
# bash 3.2, runnable from any cwd, non-zero exit when any check fails.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
RELEASE="$ROOT/.github/scripts/core-release.sh"
INSTALL="$ROOT/install.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tagents-release.XXXXXX") || exit 1
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

# core-release.sh in the directory given, stdout and stderr together, then the exit code on the last line.
rel() {  # <dir> <args…>
  local dir=$1; shift
  ( cd "$dir" && sh "$RELEASE" "$@" 2>&1; printf '\nexit=%s' "$?" )
}
code_of() { printf '%s' "${1##*exit=}"; }
body_of() { local x=${1%exit=*}; printf '%s' "${x%$'\n'}"; }

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1; else shasum -a 256 "$1" | cut -d ' ' -f 1; fi
}

# ---------------------------------------------------------------------------
t "1. the workspace version, read out of every shape of Cargo.toml"
# ---------------------------------------------------------------------------
# name|expected|Cargo.toml. "error" means the reader refuses with exit 1. The same table is run through install.sh in section 5.
SHAPES=$TMP/shapes
mkdir -p "$SHAPES"
shape() {  # <name> <expected> — the Cargo.toml comes on stdin
  cat > "$SHAPES/$1.toml"
  printf '%s\n' "$2" > "$SHAPES/$1.expected"
}
shape plain 0.1.0 <<'EOF'
[workspace]
resolver = "3"
members = ["crates/*"]

[workspace.package]
version = "0.1.0"
edition = "2024"
EOF
shape package-section-first 0.2.0 <<'EOF'
[package]
name = "x"
version = "9.9.9"

[workspace.package]
version = "0.2.0"
EOF
shape package-section-after 0.3.0 <<'EOF'
[workspace.package]
version="0.3.0"

[package]
version = "9.9.9"
EOF
shape dependency-inline 0.4.0 <<'EOF'
[workspace.dependencies]
serde = { version = "1", features = ["derive"] }
serde_json = { path = "x", version = "1.0.1" }

[workspace.package]
version = "0.4.0"
EOF
shape dependency-table 0.5.0 <<'EOF'
[dependencies.serde]
version = "1"

[workspace.dependencies.serde_json]
version = "1.0.2"

[workspace.package]
edition = "2024"
version = "0.5.0"
EOF
shape dependency-table-after-a-package-without-version error <<'EOF'
[workspace.package]
edition = "2024"

[dependencies.serde]
version = "1.2.3"

[package]
version = "4.5.6"
EOF
shape comments 0.6.0 <<'EOF'
# version = "9.9.9"
[workspace]
members = []
# [workspace.package] is below
[workspace.package]
# the version = "8.8.8" lives right here
version = "0.6.0" # version bump
EOF
shape single-quotes 0.7.0 <<'EOF'
[workspace.package]
version = '0.7.0'
EOF
shape spacing-and-header-comment 0.8.0 <<'EOF'
  [ workspace.package ]   # the shared fields
    version   =   "0.8.0"
EOF
shape crlf 0.9.0 <<'EOF'
[workspace.package]
version = "0.9.0"
EOF
sed -i.bak 's/$/\r/' "$SHAPES/crlf.toml" && rm "$SHAPES/crlf.toml.bak"
shape multi-line-array-before-the-version 1.0.0 <<'EOF'
[workspace.package]
authors = [
  "a b",
  "c d",
]
version = "1.0.0"
EOF
shape big-numbers 10.20.300 <<'EOF'
[workspace.package]
version = "10.20.300"
EOF
shape no-workspace-package-table error <<'EOF'
[package]
name = "x"
version = "1.2.3"
EOF
shape table-without-a-version error <<'EOF'
[workspace.package]
edition = "2024"
EOF
shape version-inherited-is-not-a-value error <<'EOF'
[workspace.package]
version.workspace = true
EOF
shape two-numbers error <<'EOF'
[workspace.package]
version = "1.0"
EOF
shape four-numbers error <<'EOF'
[workspace.package]
version = "1.2.3.4"
EOF
shape pre-release error <<'EOF'
[workspace.package]
version = "1.0.0-rc1"
EOF
shape v-prefix error <<'EOF'
[workspace.package]
version = "v1.0.0"
EOF
shape empty-string error <<'EOF'
[workspace.package]
version = ""
EOF
shape not-quoted error <<'EOF'
[workspace.package]
version = 1.2.3
EOF
shape unterminated-quote error <<'EOF'
[workspace.package]
version = "1.2.3
EOF
shape empty-file error </dev/null

for f in "$SHAPES"/*.toml; do
  name=$(basename "$f" .toml)
  want=$(cat "$SHAPES/$name.expected")
  out=$(rel "$TMP" version "$f"); got=$(body_of "$out")
  if [ "$want" = error ]; then
    ok "$name: a file is refused with exit 1" 1 "$(code_of "$out")"
    contains "$name: and the reason is said" "core-release:" "$got"
  else
    ok "$name: $want" "$want" "$got"
    ok "$name: exit 0" 0 "$(code_of "$out")"
  fi
  out=$(cd "$TMP" && sh "$RELEASE" version - < "$f" 2>&1; printf '\nexit=%s' "$?")
  if [ "$want" = error ]; then
    ok "$name: stdin is refused alike" 1 "$(code_of "$out")"
  else
    ok "$name: stdin gives the same" "$want" "$(body_of "$out")"
  fi
done
out=$(rel "$TMP" version "$TMP/does-not-exist.toml")
ok "a file that is not there is exit 1" 1 "$(code_of "$out")"
cp "$SHAPES/plain.toml" "$TMP/Cargo.toml"
ok "with no argument the Cargo.toml of the current directory is read" "0.1.0" "$(body_of "$(rel "$TMP" version)")"
ok "this checkout's workspace version reads" 0 "$(code_of "$(rel "$ROOT" version)")"
rm -f "$TMP/Cargo.toml"

# ---------------------------------------------------------------------------
t "2. the release archive"
# ---------------------------------------------------------------------------
PKG=$TMP/pkg
mkdir -p "$PKG/out"
printf '#!/bin/sh\necho "tagents-core 1.2.3"\n' > "$PKG/tagents-core"; chmod 700 "$PKG/tagents-core"
printf 'MIT License\n\nthe license text\n' > "$PKG/LICENSE"; chmod 600 "$PKG/LICENSE"
# macOS bsdtar adds a ._tagents-core member for a file with an extended attribute unless COPYFILE_DISABLE is set. Whether the staged copy of this file keeps the attribute depends on the cp of the machine, so the tar shim below pins the variable itself.
if command -v xattr >/dev/null 2>&1; then xattr -w com.example.test value "$PKG/tagents-core" 2>/dev/null || true; fi
TRIPLE=aarch64-apple-darwin
NAME=tagents-core-1.2.3-$TRIPLE.tar.gz
out=$(rel "$PKG" package 1.2.3 $TRIPLE "$PKG/tagents-core" "$PKG/LICENSE" "$PKG/out")
ok "package exits 0" 0 "$(code_of "$out")"
ok "it prints the two file names" "$NAME
$NAME.sha256" "$(body_of "$out")"
ok "the outdir holds those two files and nothing else" "$NAME
$NAME.sha256" "$(ls "$PKG/out")"
ok "the archive holds exactly tagents-core and LICENSE" "LICENSE
tagents-core" "$(tar -tzf "$PKG/out/$NAME" | sort)"
modes=$(tar -tvzf "$PKG/out/$NAME" | awk '{ print $1, $NF }' | sort)
ok "tagents-core is mode 755 and LICENSE 644, whatever the sources were" "-rw-r--r-- LICENSE
-rwxr-xr-x tagents-core" "$modes"
mkdir "$PKG/unpacked"; tar -xzf "$PKG/out/$NAME" -C "$PKG/unpacked"
ok "the binary unpacks to what went in" "tagents-core 1.2.3" "$("$PKG/unpacked/tagents-core")"
ok "and so does the license" "$(cat "$PKG/LICENSE")" "$(cat "$PKG/unpacked/LICENSE")"
sumline=$(cat "$PKG/out/$NAME.sha256")
ok "the checksum file is one line, <64 lowercase hex>, two spaces, the archive name" 1 "$(printf '%s\n' "$sumline" | grep -Ec "^[0-9a-f]{64}  $NAME\$")"
ok "and nothing but that line" 1 "$(wc -l < "$PKG/out/$NAME.sha256" | tr -d ' ')"
ok "the hash is the archive's" "$(sha_of "$PKG/out/$NAME")" "${sumline%% *}"
ok "shasum -a 256 -c accepts it from the output directory" 0 "$(cd "$PKG/out" && shasum -a 256 -c "$NAME.sha256" >/dev/null 2>&1; echo $?)"
if command -v sha256sum >/dev/null 2>&1; then
  ok "sha256sum -c accepts it too" 0 "$(cd "$PKG/out" && sha256sum -c "$NAME.sha256" >/dev/null 2>&1; echo $?)"
else
  printf '  skip sha256sum is not on this machine\n'
fi
cp "$PKG/out/$NAME" "$PKG/tampered.tar.gz"; printf 'x' >> "$PKG/out/$NAME"
ok "an archive changed after the checksum was written fails shasum -c" 1 "$(cd "$PKG/out" && shasum -a 256 -c "$NAME.sha256" >/dev/null 2>&1; echo $?)"
if command -v sha256sum >/dev/null 2>&1; then
  ok "and sha256sum -c" 1 "$(cd "$PKG/out" && sha256sum -c "$NAME.sha256" >/dev/null 2>&1; echo $?)"
fi
out=$(rel "$PKG" package 1.2.3 $TRIPLE "$PKG/tagents-core" "$PKG/LICENSE" "$PKG/out2/nested")
ok "an outdir that does not exist is made" 0 "$(code_of "$out")"
# A tar that refuses to run without COPYFILE_DISABLE=1 in its environment: the variable is what keeps ._ members out of the archive on macOS.
REAL_TAR=$(command -v tar)
mkdir -p "$PKG/shim"
printf '#!/bin/sh\n[ "${COPYFILE_DISABLE:-}" = 1 ] || { echo "tar was run without COPYFILE_DISABLE=1" >&2; exit 97; }\nexec "%s" "$@"\n' "$REAL_TAR" > "$PKG/shim/tar"; chmod 755 "$PKG/shim/tar"
out=$(cd "$PKG" && PATH="$PKG/shim:$PATH" sh "$RELEASE" package 1.2.3 $TRIPLE "$PKG/tagents-core" "$PKG/LICENSE" "$PKG/out3" 2>&1; printf '\nexit=%s' "$?")
ok "tar runs with COPYFILE_DISABLE=1, so macOS adds no ._ members" 0 "$(code_of "$out")"
for bad in "1.2|$TRIPLE|$PKG/tagents-core|$PKG/LICENSE|a version that is not three numbers" \
           "1.2.3|not a triple|$PKG/tagents-core|$PKG/LICENSE|a target that is not a triple" \
           "1.2.3|$TRIPLE|$PKG/missing|$PKG/LICENSE|a binary that is not there" \
           "1.2.3|$TRIPLE|$PKG|$PKG/LICENSE|a binary that is a directory" \
           "1.2.3|$TRIPLE|$PKG/LICENSE|$PKG/LICENSE|a binary that is not executable" \
           "1.2.3|$TRIPLE|$PKG/tagents-core|$PKG/missing|a license that is not there"; do
  IFS='|' read -r v tr bin lic what <<< "$bad"
  out=$(rel "$PKG" package "$v" "$tr" "$bin" "$lic" "$PKG/refused")
  ok "package refuses $what" 1 "$(code_of "$out")"
done
ok "and made nothing for them" "no" "$([ -e "$PKG/refused" ] && echo yes || echo no)"
ok "package with too few arguments is refused" 1 "$(code_of "$(rel "$PKG" package 1.2.3)")"

# ---------------------------------------------------------------------------
t "3. the gate: a change to what the binary is built from changes the version"
# ---------------------------------------------------------------------------
REPO=$TMP/repo
git_in() { git -C "$REPO" "$@"; }
mkrepo() {
  rm -rf "$REPO"; mkdir -p "$REPO"
  git_in init -q -b main && git_in config user.email t@example.com && git_in config user.name t
  mkdir -p "$REPO/crates/a/src/nested" "$REPO/crates/a/tests" "$REPO/crates/b/src" "$REPO/spec/cli" "$REPO/docs" "$REPO/.github/workflows" "$REPO/packages/core/src"
  cp "$SHAPES/plain.toml" "$REPO/Cargo.toml"
  printf '# lock\n' > "$REPO/Cargo.lock"
  printf '[toolchain]\nchannel = "1.99.1"\n' > "$REPO/rust-toolchain.toml"
  printf '[package]\nname = "a"\nversion.workspace = true\n' > "$REPO/crates/a/Cargo.toml"
  printf '[package]\nname = "b"\nversion.workspace = true\n' > "$REPO/crates/b/Cargo.toml"
  printf 'fn main() {}\n' > "$REPO/crates/a/build.rs"
  printf 'pub fn a() {}\n' > "$REPO/crates/a/src/lib.rs"
  printf 'pub fn n() {}\n' > "$REPO/crates/a/src/nested/mod.rs"
  printf 'pub fn b() {}\n' > "$REPO/crates/b/src/lib.rs"
  printf '#[test] fn t() {}\n' > "$REPO/crates/a/tests/t.rs"
  printf '{}\n' > "$REPO/spec/cli/tagents-core.json"
  printf '{}\n' > "$REPO/spec/cli/cli-spec.schema.json"
  printf 'docs\n' > "$REPO/docs/x.md"
  printf 'name: w\n' > "$REPO/.github/workflows/w.yml"
  printf 'export {}\n' > "$REPO/packages/core/src/x.ts"
  printf 'readme\n' > "$REPO/README.md"
  git_in add -A && git_in commit -q -m base
  git_in checkout -q -b change
}
bump() { sed -i.bak 's/^version = "0.1.0"/version = "0.1.1"/' "$REPO/Cargo.toml" && rm "$REPO/Cargo.toml.bak"; }
commit_all() { git_in add -A && git_in commit -q -m change; }
gate_after() {  # <description> <expected exit> <function that edits the repo>
  mkrepo
  "$3"
  commit_all
  out=$(rel "$REPO" gate main)
  ok "$1" "$2" "$(code_of "$out")"
}
touch_src() { printf '// changed\n' >> "$REPO/crates/a/src/lib.rs"; }
touch_src_and_bump() { touch_src; bump; }
touch_test() { printf '// changed\n' >> "$REPO/crates/a/tests/t.rs"; }
touch_docs() { printf 'more\n' >> "$REPO/docs/x.md"; printf 'more\n' >> "$REPO/README.md"; }
touch_workflow() { printf '# more\n' >> "$REPO/.github/workflows/w.yml"; }
touch_node_side() { printf '// more\n' >> "$REPO/packages/core/src/x.ts"; }
touch_spec() { printf '{"a":1}\n' > "$REPO/spec/cli/tagents-core.json"; }
touch_spec_schema() { printf '{"a":1}\n' > "$REPO/spec/cli/cli-spec.schema.json"; }
touch_lock() { printf '# changed\n' >> "$REPO/Cargo.lock"; }
touch_toolchain() { sed -i.bak 's/1.99.1/1.99.2/' "$REPO/rust-toolchain.toml" && rm "$REPO/rust-toolchain.toml.bak"; }
touch_build_rs() { printf '// changed\n' >> "$REPO/crates/a/build.rs"; }
touch_crate_manifest() { printf '[dependencies]\n' >> "$REPO/crates/b/Cargo.toml"; }
touch_nested_src() { printf '// changed\n' >> "$REPO/crates/a/src/nested/mod.rs"; }
touch_root_manifest_not_the_version() { printf '\n[profile.release]\nlto = true\n' >> "$REPO/Cargo.toml"; }
delete_input() { git_in rm -q crates/b/src/lib.rs; }
move_input_out() { git_in mv crates/b/src/lib.rs docs/b-lib.rs; }
bump_only() { bump; }

gate_after "a source file changed and the version did not: fails" 1 touch_src
out=$(rel "$REPO" gate main)
contains "it names the changed file" "crates/a/src/lib.rs" "$out"
contains "and says the version is unchanged" "still 0.1.0" "$out"
gate_after "a source file changed and the version moved: passes" 0 touch_src_and_bump
contains "it says the version moved" "0.1.0 to 0.1.1" "$(rel "$REPO" gate main)"
gate_after "only a test changed: passes" 0 touch_test
gate_after "only docs and the readme changed: passes" 0 touch_docs
gate_after "only a workflow changed: passes" 0 touch_workflow
gate_after "only node-side files changed: passes" 0 touch_node_side
gate_after "the version moved with nothing else: passes" 0 bump_only
gate_after "spec/cli/tagents-core.json alone: fails" 1 touch_spec
gate_after "the schema beside it: fails (accepted over-approximation)" 1 touch_spec_schema
gate_after "Cargo.lock alone: fails" 1 touch_lock
gate_after "rust-toolchain.toml alone: fails" 1 touch_toolchain
gate_after "a build.rs alone: fails" 1 touch_build_rs
gate_after "a crate's Cargo.toml alone: fails" 1 touch_crate_manifest
gate_after "a module in a subdirectory of src: fails" 1 touch_nested_src
gate_after "the root Cargo.toml changed without its version: fails" 1 touch_root_manifest_not_the_version
gate_after "a deleted input: fails" 1 delete_input
contains "and the deleted file is named" "crates/b/src/lib.rs" "$(rel "$REPO" gate main)"
gate_after "an input moved out of src (git sees a rename): fails" 1 move_input_out
contains "and the old path is named" "crates/b/src/lib.rs" "$(rel "$REPO" gate main)"
mkrepo
printf 'docs\n' >> "$REPO/docs/x.md"; commit_all
git_in checkout -q main; touch_src; bump; commit_all; git_in checkout -q change
ok "what main gained after the branch left it does not count (merge base, not tip)" 0 "$(code_of "$(rel "$REPO" gate main)")"
# The case only the three dots pass: main gains a source change and no bump, the branch changes docs. Compared tip to tip (two dots) the source change of main would look like the branch's own.
mkrepo
printf 'docs\n' >> "$REPO/docs/x.md"; commit_all
git_in checkout -q main; touch_src; commit_all; git_in checkout -q change
ok "main gained a source change and no bump while the branch changed only docs: passes (merge base, not tip)" 0 "$(code_of "$(rel "$REPO" gate main)")"
# The version has to go up from the merge base, not merely differ from the tip of the base.
version_from_to() { sed -i.bak "s/^version = \"$1\"/version = \"$2\"/" "$REPO/Cargo.toml" && rm "$REPO/Cargo.toml.bak"; }
mkrepo
git_in checkout -q main; version_from_to 0.1.0 0.1.1; commit_all; git_in checkout -q -B change main
version_from_to 0.1.1 0.1.0; touch_src; commit_all
out=$(rel "$REPO" gate main)
ok "a source change that lowers the version from 0.1.1 to 0.1.0: fails" 1 "$(code_of "$out")"
contains "and says the version went down" "went down from 0.1.1" "$out"
mkrepo
git_in checkout -q main; version_from_to 0.1.0 0.1.1; commit_all; git_in checkout -q change
touch_src; commit_all
out=$(rel "$REPO" gate main)
ok "a branch that left main before main's bump, with a source change and no bump of its own: fails" 1 "$(code_of "$out")"
contains "and says the version stayed" "still 0.1.0" "$out"
mkrepo
git_in checkout -q main; version_from_to 0.1.0 0.1.1; commit_all; git_in checkout -q change
touch_src; bump; commit_all
ok "the same branch with a bump above the merge base's version: passes" 0 "$(code_of "$(rel "$REPO" gate main)")"
for pair in "0.1.9 0.1.10" "0.9.9 0.10.0" "9.9.9 10.0.0"; do
  set -- $pair
  mkrepo
  git_in checkout -q main; version_from_to 0.1.0 "$1"; commit_all; git_in checkout -q -B change main
  version_from_to "$1" "$2"; touch_src; commit_all
  ok "$1 to $2 is a bump (the numbers are compared as numbers, not as text)" 0 "$(code_of "$(rel "$REPO" gate main)")"
done
mkrepo
out=$(rel "$REPO" gate no-such-ref)
ok "a base that does not exist is an error" 1 "$(code_of "$out")"
contains "and the error says so" "cannot compare" "$out"
ok "the gate without an argument is refused" 1 "$(code_of "$(rel "$REPO" gate)")"

# ---------------------------------------------------------------------------
t "4. the tag rules"
# ---------------------------------------------------------------------------
mkrepo
git_in checkout -q main
out=$(rel "$REPO" verify v0.1.0 main)
ok "the tag of the version, on main: passes" 0 "$(code_of "$out")"
out=$(rel "$REPO" verify v0.1.1 main)
ok "a tag that is not the version of the commit: fails" 1 "$(code_of "$out")"
contains "and says both" "v0.1.1" "$out"
ok "a tag without the v: fails" 1 "$(code_of "$(rel "$REPO" verify 0.1.0 main)")"
git_in checkout -q -b side; printf 'x\n' >> "$REPO/README.md"; commit_all
ok "a commit that is not on main: fails" 1 "$(code_of "$(rel "$REPO" verify v0.1.0 main)")"
contains "and says so" "not on main" "$(rel "$REPO" verify v0.1.0 main)"
git_in checkout -q main; git_in merge -q --ff-only side
ok "the same commit once it is on main: passes" 0 "$(code_of "$(rel "$REPO" verify v0.1.0 main)")"
git_in checkout -q HEAD~1
ok "an older commit of main: passes" 0 "$(code_of "$(rel "$REPO" verify v0.1.0 main)")"
ok "a main ref that does not exist: fails" 1 "$(code_of "$(rel "$REPO" verify v0.1.0 origin/main)")"
ok "verify without arguments: fails" 1 "$(code_of "$(rel "$REPO" verify)")"
ok "an unknown command: fails" 1 "$(code_of "$(rel "$REPO" frobnicate)")"

# ---------------------------------------------------------------------------
t "5. install.sh keeps a second copy of the version reader, and it answers like the first"
# ---------------------------------------------------------------------------
# install.sh has to stay one standalone file, so it cannot call core-release.sh. The seam is its own behaviour: a managed copy with an untracked Cargo.toml is installed again, against a release directory that is not there, and the line it says on the way to the node CLI carries the version it read (or says it found none). The curl shim refuses everything but file:// URLs.
SHIM=$TMP/shim; mkdir -p "$SHIM"
REAL_CURL=$(command -v curl || true)
cat > "$SHIM/curl" <<'EOF'
#!/bin/sh
for a in "$@"; do last=$a; done
case $last in file://*) [ -z "$REAL_CURL" ] || exec "$REAL_CURL" "$@" ;; esac
exit 22
EOF
chmod 755 "$SHIM/curl"
export REAL_CURL
ORIGIN=$TMP/origin
mkdir -p "$ORIGIN"
git -C "$ORIGIN" init -q -b main && git -C "$ORIGIN" config user.email t@example.com && git -C "$ORIGIN" config user.name t
echo stub > "$ORIGIN/file"; git -C "$ORIGIN" add -A && git -C "$ORIGIN" commit -q -m origin
HOME_DIR=$TMP/home; mkdir -p "$HOME_DIR"
install_env() {
  env HOME="$HOME_DIR" TAGENTS_HOME="$HOME_DIR/share/tagents" TAGENTS_BIN="$HOME_DIR/bin" TAGENTS_REPO="$ORIGIN" \
    TAGENTS_BUILD_CMD=true TAGENTS_CORE_BASE_URL="file://$TMP/no-release" TAGENTS_CORE_TARGET=aarch64-apple-darwin \
    PATH="$SHIM:$PATH" sh "$INSTALL" --hooks-dir "$HOME_DIR/hooks" "$@" 2>&1
}
install_env >/dev/null   # clones the copy; no Cargo.toml in it yet, so the fetch is silent
lacks "a copy with no Cargo.toml says nothing about a prebuilt binary" "prebuilt" "$(install_env)"
for f in "$SHAPES"/*.toml; do
  name=$(basename "$f" .toml)
  want=$(cat "$SHAPES/$name.expected")
  cp "$f" "$HOME_DIR/share/tagents/Cargo.toml"
  said=$(install_env)
  if [ "$want" = error ]; then
    contains "$name: install.sh finds no version either" "no workspace version in" "$said"
  else
    contains "$name: install.sh reads $want" "no prebuilt tagents-core $want for aarch64-apple-darwin" "$said"
  fi
done

# The SHA-256 helper has three homes: install.sh (one standalone file), core-release.sh, and the inline checksum step of release.yml. The two functions run over the same files here and must print the same thing.
printf 'sha pin\n' > "$TMP/sha-a"; : > "$TMP/sha-b"
inst_sha=$(sed -n '/^sha256_of() {/,/^}/p' "$INSTALL")
rel_sha=$(sed -n '/^have() /p;/^sha256_of() {/,/^}/p' "$RELEASE")
ok "both scripts define sha256_of" 2 "$(printf '%s\n%s\n' "$inst_sha" "$rel_sha" | grep -c '^sha256_of() {')"
for f in sha-a sha-b; do
  from_installer=$(sh -c "$inst_sha
sha256_of '$TMP/$f'")
  from_script=$(sh -c "$rel_sha
sha256_of '$TMP/$f'")
  ok "install.sh and core-release.sh print the same SHA-256 for $f" "$from_script" "$from_installer"
  ok "...and it is the real one" "$(sha_of "$TMP/$f")" "$from_installer"
done

# ---------------------------------------------------------------------------
t "6. release.yml and the code it relies on agree"
# ---------------------------------------------------------------------------
WORKFLOW=$ROOT/.github/workflows/release.yml
# is_input as core-release.sh defines it: its own text, not a copy.
eval "$(sed -n '/^is_input() {/,/^}/p' "$RELEASE")"
pr_paths=$(awk '
  /^  pull_request:/ { in_pr = 1; next }
  in_pr && /^  [a-z_]+:/ { in_pr = 0 }
  in_pr && /^    paths:/ { in_paths = 1; next }
  in_pr && in_paths && /^      - / { sub(/^      - /, ""); gsub(/\047/, ""); print; next }
  in_pr && in_paths { in_paths = 0 }
' "$WORKFLOW")
ok "release.yml lists paths for its pull_request trigger" yes "$([ -n "$pr_paths" ] && echo yes || echo no)"
# A pattern of the workflow is a glob where ** is read as *, as in a case pattern.
on_a_pr_path() {  # <file>
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # shellcheck disable=SC2254
    case $1 in $p) return 0 ;; esac
  done <<< "$pr_paths"
  return 1
}
for f in Cargo.toml Cargo.lock rust-toolchain.toml crates/a/Cargo.toml crates/a/build.rs crates/a/src/lib.rs crates/a/src/x/y.rs spec/cli/tagents-core.json spec/cli/cli-spec.schema.json; do
  ok "is_input accepts $f" yes "$(is_input "$f" && echo yes || echo no)"
  ok "...and a pull_request path of release.yml matches it, so the three builds run as a dry run for it" yes "$(on_a_pr_path "$f" && echo yes || echo no)"
done
for f in docs/x.md README.md crates/a/tests/t.rs packages/core/src/x.ts; do
  ok "is_input refuses $f" no "$(is_input "$f" && echo yes || echo no)"
done

# The targets exist in three places: the build matrix and the publish loop of release.yml, and core_triple in install.sh.
matrix_targets=$(awk '/^ *- target: /{ print $3 }' "$WORKFLOW" | sort | tr '\n' ' ')
loop_targets=$(sed -n 's/^ *for target in \(.*\); do$/\1/p' "$WORKFLOW" | tr ' ' '\n' | sort | tr '\n' ' ')
ok "the build matrix names three targets" 3 "$(printf '%s\n' $matrix_targets | wc -l | tr -d ' ')"
ok "the publish loop names the same targets as the build matrix" "$matrix_targets" "$loop_targets"
core_triple_fn=$(sed -n '/^core_triple() {/,/^}/p' "$INSTALL")
for target in $matrix_targets; do
  ok "install.sh takes $target through TAGENTS_CORE_TARGET" "$target" "$(TAGENTS_CORE_TARGET=$target sh -c "$core_triple_fn
core_triple")"
done
ok "...and refuses a target nobody builds" "" "$(TAGENTS_CORE_TARGET=riscv64-unknown-nothing sh -c "$core_triple_fn
core_triple")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
