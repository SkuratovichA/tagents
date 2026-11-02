#!/usr/bin/env bash
#
# tests/rust-session-parity.sh — `tagents-core session open`, `session list` and `session last` print and leave what the node CLI prints and leaves.
#
# Every scenario runs twice, `node packages/core/dist/cli/main.js <args>` and `target/debug/tagents-core <args>` (or $TAGENTS_CORE_BIN), each on its own pristine copy of the same tree at the same path (so no output can tell the two apart by where it ran), under `env -i` with a scratch HOME, TMPDIR, state directory and config directory, and a PATH that holds nothing but a symbolic link to the real node, a stub `claude` and a stub `caffeinate`. It passes only when stdout, stderr, the exit code and the whole tree afterwards (every path, its mode, its link target or the checksum of its bytes) are the same. What is normalised is the `id` that `session open` makes, which must be a version 4 UUID to be normalised at all.
# The stub `claude` is the fakeClaude of packages/core/src/testkit.ts, written by tests/rust-session-parity-driver.mts, and records what it was started with into rec/ of the tree; the stub `caffeinate` records its arguments there too. The three verbs of this suite start no process, so a scenario also fails when anything was recorded.
# Who answered is checked too. The Rust side runs with $TAGENTS_NODE pointing at a shim that notes it was started and then runs the real node: a scenario marked `rust` fails when the binary handed the call to node (a binary that forwarded everything would otherwise pass every comparison), and one marked `node` fails when the binary answered it itself (the call is one the design hands over, and answering it would be a second implementation of node's error text).
# Tripwires assert on the node run alone: its exit code, and a text it must print, so a scenario that stopped provoking what it exists for fails here instead of passing for nothing.
#
# PARITY_SELF_TEST=1 runs node on both sides and skips the checks of who answered: it proves the suite and node's determinism, not the Rust binary. PARITY_ONLY=<text> runs only the scenarios whose label holds the text, and PARITY_SHOW=<n> prints both transcripts of each, cut at n characters a line. TAGENTS_NODE names the node program.
# Needs a built node CLI (pnpm build), a node that runs .mts files, and nothing else: no network, no real home, no tmux, no real claude. bash 3.2.
#   env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/rust-session-parity.sh

set -o pipefail
umask 022

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd -P)
NODE=${TAGENTS_NODE:-$(command -v node)}
CORE_JS="$REPO/packages/core/dist/cli/main.js"
RUST=${TAGENTS_CORE_BIN:-$REPO/target/debug/tagents-core}
DRIVER="$HERE/rust-session-parity-driver.mts"
SELF_TEST=${PARITY_SELF_TEST:-}
ONLY=${PARITY_ONLY:-}
SHOW=${PARITY_SHOW:-}

[ -n "$NODE" ] && [ -x "$NODE" ] || { echo "rust-session-parity: no node to run (set TAGENTS_NODE)" >&2; exit 2; }
[ -f "$CORE_JS" ] || { echo "rust-session-parity: $CORE_JS is not built; run: pnpm install && pnpm build" >&2; exit 2; }
if [ -z "$SELF_TEST" ] && [ ! -x "$RUST" ]; then
  if [ -n "${TAGENTS_CORE_BIN:-}" ]; then echo "rust-session-parity: $RUST is not an executable" >&2; exit 2; fi
  (cd "$REPO" && cargo build -p tagents-core >&2) || { echo "rust-session-parity: cargo build failed" >&2; exit 2; }
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/tagents-session-parity.XXXXXX") || exit 2
TMP=$(cd "$TMP" && pwd -P) || exit 2
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM

RUN=$TMP/run                # what a run works in and leaves: one path for both programs
TEMPLATE=$TMP/template      # the pristine tree, copied to $RUN before each run
SHIM=$TMP/shim
BIN=$TMP/bin                # the only directory of PATH: node, the stub claude, the stub caffeinate
MARK=$TMP/handed-over       # the shim writes it when the binary hands a call to node
mkdir "$SHIM" "$BIN" || exit 2
ln -s "$NODE" "$BIN/node"
printf '#!/bin/sh\n: > "$PARITY_MARK"\nexec "$PARITY_REAL_NODE" "$@"\n' > "$SHIM/node"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$PARITY_REC/caffeinate"\n' > "$BIN/caffeinate"
chmod +x "$SHIM/node" "$BIN/caffeinate"
"$NODE" "$DRIVER" tree "$TEMPLATE" || { echo "rust-session-parity: cannot write the tree" >&2; exit 2; }
"$NODE" "$DRIVER" stub "$BIN" "{\"argvFile\":\"$RUN/rec/argv.json\",\"countFile\":\"$RUN/rec/count\",\"text\":\"stub\"}" || { echo "rust-session-parity: cannot write the stub claude" >&2; exit 2; }

# The harness itself: the program called `claude` or `caffeinate` on this PATH is the stub, so no scenario can reach a real one.
for program in claude caffeinate node; do
  [ "$(env -i "PATH=$BIN:/usr/bin:/bin" sh -c "command -v $program")" = "$BIN/$program" ] \
    || { echo "rust-session-parity: $program on the PATH of a run is not the one of $BIN" >&2; exit 2; }
done

if [ -z "$SELF_TEST" ]; then
  # The first check, before any scenario: the binary says it serves the three verbs. A build with no `session` verb would hand every scenario to node and pass them all.
  "$RUST" --spec | "$NODE" -e 'const s = JSON.parse(require("fs").readFileSync(0, "utf8")); const has = (p) => s.commands.some((c) => c.path.join(" ") === p); process.exit(has("session open") && has("session list") && has("session last") ? 0 : 1)' \
    || { echo "rust-session-parity: $RUST does not serve session open, session list and session last (--spec)" >&2; exit 2; }
fi

# One `stat` format per platform: the path, the type and mode as `ls -l` writes them, and the link target.
if stat -c %A / > /dev/null 2>&1; then STAT_FORMAT=(-c '%n %A %N'); else STAT_FORMAT=(-f '%N %Sp %Y'); fi
IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1

