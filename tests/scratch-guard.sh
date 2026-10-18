# tests/scratch-guard.sh — sourced by every tmux suite before it does anything.
#
# A suite runs inside the owner's tmux more often than not, so $TMUX points at
# the LIVE server, and any bare `tmux` (or `tagents`) call that reaches the
# default socket — after the suite has unset TMUX, say — lands on it. That has
# happened once: hooks left on the live server, still pointing at a deleted temp
# tree. So a suite refuses to start unless it is run as
#
#   env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/<suite>.sh
#
# which makes the default socket a scratch one: even a bare `tmux` in a child
# process then reaches a server nobody else uses.
#
# bash 3.2. The caller passes its own name for the message.

scratch_guard() {
  local name=${1:-suite} dir real
  if [ -z "${TMUX_TMPDIR:-}" ]; then
    echo "$name: TMUX_TMPDIR is not set, so a bare tmux call would reach the live server." >&2
    echo "$name: run  env -u TMUX -u TMUX_PANE TMUX_TMPDIR=\"\$(mktemp -d)\" bash tests/$name" >&2
    return 1
  fi
  dir=$(cd -P "$TMUX_TMPDIR" 2>/dev/null && pwd -P) || {
    echo "$name: TMUX_TMPDIR ($TMUX_TMPDIR) is not a directory." >&2; return 1; }
  # tmux keeps its default sockets in /tmp/tmux-<uid>; /tmp is /private/tmp here.
  case "$dir" in
    /tmp|/private/tmp|/var/tmp|/private/var/tmp)
      echo "$name: TMUX_TMPDIR is the system default ($dir): that is where the live server's socket is." >&2
      return 1 ;;
  esac
  # A $TMUX left in the environment outranks TMUX_TMPDIR for every tmux call.
  if [ -n "${TMUX:-}" ]; then
    real=${TMUX%%,*}
    case "$real" in
      "$dir"/*) ;;
      *) echo "$name: TMUX ($real) is not under TMUX_TMPDIR: run with env -u TMUX -u TMUX_PANE." >&2
         return 1 ;;
    esac
  fi
  return 0
}
