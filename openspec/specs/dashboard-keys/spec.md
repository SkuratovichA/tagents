# dashboard-keys Specification

## Purpose
Every key binding of the tagents dashboard, what each one does to the row under the cursor, how the keys are moved in the config, and the one-line header and the `?` window that make them discoverable.

## Requirements

### Requirement: The default keys
The dashboard SHALL bind these keys by default: `enter` and double-click open the agent; `ctrl-s` beside; `ctrl-n` new; `ctrl-p` pick the account; `ctrl-g` goto; `ctrl-o` borrow; `ctrl-e` send; `ctrl-r` and `F2` rename; `ctrl-u` undock; `ctrl-x` kill; `ctrl-t` tree or flat; `ctrl-v` preview; `ctrl-l` refresh; `ctrl-w` columns; `$` usage; `ctrl-y` closed sessions; `?` the keys window; `ctrl-q` quit. Every key acts on the row the cursor is on.

#### Scenario: Table of keys
- **WHEN** the user runs `tagents --keys`
- **THEN** it prints one `key<TAB>verb<TAB>description` line per bound verb in the order open, beside, new, pick, goto, borrow, send, rename, undock, kill, tree, preview, refresh, columns, usage, closed, keys, quit, followed by an `esc` line

#### Scenario: Header acts on its stand-in
- **WHEN** the cursor is on a project header and the user presses `enter`
- **THEN** the agent in the first row of that project is opened

### Requirement: Keys can be moved in the config
A `keys:` block in the configuration file SHALL map a verb (`open`, `beside`, `new`, `pick`, `goto`, `borrow`, `send`, `rename`, `undock`, `kill`, `tree`, `preview`, `refresh`, `columns`, `usage`, `closed`, `keys`, `quit`) to a key, and a verb not named keeps its default. The key is what fzf is handed and what `?` and `tagents --keys` list. `TA_RENAME_KEY` SHALL be honoured for `rename` when the config names none. `F2` stays bound to rename and double-click to open.

#### Scenario: Moved key
- **WHEN** the config has `keys: {closed: ctrl-o, borrow: ctrl-y}`
- **THEN** `ctrl-o` opens the closed-session picker, `ctrl-y` borrows, and `tagents --keys` lists `ctrl-o` for `:closed` and `ctrl-y` for `borrow`

### Requirement: Only keys fzf knows are accepted
A configured key SHALL be one of `ctrl-a`…`ctrl-z`, `alt-a`…`alt-z`, `alt-0`…`alt-9`, `f1`…`f12`, `enter`, `tab`, `btab`, `space`, `bspace`, `del`, `esc`, `up`, `down`, `left`, `right`, `home`, `end`, `pgup`, `pgdn`, or a single printable character other than a space, a tab, a backslash or a quote. Any other value SHALL be refused: the verb keeps its default and the reason is reported.

#### Scenario: Unknown name
- **WHEN** the config has `keys: {closed: bogus}`
- **THEN** `ctrl-y` still opens the closed picker, nothing is bound to `bogus`, and `tagents --keys` prints `# keys.closed: 'bogus' is not a key fzf knows — using ctrl-y`

### Requirement: Two verbs never share a key
When two verbs are configured onto one key, the verb earlier in the order of the default table SHALL keep it and the later one SHALL fall back to its default; if that is taken too, the verb SHALL be left unbound and contribute no binding at all. An unbound verb SHALL have no row in `tagents --keys` or in the `?` window.

#### Scenario: Clash
- **WHEN** the config has `keys: {send: ctrl-g}`
- **THEN** `ctrl-g` still goes to the agent, `send` stays on `ctrl-e`, and `tagents --keys` prints `# keys.send: ctrl-g is taken already — using ctrl-e`

#### Scenario: Both taken
- **WHEN** a verb's configured key and its default are both held by earlier verbs
- **THEN** the note says the verb is unbound and no binding for it is passed to fzf

### Requirement: Key complaints are shown where the user will see them
Complaints about keys SHALL be shown once per start of the dashboard as tmux messages prefixed `tagents: `, and by `tagents --keys` as lines prefixed `# `. A config with something wrong in it SHALL also put a summary item such as `config: 1 problem (tagents --check)` in the dashboard header for as long as it is wrong. The `configuration` capability defines the checks.

#### Scenario: Header carries the problem count
- **WHEN** a configured profile points at a directory that does not exist
- **THEN** the header contains `config: 1 problem (tagents --check)` and a good config shows no such item

### Requirement: The header is one line
The header above the list SHALL be one line of items joined by ` · `: the `enter` key with its label (`open here` in a sidebar, `open in sidebar` in a popup), `? keys`, and `ctrl-q quit` (left out in a popup), then the config summary if there is one. When the items do not fit the pane, the header SHALL wrap at the list's width minus 4 onto at most four lines, never dropping an item. `tagents --header [COLS] [LABEL] [QUIT ITEM]` prints it for a width.