pass=0; fail=0; skipped=0; rust_served=0; handed_over=0
ok() { pass=$((pass + 1)); }
bad() {  # <label> <detail...>
  fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; shift
  [ $# -gt 0 ] && printf '       %s\n' "$@"
}
t() { printf '\n%s\n' "$1"; }

# --------------------------------------------------------------- scenario state ---
# Set before a scenario, cleared after it by `reset`: the directory to run in (relative to the run), the locale, a setup run in the run's directory before the program (a shell command), the environment to add, and the arguments.
CWD=; LOCALE=en; SETUP=; EXTRA=(); ARGS=()
reset() { CWD=; LOCALE=en; SETUP=; EXTRA=(); ARGS=(); }

# What the run left: every path with its mode and its checksum or link target.
snapshot() {
  ( cd "$RUN" && { find . -exec stat "${STAT_FORMAT[@]}" {} + 2> /dev/null ; find . -type f -exec cksum {} + 2> /dev/null; } | LC_ALL=C sort )
}
# The only difference allowed between the two programs: the id of a new reference, as long as it is a version 4 UUID.
norm() { sed -E 's/"id": "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"/"id": "UUID4"/'; }

side() {  # <tag> <program words...>
  local tag=$1; shift
  rm -rf "$RUN"; chmod -R u+rwx "$RUN" 2> /dev/null
  cp -RPp "$TEMPLATE" "$RUN" || { echo "rust-session-parity: cannot copy the tree" >&2; exit 2; }
  if [ -n "$SETUP" ]; then ( cd "$RUN" && eval "$SETUP" ) || { echo "rust-session-parity: setup failed: $SETUP" >&2; exit 2; }; fi
  rm -f "$MARK"
  ( cd "$RUN/$CWD" && exec env -i "PATH=$BIN:/usr/bin:/bin" "HOME=$RUN/home" "TMPDIR=$RUN/tmp" "TA_STATE_DIR=$RUN/st" "TAGENTS_CONFIG_DIR=$RUN/cfg" "TAGENTS_LOCALE=$LOCALE" \
      "TAGENTS_NODE=$SHIM/node" "PARITY_MARK=$MARK" "PARITY_REAL_NODE=$NODE" "PARITY_REC=$RUN/rec" "${EXTRA[@]}" "$@" "${ARGS[@]}" < /dev/null ) 2> "$TMP/err.$tag" | norm > "$TMP/out.$tag"
  echo "${PIPESTATUS[0]}" > "$TMP/code.$tag"
  if [ -e "$MARK" ]; then echo node > "$TMP/via.$tag"; else echo own > "$TMP/via.$tag"; fi
  ls -A "$RUN/rec" | wc -l | tr -d ' ' > "$TMP/started.$tag"
  snapshot | norm > "$TMP/tree.$tag"
  chmod -R u+rwx "$RUN" 2> /dev/null
}

# A scenario: `sc <label> <via> <node's exit code, or - for any> <text node prints, or -> -- <the words after the program name>`.
# <via> is who must answer on the Rust side: rust or node.
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
  if [ -n "$SHOW" ]; then
    local side_name
    for side_name in node rust; do
      printf '  --- %s, %s: exit %s\n' "$label" "$side_name" "$(cat "$TMP/code.$side_name")"
      { printf 'stdout\n'; cut -c1-"$SHOW" "$TMP/out.$side_name"; printf 'stderr\n'; cut -c1-"$SHOW" "$TMP/err.$side_name"; } | sed 's/^/  | /'
    done
  fi

  if [ "$want" != - ] && [ "$(cat "$TMP/code.node")" != "$want" ]; then
    bad "tripwire $label: node exited $(cat "$TMP/code.node"), this scenario exists to provoke $want" "stderr: $(head -c 200 "$TMP/err.node" | tr '\n' '|')"
  fi
  if [ "$needle" != - ] && ! cat "$TMP/out.node" "$TMP/err.node" | grep -qF -- "$needle"; then
    bad "tripwire $label: node did not print what this scenario exists to provoke" "wanted: $needle" "stdout: $(head -c 200 "$TMP/out.node" | tr '\n' '|')" "stderr: $(head -c 200 "$TMP/err.node" | tr '\n' '|')"
  fi
  if [ "$(cat "$TMP/started.node")" != 0 ] || [ "$(cat "$TMP/started.rust")" != 0 ]; then
    bad "$label: something was started (rec/ holds $(cat "$TMP/started.node") files after node, $(cat "$TMP/started.rust") after the binary), these verbs start nothing"
  fi

  if [ -z "$SELF_TEST" ]; then
    local answered; answered=$(cat "$TMP/via.rust")
    if [ "$answered" = node ]; then handed_over=$((handed_over + 1)); else rust_served=$((rust_served + 1)); fi
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
# Run in the run's directory, before the program. A setup is built from these, and what it writes is the tree the program sees.
# A state record: st/<key>.tsv holds these tab separated fields (the first six are what the reader needs, more are the account, the pid, ...).
row() {  # <key> <fields...>
  local key=$1; shift
  local line; line=$(IFS=$'\t'; printf '%s' "$*")
  printf 'printf "%%s\\n" %q > st/%s.tsv; ' "$line" "$key"
}
# The same, with a text that is written as it is: no newline added, so a record may be cut anywhere.
rowraw() {  # <key> <text, printf's escapes understood>
  printf 'printf %q > st/%s.tsv; ' "$2" "$1"
}
# A line of history.tsv: at, kind, session id, pane, label, cwd.
hist() {  # <fields...>
  local line; line=$(IFS=$'\t'; printf '%s' "$*")
  printf 'printf "%%s\\n" %q >> st/history.tsv; ' "$line"
}
# The text of a reference that names a transcript of the tree, and the one that names a Claude session.
ref_transcript() { printf '{"id":"r1","claudeSessionId":null,"transcript":"%s/tr/%s","spec":{"kind":"claude","cwd":"%s/work","skipPermissions":false}}' "$RUN" "$1" "$RUN"; }
ref_session() { printf '{"id":"r1","claudeSessionId":"%s","transcript":null,"spec":{"kind":"claude","cwd":"%s/work","skipPermissions":false}}' "$1" "$RUN"; }
PLAIN="$RUN/tr/plain.jsonl"

# ------------------------------------------------------------------- open ---
t "open: every option"
sc "open-all-options" rust 0 '"skipPermissions": true' -- session open --cwd "$RUN/work" --resume sid-1 --label L --model opus --effort high --system-prompt-file /p/sys.md --mcp-config /p/mcp.json --config-dir /acct --skip-permissions
sc "open-minimal" rust 0 '"id": "UUID4"' -- session open --cwd "$RUN/work"
sc "open-inline-values" rust 0 '"model": "opus"' -- session open --cwd="$RUN/work" --model=opus --effort=high --label=a=b --system-prompt-file=/p/s.md --mcp-config=/p/m.json
sc "open-inline-empty-value" rust 0 '"label": ""' -- session open --cwd "$RUN/work" --label=
sc "open-empty-value" rust 0 '"model": ""' -- session open --cwd "$RUN/work" --model ""
sc "open-repeated-option-last-wins" rust 0 '"label": "b"' -- session open --cwd /a --cwd "$RUN/work" --label a --label=b
sc "open-option-order" rust 0 '"effort": "low"' -- session open --effort low --skip-permissions --cwd "$RUN/work" --model m
sc "open-skip-permissions-first" rust 0 '"skipPermissions": true' -- session open --skip-permissions --cwd "$RUN/work"
sc "open-config-dir-empty" rust 0 '"configDir": ""' -- session open --cwd "$RUN/work" --config-dir ""
sc "open-config-dir-inline-empty" rust 0 '"configDir": ""' -- session open --cwd "$RUN/work" --config-dir=
sc "open-resume-empty" rust 0 '"claudeSessionId": ""' -- session open --cwd "$RUN/work" --resume ""
sc "open-value-with-spaces" rust 0 'two words' -- session open --cwd "$RUN/work" --label "two words" --model " padded "
sc "open-value-with-unicode" rust 0 'é😀' -- session open --cwd "$RUN/work" --label 'é😀 привет'
sc "open-value-with-quote-and-backslash" rust 0 '\"' -- session open --cwd "$RUN/work" --label 'say "x" \ y'
sc "open-value-with-control-characters" rust 0 '\u0007' -- session open --cwd "$RUN/work" --label $'tab\there\nnewline\a bell\x7f'
sc "open-value-with-separator" rust 0 ' ' -- session open --cwd "$RUN/work" --label $'a\xe2\x80\xa8b'
sc "open-value-looks-like-id" rust 0 '"label": "123"' -- session open --cwd "$RUN/work" --label 123
sc "open-value-starts-with-dash-inline" rust 0 '"label": "-x"' -- session open --cwd "$RUN/work" --label=-x
sc "open-value-is-a-lone-dash" node 0 '"label": "-"' -- session open --cwd "$RUN/work" --label -
sc "open-value-is-double-dash-inline" rust 0 '"label": "--"' -- session open --cwd "$RUN/work" --label=--

t "open: the account"
sc "open-no-config-dir" rust 0 '"configDir": null' -- session open --cwd "$RUN/work" --no-config-dir
sc "open-config-dir" rust 0 '"configDir": "/acct"' -- session open --cwd "$RUN/work" --config-dir /acct
sc "open-both-account-flags" rust 2 '--config-dir + --no-config-dir' -- session open --cwd "$RUN/work" --config-dir /acct --no-config-dir
sc "open-both-account-flags-flag-first" rust 2 '--config-dir + --no-config-dir' -- session open --no-config-dir --cwd "$RUN/work" --config-dir=/acct
sc "open-both-account-flags-empty-dir" rust 2 '--config-dir + --no-config-dir' -- session open --cwd "$RUN/work" --config-dir "" --no-config-dir
LOCALE=ru; sc "open-both-account-flags-ru" rust 2 'неизвестный параметр --config-dir + --no-config-dir' -- session open --cwd "$RUN/work" --config-dir /acct --no-config-dir

t "open: the working directory"
sc "open-missing-cwd" rust 2 'missing required option --cwd' -- session open
sc "open-missing-cwd-with-other-options" rust 2 'missing required option --cwd' -- session open --label a --skip-permissions
sc "open-empty-cwd" rust 2 'missing required option --cwd' -- session open --cwd ""
sc "open-inline-empty-cwd" rust 2 'missing required option --cwd' -- session open --cwd=
sc "open-account-flags-before-cwd-check" rust 2 'missing required option --cwd' -- session open --config-dir /a --no-config-dir
LOCALE=ru; sc "open-missing-cwd-ru" rust 2 'не хватает обязательного параметра --cwd' -- session open
CWD=work; sc "open-relative-cwd" rust 0 "$RUN/work/x" -- session open --cwd ./x
CWD=work; sc "open-relative-cwd-bare" rust 0 "$RUN/work/x" -- session open --cwd x
CWD=work; sc "open-relative-cwd-parent" rust 0 "\"cwd\": \"$RUN\"" -- session open --cwd ..
CWD=work; sc "open-relative-cwd-dot" rust 0 "\"cwd\": \"$RUN/work\"" -- session open --cwd .
CWD=work; sc "open-relative-cwd-dot-segments" rust 0 "$RUN/y" -- session open --cwd ./a/../../y/./
CWD=work; sc "open-relative-cwd-above-root" rust 0 '"cwd": "/tmp-does-not-exist"' -- session open --cwd "$(printf '../%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)tmp-does-not-exist"
sc "open-absolute-cwd-trailing-slash" rust 0 "\"cwd\": \"$RUN/work\"" -- session open --cwd "$RUN/work/"
sc "open-absolute-cwd-double-slash" rust 0 "\"cwd\": \"$RUN/work\"" -- session open --cwd "$RUN//work///"
sc "open-absolute-cwd-dot-segments" rust 0 "\"cwd\": \"$RUN/work\"" -- session open --cwd "$RUN/work/./x/.."
sc "open-cwd-root" rust 0 '"cwd": "/"' -- session open --cwd /
sc "open-cwd-double-slash-root" rust 0 '"cwd": "/"' -- session open --cwd //
sc "open-cwd-does-not-exist" rust 0 '/nowhere/at/all' -- session open --cwd /nowhere/at/all
sc "open-cwd-tilde-is-a-name" rust 0 "$RUN/~" -- session open --cwd '~'
sc "open-cwd-with-spaces" rust 0 'a b' -- session open --cwd "a b"
sc "open-cwd-with-unicode" rust 0 'é😀' -- session open --cwd 'é😀'

t "open: --resume and the state"
ROW_T=$(row 5 1700000100 working sid-1 "$RUN/work" "$PLAIN" detail)
SETUP=$ROW_T; sc "open-resume-with-state" rust 0 "\"transcript\": \"$PLAIN\"" -- session open --cwd "$RUN/work" --resume sid-1
sc "open-resume-without-state" rust 0 '"transcript": null' -- session open --cwd "$RUN/work" --resume sid-1
SETUP=$ROW_T; sc "open-resume-other-session" rust 0 '"transcript": null' -- session open --cwd "$RUN/work" --resume sid-2
SETUP=$ROW_T; sc "open-resume-prefix-is-not-a-session" rust 0 '"transcript": null' -- session open --cwd "$RUN/work" --resume sid
SETUP=$(row 5 1700000100 working sid-1 "$RUN/work" "" detail); sc "open-resume-row-without-transcript" rust 0 '"transcript": null' -- session open --cwd "$RUN/work" --resume sid-1
SETUP="$(row 5 1700000100 working sid-1 "$RUN/work" "" detail)$(row 6 1700000200 done sid-1 "$RUN/work" "$RUN/tr/ru.jsonl" detail)"; sc "open-resume-newest-row-wins" rust 0 "ru.jsonl" -- session open --cwd "$RUN/work" --resume sid-1
SETUP="$(row 5 1700000300 working sid-1 "$RUN/work" "" detail)$(row 6 1700000200 done sid-1 "$RUN/work" "$RUN/tr/ru.jsonl" detail)"; sc "open-resume-skips-a-newer-row-without-transcript" rust 0 "ru.jsonl" -- session open --cwd "$RUN/work" --resume sid-1
SETUP="$(row s-sid-1 1700000100 done sid-1 "$RUN/work" "$PLAIN" detail)"; sc "open-resume-headless-row" rust 0 "plain.jsonl" -- session open --cwd "$RUN/work" --resume sid-1
SETUP="$(row 5 1700000100 subdone sid-1 "$RUN/work" "$PLAIN" detail)"; sc "open-resume-subdone-row" rust 0 "plain.jsonl" -- session open --cwd "$RUN/work" --resume sid-1
SETUP="$(row 5 junk working sid-1 "$RUN/work" "$PLAIN" detail)"; sc "open-resume-broken-row" rust 0 '"transcript": null' -- session open --cwd "$RUN/work" --resume sid-1
SETUP="$(row 5 1700000100 working '' "$RUN/work" "$PLAIN" detail)"; sc "open-resume-empty-session-in-a-row" rust 0 '"claudeSessionId": ""' -- session open --cwd "$RUN/work" --resume ''
LOCALE=ru; SETUP=$ROW_T; sc "open-ru" rust 0 "\"transcript\": \"$PLAIN\"" -- session open --cwd "$RUN/work" --resume sid-1

t "open: what node answers itself"
sc "open-unknown-option" node 2 - -- session open --cwd "$RUN/work" --bogus
sc "open-unknown-option-with-value" node 2 - -- session open --cwd "$RUN/work" --bogus value
sc "open-unknown-inline-option" node 2 - -- session open --cwd "$RUN/work" --bogus=1
sc "open-option-without-value" node 2 - -- session open --cwd
sc "open-option-without-value-last" node 2 - -- session open --cwd "$RUN/work" --label
sc "open-value-starts-with-dash" node 2 - -- session open --cwd -x
sc "open-value-starts-with-dashes" node 2 - -- session open --cwd "$RUN/work" --label --model
sc "open-short-option" node 2 - -- session open -c "$RUN/work"
sc "open-short-flag" node 2 - -- session open --cwd "$RUN/work" -s
sc "open-positional" node 2 - -- session open "$RUN/work"
sc "open-positional-after-options" node 2 - -- session open --cwd "$RUN/work" extra
sc "open-flag-with-value" node 2 - -- session open --cwd "$RUN/work" --skip-permissions=1
sc "open-no-config-dir-with-value" node 2 - -- session open --cwd "$RUN/work" --no-config-dir=x
sc "open-negated-flag" node 2 - -- session open --cwd "$RUN/work" --no-skip-permissions
sc "open-help" node 2 - -- session open --help
sc "open-double-dash-ends-the-options" rust 0 '"id": "UUID4"' -- session open --cwd "$RUN/work" --
sc "open-double-dash-positional" node 2 - -- session open --cwd "$RUN/work" -- x
sc "open-lone-dash-is-a-positional" node 2 - -- session open --cwd "$RUN/work" -
sc "open-an-argument-that-is-not-utf8" node - - -- session open --cwd "$RUN/work" --label $'\xff'
sc "open-a-cwd-that-is-not-utf8" node - - -- session open --cwd $'/x\xff'
sc "session" node 2 - -- session
sc "session-unknown-verb" node 2 'unknown command: session bogus' -- session bogus
sc "session-unknown-verb-empty" node 2 - -- session ""
sc "session-help" node 2 - -- session --help
sc "session-prompt" node 2 - -- session prompt
sc "session-abort" node 2 - -- session abort
sc "session-open-uppercase" node 2 - -- session OPEN --cwd "$RUN/work"

# ------------------------------------------------------------------- list ---
t "list: the state"
sc "list-empty" rust 0 '[]' -- session list
SETUP='rm -rf st'; sc "list-no-state-directory" rust 0 '[]' -- session list
SETUP='rm -rf st; : > st'; sc "list-state-directory-is-a-file" rust 0 '[]' -- session list
SETUP='rm -rf st; ln -s nowhere st'; sc "list-state-directory-is-a-broken-link" rust 0 '[]' -- session list
SETUP='mkdir -p st/sub st/events.d; : > st/history.tsv; : > st/events.tsv'; sc "list-state-directory-with-no-records" rust 0 '[]' -- session list
STATES="$(row 1 1700000600 new sid-new "$RUN/work" "" "")$(row 2 1700000500 working sid-working "$RUN/work" "" "")$(row 3 1700000400 blocked sid-blocked "$RUN/work" "" "")$(row 4 1700000300 done sid-done "$RUN/work" "" "")$(row 5 1700000200 gone sid-gone "$RUN/work" "" "")$(row 6 1700000100 subdone sid-subdone "$RUN/work" "" "")"
SETUP=$STATES; sc "list-states" rust 0 'sid-working' -- session list
SETUP=$STATES; sc "list-subdone-is-left-out" rust 0 '"claudeSessionId": "sid-gone"' -- session list
SETUP=$STATES; sc "list-state-working" rust 0 'sid-working' -- session list --state working
SETUP=$STATES; sc "list-state-inline" rust 0 'sid-new' -- session list --state=new
SETUP=$STATES; sc "list-state-two" rust 0 'sid-done' -- session list --state done --state=gone
SETUP=$STATES; sc "list-state-repeated" rust 0 'sid-blocked' -- session list --state working --state blocked --state working
SETUP=$STATES; sc "list-state-all-five" rust 0 'sid-gone' -- session list --state new --state working --state blocked --state done --state gone
SETUP=$STATES; sc "list-state-none-match" rust 0 '[]' -- session list --state working --label nobody
SETUP=$STATES; sc "list-state-and-label" rust 0 '[]' -- session list --state new --label x
SETUP=$STATES; sc "list-key-order-and-layout" rust 0 '"skipPermissions": false' -- session list
SETUP=$STATES; sc "list-state-new-only" rust 0 '"id": "1"' -- session list --state new

t "list: an unknown state"
SETUP=$STATES; sc "list-bad-state" rust 2 'unknown option --state a,b' -- session list --state a,b
SETUP=$STATES; sc "list-bad-states-two" rust 2 'unknown option --state a,b' -- session list --state a --state b
SETUP=$STATES; sc "list-bad-state-among-good" rust 2 'unknown option --state bogus' -- session list --state working --state bogus
SETUP=$STATES; sc "list-bad-state-subdone" rust 2 'unknown option --state subdone' -- session list --state subdone
SETUP=$STATES; sc "list-bad-state-empty" rust 2 'unknown option --state ' -- session list --state ""
SETUP=$STATES; sc "list-bad-state-uppercase" rust 2 'unknown option --state Working' -- session list --state Working
SETUP=$STATES; sc "list-bad-state-padded" rust 2 'unknown option --state  working' -- session list --state " working"
SETUP=$STATES; sc "list-bad-state-comma-list-of-good" rust 2 'unknown option --state working,done' -- session list --state working,done
SETUP=$STATES; sc "list-bad-state-before-label" rust 2 'unknown option --state x' -- session list --label a --state x
SETUP=$STATES; sc "list-bad-state-with-unicode" rust 2 'unknown option --state é😀' -- session list --state 'é😀'
LOCALE=ru; SETUP=$STATES; sc "list-ru" rust 2 'неизвестный параметр --state a,b' -- session list --state a,b
LOCALE=ru; SETUP=$STATES; sc "list-ru-ok" rust 0 'sid-working' -- session list --state working

t "list: the label"
HIST="$(hist 1700000001 start sid-working %1 build "$RUN/work")$(hist 1700000002 turn sid-working %1 build "$RUN/work")$(hist 1700000003 start sid-done %2 review "$RUN/work")$(hist 1700000004 start sid-new %3 '' "$RUN/work")"
SETUP="$STATES$HIST"; sc "list-label" rust 0 '"label": "build"' -- session list
SETUP="$STATES$HIST"; sc "list-label-filter" rust 0 'sid-working' -- session list --label build
SETUP="$STATES$HIST"; sc "list-label-filter-inline" rust 0 'sid-done' -- session list --label=review
SETUP="$STATES$HIST"; sc "list-label-filter-none" rust 0 '[]' -- session list --label Build
SETUP="$STATES$HIST"; sc "list-label-filter-empty" rust 0 'sid-new' -- session list --label ""
SETUP="$STATES$HIST"; sc "list-label-filter-repeated" rust 0 'sid-working' -- session list --label review --label build
SETUP="$STATES$HIST"; sc "list-label-and-state" rust 0 'sid-done' -- session list --label review --state done
SETUP="$STATES$HIST"; sc "list-label-and-state-disjoint" rust 0 '[]' -- session list --label review --state working
SETUP="$STATES$(hist 1 start sid-working %1 first "$RUN/work")$(hist 2 start sid-working %1 second "$RUN/work")"; sc "list-label-last-history-line-wins" rust 0 'second' -- session list
SETUP="$STATES$(hist 1 start sid-working %1 'a b' "$RUN/work")"; sc "list-label-with-space" rust 0 'a b' -- session list --label 'a b'
SETUP="$STATES$(hist 1 start sid-working %1 'é😀' "$RUN/work")"; sc "list-label-with-unicode" rust 0 'é😀' -- session list --label 'é😀'
SETUP="$STATES$(hist 1 start sid-working %1 'say "x"' "$RUN/work")"; sc "list-label-with-quotes" rust 0 'say \"x\"' -- session list
SETUP="$STATES$(hist 1 kind sid-working %1 bad "$RUN/work")"; sc "list-label-history-line-with-a-bad-kind" rust 0 '[' -- session list
SETUP="$STATES$(hist 1700000001 start sid-working %1)"; sc "list-label-history-line-too-short" rust 0 '[' -- session list
SETUP="$STATES$(hist x start sid-working %1 build "$RUN/work")"; sc "list-label-history-line-with-a-bad-time" rust 0 '[' -- session list
SETUP="$STATES"'printf "1700000001\tstart\tsid-working\t%%1\tcrlf\t/w\r\n" >> st/history.tsv'; sc "list-label-history-with-crlf" rust 0 '[' -- session list
SETUP="$STATES"'mkdir -p st/history.tsv'; sc "list-label-history-is-a-directory" rust 0 '[' -- session list
SETUP="$STATES$(hist 1 start sid-working %1 build "$RUN/work")"; sc "list-label-filter-with-lookalike" rust 0 '[]' -- session list --label 'build '

t "list: broken records and the columns"
SETUP="$(row 1 1700000100 working sid-1 /w '' d)$(rowraw 2 'garbage')$(rowraw 3 '')$(row 4 nan working sid-4 /w '' d)$(row 5 1700000100 bogus sid-5 /w '' d)$(row 6 1700000100 working sid-6 /w)$(row 7 1700000100 working sid-7 /w '' d)"
sc "list-broken-record" rust 0 'sid-7' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d)$(rowraw 2 '1700000100\tworking\tsid-2\t/w\t\td')"; sc "list-record-without-a-newline" rust 0 'sid-2' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d)$(rowraw 2 '1700000100\tworking\tsid-2\t/w\t\td\r\n')"; sc "list-record-with-crlf" rust 0 'sid-2' -- session list
SETUP="$(rowraw 1 '1700000100\tworking\tsid-1\t/w\t\td\nsecond line\n')"; sc "list-record-with-two-lines" rust 0 'sid-1' -- session list
SETUP="$(rowraw 1 '\n1700000100\tworking\tsid-1\t/w\t\td\n')"; sc "list-record-starting-with-an-empty-line" rust 0 '[]' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d)"; sc "list-six-columns" rust 0 '"skipPermissions": false' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d '')"; sc "list-seven-columns-account-empty" rust 0 '"configDir": null' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d /acct)"; sc "list-seven-columns-account-set" rust 0 '"configDir": "/acct"' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d /acct 4242 /log build 2 psid)"; sc "list-twelve-columns" rust 0 '"configDir": "/acct"' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d /acct 4242 /log build)$(hist 1 start sid-1 %1 history "$RUN/work")"; sc "list-label-of-the-record-is-not-used" rust 0 'history' -- session list
SETUP="$(row 1 1700000100 working '' /w '' d)"; sc "list-record-with-no-session" rust 0 '"claudeSessionId": null' -- session list
SETUP="$(row 1 1700000100 working sid-1 '' '' d)"; sc "list-record-with-no-cwd" rust 0 '"cwd": ""' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w "$PLAIN" d)"; sc "list-record-with-a-transcript" rust 0 "$PLAIN" -- session list
SETUP="$(row s-abc.def_1 1700000100 working sid-1 /w '' d)"; sc "list-headless-key" rust 0 '"id": "s-abc.def_1"' -- session list
SETUP="$(row 007 1700000100 working sid-1 /w '' d)"; sc "list-key-with-leading-zeros" rust 0 '"id": "007"' -- session list
SETUP="$(row s-é 1700000100 working sid-1 /w '' d)$(row 1x 1700000100 working sid-2 /w '' d)$(row s- 1700000100 working sid-3 /w '' d)$(row S-a 1700000100 working sid-4 /w '' d)"; sc "list-keys-that-are-not-keys" rust 0 '[]' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d)"'cp st/1.tsv st/2.tsv.bak; cp st/1.tsv st/3'; sc "list-files-that-are-not-records" rust 0 'sid-1' -- session list
SETUP="$(row 1 1700000100.5 working sid-1 /w '' d)$(row 2 1.7e9 working sid-2 /w '' d)$(row 3 ' 1700000000' working sid-3 /w '' d)"; sc "list-times-that-are-numbers" rust 0 '[' -- session list
SETUP="$(row 1 1700000100 working 'é😀' '/w é' '/t é' 'd é' '/a é')"; sc "list-unicode" rust 0 'é😀' -- session list
SETUP="$(row 1 1700000100 working 'a"b' '/w\x' '' d)"; sc "list-escapes" rust 0 'a\"b' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d)$(row 2 1700000200 working sid-2 /w '' d)$(row 3 1700000300 working sid-3 /w '' d)"; sc "list-newest-first" rust 0 'sid-3' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d)"'chmod 000 st/1.tsv'; sc_user "list-unreadable-record" rust 0 '[]' -- session list
SETUP="$STATES"'chmod 000 st'; sc_user "list-unreadable-state-directory" rust 0 '[]' -- session list
SETUP="$(row 1 1700000100 working sid-1 /w '' d)"'ln -s ../outside st/2.tsv; ln -s 1.tsv st/3.tsv'; sc "list-links" rust 0 'sid-1' -- session list
sc "list-positional" node 2 - -- session list x
sc "list-unknown-option" node 2 - -- session list --bogus
sc "list-option-without-value" node 2 - -- session list --label
sc "list-state-without-value" node 2 - -- session list --state
sc "list-value-starts-with-dash" node 2 - -- session list --label -x
sc "list-short-option" node 2 - -- session list -l x
sc "list-double-dash-ends-the-options" rust 0 '[]' -- session list --
sc "list-double-dash-positional" node 2 - -- session list -- x
sc "list-an-argument-that-is-not-utf8" node - - -- session list --label $'\xff'
EXTRA=("TA_STATE_DIR="); SETUP="mkdir -p home/.claude/agent-state; $(row 1 1700000100 working sid-1 /w '' d | sed 's#st/#home/.claude/agent-state/#')"; sc "list-empty-state-variable-means-the-default" rust 0 'sid-1' -- session list
EXTRA=("TA_STATE_DIR=   "); SETUP="mkdir -p home/.claude/agent-state; $(row 1 1700000100 working sid-1 /w '' d | sed 's#st/#home/.claude/agent-state/#')"; sc "list-blank-state-variable-means-the-default" rust 0 'sid-1' -- session list
EXTRA=("TA_STATE_DIR=st"); SETUP="$(row 1 1700000100 working sid-1 /w '' d)"; sc "list-relative-state-directory" rust 0 'sid-1' -- session list

