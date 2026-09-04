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
# The prompt rides along flattened: it is only ever scanned for an @-token, and
# a newline in it would end the one line this read is built on.
line=$(printf '%s' "$payload" | jq -r --arg us "$us" '
  [ (.hook_event_name // ""), (.cwd // ""), (.session_id // ""),
    ((.prompt // "") | split("\n") | join(" ") | split("\r") | join(" ")) ]
  | join($us)
' 2>/dev/null) || exit 0
[ -n "$line" ] || exit 0

IFS="$us" read -r event cwd sid prompt <<EOF
$line
EOF
sent_ctx=

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

# One hook call is one JSON object, so everything this turn has to say is said
# together or not at all.
say() {  # <text> — the turn's context, plus the sent line when there is one
  if [ -n "$sent_ctx" ]; then
    emit "$1

$sent_ctx"
  else
    emit "$1"
  fi
}

# A SESSION THAT STARTED BEFORE THE FOLDER DID NEVER HEARD OF IT. `SessionStart`
# fires once, and it fires early: the folder is often created later in the same
# session, and from then on the only thing that would mention it is a diff — so a
# quiet folder means the session never learns where documents go and writes them
# somewhere else entirely. The prompt path therefore says the standing paragraph
# once per session on its own. Who was told lives in `.git/ta-seen-sessions`,
# beside the marker and inside `.git`, so it is never tracked and never turns up
# in the diff it helps produce.
seen_file="$dir/.git/ta-seen-sessions"
told=1
if [ -n "${sid:-}" ] && ! grep -qxF "$sid" "$seen_file" 2>/dev/null; then told=0; fi

remember() {
  [ "$told" = 0 ] || return 0
  told=1
  { cat "$seen_file" 2>/dev/null; printf '%s\n' "$sid"; } | tail -n 200 \
    >"$seen_file.tmp" 2>/dev/null && mv -f "$seen_file.tmp" "$seen_file" 2>/dev/null
  return 0
}

# The paragraph on its own, for a turn that has no diff to carry it.
nudge() {
  if [ "$told" = 0 ]; then
    say "$standing"
    remember
  elif [ -n "$sent_ctx" ]; then
    emit "$sent_ctx"
  fi
  return 0
}

if [ "$event" = "SessionStart" ]; then
  emit "$standing"
  # Banked here as well: a session told at startup must not hear it again on
  # its first prompt.
  remember
  exit 0
fi

[ "$event" = "UserPromptSubmit" ] || exit 0

# THE SUBMIT IS THE ONLY PLACE A SEND IS VISIBLE. tnotes types
# `@<notes>/prompt.md ` into the input and stops; whether the user then pressed
# Enter, or reopened the editor and rewrote the draft first, is knowable only
# here. So this is where the draft is recorded as sent: a `user:` commit and the
# sha in .git/ta-sent, which is what tells the editor it may start on a blank
# page next time. The file itself is NEVER touched — the CLI reads it after this
# hook returns, and an emptied prompt.md would arrive as an empty attachment.
case "$prompt" in
  *@*/prompt.md*)
    dir_real=$(cd "$dir" 2>/dev/null && pwd -P) || dir_real=$dir
    root=${dir%/.claude/notes}
    for cand in $(printf '%s' "$prompt" | grep -o '@[^[:space:]]*/prompt\.md' 2>/dev/null); do
      cand=${cand#@}
      # A relative mention is resolved the way the CLI resolves it — against the
      # cwd it was typed in — and then against the repo root, which is where the
      # `.claude/notes/…` form the editor suggests actually points from a
      # subdirectory.
      case "$cand" in
        /*) f=$cand ;;
        *)  f=$cwd/$cand; [ -f "$f" ] || f=$root/$cand ;;
      esac
      [ -f "$f" ] || continue
      fd=$(cd "$(dirname "$f")" 2>/dev/null && pwd -P) || continue
      [ "$fd" = "$dir_real" ] || continue
      grep -q '[^[:space:]]' "$dir/prompt.md" 2>/dev/null || continue

      subj=$(awk 'NF { sub(/^[ \t]+/, ""); print substr($0, 1, 72); exit }' \
               "$dir/prompt.md" 2>/dev/null)
      [ -n "$subj" ] || subj='sent'
      # --allow-empty, and on purpose: tnotes already committed this text when
      # the editor quit, so there is usually nothing new in it. The commit being
      # recorded here is not the text, it is the SEND — `user: …` in the log is
      # how a draft that was actually submitted is told apart from one that was
      # merely saved, and it is the commit .git/ta-sent then points at. The
      # pathspec keeps anything else in the index out of it.
      git -C "$dir" add prompt.md >/dev/null 2>&1
      # The same fallback the autocommit hook has: a notes repo is never pushed,
      # and a missing global identity must not be why a send goes unrecorded.
      git -C "$dir" commit -q --allow-empty -m "user: $subj" -- prompt.md >/dev/null 2>&1 ||
        git -C "$dir" -c user.name=tnotes -c user.email=tnotes@localhost \
            commit -q --allow-empty -m "user: $subj" -- prompt.md >/dev/null 2>&1
      git -C "$dir" rev-parse HEAD >"$dir/.git/ta-sent" 2>/dev/null
      sent_ctx="The attached prompt.md is the user's message for this turn — follow it as the instruction."
      break
    done
    ;;
esac

head=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || head=
[ -n "$head" ] || { nudge; exit 0; }   # no commits yet: nothing to diff, still worth naming

marker="$dir/.git/ta-last-seen"
seen=$(cat "$marker" 2>/dev/null) || seen=
if [ "$head" = "$seen" ]; then nudge; exit 0; fi

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
  nudge
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

say "$ctx"
remember
printf '%s\n' "$head" >"$marker" 2>/dev/null
exit 0
