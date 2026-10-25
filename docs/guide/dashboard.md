# The dashboard

The dashboard is a list of every Claude Code session under tmux: what each one is doing, which is blocked on you, how much context it holds and what it has spent. It lives in a sidebar that moves into the window of the chat you select, so you can type into that chat without leaving.

![The tagents dashboard: sessions grouped by project, one working, two blocked on a question or a permission, one idle](../images/dashboard.png)

## Reading the list

Sessions are grouped by project. Each group has a header, and each session is a row under it:

```
▾ .dotfiles    ~/git/.dotfiles           ●1
  └─ ● working   0:31  p dotfiles   71k  $44.0  opus5    personal  %3
▾ storefront   ~/git/storefront          ⚠1 ✓1 ●1   $31.4/5h
  ├─ ● working   0:08  w web        38k   $9.1  sonnet5  work      %44  ⑂2
  ├─ ⚠ BLOCKED   2:14  w api       142k  $38.3  opus5    work      %31
  └─ ✓ IDLE     17:02  w worker     12k   $2.7  haiku4.5 work      %12
```

### The columns, left to right

| column | what it says |
|--------|--------------|
| state | `⚠ BLOCKED`, `✓ IDLE`, `● working` and the others; see [States and order](./states) |
| time | how long since **you** last typed into that session. It doubles as the clock of the one-hour prompt cache, see [States and order](./states#the-clock-the-rows-are-sorted-on) |
| badge | one or two characters naming the Claude login the session is on |
| name | the label you gave it with `ctrl-r`, else the title the session gave itself |
| context | how much context the session is holding (`71k`) |
| cost | what the session has spent, see [Cost](./cost) |
| model | the model the session is set to now |
| account | the full name of the login, on wide lists only |
| pane | the tmux pane id (`%3`), or `headless` or `child` for a session with no pane of its own |

A group header carries the project's directory, a tally of its states (`⚠1 ✓1 ●1`) and, when cost is on, the project's `/5h` burn (`$31.4/5h`), an estimate. `⑂2` after a row is the number of subagents the session has running.

### Badge and account

Both say which Claude login the session is on, named after the profile in your [config](./accounts) that claims its `CLAUDE_CONFIG_DIR`.

- The **account** name appears on wide lists only.
- The **badge** is one or two characters and is on every row at every width: `p`, `w`, the first letter of the profile name unless `badge:` says otherwise. More than two characters are clipped to two, since the column is as wide as the widest of them.
- Both stay blank for a session whose state record predates them, rather than guessing.
- With no profiles configured, the badge column does not exist at all.

### How a project is chosen

Agents are grouped by the directory they were **launched** in, not their current one. The hook reports a live working directory that follows the Bash tool's `cd`, and grouping on it made sessions hop between projects while you watched. The launch directory is recovered from the first `cwd` in the transcript and cached per session id.

A session counts as **running** only when a Claude process really is alive in that pane, checked against the process tree; a state file alone proves nothing. Panes whose Claude has exited are listed as closed, and `enter` resumes them on the account they ran on.

## Moving around

`enter` on a row selects it: the sidebar moves into that chat's window and your client follows. On a dimmed window row it selects the window, on a closed row it resumes the session first, and on a group header it shows that session's last-used window.

`ctrl-g` goes to the window the chat lives in and never resumes. `ctrl-e` types a line straight into an agent without leaving the list.

A few more act on the list itself: `ctrl-t` switches between tree and flat, `ctrl-l` refreshes now, `ctrl-r` names an agent (`F2` too) and `ctrl-q` quits. Every key can be moved, and `?` lists them all; see [Keys](./keys).

### The preview

`ctrl-v` opens the preview in a modal window of its own: the cost per subagent and the tail of the transcript. It scrolls, and `q` closes it. With no `less` on `$PATH` it is printed instead and any key closes it. In the `prefix+a` popup, and on a tmux with no popups at all, the preview stays fzf's own preview beside the list, because a popup cannot open a second popup.

### The timeline

```sh
tagents --timeline
```

Who worked when over the last day, as bars. A child session's hours are drawn with a `↳`.

![The timeline: one bar per agent over the last day](../images/timeline.png)

## Windows, sessions and the sidebar

A row is a tmux window and a group is a tmux session. Every session is a group, whether or not a chat has ever run in it, and a session whose only window holds nothing but the sidebar is a header with no row under it.

`enter` moves the one sidebar pane into the chosen window, as its leftmost full-height pane at `TA_WIDTH` percent of the window (45 by default). Anything else the window holds, such as a shell, a dev server or a notes editor, is yours: tagents never moves, resizes or kills it, and it leaves the screen with the window and comes back with it. The widths the other panes had are remembered per window and put back when the sidebar leaves.

### The sidebar follows you

tmux's own switches (`prefix n`, `prefix s`, a click on the status bar) fire `session-window-changed` and `client-session-changed`. tagents hooks both with `tagents --follow`, which moves the sidebar into the window now on screen, in whichever session that is.

When the window or session that held the sidebar is killed, the client lands elsewhere, the same hook fires and, with no list running, starts a new one there (one, however many hooks fire). A list in a pane makes a sidebar wanted, and `ctrl-q` ends the want, so a quit stays a quit.

### Two chats side by side

`ctrl-s` joins another chat's pane into the window on screen, to the right of its chat. The pane remembers its home session, and `ctrl-u` breaks it out into a window of its own.

A window with no chat in it is listed as a dimmed row, and `enter` on it selects the window.

### Starting new chats

![Starting a new chat from the dashboard](../images/new-chat.gif)

| key | what it starts |
|-----|----------------|
| `ctrl-n` | a new agent in the project under the cursor |
| `ctrl-p` | the same, but you choose the Claude account by hand, whatever the rules say |
| `ctrl-a` | a plain shell in a new window of the session under the cursor, in the row's directory |

All three also work on a session header with no row under it, which is how you open the first window there. Which account an agent starts on is decided by your [configuration](./accounts).

### Closing things

Closing a chat's pane or window is plain tmux: there are no seats and no placeholders, so `prefix+x` and `prefix+&` need no binding of tagents' own.

- `ctrl-x` on a chat hangs up its Claude and closes its pane, after asking. On the only chat of a window, the sidebar moves out before the window closes.
- `ctrl-x` on a row that is already closed forgets it.
- `ctrl-x` on a dimmed window row asks about the whole window, listing its panes, and closes it with all of them. The sidebar moves out first, and when it was the last window of its session a new window is made for the sidebar so the session survives.

tmux-resurrect saves the sidebar's split and gives its window back an idle shell titled `tagents-sidebar`; `tagents --resurrect` closes those shells after the restore.

## Windows are named after their agents

The dashboard is one way to find an agent. `prefix+w`, the status bar and `tmux ls` are the other, and they work when the dashboard is not on screen, so the tmux window an agent lives in is named after that agent.

- **The name is the one the list shows**: the label you gave it with `ctrl-r`, or the session's terminal title (what Claude's `/rename` sets) when you have not. Never the directory, since tmux's own `automatic-rename` already names a window after what is running in it.
- **When it renames**: within about ten seconds of the name changing while the dashboard is up, and within thirty when it is not. The status bar runs the same pass, throttled, so this works with no dashboard open at all.
- **A window several agents share** is named after the one with the newest activity. Panes with no name to give are not candidates, so a shell split off beside an agent never takes the window's name.
- **A name you typed is never overwritten.** A window is only renamed when its current name is tmux's automatic one, or the name tagents itself gave it last time (recorded in the window option `@tagents_name`). Rename a window by hand and nothing here touches it again, until the day its name coincides with one of those two.
- The sidebar does not stop a window being named: a window that holds the sidebar and a chat is named after the chat.

