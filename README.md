# tagents

A live dashboard of every Claude Code session running under tmux — what each one
is doing, which is blocked on you, how much context it is holding and what it
has spent — with the selected chat docked beside the list so you can type into
it without leaving.

```
▾ storefront   ~/git/storefront          ⚠1 ✓1 ●1   84k/5h
  ├─ ⚠ BLOCKED   2:14  api      %31   142k  31k/5h
  ├─ ● working   0:08  web      %44    38k   9k/5h  ⑂2
  └─ ✓ idle     17:02  worker   %12    12k
▾ .dotfiles    ~/git/.dotfiles           ●1
  └─ ● working   0:31  dotfiles %3     71k  44k/5h
```

## What is in here

| file | what it does |
|------|--------------|
| `tagents` | the dashboard itself — the tree, the sidebar, the timeline |
| `tusage`  | per-session cost, dollars and context accounting, read from the transcripts |
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

## Cost

Each row shows what the session has cost in dollars and which model it is on:

```
├─ ⚠ BLOCKED   2:14  api      %31   142k  $38.3  fable5   ⑂$6.94
```

**The dollars are priced per request, at the model that actually served it** —
not at the model the session is on now. That matters more than it sounds: a
session that starts on Fable ($10/MTok in) and finishes on Opus ($5), or that
fans work out to subagents on a cheaper tier, is mispriced by about 2x if you
multiply its token total by a single rate. Subagent spend is included in the
session total and also shown separately (`⑂`), because "why is this session
expensive when I have barely typed into it" is usually answered by a workflow.

`tagents --preview` / `tusage --session <id>` breaks a session down per subagent
and per model, so a mid-session switch shows up as two priced rows.

Rates live in `PRICES` at the top of `tusage`, in dollars per million tokens,
with cache multipliers (5m write 1.25x, 1h write 2x, read 0.1x) applied on top.
A model with no published rate is **never guessed at**: its usage is excluded
and the figure is marked with a trailing `?` to say it is a floor. Add a rate
without editing the file via `TU_PRICES`:

```sh
TU_PRICES='claude-opus-5 5 25;claude-fable-5 10 50' tagents
```

## Notes

Agents are grouped by the directory they were **launched** in, not their current
one: the hook reports a live cwd that follows the Bash tool's `cd`, so grouping
on it made sessions hop between projects while you watched. The launch directory
is recovered from the first `cwd` in the transcript and cached per session id.

"Running" means a Claude process really is alive in that pane, checked against
the process tree — a state file alone proves nothing. Panes whose Claude has
exited are listed as closed and `enter` resumes them.
