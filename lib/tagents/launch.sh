# lib/tagents/launch.sh — starting an agent
#
# Every way a Claude comes into existence: session_for_dir (ownership by majority vote of live panes' cwd, the dashboard window excluded), new_agent (ctrl-n, rule-decided) and new_agent_pick (ctrl-p, always ask), the account dialog (ask_profile/ask_height), start_agent — the single place a window is created — and the resume pair moved here from the docking section (resume_agent reads the recorded account before deleting the record; resume_with either types the command into the pane's own idle shell or opens a fresh window). Both restart paths send the identical command string, which is the reason they belong in one file.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# Restart a closed session with `claude --resume <id>`, on the account it ran on
# (see resume_profile). Reuse its old pane when that pane still exists and is
# sitting at a shell; otherwise open a new window in the dashboard session —
# which has to exist before a window can be opened in it, so the sidebar is
# brought up first. Either way the result is docked and focused, exactly as
# enter on a live agent would leave it.
#
# Both paths send the SAME command string, `env` prefix and all. That is why the
# prefix is carried in the string rather than passed with tmux -e: typed into a
# shell it does the identical thing, and it steps around any claude() shell
# function that would work the account out from $PWD all over again.
resume_agent() {
  local pane=$1 sid=$2 dir=$3 cfgd hascfg sess prof
  if [ -z "$sid" ]; then
    tmux display-message "tagents: no session id recorded — cannot resume" 2>/dev/null
    return 1
  fi
  [ -d "$dir" ] || dir=$HOME
  # READ THE ACCOUNT BEFORE THE RECORD IS DELETED, which is the first thing both
  # launch paths below do. It is the account this conversation ran on, and the
  # rules never get a vote: resuming it on another login opens another history,
  # where the session simply does not exist.
  IFS="$US" read -r _ _ _ cfgd hascfg < <(rec_row "$pane")
  sess=$(tmux display -p -t "$pane" '#{session_name}' 2>/dev/null)
  [ -n "$sess" ] || sess=$DASH_SESSION
  prof=$(resume_profile "${cfgd:-}" "${hascfg:-0}" "$dir" "$sess")
  if [ "$prof" = ask ]; then
    prompt "$(ask_height)" --ask-profile resume "$pane" "$sid" "$dir" && return 0
    ask_profile resume "$pane" "$sid" "$dir"
    return 0
  fi
  resume_with "$pane" "$sid" "$dir" "$prof"
}

# The fifth argument is the tmux session a NEW window goes in, for the callers
# that know where the conversation belongs (see resume_closed). Left out — which
# is what the dead-row path in the list does — it is the dashboard session,
# exactly as it always was.
resume_with() {  # <pane> <sid> <dir> <profile> [session] — the restart itself
  local pane=$1 sid=$2 dir=$3 prof=${4:-} sess=${5:-} cmd cur newpane
  # A refusal must not become an empty string: the first path below TYPES this
  # into somebody shell, where `cd "$dir" && ` is a syntax error in their pane.
  cmd=$(agent_cmd "$prof" resume "$sid") || {
    tmux display-message "tagents: no claude profile \"$prof\" in $CONFIG_FILE" 2>/dev/null
    return 1; }

  if [ -n "$pane" ] && tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx -- "$pane"; then
    cur=$(tmux display -p -t "$pane" '#{pane_current_command}' 2>/dev/null)
    if is_shell_cmd "$cur"; then
      # Its own pane, idle at a prompt — the natural place to bring it back.
      rm -f "$STATE_DIR/${pane#%}.tsv"
      tmux send-keys -t "$pane" -l -- "cd \"$dir\" && $cmd"
      tmux send-keys -t "$pane" Enter
      open_agent "$pane"
      resurrect_soon
      return 0
    fi
  fi

  # Pane is gone, or busy with something else — do not type into it.
  rm -f "$STATE_DIR/${pane#%}.tsv"
  ensure_dash >/dev/null 2>&1 || return 1
  [ -n "$sess" ] || sess=$DASH_SESSION
  newpane=$(tmux new-window -d -t "$sess:" -P -F '#{pane_id}' \
              -c "$dir" "$cmd" 2>/dev/null) || return 1
  # Before open_agent, whose status is this function's: the capture waits for
  # the SessionStart record anyway, so it does not care which runs first.
  resurrect_soon
  open_agent "$newpane"
}

