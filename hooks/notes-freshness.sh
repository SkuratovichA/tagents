#!/bin/sh
# Claude Code hook — a notes document is evidence of when it was written.
#
# Registered on `PostToolUse` with matcher `Read`. Prints the JSON that Claude
# Code splices in after the file's content, or nothing at all.
#
# WHY AT READ TIME. Nobody updates a document after the work it describes has
# landed — that is the whole problem, and every scheme that depends on someone
# remembering to has already failed. So nothing here asks for maintenance: the
# staleness is DERIVED, at the one moment anything is about to act on the file.
# A stale note cannot be read without the reader being told it is stale.
#
# WHAT ROTS, AND WHAT DOES NOT. Three things live in these documents and only
# one of them goes bad. Measurements are dated facts about a window of time and
# stay true. Reasoning — why this, why not that, what was rejected — stays true
# as well. What rots is the third kind: claims about what the code currently
# does, and recommendations, because a recommendation that has since been
# implemented still reads as outstanding work. That is the only thing this
# hook's wording asks the reader to distrust.
#
# HOW THE DRIFT IS MEASURED, sharpest first:
#   1. `<!-- pinned: <repo>@<sha> · <paths…> -->` in the first ten lines — the
#      commits that touched exactly the paths the document is about. One line
#      per repository, because the work spans a dozen of them.
#   2. No pin, but the folder above `.claude/notes` is a repository — commits
#      landed anywhere in it since. Coarser, still true.
#   3. Neither — how old it is, which is all that is knowable.
# The "written at" is never declared: the notes folder is a git repo of its own,
# so it is read out of that repo's log and cannot be wrong.
#
# WHAT IT NEVER TOUCHES. It writes no document and rewrites nothing. The only
# file it keeps is a list of what it has already said, inside `.git` so it is
# never tracked and never turns up in the diff the other notes hook produces.

