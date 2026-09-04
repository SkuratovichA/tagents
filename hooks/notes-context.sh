#!/bin/sh
# Claude Code hook — the notes workspace, on its way into the prompt.
#
# Registered on `UserPromptSubmit` and `SessionStart`. Prints the JSON that
# Claude Code splices into the conversation as extra context, or nothing at all.
#
# WHY A DIFF AND NOT A FILE. The notes folder (`<repo>/.claude/notes`) is a git
# repo of its own that both sides write: Claude drops documents there, the user
# opens them in neovim and writes back — corrections, questions, "no, do it the
# other way" — as ordinary lines in the file. Re-reading the whole folder every
# turn would be expensive and, worse, would not say what CHANGED; a diff since
# the last turn says exactly that, and the user's remarks arrive as `+` lines,
# which is the cheapest possible way to point at "this is what they wrote".
#
# The bookkeeping is one sha in `.git/ta-last-seen` — inside `.git`, so it is
# never a tracked file and never shows up in the diff it controls. The
# autocommit hook advances the same marker for Claude's OWN writes, so only
# commits the user made are ever unseen.

set -u

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# Unit separator, as in the state hook: tab is IFS whitespace, so an empty cwd
# would collapse and shift the next field into its slot.
us=$(printf '\037')
line=$(printf '%s' "$payload" | jq -r --arg us "$us" '
  [ (.hook_event_name // ""), (.cwd // "") ] | join($us)
' 2>/dev/null) || exit 0
[ -n "$line" ] || exit 0

IFS="$us" read -r event cwd <<EOF
$line
EOF

[ -n "${cwd:-}" ] || exit 0

# The prompt is submitted from wherever the user happens to be inside the
# project, so the folder is resolved from the repo root, not from the cwd.
notes_dir() {
  _root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || _root=
  [ -n "$_root" ] || _root=$(cd "$1" 2>/dev/null && pwd -P) || _root=
  [ -n "$_root" ] || return 1
  printf '%s/.claude/notes\n' "$_root"
}

dir=$(notes_dir "$cwd") || exit 0
[ -e "$dir/.git" ] || exit 0

standing="Workspace: $dir is a git-versioned notes folder. Documents you produce for the user go there as <name>.md (chat replies stay in chat). The user edits those files in neovim; their edits reach you as diffs on their next prompt, and lines starting with \"+\" in those diffs are their comments to address."

emit() {  # <text>
  printf '%s' "$1" | jq -Rs --arg ev "$event" \
    '{hookSpecificOutput:{hookEventName:$ev,additionalContext:.}}' 2>/dev/null
}

if [ "$event" = "SessionStart" ]; then
  emit "$standing"
  exit 0
fi

[ "$event" = "UserPromptSubmit" ] || exit 0

head=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || head=
[ -n "$head" ] || exit 0            # a folder with no commits yet has nothing to say

marker="$dir/.git/ta-last-seen"
seen=$(cat "$marker" 2>/dev/null) || seen=
if [ "$head" = "$seen" ]; then exit 0; fi

# A marker naming a commit that no longer exists (amend, rebase, a folder that
# was re-created) must not turn every later turn into a git error: fall back to
# "everything", which is what an empty marker means anyway.
if [ -n "$seen" ] && ! git -C "$dir" cat-file -e "${seen}^{commit}" 2>/dev/null; then
  seen=
fi

if [ -n "$seen" ]; then
  base=$seen
  log=$(git -C "$dir" log --format='%h %s' "${seen}..HEAD" 2>/dev/null)
else
  # The empty tree: diffing against it is how "no marker yet" becomes "all of it"
  # without a second code path.
  base=$(git -C "$dir" hash-object -t tree /dev/null 2>/dev/null)
  log=$(git -C "$dir" log --format='%h %s' HEAD 2>/dev/null)
fi
[ -n "$base" ] || exit 0

# prompt.md is the channel the user types INTO the running session (tnotes sends
# it and clears it); it has already been delivered as a prompt, so replaying it
# here would say everything twice.
stat=$(git -C "$dir" diff --stat "$base" HEAD -- . ':!prompt.md' 2>/dev/null)

# Nothing outside prompt.md moved: the commits are accounted for, so bank them
# and stay quiet rather than injecting an empty section.
if [ -z "$stat" ]; then
  printf '%s\n' "$head" >"$marker" 2>/dev/null
  exit 0
fi

body=$(git -C "$dir" diff --no-color "$base" HEAD -- \
  '*.md' '*.txt' '*.markdown' '*.json' '*.yaml' '*.yml' ':!prompt.md' 2>/dev/null)
bytes=$(printf '%s' "$body" | wc -c | tr -d ' ')

# A folder that grew a pasted log or a rewritten book is not context, it is a
# denial of service on the context window — say what moved and let Claude open
# the files it actually needs.
if [ "${bytes:-0}" -gt 60000 ] 2>/dev/null; then
  body="(diff over 60 KB — read the changed files)"
fi

ctx="$standing

The notes folder changed since your last turn.

$log

$stat

$body"

emit "$ctx"
printf '%s\n' "$head" >"$marker" 2>/dev/null
exit 0
