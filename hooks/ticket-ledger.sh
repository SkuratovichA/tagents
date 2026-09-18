#!/bin/sh
# Claude Code hook — which ticket is this session on, and where is its ledger.
#
# Registered on `SessionStart`. Prints the JSON that Claude Code splices into
# the conversation as extra context, or nothing at all.
#
# WHY THE HOOK AND NOT THE AGENT. A session that has to ask "which ticket am I
# on" spends a tool call on it and only asks when it remembers to. Everything
# needed to answer is already on disk before the first token: the branch name,
# the worktree it was launched in, and the label the dashboard keeps. So the
# answer is resolved here and handed over as sixty tokens of pointer.
#
# WHY A POINTER AND NOT THE FILE. A handover artifact over ~5,000 tokens comes
# back from a compaction as a path instead of its content, which is the moment
# it was supposed to work. The ledger is read by the session when it wants it;
# what this prints is its path, its age, and the next action.
#
# WHAT IT REWRITES. Only the block between the two `derived` markers, which
# holds facts a command can produce — worktree, branch, ahead/behind, dirty
# count, spec stage and drift, PR states. Everything below that block is the
# half no command can produce (decisions, rejected approaches, open questions,
# next action) and is never touched. A ledger with no markers is left alone
# entirely: a hand-written file is not this hook's to edit.
#
# WHAT IT NEVER WAITS ON. `gh` is a network round trip and must not sit in
# front of the first prompt, so PR state is read from a cache that a background
# refresh fills for the NEXT session, stamped before the work so two sessions
# starting together cannot both fire one.

