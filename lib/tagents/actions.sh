# lib/tagents/actions.sh — what a key actually does
#
# The verbs: send_line/ask_send and the ctrl-x family (kill_agent, ask_kill's live re-check, end_agent, forget_agent) with the 'killing an agent' essay heading that half, open_chat (settles a click against the records before a row is selected or joined) and act() — the short-lived execute-silent child every binding runs through, and the place that refuses pane-verbs on a headless row and every verb but a selection on a dimmed window row. Selecting, joining and breaking out live in rows.sh.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# ---------------------------------------------------------------------------
# actions
# ---------------------------------------------------------------------------

send_line() {
  local pane=$1
  [ "$pane" = "-" ] && return 0
  prompt 8 --ask-send "$pane" && return 0
  ask_send "$pane"
}

ask_send() {
  local pane=$1 text
  [ "$pane" = "-" ] && return 0
  # Bounded read on purpose. Without a popup this runs through fzf's `execute`,
  # which hands over the terminal, so a read that can block forever freezes the
  # whole dashboard with nothing on screen to explain why.
  printf '\033[1msend to %s\033[0m\n' "$pane"
  printf '\033[90mempty line cancels · ctrl-c cancels\033[0m\n> '
  IFS= read -r -t 300 text || return 0
  [ -z "$text" ] && return 0
  tmux send-keys -t "$pane" -l -- "$text" 2>/dev/null
  sleep 0.2   # let the TUI settle before the newline, or it reads as a paste
  tmux send-keys -t "$pane" Enter 2>/dev/null
}

# ---------------------------------------------------------------------------
# killing an agent
#
# ctrl-x ends the agent under the cursor: the Claude in it is hung up and its
# pane goes with it, which takes the window too when it was the only pane there.
# Same end state as typing /exit and then exiting the shell, in one keypress.
#
# IT ASKS FIRST, and not only because it is destructive. ctrl-x used to be
# undock (that moved to ctrl-u), so the muscle memory of every earlier version
# of this dashboard now lands on the one key that ends a session — and on a
# group header the row stands in for the group's most urgent member, which is
# not a pane you chose by name. The popup says which agent it is about to kill,
# so a wrong press costs a glance and a keystroke instead of a conversation.
#
# NOTHING IS LOST that /exit would have kept: Claude Code writes its transcript
# as it goes, so the row simply becomes "closed — enter resumes it", like any
# other session you have quit, and picks up where it stopped. Pressing ctrl-x on
# that closed row is the second half of the same gesture — there is no process
# left to hang up, so it drops the record and the row goes away.
# ---------------------------------------------------------------------------
kill_agent() {
  local pane=${1:-} sid=${2:-}
  [ "$pane" = "-" ] && return 0
  # The list itself is a pane in the same window as the chat it sits beside, and it is never an agent row — but a marker can drift, and killing the list from the list is not a mistake worth allowing.
  if [ "$pane" = "$(dash_pane)" ]; then
    tmux display-message "tagents: that is the dashboard itself" 2>/dev/null
    return 0
  fi
  prompt 11 --ask-kill "$pane" "$sid" && return 0
  ask_kill "$pane" "$sid"
}

ask_kill() {  # the confirmation itself — normally the body of the popup
  local pane=${1:-} sid=${2:-} nm dir where ans alive=0
  [ "$pane" = "-" ] && return 0
  # Asked of tmux, not taken from the row: the row was rendered up to two
  # seconds ago, and what is about to happen depends on whether there is still a
  # pane to kill. A row keyed "s-<session>" — a session that had no $TMUX_PANE
  # and was never resolved to one — names no pane at all and lands here too.
  case "$pane" in
    %[0-9]*) tmux list-panes -a -F '#{pane_id}' 2>/dev/null |
               grep -qx -- "$pane" && alive=1 ;;
  esac
  # The same name the row shows, worked out the same way: an explicit label
  # first, then the pane title with Claude Code leading glyph stripped, then the
  # project. A title that is just the hostname is tmux default and names nothing.
  nm=$(label_of "${sid:-$pane}")
  dir=$(LC_ALL=C awk -F"$TAB" 'NR==1 { print $4 }' "$STATE_DIR/${pane#%}.tsv" 2>/dev/null)
  if [ "$alive" = 1 ]; then
    [ -z "$dir" ] && dir=$(tmux display -p -t "$pane" '#{pane_current_path}' 2>/dev/null)
    if [ -z "$nm" ]; then
      nm=$(untitle_of "$(tmux display -p -t "$pane" '#{pane_title}' 2>/dev/null)")
      host_title "$nm" && nm=""
    fi
    [ -z "$nm" ] && nm=$(basename "${dir:-?}")
    where=$(tmux display -p -t "$pane" \
              '#{session_name}:#{window_index}  #{pane_current_path}' 2>/dev/null)
    printf '\033[1mkill this agent?\033[0m\n'
    printf '%s\n' "${nm:-$pane}"
    printf '\033[90m%s\033[0m\n' "$where"
    printf '\033[90mclaude is hung up and the pane goes with it — the window too\n'
    printf 'if it is the last pane there. the session stays resumable.\033[0m\n'
  else
    [ -z "$nm" ] && [ -n "$dir" ] && nm=$(basename "$dir")
    printf '\033[1mforget this closed session?\033[0m\n'
    printf '%s\n' "${nm:-${sid:-$pane}}"
    [ -n "$dir" ] && printf '\033[90m%s\033[0m\n' "$dir"
    printf '\033[90mno pane of this session is left, so there is nothing to hang\n'
    printf 'up. this drops the record, which is what enter resumes from.\033[0m\n'
  fi
  printf '\033[90my confirms · anything else cancels\033[0m\n> '
  # Bounded, like every other prompt here: without popups this runs inline,
  # where fzf has handed over the terminal and a read that never returns takes
  # the dashboard with it. A confirmation nobody answers means "no".
  IFS= read -r -t 60 ans || return 0
  case "$ans" in
    y|Y|yes|YES|Yes) ;;
    *) return 0 ;;
  esac
  if [ "$alive" = 1 ]; then end_agent "$pane"; else forget_agent "$pane"; fi
}

