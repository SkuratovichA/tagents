# refresher Specification

## Purpose
The refresher is the background loop that keeps an open dashboard list current without redrawing it needlessly: it sleeps on a tmux channel until something rings it, posts a reload only when something the list draws moved, repairs the sidebar's seats, and keeps the port claim other processes use to reach the list. This capability also covers the tmux hooks that ring the channels, the tmux focus hooks that make a seat switch repaint the list at once, and the status-bar text the loop keeps in a tmux option.

## Requirements

### Requirement: The list starts one refresher and hands it fzf's port and pid
When fzf in the list starts, the list SHALL run `tagents --refresher` in the background with `TA_PORT` set to fzf's listen port and `TA_LIST_PID` set to fzf's own process id. The refresher SHALL talk to the list only by an HTTP POST of an fzf action to `127.0.0.1` on that port. Run without `TA_PORT`, `tagents --refresher` SHALL do nothing and exit 0.

#### Scenario: No port
- **WHEN** `tagents --refresher` is run without `TA_PORT`
- **THEN** it exits 0 at once and posts nothing

#### Scenario: The bind
- **WHEN** the start bind of the list runs
- **THEN** it passes `TA_PORT` as fzf's port, and `TA_LIST_PID` names fzf's own process, not the shell that restarts fzf after an abort

### Requirement: The first pass
The refresher SHALL make its first pass two seconds after it starts, whether or not the channel is rung.

#### Scenario: A quiet start
- **WHEN** a refresher starts and nothing rings the channel
- **THEN** it makes its first pass two seconds later

### Requirement: The refresher sleeps until a channel is rung
The refresher SHALL wait on the tmux channel `tagents-ev` and SHALL do nothing between rings, apart from the timeouts of this capability, and no program is started while nothing happens. A ring wakes it for one pass.

#### Scenario: A quiet stretch
- **WHEN** nothing rings the channel and nothing changes for less than the idle timeout
- **THEN** after the first pass no reload is posted and no program is started

### Requirement: Who rings the refresher
`tagents-ev` SHALL be rung by the agent-state hook on its events, by the tmux hooks at index 42 of the events listed in this capability, by tagents wherever it writes what the list draws without a tmux event of its own (a label, an origin, a hidden column, the flat marker, a forgotten row, a hung-up agent), by a list that closes, and by the moves of the sidebar and the joins and breaks of chats.

#### Scenario: A hidden column
- **WHEN** `tagents --toggle-col model` runs inside tmux
- **THEN** `tagents-ev` is rung and the count `@tagents_evgen` has gone up by one

#### Scenario: Outside tmux
- **WHEN** a label is set from a shell with no `TMUX` in its environment
- **THEN** nothing is rung and the list shows it at the next pass of the loop

### Requirement: When tagents rings
The rings tagents makes for what it writes outside tmux events SHALL be made only when `TMUX` is set; the agent-state hook SHALL ring on each event that changes what the list draws.

#### Scenario: Outside tmux
- **WHEN** tagents writes a label while `TMUX` is not set
- **THEN** it rings nothing

### Requirement: Every ring is also a count, and a wait cannot lose one
Every ring of `tagents-ev`, except the plain one a refresher makes on its way out to free its own wait, SHALL first add one to the global option `@tagents_evgen`, in the same tmux call and before the signal. The refresher SHALL read that option in the call that takes its snapshot and SHALL wait only while it still holds the number it read, the test and the wait being one step inside the tmux server, so that a ring arriving between two waits makes the next wait return at once.

#### Scenario: Two rings between waits
- **WHEN** one change is rung, and while the loop's next wait has not started a second change is rung twice
- **THEN** the first change is drawn on its ring and the second on the wait that finds the count moved, without waiting for the idle timeout

#### Scenario: One event, one count
- **WHEN** the agent-state hook handles one event for a session in a pane
- **THEN** `@tagents_evgen` is one higher afterwards

### Requirement: A pass asks tmux once and posts nothing when nothing moved
On a wake the refresher SHALL ask tmux one question, the snapshot of every pane together with the ring count, and, apart from the one tmux process that waits for the next ring, SHALL start no program while nothing has changed; it SHALL post nothing. A burst of rings SHALL be one pass: after a wake the loop lets one second go by, and the rings that came meanwhile are the one count it compares. Never more than one wait is outstanding.

#### Scenario: Four rings, nothing changed
- **WHEN** the channel is rung four times, once per pass, with nothing changed
- **THEN** only the first pass posted a reload, and each of the four asked tmux once for the snapshot