# ------------------------------------------------------------------- last ---
t "last: the transcript of a reference"
sc "last-transcript" rust 0 'the last reply' -- session last "$(ref_transcript plain.jsonl)"
sc "last-transcript-ru" rust 0 'ответ: привет, мир 😀' -- session last "$(ref_transcript ru.jsonl)"
sc "last-transcript-no-newline" rust 0 'no final newline' -- session last "$(ref_transcript no-newline.jsonl)"
sc "last-transcript-two-blocks" rust 0 'two' -- session last "$(ref_transcript two-blocks.jsonl)"
sc "last-transcript-junk-lines" rust 0 'after junk' -- session last "$(ref_transcript junk.jsonl)"
sc "last-transcript-controls" rust 0 '\u0007' -- session last "$(ref_transcript controls.jsonl)"
sc "last-transcript-pair-and-escapes" rust 0 '\u0000' -- session last "$(ref_transcript pair.jsonl)"
sc "last-transcript-inside-the-window" rust 0 'inside the window' -- session last "$(ref_transcript at-window.jsonl)"
sc "last-transcript-cut-in-a-character" rust 0 'after a cut' -- session last "$(ref_transcript cut-char.jsonl)"
sc "last-transcript-invalid-utf8" rust 0 'a' -- session last "$(ref_transcript bad-utf8.jsonl)"
sc "last-reference-with-spaces-before" rust 0 'the last reply' -- session last "  $(ref_transcript plain.jsonl)"
sc "last-reference-with-newline-before" rust 0 'the last reply' -- session last "$(printf '\n\t')$(ref_transcript plain.jsonl)"
sc "last-reference-with-trailing-text" rust 1 'no session matches' -- session last "$(ref_transcript plain.jsonl) trailing"
LOCALE=ru; sc "last-transcript-and-ru" rust 0 'the last reply' -- session last "$(ref_transcript plain.jsonl)"

