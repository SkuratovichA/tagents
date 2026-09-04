# tagents

A live dashboard of every Claude Code session running under tmux — what each one
is doing, which is blocked on you, how much context it is holding and what it
has spent — with the selected chat docked beside the list so you can type into
it without leaving.

```
▾ storefront   ~/git/storefront          ⚠1 ✓1 ●1   $31.4/5h
  ├─ ⚠ BLOCKED   2:14  w api       142k  $38.3  opus5    work      %31
  ├─ ● working   0:08  w web        38k   $9.1  sonnet5  work      %44  ⑂2
  └─ ✓ IDLE     17:02  w worker     12k   $2.7  haiku4.5 work      %12
▾ .dotfiles    ~/git/.dotfiles           ●1
  └─ ● working   0:31  p dotfiles   71k  $44.0  opus5    personal  %3
```

state · age · **badge** · name · context · cost · model · **account** · pane.
Both bold columns say which Claude login the session is on, named after the
profile in `config.yaml` that claims its `CLAUDE_CONFIG_DIR` — see
[Configuration](#configuration). The account name appears on wide lists only;
the badge is one or two characters and is on every row at every width — `p`,
`w`, the first letter of the profile name unless `badge:` says otherwise (more
than two is clipped to two, since the column is as wide as the widest of them).
Both stay blank for a session whose state record predates them rather than
guessing, and with no profiles configured the badge column does not exist at
all.

## What is in here

| file | what it does |
|------|--------------|
| `tagents` | the dashboard itself — the tree, the sidebar, the timeline |
| `tusage`  | per-session cost, dollars and context accounting, read from the transcripts |
| `hooks/tmux-agent-state.sh` | the Claude Code hook that publishes session state |
| `hooks/claude-statusline.sh` | the Claude Code status line — and the only source for which model a session is *set* to |
| `hooks/notes-context.sh` | the Claude Code hook that carries the notes folder's diff into the prompt |
| `hooks/notes-autocommit.sh` | the Claude Code hook that commits what Claude writes into the notes folder |
| `config.example.yaml` | a commented example of the optional per-directory account config |

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
| `enter` | dock that agent's pane into the sidebar's current seat and put the cursor in it |
| `ctrl-s` | dock it *beside* the current seat instead — two chats side by side |
| `ctrl-n` | start a new agent in the project under the cursor |
| `ctrl-p` | the same, but choose the Claude account by hand whatever the rules say |
| `ctrl-g` | go to the agent where it lives instead |
| `ctrl-o` | borrow the agent's whole window into this session |
| `ctrl-e` | type a line straight into that agent without leaving |
| `ctrl-r` | name this agent (`F2` too) |
| `ctrl-u` | undock — send the chat in the current seat home and close the seat behind it |
| `ctrl-x` | kill this agent — hang up its Claude and close its pane (asks first). On a row that is already closed, forget it instead |
| `ctrl-t` | toggle tree / flat |
| `ctrl-v` | the preview — cost per subagent, the tail of the transcript — in a modal window of its own, scrollable, `q` closes it (with no `less` on `$PATH` it is printed instead and any key closes it). In the `prefix+a` popup, and on a tmux with no popups at all, it stays fzf's own preview beside the list: a popup cannot open a second popup |
| `ctrl-l` | refresh now |
| `ctrl-w` | show or hide columns — see [Hiding columns](#hiding-columns) |
| `?` | every key in a window of its own, and `enter` runs the one you pick |
| `ctrl-q` | quit |

The header above the list is one line: `enter · ? keys · ctrl-q quit`.
Everything else is behind `?`, which acts on the row the cursor was on — so it
is a way to *use* a key you half-remember, not a printed list. The direct keys
above all still work. `?` is a printable character, so one thing it costs is
typing a `?` into the filter query; `ctrl-w` costs the other — that was fzf's
delete-the-word-before-the-cursor in the query. Those two keys are the whole
bill, and the query is a project name long.

`tagents --help` is the real documentation — the script's header explains the
model, and every non-obvious decision in it is commented with the reason.

## Hiding columns

`ctrl-w` opens a small window with a checkmark per column — `badge`, `ctx`,
`cost`, `model`, `acct`, `loc`. `enter` toggles the one under the cursor and the
list behind reloads immediately; the picker stays open, `esc` closes it.

Hiding `cost` takes **every** figure in dollars with it: the column, the `⑂`
subagent share and the project header's `/5h` total — money you are not
currently spending against a limit is the distraction this exists for. (`⑂2`,
the subagent *count*, is not money and stays.) Nothing is ever reordered: the
freed width goes to the detail column, exactly as it does when the pane itself
is narrow.

What is hidden lives one key per line in `$STATE_DIR/cols`, so it survives a
restart. `TA_HIDE_COLS=cost,model tagents` overrides that file for a single run,
and `tagents --hidden-cols` prints what is in force.

## Several chats side by side

The sidebar window holds **seats**: panes the dashboard owns, each of them either
a placeholder (the grey "pick an agent" pane) or a chat docked into one. `enter`
opens a chat in the seat you were last in, `ctrl-s` opens one in a new seat
beside it — so `enter` on A and `ctrl-s` on B leaves you with

```
columns(list, A, B)
```

both live and typeable. With nothing docked yet there is nothing to sit beside,
so `ctrl-s` opens in the empty seat exactly as `enter` would, rather than
standing a blank placeholder a whole chat wide between the list and the chat.

The list says which is which: a `▶` on the row of the
chat whose seat the cursor is in — the one `enter` is about to replace — and a
dim `▹` on every other docked chat. `ctrl-u` sends the current seat's chat home
and closes the seat behind it, so the layout shrinks back to `columns(list, A)`.
The last seat always stays; that pane is what says "pick an agent on the left".

**Panes you opened yourself are never touched.** What the dashboard owns is said
by two markers (`@tagents_docked`, `@tagents_slot`) and by nothing else, so a
terminal split off beside the list is never swapped, broken out or killed here,
whatever the pane order in that window happens to be. It used to be answered by
position — the first pane that is not the list — which was true only while the
window had exactly two panes.

**Closing a pane must not close a session.** A docked pane *is* the session's own
pane — that is what makes it typeable — so `prefix+x` on it hangs up the Claude
for good, and no tmux hook can veto a kill. The answer is a binding that asks
first, in your `.tmux.conf`:

```tmux
bind-key x if-shell -F '#{@tagents_docked}' \
  "run-shell \"tagents --undock-pane '#{pane_id}'\"" kill-pane
bind-key & run-shell "tagents --undock-window '#{window_id}'" \; kill-window
```

`tagents --undock-pane` sends that chat home and exits 0; on anything else — the
list, a placeholder, your own terminal — it does nothing and exits 1, so the
binding stays a plain `kill-pane` everywhere else. `--undock-window` does the
same for every chat docked in a window and always exits 0.

## Windows are named after their agents

The dashboard is one way to find an agent. `prefix+w`, the status bar and `tmux
ls` are the other, and they are the ones that work when the dashboard is not on
screen — so the tmux window an agent lives in is named after that agent.

The name is the one the list shows: the label you gave it with `ctrl-r`, or the
session's terminal title (what Claude's `/rename` sets) when you have not. Never
the directory — tmux's own `automatic-rename` already names a window after what
is running in it, and that name is right. A window renames itself within about
ten seconds of the name changing while the dashboard is up, and within thirty
when it is not: the status bar runs the same pass, throttled, so this works with
no dashboard open at all.

**A window several agents share is named after the one with the newest
activity** — the agent you are actually working with names the window. Panes
with no name to give are not candidates, so a shell split off beside an agent
never takes the window's name.

**A name you typed is never overwritten.** A window is only ever renamed when
its current name is tmux's automatic one, or the name `tagents` itself gave it
last time (recorded in the window option `@tagents_name`). Rename a window by
hand in tmux and nothing here touches it again, until the day its name coincides
with one of those two. The dashboard window, any window a list is running in and
chats docked into a sidebar are all left out of it.

`tagents --sync-names` runs one pass by hand, which is the way to see what it
would do.

## Configuration

Optional, and only about one thing: **which Claude account an agent is started
on**. Without `~/.config/tagents/config.yaml` (or `$TA_CONFIG`) nothing below
happens and every agent is started exactly as it always was — a plain `claude
--dangerously-skip-permissions`, environment inherited, no dialog ever.

### The bug it fixes

`tmux new-window "<command>"` runs that command through `/bin/sh` as a direct
child of the **tmux server**. Your interactive shell is never involved, so
`.zshrc` never runs — and `.zshrc` is where a per-directory account is usually
chosen. The tmux server has no `CLAUDE_CONFIG_DIR` of its own, so every agent
started from the dashboard ran on the default account whatever directory it was
in, silently and for as long as nobody looked.

An account is a config dir, and it is a whole **login**, not a preference:
Claude Code derives its keychain item from the literal path, so
`~/.claude-personal` and `~/.claude` are two independent logins. Unset is a
third thing again and is not the same as empty — which is why every launch goes
out as `env -u CLAUDE_CONFIG_DIR [CLAUDE_CONFIG_DIR=…] claude …`, prefix carried
in the command string so the identical string also works when it is typed into a
shell (the resume-in-place path) and so it steps around any `claude()` shell
function that would resolve the account all over again.

### The file

```yaml
claude:
  # What every agent is started with, unless a profile overrides it.
  # A string (your own shell words, verbatim) or a list (each item quoted).
  args: --dangerously-skip-permissions

  profiles:
    personal:
      config_dir: ~/.claude-personal
      # badge: p    # the row column before the agent name. Defaults to the
      #             # first character of the profile name, so personal and work
      #             # are p and w already; set it when two accounts collide.
    work:
      # config_dir omitted: CLAUDE_CONFIG_DIR is UNSET for this one. Omit it,
      # do not write ~/.claude — set and unset are different keychain items.
      # command: claude                                     # binary or wrapper
      # args: --dangerously-skip-permissions --model opus   # replaces claude.args
      # env:
      #   ANTHROPIC_BASE_URL: https://proxy.example.com

  # First match wins. `dir` matches that directory and everything under it, by
  # path component (~/git/personalx is not under ~/git/personal). `session`
  # matches when the tmux session name CONTAINS the text. Both present means
  # both must match; neither present is a catch-all.
  rules:
    - dir: ~/git/personal
      profile: personal
    - session: work
      profile: work

  # When nothing matches. `ask` (the default) opens a picker; a profile name
  # settles it silently.
  default: ask
```

Every `config_dir` you name here needs its own copy of Install steps 2–4 — the
`hooks/` symlinks and the `settings.json` entries — inside it. A config dir with
no `settings.json` runs no state hook and no status line, so agents started on
it never appear in the dashboard at all and have no model column, which reads as
a `tagents` bug and is a config-dir one.

The parser is a deliberate YAML subset — mappings, sequences, `#` comments,
single- and double-quoted scalars. Tabs for indentation, flow style (`{}`,
`[]`), block scalars (`|`, `>`) and anchors are refused with a one-line warning
naming the line, and the rest of the file is still read.

### Choosing by hand

`profile: ask`, `default: ask`, or **`ctrl-p`** on any row open a small picker
over the profiles. `ctrl-p` ignores the rules entirely, which is the answer to
"this one agent in a personal repo has to run on the work account".

**Resuming never consults the rules.** The account a closed session comes back
on is the one it actually ran on, recorded as the 7th field of its state record
by `hooks/tmux-agent-state.sh` — a conversation resumed on another login is
simply not there. A record written before that field existed falls back to the
rules, and asks if they say `ask`.

### Checking it

```sh
tagents --config                    # the file as tagents reads it, path<TAB>value
tagents --profile-for ~/git/work    # which profile the rules pick for a directory
tagents --agent-cmd personal new    # the exact command string a launch would run
tagents --new ~/git/thing personal  # start one from outside the dashboard
```

`--config` is the thing to look at when a rule will not fire: it prints one leaf
per line (`claude.rules.0.dir`), which is also how a rule is referred to in the
warnings.

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

## Notes workspace

A chat is a bad place to review a document. `.claude/notes/` — one per project,
next to `.claude/settings.local.json` — is where the long-form output goes
instead: Claude writes `<name>.md` files there, you open them in neovim, and
what you type back reaches the session on your next prompt. Chat replies stay in
chat; only documents go to the folder.

`prefix + C-t` toggles it ("text"): the editor opens beside the Claude pane it
was called from, on the notes folder of that pane's project. `:q` sends —
whatever is in `prompt.md` is delivered to that session and the file is cleared,
so the editor doubles as the place to write a long prompt without fighting the
terminal's line editing. The editor itself lives in a hidden `ta-notes` tmux
session and is only ever *linked* into the window you are looking at, which is
why toggling it does not disturb the layout you had.

The folder is a git repo of its own, and that is the whole mechanism:

- **Claude's writes are committed for it** (`notes-autocommit.sh`, on
  `PostToolUse`) as `claude: <file>`, and the marker `.git/ta-last-seen` moves
  with them.
