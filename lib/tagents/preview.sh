# lib/tagents/preview.sh — a row, up close
#
# preview() — the body fzf and the popup both show: state, session id, account, per-subagent cost, then the headless log tail, the dead-session resume command, or a live capture-pane — plus the ctrl-v window around it (preview_name's heading order, preview_window, ask_preview's tail -f/less/read fallbacks, and preview_popup's 0.3 s detour for the one caller that is itself a popup). The 'THE PREVIEW AS A WINDOW OF ITS OWN' essay heads the file.
#
# Part of ./tagents; `tagents --help` is the model this implements.

preview() {
  local pane=$1 state=${2:-} f ts st sid cwd tr detail cfgd hascfg acct rprof log
  [ "$pane" = "-" ] && return 0
  f="$STATE_DIR/${pane#%}.tsv"
  if [ -e "$f" ]; then
    # Not IFS=TAB: tab is IFS whitespace, so an empty field (no session id, no
    # detail) would collapse and shift every later value one slot left.
    IFS="$US" read -r ts st sid cwd tr detail cfgd hascfg < <(
      awk -F"$TAB" -v OFS="$US" \
          'NR==1 { print $1, $2, $3, $4, $5, $6, $7, (NF >= 7 ? 1 : 0); exit }' "$f")
    printf '\033[1m%s\033[0m\n' "$(origin_of "${sid:-}" "${tr:-}" || printf '%s' "$cwd")"
    [ -n "$cwd" ] && printf '\033[90mcwd now: %s\033[0m\n' "$cwd"
    printf '\033[90m%s · %s\033[0m\n' "$st" "$detail"
    [ -n "$sid" ] && printf '\033[90msession %s\033[0m\n' "$sid"
    # Which login this conversation belongs to — the thing you cannot see from
    # the pane itself, and the thing that decides whether resuming it will find
    # anything. Silent for a record written before the hook recorded it.
    acct=$(profile_of_cfg "${cfgd:-}" "${hascfg:-0}")
    [ -n "$acct" ] &&
      printf '\033[90maccount: %s  (%s)\033[0m\n' "$acct" "${cfgd:-default ~/.claude}"
    # What this session has actually cost, broken down by every subagent and
    # workflow it spawned — the part that is invisible from the pane itself.
    if [ -n "$sid" ] && command -v tusage >/dev/null 2>&1; then
      tusage --no-update --session "$sid" 2>/dev/null | tail -n +2
    fi
    printf '\033[90m%s\033[0m\n' "----------------------------------------"
  fi
  # A PANE-LESS SESSION HAS NOTHING TO CAPTURE, and nothing to resume into
  # either, so it takes neither branch below. Its output went to $TA_LOG, which
  # the hook wrote down; the tail of that file is this row's capture-pane, and a
  # snapshot for the same reason capture-pane is one — the preview is re-rendered
  # on every repaint, while a `tail -f` here would never return and would hang
  # the pane fzf draws it in. ctrl-v opens the same log as a real follow.
  case "$pane" in
    %s-*)
      if log=$(headless_log "$pane"); then
        printf '\033[90mheadless — no pane. log (ctrl-v follows it):\n%s\033[0m\n' "$log"
        tail -n 60 "$log" 2>/dev/null
      else
        printf '\033[90mheadless session — it runs in no pane, so there is nothing\n'
        printf 'to show here and nothing to dock. No readable $TA_LOG was\n'
        printf 'recorded for it either; export TA_LOG before starting one.\033[0m\n'
      fi
      return 0 ;;
  esac
  if [ "$state" = dead ]; then
    # The REAL command, account prefix and all — built the same way enter builds
    # it. Printing the bare RESUME_CMD here said the session would come back on
    # whatever account you happened to be on, which is the misunderstanding this
    # whole thing exists to end.
    # Silenced HERE and nowhere else: this runs on every preview refresh, and
    # fzf captures only stdout from a preview command, so a warning about a
    # misspelt rule would land on the dashboard terminal a few times a second.
    # --profile-for, --config and the launch paths stay loud, which is where
    # somebody is actually asking the config a question.
    rprof=$(resume_profile "${cfgd:-}" "${hascfg:-0}" "${cwd:-}" "$DASH_SESSION" 2>/dev/null)
    printf '\033[90mno Claude running in this pane any more.\n\nenter runs:\033[0m\n'
    if [ "$rprof" = ask ]; then
      printf '  \033[90m(enter asks which account first)\033[0m\n'
    else
      printf '  %s\n' "$(agent_cmd "$rprof" resume "${sid:-<unknown>}")"
    fi
    [ -n "${tr:-}" ] && [ -e "${tr:-}" ] &&
      printf '\n\033[90mlast lines of its transcript:\033[0m\n' &&
      tail -n 3 "$tr" | cut -c1-400
    return 0
  fi
  tmux capture-pane -e -p -t "$pane" 2>/dev/null | tail -n 60
}

