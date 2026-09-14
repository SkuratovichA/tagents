#!/bin/sh
# Publish Claude Code session state into tmux so `tagents` can render a live
# dashboard of every agent running under tmux.
#
# Registered in ~/.claude/settings.json for SessionStart, UserPromptSubmit,
# PreToolUse, PostToolUse, Notification, Stop, SubagentStop and SessionEnd.
#
# THREE KINDS OF RECORD go into ~/.claude/agent-state, and deciding which one a
# session gets is the whole of the classification below. All of them carry the
# same first seven fields, the last being the CLAUDE_CONFIG_DIR the session runs
# on; the two pane-less kinds add more.
#
#   <pane>.tsv   A SESSION THAT OWNS A PANE — seven fields and not one more,
#                which is what every reader of such a record still expects. The
#                coarse state is mirrored onto the pane option @agent, read by
#                the status bar.
#   s-<sid>.tsv  A SESSION WITH NO PANE ANYWHERE IN ITS ANCESTRY — a headless
#                `claude -p` run by a daemon or a launchd job. Three fields
#                more: 8 the pid of its claude process (there is no pane to ask
#                tmux about, so that pid is the whole of "is it still running"),
#                9 $TA_LOG, 10 $TA_LABEL. No tmux option is ever set for one.
#                This used to be where those sessions were dropped, which is why
#                the busiest agents on the machine were invisible.
#   s-<sid>.tsv  A CHILD SESSION — a `claude -p` that an agent started from its
#   (12 fields)  own Bash tool. It is a separate conversation with a session id
#                of its own, and it INHERITS $TMUX_PANE from the agent that
#                spawned it: keyed by that pane it overwrote the parent's record
#                on every event, wiped the parent's subagent counters and
#                deleted the record outright on SessionEnd. Two fields beyond a
#                headless one: 11 the parent's record key ("83" or "s-<sid>"),
#                12 the parent's session id. A child NEVER touches the pane it
#                inherited — no @agent, no `set -up`, and its subagent files are
#                keyed by its own session.
#
# WHO THE PARENT IS is decided at SessionStart and cached in the record.
# $CLAUDE_PID — the pid of the claude process this hook is running inside — is
# the anchor: with it unset there is no ancestry to reason about and the hook
# classifies exactly as it did before children existed. One pass over `ps` and
# the pane map answers four questions at once: which pane this session's own
# ancestry reaches, which process is its claude, whether a claude sits STRICTLY
# ABOVE it in the chain (that one is a parent session), and whether the
# $TMUX_PANE we inherited is a pane of the server we can actually see. Then:
#
#   1. a claude above us — the parent is that process's session: the s-*.tsv
#      that names its pid, or else the pane our own chain reaches;
#   2. no claude above us, but $TMUX_PANE names a live pane our own chain does
#      NOT reach: we only inherited it, so its session is the parent. A sibling
#      suspended in the same pane and a `claude --resume` there both reach it,
#      so neither is ever mistaken for a child;
#   3. otherwise the pane our chain reaches — or the one we were handed when the
#      walk found none, or no pane at all.
#
# Runs on every tool call, so it stays deliberately cheap: one jq, one tmux, and
# on every event but SessionStart one awk read of the record instead of a `ps`.

set -u

command -v jq >/dev/null 2>&1 || exit 0

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

# ---------------------------------------------------------------------------
# WHOSE RECORD THIS EVENT BELONGS TO
# ---------------------------------------------------------------------------
pane=; key=; headless=0
parkey=; parsid=; parlbl=          # the parent, when this turns out to be a child
cpid=; clog=; clbl=                # fields 8, 9 and 10 of a pane-less record
mine=; wcpid=; pclaude=; nmap=0; known=0

# $CLAUDE_PID is the pid of the claude running this hook. Parent detection runs
# only when it is there and is a number; without it every rule below is skipped
# and the hook behaves exactly as it always has.
own=; hasown=0
case "${CLAUDE_PID:-}" in
  ''|*[!0-9]*) ;;
  *) own=$CLAUDE_PID; hasown=1 ;;
