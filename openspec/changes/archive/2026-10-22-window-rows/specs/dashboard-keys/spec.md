## RENAMED Requirements
- FROM: `### Requirement: Open docks the agent and resumes closed ones`
- TO: `### Requirement: Open selects the agent's row and resumes closed ones`

## MODIFIED Requirements

### Requirement: The default keys
The dashboard SHALL bind these keys by default: `enter` and double-click open the agent; `ctrl-s` join beside; `ctrl-n` new; `ctrl-p` pick the account; `ctrl-g` goto; `ctrl-e` send; `ctrl-r` and `F2` rename; `ctrl-u` break out; `ctrl-x` kill; `ctrl-t` tree or flat; `ctrl-v` preview; `ctrl-l` refresh; `ctrl-w` columns; `$` usage; `ctrl-y` closed sessions; `?` the keys window; `ctrl-q` quit. Every key acts on the row the cursor is on. The verbs keep the names `beside` and `undock` that configurations already use.

#### Scenario: Table of keys
- **WHEN** the user runs `tagents --keys`
- **THEN** it prints one `key<TAB>verb<TAB>description` line per bound verb in the order open, beside, new, pick, goto, send, rename, undock, kill, tree, preview, refresh, columns, usage, closed, keys, quit, followed by an `esc` line
- **AND** it prints no line for `ctrl-o`

#### Scenario: Header of a session acts on the session
- **WHEN** the cursor is on the header of a session and the user presses `enter`
- **THEN** the session's last-used window is shown with the sidebar in it

#### Scenario: Header acts on its stand-in
- **WHEN** the cursor is on the header of a project group of rows with no window and the user presses `enter`
- **THEN** the agent in the first row of that group is opened

### Requirement: Keys can be moved in the config
A `keys:` block in the configuration file SHALL map a verb (`open`, `beside`, `new`, `pick`, `goto`, `send`, `rename`, `undock`, `kill`, `tree`, `preview`, `refresh`, `columns`, `usage`, `closed`, `keys`, `quit`) to a key, and a verb not named keeps its default. An entry for any other verb, such as the retired `borrow`, SHALL be ignored. The key is what fzf is handed and what `?` and `tagents --keys` list. `TA_RENAME_KEY` SHALL be honoured for `rename` when the config names none. `F2` stays bound to rename and double-click to open.

#### Scenario: Moved key
- **WHEN** the config has `keys: {closed: ctrl-o, goto: ctrl-y}`
- **THEN** `ctrl-o` opens the closed-session picker, `ctrl-y` goes to the agent, and `tagents --keys` lists `ctrl-o` for `:closed` and `ctrl-y` for `goto`

#### Scenario: A retired verb
- **WHEN** the config has `keys: {borrow: ctrl-b}`
- **THEN** nothing is bound to `ctrl-b` and `tagents --keys` has no line for it

### Requirement: The ? window lists every key and runs the one picked
`?` SHALL open a window listing every key of the table with a one-line description, searchable by the verb's words, headed by `every key — enter runs the one you pick`. `enter` SHALL run the chosen verb on the row the cursor was on and `esc` closes the window. The quit rows (`ctrl-q`, and `esc` in a popup) are listed dim and, if picked, only close the window. Every bound key SHALL have a row and every row a binding.

#### Scenario: Picking undock
- **WHEN** a chat is joined into another window and the user picks `undock` in the window
- **THEN** the chat is broken out into a window of its own and the agent is still alive

#### Scenario: Picking a quit row
- **WHEN** the user picks `quit`
- **THEN** the window closes, nothing is killed and the list keeps running

#### Scenario: Searching by word
- **WHEN** the user types `undock` into the window
- **THEN** the row for the undock key is found

### Requirement: ctrl-q quits and esc does not
In the sidebar `ctrl-q` SHALL end the dashboard and `esc` SHALL do nothing, so the dashboard cannot be closed by accident. The dashboard SHALL turn off terminal flow control so `ctrl-s` and `ctrl-q` reach the list. If fzf exits for any other reason the dashboard SHALL start it again, and give up with a message after five exits within a second of starting.

#### Scenario: Esc ignored
- **WHEN** the user presses `esc` in the sidebar
- **THEN** the list stays up

#### Scenario: Not in tmux
- **WHEN** `tagents` is started outside tmux with no session name known
- **THEN** it prints `tagents: not inside tmux` on standard error and exits 1

### Requirement: Open selects the agent's row and resumes closed ones
`enter` SHALL select the agent's row as the `window-rows` capability describes, moving the sidebar into the agent's window and putting the cursor in the chat; on a closed row it SHALL resume the session and then select it (see `chat-launch`). A row marked live whose pane is no longer a running Claude SHALL be settled by session id, as the scenarios say.

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
`ctrl-x` SHALL ask `kill this agent?`, naming the agent, its tmux location and what will happen, and SHALL act only on `y`, `yes` or their capitals; anything else, or no answer within 60 seconds, cancels. Confirming SHALL hang up the Claude and close its pane (and its window when it was the only pane there besides the sidebar, the sidebar being moved to the window the client lands on first), ring the refresher's channel and leave the session resumable as a closed row.