# WHICH TMUX SESSION OWNS A PROJECT. A new agent for a project belongs beside
# that project's other windows, not in the dashboard session — that is what keeps
# prefix+w, the status bar and `tmux ls` reading as one window list per project
# rather than a pile of unrelated chats under "agents".
#
# Decided by majority vote over the live panes sitting in that directory, NOT by
# asking the selected pane what session it is in: while an agent is docked its
# pane really is in the dashboard window (that is what docking does), so the
# selected row would name the dashboard session for a project that lives
# somewhere else entirely.
#
# What is skipped is the dashboard WINDOW (@tagents), not the dashboard session:
# the docked chat and the list itself sit in that window and would both vote for
# the wrong place, while an ordinary window that merely happens to live in the
# dashboard session is a real home for a project and must still count.
session_for_dir() {  # <dir> -> session name, empty when the project has no windows
  local dir=$1
  [ -n "$dir" ] || return 1
  tmux list-panes -a -F "#{session_name}$TAB#{pane_current_path}$TAB#{@tagents}" 2>/dev/null |
    awk -F"$TAB" -v dir="$dir" -v dash="$DASH_SESSION" '
      $3 != "" { next }                                   # the dashboard window
      $2 == dir || index($2, dir "/") == 1 { c[$1]++ }
      END {
        best = ""; n = -1; bd = -1
        for (s in c) {
          # On a tie, a real project session beats the dashboard session: an
          # ordinary window that happens to live under "agents" is a weaker claim
          # to being the projects home than any session of its own.
          nd = (s == dash) ? 0 : 1
          if (c[s] > n || (c[s] == n && nd > bd) || (c[s] == n && nd == bd && s < best)) {
            n = c[s]; bd = nd; best = s
          }
        }
        if (best != "") print best
      }'
}

# ctrl-n: start a fresh Claude for the project under the cursor. Works on a group
# header (the project as a whole) and on an agent row (the project it belongs
# to) — both carry a directory, so both mean the same thing here.
#
# The directory is normalised to the repo root, so a session started from
# ~/repo/packages/client makes the new agent a sibling in ~/repo rather than
# burying it in a subdirectory the tree would file separately.
new_agent() {  # <dir> [profile]
  local dir=${1:-} prof=${2:-} root sess
  [ -n "$dir" ] && [ "$dir" != "(unknown)" ] || dir=$(pwd 2>/dev/null)
  [ -d "$dir" ] || { tmux display-message "tagents: $dir is not a directory" 2>/dev/null; return 1; }
  # A NAME THAT CAME FROM A HUMAN IS CHECKED FIRST, before a window or a
  # dashboard session is brought into being for it. profile_for only ever
  # returns names the config already has; `tagents --new <dir> personl` used to
  # sail straight through to a launch on the default account, which is the exact
  # silent wrong login all of this exists to end. Not profile_named: nothing is
  # being skipped here, the launch is refused. `ask` passes — it is not a
  # profile, it is the instruction to ask for one.
  if [ -n "$prof" ] && [ "$prof" != ask ] && ! profile_exists "$prof"; then
    echo "tagents: no claude profile \"$prof\" in $CONFIG_FILE" >&2
    tmux display-message "tagents: no claude profile \"$prof\" in $CONFIG_FILE" 2>/dev/null
    return 1
  fi
  root=$(repo_root "$dir") || root=$dir

  # No windows for this project yet (every agent in it is closed, or it is new):
  # the dashboard session is the only place left that is certainly there.
  sess=$(session_for_dir "$root")
  if [ -z "$sess" ]; then
    ensure_dash >/dev/null 2>&1 || return 1
    sess=$DASH_SESSION
  fi

  # The session name is worked out first because a rule may match on it: an
  # agent for a project that lives in the "work" tmux session is a work agent
  # whatever its directory looks like.
  [ -n "$prof" ] || prof=$(profile_for "$root" "$sess") || prof=""
  if [ "$prof" = ask ]; then
    prompt "$(ask_height)" --ask-profile new "$root" "$sess" && return 0
    ask_profile new "$root" "$sess"
    return 0
  fi
  start_agent "$root" "$sess" "$prof"
}

