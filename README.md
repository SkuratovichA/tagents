# tagents

A live dashboard of every Claude Code session running under tmux — what each one
is doing, which is blocked on you, how much context it is holding and what it
has spent — with the selected chat docked beside the list so you can type into
it without leaving.

```
▾ storefront   ~/git/storefront          ⚠1 ✓1 ●1   $31.4/5h
  ├─ ⚠ BLOCKED   2:14  api      142k  $38.3  opus5    %31
  ├─ ● working   0:08  web       38k   $9.1  sonnet5  %44  ⑂2
  └─ ✓ IDLE     17:02  worker    12k   $2.7  haiku4.5 %12
▾ .dotfiles    ~/git/.dotfiles           ●1
  └─ ● working   0:31  dotfiles  71k  $44.0  opus5    %3
```

## What is in here

| file | what it does |
|------|--------------|
| `tagents` | the dashboard itself — the tree, the sidebar, the timeline |
| `tusage`  | per-session cost, dollars and context accounting, read from the transcripts |
| `hooks/tmux-agent-state.sh` | the Claude Code hook that publishes session state |
| `hooks/claude-statusline.sh` | the Claude Code status line — and the only source for which model a session is *set* to |

They are one system. The hook writes a record per session into
`~/.claude/agent-state/`; `tagents` joins that with the live tmux pane list and
renders it; `tusage` supplies the two cost columns, joined on the session id.
`tagents` degrades gracefully when `tusage` or the status line is missing, but
without the state hook there is nothing to show.

## Install

```sh
git clone git@github.com:SkuratovichA/tagents.git
cd tagents

# 1. on $PATH
ln -sf "$PWD/tagents" "$PWD/tusage" ~/.local/bin/

# 2. the hook scripts
mkdir -p ~/.claude/hooks
ln -sf "$PWD/hooks/tmux-agent-state.sh" "$PWD/hooks/claude-statusline.sh" ~/.claude/hooks/

# 3. register the hook, so Claude actually calls it
#    add tmux-agent-state.sh to ~/.claude/settings.json under "hooks" for
#    SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Notification,
#    Stop, SubagentStop and SessionEnd. PreToolUse/PostToolUse/SubagentStop
#    should be "async": true so they never sit in the tool-call critical path.

# 4. the status line, which is what feeds the model column
#    "statusLine": {
#      "type": "command",
#      "command": "sh \"$HOME/.claude/hooks/claude-statusline.sh\"",
#      "padding": 0
#    }
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
| `ctrl-u` | undock — send the docked pane home |
| `ctrl-x` | kill this agent — hang up its Claude and close its pane (asks first). On a row that is already closed, forget it instead |
| `ctrl-t` | toggle tree / flat |
| `ctrl-l` | refresh now |
| `ctrl-q` | quit |

`tagents --help` is the real documentation — the script's header explains the
model, and every non-obvious decision in it is commented with the reason.

## States

| | | |
|--|--|--|
| `⚠` | **BLOCKED** | Claude asked something and cannot go on until you answer |
| `✓` | **IDLE** | the turn ended; nothing is stuck, it is your move |
| `●` | working | a prompt or a tool call is in flight |
| `○` | new | the session just opened and has not been given anything yet |
| `✗` | closed | no Claude process in that pane — `enter` resumes it, `ctrl-x` forgets it |

Claude Code also pings a notification after about a minute of silence, which
says nothing beyond "your move". That is folded into IDLE rather than shown as
its own state with its own message, so `⚠` stays a signal worth reacting to —
including on the tmux window tab, which flags `blocked` panes only.

## Cost

Each row shows what the session has cost in dollars and which model it is on:

```
├─ ⚠ BLOCKED   2:14  api      142k  $38.3  fable5  %31  ⑂$6.94
```

**Where the number comes from.** Claude Code keeps its own cost ledger and
publishes it to the status line, so for any session that is open the dollar
figure IS that ledger — exact, and inclusive of the requests that never reach
the transcript at all (retries, conversation titles, away summaries). The status
line is registered with `refreshInterval: 30`, which matters more than it looks:
without it an idle session never re-renders, so it would sit on a stale estimate
precisely when you are staring at it wondering why the two disagree.

A figure prefixed **`~` is an estimate** — `tusage` pricing the transcript,
which is what closed sessions get, and what the `/5h` burn and the `⑂` subagent
share always are, since the ledger publishes no breakdown. Measured against the
ledger it lands within a few percent; never compare a `~` figure to the status
line and expect them to match.

**The fallback is priced per request, at the model that actually served it** —
not at the model the session is on now. That matters more than it sounds: a
session that starts on Fable ($10/MTok in) and finishes on Opus ($5), or that
fans work out to subagents on a cheaper tier, is mispriced by about 2x if you
multiply its token total by a single rate. Subagent spend is included in the
session total and also shown separately (`⑂`), because "why is this session
expensive when I have barely typed into it" is usually answered by a workflow.

`tagents --preview` / `tusage --session <id>` breaks a session down per subagent
and per model, so a mid-session switch shows up as two priced rows.

**The model column is the model the session is set to now**, which is a
different question with a different source. The transcript records the model of
every assistant *message*, so it can only ever say what answered last — flip a
session to Opus and say nothing, and the newest message on disk is still the
Fable one from an hour ago. Nothing else on disk disagrees, and the only channel
carrying the configured model is the status line payload, which is why
`hooks/claude-statusline.sh` exists. Without it the column falls back to the
last model billed, which is correct right up until you switch.

One updater at a time: the index is append-only and each updater starts from
the offset it read at entry, so two running at once append the same requests
twice and the totals silently inflate — measured at 13 requests indexed as 21.
`tusage` takes a lock (`agent-state/usage/.update.lock`); a background refresh
that loses it just returns. If the totals ever look wrong, `tusage --rebuild`
throws the index away and rescans.

Rates live in `PRICES` at the top of `tusage`, in dollars per million tokens,
with cache multipliers (5m write 1.25x, 1h write 2x, read 0.1x) applied on top.
They are checked against the ledger rather than trusted: `fable` is 15/75 there,
not the 10/50 of the public table, because 10/50 does not reproduce the bill —
solving `ledger = a*fable + b*opus` across four sessions read at one instant
gives a = 1.5 consistently. The header of `tusage` explains how to re-derive it.
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