set -u

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# Unit separator, as in the other hooks: tab is IFS whitespace, so an empty cwd
# would collapse and shift the next field into its slot.
us=$(printf '\037')
line=$(printf '%s' "$payload" | jq -r --arg us "$us" '
  [ (.hook_event_name // ""), (.cwd // ""), (.session_id // "") ] | join($us)
' 2>/dev/null) || exit 0
[ -n "$line" ] || exit 0

IFS="$us" read -r event cwd sid <<EOF
$line
EOF

[ -n "${cwd:-}" ] && [ -d "$cwd" ] || exit 0

STATE=${TA_STATE:-$HOME/.claude/agent-state}
PR_TTL=${TL_PR_TTL:-15}          # minutes a cached PR listing is served for
KEY='[A-Z][A-Z0-9]*-[0-9][0-9]*'

# ---------------------------------------------------------------------------
#  1. who am I
# ---------------------------------------------------------------------------
# Branch first: it is what the work is actually on, and it is wrong far less
# often than a name a human typed. The worktree directory second, for the
# session that is sitting in a detached checkout. The dashboard label last,
# because it is the only one that survives a session with no repo yet.
first_key() { grep -oE "$KEY" 2>/dev/null | head -n 1; }

ticket=$(git -C "$cwd" branch --show-current 2>/dev/null | first_key)
[ -n "$ticket" ] || ticket=$(basename "$cwd" | first_key)
[ -n "$ticket" ] || [ -z "${sid:-}" ] || [ ! -s "$STATE/labels.tsv" ] ||
  ticket=$(awk -F'\t' -v s="$sid" '$1 == s { print $2 }' "$STATE/labels.tsv" 2>/dev/null | first_key)
[ -n "$ticket" ] || exit 0

root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || root=
[ -n "$root" ] || root=$(cd "$cwd" 2>/dev/null && pwd -P) || exit 0
led="$root/.claude/notes/$ticket/ledger.md"

emit() {  # <text> — the only way anything leaves this hook
  printf '%s' "$1" | jq -Rs --arg ev "${event:-SessionStart}" \
    '{hookSpecificOutput:{hookEventName:$ev,additionalContext:.}}' 2>/dev/null
  exit 0
}

if [ ! -f "$led" ]; then
  emit "This session looks like $ticket, and it has no ledger yet. If this session learns something worth carrying — a decision and its reason, an approach that was rejected, a question answered, what is left — write it to $led so the next session starts from it instead of from nothing."
fi

# ---------------------------------------------------------------------------
#  2. the facts a command can produce
# ---------------------------------------------------------------------------
branch=$(git -C "$cwd" branch --show-current 2>/dev/null) || branch=
[ -n "$branch" ] || branch='(detached)'
track=$(git -C "$cwd" status -sb 2>/dev/null | sed -n '1s/.*\[\(.*\)\].*/\1/p')
dirty=$(git -C "$cwd" status --porcelain 2>/dev/null | grep -c .) || dirty=0
wt=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || wt="$cwd"

state_line="worktree  $wt — branch \`$branch\`${track:+, $track}${dirty:+, $dirty uncommitted}"

# The spec, and whether it has drifted. openspec's own ledger.yaml is written
# at stage transitions and documented as a cache of git reality, not an
# authority — so the useful thing to print is not the stage alone but how many
# commits have landed in the change directory since that stage was recorded.
spec_line=
for d in "$root"/openspec/changes/*/; do
  [ -d "$d" ] || continue
  case "$d" in *"$(printf '%s' "$ticket" | tr 'A-Z' 'a-z')"*) ;; *)
    grep -qs "$ticket" "$d/proposal.md" "$d/tasks.md" 2>/dev/null || continue ;;
  esac
  stage=$(sed -n 's/^[[:space:]]*stage:[[:space:]]*//p' "$d/ledger.yaml" 2>/dev/null | head -n 1)
  rel=${d#"$root"/}
  if [ -f "$d/ledger.yaml" ]; then
    when=$(git -C "$root" log -1 --format=%cr -- "$d/ledger.yaml" 2>/dev/null)
    since=$(git -C "$root" rev-list --count "HEAD" --since="$(git -C "$root" log -1 --format=%cI -- "$d/ledger.yaml" 2>/dev/null)" -- "$d" 2>/dev/null)
    drift=
    [ "${since:-0}" -gt 1 ] 2>/dev/null && drift=" — $((since - 1)) commits to the change since, STALE"
    spec_line="spec      \`$rel\` — stage \`${stage:-unknown}\`, ledger.yaml written $when$drift"
  else
    spec_line="spec      \`$rel\` — no ledger.yaml"
  fi
  break
done

# PRs: served from cache, never waited on. The stamp is written BEFORE the
# refresh so two sessions starting together cannot both fire one.
pr_line=
prs="$STATE/ledger/prs.$ticket.txt"
mkdir -p "$STATE/ledger" 2>/dev/null
[ -s "$prs" ] && pr_line="PRs       $(cat "$prs")"
if command -v gh >/dev/null 2>&1 && [ -z "$(find "$prs" -mmin "-$PR_TTL" 2>/dev/null)" ]; then
  : >>"$prs" 2>/dev/null
  ( gh search prs "$ticket" --limit 20 --json repository,number,state 2>/dev/null |
      jq -r '[ .[] | "\(.repository.nameWithOwner | split("/") | last)#\(.number) \(.state | ascii_downcase)" ] | join(" · ")' \
      >"$prs.new" 2>/dev/null && [ -s "$prs.new" ] && mv -f "$prs.new" "$prs" || rm -f "$prs.new" ) >/dev/null 2>&1 &
fi

# ---------------------------------------------------------------------------
#  3. rewrite the derived block, and only that
# ---------------------------------------------------------------------------
if grep -q '^<!-- derived' "$led" 2>/dev/null && grep -q '^<!-- /derived -->' "$led" 2>/dev/null; then
  tmp="$led.tl.$$"
  {
    printf '## State · synced %s\n' "$(date '+%d.%m %H:%M')"
    printf '%s\n' "$state_line"
    [ -n "$spec_line" ] && printf '%s\n' "$spec_line"
    [ -n "$pr_line" ] && printf '%s\n' "$pr_line"
  } >"$tmp.block" 2>/dev/null
  awk -v blockfile="$tmp.block" '
    /^<!-- derived/   { print; while ((getline l < blockfile) > 0) print l; skip = 1; next }
    /^<!-- \/derived -->/ { skip = 0 }
    !skip             { print }
  ' "$led" >"$tmp" 2>/dev/null && mv -f "$tmp" "$led" 2>/dev/null
  rm -f "$tmp.block" "$tmp" 2>/dev/null
fi

# ---------------------------------------------------------------------------
#  4. the pointer
# ---------------------------------------------------------------------------
# The block above carries its own sync time, so the pointer does not repeat it.
# Nothing here may end up inside $(( )): an empty command substitution there is
# a syntax error, and a hook that dies after rewriting the ledger says nothing
# at all — which is exactly how this looked the first time it was run.
next=$(sed -n '/^## Next/,$p' "$led" 2>/dev/null | sed -n '2,4p' | tr '\n' ' ' | sed 's/  */ /g')
open=$(sed -n '/^## Open questions/,/^## /p' "$led" 2>/dev/null | grep -c '^- ') || open=0
case "${open:-0}" in 0|'') open= ;; *) open=" Open questions: $open." ;; esac

emit "This session is on $ticket. Its ledger is $led — the block between the derived markers was just regenerated from git; everything below it is the half no command can produce. Read it before starting, and before you finish, update that half with any decision and its reason, any approach you rejected, and what is left.${open}${next:+ Next: $next}"
