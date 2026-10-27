## MODIFIED Requirements

### Requirement: The default keys
The dashboard SHALL bind by default: `enter` and double-click open; `ctrl-s` join beside; `ctrl-n` new; `ctrl-p` pick the account; `ctrl-a` shell; `ctrl-g` goto; `ctrl-e` send; `ctrl-r` and `F2` rename; `ctrl-u` break out; `ctrl-x` kill; `ctrl-t` tree or flat; `ctrl-v` preview; `ctrl-l` refresh; `ctrl-w` columns; `$` usage; `ctrl-y` closed sessions; `?` the keys window; `ctrl-q` quit. Every key acts on the row the cursor is on. The verbs `beside` and `undock` keep their names.

#### Scenario: Table of keys
- **WHEN** the user runs `tagents --keys`
- **THEN** it prints one `key<TAB>verb<TAB>description` line per bound verb in the order open, beside, new, pick, shell, goto, send, rename, undock, kill, tree, preview, refresh, columns, usage, closed, keys, quit, followed by an `esc` line
- **AND** in the verb column a verb the list runs itself carries a leading colon (`:tree`, `:preview`, `:refresh`, `:columns`, `:usage`, `:closed`, `:quit`), the `keys` line's verb is `:none`, and the `esc` line's verb is `:quit`
- **AND** it prints no line for `ctrl-o`

#### Scenario: Header of a session acts on the session
- **WHEN** the cursor is on the header of a session and the user presses `enter`
- **THEN** the viewport shows the session's last-used window

#### Scenario: Header acts on its stand-in
- **WHEN** the cursor is on the header of a project group of rows with no window and the user presses `enter`
- **THEN** the agent in the first row of that group is opened

