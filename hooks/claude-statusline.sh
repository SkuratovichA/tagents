#!/bin/sh
# Claude Code status line — and the only place tagents can learn which model a
# session is actually set to.
#
# Registered as `statusLine` in ~/.claude/settings.json. Claude Code runs it on
# every conversation update (debounced) and renders what it prints under the
# prompt.
#
# WHY tagents NEEDS THIS. The transcript records the model of every assistant
# message, which is what lets tusage price each request at the model that served
# it. What it never records is the model you PICKED: switch a session to Opus
# and then say nothing, and the newest message on disk is still the one Fable
# answered an hour ago — so the dashboard confidently showed the old tier and
# there was no file anywhere on disk that disagreed. The statusLine payload is
# the only channel carrying `model.id`, so it is written out here and joined
# back on the session id.
#
# The money is emphatically NOT computed from this. What a session cost is the
# sum of its requests priced at the model that served each one; the model shown
# here is only "what the next request will be billed at".
#
# One jq and one write: this runs far more often than a hook does.

set -u

command -v jq >/dev/null 2>&1 || exit 0

dir=${TA_STATE_DIR:-$HOME/.claude/agent-state}

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# Same unit-separator join as the state hook: tab is IFS whitespace, so an empty
# field would collapse and shift every later value one slot left.
us=$(printf '\037')

line=$(printf '%s' "$payload" | jq -r --arg us "$us" '
  [ (.session_id // "")
  # "[1m]" and friends are a context-window suffix, not a different model, and
  # nothing downstream prices or matches on them.
  , ((.model.id // "") | gsub("\\[[^]]*\\]"; ""))
  , (.model.display_name // "")
  , (.cost.total_cost_usd // 0)
  , ((.context_window.used_percentage // 0) | floor)
  , (.fast_mode // false)
  ] | map(tostring | gsub("[\r\n\t]"; " ")) | join($us)
' 2>/dev/null) || exit 0
[ -n "$line" ] || exit 0

IFS="$us" read -r sid mid mname cost ctx fast <<EOF
$line
EOF

if [ -n "${sid:-}" ] && [ -n "${mid:-}" ]; then
  d="$dir/model"
  if [ ! -e "$d/$sid.tsv" ]; then
    mkdir -p "$d" 2>/dev/null || exit 0
    # One file per session id and nothing ever deletes them, so the sweep lives
    # here — on the rare path, not on the one that runs every few hundred ms.
    find "$d" -name '*.tsv' -mtime +30 -delete 2>/dev/null
  fi
  tmpf="$d/.$sid.$$"
  if printf '%s\t%s\t%s\n' "$(date +%s)" "$mid" "$mname" >"$tmpf" 2>/dev/null; then
    mv -f "$tmpf" "$d/$sid.tsv" 2>/dev/null || rm -f "$tmpf"
  fi
fi

# ---------------------------------------------------------------------------
# What the line itself says. Deliberately short: it sits under the prompt in
# every session, and the dashboard is where the detail belongs.
# ---------------------------------------------------------------------------
DIM=$(printf '\033[90m'); R=$(printf '\033[0m')
ctxcol=$DIM
[ "${ctx:-0}" -ge 60 ] 2>/dev/null && ctxcol=$(printf '\033[33m')
[ "${ctx:-0}" -ge 85 ] 2>/dev/null && ctxcol=$(printf '\033[1;31m')

name=${mname:-$mid}
[ -n "$name" ] || exit 0
[ "${fast:-false}" = true ] && name="$name ⚡"

printf '%s%s · %s%s%%%s ctx · $%.2f%s\n' \
  "$name" "$DIM" "$ctxcol" "${ctx:-0}" "$DIM" "${cost:-0}" "$R"