t "last: no reply"
sc "last-no-transcript" rust 0 'null' -- session last "$(ref_session nobody)"
sc "last-transcript-is-missing" rust 0 'null' -- session last "$(ref_transcript missing.jsonl)"
sc "last-transcript-is-empty" rust 0 'null' -- session last "$(ref_transcript empty.jsonl)"
sc "last-transcript-without-assistant" rust 0 'null' -- session last "$(ref_transcript no-assistant.jsonl)"
sc "last-transcript-blank-text" rust 0 'null' -- session last "$(ref_transcript blank-text.jsonl)"
sc "last-transcript-before-the-window" rust 0 'null' -- session last "$(ref_transcript before-window.jsonl)"
sc "last-transcript-empty-path" rust 0 'null' -- session last '{"id":"r1","claudeSessionId":null,"transcript":"","spec":{"kind":"claude","cwd":"/w","skipPermissions":false}}'
sc "last-transcript-relative-path" rust 0 'the last reply' -- session last '{"id":"r1","claudeSessionId":null,"transcript":"tr/plain.jsonl","spec":{"kind":"claude","cwd":"/w","skipPermissions":false}}'
sc "last-transcript-is-null-and-no-session" rust 0 'null' -- session last '{"id":"r1","claudeSessionId":null,"transcript":null,"spec":{"kind":"claude","cwd":"/w","skipPermissions":false}}'
sc "last-transcript-is-null-and-empty-session" rust 0 'null' -- session last '{"id":"r1","claudeSessionId":"","transcript":null,"spec":{"kind":"claude","cwd":"/w","skipPermissions":false}}'

