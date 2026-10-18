# lib/tagents/core.sh — constants, and the plumbing every dialog is built on
#
# The globals the whole program reads (STATE_DIR and the TA_* overrides, the TAB/US separators) plus the four helpers that belong to no feature: has_popup/prompt/prompt_at (why a prompt must be a tmux popup and not an fzf `execute` child — that essay, lines 1775-1797, heads the file), post_fzf (how a popup pokes the list that spawned it), pane_exists (a row can be 2 s stale) and tilde_of — and the ones shared by the restart paths: is_shell_cmd (the one kind of pane safe to replace) and the mkdir lock lock_dir/lock_age/unlock_dir. Sourced first, so every STATE_DIR-derived global later is legal.
#
# Part of ./tagents; `tagents --help` is the model this implements.

# Where the hook writes. Overridable only so the renderer can be pointed at a
# throwaway directory; the hook honours the same variable, so both move together.
STATE_DIR=${TA_STATE_DIR:-$HOME/.claude/agent-state}
DASH_SESSION=${TA_SESSION:-agents}
# Subagent records are cleared explicitly on SubagentStop and on the parent's
# Stop, so this is only a safety net for records that never got cleaned up. It
# has to outlast a single long tool call, or a subagent running one 10-minute
# command would silently drop out of the count.
SUB_TTL=${TA_SUB_TTL:-1800}
DEAD_TTL=${TA_DEAD_TTL:-86400}  # how long a closed session stays offered for resume
DASH_WIDTH=${TA_WIDTH:-45}    # percent of the dashboard window the list occupies
RESUME_CMD=${TA_RESUME_CMD:-claude --dangerously-skip-permissions --resume}
# Starting a fresh agent in a project, as opposed to resuming a closed one.
NEW_CMD=${TA_NEW_CMD:-claude --dangerously-skip-permissions}
# Naming an agent is bound here rather than to a function key: a Mac keyboard
# either has no F-row at all or needs fn held down for it, which is no way to
# reach a key you use constantly. ctrl-r costs fzf nothing it does not already
# have another key for, and F2 stays as an alias. It used to be ctrl-n, which
# ctrl-n now needs for "new agent here"; refresh moved off ctrl-r to ctrl-l, the
# terminal's own redraw key, to make room. The default itself lives in
# KEY_DEFAULTS below with every other key; TA_RENAME_KEY still overrides it, and
# so does keys.rename in the config.
TAB=$'\t'
US=$'\037'   # unit separator: unlike tab it is not IFS whitespace, so `read`
             # keeps empty fields instead of silently shifting the rest left

