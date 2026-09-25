# tagents

A live dashboard of every Claude Code session running under tmux — what each one
is doing, which is blocked on you, how much context it is holding and what it
has spent — with the selected chat docked beside the list so you can type into
it without leaving.

```
▾ .dotfiles    ~/git/.dotfiles           ●1
  └─ ● working   0:31  p dotfiles   71k  $44.0  opus5    personal  %3
▾ storefront   ~/git/storefront          ⚠1 ✓1 ●1   $31.4/5h
  ├─ ● working   0:08  w web        38k   $9.1  sonnet5  work      %44  ⑂2
  ├─ ⚠ BLOCKED   2:14  w api       142k  $38.3  opus5    work      %31
  └─ ✓ IDLE     17:02  w worker     12k   $2.7  haiku4.5 work      %12
```

state · since you last typed · **badge** · name · context · cost · model · **account** · pane.
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
| `lib/tagents/` | what the dashboard is made of: one file per part, sourced by `tagents`. [What each one is](lib/tagents/README.md) |
| `tusage`  | per-session cost, dollars and context accounting, read from the transcripts |
| `hooks/tmux-agent-state.sh` | the Claude Code hook that publishes session state |
| `hooks/claude-statusline.sh` | the Claude Code status line — and the only source for which model a session is *set* to |
| `hooks/notes-context.sh` | the Claude Code hook that carries the notes folder's diff into the prompt |
| `hooks/notes-autocommit.sh` | the Claude Code hook that commits what Claude writes into the notes folder |
| `config.example.yaml` | a commented example of the optional per-directory account config |
| `packages/core/` | `@tagents/core`, the TypeScript package for **headless** sessions |
| `packages/knowledge/` | [`@tagents/knowledge`](packages/knowledge/README.md), the owner's notes as markdown documents with an FTS5 index, a `tagents-knowledge` CLI and an MCP server |
| `packages/telegram/` | [`@tagents/telegram`](packages/telegram/README.md), the Telegram Bot API typed and small — one client for every plugin that has a bot token |

They are one system. The hook writes a record per session into
`~/.claude/agent-state/`; `tagents` joins that with the live tmux pane list and
renders it; `tusage` supplies the two cost columns, joined on the session id.
`tagents` degrades gracefully when `tusage` or the status line is missing, but
without the state hook there is nothing to show.

### Sessions with no pane

Everything above is about sessions you can look at. The ones a bot or a cron job
runs headlessly (`claude -p`) have no pane and no window, and the dashboard sees
them only through the same hook. Spawning, prompting and reading THOSE lives in
[`packages/core`](packages/core/README.md) — a TypeScript package
(`@tagents/core`) with a `tagents-core` CLI, so bash gets it too. It is a
separate workspace at the root of this repo; the scripts above neither import it
nor need it.

## The ecosystem

| package | what it is |
|---------|------------|
| `tagents` (this script) | the dashboard: tmux, fzf, the tree, the sidebar. Bash, no dependencies of its own — the entry point, with the rest of it in `lib/tagents/` |
| [`@tagents/core`](packages/core/README.md) | headless sessions — spawn, prompt, read, list — plus the plugin contract and host, behind a `tagents-core` CLI |
| [`@tagents/knowledge`](packages/knowledge/README.md) | the owner's notes as markdown documents with an FTS5 index, a `tagents-knowledge` CLI and an MCP server |
| [`@tagents/telegram`](packages/telegram/README.md) | the Telegram Bot API, typed and small: one envelope-parsing `call()`, the methods a bot actually uses, and the 4096-character split |
| plugins, e.g. `@tagents/plugin-telegram` | a package the config names: one `definePlugin({ … })` object offering CLI verbs, long-running services and MCP tools |

One name reaches all of it. A verb `tagents` has no flag for — `tagents plugin
list`, `tagents session list`, `tagents doctor` — is handed to `tagents-core`
unchanged, found on `$PATH` or beside this script in a checkout.