`tagents --sync-names` runs one pass by hand, which is the way to see what it would do.

## Hiding columns

`ctrl-w` opens a small window with a checkmark per column: `badge`, `ctx`, `cost`, `model`, `acct`, `loc`. `enter` toggles the one under the cursor and the list behind reloads immediately. The picker stays open; `esc` closes it.

Hiding `cost` takes **every** figure in dollars with it: the column, the `⑂` subagent share and the project header's `/5h` total. Money you are not currently spending against a limit is the distraction this exists for. The subagent *count* (`⑂2`) is not money and stays. Nothing is ever reordered: the freed width goes to the detail column, exactly as it does when the pane itself is narrow.

What is hidden lives one key per line in `$STATE_DIR/cols`, so it survives a restart.

- `TA_HIDE_COLS=cost,model tagents` overrides that file for a single run.
- `tagents --hidden-cols` prints what is in force.

## The cockpit layout

By default (`dashboard.layout: follow`) the sidebar moves into the window you are in. The alternative puts the dashboard in a session of its own:

```yaml
dashboard:
  layout: cockpit
```

The session is named `tagents`. The list is its left pane at `TA_WIDTH` percent, and the right pane, the **viewport**, is a second client of the same tmux server that shows the window you select, so no pane ever moves between windows.

- `tagents --ensure-dash` starts it, and `enter` on a row points the viewport at that row's window.
- A selection made for a terminal that is attached elsewhere (a popup, a notification click) points the viewport the same way and brings that terminal to the session `tagents`.
- A list or a viewport that is killed comes back within about a second.
- A session that is already named `tagents` and is not a dashboard stops the cockpit with a message: rename it, or set the layout back to `follow`.

