# States and order

Every row in the list is in one state, and the rows are in a fixed order that does not rearrange itself under you. This page says what each state means and why the list is sorted the way it is.

## The states

| | state | meaning |
|--|-------|---------|
| `⚠` | **BLOCKED** | Claude asked something and cannot go on until you answer |
| `✓` | **IDLE** | the turn ended; nothing is stuck, it is your move |
| `●` | working | a prompt or a tool call is in flight |
| `○` | new | the session just opened and has not been given anything yet |
| `✗` | closed | no Claude process in that pane: `enter` resumes it, `ctrl-x` forgets it |
| `●`… | headless | a session with no pane at all: same states, no pane to select |
| `●`… | child | a headless session an agent started itself, drawn under that agent |

Claude Code also pings a notification after about a minute of silence, which says nothing beyond "your move". That is folded into IDLE rather than shown as its own state with its own message, so `⚠` stays a signal worth reacting to, including on the tmux window tab, which flags `blocked` panes only.

## Headless sessions

A `claude -p` started by a daemon, a launchd job or a `nohup` has no tmux pane anywhere in its ancestry. It is listed all the same, in the group of the directory it was launched in, with `headless` where the location column names a pane for everybody else.

It shows the ordinary states. Liveness is the pid of its claude process, recorded by the hook, rather than a pane, and the row dims to `✗ closed` when that process is gone, without offering a resume it has nowhere to put.

What you cannot do with one is anything that needs a pane: `enter`, `ctrl-s`, `ctrl-e` and `ctrl-r` refuse with a one-line notice. `ctrl-v` is the exception, and the reason to look at such a row at all: it follows `$TA_LOG` with a live `tail -f`, and the sidebar preview shows the tail of the same file. So export the two variables before starting one:

```sh
TA_LABEL=ticket-agent TA_LOG=/tmp/ticket-agent.log \
  nohup claude -p "$prompt" >>/tmp/ticket-agent.log 2>&1 &
```

- `TA_LABEL` is the name the row shows. A headless session has no terminal title to borrow one from.
- `TA_LOG` is what `ctrl-v` follows.
- Neither is required. Without them the row is named after the title the session gave itself, or after its directory.
- A name can still be given from outside with `tagents --label <session id> NAME`.

To spawn, prompt and read headless sessions from code, see [`@tagents/core`](../architecture/overview#sessions-with-no-pane).

## Child sessions

An agent that runs `claude -p` from its own Bash tool starts a separate conversation with a session id of its own. That conversation inherits `$TMUX_PANE` from the agent that spawned it, which is how it used to overwrite that agent's row and then delete it.

Such a session is listed **under** the agent that started it: one level deeper in the tree, and in that agent's group rather than in whatever scratch worktree it runs in. It shows `child` where the location column names a pane.

```
▾ tagents  ~/git/tagents                      ●2
  └─ ● working   2:14  dashboard      …   1.0     Edit list.sh
     └─ ● working   0:41  the nightly sweep   …   child   ▸ Bash ls -la
```

How a child behaves:

- **Counting.** The `⑂` count on the parent counts it exactly as it counts a subagent, and a blocked child shows up in the group badges like any other row.
- **Naming.** It is named by `$TA_LABEL` where it has one of its own. A value it merely inherited names an ancestor rather than itself, so the hook drops it, and drops an inherited `$TA_LOG` with it, however many generations up the family the two came from. Otherwise it is named by the title the session gave itself, read out of its transcript.
- **Preview.** A child rarely has a `$TA_LOG` of its own, so `ctrl-v` and the sidebar preview show the last turns of its transcript instead of a log tail, and the pane verbs refuse with a notice of their own.
- **Resume.** It is never offered in the [closed-session](./closed-sessions) picker: resuming somebody else's conversation would start a second one on the same transcript with nobody to type at it.
- **Timeline.** The timeline still draws the hours it worked, marked with a `↳`.
- **Orphans.** A child whose parent is no longer on the list falls back to a row of its own at the top level. A grandchild joins the same block rather than opening a third level of indentation.

## The order of the list

**Projects keep the place their path gives them.** The list is not sorted by urgency: a project does not climb when one of its agents blocks and does not drop back when you answer it, so the thing you were looking at is still where you left it. The only project that moves is one with nothing running in it at all (every agent closed), and it moves once, to the dim section at the bottom. What a project is doing is in its header badge (`⚠1 ✓1 ●1`), which is a thing to read rather than a thing that rearranges the page under you.

**Inside a project, rows are ordered by when you last typed into them.** The newest conversation is on top and closed ones are underneath. The order is not by state, and not by anything that moves during a turn: the state record is rewritten on every tool call, so ordering on it made two working agents trade places while they ran. The clock here moves exactly once per turn, when you press enter, which is also why the agent you just sent something to is the one at the top.

## The clock the rows are sorted on

The second column is that same clock: how long since your last message, not how long the session has been in its current state.

It is the number that says how much of the one-hour prompt cache is left. While it reads `47:12` the next thing you send is still cheap, and once it has an `h` in it (`1h03`) the cache is gone and the whole conversation is re-read at full price.

::: tip A floor, deliberately
A long turn keeps writing the cache after your prompt, so a row that says `58:00` may have a few more minutes in it than that, never fewer.
:::

The clock comes from one file per session under `$STATE_DIR/prompt/`, written by the hook on `UserPromptSubmit` and by nothing else, and removed with the record when the session ends. A session recorded before that file existed falls back to the time of its last event, which for a finished turn is within one turn of the right answer.