#### Scenario: One line
- **WHEN** `tagents --header 100 'open here' 'ctrl-q quit'` is run
- **THEN** one line is printed, naming `enter open here` and `? keys`

#### Scenario: Narrow pane
- **WHEN** the width is 34
- **THEN** every item is still printed, on two lines

#### Scenario: Popup header
- **WHEN** the quit item is empty
- **THEN** the header has no `ctrl-q`

### Requirement: The ? window lists every key and runs the one picked
`?` SHALL open a window listing every key of the table with a one-line description, searchable by the verb's words, headed by `every key — enter runs the one you pick`. `enter` SHALL run the chosen verb on the row the cursor was on and `esc` closes the window. The quit rows (`ctrl-q`, and `esc` in a popup) are listed dim and, if picked, only close the window. Every bound key SHALL have a row and every row a binding.

#### Scenario: Picking undock
- **WHEN** a chat is docked and the user picks `undock` in the window
- **THEN** the chat is sent home and the agent is still alive

#### Scenario: Picking a quit row
- **WHEN** the user picks `quit`
- **THEN** the window closes, nothing is killed and the list keeps running

#### Scenario: Searching by word
- **WHEN** the user types `undock` into the window
- **THEN** the row for the undock key is found

### Requirement: Keys that ask a question work from the ? window
Verbs that ask a question — rename, send, kill, pick, and open on a closed row whose account is unknown — SHALL ask inline in the `?` window's own terminal, since a popup cannot open a second popup, and SHALL really take effect.

#### Scenario: Rename from the window
- **WHEN** the user picks `rename` in the `?` window and types `zzname`
- **THEN** the session's label is `zzname`

### Requirement: The ? window and ctrl-w cost two filter-query keys
`?` and `ctrl-w` SHALL be taken off fzf's filter query: `?` cannot be typed into it, and `ctrl-w` does not delete the word before the cursor.

#### Scenario: Backspace remains
- **WHEN** the user wants to correct the filter query
- **THEN** `bspace` still deletes characters

### Requirement: ctrl-q quits and esc does not
In the dedicated dashboard session `ctrl-q` SHALL end the dashboard and `esc` SHALL do nothing, so the dashboard cannot be closed by accident. The dashboard SHALL turn off terminal flow control so `ctrl-s` and `ctrl-q` reach the list. If fzf exits for any other reason the dashboard SHALL start it again, and give up with a message after five exits within a second of starting.

#### Scenario: Esc ignored
- **WHEN** the user presses `esc` in the sidebar
- **THEN** the list stays up

#### Scenario: Not in tmux
- **WHEN** `tagents` is started outside tmux with no session name known
- **THEN** it prints `tagents: not inside tmux` on standard error and exits 1

### Requirement: Open docks the agent and resumes closed ones
`enter` SHALL open the agent's pane in the sidebar's current seat and put the cursor in it; on a closed row it SHALL resume the session and then open it (see `chat-launch`). A row marked live whose pane is no longer a running Claude SHALL be settled by session id, as the scenarios say. Seats are the `seats-and-docking` capability's.

#### Scenario: Stale click
- **WHEN** `--act open` is given a pane that has been killed but whose session id is on record
- **THEN** the session is resumed from that record, on the account it ran on, and no dock lock is left behind

#### Scenario: Another pane runs it
- **WHEN** a live pane other than the one named runs that session
- **THEN** that pane is opened

#### Scenario: Unknown session
- **WHEN** no record names the session
- **THEN** nothing is resumed, the message `tagents: that chat has ended and left no record — ctrl-y lists closed sessions` is shown and the command exits 0

### Requirement: ctrl-s opens beside, ctrl-g goes there, ctrl-o borrows
`ctrl-s` SHALL open the agent in a new seat beside the current one (a closed row is resumed first and docked in the current seat). `ctrl-g` SHALL switch the client to the session and window the agent lives in and select its pane. `ctrl-o` SHALL link the agent's whole window into the dashboard's session without moving it out of its own session, and select it.

#### Scenario: Borrow keeps the window home
- **WHEN** the user presses `ctrl-o` on an agent whose window lives in another session
- **THEN** the window is also linked in the dashboard's session and still exists in its own

### Requirement: ctrl-u undocks, or gives a borrowed window back
`ctrl-u` SHALL send the chat in the current seat home and close the seat behind it unless it is the last one. With nothing docked it SHALL unlink a window borrowed with `ctrl-o` from the dashboard's session only.

#### Scenario: Nothing docked
- **WHEN** nothing is docked and the user presses `ctrl-u` on a borrowed agent
- **THEN** its window is unlinked from the dashboard's session and survives in its own