#### Scenario: Confirmed
- **WHEN** the user answers `y` for a live agent
- **THEN** its pane is gone and its row becomes `closed — enter resumes it`

#### Scenario: Anything else
- **WHEN** the user answers `n` or presses enter on an empty line
- **THEN** nothing is killed

#### Scenario: The sidebar survives
- **WHEN** the user confirms on the only chat of a window that holds nothing else but the sidebar
- **THEN** the window is closed and the sidebar is in the window now on screen

### Requirement: Pane verbs refuse pane-less rows
On a headless or child row, `enter`, `ctrl-s`, `ctrl-g`, `ctrl-e` and `ctrl-r` SHALL do nothing but show a one-line notice: `tagents: headless session — no pane to open, type into or rename (ctrl-v follows its log)` or, for a child, `tagents: child session — no pane to open, type into or rename (ctrl-v shows its transcript)`. On a dimmed window row only `enter` and `ctrl-g` act, selecting the window, and `ctrl-s`, `ctrl-u`, `ctrl-e`, `ctrl-r` and `ctrl-x` SHALL do nothing but show `tagents: that window runs no chat`.

#### Scenario: Headless enter
- **WHEN** the user presses `enter` on a headless row
- **THEN** the headless notice is shown and no window is created

#### Scenario: Dimmed row
- **WHEN** the user presses `ctrl-e` on a dimmed window row
- **THEN** nothing is typed anywhere and `tagents: that window runs no chat` is shown

### Requirement: A verb can be run from outside with --act
`tagents --act VERB PANE STATE SESSION DIR` SHALL run one of the verbs `open`, `beside`, `goto`, `send`, `rename`, `preview`, `new`, `pick`, `undock`, `kill`, `usage`, `closed`, `keys`, `columns` exactly as its key does, with the fields of the row as arguments.

#### Scenario: Open by hand
- **WHEN** `tagents --act open %5 live sid-x ~/projects/app` is run
- **THEN** the agent in `%5` is opened as if `enter` had been pressed on its row

## ADDED Requirements

### Requirement: ctrl-s joins beside, ctrl-g goes there
`ctrl-s` SHALL join the agent's pane into the window on screen beside its chat, as the `window-rows` capability describes; a closed row is resumed first and then joined. `ctrl-g` SHALL switch the client to the window the agent lives in and select its pane, and never resumes: on a closed row it SHALL do nothing but show `tagents: that chat is closed — enter resumes it`.

#### Scenario: Join keeps the cursor
- **WHEN** the user presses `ctrl-s` on a live agent that lives in another window
- **THEN** its pane is beside the chat of the window on screen and the cursor has not moved

#### Scenario: Goto a closed row
- **WHEN** the user presses `ctrl-g` on a closed row
- **THEN** nothing is resumed and the message `tagents: that chat is closed — enter resumes it` is shown

### Requirement: ctrl-u breaks a joined chat out
`ctrl-u` SHALL break the chat of the row under the cursor out of the window it was joined into, as the `window-rows` capability describes. On a chat that is not joined it SHALL do nothing but show `tagents: that chat is not joined to another window`.

#### Scenario: A joined chat
- **WHEN** the user presses `ctrl-u` on a chat that was joined with `ctrl-s`
- **THEN** it is the only pane of a new window of its home session and its process is still running

#### Scenario: A chat that was never joined
- **WHEN** the user presses `ctrl-u` on a chat of a window of its own
- **THEN** nothing moves and the message `tagents: that chat is not joined to another window` is shown

## REMOVED Requirements

### Requirement: ctrl-x never kills the dashboard
**Reason**: The rule belongs with the sidebar's other guarantees, which now live in the `window-rows` capability together with what survives of `seats-and-docking`.
**Migration**: The `window-rows` capability: "ctrl-x never kills the sidebar", with the same text and scenario.

### Requirement: ctrl-s opens beside, ctrl-g goes there, ctrl-o borrows
**Reason**: Opening beside is a join of the chat's pane into the window on screen now, and borrowing a window into another session conflicts with a window being in exactly one group: `enter` already switches the client to a row in another session and `ctrl-g` goes to the window without moving anything else.
**Migration**: "ctrl-s joins beside, ctrl-g goes there" in this capability, and the `window-rows` capability for the join. `ctrl-o` and the `borrow` verb are removed with no replacement.

### Requirement: ctrl-u undocks, or gives a borrowed window back
**Reason**: Nothing is docked or borrowed any more; `ctrl-u` now breaks a joined chat out into a window of its own.
**Migration**: "ctrl-u breaks a joined chat out" in this capability, and the `window-rows` capability for the move.
