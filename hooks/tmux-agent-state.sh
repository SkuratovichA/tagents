#!/bin/sh
# Publish Claude Code session state into tmux so `tagents` can render a live
# dashboard of every agent running under tmux.
#
# Registered in ~/.claude/settings.json for SessionStart, UserPromptSubmit,
# PreToolUse, PostToolUse, Notification, Stop, SubagentStop and SessionEnd.
# Writes one record per pane into ~/.claude/agent-state/<pane>.tsv (7 tab-separated
# fields, the last being the CLAUDE_CONFIG_DIR the session runs on) and mirrors
# the coarse state onto the tmux pane option @agent (read by the status bar).
#
# A SESSION WITH NO PANE ANYWHERE IN ITS ANCESTRY — a headless `claude -p` run by
# a daemon or a launchd job — is recorded too, under `s-<session id>.tsv`, with
# three more fields: the pid of its claude process (the dashboard has no pane to
# check liveness against, so it kill -0s that instead), $TA_LOG and $TA_LABEL.
# There is no pane there, so no tmux option is ever set for such a record. This
# used to be where those sessions were dropped, which is why the busiest agents
# on the machine were invisible in the dashboard.
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
cpid=
if [ -z "$pane" ]; then
  # ONE PASS OVER THE PROCESS TABLE ANSWERS TWO QUESTIONS, and it is the only
  # pass this hook ever makes. Which pane the session lives in, if any — and
  # which process is the claude running it, which is the only liveness signal a
  # session with NO pane has: the dashboard cannot ask tmux about a pane that
  # does not exist, so it kill -0s that pid instead. The claude test is the one
  # live_panes makes in tagents, so both sides agree on what a claude is.
  walk=$({
    tmux list-panes -a -F 'MAP #{pane_pid} #{pane_id}' 2>/dev/null
    ps -eo pid=,ppid=,comm= 2>/dev/null
  } | awk -v start="$$" '
      $1 == "MAP" { pane[$2] = $3; next }
      { pid = $1; up[pid] = $2; c = $0
        sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", c)
        if (index(c, "/claude/versions/") > 0 || c ~ /\/claude$/ || c == "claude") cl[pid] = 1 }
      END {
        q = start; p = ""; cp = ""
        for (i = 0; i < 50 && q != "" && q != "0" && q != "1"; i++) {
          if (cp == "" && (q in cl)) cp = q
          if (q in pane) { p = pane[q]; break }
          q = up[q]
        }
        # One line, colon-joined: a pane id is %<digits> and a pid is digits, so
        # neither half can ever contain the separator, and the shell splits it
        # without a second process.
        print p ":" cp
      }')
  pane=${walk%%:*}
  cpid=${walk#*:}
fi
# A pane id is %<number>. Anything else means the walk above latched onto
# something that is not a pane, and naming a state file after it would leave
# junk named after nothing (that is where a stray ".tsv" comes from). It is no
# longer a reason to give up, though: no pane is a state this hook can record,
# and the record goes under the session key instead (see $headless below).
case "$pane" in %[0-9]*) ;; *) pane= ;; esac
# The hook's parent IS the claude process — Claude Code runs the command as a
# simple command, so the shell it starts execs this script in place. Only the
# fallback, for the case the walk above found no ancestor that ps calls claude
# (a wrapper, a renamed binary, a test stub). Left empty rather than defaulted
# if even that is unset: the reader treats an unusable pid as "not running",
# which is the honest answer, while a 0 would be read as a whole process group.
[ -n "$cpid" ] || cpid=${PPID:-}

dir=${TA_STATE_DIR:-$HOME/.claude/agent-state}
mkdir -p "$dir/sub" "$dir/prompt" 2>/dev/null || exit 0

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

now=$(date +%s)

