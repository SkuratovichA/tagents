# lib/tagents/actions.sh — what a key actually does
#
# The verbs: borrow/give_back (link a window into the home session and unlink it), goto, send_line/ask_send, and the ctrl-x family (kill_agent, ask_kill's live re-check, end_agent, forget_agent) with the 'killing an agent' essay heading that half. act() lives here too — the short-lived execute-silent child every binding runs through, and the place that refuses pane-verbs on a headless row.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# ---------------------------------------------------------------------------
# actions
# ---------------------------------------------------------------------------

win_index_in() {  # <window_id> <session> -> index, empty if not linked there
  tmux list-windows -t "$2" -F '#{window_index} #{window_id}' 2>/dev/null |
    awk -v w="$1" '$2==w { print $1; exit }'
}

borrow() {  # bring the agent's window into $home without moving it out of its own session
  local pane=$1 home=$2 win src idx
  [ "$pane" = "-" ] && return 0
  win=$(tmux display -p -t "$pane" '#{window_id}' 2>/dev/null) || return 0
  src=$(tmux display -p -t "$pane" '#{session_name}' 2>/dev/null)
  if [ "$src" != "$home" ]; then
    idx=$(win_index_in "$win" "$home")
    if [ -z "$idx" ]; then
      tmux link-window -s "$win" -t "$home:" 2>/dev/null
      idx=$(win_index_in "$win" "$home")
    fi
    [ -n "$idx" ] && tmux select-window -t "$home:$idx" 2>/dev/null
  else
    tmux select-window -t "$win" 2>/dev/null
  fi
  tmux select-pane -t "$pane" 2>/dev/null
  tmux switch-client -t "$home" 2>/dev/null
}

goto() {
  local pane=$1 sess win
  [ "$pane" = "-" ] && return 0
  sess=$(tmux display -p -t "$pane" '#{session_name}' 2>/dev/null) || return 0
  win=$(tmux display -p -t "$pane" '#{window_index}' 2>/dev/null)
  tmux switch-client -t "$sess" 2>/dev/null
  tmux select-window -t "$sess:$win" 2>/dev/null
  tmux select-pane -t "$pane" 2>/dev/null
}

give_back() {
  local pane=$1 home=$2 win idx
  [ "$pane" = "-" ] && return 0
  win=$(tmux display -p -t "$pane" '#{window_id}' 2>/dev/null) || return 0
  idx=$(win_index_in "$win" "$home")
  # unlink-window refuses when this is the window's last session, so a window
  # that actually lives here cannot be destroyed by accident.
  [ -n "$idx" ] && tmux unlink-window -t "$home:$idx" 2>/dev/null
}

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
  # The list itself is a pane in the same window as the chat it docks, and it is
  # never an agent row — but a marker can drift, and killing the list from the
  # list is not a mistake worth allowing.
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
  dir=$(awk -F"$TAB" 'NR==1 { print $4 }' "$STATE_DIR/${pane#%}.tsv" 2>/dev/null)
  if [ "$alive" = 1 ]; then
    [ -z "$dir" ] && dir=$(tmux display -p -t "$pane" '#{pane_current_path}' 2>/dev/null)
    if [ -z "$nm" ]; then
      nm=$(untitle_of "$(tmux display -p -t "$pane" '#{pane_title}' 2>/dev/null)")
      [ "$nm" = "$(hostname -s 2>/dev/null)" ] && nm=""
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