- **Your edits are not**, until you commit them or `tnotes` does. On the next
  prompt `notes-context.sh` injects everything since the marker: the commit
  log, the diffstat, and the unified diff of the text files. Lines you added
  arrive as `+` lines and are read as your comments — so `> is this right?` on
  the line under a paragraph is a review remark, in place, with no quoting and
  no re-reading of the file.
- `prompt.md` is excluded from all of it (it was already delivered as a
  prompt), and a diff over 60 KB is replaced by its stat with a note to open
  the files.

`tnotes` is the command behind the key — `tnotes toggle <pane-id>` is what the
binding runs; run `tnotes` with no arguments for the rest. The folder is ignored
globally (`**/.claude/notes/` in `.gitignore_global`), so notes never land in
the project's own history.

One caveat while the loop is young: `@`-completion does not offer paths inside
`.claude/notes/` (a dot-directory the global ignore also covers), so a file
there has to be named in full if you want to point at it explicitly — usually
you do not, since the diff already carries it.

## Notes

Agents are grouped by the directory they were **launched** in, not their current
one: the hook reports a live cwd that follows the Bash tool's `cd`, so grouping
on it made sessions hop between projects while you watched. The launch directory
is recovered from the first `cwd` in the transcript and cached per session id.

"Running" means a Claude process really is alive in that pane, checked against
the process tree — a state file alone proves nothing. Panes whose Claude has
exited are listed as closed and `enter` resumes them, on the account they ran
on.

`tests/config.sh` covers the config parser, the rules and the command builder
with no tmux involved; `tests/launch.sh` starts and resumes real agents,
`tests/panes.sh` docks, undocks and kills them across seats, `tests/ui.sh`
covers what the row looks like — the badge column, the hidden ones, the `?`
window running a real key, the one-line header and the `ctrl-v` modal — and
`tests/names.sh` covers the window naming above, including the refusal to
overwrite a name you typed. Each runs against a throwaway tmux server of its own
(`tmux -L tatest-$$`), never the default socket. All five are bash 3.2, run
every check, and exit non-zero when any of them fails.