t "last: a lone surrogate"
sc "last-lone-surrogate-high" rust 0 '\ud83d' -- session last "$(ref_transcript lone-high.jsonl)"
sc "last-lone-surrogate-low" rust 0 '\ude00' -- session last "$(ref_transcript lone-low.jsonl)"
sc "last-lone-surrogate-trimmed" rust 0 '\ud83d' -- session last "$(ref_transcript lone-and-trim.jsonl)"

t "last: a transcript that cannot be read"
SETUP='chmod 000 tr/plain.jsonl'; sc_user "last-unreadable" rust 1 'EACCES' -- session last "$(ref_transcript plain.jsonl)"
sc "last-transcript-is-a-directory" rust 1 'EISDIR' -- session last "$(ref_transcript a-directory.jsonl)"
SETUP='chmod 000 tr'; sc_user "last-unreadable-directory" rust 0 'null' -- session last "$(ref_transcript plain.jsonl)"
SETUP='ln -s nowhere tr/broken.jsonl'; sc "last-transcript-is-a-broken-link" rust 0 'null' -- session last "$(ref_transcript broken.jsonl)"
SETUP='ln -s plain.jsonl tr/link.jsonl'; sc "last-transcript-is-a-link" rust 0 'the last reply' -- session last "$(ref_transcript link.jsonl)"

