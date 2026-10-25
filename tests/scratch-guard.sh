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
# A suite killed before its EXIT trap runs (kill -9, a closed terminal, a runner's timeout) leaves its tmux server and every client behind, and once a server freezes each of those clients spins at 100% CPU until somebody notices; four of them ran for an hour on 25.10.2026. Socket names do not find them all (`script` keepers, clients of a socket already unlinked), so the run is tagged instead: scratch_guard exports TA_SUITE_RUN, which every process the suite starts inherits (the tmux server forks from its first client and its panes get the server's environment), and starts a reaper that waits for the suite to end however it ends and then kills every process whose environment still carries the tag. macOS hides the environment of its own binaries from `ps` (sleep, script, /bin/sh), so what the tag finds is tmux, the server and every client, which are the processes that spin; the rest goes with them: a pane's processes get SIGHUP when the server is gone and `script` ends with its client. A keeper's `sleep 300` is left to end by itself.
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
  scratch_reaper
  return 0
}

# The reaper is started from a subshell that exits at once, so it is not a job of the suite (a bare `wait` in the suite would otherwise wait for it, and it for the suite) and, with -m, it is in a process group of its own, which a ^C to the suite does not reach. It does not carry the tag itself, and the tag reaches awk through REAP_TAG, whose field in `ps` output reads REAP_TAG=TA_SUITE_RUN=..., so neither matches.
scratch_reaper() {
  TA_SUITE_RUN="tasuite-$$-$(date +%s)"
  export TA_SUITE_RUN
  ( set -m
    REAP_SUITE=$$ REAP_TAG="TA_SUITE_RUN=$TA_SUITE_RUN" env -u TA_SUITE_RUN /bin/sh -c '
      trap "" HUP INT TERM
      while kill -0 "$REAP_SUITE" 2>/dev/null; do sleep 1; done
      pids=$(ps axeww -o pid= -o command= 2>/dev/null | awk -v me="$$" '\''
        $1 != me { for (i = 2; i <= NF; i++) if ($i == ENVIRON["REAP_TAG"]) { print $1; break } }'\'')
      [ -z "$pids" ] || kill -9 $pids 2>/dev/null
    ' </dev/null >/dev/null 2>&1 & )
}