forget_agent() {  # <pane-key> — drop a closed session's record from the list
  local key=${1#%}
  [ -n "$key" ] || return 0
  rm -f "$STATE_DIR/$key.tsv" 2>/dev/null
  rm -f "$STATE_DIR/sub/$key".* 2>/dev/null
  # ...and when you last typed into it, which is what the row was ordered on.
  rm -f "$STATE_DIR/prompt/$key" 2>/dev/null
  signal_ev   # a deleted record is not a tmux event, and the row has to go
  return 0
}


end_agent() {  # <pane> — hang up the agent running in it
  local pane=$1 key=${pane#%}
  # The sidebar leaves the window first when the window is about to close with the chat (rows.sh).
  leave_window_for_kill "$pane"
  tmux kill-pane -t "$pane" 2>/dev/null || return 1
  # SessionEnd cannot fire for a pane that has been killed, so do the half of its cleanup that would otherwise show: the subagent files, which keep claiming this session has work fanned out under it. Its own record is kept on purpose — that is what leaves the row as "closed, enter resumes it".
  [ -n "$key" ] && rm -f "$STATE_DIR/sub/$key".* 2>/dev/null
  signal_ev   # the pane's own death rang once already, before these files went
  # A chat hung up on purpose must not come back after the next reboot: the snapshot is retaken now rather than at the next status-bar tick.
  resurrect_soon
  return 0
}

# A notice stays on screen until it is dismissed, so its click arrives long after the pane id in it was true: the chat may have been killed since, or tmux may have restarted and given that id to another chat. The session id still names the chat, so for a non-empty one the pane is settled against the records before anything is selected. "A pane exists" is not "the chat runs" (a chat that exited leaves its shell), so the test is the dashboard's own: the pane is in live_panes, taken once per click. The ordinary click (the named pane runs a Claude and its record names this session) costs that one walk and one read.
open_chat() {  # <open_agent|open_beside> <pane> <sid> <dir>
  local selfn=$1 pane=$2 sid=${3:-} dir=${4:-} recsid="" msg live k ts key newest="" newestts=-1 locked=0 rc
  if [ -n "$sid" ] && [ "$pane" != "-" ]; then
    live=" $(live_panes 2>/dev/null | tr '\n' ' ') "
    IFS="$US" read -r recsid _ < <(rec_row "$pane")
    case "$live" in
      *" $pane "*) [ "$recsid" = "$sid" ] && key=$pane || key="" ;;
      *) key="" ;;
    esac
    if [ -z "$key" ]; then
      # Several records can name one session (a chat resumed by hand elsewhere leaves the old one behind): one that runs a Claude is the running chat; when none does the session is over, and it comes back from the NEWEST record, whose account is the one it last ran on. A headless record has no pane to select or resume into.
      while IFS="$TAB" read -r k ts; do
        [ -n "$k" ] || continue
        case $k in %s-*) continue ;; esac
        case "$live" in *" $k "*) key=$k; break ;; esac
        case $ts in ''|*[!0-9]*) ts=0 ;; esac
        if [ "$ts" -gt "$newestts" ]; then newest=$k; newestts=$ts; fi
      done < <(panes_for_sid "$sid")
      if [ -z "$key" ] && [ -z "$newest" ]; then
        # Also on stderr: the notice helper logs a click's stderr, which is the only trace of why this click selected nothing.
        msg="tagents: that chat has ended and left no record — ctrl-y lists closed sessions"
        tmux display-message "$msg" 2>/dev/null
        printf '%s\n' "$msg" >&2
        return 0
      fi
      if [ -z "$key" ]; then
        # The session has ended: Enter on its dead row, from the record that names it. ctrl-s joins the resumed chat, enter selects it.
        resume_agent "$newest" "$sid" "$dir" "$selfn"
        return
      fi
    fi
    pane=$key
  fi
  # Two notices clicked together would run two selections over the same window. A lock that cannot be had is not a reason to do nothing: a click that does nothing is worse than a race. The wait is 3 s of wall time, whatever a try costs (at background priority 36 tries took 4.4 s, see lock_dir); the helper that runs this gives it 8 s.
  lock_dir "$STATE_DIR/.select.lock" 10 100 3 && locked=1
  "$selfn" "$pane"; rc=$?
  [ "$locked" = 1 ] && unlock_dir "$STATE_DIR/.select.lock"
  return "$rc"
}

