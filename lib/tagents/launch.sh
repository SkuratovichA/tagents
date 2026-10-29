# lib/tagents/launch.sh — starting an agent
#
# Every way a Claude comes into existence: session_for_dir (ownership by majority vote of live panes' cwd, for a chat started with no group to put it in), new_agent (ctrl-n, rule-decided) and new_agent_pick (ctrl-p, always ask) — both open a new window in the session of the group the cursor is in — the account dialog (ask_profile/ask_height), start_agent, new_shell (ctrl-a) — both through launch_session and new_pane_window, the single place a window is created — and the resume pair (resume_agent reads the recorded account before deleting the record; resume_with either types the command into the pane's own idle shell or opens a fresh window). Both restart paths send the identical command string, which is the reason they belong in one file. Every launch ends in <after> (default open_agent, rows.sh), which selects the chat like any row.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# Set by the entry points of --new and --window when their first word is --detach: the window is made and left where it is, no dialog is opened and nothing is selected or switched to. Reset here so that nothing in the environment can switch it on.
LAUNCH_DETACH=""

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
  [ "$w" -gt 0 ] || { notice "tagents: no claude profiles in $CONFIG_FILE"; return 0; }
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

# Restart a closed session with `claude --resume <id>`, on the account it ran on (see resume_profile). Reuse its old pane when that pane still exists and is sitting at a shell; otherwise open a new window in the session the row was in. <after> is what runs on the pane that was started (default: select it like any row; ctrl-s passes open_beside).
#
# Both paths send the SAME command string, `env` prefix and all. That is why the prefix is carried in the string rather than passed with tmux -e: typed into a shell it does the identical thing, and it steps around any claude() shell function that would work the account out from $PWD all over again.
resume_agent() {  # <pane> <sid> <dir> [after]
  local pane=$1 sid=$2 dir=$3 after=${4:-open_agent} cfgd hascfg sess prof
  if [ -z "$sid" ]; then
    notice "tagents: no session id recorded — cannot resume"
    return 1
  fi
  [ -d "$dir" ] || dir=$HOME
  # READ THE ACCOUNT BEFORE THE RECORD IS DELETED, which is the first thing both launch paths below do. It is the account this conversation ran on, and the rules never get a vote: resuming it on another login opens another history, where the session simply does not exist.
  IFS="$US" read -r _ _ _ cfgd hascfg < <(rec_row "$pane")
  sess=$(row_session "$pane")
  [ -n "$sess" ] || sess=$(client_session "")
  prof=$(resume_profile "${cfgd:-}" "${hascfg:-0}" "$dir" "$sess")
  if [ "$prof" = ask ]; then
    prompt "$(ask_height)" --ask-profile resume "$pane" "$sid" "$dir" && return 0
    ask_profile resume "$pane" "$sid" "$dir"
    return 0
  fi
  resume_with "$pane" "$sid" "$dir" "$prof" "$sess" "$after"
}

# The restart itself. The fifth argument is the tmux session a NEW window goes in (the group the cursor was in); left out, it is the session of the old pane, else the client's. With the old pane at an idle shell the command is typed into it; otherwise a new detached window is made in that session. A profile question asked in a dialog loses <after> and selects.
resume_with() {  # <pane> <sid> <dir> <profile> [session] [after]
  local pane=$1 sid=$2 dir=$3 prof=${4:-} sess=${5:-} after=${6:-open_agent} cmd cur newpane
  # A refusal must not become an empty string: the first path below TYPES this into somebody's shell, where `cd "$dir" && ` is a syntax error in their pane.
  cmd=$(agent_cmd "$prof" resume "$sid") || {
    notice "tagents: no claude profile \"$prof\" in $CONFIG_FILE"
    return 1; }

  if [ -n "$pane" ] && tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx -- "$pane"; then
    cur=$(tmux display -p -t "$pane" '#{pane_current_command}' 2>/dev/null)
    if is_shell_cmd "$cur"; then
      # Its own pane, idle at a prompt — the natural place to bring it back.
      rm -f "$STATE_DIR/${pane#%}.tsv"
      tmux send-keys -t "$pane" -l -- "cd \"$dir\" && $cmd"
      tmux send-keys -t "$pane" Enter
      "$after" "$pane"
      resurrect_soon
      return 0
    fi
  fi

  # Pane is gone, or busy with something else — do not type into it.
  rm -f "$STATE_DIR/${pane#%}.tsv"
  [ -n "$sess" ] || sess=$(row_session "$pane")
  ! session_is_cockpit "$sess" || sess=""
  [ -n "$sess" ] || sess=$(client_session "")
  ! session_is_cockpit "$sess" || sess=""
  [ -n "$sess" ] || sess=$(tmux display -p '#{session_name}' 2>/dev/null)
  ! session_is_cockpit "$sess" || sess=""
  [ -n "$sess" ] || sess=$LAST_RESORT_SESSION
  newpane=$(new_pane_window "$sess" "$dir" "$cmd") || {
    notice "tagents: could not open a window in $sess"; return 1; }
  # Before <after>, whose status is this function's: the capture waits for the SessionStart record anyway, so it does not care which runs first.
  resurrect_soon
  "$after" "$newpane"
}

