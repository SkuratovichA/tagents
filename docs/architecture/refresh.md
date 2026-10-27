# How the dashboard stays current

The list updates the moment something changes, and does nothing at all when nothing does. This page explains how: a refresher that sleeps until it is rung, who rings it, what a wake costs, and how the tmux status bar is fed from the same loop.

## It waits; it does not poll

The refresher beside the list sleeps on a tmux channel, `tagents-ev`, and does nothing until something rings it. There are no timer ticks and no program started on a quiet minute.

`tmux wait-for -S <channel>` is the ring, and it wakes every waiter. Two signals with nobody waiting cancel each other, so every ring is also a count:

1. A ring first adds one to a global option (`@tagents_evgen` for the refresher, `@tagents_gen` for the slots), in the same tmux call.
2. A waiter sleeps only while that number is the one it saw with its last look. `tmux if-shell -F` decides and waits in one step, inside the server.

A ring that lands between two waits is a number that moved, never a lost signal.

## Who rings

### The agent-state hook

The hook rings in the one `tmux` call it already makes:

```sh
tmux set -gF @tagents_evgen '#{e|+|:#{@tagents_evgen},1}' \; wait-for -S tagents-ev \; set -p -t "$pane" @agent "$state"
```

The count and the signal come first, so a pane that has just closed (a failed `set`) still announces the record that was written.

- An event with no pane rings on its own. A headless session or a child has no pane to set an option on, so it rings the default tmux server, one `tmux` program per event, and the list shows it at once.
- A subagent's file that appears or goes rings too. A rewrite of one that is already there does not.

### tmux itself

Through hooks that `tagents` puts at array index **42** (`set-hook -g after-new-window[42] …`):

| group | events |
|-------|--------|
| creating and closing | `after-new-window`, `after-split-window`, `after-new-session`, `after-kill-pane`, `pane-exited`, `pane-died`, `session-closed` |
| moving | `window-linked`, `window-unlinked` |
| renaming and layout | `window-renamed`, `session-renamed`, `window-layout-changed` |
| clients | `client-attached`, `client-detached` |
| focus | `pane-focus-in`, `after-select-pane`, `after-select-window`, `client-session-changed` |

Why index 42:

- A hook of your own is left alone. `set-hook -g` without an index replaces the event's whole list, and `[0]` is somebody's.
- Installing them again is installing them once.
- They are put in at every refresher start and every slow pass, so a `.tmux.conf` that sets one of those events without an index (which wipes the event's list, ours with it) is healed within `TA_REFRESH_SLOW` seconds.

The follow hooks (`tagents --follow` on `session-window-changed` and `client-session-changed`) sit beside them at `[43]` and move the list's cursor onto the window the viewport now shows.

tmux 3.7 has no `after-swap-pane`, `after-join-pane`, `after-break-pane`, `after-move-window` or `after-respawn-pane`. `window-layout-changed` fires for a swap, a join and a break (for both windows when they differ), and a respawned pane changes nothing the list draws until the slow pass.

### tagents itself

Wherever it writes something the list draws without a tmux command of its own: a label, an origin, a hidden column, a forgotten row, a closed pane. The joins and breaks of panes ring the channel themselves, because tmux has no hook for them.

## What a wake does

1. One `tmux list-panes` takes the snapshot, with the ring count read in the same call.
2. A reload is posted into the list only if the snapshot moved, a file the list reads is newer than the marker, a state file was added or removed, or an earlier post was refused. A refused post is retried every 2 seconds, which is the one place left that polls; five in a row end the loop.
3. A burst of rings is one pass: the loop lets a second go by after a wake.

**At most one reload is posted every `TA_REFRESH_MIN` seconds** (2 by default, a whole number, one at the least). A single change after a quiet spell is posted at once. One that comes within the interval of a post is owed and made when the interval is over, with no ring needed.

A pass that posted is looked at once more a second later. That second look is there for the marker (file times are compared in whole seconds, so a write in the second of a reload's touch would otherwise be drawn twice), not for a lost ring.

A quiet wake starts two programs: that snapshot and one `tmux if-shell` for the next wait. That is one of each per pass and nothing per ring, and never more than one wait outstanding.

## The slow pass

The slow pass is what every fifth tick used to carry:

- the config re-read,
- `tusage --update` and the footer,
- window names,
- the resurrect snapshot,
- `tnotes sync`,
- and a reload whether or not anything moved (the age column, the pane titles and dead processes need that).

It runs on the first wake after `TA_REFRESH_SLOW` seconds (10) since the last one, and always at the idle timeout `TA_REFRESH_IDLE` (60 seconds, two at the least), which is also how often a loop with no rings at all still looks. A config edited by hand is therefore seen within `TA_REFRESH_SLOW` of the next ring, or within `TA_REFRESH_IDLE` of none. The slow pass also puts the `[42]` hooks back.

## The loop ends with its list

It watches fzf itself. The start bind hands it `$PPID` of the shell fzf starts, not the bash that restarts fzf after an abort. The check happens at every wake, at every timeout and again after the delay, and closing the list rings the channel on the way out.

A refresher that is killed, not asked, leaves its markers in the state directory; the next one sweeps them. The list that closes takes `@tagents_counts` down if no refresher is left to.

## The status bar is fed from the same loop

![The tagents tally in the tmux status bar](../images/statusbar.png)

While a refresher answers, it sets the global tmux option `@tagents_counts` to the text the bar prints. It does so on every pass, only when the text changes, so the second look after a reload picks up the tally that reload wrote. A reload that is slower than that leaves the bar one pass behind until the next pass. It unsets the option when the last refresher ends.

A status line that prints the option and runs `tagents --counts` only when it is not set costs nothing per redraw:

```sh
set -g status-right '#{?@tagents_counts,#{@tagents_counts},#(~/.local/bin/tagents --counts)}'
```

The `#()` in the branch that is not taken never runs.

- **Without a refresher** the option is not set, and the bar computes the counts itself, throttled by `TA_COUNTS_EVERY` (5 seconds by default; `0` turns the throttle off).
- **With a refresher alive**, a bar that still runs `tagents --counts` (the old line) prints the cache whatever its age and starts no program.