t "last: the transcript of a state record"
ROWS="$(row 5 1700000100 working sid-1 "$RUN/work" "$PLAIN" detail)$(row s-sid-2 1700000200 done sid-2 "$RUN/work" "$RUN/tr/ru.jsonl" detail)"
SETUP=$ROWS; sc "last-by-state-row" rust 0 'the last reply' -- session last "$(ref_session sid-1)"
SETUP=$ROWS; sc "last-by-state-row-headless" rust 0 'ответ' -- session last "$(ref_session sid-2)"
SETUP=$ROWS; sc "last-by-state-row-without-a-session" rust 0 'null' -- session last "$(ref_session sid-3)"
SETUP=$ROWS; sc "last-by-state-row-the-prefix-is-not-a-session" rust 0 'null' -- session last "$(ref_session sid)"
SETUP=$ROWS; sc "last-by-state-row-transcript-of-the-reference-wins" rust 0 'ответ' -- session last "$(printf '{"id":"r1","claudeSessionId":"sid-1","transcript":"%s/tr/ru.jsonl","spec":{"kind":"claude","cwd":"/w","skipPermissions":false}}' "$RUN")"
SETUP="$(row 5 1700000100 working sid-1 "$RUN/work" "" detail)"; sc "last-by-state-row-without-transcript" rust 0 'null' -- session last "$(ref_session sid-1)"
SETUP="$(row 5 1700000300 working sid-1 "$RUN/work" "" detail)$(row 6 1700000200 done sid-1 "$RUN/work" "$PLAIN" detail)"; sc "last-by-state-row-skips-a-newer-row-without-transcript" rust 0 'the last reply' -- session last "$(ref_session sid-1)"
SETUP="$(row 5 1700000100 subdone sid-1 "$RUN/work" "$PLAIN" detail)"; sc "last-by-state-row-subdone" rust 0 'the last reply' -- session last "$(ref_session sid-1)"
SETUP="$(row 5 1700000100 working sid-1 "$RUN/work" "$RUN/tr/missing.jsonl" detail)"; sc "last-by-state-row-transcript-is-missing" rust 0 'null' -- session last "$(ref_session sid-1)"