### Requirement: The header is one line
The header above the list SHALL be one line of items joined by ` · `: the `enter` key with its label (`open here` in the dashboard's list, `open in dashboard` in a popup), `? keys`, and `ctrl-q quit` (left out in a popup), then the config summary if there is one. When the items do not fit the pane, the header SHALL wrap at the list's width minus 4 onto at most four lines, never dropping an item. `tagents --header [COLS] [LABEL] [QUIT ITEM]` prints it for a width.

#### Scenario: One line
- **WHEN** `tagents --header 100 'open here' 'ctrl-q quit'` is run
- **THEN** one line is printed, naming `enter open here` and `? keys`

#### Scenario: Narrow pane
- **WHEN** the width is 34
- **THEN** every item is still printed, on two lines

#### Scenario: Popup header
- **WHEN** the quit item is empty
- **THEN** the header has no `ctrl-q`

### Requirement: ctrl-q quits and esc does not
In the dashboard's list `ctrl-q` SHALL end the dashboard and `esc` SHALL do nothing, so the dashboard cannot be closed by accident. The dashboard SHALL turn off terminal flow control so `ctrl-s` and `ctrl-q` reach the list. If fzf exits for any other reason the dashboard SHALL start it again, and give up with a message after five exits within a second of starting.

#### Scenario: Esc ignored
- **WHEN** the user presses `esc` in the dashboard's list
- **THEN** the list stays up

#### Scenario: Not in tmux
- **WHEN** `tagents` is started outside tmux with no session name known
- **THEN** it prints `tagents: not inside tmux` on standard error and exits 1

### Requirement: Open selects the agent's row and resumes closed ones
`enter` SHALL select the agent's row as the `window-rows` capability describes, showing the agent's window in the viewport and leaving the cursor on the row; on a closed row it SHALL resume the session and then select it (see `chat-launch`). A row marked live whose pane is no longer a running Claude SHALL be settled by session id, as the scenarios say.

#### Scenario: Stale click
- **WHEN** `--act open` is given a pane that has been killed but whose session id is on record
- **THEN** the session is resumed from that record, on the account it ran on, and no lock is left behind

#### Scenario: Another pane runs it
- **WHEN** a live pane other than the one named runs that session
- **THEN** that pane is opened

#### Scenario: Unknown session
- **WHEN** no record names the session
- **THEN** nothing is resumed, the message `tagents: that chat has ended and left no record — ctrl-y lists closed sessions` is shown and the command exits 0

### Requirement: ctrl-x kills an agent after asking
`ctrl-x` SHALL ask `kill this agent?`, naming the agent, its tmux location and what will happen, and SHALL act only on `y`, `yes` or their capitals; anything else, or no answer within 60 seconds, cancels. Confirming SHALL hang up the Claude and close its pane (and its window when it was the only pane there), ring the refresher's channel and leave the session resumable as a closed row.

#### Scenario: Confirmed
- **WHEN** the user answers `y` for a live agent
- **THEN** its pane is gone and its row becomes `closed — enter resumes it`

#### Scenario: Anything else
- **WHEN** the user answers `n` or presses enter on an empty line
- **THEN** nothing is killed

#### Scenario: The dashboard survives
- **WHEN** the user confirms on the only chat of a window
- **THEN** the window is closed and the dashboard still holds the list and the viewport

### Requirement: ctrl-s joins beside, ctrl-g goes there
`ctrl-s` SHALL join the agent's pane into the window on screen beside its chat, as the `window-rows` capability describes; a closed row is resumed first and then joined. `ctrl-g` SHALL take the terminal itself to where the agent lives, as the next requirement says, and never resumes: on a closed row it SHALL do nothing but show `tagents: that chat is closed — enter resumes it`.

#### Scenario: Join keeps the cursor
- **WHEN** the user presses `ctrl-s` on a live agent that lives in another window
- **THEN** its pane is beside the chat of the window on screen and the cursor has not moved

#### Scenario: Goto a closed row
- **WHEN** the user presses `ctrl-g` on a closed row
- **THEN** nothing is resumed and the message `tagents: that chat is closed — enter resumes it` is shown

## ADDED Requirements

### Requirement: $ says when usage is off
`$` with `usage.watch` unset SHALL open nothing and show `tagents: usage is off — set usage.watch to the profile to track`, so that the key never looks broken.

#### Scenario: Usage off
- **WHEN** `usage.watch` is unset and the user presses `$`
- **THEN** no window opens and `tagents: usage is off — set usage.watch to the profile to track` is shown

### Requirement: ctrl-g leaves the dashboard for the agent's own window
With the cockpit up, `ctrl-g` on a live row SHALL switch the most recently active terminal that is not the viewport's to the agent's own session, select the window and the agent's pane, and so leave the dashboard. It SHALL NOT point the viewport anywhere. On a group header it SHALL go to that session's own selected window.

#### Scenario: A live row
- **WHEN** the cursor is on the row of a chat in `personal:2` and the user presses `ctrl-g`
- **THEN** the user's terminal shows the session `personal` and its window 2, the chat's pane is active, and the terminal no longer shows the session `tagents`

#### Scenario: A header
- **WHEN** the user presses `ctrl-g` on the header `scratch`
- **THEN** the user's terminal shows the window the session `scratch` has selected

#### Scenario: A window that is gone
- **WHEN** the row's window was closed after the row was drawn and the user presses `ctrl-g`
- **THEN** nothing moves and `tagents: that window is gone` is shown

#### Scenario: No terminal
- **WHEN** `tagents --act goto` runs on a live row while no terminal is attached to the tmux server
- **THEN** nothing moves and `tagents: no terminal to take there` is shown

#### Scenario: A notification's click
- **WHEN** `tagents --goto %12` runs with the cockpit up
- **THEN** the viewport shows the window of `%12` and the terminal stays where it was, because that verb makes the selection `enter` makes

### Requirement: ctrl-g shares the session with the viewport and works without a cockpit
When the agent's window is in the session the viewport shows, the viewport SHALL show that window too, because a tmux session has one current window. With no cockpit up, `ctrl-g` SHALL select the window and switch the terminal to it, and SHALL NOT bring the cockpit up.

#### Scenario: The agent lives in the session the viewport shows
- **WHEN** the viewport shows `personal:1` and the user presses `ctrl-g` on a chat in `personal:2`
- **THEN** the user's terminal shows `personal:2` and the viewport shows `personal:2` too

#### Scenario: No cockpit
- **WHEN** no cockpit is up and the user presses `ctrl-g` on a live row
- **THEN** the window is selected, the terminal is switched to it and no session `tagents` appears
