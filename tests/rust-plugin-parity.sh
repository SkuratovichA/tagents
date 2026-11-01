#!/usr/bin/env bash
#
# tests/rust-plugin-parity.sh — `tagents-core plugin add` and `plugin remove` leave what the node CLI leaves.
#
# Every scenario runs twice, `node packages/core/dist/cli/main.js <args>` and `target/debug/tagents-core <args>` (or $TAGENTS_CORE_BIN), each on its own pristine copy of the same tree at the same path (so no transcript can tell the two apart by where it ran), under `env -i` with a scratch HOME, config directory and locale, and with no `pnpm` on PATH (node's last resort for a package it cannot find is `pnpm root -g`). It passes only when stdout, stderr, the exit code and the whole tree afterwards (every path, its mode, its link target or the checksum of its bytes) are the same. The only thing normalised is the process id in a temporary file's name.
# The tree is the package tree of tests/rust-plugin-vectors/tree.mts, and the config documents are the corpus of tests/rust-plugin-vectors/corpus.mts, written by tests/rust-plugin-vectors/materialise.mts, so the cases here and the vectors of crates/tagents-core/tests/plugin_vectors/ are about the same inputs.
# Who answered is checked too. The Rust side runs with $TAGENTS_NODE pointing at a shim that notes it was started and then runs the real node: a scenario marked `rust` fails when the binary handed the call to node (a binary that forwarded everything would otherwise pass every comparison), one marked `node` fails when the binary answered it itself (the call is one the design hands over, and answering it would be a second implementation of node's error text), and one marked `any` is counted and not judged (the corpus sweeps, where whether Rust can prove an answer depends on the document). A floor on the count says the sweeps were not all handed over.
# Tripwires assert on the node run alone: its exit code, and a text it must print, so a scenario that stopped provoking what it exists for fails here instead of passing for nothing.
#
# PARITY_SELF_TEST=1 runs node on both sides and skips the checks of who answered: it proves the suite and node's determinism, not the Rust binary. PARITY_ONLY=<text> runs only the scenarios whose label holds the text. TAGENTS_NODE names the node program.
# Needs a built node CLI (pnpm build), a node that runs .mts files, and nothing else: no network, no real home, no tmux. bash 3.2.
#   env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/rust-plugin-parity.sh

set -o pipefail
umask 022

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd -P)
NODE=${TAGENTS_NODE:-$(command -v node)}
CORE_JS="$REPO/packages/core/dist/cli/main.js"
RUST=${TAGENTS_CORE_BIN:-$REPO/target/debug/tagents-core}
MATERIALISE="$HERE/rust-plugin-vectors/materialise.mts"
SELF_TEST=${PARITY_SELF_TEST:-}
ONLY=${PARITY_ONLY:-}
SWEEP_FLOOR=150

[ -n "$NODE" ] && [ -x "$NODE" ] || { echo "rust-plugin-parity: no node to run (set TAGENTS_NODE)" >&2; exit 2; }
[ -f "$CORE_JS" ] || { echo "rust-plugin-parity: $CORE_JS is not built; run: pnpm install && pnpm build" >&2; exit 2; }
if [ -z "$SELF_TEST" ] && [ ! -x "$RUST" ]; then
  if [ -n "${TAGENTS_CORE_BIN:-}" ]; then echo "rust-plugin-parity: $RUST is not an executable" >&2; exit 2; fi
  (cd "$REPO" && cargo build -p tagents-core >&2) || { echo "rust-plugin-parity: cargo build failed" >&2; exit 2; }
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/tagents-plugin-parity.XXXXXX") || exit 2
TMP=$(cd "$TMP" && pwd -P) || exit 2
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM

RUN=$TMP/run                # what a run works in and leaves: one path for both programs
TEMPLATE=$TMP/template      # the pristine tree, copied to $RUN before each run
CORPUS=$TMP/corpus          # one <name>.toml for each document of the corpus
SHIM=$TMP/shim
BIN=$TMP/bin                # the only directory of PATH that holds node
MARK=$TMP/handed-over       # the shim writes it when the binary hands a call to node
mkdir "$SHIM" "$BIN" || exit 2
ln -s "$NODE" "$BIN/node"
printf '#!/bin/sh\n: > "$PARITY_MARK"\nexec "$PARITY_REAL_NODE" "$@"\n' > "$SHIM/node"
chmod +x "$SHIM/node"
"$NODE" "$MATERIALISE" tree "$TEMPLATE" || { echo "rust-plugin-parity: cannot write the package tree" >&2; exit 2; }
"$NODE" "$MATERIALISE" corpus "$CORPUS" || { echo "rust-plugin-parity: cannot write the corpus" >&2; exit 2; }