# ctrl-p: the same thing, but always asking. A rule is a default, not a verdict —
# one agent in a personal repo that has to run on the work account is an ordinary
# request, and there is no other way to make it.
new_agent_pick() {  # <dir>
  local dir=${1:-} root sess
  [ -n "$dir" ] && [ "$dir" != "(unknown)" ] || dir=$(pwd 2>/dev/null)
  [ -d "$dir" ] || { tmux display-message "tagents: $dir is not a directory" 2>/dev/null; return 1; }
  # Asked before anything is created: with nothing to choose between, bringing
  # the dashboard session up to host a dialog that cannot open would be a window
  # out of nowhere for no reason.
  if [ -z "$(cfg_children claude.profiles)" ]; then
    tmux display-message "tagents: no claude profiles in $CONFIG_FILE" 2>/dev/null
    return 0
  fi
  root=$(repo_root "$dir") || root=$dir
  sess=$(session_for_dir "$root")
  if [ -z "$sess" ]; then
    ensure_dash >/dev/null 2>&1 || return 1
    sess=$DASH_SESSION
  fi
  prompt "$(ask_height)" --ask-profile pick "$root" "$sess" && return 0
  ask_profile pick "$root" "$sess"
}

# The one place a fresh agent gets a window. Both entry points come through here
# so the command, the message and the "it stays where it was born" policy are
# decided once.
start_agent() {  # <root> <session> <profile>
  local root=$1 sess=$2 prof=${3:-} newpane idx cmd
  # Built before the window exists: agent_cmd refuses a profile it cannot
  # account for, and opening a window on an empty command string would give you
  # a bare shell where an agent was asked for.
  cmd=$(agent_cmd "$prof" new) || {
    tmux display-message "tagents: no claude profile \"$prof\" in $CONFIG_FILE" 2>/dev/null
    return 1; }
  # -d so the window is not selected as a side effect of being created, half
  # built and before its pane id is even known; the cursor reaches the pane
  # once, deliberately, through open_agent below.
  newpane=$(tmux new-window -d -t "$sess:" -P -F '#{pane_id}' \
              -c "$root" "$cmd" 2>/dev/null) || {
    tmux display-message "tagents: could not open a window in $sess" 2>/dev/null; return 1; }

  # IT IS OPENED LIKE ANY OTHER AGENT. The home window is still created with -d
  # in the project's own session — that is where the chat lives and where it
  # goes back to on ctrl-u — but the pane is then docked into the seat you are
  # looking at and the cursor put in it, exactly what enter on its row would do
  # a moment later, and exactly what resume_with already does for a dead row.
  # Asking for an agent from the sidebar and being left looking at the previous
  # one (or, worse, taken to a bare window in another session) was never what
  # the key meant. With no sidebar to dock into, the cursor is moved to the new
  # window instead. ctrl-n and ctrl-p both land here and both behave the same.
  idx=$(tmux display -p -t "$newpane" '#{window_index}' 2>/dev/null)
  open_agent "$newpane" || goto "$newpane"
  # Every launch and every kill retakes the snapshot, so a chat is in it within
  # seconds of starting rather than at the next status-bar tick — see
  # resurrect_soon for why it is not taken at once.
  resurrect_soon
  tmux display-message \
    "tagents: new agent in $(basename "$root") ($sess:$idx)${prof:+ as $prof}" 2>/dev/null
  return 0
}