#### Scenario: A busy period
- **WHEN** the channel is rung about ten times a second for six seconds with a state file rewritten each time
- **THEN** the tmux programs started are about the passes made, fewer than half the rings

### Requirement: When a reload is posted
The refresher SHALL post `reload-sync(<tagents> --list)` on its first pass; on a pass where the tmux snapshot, a file the list reads or the number of state files differs from the last reload; on a slow pass; and on the retry after a reload was refused. On any other pass it SHALL post nothing. A reload due within the minimum interval is held back as the next requirement says.

#### Scenario: A quiet minute
- **WHEN** a refresher runs five passes with no change
- **THEN** exactly one reload was posted, on the first

#### Scenario: A refused reload is repeated
- **WHEN** the reload posted on a pass is refused
- **THEN** it is posted again two seconds later with nothing else changed

### Requirement: At most one reload per minimum interval
The refresher SHALL post at most one reload every `TA_REFRESH_MIN` seconds (default 2; a whole number of at least 1, anything else meaning 2). A change after a quiet spell SHALL be posted at once. A change that comes within the interval of a post SHALL be owed and made when the interval is over, with no further ring needed. A refused post SHALL NOT be held back by the interval.

#### Scenario: A change just after a burst
- **WHEN** a state file is written and the channel rung once, less than the interval after a post
- **THEN** the reload is posted within 3.5 seconds of the ring, and no second ring is needed

#### Scenario: A busy Claude
- **WHEN** a state file is rewritten and rung ten times a second for six seconds with the interval at 2
- **THEN** at most four reloads were posted, and at least two

### Requirement: The second look after a post
A pass that posted a reload SHALL be looked at once more one second later. That look counts only files strictly newer than the reload's marker, and when it finds nothing it SHALL move the marker on, so that a write in the second of the reload is not drawn a second time on the next wake. The look is never a slow pass, and a ring that came in meanwhile makes the next pass an ordinary one.

#### Scenario: One event, one reload
- **WHEN** a state file is written and the channel rung once on a quiet list
- **THEN** one reload is posted for it, and the wakes after it post nothing

### Requirement: What counts as a change on disk
A reload SHALL be posted when any of these was written since the last reload: a state file, the origin cache, the labels file, the hidden-columns file, the `.flat` marker, the `sub/`, `model/` and `prompt/` directories and the files in them, the config file, or its per-host overlay. A write in the same second as the last reload SHALL count. A state file that was deleted SHALL count too, detected by a change in the number of state files. The state directory itself is not watched.

#### Scenario: One write of each kind
- **WHEN** a state file, a `s-` state file, the origin cache, the labels file, the hidden-columns file, the `.flat` marker, a `sub/` file, a `model/` file, a `prompt/` file, the config and the overlay are each written and rung on a separate pass
- **THEN** each write causes exactly one reload on the pass that follows and the passes between stay quiet

#### Scenario: A deleted state file
- **WHEN** a state file is removed between two idle passes
- **THEN** the next pass posts a reload

### Requirement: The slow pass
The refresher SHALL make a slow pass on the first wake that comes `TA_REFRESH_SLOW` seconds (default 10; a value that is not a number meaning 10, and 0 making every wake slow) after the last slow pass, and always when the idle timeout `TA_REFRESH_IDLE` runs out. `TA_REFRESH_IDLE` defaults to 60; a value that is not a whole number, or is 0, means 60, and 1 means 2. A slow pass SHALL post a reload whether or not anything moved.

#### Scenario: No ring at all
- **WHEN** a refresher runs with an idle timeout of 2 seconds and nothing rings the channel for nine seconds
- **THEN** it posted at least two more reloads after the first, each on the timeout

#### Scenario: Out of reach
- **WHEN** the slow interval is far longer than the run and the channel is rung
- **THEN** no wake is a slow pass and `tusage --update` is not run

### Requirement: A changed config is read again
On every slow pass the refresher SHALL read the config again when the config file or its per-host overlay is not older than the last read, or when either has appeared or disappeared since then. A deleted overlay or config SHALL read as empty. The usage update SHALL follow the new config, so turning usage off stops the updates and turning it on starts them.

#### Scenario: Usage turned on under a running refresher
- **WHEN** the config gains a `usage:` block with a watched account while the refresher runs
- **THEN** `tusage --update` runs on the next slow pass and on every later one

#### Scenario: Usage turned off, or the config deleted
- **WHEN** the block is removed, or the file holding it is deleted
- **THEN** no `tusage --update` runs on the following slow passes

### Requirement: The usage figure is renewed on the slow pass
When usage is enabled, the slow pass SHALL run `tusage --update` and SHALL push the footer as an fzf `change-footer(...)` action. It SHALL pass the account profiles and directory rules of the current config. The month is fetched once for the status text and the footer together. What the usage numbers mean belongs to the `usage-accounting` capability.