t "last: a session id in place of a reference"
SETUP=$ROWS; sc "last-id-is-a-claude-session" rust 0 'the last reply' -- session last sid-1
SETUP=$ROWS; sc "last-id-is-a-key" rust 0 'the last reply' -- session last 5
SETUP=$ROWS; sc "last-id-is-a-headless-key" rust 0 'ответ' -- session last s-sid-2
SETUP=$ROWS; sc "last-id-is-a-prefix" rust 0 'ответ' -- session last sid-
SETUP="$(row 5 1700000100 working abc1 "$RUN/work" "$PLAIN" d)$(row 6 1700000200 working abc2 "$RUN/work" "$RUN/tr/ru.jsonl" d)"; sc "last-prefix-first-in-order" rust 0 'ответ' -- session last abc
SETUP="$(row 5 1700000100 working abc1 "$RUN/work" "$PLAIN" d)$(row 6 1700000200 working abc2 "$RUN/work" "$RUN/tr/ru.jsonl" d)"; sc "last-prefix-that-is-unique" rust 0 'the last reply' -- session last abc1
SETUP="$(row 5 1700000100 working abc "$RUN/work" "$PLAIN" d)$(row 6 1700000200 working abcdef "$RUN/work" "$RUN/tr/ru.jsonl" d)"; sc "last-exact-beats-a-prefix-of-an-earlier-row" rust 0 'the last reply' -- session last abc
SETUP="$(row 5 1700000100 working abcdef "$RUN/work" "$PLAIN" d)$(row 6 1700000200 working abc "$RUN/work" "$RUN/tr/ru.jsonl" d)"; sc "last-exact-beats-a-prefix-of-a-later-row" rust 0 'ответ' -- session last abc
SETUP="$(row 7 1700000100 working 7 "$RUN/work" "$PLAIN" d)$(row 8 1700000200 working sid-8 "$RUN/work" "$RUN/tr/ru.jsonl" d)"; sc "last-key-matches-exactly" rust 0 'ответ' -- session last 8
SETUP="$(row 7 1700000100 working sid-7 "$RUN/work" "$PLAIN" d)$(row 8 1700000200 working 7 "$RUN/work" "$RUN/tr/ru.jsonl" d)"; sc "last-id-matches-a-key-or-a-session-first-in-order" rust 0 'ответ' -- session last 7
SETUP="$(row 5 1700000100 working '' "$RUN/work" "$PLAIN" d)"; sc "last-a-row-with-no-session-has-no-prefix" rust 1 'no session matches' -- session last s
SETUP="$(row 5 1700000100 subdone sid-1 "$RUN/work" "$PLAIN" d)"; sc "last-a-subdone-row-is-not-listed" rust 1 'no session matches sid-1' -- session last sid-1
SETUP="$(row 5 1700000100 working sid-1 "$RUN/work" "$PLAIN" d)"; sc "last-id-is-case-sensitive" rust 1 'no session matches SID-1' -- session last SID-1
SETUP="$(row 5 1700000100 working sid-1 "$RUN/work" "$PLAIN" d)"; sc "last-id-with-a-trailing-space" rust 1 'no session matches' -- session last 'sid-1 '
SETUP="$(row 5 1700000100 working 'é😀x' "$RUN/work" "$PLAIN" d)"; sc "last-prefix-is-unicode" rust 0 'the last reply' -- session last 'é😀'
SETUP="$(row 5 1700000100 working 'é😀x' "$RUN/work" "$PLAIN" d)"; sc "last-prefix-is-half-an-emoji" rust 1 'no session matches' -- session last $'\xf0\x9f'
SETUP="$(row 5 1700000100 working sid-1 "$RUN/work" "$PLAIN" d)"; sc "last-id-looks-like-an-option" rust 0 'the last reply' -- session last sid-1 --bogus
SETUP="$(row 5 1700000100 working -x "$RUN/work" "$PLAIN" d)"; sc "last-id-is-an-option-looking-session" rust 0 'the last reply' -- session last -x
SETUP="$(row 5 1700000100 working sid-1 "$RUN/work" "$PLAIN" d)"; sc "last-id-and-more-words" rust 0 'the last reply' -- session last sid-1 more words
SETUP="$(row 5 1700000100 working -- "$RUN/work" "$PLAIN" d)"; sc "last-double-dash-is-the-reference" rust 0 'the last reply' -- session last --
SETUP="$(row 5 1700000100 working sid-1 "$RUN/work" "$PLAIN" d)"; sc "last-id-from-a-unicode-argument" rust 1 'no session matches é' -- session last 'é'