# Every key runs through here as a short-lived child of fzf, so fzf itself never has to exit and restart. That is what keeps the list from repainting on each action — execute-silent does not touch the screen. LINE (optional) is the text of the line under the cursor: a group header has the ▾ in it, and enter and ctrl-g on the header of a session show the session instead of acting on the header's stand-in row.
act() {
  local what=${1:-} pane=${2:-} state=${3:-} sid=${4:-} dir=${5:-} line=${6:-} hdr=0 sess
  case "$line" in *▾*) hdr=1 ;; esac
  # A HEADLESS ROW IS NOT A PANE, so every verb that selects, focuses, types into or renames one has nothing to act on: the agent is a `claude -p` some daemon started, with no terminal anywhere. tmux answers "can't find pane %s-<id>" to all of them, and every one of those calls is silenced, so without this the key simply did nothing and said nothing about why. `open` on a CLOSED headless row was worse than nothing: it would have gone to resume_agent and started a fresh claude in a new window, which is not that agent coming back. ctrl-v is the one key that still works, and is what the notice points at: the popup follows the session's log. kill is deliberately left alone — ask_kill already reads a pane-less key as "forget this record", which is the only thing that can be done to such a row. Resuming the CONVERSATION is still possible where it belongs, in the closed-sessions browser (ctrl-y), which offers it once the session has actually ended.
  case "$pane" in
    %s-*)
      case "$what" in
        open|beside|goto|send|rename)
          # A CHILD IS THE SAME REFUSAL FOR A DIFFERENT REASON, and the reason is what the notice is for: it is not a daemon nobody is watching, it is a `claude -p` the agent above it started, and there is no log to follow either — ctrl-v shows its transcript instead.
          if [ -n "$(LC_ALL=C awk -F"$TAB" 'NR==1 { print $11; exit }' "$STATE_DIR/${pane#%}.tsv" 2>/dev/null)" ]; then
            tmux display-message \
              "tagents: child session — no pane to open, type into or rename (ctrl-v shows its transcript)" 2>/dev/null
          else
            tmux display-message \
              "tagents: headless session — no pane to open, type into or rename (ctrl-v follows its log)" 2>/dev/null
          fi
          return 0 ;;
      esac ;;
    @*)
      # A window that runs no chat: only selecting it makes sense.
      case "$what" in
        open|goto)
          if [ "$hdr" = 1 ]; then open_session "$pane"; else open_agent "$pane"; fi
          return 0 ;;
        beside|undock|send|rename|kill|preview)
          tmux display-message "tagents: that window runs no chat" 2>/dev/null
          return 0 ;;
      esac ;;
  esac
  sess=""
  [ "$hdr" = 1 ] && sess=$(row_group "$pane")
  case "$what" in
    open)
      if [ -n "$sess" ]; then open_session "$pane"
      elif [ "$state" = dead ]; then resume_agent "$pane" "$sid" "$dir"
      else open_chat open_agent "$pane" "$sid" "$dir"; fi ;;
    beside)
      # A closed session has no pane to join yet: bring it back first, then join it.
      if [ "$state" = dead ]; then resume_agent "$pane" "$sid" "$dir" open_beside
      else open_chat open_beside "$pane" "$sid" "$dir"; fi ;;
    goto)
      if [ -n "$sess" ]; then open_session "$pane"
      elif [ "$state" = dead ]; then tmux display-message "tagents: that chat is closed — enter resumes it" 2>/dev/null
      else goto "$pane"; fi ;;
    send)   send_line "$pane" ;;
    rename) rename_agent "$pane" "$sid" ;;
    # ctrl-v in the sidebar: a modal, not a column taken off the list.
    preview) preview_window "$pane" "$state" ;;
    new)    new_agent "$dir" "" "$(row_group "$pane")" ;;
    pick)   new_agent_pick "$dir" "$(row_group "$pane")" ;;
    undock) undock "$pane" ;;
    kill)   kill_agent "$pane" "$sid" ;;
    # The two windows about the dashboard itself rather than about an agent. They run here, in fzf own child, because this is where FZF_PORT is.
    usage)   usage_window ;;
    closed)  closed_window "$pane" ;;
    keys)    keys_window "$pane" "$state" "$sid" "$dir" ;;
    columns) columns_window ;;
  esac
}