set -uf   # -f: a pinned scope is deliberately unquoted below so several
          # pathspecs split into words; globbing it against the hook's own
          # working directory is the bug that would hide.

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# Unit separator, as in the other hooks: tab is IFS whitespace, so an empty
# field would collapse and shift the next one into its slot.
us=$(printf '\037')
line=$(printf '%s' "$payload" | jq -r --arg us "$us" '
  [ (.hook_event_name // ""), (.tool_name // ""),
    (.tool_input.file_path // ""), (.session_id // "") ] | join($us)
' 2>/dev/null) || exit 0
[ -n "$line" ] || exit 0

IFS="$us" read -r event tool path sid <<EOF
$line
EOF

# ---------------------------------------------------------------------------
#  1. is this even a notes document
# ---------------------------------------------------------------------------
# Cheapest checks first: this fires after EVERY Read in the session, so anything
# that is not a document under a notes folder must cost a case statement and
# nothing else — no git, no stat, no fork.
[ "${tool:-}" = "Read" ] || exit 0
case "${path:-}" in
  */.claude/notes/*.md) ;;
  *) exit 0 ;;
esac
case "${path##*/}" in
  # prompt.md is the channel the user types INTO the session, not a document;
  # ledger.md carries its own sync stamp and a derived block right above the
  # hand-written half, so a second staleness line would only say it twice.
  prompt.md|ledger.md) exit 0 ;;
esac
[ -f "$path" ] || exit 0

dir=${path%%/.claude/notes/*}/.claude/notes
[ -e "$dir/.git" ] || exit 0
parent=${dir%/.claude/notes}

# ---------------------------------------------------------------------------
#  2. once per document per session
# ---------------------------------------------------------------------------
# A document read three times in one session is the same document; the banner
# is worth its forty tokens once. Banked only after it is actually said, so a
# document that goes stale later in the session is still announced then.
seen_file="$dir/.git/ta-freshness-seen"
seen_key="${sid:-?} $path"
grep -qxF "$seen_key" "$seen_file" 2>/dev/null && exit 0

emit() {  # <text> — the only way anything leaves this hook
  { cat "$seen_file" 2>/dev/null; printf '%s\n' "$seen_key"; } | tail -n 500 \
    >"$seen_file.tmp" 2>/dev/null && mv -f "$seen_file.tmp" "$seen_file" 2>/dev/null
  printf '%s' "$1" | jq -Rs --arg ev "${event:-PostToolUse}" \
    '{hookSpecificOutput:{hookEventName:$ev,additionalContext:.}}' 2>/dev/null
  exit 0
}

# ---------------------------------------------------------------------------
#  3. when was it written
# ---------------------------------------------------------------------------
# Out of the notes repo's own log, never out of the file. A document that has
# never been committed was written in this session or is not versioned at all;
# either way there is no claim to make about it.
written=$(git -C "$dir" log -1 --format=%ct -- "$path" 2>/dev/null)
case "${written:-}" in ''|*[!0-9]*) exit 0 ;; esac

now=$(date +%s 2>/dev/null)
case "${now:-}" in ''|*[!0-9]*) exit 0 ;; esac
when=$(date -r "$written" '+%d.%m' 2>/dev/null) || when=
[ -n "$when" ] || when=$(date -d "@$written" '+%d.%m' 2>/dev/null) || when="earlier"

name=${path##*/}
stands="Its measurements and its reasoning hold for that date; treat its claims about current code, and any recommendation it still lists as open, as hypotheses to verify before acting on them."

# ---------------------------------------------------------------------------
#  4. the pin — commits against the paths the document is actually about
# ---------------------------------------------------------------------------
trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# First ten lines only, and anchored at the start of one. A document ABOUT this
# convention quotes the marker in a fenced example, and an example must not be
# mistaken for a pin.
pins=$(sed -n '1,10{/^<!-- pinned:/p;}' "$path" 2>/dev/null)

total=0
resolved=0
detail=
if [ -n "$pins" ]; then
  # A here-document, not a pipe: `while read` on the right of a `|` runs in a
  # subshell and every count below would be thrown away when it ended.
  while IFS= read -r p; do
    spec=${p#<!-- pinned:}
    spec=${spec%-->}
    case "$spec" in *@*) ;; *) continue ;; esac
    repo=$(trim "${spec%%@*}")
    rest=${spec#*@}
    case "$rest" in
      *·*) sha=$(trim "${rest%%·*}"); scope=$(trim "${rest#*·}") ;;
      *)   sha=$(trim "$rest");       scope= ;;
    esac
    [ -n "$repo" ] && [ -n "$sha" ] || continue

    case "$repo" in
      /*)   rp=$repo ;;
      '~'/*) rp=$HOME/${repo#'~'/} ;;
      *)    rp=$parent/$repo ;;
    esac
    [ -d "$rp" ] || continue

    # A pin naming a commit this repository has never heard of is a pin that
    # came loose — a rebase, a renamed repo, a typo. Counting from it would
    # invent a number, so it is skipped and the age signal carries the document
    # instead; a pin that resolves is what earns the silence when nothing moved.
    git -C "$rp" cat-file -e "${sha}^{commit}" 2>/dev/null || continue
    # Unquoted on purpose: several pathspecs in one scope. `set -f` above is
    # what keeps it from globbing against the wrong directory.
    n=$(git -C "$rp" rev-list --count "$sha..HEAD" -- $scope 2>/dev/null)
    case "${n:-}" in ''|*[!0-9]*) continue ;; esac
    resolved=$((resolved + 1))
    [ "$n" -gt 0 ] || continue
    total=$((total + n))
    detail="${detail:+$detail, }${repo##*/} $n"
  done <<EOF
$pins
EOF

  [ "$total" -gt 0 ] && emit "$name was written $when. Since then $total commits touched the paths it pins ($detail). $stands"
  # Every pin resolved and none of them moved: the document is current, and
  # saying anything at all here would be the noise that gets banners ignored.
  [ "$resolved" -gt 0 ] && exit 0
fi

# ---------------------------------------------------------------------------
#  5. no pin: the repository around the notes folder, then bare age
# ---------------------------------------------------------------------------
if git -C "$parent" rev-parse --git-dir >/dev/null 2>&1; then
  n=$(git -C "$parent" rev-list --count HEAD --since="@$written" 2>/dev/null)
  case "${n:-}" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -gt 0 ] && emit "$name was written $when, and ${n} commits have landed in ${parent##*/} since. It pins no paths, so that counts the whole repository rather than the files it is about. $stands"
  exit 0
fi

# Nothing around it to measure against — the personal notes folder, where the
# work it describes lives in some other tree entirely. Age is all there is, and
# saying it every day would be noise, so it waits until the document is old
# enough that the question is worth asking.
age_days=${NF_AGE_DAYS:-14}
case "$age_days" in ''|*[!0-9]*) age_days=14 ;; esac
days=$(( (now - written) / 86400 ))
[ "$days" -ge "$age_days" ] && emit "$name was written $when, $days days ago, and there is no repository beside it to say whether what it describes has moved. $stands"
exit 0
