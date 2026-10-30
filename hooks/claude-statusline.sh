#!/bin/sh
# Claude Code status line — and the only place tagents can learn which model a
# session is actually set to.
#
# Registered as `statusLine` in ~/.claude/settings.json by `tagents setup`, from hooks/claude-settings.json; a status line of the user's own is kept unless setup is given --statusline. Claude Code runs it on every conversation update (debounced) and renders what it prints under the prompt.
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
# sum of its requests priced at the model that served each one; the model
# recorded here is only "what the next request will be billed at".
#
# One jq and one write: this runs far more often than a hook does.

set -u

command -v jq >/dev/null 2>&1 || exit 0

dir=${TA_STATE_DIR:-$HOME/.claude/agent-state}

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# Same unit-separator join as the state hook: tab is IFS whitespace, so an empty
# field would collapse and shift every later value one slot left.
# The escape byte comes out of the same fork: one printf, split by the shell.
ctl=$(printf '\033\037'); ESC=${ctl%?}; us=${ctl#?}

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
  # cost is Claude Code's OWN running total for this session — the only figure
  # that is not an estimate, since it is what actually gets billed. tusage
  # prices the transcript instead, which is the only way to answer "what did
  # the subagents cost" or "what did the last five hours cost", but where the
  # two disagree this one is right.
  # Claude Code runs this every 30 s per open session, and a rewrite of an
  # unchanged file makes the picker reload for nothing: the file is written only
  # when what the readers use (the model, its name and the cost; field 1, the
  # time, is read by nothing) differs from what is there. The tab is held in a
  # variable and the line is cut with ${old#*TAB}, not split with read, because
  # tab is IFS whitespace and an empty field would collapse.
  tab=$(printf '\t')
  new="$mid$tab$mname$tab${cost:-0}"
  old=
  [ -r "$d/$sid.tsv" ] && IFS= read -r old <"$d/$sid.tsv" 2>/dev/null
  if [ ! -e "$d/$sid.tsv" ] || [ "${old#*"$tab"}" != "$new" ]; then
    tmpf="$d/.$sid.$$"
    if printf '%s\t%s\n' "$(date +%s)" "$new" >"$tmpf" 2>/dev/null; then
      mv -f "$tmpf" "$d/$sid.tsv" 2>/dev/null || rm -f "$tmpf"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# What the line itself says: context used, and nothing else. The model and the
# session cost are deliberately NOT printed — tagents and the tmux status bar
# already show both, and /model answers "which model" on demand — so under the
# prompt they were only a duplicate. Everything above still runs regardless:
# the model file is what tagents reads, the printed line is not.
# ---------------------------------------------------------------------------
DIM="${ESC}[90m"; R="${ESC}[0m"
ctxcol=$DIM
[ "${ctx:-0}" -ge 60 ] 2>/dev/null && ctxcol="${ESC}[33m"
[ "${ctx:-0}" -ge 85 ] 2>/dev/null && ctxcol="${ESC}[1;31m"

fastmark=
[ "${fast:-false}" = true ] && fastmark=' ⚡'

printf '%s%s%%%s ctx%s%s\n' "$ctxcol" "${ctx:-0}" "$DIM" "$fastmark" "$R"