#### Scenario: Footer on the slow pass
- **WHEN** usage is enabled and a slow pass runs
- **THEN** one `tusage --daily` fetch is made and a `change-footer(` action is posted

### Requirement: Notes editors are looked after only while there are some
On the slow pass the refresher SHALL run `tnotes sync` in the background when a pane carries `@ta_notes_for` or a session named `ta-notes` exists, and a `tnotes` executable sits beside `tagents`, and SHALL NOT run it otherwise. The notes workspace itself belongs to the `notes-workspace` capability.

#### Scenario: Editors exist
- **WHEN** a pane carries `@ta_notes_for` and two slow passes run
- **THEN** `tnotes sync` was started twice

#### Scenario: No editors
- **WHEN** no pane carries `@ta_notes_for`, there is no `ta-notes` session and a slow pass runs
- **THEN** `tnotes sync` is not started

### Requirement: The port claim
Once a post has been answered, the refresher SHALL publish its port in the pane option `@tagents_port` of the list pane, and SHALL make the claim again on the pass that finds the pane no longer says its port, such as after another refresher removed it or the list moved. A refused post SHALL give the claim up at once if it is still the refresher's own. When the loop ends, it SHALL remove the option only if the pane still carries its port.

#### Scenario: The option is overwritten
- **WHEN** `@tagents_port` of the list pane is set to another value and the channel rung
- **THEN** the refresher writes its port again within that pass

#### Scenario: A refresher whose list is gone
- **WHEN** a refresher is started against a port nobody listens on
- **THEN** it never takes the live list's `@tagents_port`

### Requirement: Five refused posts end the loop
The refresher SHALL end after five consecutive refused posts, which it makes at most two seconds apart, and any answered post SHALL reset the count. A single refused post SHALL NOT end it, because fzf refuses connections while it is busy.

#### Scenario: A list that never answers
- **WHEN** every post from the second pass on is refused
- **THEN** the loop ends after the fifth refused post, with its markers removed and its claim given up

### Requirement: The loop ends with its list
The refresher SHALL end when the list process is gone, asking `kill -0` about `TA_LIST_PID` (without it, the process named by `@tagents_list` of the pane it was started in) on every wake, every timeout and again after the delay that follows a wake. A list that closes SHALL ring `tagents-ev` on its way out, a popup list as well, so that the loop notices without waiting for a timeout. A shell around fzf that outlives fzf SHALL NOT keep the refresher alive.

#### Scenario: The list process dies
- **WHEN** the list process exits and the channel is rung
- **THEN** the loop ends within four seconds, by itself, and its markers are gone

#### Scenario: Fzf is killed, its shell lives
- **WHEN** fzf is killed in a shell that goes on running, with an idle timeout of 2 seconds
- **THEN** the refresher ends within the timeout and not by its refused posts

### Requirement: What the loop leaves behind
When the loop ends it SHALL free the wait it has outstanding so that no `tmux` process of the loop stays in the server, remove its markers and FIFOs, remove its port claim if it is still its own, and unset the global option `@tagents_counts` unless another refresher is alive. A sidebar list that closes SHALL unset it when no refresher with a live process remains; a popup list SHALL NOT.

#### Scenario: No waiter left
- **WHEN** a refresher has made a pass and then ends
- **THEN** no process of its wait is left in the server

#### Scenario: A refresher killed with -9
- **WHEN** the only marker left belongs to a dead process and the list closes
- **THEN** `@tagents_counts` is unset; with another refresher alive it is left alone

### Requirement: The refresher's markers
A refresher SHALL keep five files in the state directory named by its own process id: `.refresher.<pid>` (the time of the last reload), `.cfg` (the last config read), `.start`, and the FIFOs `.evq` and `.nap`, each after `.refresher.<pid>`. At its start it SHALL delete the files named after dead process ids: those five and `.counts.tally.<pid>` and `.counts.out.<pid>`; a live process's files stay. It SHALL remove its own when the loop ends.

#### Scenario: A dead refresher left files
- **WHEN** a refresher starts and the directory holds the files of a pid that has exited and those of a live one
- **THEN** the dead pid's files are all gone and the live pid's are kept
- **AND** while it runs it has exactly its own five markers, none named after the port

### Requirement: The refresher keeps the status bar's cache and text
On every pass whose post was not refused, the refresher SHALL turn the tally the list wrote into the status bar's cache and into the global tmux option `@tagents_counts`, exactly as the `status-bar-tally` capability describes, setting the option only when its text changes, and SHALL stop stamping the cache as soon as the list stops answering.