end_agent() {  # <pane> — hang up the agent running in it
  local pane=$1 key=${pane#%}
  # Send it home first if it is docked. Killing it where it sits leaves the
  # placeholder parked in its seat pointing at a pane that no longer exists;
  # slot() does clear that up by itself, but only after two ticks, and until
  # then that seat of the sidebar is blank for no visible reason. Asked of this
  # pane alone: another chat may be docked beside it, and it is not the one being
  # killed.
  is_docked "$pane" && undock_pane "$pane"
  tmux kill-pane -t "$pane" 2>/dev/null || return 1
  # SessionEnd cannot fire for a pane that has been killed, so do the half of
  # its cleanup that would otherwise show: the subagent files, which keep
  # claiming this session has work fanned out under it. Its own record is kept
  # on purpose — that is what leaves the row as "closed, enter resumes it".
  [ -n "$key" ] && rm -f "$STATE_DIR/sub/$key".* 2>/dev/null
  return 0
}

forget_agent() {  # <pane-key> — drop a closed session's record from the list
  local key=${1#%}
  [ -n "$key" ] || return 0
  rm -f "$STATE_DIR/$key.tsv" 2>/dev/null
  rm -f "$STATE_DIR/sub/$key".* 2>/dev/null
  # ...and when you last typed into it, which is what the row was ordered on.
  rm -f "$STATE_DIR/prompt/$key" 2>/dev/null
  return 0
}

# Every key runs through here as a short-lived child of fzf, so fzf itself never
# has to exit and restart. That is what keeps the list from repainting on each
# action — execute-silent does not touch the screen.
act() {
  local what=${1:-} pane=${2:-} state=${3:-} sid=${4:-} dir=${5:-}
  # A HEADLESS ROW IS NOT A PANE, so every verb that docks, focuses, types into
  # or renames one has nothing to act on: the agent is a `claude -p` some daemon
  # started, with no terminal anywhere. tmux answers "can't find pane %s-<id>"
  # to all of them, and every one of those calls is silenced, so without this
  # the key simply did nothing and said nothing about why. `open` on a CLOSED
  # headless row was worse than nothing: it would have gone to resume_agent and
  # started a fresh claude in a new window, which is not that agent coming back.
  # ctrl-v is the one key that still works, and is what the notice points at:
  # the popup follows the session's log. kill is deliberately left alone —
  # ask_kill already reads a pane-less key as "forget this record", which is the
  # only thing that can be done to such a row. Resuming the CONVERSATION is
  # still possible where it belongs, in the closed-sessions browser (ctrl-y),
  # which offers it once the session has actually ended.
  case "$pane" in
    %s-*)
      case "$what" in
        open|beside|borrow|goto|send|rename)
          tmux display-message \
            "tagents: headless session — no pane to dock, type into or rename (ctrl-v follows its log)" \
            2>/dev/null
          return 0 ;;
      esac ;;
  esac
  case "$what" in
    open)
      # Same thing wherever the list is running: the chat ends up in the sidebar's
      # current seat with the cursor in it. See open_agent().
      if [ "$state" = dead ]; then
        resume_agent "$pane" "$sid" "$dir"
      else
        open_agent "$pane"
      fi ;;
    beside)
      # A closed session has no pane to put anywhere yet, so bring it back first —
      # which docks it in the current seat. ctrl-s on the NEXT one then puts that
      # one beside it, which is the order this happens in anyway.
      if [ "$state" = dead ]; then
        resume_agent "$pane" "$sid" "$dir"
      else
        open_beside "$pane"
      fi ;;
    borrow) borrow "$pane" "${TA_HOME:-}" ;;
    goto)   goto "$pane" ;;
    send)   send_line "$pane" ;;
    rename) rename_agent "$pane" "$sid" ;;
    # ctrl-v in the sidebar: a modal, not a column taken off the list.
    preview) preview_window "$pane" "$state" ;;
    new)    new_agent "$dir" ;;
    pick)   new_agent_pick "$dir" ;;
    undock)
      # Send the chat in the current seat home. With nothing docked, the only
      # other way a window gets pulled in here is ctrl-o's borrow — undo that
      # instead.
      undock || give_back "$pane" "${TA_HOME:-}" ;;
    kill)   kill_agent "$pane" "$sid" ;;
    # The two windows about the dashboard itself rather than about an agent.
    # They run here, in fzf own child, because this is where FZF_PORT is.
    usage)   usage_window ;;
    closed)  closed_window ;;
    keys)    keys_window "$pane" "$state" "$sid" "$dir" ;;
    columns) columns_window ;;
  esac
}