t "last: a reference that does not name a session"
sc "last-bad-ref" rust 1 'no session matches {bad' -- session last '{bad'
sc "last-bad-ref-schema" rust 1 'no session matches {"id":1}' -- session last '{"id":1}'
sc "last-bad-ref-empty-object" rust 1 'no session matches {}' -- session last '{}'
sc "last-bad-ref-kind" rust 1 'no session matches' -- session last '{"id":"r1","claudeSessionId":null,"transcript":null,"spec":{"kind":"other","cwd":"/w","skipPermissions":false}}'
sc "last-bad-ref-missing-spec" rust 1 'no session matches' -- session last '{"id":"r1","claudeSessionId":null,"transcript":null}'
sc "last-bad-ref-trailing-comma" rust 1 'no session matches' -- session last '{"id":"r1","claudeSessionId":null,"transcript":null,"spec":{"kind":"claude","cwd":"/w","skipPermissions":false},}'
sc "last-bad-ref-array" rust 1 'no session matches [' -- session last '[]'
sc "last-bad-ref-not-an-object-after-spaces" rust 1 'no session matches' -- session last '   {'
sc "last-bad-ref-spaces-only-is-a-session-id" rust 1 'no session matches' -- session last '   '
sc "last-bad-ref-with-unicode" rust 1 'no session matches {é😀' -- session last '{é😀'
sc "last-bad-ref-with-a-newline" rust 1 'no session matches' -- session last $'{\n}'
LOCALE=ru; sc "last-bad-ref-ru" rust 1 'сессия не найдена: {bad' -- session last '{bad'
LOCALE=ru; sc "last-missing-ref-ru" rust 2 'не хватает обязательного параметра <ref>' -- session last
sc "last-missing-ref" rust 2 'missing required option <ref>' -- session last
sc "last-empty-ref" rust 2 'missing required option <ref>' -- session last ""
sc "last-unknown-ref" rust 1 'no session matches nobody' -- session last nobody
sc "last-an-argument-that-is-not-utf8" node - - -- session last $'\xff'
sc "last-a-reference-with-a-lone-surrogate-escape" node - - -- session last '{"id":"\ud83d","claudeSessionId":null,"transcript":null,"spec":{"kind":"claude","cwd":"/w","skipPermissions":false}}'
sc "last-a-reference-with-a-lone-surrogate-escape-in-a-key" node - - -- session last '{"id":"r1","claudeSessionId":null,"transcript":null,"spec":{"kind":"claude","cwd":"/w","skipPermissions":false},"\ud83d":1}'
sc "last-a-reference-with-a-lone-surrogate-in-the-transcript" node - - -- session last '{"id":"r1","claudeSessionId":null,"transcript":"/t\ud83d.jsonl","spec":{"kind":"claude","cwd":"/w","skipPermissions":false}}'
sc "last-a-reference-with-a-nul" node - - -- session last '{"id":"r1","claudeSessionId":null,"transcript":null,"spec":{"kind":"claude","cwd":"/w\u0000","skipPermissions":false}}'
sc "last-a-reference-with-an-empty-bin" node - - -- session last '{"id":"r1","claudeSessionId":null,"transcript":null,"spec":{"kind":"claude","cwd":"/w","skipPermissions":false,"bin":""}}'
sc "last-a-reference-with-a-bad-env-name" node - - -- session last '{"id":"r1","claudeSessionId":null,"transcript":null,"spec":{"kind":"claude","cwd":"/w","skipPermissions":false,"env":{"A=B":"1"}}}'

printf '\nrust-session-parity: %d passed, %d failed, %d skipped' "$pass" "$fail" "$skipped"
if [ -z "$SELF_TEST" ]; then
  printf '; answered by the binary: %d, handed to node: %d\n' "$rust_served" "$handed_over"
else
  printf ' (self test: node on both sides)\n'
fi
[ "$fail" -eq 0 ]
