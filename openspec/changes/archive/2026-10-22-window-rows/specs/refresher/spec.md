## MODIFIED Requirements

### Requirement: Who rings the refresher
`tagents-ev` SHALL be rung by the agent-state hook on its events, by the tmux hooks at index 42 of the events listed in this capability, by tagents wherever it writes what the list draws without a tmux event of its own (a label, an origin, a hidden column, the flat marker, a forgotten row, a hung-up agent), by a list that closes, and by the moves of the sidebar and the joins and breaks of chats.

#### Scenario: A hidden column
- **WHEN** `tagents --toggle-col model` runs inside tmux
- **THEN** `tagents-ev` is rung and the count `@tagents_evgen` has gone up by one

#### Scenario: Outside tmux
- **WHEN** a label is set from a shell with no `TMUX` in its environment
- **THEN** nothing is rung and the list shows it at the next pass of the loop

### Requirement: Notes editors are looked after only while there are some
On the slow pass the refresher SHALL run `tnotes sync` in the background when a pane carries `@ta_notes_for` or a session named `ta-notes` exists, and a `tnotes` executable sits beside `tagents`, and SHALL NOT run it otherwise. The notes workspace itself belongs to the `notes-workspace` capability.

#### Scenario: Editors exist
- **WHEN** a pane carries `@ta_notes_for` and two slow passes run
- **THEN** `tnotes sync` was started twice

#### Scenario: No editors
- **WHEN** no pane carries `@ta_notes_for`, there is no `ta-notes` session and a slow pass runs
- **THEN** `tnotes sync` is not started

### Requirement: The event hooks are installed at index 42
`tagents` SHALL put a hook at index 42 of each of `after-new-window`, `after-split-window`, `after-new-session`, `after-kill-pane`, `pane-exited`, `pane-died`, `window-linked`, `window-unlinked`, `session-closed`, `window-renamed`, `session-renamed`, `window-layout-changed`, `client-attached`, `client-detached` and the four focus events `pane-focus-in`, `after-select-pane`, `after-select-window` and `client-session-changed`. Each SHALL bump `@tagents_evgen` and signal `tagents-ev`, and no program is started.

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

### Requirement: Switching between unrelated panes starts no program
The four focus events SHALL carry nothing but the ring, so that moving between panes starts no program. Only a switch of window or session runs a program, `tagents --follow` of the `window-rows` capability, which returns at once when the sidebar is already in the window on screen or the window is not in a group.

#### Scenario: A plain terminal is focused
- **WHEN** the user moves between two ordinary panes of one window
- **THEN** none of the hook commands runs a program

## ADDED Requirements

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

## REMOVED Requirements

### Requirement: What counts as a tmux change
**Reason**: It names the seat markers, the sidebar's border status and `@ta_notes_any`, none of which exist any more.
**Migration**: "What the tmux snapshot covers" in this capability.

### Requirement: What the slow pass carries
**Reason**: It carries the seat repair, which has nothing to repair, and starts `tnotes sync` on `@ta_notes_any`.
**Migration**: "What the slow pass does" in this capability.

### Requirement: A slow pass is owed when the dashboard window has no seat
**Reason**: There are no seats, and a sidebar that is missing is brought back by `tagents --ensure-dash`, not by the refresher.
**Migration**: None.

### Requirement: Seats are looked at only when tmux moved
**Reason**: Seats, the title bar and the seat cursor are gone; only the port claim is still checked.
**Migration**: "The port claim is checked only when tmux moved" in this capability.

### Requirement: The list cursor follows the seat
**Reason**: There is no current seat for the cursor to follow, and the list no longer marks which row is on screen.
**Migration**: None. The cursor stays where the user left it; `enter` selects a row.

### Requirement: The focus hooks are installed on first use
**Reason**: Focus hooks that unpark, stamp, poke and sync notes are gone; the four focus events carry only the ring, which every refresher installs.
**Migration**: "The event hooks are installed at index 42" and "The event hooks are put back" in this capability, and the follow hooks of the `window-rows` capability. `tagents --focus-hooks` is removed.

### Requirement: What each focus hook does
**Reason**: `tagents --unpark`, the `@tagents_cur` stamp, `tagents --poke` and `tnotes sync <pane>` on focus no longer exist.
**Migration**: "Switching between unrelated panes starts no program" in this capability, and the follow hooks of the `window-rows` capability.

### Requirement: A seat switch repaints the list at once
**Reason**: `tagents --poke` repainted the list for a seat switch; with no seat there is nothing for it to wake, and the ring at `[42]` already repaints the list on every focus event.
**Migration**: None. `tagents --poke` is removed.
