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
# A pane id is %<number>. Anything else means the walk above latched onto
# something that is not a pane, and writing it out would leave junk state files
# named after nothing (that is where a stray ".tsv" comes from).
case "$pane" in %[0-9]*) ;; *) exit 0 ;; esac

dir=${TA_STATE_DIR:-$HOME/.claude/agent-state}
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
  # A Notification is not automatically something to act on. Claude Code sends
  # one when it wants a decision ("Claude needs your permission to use Bash"),
  # and it also sends one after ~60s of silence purely to say the turn is over
  # and it is your move — which is the same situation Stop already reports. The
  # second kind is folded into "done" and carries no text: the state column
  # already says it, and repeating "Claude is waiting for your input" on every
  # such row was noise. Only a real ask keeps the "blocked" state, and there the
  # message is the whole point, so it is kept verbatim.
  def idleping: ((.notification_type // .notificationType // "") == "idle_prompt")
                or ((.message // "") | test("waiting for your input"; "i"));
  . as $h
  | ($h.hook_event_name // "") as $e
  | (if   $e == "Notification"     then (if ($h | idleping) then ["done", ""]
                                         else ["blocked", ($h.message // "")] end)
     elif $e == "Stop"             then ["done",    ""]
     elif $e == "UserPromptSubmit" then ["working", ($h.prompt // "")]
     elif $e == "PreToolUse"       then ["working", (($h.tool_name // "tool")
                                                     + (($h | arg) | if . == "" then "" else " " + . end))]
     elif $e == "PostToolUse"      then ["working", (($h.tool_name // "tool") + " ✓")]
     elif $e == "SessionStart"     then ["new",     ("session " + ($h.source // "start"))]
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

# A session started as a BACKGROUND JOB has no $TMUX_PANE, so the walk above
# resolves it to whatever pane its ancestor chain reaches — which is the pane of
# the session that spawned it, already occupied by a different, live
# conversation. Keying state by pane then makes the two silently overwrite each
# other: the parent agent's row starts showing the background job's session id,
# name and token counts. Observed live. Give the intruder its own key rather
# than letting it steal the pane's.
if [ -z "${TMUX_PANE:-}" ] && [ -n "${sid:-}" ] && [ -e "$dir/$key.tsv" ]; then
  owner=$(awk -F'	' 'NR==1 { print $3 }' "$dir/$key.tsv" 2>/dev/null)
  if [ -n "$owner" ] && [ "$owner" != "$sid" ]; then
    key="s-$sid"
  fi
fi

# ---------------------------------------------------------------------------
# Append-only history, read by `tagents --timeline`. Only three event kinds get
# logged, so this stays a handful of lines per session instead of one per tool
# call: session start, end of a turn — which is what makes "was working at this
# time" derivable even for a session killed without SessionEnd — and end.
# ---------------------------------------------------------------------------
if [ -z "${agent:-}" ]; then
  hist=
  case "$event" in
    SessionStart) hist=start ;;
    Stop)         hist=turn ;;
    SessionEnd)   hist=end ;;
  esac
  if [ -n "$hist" ]; then
    if [ "$hist" = start ] && [ -e "$dir/history.tsv" ]; then
      # Rotate on start only: rare enough that the size check costs nothing.
      sz=$(wc -c <"$dir/history.tsv" 2>/dev/null || echo 0)
      [ "${sz:-0}" -gt 5242880 ] && mv -f "$dir/history.tsv" "$dir/history.tsv.1"
    fi
    # TA_LABEL is optional: export it before starting claude and the timeline
    # has a name for the session from its first line, without waiting for one to
    # be typed in the dashboard.
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$now" "$hist" "${sid:-}" "$pane" "${TA_LABEL:-}" "${cwd:-}" \
      >>"$dir/history.tsv" 2>/dev/null
  fi
fi

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
