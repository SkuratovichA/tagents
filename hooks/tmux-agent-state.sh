#!/bin/sh
# Publish Claude Code session state into tmux so `tagents` can render a live
# dashboard of every agent running under tmux.
#
# Registered in ~/.claude/settings.json for SessionStart, UserPromptSubmit,
# PreToolUse, PostToolUse, Notification, Stop, SubagentStop and SessionEnd.
# Writes one record per pane into ~/.claude/agent-state/<pane>.tsv and mirrors
# the coarse state onto the tmux pane option @agent (read by the status bar).
#
# Runs on every tool call, so it stays deliberately cheap: one jq, one tmux.

set -u

command -v jq >/dev/null 2>&1 || exit 0

# $TMUX_PANE is the fast path, but it is not always in the environment — a
# session started outside tmux and later re-parented, or run as a background
# job, has no such variable, and the hook used to give up silently there (no
# state, no subagent counts, no explanation). Fall back to walking up from this
# process until an ancestor turns out to be some pane's root process.
pane=${TMUX_PANE:-}
if [ -z "$pane" ]; then
  pane=$({
    tmux list-panes -a -F 'MAP #{pane_pid} #{pane_id}' 2>/dev/null
    ps -eo pid=,ppid= 2>/dev/null
  } | awk -v start="$$" '
      $1 == "MAP" { pane[$2] = $3; next }
      { up[$1] = $2 }
      END {
        q = start
        for (i = 0; i < 50 && q != "" && q != "0" && q != "1"; i++) {
          if (q in pane) { print pane[q]; exit }
          q = up[q]
        }
      }')
fi
[ -n "$pane" ] || exit 0

dir="$HOME/.claude/agent-state"
mkdir -p "$dir/sub" 2>/dev/null || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

# Fields are joined with the unit separator rather than a tab: tab counts as IFS
# whitespace, so `read` would collapse the (usually empty) agent_id field and
# shift every remaining value one slot to the left.
us=$(printf '\037')

line=$(printf '%s' "$payload" | jq -r --arg us "$us" '
  def clip: if (length > 90) then (.[0:89] + "…") else . end;
  def one:  tostring | gsub("[\\r\\n\\t]+"; " ") | gsub($us; " ")
            | gsub("^ +| +$"; "") | clip;
  def arg:  (.tool_input // {})
            | (.command // .file_path // .pattern // .path // .url
               // .description // .prompt // "") | tostring;
  . as $h
  | ($h.hook_event_name // "") as $e
  | (if   $e == "Notification"     then ["blocked", ($h.message // "нужен твой ответ")]
     elif $e == "Stop"             then ["done",    "ход закончен — ждёт ввода"]
     elif $e == "UserPromptSubmit" then ["working", ($h.prompt // "")]
     elif $e == "PreToolUse"       then ["working", (($h.tool_name // "tool")
                                                     + (($h | arg) | if . == "" then "" else " " + . end))]
     elif $e == "PostToolUse"      then ["working", (($h.tool_name // "tool") + " ✓")]
     elif $e == "SessionStart"     then ["idle",    ("сессия: " + ($h.source // "start"))]
     elif $e == "SessionEnd"       then ["gone",    ""]
     elif $e == "SubagentStop"     then ["subdone", ""]
     else                               ["working", $e] end) as [$state, $detail]
  | [$e, ($h.agent_id // ""), $state,
     ($h.session_id // ""), ($h.cwd // ""), ($h.transcript_path // ""),
     ($detail | one)]
  | map(tostring | gsub("[\\r\\n\\t]"; " ") | gsub($us; " "))
  | join($us)
' 2>/dev/null) || exit 0
[ -n "$line" ] || exit 0

IFS="$us" read -r event agent state sid cwd transcript detail <<EOF
$line
EOF

key=${pane#%}
now=$(date +%s)

# ---------------------------------------------------------------------------
# Subagents are tracked per (pane, agent_id) so the dashboard can show how much
# is fanned out under a session without clobbering the session's own state.
# ---------------------------------------------------------------------------
if [ -n "${agent:-}" ]; then
  case "$state" in
    subdone|gone) rm -f "$dir/sub/$key.$agent" ;;
    *) printf '%s\t%s\n' "$now" "${detail:-}" >"$dir/sub/$key.$agent" 2>/dev/null ;;
  esac
  exit 0
fi

# SubagentStop without an agent_id carries no identity — leave those entries to
# the dashboard's age-based pruning.
[ "$state" = "subdone" ] && exit 0

if [ "$state" = "gone" ]; then
  rm -f "$dir/$key.tsv"
  rm -f "$dir/sub/$key".* 2>/dev/null
  tmux set -up -t "$pane" @agent 2>/dev/null
  exit 0
fi

# A finished turn means no subagent of this session can still be running.
[ "$state" = "done" ] && rm -f "$dir/sub/$key".* 2>/dev/null

tmpf="$dir/.$key.$$"
if printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
     "$now" "$state" "$sid" "$cwd" "$transcript" "${detail:-}" >"$tmpf" 2>/dev/null; then
  mv -f "$tmpf" "$dir/$key.tsv" 2>/dev/null || rm -f "$tmpf"
fi

tmux set -p -t "$pane" @agent "$state" 2>/dev/null
exit 0
