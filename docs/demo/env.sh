# docs/demo/env.sh — the environment every demo process runs in. Sourced, never executed.
#
# Everything the real tagents, the real state hook and tmux would write goes under $DEMO_ROOT, and HOME is moved there too, so nothing reaches ~/.claude or the owner's tmux server.

DEMO_SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$DEMO_SRC/../.." && pwd)

# A unix socket path is limited to ~100 bytes, so the root stays short.
DEMO_ROOT=${DEMO_ROOT:-/tmp/tagents-demo}
mkdir -p "$DEMO_ROOT" && DEMO_ROOT=$(cd "$DEMO_ROOT" && pwd -P)

export DEMO_SRC REPO DEMO_ROOT
export HOME="$DEMO_ROOT/home"
export TMUX_TMPDIR="$DEMO_ROOT/tmux"
export TA_STATE_DIR="$DEMO_ROOT/state"
export TA_CONFIG="$HOME/.config/tagents/config.toml"
export TA_HOST=demo SHELL=/bin/bash
export TA_COUNTS_EVERY=0
export TA_RESURRECT_YOUNG=0 TA_RESURRECT_SOON=2 TA_RESURRECT_RETAKE=2
export DEMO_CTL="$DEMO_ROOT/ctl" DEMO_CHATS="$DEMO_ROOT/chats" DEMO_USAGE="$DEMO_ROOT/usage"
export DEMO_HOOK="$REPO/hooks/tmux-agent-state.sh" DEMO_STATUSLINE="$REPO/hooks/claude-statusline.sh"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export TERM=${TERM:-xterm-256color}
export PATH="${DEMO_FZF_DIR:+$DEMO_FZF_DIR:}$DEMO_SRC/bin:$REPO:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
unset TMUX TMUX_PANE CLAUDE_PID CLAUDE_CONFIG_DIR TA_LOG TA_LABEL TA_MODE TA_FLAT TA_COLS TA_NEW_CMD TA_RESUME_CMD TA_HOME TA_SESSION FZF_DEFAULT_OPTS
mkdir -p "$TMUX_TMPDIR"