# ---------------------------------------------------------------------------
# ctrl-v: THE PREVIEW AS A WINDOW OF ITS OWN
#
# It used to be fzf's own preview pane, and in the sidebar that is the wrong
# shape: the list is already only 45% of a window, and taking 55% of THAT for a
# preview left a column too narrow to read either half in. So ctrl-v opens a
# popup at the size prefix+C-f, tsess and tneww open at — 80% by 85% — and the
# list is not disturbed at all.
#
# It is a snapshot, deliberately. The live view of an agent is the agent's own
# pane docked beside the list, one enter away; what this is for is the part of
# the preview that does not fit on one screen — the per-subagent cost breakdown
# and the tail of the transcript — so it goes through a pager and can be
# scrolled, and refreshing it matters less than that.
# ---------------------------------------------------------------------------

# The heading of that page: the name the row shows for the agent, resolved the
# way ask_kill resolves it — the label first, then the pane title with Claude
# leading glyph off it, then the project. Deliberately NOT the way
# sync_window_names resolves it: a heading falling back to the project is
# better than a heading with a bare pane id in it, while a WINDOW named after
# its own directory is a rename tmux automatic-rename would only undo.
preview_name() {  # <pane>
  local pane=${1:-} sid dir lbl nm
  IFS="$US" read -r sid dir lbl < <(
    awk -F"$TAB" -v OFS="$US" 'NR==1 { print $3, $4, $10; exit }' \
        "$STATE_DIR/${pane#%}.tsv" 2>/dev/null)
  nm=$(label_of "${sid:-$pane}")
  if [ -z "$nm" ]; then
    nm=$(untitle_of "$(tmux display -p -t "$pane" '#{pane_title}' 2>/dev/null)")
    # tmux default pane title is the host name, which names nothing.
    [ "$nm" = "$(hostname -s 2>/dev/null)" ] && nm=""
  fi
  # $TA_LABEL — the same fallback the row itself uses, and the only name a
  # headless session has: no pane means no pane title to strip a glyph off.
  [ -n "$nm" ] || nm=$lbl
  [ -n "$nm" ] || nm=$(basename "${dir:-$pane}")
  printf '%s' "$nm"
}

preview_window() {  # <pane> <state> — what ctrl-v runs
  local pane=${1:-} state=${2:-}
  [ -n "$pane" ] && [ "$pane" != "-" ] || return 0
  prompt_at 80% 85% --ask-preview "$pane" "$state" && return 0
  # dash() binds ctrl-v to fzf own toggle-preview wherever a popup cannot be
  # had, so this is only reached when popups went away underneath a running
  # list. Say so rather than printing a screenful into a pane fzf is drawing
  # over — that is the invisible freeze the popups exist to avoid.
  tmux display-message "tagents: no popup here to show the preview in" 2>/dev/null
  return 0
}

ask_preview() {  # <pane> <state> — the body of that popup
  local pane=${1:-} state=${2:-} nm ans log
  [ -n "$pane" ] && [ "$pane" != "-" ] || return 0
  nm=$(preview_name "$pane")
  # THE LIVE VIEW OF A HEADLESS AGENT IS ITS LOG, because it has no pane to dock
  # beside the list and enter cannot give it one. So this popup is the one place
  # that follows it: the record and the last lines first, then a real `tail -f`
  # that keeps printing until ctrl-c closes the popup with it. Deliberately NOT
  # through `less`: paging a stream that never ends shows one screen and waits.
  if log=$(headless_log "$pane"); then
    printf '\033[1m%s\033[0m  \033[90mctrl-c closes · tail -f %s\033[0m\n' "${nm:-$pane}" "$log"
    preview "$pane" "$state"
    tail -n 0 -f "$log" 2>/dev/null
    return 0
  fi
  # less takes the scrolling and gives back a q that closes the popup with it
  # (the body exits, so the popup does). Without it the text is simply printed
  # and any key closes it — no scrollback, but the popup is still readable and
  # still closes.
  if command -v less >/dev/null 2>&1; then
    { printf '\033[1m%s\033[0m  \033[90mq closes\033[0m\n' "${nm:-$pane}"
      preview "$pane" "$state"; } | less -R
    return 0
  fi
  printf '\033[1m%s\033[0m  \033[90many key closes\033[0m\n' "${nm:-$pane}"
  preview "$pane" "$state"
  # Bounded, like every other read here: this owns the popup tty, and a read
  # that never returns is a popup with no way out but killing it.
  IFS= read -r -t 300 -n 1 ans 2>/dev/null
  return 0
}

# THE ? WINDOW CANNOT OPEN THIS ITSELF. That window is a popup, and a
# display-popup issued from inside a popup returns rc=0 and does nothing at all
# — so :preview hands the job to `run-shell -b`, a detached child of the tmux
# SERVER, which is outside the popup. But that child starts while the ? popup is
# still on screen, and the same rule would bite it there. Hence the sleep: it is
# a race against ask_keys returning and tmux tearing its popup down, and tmux
# offers nothing to wait on for it. 0.3s is comfortably longer than that takes
# and short enough not to read as a delay; losing the race costs one keypress,
# and nothing is left behind by it.
preview_popup() {  # <pane> <state>
  sleep 0.3
  # A server child has none of the popup environment, TA_MODE included, so
  # prompt_at opens the popup here instead of refusing the way it does inside
  # one.
  preview_window "$@"
}
