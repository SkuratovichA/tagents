# tagents

A live dashboard of every Claude Code session running under tmux — what each one
is doing, which is blocked on you, how much context it is holding and what it
has spent — with the selected chat docked beside the list so you can type into
it without leaving.

```
▾ salon-reach  ~/git/work/salon-reach   ⚠1 ✓1 ●1   84k/5h
  ├─ ⚠ BLOCKED   2:14  api      %31   142k  31k/5h
  ├─ ● working   0:08  web      %44    38k   9k/5h  ⑂2
  └─ ✓ idle     17:02  worker   %12    12k
▾ .dotfiles    ~/git/personal/.dotfiles  ●1
  └─ ● working   0:31  dotfiles %3     71k  44k/5h
```

## What is in here

| file | what it does |
|------|--------------|
| `tagents` | the dashboard itself — the tree, the sidebar, the timeline |
| `tusage`  | per-session cost and context accounting, read from the transcripts |
| `hooks/tmux-agent-state.sh` | the Claude Code hook that publishes session state |

The three are one system. The hook writes a record per session into
`~/.claude/agent-state/`; `tagents` joins that with the live tmux pane list and
renders it; `tusage` supplies the two cost columns, joined on the session id.
`tagents` degrades gracefully when `tusage` is missing, but without the hook
there is nothing to show.

## Install

```sh
git clone git@github.com:SkuratovichA/tagents.git
cd tagents

# 1. on $PATH
ln -sf "$PWD/tagents" "$PWD/tusage" ~/.local/bin/

# 2. the hook script
mkdir -p ~/.claude/hooks
ln -sf "$PWD/hooks/tmux-agent-state.sh" ~/.claude/hooks/

# 3. register the hook, so Claude actually calls it
#    add tmux-agent-state.sh to ~/.claude/settings.json under "hooks" for
#    SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Notification,
#    Stop, SubagentStop and SessionEnd. PreToolUse/PostToolUse/SubagentStop
#    should be "async": true so they never sit in the tool-call critical path.
```

Needs `tmux`, `fzf`, `jq` and `awk`. Written for bash 3.2 on purpose — macOS
ships nothing newer.

As part of [.dotfiles](https://github.com/SkuratovichA/.dotfiles) this repo is a
submodule at `tagents/`, and `scripts/bootstrap.sh` does all three steps above.

## Using it

```
tagents               interactive dashboard
tagents --timeline    who worked when over the last day, as bars
tagents --counts      compact summary, for the tmux status bar
```

Keys inside the dashboard:

| key | |
|-----|--|
| `enter` | dock that agent's pane into the sidebar and put the cursor in it |
| `ctrl-n` | start a new agent in the project under the cursor |
| `ctrl-g` | go to the agent where it lives instead |
| `ctrl-o` | borrow the agent's whole window into this session |
| `ctrl-e` | type a line straight into that agent without leaving |
| `ctrl-r` | name this agent (`F2` too) |
| `ctrl-x` | undock — send the docked pane home |
| `ctrl-t` | toggle tree / flat |
| `ctrl-l` | refresh now |
| `ctrl-q` | quit |

`tagents --help` is the real documentation — the script's header explains the
model, and every non-obvious decision in it is commented with the reason.

## Notes

Agents are grouped by the directory they were **launched** in, not their current
one: the hook reports a live cwd that follows the Bash tool's `cd`, so grouping
on it made sessions hop between projects while you watched. The launch directory
is recovered from the first `cwd` in the transcript and cached per session id.

"Running" means a Claude process really is alive in that pane, checked against
the process tree — a state file alone proves nothing. Panes whose Claude has
exited are listed as closed and `enter` resumes them.