# Tall enough for the profiles plus the three header lines, the prompt and a
# little air: a picker that scrolls when it is showing three things reads as
# broken.
ask_height() {
  local n
  n=$(cfg_children claude.profiles | wc -l | tr -d ' ')
  printf '%s' "$(( ${n:-0} + 7 ))"
}

# THE ACCOUNT DIALOG — normally the body of a popup, inline when there is no
# popup to be had (including inside one; see prompt()). It is an fzf rather than
# a y/n read because the answer is one of a list, and because typing "wo<enter>"
# is the whole interaction.
ask_profile() {  # <new|pick|resume> <args…>
  local purpose=${1:-new} root sess pane sid dir
  local p pd w=0 rows="" hdr sub note pick nm
  shift
  case $purpose in
    resume) pane=${1:-}; sid=${2:-}; dir=${3:-} ;;
    *)      root=${1:-}; sess=${2:-} ;;
  esac

  for p in $(cfg_children claude.profiles); do
    [ ${#p} -gt "$w" ] && w=${#p}
  done
  [ "$w" -gt 0 ] || { tmux display-message "tagents: no claude profiles in $CONFIG_FILE" 2>/dev/null; return 0; }
  # The name is column 1 and never shown; what you read is column 2, where the
  # config dir sits next to it — the profile name alone does not say which login
  # it is, and that is the whole question being asked.
  for p in $(cfg_children claude.profiles); do
    pd=$(cfg_get "claude.profiles.$p.config_dir") || pd="default (~/.claude)"
    [ -n "$pd" ] || pd="default (~/.claude)"
    rows="$rows$p$TAB$(printf '%-*s' "$w" "$p")  $pd
"
  done

  case $purpose in
    new)
      hdr="which claude account for $(basename "$root")?"
      sub="$(tilde_of "$root") · session $sess"
      note="no rule in $(tilde_of "$CONFIG_FILE") decides this · esc cancels" ;;
    pick)
      hdr="start a new agent in $(basename "$root") as…"
      sub="$(tilde_of "$root") · session $sess"
      note="whatever the rules in $(tilde_of "$CONFIG_FILE") say · esc cancels" ;;
    resume)
      nm=$(label_of "${sid:-$pane}")
      [ -n "$nm" ] || nm=$(basename "${dir:-?}")
      hdr="resume $nm as…"
      sub="$(tilde_of "$dir") · session ${sid:-?}"
      note="its record does not say which account it ran on · esc cancels" ;;
  esac

  # Not piped into `cut`: under pipefail an esc (fzf exits 130) would take the
  # whole pipeline down, and the empty answer is the normal way out of here.
  #
  # FZF DRAWS ON STDERR. Its UI is written to fd 2 so that stdout can be the
  # answer; only the input comes from /dev/tty. So `2>/dev/null` on an fzf that
  # is meant to be LOOKED AT is a blank modal that still takes keys — the
  # picker "did not work" for a whole session on fzf 0.52 before this was
  # traced (lsof on the running fzf: 2w /dev/null, 3r /dev/tty, nothing else).
  # None of the dialogs here — this one, rename, columns, the ? window —
  # may silence it; tests/ui.sh scans for exactly that.
  pick=$(printf '%s' "$rows" | fzf --delimiter="$TAB" --with-nth=2 \
           --layout=reverse --height=100% --no-info --prompt='account> ' \
           --header="$hdr
$sub
$note")
  pick=${pick%%$TAB*}
  [ -n "$pick" ] || return 0
  profile_exists "$pick" || return 0

  case $purpose in
    new|pick) start_agent "$root" "$sess" "$pick" ;;
    resume)   resume_with "$pane" "$sid" "$dir" "$pick" ;;
  esac
}