# WHICH TMUX SESSION OWNS A PROJECT, for a chat started with no group to put it in (`tagents --new` from a shell): the session where most of the live panes sitting in that directory are. The dashboard's own session never owns one: the caller skips it.
session_for_dir() {  # <dir> -> session name, empty when the project has no windows
  local dir=$1
  [ -n "$dir" ] || return 1
  tmux list-panes -a -F "#{session_name}$TAB#{pane_current_path}$TAB#{?#{@tagents_cockpit},1,0}" 2>/dev/null |
    LC_ALL=C awk -F"$TAB" -v dir="$dir" '
      $3 == 1 { next }
      $2 == dir || index($2, dir "/") == 1 { c[$1]++ }
      END {
        best = ""; n = -1
        for (s in c) if (c[s] > n || (c[s] == n && s < best)) { n = c[s]; best = s }
        if (best != "") print best
      }'
}

# The session a chat gets when there is no session to put it in: no tmux server at all, or one with none. The previous version made the same one for it.
LAST_RESORT_SESSION=agents

# The session a new window goes in when the caller named none: the one that owns the root, else the client's, else the current, else the last resort. An empty root skips the vote (a shell started from a row with no directory).
launch_session() {  # <root> -> session name
  local root=${1:-} sess=""
  [ -z "$root" ] || sess=$(session_for_dir "$root")
  ! session_is_cockpit "$sess" || sess=""
  [ -n "$sess" ] || sess=$(client_session "")
  ! session_is_cockpit "$sess" || sess=""
  [ -n "$sess" ] || sess=$(tmux display -p '#{session_name}' 2>/dev/null)
  ! session_is_cockpit "$sess" || sess=""
  [ -n "$sess" ] || sess=$LAST_RESORT_SESSION
  printf '%s\n' "$sess"
}

# The one place a window is created, for a chat and a shell alike; prints the new pane id, its status is tmux's. -d so the window is not selected as a side effect of being created; -c always, because a window made from a command client starts in the caller's directory without it; no command means tmux's default shell; `--` ends tmux's own options, so a command that starts with a dash is the command and not a flag.
# The last resort session does not exist yet (no tmux server running, or none with a session): it is created with the window as its first. Any other name that is gone is a session killed under the caller, and it stays gone.
new_pane_window() {  # <session> <dir> [cmd]
  local sess=$1 dir=$2 cmd=${3:-}
  if [ "$sess" = "$LAST_RESORT_SESSION" ] && ! tmux has-session -t "=$sess" 2>/dev/null; then
    tmux new-session -d -s "$sess" -P -F '#{pane_id}' -c "$dir" ${cmd:+-- "$cmd"} 2>/dev/null
  else
    tmux new-window -d -t "=$sess:" -P -F '#{pane_id}' -c "$dir" ${cmd:+-- "$cmd"} 2>/dev/null
  fi
}

# Says why a launch was refused. The tmux message is for a person at the keyboard; a caller that passed --detach is a program, and what it can read is standard error and the exit status, so there the reason goes to standard error as well and a failed tool call carries its reason.
launch_refusal() {  # <message>
  [ -z "$LAUNCH_DETACH" ] || echo "$1" >&2
  notice "$1"
}