esac
[ -n "$own" ] || own=$$

# One field of a record's first line, without a shell loop to get at it.
rec_parent() {  # <record file> — its session id and its label, in one read
  parsid=; parlbl=
  IFS="$us" read -r parsid parlbl <<EOF
$(awk -F'	' -v OFS="$us" 'NR==1 { print $3, $10; exit }' "$1" 2>/dev/null)
EOF
}

# ONE PASS OVER THE PROCESS TABLE ANSWERS FOUR QUESTIONS, and it is the only
# pass this hook ever makes. Which pane this session's ancestry reaches, if any;
# which process is the claude running it, the only liveness signal a session
# with NO pane has (the dashboard cannot ask tmux about a pane that does not
# exist, so it kill -0s that pid instead); whether a claude sits above us, which
# is what makes this session somebody's child; and how much of the pane map we
# could see at all, so "that pane is not ours" can be told from "there was no
# server to ask". The claude test is the one live_panes makes in tagents, so
# both sides agree on what a claude is.
ta_walk() {
  walk=$({
    tmux list-panes -a -F 'MAP #{pane_pid} #{pane_id}' 2>/dev/null
    ps -eo pid=,ppid=,comm= 2>/dev/null
  } | awk -v own="$own" -v claim="${TMUX_PANE:-}" '
      $1 == "MAP" { pane[$2] = $3; nmap++; if ($3 == claim) known = 1; next }
      { pid = $1; up[pid] = $2; c = $0
        sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", c)
        if (index(c, "/claude/versions/") > 0 || c ~ /\/claude$/ || c == "claude") cl[pid] = 1 }
      END {
        q = own; p = ""; cp = ""; pc = ""; step = 0
        for (i = 0; i < 50 && q != "" && q != "0" && q != "1"; i++) {
          if (q in cl) {
            if (cp == "") cp = q
            # STRICTLY above: our own claude is not our parent.
            if (step > 0 && pc == "") pc = q
          }
          if (q in pane) { p = pane[q]; break }
          q = up[q]; step++
        }
        # One line, colon-joined: a pane id is %<digits> and everything else
        # here is a number, so no field can ever contain the separator and the
        # shell splits it without a second process.
        print p ":" cp ":" pc ":" (nmap + 0) ":" (known + 0)
      }')
  mine=${walk%%:*};    walk=${walk#*:}
  wcpid=${walk%%:*};   walk=${walk#*:}
  pclaude=${walk%%:*}; walk=${walk#*:}
  nmap=${walk%%:*}
  known=${walk#*:}
  # A pane id is %<number>. Anything else means the walk latched onto something
  # that is not a pane, and naming a state file after it would leave junk named
  # after nothing (that is where a stray ".tsv" comes from).
  case "$mine" in %[0-9]*) ;; *) mine= ;; esac
  case "${nmap:-}" in ''|*[!0-9]*) nmap=0 ;; esac
}

# The full classification: the walk, then the three rules. Run at SessionStart
# and in the one fallback below, never on the hot path.
classify() {
  ta_walk
  parkey=; parsid=; parlbl=
  if [ "$hasown" = 1 ]; then
    if [ -n "$pclaude" ]; then
      # 1(a) THE PARENT HAS NO PANE OF ITS OWN — it is headless, or is itself a
      # child — so it is not in the pane map at all and only its own record
      # names its pid. set -u is on and the glob stays literal when nothing
      # matches it, which is what the redirect is for.
      pfile=$(awk -F'	' -v p="$pclaude" 'FNR==1 && $8 == p { print FILENAME; exit }' \
                "$dir"/s-*.tsv 2>/dev/null)
      if [ -n "$pfile" ]; then
        parkey=${pfile##*/}; parkey=${parkey%.tsv}
        rec_parent "$pfile"
      elif [ -n "$mine" ]; then
        # 1(b) ...or it is the claude sitting in the pane our chain reaches.
        parkey=${mine#%}
        rec_parent "$dir/$parkey.tsv"
      fi
    fi
    # 2. THE INHERITED PANE. A pane of a server we can see, occupied by
    # somebody, that our own chain does not reach: we were handed $TMUX_PANE
    # through the environment and it is not ours. This is a property of THIS
    # session, which is what makes it safe — a sibling suspended with ctrl-z and
    # a `claude --resume` in the same pane both reach that pane and neither is a
    # child, while an orphan whose parent has already exited still is one.
    if [ -z "$parkey" ] && [ -n "${TMUX_PANE:-}" ] && [ "$nmap" -gt 0 ] &&
       [ "$known" = 1 ] && [ "$mine" != "$TMUX_PANE" ]; then
      parkey=${TMUX_PANE#%}
      rec_parent "$dir/$parkey.tsv"
    fi
  fi
  if [ -n "$parkey" ] && [ -n "${sid:-}" ]; then
    pane=; headless=1; key="s-$sid"
  else
    # 3. NOT A CHILD. Ancestry beats an inherited environment variable where
    # there is any: the walk resolving to a pane is a fact about this process,
    # while $TMUX_PANE is only what we were started with. With no pane in the
    # ancestry the inherited one is still the best answer there is, which is
    # what a hook with no $CLAUDE_PID at all falls back to for everything.
    parkey=; parsid=; parlbl=
    pane=$mine
    [ -n "$pane" ] || pane=${TMUX_PANE:-}
    case "$pane" in %[0-9]*) ;; *) pane= ;; esac
  fi
  if [ "$hasown" = 1 ]; then cpid=$own; else cpid=$wcpid; fi
  # The hook's parent IS the claude process — Claude Code runs the command as a
  # simple command, so the shell it starts execs this script in place. Only the
  # fallback, for the case the walk found no ancestor that ps calls claude (a
  # wrapper, a renamed binary, a test stub). Left empty rather than defaulted if
  # even that is unset: the reader treats an unusable pid as "not running",
  # which is the honest answer, while a 0 would be read as a whole process group.
  [ -n "$cpid" ] || cpid=${PPID:-}
  clog=${TA_LOG:-}
  # AN INHERITED LABEL NAMES THE PARENT, NOT THIS SESSION. A child started from
  # an agent's Bash tool inherits its whole environment, $TA_LABEL included, so
  # every child of tg-orchestrator called itself tg-orchestrator. Blanked here,
  # while the parent's record is being read anyway; the row then falls back to
  # the session's own ai-title.
  clbl=${TA_LABEL:-}
  if [ -n "$parkey" ] && [ -n "$parlbl" ] && [ "$parlbl" = "$clbl" ]; then clbl=; fi
}

if [ "$event" = SessionStart ]; then
  # SessionStart always re-decides from scratch and ignores the cache: this is
  # the one event that knows the conversation is starting here and now.
  classify
  # A stale child record must not re-adopt a session that has just been decided
  # to live in a pane of its own — it would win rule 1 of §2.5 on the very next
  # event and key everything back under s-<sid>.
  if [ -n "$pane" ] && [ -n "${sid:-}" ]; then
    rm -f "$dir/s-$sid.tsv" 2>/dev/null
    # ...and when you last typed into it, which is what the row was ordered on.
    rm -f "$dir/prompt/s-$sid" 2>/dev/null
  fi
else
  # THE HOT PATH: one awk read and no `ps` at all.
  if [ -n "${sid:-}" ] && [ -e "$dir/s-$sid.tsv" ]; then
    # 1. A pane-less record of THIS session — headless or child. Field 8 says
    # which claude wrote it: when that is not us the record was left by an
    # earlier, crashed run of a conversation now resumed somewhere else, and
    # re-deciding is the only honest answer.
    IFS="$us" read -r c8 c9 c10 c11 c12 <<EOF
$(awk -F'	' -v OFS="$us" 'NR==1 { print $8, $9, $10, $11, $12; exit }' \
       "$dir/s-$sid.tsv" 2>/dev/null)
EOF
    if [ "$hasown" = 0 ] || [ "$c8" = "$own" ]; then
      key="s-$sid"; headless=1; pane=
      cpid=$c8; clog=$c9; clbl=$c10; parkey=$c11; parsid=$c12
    fi
  fi
  if [ -z "$key" ]; then
    if [ -n "${TMUX_PANE:-}" ]; then
      # 2. The pane we were handed, but only while we can prove the record in it
      # is ours. A record we cannot prove is ours is never overwritten blindly —
      # that is what sent the walk after it instead.
      rec_parent "$dir/${TMUX_PANE#%}.tsv"
      if [ -z "$parsid" ] || [ "$parsid" = "${sid:-}" ]; then
        pane=$TMUX_PANE; key=${pane#%}; headless=0
        parkey=; parsid=; parlbl=
        cpid=${PPID:-}; clog=${TA_LOG:-}; clbl=${TA_LABEL:-}
      else
        classify
      fi
    else
      # 3. Nothing to go on: walk, exactly as this hook always did here.
      classify
    fi
  fi
fi

if [ -z "$key" ]; then
  if [ -n "$pane" ]; then
    key=${pane#%}
  else
    # NO PANE ANYWHERE IN THE ANCESTRY: a headless `claude -p` started by a
    # daemon or a launchd job. `s-<session id>` is the key tagents state_files()
    # already accepts for a session that owns no pane, and with no id there is
    # nothing to key on at all.
    [ -n "${sid:-}" ] || exit 0
    key="s-$sid"
    headless=1
  fi
fi

# A session started as a BACKGROUND JOB has no $TMUX_PANE, so the walk above
# resolves it to whatever pane its ancestor chain reaches — which is the pane of
# the session that spawned it, already occupied by a different, live
# conversation. Keying state by pane then makes the two silently overwrite each
# other: the parent agent's row starts showing the background job's session id,
# name and token counts. Observed live. Give the intruder its own key rather
# than letting it steal the pane's. (A child proper is already keyed by its own
# session above; this is the same rule for the cases no ancestry explains.)
if [ "$headless" = 0 ] && [ -z "${TMUX_PANE:-}" ] && [ -n "${sid:-}" ] &&
   [ -e "$dir/$key.tsv" ]; then
  owner=$(awk -F'	' 'NR==1 { print $3 }' "$dir/$key.tsv" 2>/dev/null)
  if [ -n "$owner" ] && [ "$owner" != "$sid" ]; then
    key="s-$sid"
    headless=1
    pane=
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
    # A CHILD GETS A SEVENTH COLUMN and nobody else does — the parent's session
    # id, which is how the closed-session picker knows not to offer a child as a
    # conversation to resume. The line stays six fields wide for every other
    # session, byte for byte what it always was, and every reader projects
    # $1..$6 explicitly.
    if [ -n "$parkey" ]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$now" "$hist" "${sid:-}" "" "$clbl" "${cwd:-}" "${parsid:-}"
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$now" "$hist" "${sid:-}" "$pane" "${TA_LABEL:-}" "${cwd:-}"
    fi >>"$dir/history.tsv" 2>/dev/null
  fi
fi

# ---------------------------------------------------------------------------
# Subagents are tracked per (key, agent_id) so the dashboard can show how much
# is fanned out under a session without clobbering the session's own state. A
# child's key is its own, so its subagents no longer wipe the parent's.
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
  # A PARENT TAKES ITS FINISHED CHILDREN WITH IT. Off the hot path, so it can
  # afford a pass over the pane-less records: every child of this session whose
  # own claude is gone is a row nobody can do anything with. A child still
  # RUNNING is kept and simply renders at the top level once the parent's row
  # has gone.
  if [ -n "${sid:-}" ]; then
    for kidf in "$dir"/s-*.tsv; do
      [ -e "$kidf" ] || continue
      IFS="$us" read -r kpar kpid <<EOF
$(awk -F'	' -v OFS="$us" 'NR==1 { print $12, $8; exit }' "$kidf" 2>/dev/null)
EOF
      [ "$kpar" = "$sid" ] || continue
      case ${kpid:-} in
        ''|0|*[!0-9]*) ;;
        *) kill -0 "$kpid" 2>/dev/null && continue ;;
      esac
      kidkey=${kidf##*/}; kidkey=${kidkey%.tsv}
      rm -f "$kidf"
      rm -f "$dir/sub/$kidkey".* 2>/dev/null
      rm -f "$dir/prompt/$kidkey" 2>/dev/null
    done
  fi
  # SID-GUARDED WHATEVER THIS SESSION TURNED OUT TO BE: a record that names
  # another conversation is somebody else's, and dropping it (and its subagent
  # counters, and its pane option) on our way out is the bug this hook had.
  gowner=$(awk -F'	' 'NR==1 { print $3 }' "$dir/$key.tsv" 2>/dev/null)
  if [ -z "$gowner" ] || [ "$gowner" = "${sid:-}" ]; then
    rm -f "$dir/$key.tsv"
    rm -f "$dir/sub/$key".* 2>/dev/null
    # ...and when you last typed into it, which is what the row was ordered on.
    rm -f "$dir/prompt/$key" 2>/dev/null
    # No pane, no pane option to unset — and `-t ""` is not a no-op to tmux, it
    # is "the current pane", i.e. somebody else's. A child never has one.
    [ -n "$pane" ] && tmux set -up -t "$pane" @agent 2>/dev/null
  fi
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
#
# Nothing here can overwrite a <pane>.tsv that names another session: outside
# SessionStart the key is only ever a pane after the guard above proved the
# record in it is ours, and at SessionStart the conversation really is starting
# in that pane.
tmpf="$dir/.$key.$$"
if [ -n "$parkey" ]; then
  # A CHILD: the headless layout plus the two fields that say whose it is.
  #  11  the parent's record key — "83" for a pane, "s-<sid>" for a parent that
  #      is itself pane-less. It is what the dashboard nests the row under.
  #  12  the parent's session id, which is the same answer in the form the
  #      history file and the closed-session picker can join on.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$now" "$state" "$sid" "$cwd" "$transcript" "${detail:-}" \
    "${CLAUDE_CONFIG_DIR:-}" "$cpid" "$clog" "$clbl" "$parkey" "${parsid:-}" \
    >"$tmpf" 2>/dev/null && { mv -f "$tmpf" "$dir/$key.tsv" 2>/dev/null || rm -f "$tmpf"; }
elif [ "$headless" = 1 ]; then
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
    "${CLAUDE_CONFIG_DIR:-}" "$cpid" "$clog" "$clbl" \
    >"$tmpf" 2>/dev/null && { mv -f "$tmpf" "$dir/$key.tsv" 2>/dev/null || rm -f "$tmpf"; }
elif printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
     "$now" "$state" "$sid" "$cwd" "$transcript" "${detail:-}" \
     "${CLAUDE_CONFIG_DIR:-}" >"$tmpf" 2>/dev/null; then
  mv -f "$tmpf" "$dir/$key.tsv" 2>/dev/null || rm -f "$tmpf"
fi

# Nothing to mirror the state onto without a pane; the dashboard reads the file.
# A child has none on purpose: the pane it inherited belongs to its parent, and
# writing this session's state there is what made the parent's row lie.
[ -n "$pane" ] && tmux set -p -t "$pane" @agent "$state" 2>/dev/null
exit 0