#### Scenario: The list goes deaf
- **WHEN** posts are refused from some pass on
- **THEN** the cache stamp stops moving at the value of the last answered pass

#### Scenario: Fresh within seconds
- **WHEN** a change is made and rung once, and the list writes its tally a moment after the reload
- **THEN** the cache and the option hold the new tally within 3 seconds, with no further ring

### Requirement: The event hooks are installed at index 42
`tagents` SHALL put a hook at index 42 of each of `after-new-window`, `after-split-window`, `after-new-session`, `after-kill-pane`, `pane-exited`, `pane-died`, `window-linked`, `window-unlinked`, `session-closed`, `window-renamed`, `session-renamed`, `window-layout-changed`, `client-attached`, `client-detached`, `pane-focus-in`, `after-select-pane`, `after-select-window` and `client-session-changed`. Each SHALL bump `@tagents_evgen` and signal `tagents-ev`, and start no program.

#### Scenario: Eighteen hooks
- **WHEN** a refresher has started
- **THEN** 18 hooks carry the ring at `[42]`, with the count bump first

#### Scenario: The owner's hooks
- **WHEN** the owner has hooks at `after-split-window[7]` and tagents installs its hooks
- **THEN** the owner's hook runs beside tagents' on a split

### Requirement: The event hooks are put back
The hooks SHALL be installed at the start of every refresher and on every slow pass, together with the follow hooks of the `window-rows` capability, and installing again SHALL leave exactly one per event. A `.tmux.conf` that sets one of these events without an index wipes the event's list, and the next slow pass SHALL put the hook at `[42]` back beside the one that wiped it, and the follow hook too when it was an event of that hook.

#### Scenario: A hook set without an index
- **WHEN** `set-hook -g pane-focus-in` is run without an index and a slow pass follows
- **THEN** `pane-focus-in[42]` carries the ring again, beside the hook just set

#### Scenario: A follow hook wiped
- **WHEN** `set-hook -g client-session-changed` is run without an index and a slow pass follows
- **THEN** the event carries the ring and one `tagents --follow` command again

### Requirement: A focus event rings once
Each focus event SHALL ring once; a change made with a client attached can fire several, which the refresher draws as one pass.

#### Scenario: One focus change, one ring
- **WHEN** the user selects another pane, or another window
- **THEN** `@tagents_evgen` goes up by exactly one for each focus event that fires

### Requirement: Switching between unrelated panes starts no program
The four focus events SHALL carry nothing but the ring, so that moving between panes starts no program. Only a switch of window or session runs a program, `tagents --follow` of the `window-rows` capability, which returns at once when the sidebar is already in the window on screen or the window is not in a group.

#### Scenario: A plain terminal is focused
- **WHEN** the user moves between two ordinary panes of one window
- **THEN** none of the hook commands runs a program

### Requirement: What the tmux snapshot covers
The tmux snapshot compared between passes SHALL cover each pane's id, position, window, current path, current command, pid and active and last flags, the sidebar markers `@tagents_list`, `@tagents_dash` and `@tagents_joined`, the port claim, and whether a pane carries `@ta_notes_for`. The pane title SHALL NOT be part of it, because Claude retitles a working pane several times a second; a title-only change waits for the next slow pass.

#### Scenario: A joined chat
- **WHEN** `@tagents_joined` of a chat pane is set between two idle passes
- **THEN** a reload is posted on the next pass
- **AND** the pass after it is quiet again

#### Scenario: The options in the snapshot
- **WHEN** any of `@tagents_list`, `@tagents_dash`, `@tagents_joined` or `@tagents_port` changes
- **THEN** the pass that follows posts a reload

### Requirement: What the slow pass does
A slow pass SHALL put the tmux event hooks and the follow hooks back, re-read a changed config, run `tusage --update` and push the footer, sweep the window names, take the resurrect snapshot if due, start `tnotes sync` while editors exist, and read the burn, month line and config marker again for the status bar. It also renews the age column, the pane titles and the state of dead processes by its reload.

#### Scenario: Names and hooks on the slow pass
- **WHEN** a slow pass runs
- **THEN** the window names are swept and the follow hooks are present once each

### Requirement: The port claim is checked only when tmux moved
After a pass whose post was not refused, the refresher SHALL check the port claim only when the snapshot changed, when it holds no port claim, or on a slow pass. This check renews the port claim.

#### Scenario: A quiet pass
- **WHEN** the snapshot is unchanged, the claim is held and it is not a slow pass
- **THEN** the port claim is not queried
