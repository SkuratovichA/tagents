## MODIFIED Requirements

### Requirement: The default keys
The dashboard SHALL bind by default: `enter` and double-click open; `ctrl-s` join beside; `ctrl-n` new; `ctrl-p` pick the account; `ctrl-a` shell; `ctrl-g` goto; `ctrl-e` send; `ctrl-r` and `F2` rename; `ctrl-u` break out; `ctrl-x` kill; `ctrl-t` tree or flat; `ctrl-o` window order or last message; `ctrl-v` preview; `ctrl-l` refresh; `ctrl-w` columns; `$` usage; `ctrl-y` closed sessions; `?` the keys window; `ctrl-q` quit. Every key acts on the row the cursor is on. The verbs `beside` and `undock` keep their names.

#### Scenario: Table of keys
- **WHEN** the user runs `tagents --keys`
- **THEN** it prints one `key<TAB>verb<TAB>description` line per bound verb in the order open, beside, new, pick, shell, goto, send, rename, undock, kill, tree, order, preview, refresh, columns, usage, closed, keys, quit, followed by an `esc` line
- **AND** in the verb column a verb the list runs itself carries a leading colon (`:tree`, `:order`, `:preview`, `:refresh`, `:columns`, `:usage`, `:closed`, `:quit`), the `keys` line's verb is `:none`, and the `esc` line's verb is `:quit`

#### Scenario: Header of a session acts on the session
- **WHEN** the cursor is on the header of a session and the user presses `enter`
- **THEN** the viewport shows the session's last-used window

#### Scenario: Header acts on its stand-in
- **WHEN** the cursor is on the header of a project group of rows with no window and the user presses `enter`
- **THEN** the agent in the first row of that group is opened

### Requirement: Keys can be moved in the config
A `keys:` block in the configuration file SHALL map a verb (`open`, `beside`, `new`, `pick`, `shell`, `goto`, `send`, `rename`, `undock`, `kill`, `tree`, `order`, `preview`, `refresh`, `columns`, `usage`, `closed`, `keys`, `quit`) to a key; a verb not named keeps its default, and an entry for any other verb, such as the retired `borrow`, SHALL be ignored. The key is what fzf is handed and what `?` and `tagents --keys` list.

#### Scenario: Moved key
- **WHEN** the config has `keys: {closed: ctrl-o, goto: ctrl-y}`
- **THEN** `ctrl-o` opens the closed-session picker, `ctrl-y` goes to the agent, and `tagents --keys` lists `ctrl-o` for `:closed` and `ctrl-y` for `goto`

#### Scenario: A retired verb
- **WHEN** the config has `keys: {borrow: ctrl-b}`
- **THEN** nothing is bound to `ctrl-b` and `tagents --keys` has no line for it

#### Scenario: The shell key moved
- **WHEN** the config has `keys: {shell: alt-s}`
- **THEN** `alt-s` opens a shell window, `ctrl-a` does not, and `tagents --keys` lists `alt-s` for `shell`

### Requirement: Dashboard-level keys
`ctrl-t` toggles tree and flat, `ctrl-o` toggles window order, `ctrl-l` reloads the list now, `ctrl-w` opens the column picker, `ctrl-v` the preview (all in `dashboard-list`), `$` opens the month's usage per day (the `usage-accounting` capability), `ctrl-y` the closed-session picker (`closed-sessions`), `ctrl-n` and `ctrl-p` start an agent (`chat-launch`), and `ctrl-a` opens a shell window (`window-rows`). The list SHALL also reload when its window is resized.

#### Scenario: Refresh
- **WHEN** the user presses `ctrl-l`
- **THEN** the list is rebuilt from the records at once