### Keys and the prefix in the cockpit

The session `tagents` has no prefix of its own. The list keeps its keys (`ctrl-n`, `ctrl-s` and the rest work as before), and your tmux prefix, typed in the list, is sent on to the viewport, which becomes the active pane. So `prefix c` opens a window in the session the viewport shows, and `prefix d` detaches your terminal and leaves the viewport attached to the session it showed, ready for the next `tmux attach -t tagents`. The mouse bindings of the root table that do not open a menu work in the list too. Messages and popups appear on the viewport's client, because the dashboard's own status line is off.

Root bindings (`bind -n …`) do not fire while the list is the active pane; they do in the viewport, where they act in the window it shows. Press the prefix first or click into the viewport.

`ctrl-q` in the list is the way out. It shows your terminal the window the viewport showed, removes the key table, the hook and the options the cockpit set, and closes the session `tagents`; every other terminal attached to it moves to that window too.

::: tip Measured on one tmux
The cockpit is measured on tmux 3.7b only.
:::

### The cockpit and resurrect

The resurrect snapshot files the sidebar under the window the viewport showed (`D`, `work`, `2`, never the session `tagents`). `tagents --resurrect` brings the cockpit back with its viewport on that window and leaves your terminal where it is. A session `tagents` that tmux-resurrect left as two idle shells titled `tagents-sidebar` and `tagents-viewport` is rebuilt in place, without detaching anyone. In the follow layout it is closed instead, and its terminals move to the sidebar's window. The idle shells with those titles left in other windows are closed.

## Upgrading from the seat-based version

An earlier version swapped chats into seats of an `agents:1` window. On the first start after the upgrade tagents sends every docked chat home, closes the placeholders and removes the old options and hooks, once.

- Until that start, the old focus hooks still fire on every focus, and the verbs they and the old kill bindings call (`--poke`, `--unpark`, `--undock-pane`, `--undock-window`) exit 0 and do nothing, so tmux has no "returned 2" to show.
- A `bind-key x … --undock-pane` line in your `tmux.conf` then falls through to a plain `kill-pane`, and a `bind-key & … --undock-window` line to a plain `kill-window`, so both can be deleted.
- `TA_SESSION` is no longer read.
- A dashboard that was already running when you upgraded is the previous version's process, and tagents does not stop it for you: it carries the same markers as a current one, so it cannot be told apart safely, and its quit key is yours to rebind. It keeps the previous version's key bindings, so `ctrl-o` (borrow) in it calls an action that no longer exists. Restart it once: `ctrl-q` in it, then `tagents --ensure-dash` to start a sidebar in the window you are in.
