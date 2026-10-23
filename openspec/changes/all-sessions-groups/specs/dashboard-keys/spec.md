## RENAMED Requirements

- FROM: `### Requirement: A dimmed row takes only enter, goto and kill`
- TO: `### Requirement: A dimmed row refuses only the verbs that need a chat`

## MODIFIED Requirements

### Requirement: The default keys
The dashboard SHALL bind by default: `enter` and double-click open; `ctrl-s` join beside; `ctrl-n` new; `ctrl-p` pick the account; `ctrl-a` shell; `ctrl-g` goto; `ctrl-e` send; `ctrl-r` and `F2` rename; `ctrl-u` break out; `ctrl-x` kill; `ctrl-t` tree or flat; `ctrl-v` preview; `ctrl-l` refresh; `ctrl-w` columns; `$` usage; `ctrl-y` closed sessions; `?` the keys window; `ctrl-q` quit. Every key acts on the row the cursor is on. The verbs `beside` and `undock` keep their names.

#### Scenario: Table of keys
- **WHEN** the user runs `tagents --keys`
- **THEN** it prints one `key<TAB>verb<TAB>description` line per bound verb in the order open, beside, new, pick, shell, goto, send, rename, undock, kill, tree, preview, refresh, columns, usage, closed, keys, quit, followed by an `esc` line
- **AND** it prints no line for `ctrl-o`

#### Scenario: Header of a session acts on the session
- **WHEN** the cursor is on the header of a session and the user presses `enter`
- **THEN** the session's last-used window is shown with the sidebar in it

#### Scenario: Header acts on its stand-in
- **WHEN** the cursor is on the header of a project group of rows with no window and the user presses `enter`
- **THEN** the agent in the first row of that group is opened

### Requirement: Keys can be moved in the config
A `keys:` block in the configuration file SHALL map a verb (`open`, `beside`, `new`, `pick`, `shell`, `goto`, `send`, `rename`, `undock`, `kill`, `tree`, `preview`, `refresh`, `columns`, `usage`, `closed`, `keys`, `quit`) to a key; a verb not named keeps its default, and an entry for any other verb, such as the retired `borrow`, SHALL be ignored. The key is what fzf is handed and what `?` and `tagents --keys` list.

#### Scenario: Moved key
- **WHEN** the config has `keys: {closed: ctrl-o, goto: ctrl-y}`
- **THEN** `ctrl-o` opens the closed-session picker, `ctrl-y` goes to the agent, and `tagents --keys` lists `ctrl-o` for `:closed` and `ctrl-y` for `goto`

#### Scenario: A retired verb
- **WHEN** the config has `keys: {borrow: ctrl-b}`
- **THEN** nothing is bound to `ctrl-b` and `tagents --keys` has no line for it

#### Scenario: The shell key moved
- **WHEN** the config has `keys: {shell: alt-s}`
- **THEN** `alt-s` opens a shell window, `ctrl-a` does not, and `tagents --keys` lists `alt-s` for `shell`

### Requirement: A dimmed row refuses only the verbs that need a chat
On a dimmed window row `enter` and `ctrl-g` SHALL select the window and `ctrl-x` SHALL ask to kill it, as the `window-rows` capability describes, `ctrl-n` and `ctrl-p` SHALL start a chat and `ctrl-a` a shell in the row's session, while `ctrl-s`, `ctrl-u`, `ctrl-e` and `ctrl-r` SHALL only show `tagents: that window runs no chat`.

#### Scenario: Dimmed row
- **WHEN** the user presses `ctrl-e` on a dimmed window row
- **THEN** nothing is typed anywhere and `tagents: that window runs no chat` is shown

#### Scenario: ctrl-x on a dimmed row asks
- **WHEN** the user presses `ctrl-x` on a dimmed window row
- **THEN** `kill this window?` is asked and `tagents: that window runs no chat` is not shown

#### Scenario: ctrl-a on a dimmed row
- **WHEN** the user presses `ctrl-a` on a dimmed window row of session `scratch`
- **THEN** a new window of `scratch` runs a shell and `tagents: that window runs no chat` is not shown

### Requirement: Dashboard-level keys
`ctrl-t` toggles tree and flat, `ctrl-l` reloads the list now, `ctrl-w` opens the column picker, `ctrl-v` the preview (all in `dashboard-list`), `$` opens the month's usage per day (the `usage-accounting` capability), `ctrl-y` the closed-session picker (`closed-sessions`), `ctrl-n` and `ctrl-p` start an agent (`chat-launch`), and `ctrl-a` opens a shell window (`window-rows`). The list SHALL also reload when its window is resized.

#### Scenario: Refresh
- **WHEN** the user presses `ctrl-l`
- **THEN** the list is rebuilt from the records at once

### Requirement: A verb can be run from outside with --act
`tagents --act VERB PANE STATE SESSION DIR` SHALL run one of the verbs `open`, `beside`, `goto`, `send`, `rename`, `preview`, `new`, `pick`, `shell`, `undock`, `kill`, `usage`, `closed`, `keys`, `columns` exactly as its key does, with the fields of the row as arguments.

#### Scenario: Open by hand
- **WHEN** `tagents --act open %5 live sid-x ~/projects/app` is run
- **THEN** the agent in `%5` is opened as if `enter` had been pressed on its row

#### Scenario: A shell by hand
- **WHEN** `tagents --act shell @7 none '' ~/app` is run and window `@7` is in session `scratch`
- **THEN** a new window of `scratch` runs a shell in `~/app`
