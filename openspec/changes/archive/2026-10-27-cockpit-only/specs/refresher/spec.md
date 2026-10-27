## MODIFIED Requirements

### Requirement: Who rings the refresher
`tagents-ev` SHALL be rung by the agent-state hook on its events, by the tmux hooks at index 42 of the events listed in this capability, by tagents wherever it writes what the list draws without a tmux event of its own (a label, an origin, a hidden column, the flat marker, a forgotten row, a hung-up agent), by a list that closes, and by the joins and breaks of chats.

#### Scenario: A hidden column
- **WHEN** `tagents --toggle-col model` runs inside tmux
- **THEN** `tagents-ev` is rung and the count `@tagents_evgen` has gone up by one

#### Scenario: Outside tmux
- **WHEN** a label is set from a shell with no `TMUX` in its environment
- **THEN** nothing is rung and the list shows it at the next pass of the loop

### Requirement: What the loop leaves behind
When the loop ends it SHALL free the wait it has outstanding so that no `tmux` process of the loop stays in the server, remove its markers and FIFOs, remove its port claim if it is still its own, and unset the global option `@tagents_counts` unless another refresher is alive. A list in the dashboard's pane that closes SHALL unset it when no refresher with a live process remains; a popup list SHALL NOT.

#### Scenario: No waiter left
- **WHEN** a refresher has made a pass and then ends
- **THEN** no process of its wait is left in the server

#### Scenario: A refresher killed with -9
- **WHEN** the only marker left belongs to a dead process and the list closes
- **THEN** `@tagents_counts` is unset; with another refresher alive it is left alone

### Requirement: Switching between unrelated panes starts no program
The four focus events SHALL carry nothing but the ring, so that moving between panes starts no program. Only a switch of window or session runs a program, `tagents --follow` of the `window-rows` capability, which moves the list's cursor onto the row of the window the viewport shows and returns at once when no cockpit is up.

#### Scenario: A plain terminal is focused
- **WHEN** the user moves between two ordinary panes of one window
- **THEN** none of the hook commands runs a program

### Requirement: What the tmux snapshot covers
The tmux snapshot compared between passes SHALL cover each pane's id, position, window, current path, current command, pid and active and last flags, the list markers `@tagents_list`, `@tagents_dash` and `@tagents_joined`, the port claim, and whether a pane carries `@ta_notes_for`. The pane title SHALL NOT be part of it, because Claude retitles a working pane several times a second; a title-only change waits for the next slow pass.

#### Scenario: A joined chat
- **WHEN** `@tagents_joined` of a chat pane is set between two idle passes
- **THEN** a reload is posted on the next pass
- **AND** the pass after it is quiet again

#### Scenario: The options in the snapshot
- **WHEN** any of `@tagents_list`, `@tagents_dash`, `@tagents_joined` or `@tagents_port` changes
- **THEN** the pass that follows posts a reload