# ctrl-n: start a fresh Claude for the project under the cursor, as a new window of <session> (the group the cursor is in). With no session given (`tagents --new`, or the cursor on the group `no window`) the session that owns the project, else the client's, else the current. The directory is normalised to the repo root, so a session started from ~/repo/packages/client makes the new agent a sibling in ~/repo rather than burying it in a subdirectory the tree would file separately.
new_agent() {  # <dir> [profile] [session]
  local dir=${1:-} prof=${2:-} sess=${3:-} root abs
  [ -n "$dir" ] && [ "$dir" != "(unknown)" ] || dir=$(pwd 2>/dev/null)
  abs=$(abs_dir "$dir") || { launch_refusal "tagents: $dir is not a directory"; return 1; }
  dir=$abs
  # A NAME THAT CAME FROM A HUMAN IS CHECKED FIRST, before a window is created for it. profile_for only ever returns names the config already has; `tagents --new <dir> personl` used to sail straight through to a launch on the default account, which is the exact silent wrong login all of this exists to end. Not profile_named: nothing is being skipped here, the launch is refused. `ask` passes — it is not a profile, it is the instruction to ask for one.
  if [ -n "$prof" ] && [ "$prof" != ask ] && ! profile_exists "$prof"; then
    echo "tagents: no claude profile \"$prof\" in $CONFIG_FILE" >&2
    notice "tagents: no claude profile \"$prof\" in $CONFIG_FILE"
    return 1
  fi
  root=$(repo_root "$dir") || root=$dir
  [ -n "$sess" ] || sess=$(launch_session "$root")
  # The session name is worked out first because a rule may match on it: an agent for a project that lives in the "work" tmux session is a work agent whatever its directory looks like.
  [ -n "$prof" ] || prof=$(profile_for "$root" "$sess") || prof=""
  if [ "$prof" = ask ]; then
    # A caller with no screen to answer on cannot be shown the dialog: it is told which accounts there are and asked again with one.
    if [ -n "$LAUNCH_DETACH" ]; then
      echo "tagents: the config asks which account $root runs on, and --detach opens no dialog; name one of: $(cfg_children claude.profiles | paste -sd' ' -)" >&2
      return 2
    fi
    prompt "$(ask_height)" --ask-profile new "$root" "$sess" && return 0
    ask_profile new "$root" "$sess"
    return 0
  fi
  start_agent "$root" "$sess" "$prof"
}

# ctrl-p: the same thing, but always asking. A rule is a default, not a verdict — one agent in a personal repo that has to run on the work account is an ordinary request, and there is no other way to make it.
new_agent_pick() {  # <dir> [session]
  local dir=${1:-} sess=${2:-} root
  [ -n "$dir" ] && [ "$dir" != "(unknown)" ] || dir=$(pwd 2>/dev/null)
  [ -d "$dir" ] || { notice "tagents: $dir is not a directory"; return 1; }
  # Asked before anything is created: with nothing to choose between, a window out of nowhere for a dialog that cannot open would be for no reason.
  if [ -z "$(cfg_children claude.profiles)" ]; then
    notice "tagents: no claude profiles in $CONFIG_FILE"
    return 0
  fi
  root=$(repo_root "$dir") || root=$dir
  [ -n "$sess" ] || sess=$(launch_session "$root")
  prompt "$(ask_height)" --ask-profile pick "$root" "$sess" && return 0
  ask_profile pick "$root" "$sess"
}

