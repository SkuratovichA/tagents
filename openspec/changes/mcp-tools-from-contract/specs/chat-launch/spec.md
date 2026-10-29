## ADDED Requirements

### Requirement: `tagents --window` opens a plain window from outside the list
`tagents --window DIR COMMAND` SHALL open a window in the tmux session that owns DIR, found as for a new agent, and run COMMAND in it, one string for the window's shell: the window closes when COMMAND ends. DIR is made absolute against the caller's directory.

#### Scenario: A command in a project
- **WHEN** `tagents --window ~/projects/app "npm run dev"` runs inside tmux
- **THEN** a window opens in the session that owns `~/projects/app` with its working directory there, running `npm run dev`

#### Scenario: A relative directory
- **WHEN** `tagents --window . "make watch"` runs from a shell whose directory differs from the tmux server's
- **THEN** the window's working directory is the shell's

### Requirement: `tagents --window` shows and reports the window
The new window SHALL be selected as `enter` on a row would do, a tmux message `tagents: new window in <project> (<session>:<window>)` SHALL be shown, and standard output SHALL be the new pane id, a tab and `<session>:<window index>`.

#### Scenario: Where the window is
- **WHEN** `tagents --window ~/projects/app "npm run dev"` succeeds
- **THEN** standard output is `%<n>`, a tab and `<session>:<index>` of the new window, which is the active window of its session

### Requirement: `tagents --window` refuses what it cannot open
A DIR that is not a directory SHALL print `tagents: <dir> is not a directory` on standard error and exit 1. A missing DIR or COMMAND SHALL print `tagents: --window needs a directory and a command` and exit 2. No window is opened in either case.

#### Scenario: Not a directory
- **WHEN** `tagents --window /nowhere "ls"` runs
- **THEN** it exits 1, prints `tagents: /nowhere is not a directory` and opens no window

#### Scenario: Missing command
- **WHEN** `tagents --window ~/projects/app` runs
- **THEN** it exits 2 and opens no window