headless=0
if [ -n "$pane" ]; then
  key=${pane#%}
else
  # NO PANE ANYWHERE IN THE ANCESTRY: a headless `claude -p` started by a daemon
  # or a launchd job. Its hooks fire exactly like everyone else's — this is
  # simply where the record used to be thrown away. `s-<session id>` is the key
  # tagents state_files() already accepts for a session that owns no pane, and
  # with no id there is nothing to key on at all.
  [ -n "${sid:-}" ] || exit 0
  key="s-$sid"
  headless=1
fi

# A session started as a BACKGROUND JOB has no $TMUX_PANE, so the walk above
# resolves it to whatever pane its ancestor chain reaches — which is the pane of
# the session that spawned it, already occupied by a different, live
# conversation. Keying state by pane then makes the two silently overwrite each
# other: the parent agent's row starts showing the background job's session id,
# name and token counts. Observed live. Give the intruder its own key rather
# than letting it steal the pane's.
if [ "$headless" = 0 ] && [ -z "${TMUX_PANE:-}" ] && [ -n "${sid:-}" ] &&
   [ -e "$dir/$key.tsv" ]; then
  owner=$(awk -F'	' 'NR==1 { print $3 }' "$dir/$key.tsv" 2>/dev/null)
  if [ -n "$owner" ] && [ "$owner" != "$sid" ]; then
    key="s-$sid"
  fi
fi

# ---------------------------------------------------------------------------
# WHEN THE OWNER LAST TYPED — one file per session, holding nothing but that
# epoch second. Written on UserPromptSubmit and on nothing else, which is the
# whole point: the record above is rewritten on every tool call, so an age taken
# from it restarts at 0:00 the moment an agent picks up a tool, and a list
# sorted on it reshuffles while you watch. This one moves once per turn, when
# you send something, so it is both a stable sort key and the answer to "how
# long since my last message" — i.e. how much of the one-hour prompt cache is
# left. Its own file rather than an eighth field, so the record stays byte for
# byte what every reader of it already expects.
# ---------------------------------------------------------------------------
if [ "$event" = UserPromptSubmit ] && [ -z "${agent:-}" ]; then
  printf '%s\n' "$now" >"$dir/prompt/$key" 2>/dev/null
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
  rm -f "$dir/prompt/$key" 2>/dev/null
  # No pane, no pane option to unset — and `-t ""` is not a no-op to tmux, it is
  # "the current pane", i.e. somebody else's.
  [ -n "$pane" ] && tmux set -up -t "$pane" @agent 2>/dev/null
  exit 0
fi

# A finished turn means no subagent of this session can still be running.
[ "$state" = "done" ] && rm -f "$dir/sub/$key".* 2>/dev/null

# WHICH ACCOUNT THIS SESSION IS ON, as the 7th field. A hook runs inside
# Claude's own process, so it is the only thing that can see the CLAUDE_CONFIG_DIR
# the session was actually started with — and that is a whole login, not a
# setting: resuming the conversation anywhere else finds nothing. An empty value
# means the default account; a record with only 6 fields was written before this
# existed and means nothing at all, which is why the reader tests NF rather than
# treating the two the same.
tmpf="$dir/.$key.$$"
if [ "$headless" = 1 ]; then
  # THREE MORE FIELDS, AND ONLY WHERE THERE IS NO PANE — a paned record is
  # written byte for byte as it always was, which is what every reader of it
  # still expects:
  #   8  the pid of this session's claude. There is no pane to ask tmux about,
  #      so this is the whole of what "is it still running" means for such a row.
  #   9  $TA_LOG — where whatever started this session sends its output. With no
  #      pane there is nothing to capture-pane, so this is what the preview
  #      tails instead.
  #  10  $TA_LABEL — the name to show. A headless session has no terminal title
  #      either, and "ticket-agent" beats the basename of a cwd.
  # The daemons that start these sessions already export the last two.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$now" "$state" "$sid" "$cwd" "$transcript" "${detail:-}" \
    "${CLAUDE_CONFIG_DIR:-}" "$cpid" "${TA_LOG:-}" "${TA_LABEL:-}" \
    >"$tmpf" 2>/dev/null && { mv -f "$tmpf" "$dir/$key.tsv" 2>/dev/null || rm -f "$tmpf"; }
elif printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
     "$now" "$state" "$sid" "$cwd" "$transcript" "${detail:-}" \
     "${CLAUDE_CONFIG_DIR:-}" >"$tmpf" 2>/dev/null; then
  mv -f "$tmpf" "$dir/$key.tsv" 2>/dev/null || rm -f "$tmpf"
fi

# Nothing to mirror the state onto without a pane; the dashboard reads the file.
[ -n "$pane" ] && tmux set -p -t "$pane" @agent "$state" 2>/dev/null
exit 0