### Requirement: ctrl-e types a line into the agent
`ctrl-e` SHALL ask `send to <pane>` and type the answer, literally, into the agent's pane followed by a newline after a short pause. An empty line or `ctrl-c` cancels, and the question gives up after 300 seconds.

#### Scenario: Empty line
- **WHEN** the user presses `enter` on an empty line
- **THEN** nothing is sent

### Requirement: ctrl-r names an agent
`ctrl-r` and `F2` SHALL open a one-line dialog seeded with the agent's current name. The answer is stored as the label of the session id, or of the pane when it has none, in `labels.tsv` in the state directory (one `key<TAB>name` line per label), and the agent's tmux window is renamed with it. An empty answer removes the label; `esc` leaves it as it was.

#### Scenario: Name stored
- **WHEN** the user answers `newname` to the dialog of session `sid-rename`
- **THEN** `labels.tsv` holds `sid-rename<TAB>newname`

#### Scenario: Empty clears
- **WHEN** the user answers with an empty line
- **THEN** the label is removed and the row shows the pane title again

#### Scenario: From outside
- **WHEN** `tagents --label <session id> NAME` is run
- **THEN** the same label is stored, and with an empty id the command prints a message and exits 2

### Requirement: ctrl-x kills an agent after asking
`ctrl-x` SHALL ask `kill this agent?`, naming the agent, its tmux location and what will happen, and SHALL act only on `y`, `yes` or their capitals; anything else, or no answer within 60 seconds, cancels. Confirming SHALL hang up the Claude and close its pane (and its window when it was the only pane there), send a docked chat home first, ring the refresher's channel and leave the session resumable as a closed row.

#### Scenario: Confirmed
- **WHEN** the user answers `y` for a live agent
- **THEN** its pane is gone and its row becomes `closed — enter resumes it`

#### Scenario: Anything else
- **WHEN** the user answers `n` or presses enter on an empty line
- **THEN** nothing is killed

### Requirement: The kill question checks the pane when it is asked
Whether the pane exists SHALL be checked when the question is asked, not taken from the row.

#### Scenario: A pane that closed since the row was drawn
- **WHEN** the user presses `ctrl-x` on a row whose pane has closed since the list was drawn
- **THEN** the question treats the agent as having no pane

### Requirement: ctrl-x on a closed row forgets it
On a row with no pane left, `ctrl-x` SHALL ask `forget this closed session?` and, when confirmed, delete the row's record, subagent files and prompt-time file and ring the refresher's channel so the row disappears; the transcript is not touched. On a pane-less row this is the only effect of `ctrl-x`.

#### Scenario: Forgotten
- **WHEN** the user confirms on a closed row
- **THEN** the row does not appear in the list

### Requirement: ctrl-x never kills the dashboard
`ctrl-x` on the pane the list itself runs in SHALL do nothing but show `tagents: that is the dashboard itself`.

#### Scenario: Own pane
- **WHEN** a marker drifted so that the list's own pane is under the cursor
- **THEN** the pane survives

### Requirement: Pane verbs refuse pane-less rows
On a headless or child row, `enter`, `ctrl-s`, `ctrl-o`, `ctrl-g`, `ctrl-e` and `ctrl-r` SHALL do nothing but show a one-line notice: `tagents: headless session — no pane to dock, type into or rename (ctrl-v follows its log)` or, for a child, `tagents: child session — no pane to dock, type into or rename (ctrl-v shows its transcript)`.

#### Scenario: Headless enter
- **WHEN** the user presses `enter` on a headless row
- **THEN** the headless notice is shown and no window is created

### Requirement: Dashboard-level keys
`ctrl-t` toggles tree and flat, `ctrl-l` reloads the list now, `ctrl-w` opens the column picker, `ctrl-v` the preview (all in `dashboard-list`), `$` opens the month's usage per day (the `usage-accounting` capability), `ctrl-y` the closed-session picker (`closed-sessions`), and `ctrl-n` and `ctrl-p` start an agent (`chat-launch`). The list SHALL also reload when its window is resized.

#### Scenario: Refresh
- **WHEN** the user presses `ctrl-l`
- **THEN** the list is rebuilt from the records at once

### Requirement: A verb can be run from outside with --act
`tagents --act VERB PANE STATE SESSION DIR` SHALL run one of the verbs `open`, `beside`, `borrow`, `goto`, `send`, `rename`, `preview`, `new`, `pick`, `undock`, `kill`, `usage`, `closed`, `keys`, `columns` exactly as its key does, with the fields of the row as arguments.

#### Scenario: Open by hand
- **WHEN** `tagents --act open %5 live sid-x ~/projects/app` is run
- **THEN** the agent in `%5` is opened as if `enter` had been pressed on its row
