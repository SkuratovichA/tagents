#!/bin/sh
# Claude Code hook — every document Claude writes into the notes folder becomes
# a commit there.
#
# Registered on `PostToolUse` with matcher `Write|Edit|MultiEdit`, async: it is
# never in the critical path of a tool call.
#
# WHY COMMIT AT ALL. The notes folder is a conversation held in files, and the
# other hook (`notes-context.sh`) reports it as "what changed since last turn".
# That only works if there is a commit to measure from: without one, Claude's
# own paragraph would arrive back on the next prompt as a `+` line and read as
# something the USER wrote — the one confusion this pair exists to prevent. So
# the write is committed and the marker is advanced in the same breath, and what
# stays unseen is exactly what the user typed in neovim.
#
# It prints nothing: a hook that talks on every Write would be noise.

set -u

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

us=$(printf '\037')
line=$(printf '%s' "$payload" | jq -r --arg us "$us" '
  [ (.cwd // ""), (.tool_input.file_path // "") ] | join($us)
' 2>/dev/null) || exit 0
[ -n "$line" ] || exit 0

IFS="$us" read -r cwd f <<EOF
$line
EOF

[ -n "${cwd:-}" ] || exit 0
[ -n "${f:-}" ] || exit 0

notes_dir() {
  _root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || _root=
  [ -n "$_root" ] || _root=$(cd "$1" 2>/dev/null && pwd -P) || _root=
  [ -n "$_root" ] || return 1
  printf '%s/.claude/notes\n' "$_root"
}

dir=$(notes_dir "$cwd") || exit 0
[ -e "$dir/.git" ] || exit 0

# git reports the toplevel with symlinks resolved (/private/var, not /var) while
# the tool payload carries whatever path the model typed, so both sides are
# resolved before they are compared — otherwise a file plainly inside the folder
# fails the prefix test on macOS.
fdir=$(cd "$(dirname "$f")" 2>/dev/null && pwd -P) || exit 0
f="$fdir/$(basename "$f")"

# Prefix test with the slash attached, so a sibling `.../notes-archive/x.md` is
# not mistaken for something inside `.../notes/`.
case "$f" in
  "$dir"/*) ;;
  *) exit 0 ;;
esac

rel=${f#"$dir"/}
[ "$rel" = "prompt.md" ] && exit 0   # the user's outbox, cleared by tnotes; not a document
[ -e "$f" ] || exit 0

git -C "$dir" add -- "$f" >/dev/null 2>&1 || exit 0

# An Edit that changed nothing on disk stages nothing; committing anyway would
# fill the log with empty commits and, worse, move the marker past the user's
# unseen work.
if git -C "$dir" diff --cached --quiet 2>/dev/null; then
  exit 0
fi

# THE SAME IDENTITY FALLBACK `tnotes` COMMITS WITH. A machine whose git has no
# global user.name is not a reason to drop Claude's write on the floor: this
# repository is never pushed and never shared, so a placeholder identity is
# harmless, and without the fallback the commit fails silently, the marker never
# advances, and every later diff is computed from the wrong base.
git -C "$dir" commit -q -m "claude: $rel" >/dev/null 2>&1 ||
  git -C "$dir" -c user.name=tnotes -c user.email=tnotes@localhost \
      commit -q -m "claude: $rel" >/dev/null 2>&1 || exit 0

head=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || exit 0
[ -n "$head" ] && printf '%s\n' "$head" >"$dir/.git/ta-last-seen" 2>/dev/null
exit 0