**The plugin model.** A plugin is an ordinary package that default-exports one
`definePlugin({ name, apiVersion: 1, commands, services, mcpTools, locales })`
object and declares where that object lives in its own package.json:
`"tagents": { "apiVersion": 1, "entry": "./src/plugin.ts" }`. `tagents plugin
add <package-or-path>` checks that manifest — without importing anything — and
writes the package under `plugins:` in `~/.config/tagents/config.yaml`; the host
loads exactly what that map names and never scans `node_modules`, because
scanning is how a machine ends up running code nobody chose. `tagents plugin
new <name>` scaffolds a package that is already a plugin and typechecks as
written. See [packages/core/README.md](packages/core/README.md#plugins).

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

`tagents` is the entry point of a checkout, not a file to copy on its own: the
rest of it is `lib/tagents/*.sh` beside it, which it finds by following the
symlink back to the real file. Copied alone it says so and stops, rather than
half-working.

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

Every one of those keys can be moved. A `keys:` block in
`~/.config/tagents/config.yaml` maps a verb to a key — `closed: ctrl-y`,
`send: alt-s` — and anything not named there keeps its default;
`config.example.yaml` lists the lot with theirs. fzf's key names are what count
(`ctrl-a`…`ctrl-z`, `alt-a`…`alt-z`, `alt-0`…`alt-9`, `f1`…`f12`, `enter`,
`tab`, `btab`, `space`, `bspace`, `del`, the arrows, `home`, `end`, `pgup`,
`pgdn`, `esc`, or any single printable character); a name fzf does not know
would stop it starting, so it is refused with a message and the default kept,
and so is a key another verb already has. `tagents --keys` prints where each one
ended up, and the `?` window in the list shows the same thing live.

`tagents --help` is the real documentation — the script's header explains the
model, and every non-obvious decision in it is commented with the reason.

## Closed sessions

`ctrl-y` opens every session that is **not** running, newest activity first,
under the name this dashboard knows it by — the one you typed on `ctrl-r`, else
the one `$TA_LABEL` announced at launch, else the session's first prompt, else
its bare id. The preview beside it is the last ten prompts of that conversation,
the directory it ran in, and what it cost when `tusage` still has it. `enter`
resumes the one you pick — on the account it actually ran on, and in the tmux
session that owns its project; `esc` closes without doing anything.

Nothing here is a new store. Two files that were already being written are
joined by session id: `$STATE_DIR/history.tsv`, which the state hook appends a
line to on every session start, turn end and session end, and each account's own
`<config dir>/history.jsonl`, which has a line per prompt typed into it. The
file a prompt is in is also the answer to which login can resume the session,
which is why the account column can be trusted. A session is browsable for as
long as *either* file remembers it, and the directory a resume starts in is the
last one the hook recorded (falling back to the prompt log's project, and to
`$HOME` when that directory is gone).

The closed rows *inside* the list are a different thing and still expire after
`DEAD_TTL` (24 h): those are panes whose state record is still around, offered
where you last saw the agent. `tagents --closed-rows` prints the machine-readable
table this picker is built from.

## Resurrect

After a reboot, or anything else that takes the tmux server down, every Claude chat that had a pane comes back in its window — resumed on the account it ran on, with the model it was set to, under the window name it had — without you starting anything. tmux-resurrect and tmux-continuum already bring back the sessions, windows, splits, directories and window names, and a chat among them as an idle shell in the right directory, because they cannot know which conversation it was. tagents keeps that missing fact: a snapshot of every live chat keyed by session id (which login, which conversation, which model, which window and pane), and a restore that turns each of those idle shells back into `claude --resume` at the same place.

What comes back, and how:

- **Every chat with a state record**, whether tagents started it or you typed `claude` by hand — the state hook runs in every Claude.
- **At the same `session:window.pane`** when tmux-resurrect left an idle shell there; in a new window of that session when that pane is busy or gone; in a new session of that name when even the session is gone. A pane running anything but a shell is never touched, and nothing depends on tmux-resurrect having run: on a bare server the restore creates what is missing.
- **On the login it ran on**, never the account rules and never a dialog — a hook has no terminal to ask in. A record from before the account field existed is resumed on the default login, and the report says so.
- **With its model** (the status line records a `/model` switch too) and any `--effort` it was started with. `--resume` brings the permission mode back by itself.
- **Under its window name**: a name tagents gave the window keeps following the agent, and one you typed stays yours.
- **The dashboard**, when it was up. tmux-resurrect restores the sidebar as a dead `dash` window, and the list is started in that window rather than beside it — by the restore and by `prefix A` alike. Docked chats come back at their homes, undocked, and `enter` docks them again.
- **The notes editor** of every chat whose editor was on screen; one that was hidden stays hidden. The editors tmux-resurrect brought back, parked in `ta-notes` or beside a chat in its own window, belong to no chat and hold their files open, so the next `prefix C-t` would run into a swap-file warning; they are closed first.
- **Nothing twice.** A chat already running, by session id, is skipped, and so is one whose transcript is gone from its login. A directory that no longer exists is resumed in `$HOME`, and the report says so. The hook's `--auto` restores once per tmux server, and only within the server's first 5 minutes: tmux-resurrect fires the same hook on a `prefix + C-r` in a server that has been up for hours, where a restore would bring back every chat ended since the boot and replace idle shells that are yours now. `tagents --resurrect` by hand is the way to run it again.

The snapshots are `$STATE_DIR/resurrect/<epoch>.tsv` (`~/.claude/agent-state/` by default). One is written on every tmux-resurrect save (every 15 minutes with continuum, and on `prefix + C-s`), a few seconds after every launch or kill by tagents, and by the status bar every `resurrect.every` seconds; one that says exactly what the newest already says is not written again, and the newest 50 are kept, plus the one a restore on this server would read however old it is. **The restore uses the newest snapshot written before this tmux server started**, so the captures taken after the boot can never shadow the set that was running before it. They are not harmless all the same: a capture of a server nothing has been restored on yet says "no chats", and a second server start soon after (a `kill-server`, a crash) would pick exactly that one. So while `resurrect.auto` is on, a new server is not captured until the hook has restored it (or until it is 5 minutes old, if the hook never fires), nothing is captured while a restore is placing chats, and the restore takes a snapshot of its own 15 seconds after it is done, once the chats it resumed have written their records. `tagents --resurrect-rows` prints that snapshot's raw rows, `tagents --resurrect-rows latest` the newest one of all.

Two lines in `~/.tmux.conf`, after the tmux-resurrect plugin settings, make both halves happen on their own:

```tmux
set -g @resurrect-hook-post-save-layout '~/.local/bin/tagents --resurrect-save'
set -g @resurrect-hook-post-restore-all '~/.local/bin/tagents --resurrect --auto'
```

The first captures on every tmux-resurrect save, the second restores once continuum has put the layout back after a start. `tmux source-file ~/.tmux.conf` picks them up. `--auto` has no terminal, so its report goes to `$STATE_DIR/resurrect.log` (its last 2000 lines are kept) and the status line says `tagents: resurrected N agents, K skipped`.

The `resurrect:` leaf of the tagents config steers it; every key is optional and `tagents --check` names a value it cannot read:

```yaml
resurrect:
  auto: true       # restore when tmux-resurrect's post-restore-all hook fires (default true)
  every: 300       # seconds between status-bar captures; 0 turns the periodic capture off
  notes: reopen    # reopen the tnotes editor of every restored chat that had it on screen: reopen | off
```

`auto: false` makes the hook do nothing at all; `tagents --resurrect` by hand still works.

### Before a planned reboot

1. `prefix + C-s` — tmux-resurrect saves, and its hook takes the tagents snapshot at the same instant. Or `tagents --resurrect-save`.
2. Optional: `tagents --resurrect --dry-run --from latest` lists what would come back.
3. Reboot, open a terminal, start tmux as usual. Continuum restores the layout, the hook runs `tagents --resurrect --auto`, the status line says how many agents came back, and the line per chat is in `~/.claude/agent-state/resurrect.log`.
4. If auto-restore is off or the hook did not fire: `tagents --resurrect` picks the newest snapshot from before the boot, and `tagents --resurrect --dry-run` shows it first.

### What does not come back

- A chat's seat in the sidebar: the restored dashboard opens empty, and `enter` docks as always.
- A chat's scrollback: tmux-resurrect restores it and the resume replaces it, but Claude redraws the conversation anyway.
- An `/effort` chosen inside a session is recorded nowhere; only an `--effort` on the command line is replayed. `/model` is covered.
- A Claude on a login without the state hook has no record, so it is not captured.
- Headless sessions (`s-*`) have no pane to go back into and are not resurrected.
- A shell under a resumed chat: its pane runs `claude --resume` itself, like a chat started from the dashboard, so `/exit` closes the pane instead of dropping back to a prompt.
- A chat started by hand in the last `resurrect.every` seconds before an unplanned crash (launches by tagents are captured a few seconds after they start). The procedure above closes that gap for a planned reboot.

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

### One config, several machines

The file is shared through dotfiles, and the one thing in it that cannot be
shared is the account table: on one laptop the default login is the employer's
and `~/.claude-personal` is the second, on another the default is the personal
account and the second is a client's. A profile pointing at a directory that
does not exist on this machine starts a **logged-out** Claude, from a picker
that looked perfectly fine.

So `config.<hostname>.yaml` beside `config.yaml` (`hostname -s`) is laid over
it. Every `a.b` subtree the overlay names — `claude.profiles`, `claude.rules`,
`claude.default`, `notes.send`, … — replaces the base one wholesale; the rest is
inherited. Wholesale rather than merged because profiles and rules are tables:
a union would keep the other laptop's rows in this machine's picker, which is
the exact thing being fixed. `tagents --config` prints the merged result;
`TA_HOST` overrides the hostname, which is how the tests have one.

`tagents --check` lists what is wrong with the config, one `file: key: problem — what
to do` line each, and exits 1 while anything is; the dashboard header carries the count
and the status bar shows `cfg!N`. The first thing it looks for is a profile whose
`config_dir` is not on this machine, which is what a shared dotfiles config produces on
every machine but the one it was written on: the agent starts logged out, from a picker
that looked fine.

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
| `●`… | headless | a session with no pane at all: same states, nothing to dock into |

Claude Code also pings a notification after about a minute of silence, which
says nothing beyond "your move". That is folded into IDLE rather than shown as
its own state with its own message, so `⚠` stays a signal worth reacting to —
including on the tmux window tab, which flags `blocked` panes only.

**Headless sessions.** A `claude -p` started by a daemon, a launchd job or a
`nohup` has no tmux pane anywhere in its ancestry. It is listed all the same, in
the group of the directory it was launched in, with `headless` where the
location column names a pane for everybody else. It shows the ordinary states —
liveness is the pid of its claude process, recorded by the hook, rather than a
pane — and dims to `✗ closed` when that process is gone, without offering a
resume it has nowhere to put.

What you cannot do with one is anything that needs a pane: `enter`, `ctrl-s`,
`ctrl-e`, `ctrl-o` and `ctrl-r` refuse with a one-line notice. `ctrl-v` is the
exception, and is the reason to look at such a row at all — it follows `$TA_LOG`
with a live `tail -f`, and the sidebar preview shows the tail of the same file.
So export the two variables before starting one:

```sh
TA_LABEL=ticket-agent TA_LOG=/tmp/ticket-agent.log \
  nohup claude -p "$prompt" >>/tmp/ticket-agent.log 2>&1 &
```

`TA_LABEL` is the name the row shows (a headless session has no terminal title
to borrow one from) and `TA_LOG` is what `ctrl-v` follows. Neither is required:
without them the row is named after its directory and says it has no log. A name
can still be given from outside with `tagents --label <session id> NAME`.

## The order, and the clock the rows are sorted on

**Projects keep the place their path gives them.** The list is not sorted by how urgent anything is: a project does not climb when one of its agents blocks and does not drop back when you answer it, so the thing you were looking at is still where you left it. The only project that moves is one with nothing running in it at all — every agent closed — and it moves once, to the dim section at the bottom. What a project is doing is in its header badge (`⚠1 ✓1 ●1`), which is a thing to read rather than a thing that rearranges the page under you.

**Inside a project, rows are ordered by when YOU last typed into them** — the newest conversation on top, closed ones underneath. Not by state, and not by anything that moves during a turn: the state record is rewritten on every tool call, so ordering on it made two working agents trade places while they ran. The clock here moves exactly once per turn, when you press enter, which is also why the agent you just sent something to is the one at the top.

**The second column is that same clock** — how long since your last message, not how long the session has been in its current state. It is the number that says how much of the one-hour prompt cache is left: while it reads `47:12` the next thing you send is still cheap, and once it has an `h` in it (`1h03`) the cache is gone and the whole conversation is re-read at full price. It is a floor, deliberately: a long turn keeps writing the cache after your prompt, so a row that says `58:00` may have a few more minutes in it than that, never fewer.

It comes from one file per session under `$STATE_DIR/prompt/`, written by the hook on `UserPromptSubmit` and by nothing else, and removed with the record when the session ends. A session recorded before that file existed falls back to the time of its last event, which for a finished turn is within one turn of the right answer.

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

**A transcript is indexed by session, not by path.** Claude Code moves a
session's files between project directories — one started in a worktree lives
under the worktree's slug and reappears under the parent project's when the
worktree is deleted — so an index keyed by absolute path saw a new file after
every move and read it again from byte 0. One live session was indexed under
three slugs and $162 of the $285 charged to it was the copies. `offsets.tsv`
carries the session-relative key (the sid, plus the path below it for a subagent
file) as a fourth field, adopts the stored offset when that key turns up
somewhere new, and reads only the tail; rows written before the key existed
still work. If both copies are on disk at once only the newest is indexed, and
`--update`/`--rebuild` say how many were skipped.

**The month is the meter, and the meter is fetched.** The estimate runs
steadily beside the account's own meter without tracking it — $807 against $733
one day, $1108 against $830 a fortnight later — and a ratio typed in by hand
goes stale within days. So `tusage --meter` asks the account: a GET to
`/api/oauth/usage` with the OAuth token Claude Code keeps in the keychain for
the default config dir, giving the month-to-date spend and the limit behind it.
The reading lands in `meter.tsv` (one row per account, refreshed at most every
`TU_METER_TTL` seconds — 900 by default, 300 past 90% of the limit), re-prices
the per-day factor so `--daily` and the sparkline agree with it, and `--update`
refreshes it in passing, which is how the dashboard gets it for free.
`TU_NO_METER=1` turns it off. The token is read into a variable, handed to curl
as one header and dropped — never printed, never logged, never written down.

On screen: while a reading is under two days old the limit is the meter's own
and the month wears a `~`, with `~meter HH:MM` in the footer naming when it was
read; `usage.monthly_limit_usd` is what shows when the meter cannot be reached.
A seat with no meter (a plan, not credits) answers without a spend figure and is
left alone for a day. `tusage --calibrate work 732.71` is still there as the
manual fallback — the way to price an account whose meter this cannot read — and
`usage.meter: "2026-09-10 15:30 = 684.66"` in the config overrides the fetched
reading entirely. A typed reading from another month, or one implying a
correction outside 0.5–1.5, is ignored and the footer says so.

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
was called from, on the notes folder of that pane's project, so it doubles as
the place to write a long prompt without fighting the terminal's line editing.
The editor itself lives in a hidden `ta-notes` tmux session and is only ever
*linked* into the window you are looking at, which is why toggling it does not
disturb the layout you had.

`:q` commits the draft and leaves `@.claude/notes/prompt.md ` in the chat's
input. **You** press Enter, and the CLI reads the file at that moment — so
until you do, `prefix + C-t` reopens the draft and whatever you change is what
gets sent. Every other document in the folder that you changed since the
session last saw it is mentioned right beside it (`@.claude/notes/review.md `),
so a remark you left under a paragraph arrives with the whole file around it,
not only as a `+` line in the diff. "Since the session last saw it" is the
context hook's own marker, so the two agree; a document you annotate *after*
the first `:q` is added to the line, and nothing is mentioned twice.
Nothing under an `archive/` folder is ever mentioned (see below), and neither is a document that is gone. The
`paste` and `submit` shapes send the draft alone. Nothing is truncated on the
way out; the file is cleared for you the
next time the editor opens *after* it was actually sent (the submit hook
commits it as `user: <first line>` and records the sha in `.git/ta-sent`, and
the editor starts blank only when the file still matches that commit).

The `notes.send` leaf in the tagents config picks a different shape if you want
one: `paste` puts the text itself in the input without pressing Enter, and
`submit` is the original behaviour — paste, Enter, and clear the file at once.
Absent or unrecognised means `reference`.

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
- **An `archive/` folder is out of the prompt** — at the top of the notes or inside a ticket's folder (`AA-1234/archive/`). A document whose conclusions have landed goes there to keep its reasoning without re-entering every turn: nothing under it is diffed or mentioned, a change made only inside one injects nothing, and a document you move into one arrives as a single line (`archived: plan.md => AA-1234/archive/plan.md`) rather than as its whole text deleted. A folder that merely contains the word (`notes-archive/`) is a folder like any other.

`tnotes` is the command behind the key — `tnotes toggle <pane-id>` is what the
binding runs; run `tnotes` with no arguments for the rest:

- `tnotes toggle <pane>` — open the editor beside a Claude pane, or hide it again
  when it is already there.
- `tnotes sync [pane]` — park every editor whose chat you are not looking at, and
  bring back the one belonging to `<pane>`.
- `tnotes send <chat> <dir>` — commit the notes and hand `prompt.md` to `<chat>`,
  as a reference, a paste or a submitted paste (see `notes.send`).
- `tnotes close <editor>` — ask the editor to write and quit, then make sure it did.
- `tnotes editor <chat> <dir>` — the program the editor pane runs; not for you.

The folder is ignored globally (`**/.claude/notes/` in `.gitignore_global`), so
notes never land in the project's own history.

To point the session at one document in particular, reference it from
`prompt.md` as `@.claude/notes/<file>`: the mention attaches the file, no
completion needed — `@`-completion does not offer paths inside a dot-directory,
and does not have to. Usually you do not need it at all, since the diff already
carries what changed.

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
window running a real key, the one-line header, the `ctrl-v` modal and the
order, which is checked by making a state change and asserting that nothing
moved — and
`tests/names.sh` covers the window naming above, including the refusal to
overwrite a name you typed, and `tests/headless.sh` covers the sessions with no
pane at all — what the hook writes for one, how the row reads while its process
lives and once it does not, and that every verb needing a pane refuses.
`tests/modules.sh` covers the layout itself — that every module is sourced and
no module is orphaned, that nothing is defined twice, that a module only defines
things, and that the entry point still finds its modules through a symlink and
refuses to run without them. Each runs against a throwaway tmux server of its
own (`tmux -L tatest-$$`), never the default socket. All of them are bash 3.2,
run every check, and exit non-zero when any of them fails.