# The other direction, for anything a human reads: a header three lines tall has
# no room for /Users/<name>/ on every one of them.
tilde_of() {  # <path>
  local p=${1:-}
  case $p in "$HOME"/*) printf '~%s' "${p#$HOME}" ;; *) printf '%s' "$p" ;; esac
}

# What an idle pane looks like to tmux: the shell itself in front, nothing it
# started. Anything else is somebody's editor, build or chat, and a restart
# leaves it alone.
is_shell_cmd() {  # <pane_current_command> — an idle shell, the one thing safe to type into or replace
  case ${1:-} in zsh|bash|sh|fish|dash|tcsh|ksh) return 0 ;; esac
  return 1
}

# mkdir is the atomic primitive (macOS has no flock). A lock older than <stale> seconds belongs to a process that died holding it and is taken over. tnotes carries its own copy as take_lock (tnotes:216-228) — that script stands alone — still without the bound below.
# Every pass costs a try, the takeover included: a mkdir that fails for any other reason (a parent nobody may write to) gives up after the tries instead of spinning on a takeover that never lands.
# A short sleep is not a short wait: a process at background priority (a detached worker, measured) has its timers coalesced, and there `sleep 0.05` took 0.12 s, so 36 tries were 4.4 s instead of 3. [seconds] bounds the wait by the clock as well; SECONDS counts whole seconds, so N waits between N-1 and N.
lock_dir() {  # <dir> <stale seconds> [tries, 0.05 s apart; default 40] [seconds]
  local d=$1 stale=$2 tries=${3:-40} end=
  [ -n "${4:-}" ] && end=$((SECONDS + $4))
  mkdir -p "${d%/*}" 2>/dev/null
  while :; do
    mkdir "$d" 2>/dev/null && return 0
    [ "$(lock_age "$d")" -gt "$stale" ] && rm -rf "$d" 2>/dev/null
    tries=$((tries - 1)); [ "$tries" -gt 0 ] || return 1
    [ -n "$end" ] && [ "$SECONDS" -ge "$end" ] && return 1
    sleep 0.05
  done
}
# How long a lock has been held. One stat cannot read is as young as now, never an age measured from the epoch: that is a lock missing or out of reach, not one somebody died holding.
lock_age() {  # <dir> -> seconds
  local now; now=$(date +%s)
  printf '%s' $(( now - $(stat -f %m "$1" 2>/dev/null || echo "$now") ))
}
# The release, a statement of its own on every path out: never a `trap ...
# RETURN`, which bash 3.2 fires again when the caller returns (see collapse_seat).
unlock_dir() { rm -rf "${1:?}" 2>/dev/null; return 0; }

# tmux default pane title is the machine name, which names nothing — and it is
# the FULL name (`hostname`, sukas-MacBook-Pro.local) while the comparisons
# here were all made against the short one (`hostname -s`), so on a Mac the
# default title slipped through as the name of every agent that had not set a
# title of its own. Both forms are "nothing"; anything else somebody chose.
host_title() {  # <title> — true when it is only the host name
  case ${1:-} in
    '') return 1 ;;
    "$(hostname -s 2>/dev/null)"|"$(hostname 2>/dev/null)") return 0 ;;
  esac
  return 1
}

# Prompts run in a tmux popup, not in the dashboard pane. fzf's `execute` hands
# the terminal to the child, which puts the prompt under fzf's alternate screen
# where it is invisible, and lets a child that never returns wedge the whole
# dashboard. A popup is its own little terminal: always on top, and closing it
# cannot hurt the list.
has_popup() { tmux list-commands display-popup >/dev/null 2>&1; }

# Non-zero means "this tmux cannot do popups — ask in place instead". A popup
# that could have opened but did not (nobody attached to this session, say) is
# NOT a reason to fall back: dash() only binds the in-place prompt to `execute`
# when popups are unavailable, so falling back here would leave a read blocking
# invisibly behind execute-silent — exactly the freeze this all exists to avoid.
prompt() {  # <height> <args for $SELF...>
  local h=$1
  shift
  # 60% wide is the width of a question: one line to read and one to type into.
  prompt_at 60% "$h" "$@"
}

# The same popup at a size given by the caller, for the one body that is not a
# question but a page — the ctrl-v preview, which wants the room prefix+C-f,
# tsess and tneww all open at. Kept as a second entry point rather than a third
# argument on prompt() so no existing dialog can change size by accident.
prompt_at() {  # <width> <height> <args for $SELF...>
  local w=$1 h=$2
  shift 2
  # A display-popup issued from INSIDE a popup returns rc=0 and silently does
  # nothing, so in prefix+a mode every prompt here was dead: the key appeared to
  # work, the popup closed, and nothing had been asked. There is no second popup
  # to be had — but a popup is a terminal of its own, so the inline body works
  # perfectly well there. dash() binds these keys to `execute` in popup mode so
  # fzf hands the terminal over for it.
  [ "${TA_MODE:-}" = popup ] && return 1
  has_popup || return 1
  # No `--` before the command: tmux 3.4 does not take one there and fails
  # silently. Every argument is ours, so nothing needs quoting anyway.
  if [ -n "${TMUX_PANE:-}" ]; then
    tmux display-popup -E -w "$w" -h "$h" -t "$TMUX_PANE" "$SELF" "$@" 2>/dev/null
  else
    tmux display-popup -E -w "$w" -h "$h" "$SELF" "$@" 2>/dev/null
  fi || tmux display-message "tagents: no client here to prompt on" 2>/dev/null
  return 0
}

# RINGING THE CHANNELS where tagents itself writes something the list draws.
# The refresher no longer looks on a timer: it sleeps on the tmux channel
# tagents-ev, and whatever changes the picture without a tmux command of its own
# (a label, an origin, a hidden column, a forgotten row) has to say so. 'panes'
# rings the slots' channel, tagents-panes, too. One tmux call, no output, and
# nothing at all outside tmux: with no $TMUX the call would go to the default
# server, which is somebody else's. A change made from a shell outside tmux is
# seen at the refresher's next wake or at its idle timeout.
#
# THE SLOTS' CHANNEL IS RUNG TOGETHER WITH A COUNT. Two signals with no waiter
# cancel each other (a signal nobody waits for is remembered, a second one clears
# it), so a slot that is busy with a lap while two rings arrive would sleep through
# both. Every ring of tagents-panes therefore also adds one to the global option
# @tagents_gen, which is the same server-side command and starts no program; a
# slot reads it in the list-panes it makes anyway, and waits only if it has not
# moved since (see slot).
GEN_BUMP='#{e|+|:#{@tagents_gen},1}'
# THE REFRESHER'S CHANNEL IS RUNG WITH A COUNT TOO, for the same reason and the
# same way: every ring of tagents-ev first adds one to the global option
# @tagents_evgen, in the same tmux call and BEFORE the signal, so a ring that
# lands while the refresher is between two waits is a number that moved, not a
# signal that cancelled another one. The refresher reads the number in the call
# that takes its snapshot and waits only while it has not moved (see refresher).
# The hook (hooks/tmux-agent-state.sh) is POSIX sh and cannot source this file, so
# it carries a copy of EV_BUMP; tests/refresh.sh pins the two against each other.
#   EV_BUMP, GEN_BUMP   the format that adds one to the option it is set into
#   EV_SIGNAL           the command text of a tmux hook: both channels, both counts
#   RING_EV, RING_BOTH  the same as arguments to one tmux call, after a `\;`
EV_BUMP='#{e|+|:#{@tagents_evgen},1}'
EV_SIGNAL="set -gF @tagents_evgen '$EV_BUMP' ; wait-for -S tagents-ev ; wait-for -S tagents-panes ; set -gF @tagents_gen '$GEN_BUMP'"
RING_EV=(set -gF @tagents_evgen "$EV_BUMP" ';' wait-for -S tagents-ev)
RING_BOTH=("${RING_EV[@]}" ';' wait-for -S tagents-panes ';' set -gF @tagents_gen "$GEN_BUMP")
signal_ev() {  # [panes]
  [ -n "${TMUX:-}" ] || return 0
  if [ "${1:-}" = panes ]; then
    tmux "${RING_BOTH[@]}" 2>/dev/null
  else
    tmux "${RING_EV[@]}" 2>/dev/null
  fi
  return 0
}

# IS A REFRESHER ALIVE? By the start marker each one keeps (.refresher.<pid>.start,
# see refresher), whose pid has to pass kill -0: a refresher that was killed with
# -9 leaves its marker behind until the next one's sweep. Builtins only, no
# program. The pid in $1 is left out, which is how a refresher asks "another one?"
# (other_refresher); the status bar's --counts asks with no argument, to know that
# the cache it prints is being kept (see counts).
refresher_alive() {  # [pid to leave out]
  local f n pid
  for f in "$STATE_DIR"/.refresher.[0-9]*.start; do
    [ -e "$f" ] || continue
    n=${f##*/}; n=${n#.refresher.}; pid=${n%%.*}
    case $pid in ''|*[!0-9]*) continue ;; esac
    [ "$pid" = "${1:-}" ] && continue
    kill -0 "$pid" 2>/dev/null && return 0
  done
  return 1
}

# A whole file into the variable named by $1, every byte of it, trailing newlines
# included: -d '' reads to the end, IFS= keeps the edges, and the braces keep the
# error of a missing file away from the caller (the redirection fails before a
# 2>/dev/null on read does). A missing file leaves the variable empty. No process
# is started.
slurp() {  # <variable name> <file>
  local _slurp_c=""
  { IFS= read -r -d '' _slurp_c <"$2"; } 2>/dev/null
  printf -v "$1" '%s' "$_slurp_c"
}

# Telling the list that runs this picker to redraw. fzf takes actions on its
# --listen port, and FZF_PORT is exported to the children of its own bindings —
# but a tmux popup is spawned by the SERVER and inherits nothing of that, so the
# port travels as an argument, like the row fields do. No port (a bare --list
# from a script, or a test) is not an error: the toggle still happens, it is
# just not seen until the next refresher tick.
post_fzf() {  # <port> <fzf action> — curl's exit status; 0 when there is no port
  [ -n "${1:-}" ] || return 0
  curl -s -XPOST "http://127.0.0.1:$1" -d "$2" >/dev/null 2>&1
}