# ctrl-a: a plain shell in a new window of <session> (the group the cursor is in), starting where the row works: its directory, else the session's own path, else home. Nothing is asked and no chat is recorded, so no resurrect_soon.
new_shell() {  # <dir> [session]
  local dir=${1:-} sess=${2:-} pane idx
  case $dir in /*) [ -d "$dir" ] || dir="" ;; *) dir="" ;; esac
  [ -n "$sess" ] || sess=$(launch_session "$(repo_root "$dir" || printf '%s' "$dir")")
  [ -n "$dir" ] || dir=$(tmux display -p -t "=$sess:" '#{session_path}' 2>/dev/null)
  [ -n "$dir" ] && [ -d "$dir" ] || dir=$HOME
  pane=$(new_pane_window "$sess" "$dir") || {
    notice "tagents: could not open a window in $sess"; return 1; }
  idx=$(tmux display -p -t "$pane" '#{window_index}' 2>/dev/null)
  open_agent "$pane"
  notice "tagents: new shell in $(basename "$(tilde_of "$dir")") ($sess:$idx)"
}

# A directory made absolute, printed; it fails for an empty name (`cd -- ""` is a no-op that would answer with the current directory) and for one that is not a directory. The path is the PHYSICAL one (norm_dir), because tmux's pane_current_path and the session lookup compare physical paths. A relative name is the caller's, and everything downstream of a launch (the repository root, the session that owns it, tmux's `-c`) reads it as a path, so it is resolved here, once. CDPATH is emptied, or a relative name could be looked up elsewhere and `cd` would print where it went into the substitution.
abs_dir() {  # <dir>
  [ -n "$1" ] && [ -d "$1" ] && norm_dir "$1"
}

# The line a caller finds its new window by: the pane, a tab, and where it is as session:window index. `--window` always prints it, `--new` only with `--detach`, whose caller is a program that cannot look at the screen.
window_line() {  # <pane> <session> <index>
  printf '%s\t%s:%s\n' "$1" "$2" "$3"
}

# `tagents --window [--detach] DIR COMMAND`: the twin of --new for anything that is not an agent, from outside the list. COMMAND is one string the window's shell runs, so the window closes when it ends: a long-running command is what this is for, and a bare `ls` is gone before anyone sees it. The window goes where a chat for DIR would, the session that owns it, is shown like any new window (open_agent) unless --detach, and the line printed is the new pane and where it is, TAB-separated, for a caller that wants to find it again. Exactly two words: a command typed without quotes arrives as several, and the extra ones would be dropped without a word.
new_window() {  # <dir> <command>
  local dir cmd root sess pane idx
  if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
    echo "tagents: --window takes a directory and one command, quoted" >&2
    return 2
  fi
  cmd=$2
  dir=$(abs_dir "$1") || { echo "tagents: $1 is not a directory" >&2; return 1; }
  root=$(repo_root "$dir") || root=$dir
  sess=$(launch_session "$root")
  pane=$(new_pane_window "$sess" "$dir" "$cmd")
  [ -n "$pane" ] || { echo "tagents: could not open a window in $sess" >&2; return 1; }
  idx=$(tmux display -p -t "$pane" '#{window_index}' 2>/dev/null)
  [ -n "$LAUNCH_DETACH" ] || open_agent "$pane"
  notice "tagents: new window in $(basename "$(tilde_of "$dir")") ($sess:$idx)"
  window_line "$pane" "$sess" "$idx"
}

# The one place a fresh agent gets a window. Both entry points come through here so the command, the message and the "it is selected like any row" policy are decided once.
start_agent() {  # <root> <session> <profile>
  local root=$1 sess=$2 prof=${3:-} newpane idx cmd
  # Built before the window exists: agent_cmd refuses a profile it cannot account for, and a window on an empty command string would be a bare shell where an agent was asked for.
  cmd=$(agent_cmd "$prof" new) || {
    launch_refusal "tagents: no claude profile \"$prof\" in $CONFIG_FILE"
    return 1; }
  # -d so the window is not selected as a side effect of being created, half built and before its pane id is even known; it is selected once, deliberately, below.
  # The last resort session does not exist yet (no tmux server running, or none with a session): it is created with the chat as its first window. Any other name that is gone is a session killed under the caller, and it stays gone.
  newpane=$(new_pane_window "$sess" "$root" "$cmd")
  [ -n "$newpane" ] || {
    launch_refusal "tagents: could not open a window in $sess"; return 1; }
  idx=$(tmux display -p -t "$newpane" '#{window_index}' 2>/dev/null)
  # OPENED LIKE ANY OTHER AGENT: the viewport shows it and the cursor is on its row. Asking for an agent from the list and being left looking at the previous one was never what the key meant. With no dashboard up the client is simply taken to the new window. A detached start leaves everything where it was.
  [ -n "$LAUNCH_DETACH" ] || open_agent "$newpane"
  resurrect_soon
  notice \
    "tagents: new agent in $(basename "$root") ($sess:$idx)${prof:+ as $prof}"
  [ -z "$LAUNCH_DETACH" ] || window_line "$newpane" "$sess" "$idx"
  return 0
}
