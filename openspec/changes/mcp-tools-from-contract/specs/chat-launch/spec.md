## ADDED Requirements

### Requirement: `tagents --window` opens a plain window from outside the list
`tagents --window DIR COMMAND` SHALL open a window in the tmux session that owns DIR, found as for a new agent, and run COMMAND in it, one string for the window's shell: the window closes when COMMAND ends. DIR is made absolute against the caller's directory, whatever `CDPATH` holds, as `tagents --new` does for its DIR, and a COMMAND that starts with a dash is the command and not an option of tmux.

#### Scenario: A command in a project
- **WHEN** `tagents --window ~/projects/app "npm run dev"` runs inside tmux
- **THEN** a window opens in the session that owns `~/projects/app` with its working directory there, running `npm run dev`

#### Scenario: A relative directory
- **WHEN** `tagents --window . "make watch"` runs from a shell whose directory differs from the tmux server's
- **THEN** the window's working directory is the shell's

#### Scenario: A relative directory for a new agent
- **WHEN** `tagents --new plain-dir personal` runs from the directory that holds `plain-dir`
- **THEN** the agent starts in the absolute path of `plain-dir`, in the session that owns it

#### Scenario: A directory name with `CDPATH` set
- **WHEN** `CDPATH` holds a directory that also contains a directory called `app`, and `tagents --window app "make watch"` runs
- **THEN** the window is opened in the `app` of the current directory, and standard output is exactly one line

#### Scenario: A command that starts with a dash
- **WHEN** `tagents --window ~/projects/app "-zzz"` runs
- **THEN** a window opens whose shell is given `-zzz` as its command, and tmux does not read it as one of its own options

### Requirement: `tagents --window` shows and reports the window
The new window SHALL be selected as `enter` on a row would do, a tmux message `tagents: new window in <project> (<session>:<window>)` SHALL be shown, and standard output SHALL be the new pane id, a tab and `<session>:<window index>`.

#### Scenario: Where the window is
- **WHEN** `tagents --window ~/projects/app "npm run dev"` succeeds
- **THEN** standard output is `%<n>`, a tab and `<session>:<index>` of the new window, which is the active window of its session

### Requirement: `tagents --window` refuses what it cannot open
A DIR that is not a directory SHALL print `tagents: <dir> is not a directory` on standard error and exit 1. Anything but exactly a DIR and one COMMAND (none, one, or more than two words, or an empty one) SHALL print `tagents: --window takes a directory and one command, quoted` and exit 2. No window is opened in either case.

#### Scenario: Not a directory
- **WHEN** `tagents --window /nowhere "ls"` runs
- **THEN** it exits 1, prints `tagents: /nowhere is not a directory` and opens no window

#### Scenario: Missing command
- **WHEN** `tagents --window ~/projects/app` runs
- **THEN** it exits 2, prints `tagents: --window takes a directory and one command, quoted` and opens no window

#### Scenario: A command that was not quoted
- **WHEN** `tagents --window ~/projects/app npm run dev` runs
- **THEN** it exits 2, prints the same line and opens no window, instead of running `npm` and dropping `run dev`

### Requirement: `--detach` opens the window without taking the screen
`tagents --new [--detach] [DIR] [PROFILE]` and `tagents --window [--detach] DIR COMMAND` SHALL, given `--detach` straight after the flag, make and register the window where it belongs without selecting it, without switching any client. The one-line tmux message is shown as without the flag, and a refusal is also written to standard error, because the caller is a program that reads standard error and the exit status. Without `--detach` both behave as before.

#### Scenario: A window that is not selected
- **WHEN** `tagents --window --detach ~/projects/app "npm run dev"` runs while another window of that session is selected
- **THEN** the window opens running the command, standard output is its pane, a tab and `<session>:<window index>` as without the flag, and the window that was selected still is

#### Scenario: An agent that is not selected
- **WHEN** `tagents --new --detach ~/projects/app work` runs
- **THEN** the agent starts on the account `work` in the session that owns the directory, and its window is not selected

#### Scenario: Without the flag
- **WHEN** `tagents --new ~/projects/app work` runs
- **THEN** the new window is selected, as `enter` on a row leaves it

#### Scenario: A refusal under --detach
- **WHEN** `tagents --new --detach /nowhere` runs and `/nowhere` is not a directory
- **THEN** it exits 1, prints `tagents: /nowhere is not a directory` on standard error and opens no window

### Requirement: A detached `--new` says which window it opened
`tagents --new --detach` SHALL print on standard output the one line `tagents --window` prints, the new pane, a tab and `<session>:<window index>`, so a caller that cannot see the screen can say which window it opened. `tagents --new` without `--detach` SHALL print nothing on standard output, as it always did.

#### Scenario: A detached agent is named by its line
- **WHEN** `tagents --new --detach ~/projects/app work` runs
- **THEN** standard output is one line: the agent's pane, a tab and `<session>:<window index>` of its window

#### Scenario: An agent that is selected prints nothing
- **WHEN** `tagents --new ~/projects/app work` runs
- **THEN** nothing is printed on standard output

### Requirement: A detached `--new` never asks which account
`tagents --new --detach` SHALL never open a dialog. When the rules for DIR resolve to asking which account to use, or the profile given is `ask`, it SHALL print `tagents: the config asks which account <dir> runs on, and --detach opens no dialog; name one of: <profiles>` on standard error with the configured profiles, exit 2, open no window and start nothing.

#### Scenario: The rules say to ask
- **WHEN** no rule matches the directory, so the config asks which account to use, and `tagents --new --detach <dir>` runs
- **THEN** it exits 2, names the configured profiles, opens no window and starts nothing

#### Scenario: Asking by name
- **WHEN** `tagents --new --detach <dir> ask` runs
- **THEN** it is refused in the same way