if [ -z "$SELF_TEST" ]; then
  # The first check, before any scenario: the binary says it serves the two verbs. A build with no `plugin` group would hand every scenario to node and pass them all.
  "$RUST" --spec | "$NODE" -e 'const s = JSON.parse(require("fs").readFileSync(0, "utf8")); const has = (p) => s.commands.some((c) => c.path.join(" ") === p); process.exit(has("plugin add") && has("plugin remove") ? 0 : 1)' \
    || { echo "rust-plugin-parity: $RUST does not serve plugin add and plugin remove (--spec)" >&2; exit 2; }
fi

# One `stat` format per platform: the path, the type and mode as `ls -l` writes them, and the link target.
if stat -c %A / > /dev/null 2>&1; then STAT_FORMAT=(-c '%n %A %N'); else STAT_FORMAT=(-f '%N %Sp %Y'); fi
IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1

pass=0; fail=0; skipped=0; rust_served=0; handed_over=0; sweep_served=0; sweep_total=0
ok() { pass=$((pass + 1)); }
bad() {  # <label> <detail...>
  fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; shift
  [ $# -gt 0 ] && printf '       %s\n' "$@"
}
t() { printf '\n%s\n' "$1"; }

# --------------------------------------------------------------- scenario state ---
# Set before a scenario, cleared after it by `reset`: the directory to run in (relative to the run), the locale, a setup run in the run's directory before the program (a shell command), the environment to add, the config directory (relative to the run), and the arguments.
CWD=; LOCALE=en; SETUP=; CFGDIR=cfg; EXTRA=(); ARGS=()
reset() { CWD=; LOCALE=en; SETUP=; CFGDIR=cfg; EXTRA=(); ARGS=(); }

# What the run left: every path with its mode and its checksum or link target.
snapshot() {
  ( cd "$RUN" && { find . -exec stat "${STAT_FORMAT[@]}" {} + ; find . -type f -exec cksum {} + 2> /dev/null; } | LC_ALL=C sort )
}
# The only difference allowed between the two programs: the process id in `<config>.<pid>.tmp`.
norm() { sed -E 's/\.[0-9]+\.tmp/.PID.tmp/g'; }

side() {  # <tag> <program words...>
  local tag=$1; shift
  rm -rf "$RUN"; chmod -R u+rwx "$RUN" 2> /dev/null
  cp -RPp "$TEMPLATE" "$RUN" || { echo "rust-plugin-parity: cannot copy the tree" >&2; exit 2; }
  if [ -n "$SETUP" ]; then ( cd "$RUN" && eval "$SETUP" ) || { echo "rust-plugin-parity: setup failed: $SETUP" >&2; exit 2; }; fi
  rm -f "$MARK"
  ( cd "$RUN/$CWD" && exec env -i "PATH=$BIN:/usr/bin:/bin" "HOME=$RUN/home" "TAGENTS_CONFIG_DIR=$RUN/$CFGDIR" "TAGENTS_LOCALE=$LOCALE" \
      "TAGENTS_NODE=$SHIM/node" "PARITY_MARK=$MARK" "PARITY_REAL_NODE=$NODE" "${EXTRA[@]}" "$@" "${ARGS[@]}" ) 2> "$TMP/err.$tag.raw" | norm > "$TMP/out.$tag"
  echo "${PIPESTATUS[0]}" > "$TMP/code.$tag"
  norm < "$TMP/err.$tag.raw" > "$TMP/err.$tag"
  if [ -e "$MARK" ]; then echo node > "$TMP/via.$tag"; else echo own > "$TMP/via.$tag"; fi
  snapshot | norm > "$TMP/tree.$tag"
  chmod -R u+rwx "$RUN" 2> /dev/null
}

# A scenario: `sc <label> <via> <node's exit code, or - for any> <text node prints, or -> -- <the words after the program name>`.
# <via> is who must answer on the Rust side: rust, node, or any.
sc() {
  local label=$1 via=$2 want=$3 needle=$4; shift 5
  ARGS=("$@")
  if [ -n "$ONLY" ] && [[ $label != *"$ONLY"* ]]; then reset; return; fi
  side node "$NODE" "$CORE_JS"
  if [ -n "$SELF_TEST" ]; then side rust "$NODE" "$CORE_JS"; else side rust "$RUST"; fi

  local what=()
  cmp -s "$TMP/out.node" "$TMP/out.rust" || what+=(stdout)
  cmp -s "$TMP/err.node" "$TMP/err.rust" || what+=(stderr)
  cmp -s "$TMP/code.node" "$TMP/code.rust" || what+=("exit code")
  cmp -s "$TMP/tree.node" "$TMP/tree.rust" || what+=(tree)
  if [ ${#what[@]} -ne 0 ]; then
    bad "$label: differs in ${what[*]}" \
      "args: $(printf '%q ' "${ARGS[@]}")" \
      "exit node=$(cat "$TMP/code.node") rust=$(cat "$TMP/code.rust")" \
      "stdout node: $(head -c 300 "$TMP/out.node" | tr '\n' '|')" \
      "stdout rust: $(head -c 300 "$TMP/out.rust" | tr '\n' '|')" \
      "stderr node: $(head -c 300 "$TMP/err.node" | tr '\n' '|')" \
      "stderr rust: $(head -c 300 "$TMP/err.rust" | tr '\n' '|')" \
      "tree: $(diff "$TMP/tree.node" "$TMP/tree.rust" | head -4 | tr '\n' '|')"
  else
    ok
  fi

  if [ "$want" != - ] && [ "$(cat "$TMP/code.node")" != "$want" ]; then
    bad "tripwire $label: node exited $(cat "$TMP/code.node"), this scenario exists to provoke $want" "stderr: $(head -c 200 "$TMP/err.node" | tr '\n' '|')"
  fi
  if [ "$needle" != - ] && ! cat "$TMP/out.node" "$TMP/err.node" | grep -qF -- "$needle"; then
    bad "tripwire $label: node did not print what this scenario exists to provoke" "wanted: $needle" "stdout: $(head -c 200 "$TMP/out.node" | tr '\n' '|')" "stderr: $(head -c 200 "$TMP/err.node" | tr '\n' '|')"
  fi

  if [ -z "$SELF_TEST" ]; then
    local answered; answered=$(cat "$TMP/via.rust")
    if [ "$answered" = node ]; then handed_over=$((handed_over + 1)); else rust_served=$((rust_served + 1)); fi
    if [ "$via" = any ]; then sweep_total=$((sweep_total + 1)); [ "$answered" = own ] && sweep_served=$((sweep_served + 1)); fi
    case "$via:$answered" in
      rust:node) bad "$label: the binary handed this call to node, it should answer it" ;;
      node:own) bad "$label: the binary answered this call, the design hands it to node" ;;
    esac
  fi
  reset
}

# A scenario that needs a user who is not root (a mode that keeps root out means nothing to root).
sc_user() {  # <label> <the rest of sc's words>
  if [ "$IS_ROOT" -eq 1 ]; then skipped=$((skipped + 1)); reset; return; fi
  sc "$@"
}

# ------------------------------------------------------------------- setups ---
# Run in the run's directory, before the program. Single quotes are the shell's, so a setup may use $CORPUS.
S_DOC='mkdir -p cfg; cp "$CORPUS/%s.toml" cfg/config.toml'
doc() { printf "$S_DOC" "$1"; }                            # the config is this corpus document
text() { printf 'mkdir -p cfg; printf "%%s" %q > cfg/config.toml' "$1"; }   # the config holds this text
CORPUS_DIR=$CORPUS
export CORPUS

# ------------------------------------------------------------ by directory ---
t "add: a directory"
CWD=proj/a/b
sc "add a relative directory" rust 0 "added plain-pkg" -- plugin add ../../../pkgs/plain
CWD=proj/a/b; sc "add a relative directory with a trailing slash" rust 0 "added plain-pkg" -- plugin add ../../../pkgs/plain/
CWD=proj/a/b; sc "add a directory through .." rust 0 "added plain-pkg" -- plugin add ../../../pkgs/../pkgs/plain
CWD=proj/a/b; sc "add a directory with a manifest in the argument" rust 1 "package.json" -- plugin add ../../../pkgs/plain/package.json
sc "add ~ is the home directory" rust 1 "package.json" -- plugin add '~'
sc "add ~/home-pkg" rust 0 "added home-pkg" -- plugin add '~/home-pkg'
sc "add ~x is a directory called ~x" rust 1 "~x" -- plugin add '~x'
sc "add a directory by absolute path" rust 0 "added plain-pkg" -- plugin add "$RUN/pkgs/plain"
sc "add a directory that is not there" rust 1 "nothing" -- plugin add ./nothing
sc "add /" rust 1 "package.json" -- plugin add /
sc "add a path above the root" rust 1 "package.json" -- plugin add "$(printf '../%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)tmp-does-not-exist"
LOCALE=ru; sc "add a directory, in Russian (locale ru)" rust 0 "plain-pkg" -- plugin add ./pkgs/plain
LOCALE=ru; sc "add a directory that is not there, in Russian" rust 1 - -- plugin add ./nothing
LOCALE=fr; sc "add a directory, locale fr is English" rust 0 "added plain-pkg" -- plugin add ./pkgs/plain
LOCALE=RU; sc "add a directory, locale RU is English" rust 0 "added plain-pkg" -- plugin add ./pkgs/plain
LOCALE=; sc "add a directory, a blank locale is English" rust 0 "added plain-pkg" -- plugin add ./pkgs/plain

t "add: the packages of the tree, by directory (a sweep)"
for d in $(ls "$TEMPLATE/pkgs"); do
  sc "add pkgs/$d" any - - -- plugin add "./pkgs/$d"
  LOCALE=ru; sc "add pkgs/$d (ru)" any - - -- plugin add "./pkgs/$d"
done

t "add: the names"
CWD=proj/a/b; sc "add --name" rust 0 "added mine" -- plugin add ../../../pkgs/plain --name mine
CWD=proj/a/b; sc "add --name before the package" rust 0 "added mine" -- plugin add --name mine ../../../pkgs/plain
CWD=proj/a/b; sc "add --name=" rust 0 "added mine" -- plugin add ../../../pkgs/plain --name=mine
CWD=proj/a/b; sc "add the last --name wins" rust 0 "added last" -- plugin add ../../../pkgs/plain --name first --name=last
CWD=proj/a/b; sc "add -- ends the options" rust 0 "added plain-pkg" -- plugin add -- ../../../pkgs/plain
sc "add a second package is ignored" rust 0 "added plain-pkg" -- plugin add ./pkgs/plain ./pkgs/no-name
sc "add the default name of a scoped package" rust 0 "added telegram" -- plugin add ./pkgs/scoped-name
sc "add the default name of a tagents-plugin- package" rust 0 "added wiki" -- plugin add ./pkgs/prefixed-name
sc "add the default name of a package with no name is its directory's" rust 0 "added no-name" -- plugin add ./pkgs/no-name
sc "add --name with a space" rust 2 - -- plugin add ./pkgs/plain --name 'bad name'
sc "add --name with a slash" rust 2 - -- plugin add ./pkgs/plain --name a/b
sc "add --name that starts with a dot" rust 2 - -- plugin add ./pkgs/plain --name=.x
sc "add --name that starts with a dash" rust 2 - -- plugin add ./pkgs/plain --name=-x
sc "add --name that is empty" rust 2 - -- plugin add ./pkgs/plain --name=
sc "add --name with a newline at the end" rust 2 - -- plugin add ./pkgs/plain --name "$(printf 'a\nb')"
sc "add --name with a trailing newline" rust 2 - -- plugin add ./pkgs/plain $'--name=a\n'
sc "add --name {{file}} is printed as typed" rust 2 - -- plugin add ./pkgs/plain '--name={{file}}'
LOCALE=ru; sc "add a bad name, in Russian" rust 2 - -- plugin add ./pkgs/plain --name 'bad name'
sc "add a name that is bad for a package that is not there is the package's error" rust 1 - -- plugin add ./nothing --name 'bad name'
sc "add --name. . _ -" rust 0 "added a.b_c-d" -- plugin add ./pkgs/plain --name a.b_c-d
sc "add --name with a unicode letter" rust 2 - -- plugin add ./pkgs/plain --name é

t "add: usage"
sc "add without a package" rust 2 "missing required option <package-or-path>" -- plugin add
LOCALE=ru; sc "add without a package, in Russian" rust 2 - -- plugin add
sc "add --name and no package" rust 2 "missing required option" -- plugin add --name x
sc "add -- and no package" rust 2 "missing required option" -- plugin add --

# ----------------------------------------------------------------- by name ---
t "add: a package by name (from proj/a/b)"
CWD=proj/a/b; sc "add plain" rust 0 "added plain-in-nm" -- plugin add plain
CWD=proj/a/b; sc "add plain --name" rust 0 "added mine" -- plugin add plain --name mine
CWD=proj/a/b; sc "add @sc/plugin-x" rust 0 "added x" -- plugin add @sc/plugin-x
CWD=proj/a/b; sc "add a package with no name is the directory's" rust 0 "added no-name-nm" -- plugin add no-name-nm
CWD=proj/a/b; sc "add the nearest node_modules wins" rust 0 "added shadow-near" -- plugin add shadow
CWD=proj/a/b; sc "add a directory with no manifest is skipped for the next one" rust 0 "added hollow-far" -- plugin add hollow
CWD=proj/a/b; sc "add a directory named package.json is skipped for the next one" rust 0 "added dirjson-far" -- plugin add dirjson
CWD=proj/a/b; sc "add a link into the tree" rust 0 "added real-linked" -- plugin add linked
CWD=proj/a/b; sc "add a package with exports: null" any 0 - -- plugin add null-exports
CWD=proj/a/b; sc "add a package whose exports allow package.json" node 0 "added" -- plugin add exports-with-package-json
CWD=proj/a/b; sc "add a package whose exports do not allow package.json" node 1 - -- plugin add exports-without-package-json
CWD=proj/a/b; sc "add a package whose manifest is not JSON" any - - -- plugin add bad-json
CWD=proj/a/b; sc "add a package that is not a plugin" rust 3 - -- plugin add no-tagents-nm
CWD=proj/a/b; sc "add a package of api 2" rust 3 - -- plugin add api2-nm
CWD=proj/a/b; sc "add a package whose entry is missing" rust 3 - -- plugin add no-entry-nm
CWD=proj/a/b; sc "add a package nobody has" node 1 - -- plugin add no-such-package-anywhere
CWD=proj/a/b; sc "add a package whose name starts with an underscore" node - - -- plugin add _underscore
CWD=proj/a/b; sc "add a subpath of a package" node - - -- plugin add plain/package.json
CWD=proj/a/b; sc "add a name in capitals (the disk's case is not the typed one on a case-insensitive volume)" any - - -- plugin add PLAIN
CWD=proj/a/b; sc "add a package with no name in capitals" any - - -- plugin add NO-NAME-NM
CWD=proj/a/b; LOCALE=ru; sc "add a package, in Russian" rust 0 plain-in-nm -- plugin add plain
CWD=selfref/a; sc "add the package the working directory is in, which has exports (self-reference)" node - - -- plugin add selfref
CWD=selfnoexp/a; sc "add the package the working directory is in, with no exports" rust 0 "added selfnoexp-in-nm" -- plugin add selfnoexp

t "add: what node's flags change"
SETUP='printf "const M = require(\"module\"); const o = M._resolveFilename; M._resolveFilename = function (r, ...a) { return r === \"plain/package.json\" ? process.env.HOME + \"/../pkgs/plain/package.json\" : o.call(this, r, ...a); };\n" > hook.cjs'
CWD=proj/a/b; EXTRA=("NODE_OPTIONS=--require=$RUN/hook.cjs"); sc "add plain under a --require hook that redirects it" node 0 "added plain-pkg" -- plugin add plain
CWD=proj/a/b; EXTRA=("NODE_OPTIONS=--no-warnings"); sc "add plain under NODE_OPTIONS" node 0 "added plain-in-nm" -- plugin add plain
CWD=proj/a/b; EXTRA=("NODE_PRESERVE_SYMLINKS=1"); sc "add a link under NODE_PRESERVE_SYMLINKS" node 0 "added" -- plugin add linked
CWD=proj/a/b; EXTRA=("NODE_OPTIONS=--no-warnings"); sc "add a directory under NODE_OPTIONS" rust 0 "added plain-pkg" -- plugin add ../../../pkgs/plain
CWD=proj/a/b; EXTRA=("NODE_PATH=$RUN/pkgs"); sc "add a package only NODE_PATH has" node 0 "added no-name" -- plugin add no-name
CWD=proj/a/b; EXTRA=("NODE_PATH=$RUN/pkgs"); sc "add a package node_modules has, with NODE_PATH set (node_modules is searched first)" rust 0 "added plain-in-nm" -- plugin add plain

# ----------------------------------------------------------- the config file ---
t "add and remove: the state of the config"
sc "add: no config and no directory" rust 0 "added plain-pkg" -- plugin add ./pkgs/plain
CFGDIR=new/deep/cfg; sc "add: a config directory that is not there is made" rust 0 "added plain-pkg" -- plugin add ./pkgs/plain
SETUP=$(text '[plugins.plain-pkg]
from = "/elsewhere"
'); sc "add: the key is listed" rust 3 "already listed" -- plugin add ./pkgs/plain
SETUP=$(text '[plugins.other]
from = "/elsewhere"
'); sc "add: another key is listed" rust 0 "added plain-pkg" -- plugin add ./pkgs/plain
SETUP=$(text '# my plugins'); sc "add: a config that is a comment with no newline" rust 0 "added plain-pkg" -- plugin add ./pkgs/plain
SETUP=$(text ''); sc "add: an empty config" rust 0 "added plain-pkg" -- plugin add ./pkgs/plain
SETUP='mkdir -p cfg; printf "[plugins.keep]\nfrom = \"/k\"\n" > cfg/config.toml; chmod 600 cfg/config.toml'; sc "add: the mode of the config is not kept (node does not keep it)" rust 0 "added plain-pkg" -- plugin add ./pkgs/plain
SETUP='mkdir -p cfg dotfiles; printf "[plugins.keep]\nfrom = \"/k\"\n" > dotfiles/tagents.toml; ln -s ../dotfiles/tagents.toml cfg/config.toml'; sc "add: a config that is a link stays one" rust 0 "added plain-pkg" -- plugin add ./pkgs/plain
SETUP='mkdir -p cfg dotfiles; printf "[plugins.plain-pkg]\nfrom = \"/p\"\n[plugins.keep]\nfrom = \"/k\"\n" > dotfiles/tagents.toml; ln -s ../dotfiles/tagents.toml cfg/config.toml'; sc "remove: a config that is a link stays one" rust 0 "removed plain-pkg" -- plugin remove plain-pkg
SETUP='mkdir -p cfg dotfiles; printf "[plugins.keep]\nfrom = \"/k\"\n" > dotfiles/tagents.toml; ln -s ../dotfiles/tagents.toml cfg/config.toml; ln -s cfg/config.toml link-to-link'; CFGDIR=cfg; sc "add: a link in front of the link" rust 0 - -- plugin add ./pkgs/plain
SETUP='mkdir -p cfg; ln -s missing.toml cfg/config.toml'; sc "add: a link that leads nowhere" node 1 - -- plugin add ./pkgs/plain
SETUP='mkdir -p cfg; ln -s missing.toml cfg/config.toml'; sc "remove: a link that leads nowhere" node 1 - -- plugin remove x
SETUP='mkdir -p cfg; ln -s config.toml cfg/config.toml'; sc "add: a link to itself" node 1 - -- plugin add ./pkgs/plain
SETUP='mkdir -p cfg; ln -s b cfg/a; ln -s a cfg/b; ln -s a cfg/config.toml'; sc "remove: a loop of links" node 1 - -- plugin remove x
SETUP='mkdir -p cfg dotfiles/dir; ln -s ../dotfiles/dir cfg/config.toml'; sc "add: a link to a directory" node 1 - -- plugin add ./pkgs/plain
SETUP='mkdir -p cfg/config.toml'; sc "add: a directory where the config is" node 1 - -- plugin add ./pkgs/plain
SETUP='mkdir -p cfg/config.toml'; sc "remove: a directory where the config is" node 1 - -- plugin remove x
SETUP='mkdir -p cfg; printf "[plugins.x]\nfrom = \"/p\"\n" > cfg/config.toml; chmod 000 cfg/config.toml'; sc_user "add: a config nobody may read" node 1 - -- plugin add ./pkgs/plain
SETUP='mkdir -p cfg; printf "[plugins.x]\nfrom = \"/p\"\n" > cfg/config.toml; chmod 000 cfg/config.toml'; sc_user "remove: a config nobody may read" node 1 - -- plugin remove x
SETUP='mkdir -p cfg; printf "[plugins.x]\nfrom = \"/p\"\n" > cfg/config.toml; chmod 555 cfg'; sc_user "add: a directory nobody may write in" node 1 - -- plugin add ./pkgs/plain
SETUP='mkdir -p cfg; printf "[plugins.x]\nfrom = \"/p\"\n" > cfg/config.toml; chmod 555 cfg'; sc_user "remove: a directory nobody may write in" node 1 - -- plugin remove x
SETUP='mkdir -p cfg; printf "# caf\xe9\n[plugins.x]\nfrom = \"/p\"\n" > cfg/config.toml'; sc "add: a config that is not UTF-8" node 0 - -- plugin add ./pkgs/plain
SETUP='mkdir -p cfg; printf "# caf\xe9\n[plugins.x]\nfrom = \"/p\"\n" > cfg/config.toml'; sc "remove: a config that is not UTF-8" node 0 - -- plugin remove x
SETUP='mkdir -p cfg; printf "[plugins\n" > cfg/config.toml'; sc "add: a config that is not TOML" node 1 - -- plugin add ./pkgs/plain
SETUP='mkdir -p cfg; printf "plugins = 3\n" > cfg/config.toml'; sc "add: plugins that is not a table" node 1 - -- plugin add ./pkgs/plain
SETUP='mkdir -p cfg; printf "plugins = 3\n" > cfg/config.toml'; sc "remove: plugins that is not a table" node 1 - -- plugin remove x

t "remove"
sc "remove: no config" rust 3 "not listed" -- plugin remove x
LOCALE=ru; sc "remove: no config (locale ru)" rust 3 - -- plugin remove x
SETUP=$(text '[plugins.x]
from = "/p"
'); sc "remove: the only entry" rust 0 "removed x" -- plugin remove x
SETUP=$(text '[plugins.x]
from = "/p"
'); LOCALE=ru; sc "remove: the only entry (locale ru)" rust 0 - -- plugin remove x
SETUP=$(text '[plugins.x]
from = "/p"
'); sc "remove: an entry that is not there" rust 3 "not listed" -- plugin remove y
SETUP=$(text '[plugins.x]
from = "/p"
'); sc "remove: a second name is ignored" rust 0 "removed x" -- plugin remove x y
SETUP=$(text '[plugins.x]
from = "/p"
'); sc "remove: -- ends the options" rust 0 "removed x" -- plugin remove -- x
SETUP=$(text '[plugins.x]
from = "/p"
'); sc "remove: an empty name" rust 3 - -- plugin remove ''
SETUP=$(text '[plugins."a.b"]
from = "/p"
[plugins.c]
from = "/q"
'); sc "remove: a key with a dot" rust 0 "removed a.b" -- plugin remove a.b
SETUP=$(text '[plugins.__proto__]
from = "/p"
'); sc "remove: __proto__" node - - -- plugin remove __proto__
sc "remove: no name" rust 2 "missing required option <name>" -- plugin remove
LOCALE=ru; sc "remove: no name, in Russian" rust 2 - -- plugin remove
sc "remove: -- and no name" rust 2 "missing required option" -- plugin remove --
sc "remove: an option" node 2 - -- plugin remove --name x
sc "remove: a short option" node 2 - -- plugin remove -x
sc "remove: an option and a name" node 2 - -- plugin remove x --json
SETUP=$(text '# top comment

[plugins.x]
from = "/p"
# about y
[plugins.y]
from = "/q"
'); sc "remove: a comment above the next section stays with it" rust 0 "removed x" -- plugin remove x
SETUP=$(text '[plugins.x]
from = "/p"

[plugins.y]
from = "/q"

[other]
a = 1
'); sc "remove: the blank lines around an entry" rust 0 "removed y" -- plugin remove y

t "add: weird directories (what the escaping of from has to carry)"
# A control character cannot be written into the config (config-file.ts UNWRITABLE): node refuses and the binary hands the call over, so the three directories with one are node's and the rest are served here.
WEIRD_SETUP='mkdir -p "pkgs/$WEIRD/src"; cp pkgs/plain/package.json "pkgs/$WEIRD/"; cp pkgs/plain/src/plugin.ts "pkgs/$WEIRD/src/"'
for d in 'q"uote' 'back\slash' "it's" 'é😀' 'a b' '[x]' '#hash'; do
  export WEIRD=$d; SETUP=$WEIRD_SETUP
  sc "add a directory called $d" rust 0 "added w" -- plugin add "./pkgs/$d" --name w
done
for d in "$(printf 'tab\there')" "$(printf 'new\nline')" "$(printf 'del\177x')"; do
  export WEIRD=$d; SETUP=$WEIRD_SETUP
  sc "add a directory with a control character ($(printf '%s' "$d" | od -An -c | tr -s ' ' | head -c 24))" node 1 - -- plugin add "./pkgs/$d" --name w
done

# ------------------------------------------------------------ the corpus ---
t "add and remove: every document of the corpus (a sweep)"
for f in "$CORPUS"/*.toml; do
  n=$(basename "$f" .toml)
  SETUP=$(doc "$n"); sc "add into $n" any - - -- plugin add ./pkgs/plain
  SETUP=$(doc "$n"); sc "remove x from $n" any - - -- plugin remove x
  SETUP=$(doc "$n"); sc "remove plain-pkg from $n" any - - -- plugin remove plain-pkg
done

# --------------------------------------------------------------- hand-overs ---
t "what stays with node, and what the grammar hands over"
sc "plugin" node 2 - -- plugin
sc "plugin list with no config" node 0 - -- plugin list
sc "plugin list --json with no config" node 0 - -- plugin list --json
SETUP=$(text '[plugins.x]
from = "/nowhere"
'); sc "plugin list with a plugin that is not there" node 1 - -- plugin list
sc "plugin bogus" node 2 - -- plugin bogus
sc "plugin new with no name" node 2 - -- plugin new
sc "plugin add --bogus" node 2 - -- plugin add --bogus ./pkgs/plain
sc "plugin add --name with no value" node 2 - -- plugin add ./pkgs/plain --name
sc "plugin add --name followed by an option" node 2 - -- plugin add ./pkgs/plain --name --x
sc "plugin add -n" node 2 - -- plugin add -n x ./pkgs/plain
sc "plugin add --json" node 2 - -- plugin add ./pkgs/plain --json
sc "plugin add --no-name" node 2 - -- plugin add ./pkgs/plain --no-name
sc "plugin add -h" node 2 - -- plugin add -h
sc "plugin add --help" node 2 - -- plugin add --help
sc "plugin remove -h" node 2 - -- plugin remove -h
sc "plugin add an argument that is not UTF-8" node - - -- plugin add $'\xff'
sc "plugin add --name an argument that is not UTF-8" node - - -- plugin add ./pkgs/plain --name $'\xff'
sc "plugin remove an argument that is not UTF-8" node - - -- plugin remove $'\xff'

printf '\nrust-plugin-parity: %d passed, %d failed, %d skipped' "$pass" "$fail" "$skipped"
if [ -z "$SELF_TEST" ]; then
  printf '; answered by the binary: %d, handed to node: %d; of the %d sweep runs, the binary answered %d\n' "$rust_served" "$handed_over" "$sweep_total" "$sweep_served"
  if [ -z "$ONLY" ] && [ "$sweep_served" -lt "$SWEEP_FLOOR" ]; then
    printf '  FAIL the binary answered only %d of the sweep runs, fewer than the %d it is expected to (everything handed to node?)\n' "$sweep_served" "$SWEEP_FLOOR"
    fail=$((fail + 1))
  fi
else
  printf ' (self test: node on both sides)\n'
fi
[ "$fail" -eq 0 ]
