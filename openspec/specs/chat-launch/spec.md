# chat-launch Specification

## Purpose
Starting a Claude Code chat from tagents: a new agent for a project from `ctrl-n`, `ctrl-p` or `tagents --new`, the account dialog, and bringing a closed row back with `enter` on the account it ran on.

## Requirements

### Requirement: ctrl-n starts a new agent for the project under the cursor
`ctrl-n` SHALL start a fresh Claude for the project of the row under the cursor, a group header and an agent row alike, on the account the rules of the configuration pick for that project and tmux session. The directory SHALL be normalised to its repository root, so a session started in a subdirectory makes the new agent a sibling in the repository rather than in the subdirectory. A row with no known directory means the current working directory.

#### Scenario: Subdirectory
- **WHEN** the cursor is on a row whose directory is `~/projects/app/packages/client` inside the repository `~/projects/app`
- **THEN** the new agent starts in `~/projects/app`

#### Scenario: Account from the rules
- **WHEN** a rule maps the directory to the profile `personal`
- **THEN** the agent starts on that profile's config directory with the configured arguments

### Requirement: ctrl-p always asks which account
`ctrl-p` SHALL open the account dialog for the project under the cursor whatever the rules say, since a rule is a default and not a verdict. With no profiles in the configuration it SHALL show `tagents: no claude profiles in <config file>`, open no window and start nothing.

#### Scenario: No profiles
- **WHEN** no configuration file exists and the user presses `ctrl-p`
- **THEN** no window is opened and nothing is started

### Requirement: `tagents --new` starts an agent from outside the list
`tagents --new [DIR] [PROFILE]` SHALL start an agent in DIR (default the current directory) from a tmux binding, a shell or a script. PROFILE, when given, SHALL be an existing profile or `ask`; the account otherwise comes from the rules. A DIR that is not a directory SHALL print `tagents: <dir> is not a directory` as a tmux message and exit 1.

#### Scenario: Explicit profile
- **WHEN** `tagents --new ~/projects/app personal` is run
- **THEN** the agent starts in `~/projects/app` on the config directory of the profile `personal`, with the configured arguments

#### Scenario: Profile without a config directory
- **WHEN** the profile has no `config_dir` and the caller's environment has `CLAUDE_CONFIG_DIR` set
- **THEN** the agent starts with `CLAUDE_CONFIG_DIR` unset, not empty and not inherited

#### Scenario: Rules
- **WHEN** no profile is given and a rule matches the directory
- **THEN** the rule's profile is used

### Requirement: A profile that does not exist is refused
A profile name that is not in the configuration, such as a misspelling of a real one, SHALL be refused before any window or session is created: `tagents --new` prints `tagents: no claude profile "<name>" in <config file>` on standard error, shows the same as a tmux message and exits 1. The agent SHALL NOT be started on the default account instead.

#### Scenario: Misspelt profile
- **WHEN** `tagents --new ~/projects/app personl` is run
- **THEN** it exits 1, starts nothing and opens no window

### Requirement: Without any configuration nothing changes
With no configuration file, an agent SHALL be started as it always was: with `--dangerously-skip-permissions` and the caller's environment inherited. How the configuration is parsed, and the rules, belong to the `configuration` and `accounts` capabilities.

#### Scenario: No config
- **WHEN** `TA_CONFIG` names a file that does not exist and `tagents --new ~/projects/app` is run
- **THEN** the agent has `--dangerously-skip-permissions` and an unmodified `CLAUDE_CONFIG_DIR`

### Requirement: A new agent opens in the group the cursor is in
The new agent's window SHALL be created, detached, in the tmux session of the group the dashboard cursor is in. When the cursor is on the group `no window`, or the agent is started without a dashboard (`tagents --new` from a shell), it SHALL be created in the session that owns the project: the session where most of the live panes sitting in that directory are, else the session of the client, else the session tmux treats as current, else, with no session at all, a new session named `agents`.

#### Scenario: Owning session
- **WHEN** the cursor is on a row of the tmux session `proj`
- **THEN** the new agent's window is in `proj`

#### Scenario: No windows
- **WHEN** the cursor is on the group `no window` and every agent of the project is closed
- **THEN** the window is created in the session of the client

#### Scenario: No tmux server
- **WHEN** `tagents --new DIR` runs with no tmux server running and no window for the project
- **THEN** a tmux server is started with a session named `agents` whose first window is the new agent

### Requirement: A new agent is opened like any other
After its window is created the new agent SHALL be selected as `enter` on its row would do (the `window-rows` capability): the viewport shows its window and the cursor is on its row. With no dashboard up the client SHALL be taken to the new window. `tagents` SHALL show `tagents: new agent in <project> (<session>:<window>) as <profile>` (the last words only when a profile was used) and take a fresh snapshot for the `resurrect` capability.

#### Scenario: Cursor lands in the agent
- **WHEN** the user presses `ctrl-n` in the dashboard's list
- **THEN** the viewport shows the new agent's window with the agent's pane active

### Requirement: The account dialog is a list of profiles
When the rules say `ask`, or on `ctrl-p`, an `account> ` picker SHALL list every profile with its config directory (`default (~/.claude)` for a profile with none), under a header saying which project it is for (`which claude account for <project>?` or `start a new agent in <project> as…`) and the directory and session, ending with `esc cancels`. Choosing a profile starts the agent on it; `esc`, or a choice that is not a profile, starts nothing.

#### Scenario: Choose work
- **WHEN** the user chooses `work`, a profile without a config directory
- **THEN** the agent starts on the default account in the asked directory

#### Scenario: Choose nothing
- **WHEN** the picker is closed without a choice
- **THEN** nothing is started

#### Scenario: Drawn on screen
- **WHEN** the picker is shown in a pane
- **THEN** its prompt, its profile rows and its header are visible, since it draws on standard error

### Requirement: Enter on a closed row resumes it
`enter` on a closed row SHALL restart the session with `claude --resume <id>` on the account it ran on and select it as `enter` on a live agent would. When the row's old pane still exists and sits at an idle shell the command SHALL be typed into it after a `cd` to the session's directory; otherwise it SHALL be started in a new window of the session of the row's group, or of the client's session for a row in the group `no window`.

#### Scenario: Idle shell
- **WHEN** the dead row's pane is at a shell prompt
- **THEN** the resume command is typed into that same pane

#### Scenario: Pane busy or gone
- **WHEN** the pane is gone or running something else
- **THEN** a new window is opened and nothing is typed into the old pane

#### Scenario: Directory gone
- **WHEN** the session's directory no longer exists
- **THEN** the home directory is used instead

#### Scenario: No session id
- **WHEN** the row's record has no session id
- **THEN** `tagents: no session id recorded — cannot resume` is shown and nothing is started

### Requirement: Resuming never consults the rules
The account a closed row comes back on SHALL be the one recorded for it by the hook, because a conversation resumed on another login does not exist there. Only a record written before accounts were recorded falls back to the rules, and when they say `ask` the account dialog opens headed `resume <name> as…`. A recorded account that no profile claims SHALL NOT be guessed.

#### Scenario: Recorded account wins
- **WHEN** the pane's shell has `CLAUDE_CONFIG_DIR=/leak` exported and the record names the personal profile
- **THEN** the session resumes on the personal config directory

#### Scenario: Old record
- **WHEN** a six-field record names no account
- **THEN** the rules of the configuration pick the account

#### Scenario: Profile named default
- **WHEN** a profile happens to be called `default` with its own config directory and a record has an empty account
- **THEN** the resume command unsets `CLAUDE_CONFIG_DIR` and does not set the default profile's directory

### Requirement: Both resume routes send the same command
Whether the command is typed into the old pane or started as a new window, it SHALL be the identical string, with its `env` prefix selecting the account, so it does not depend on any shell function of the user that would work the account out again from the directory.

#### Scenario: Preview matches
- **WHEN** a closed row's preview shows `enter runs:`
- **THEN** the command shown is the command `enter` runs

### Requirement: `tagents --window` opens a plain window from outside the list
`tagents --window DIR COMMAND` SHALL open a window in the tmux session that owns DIR, found as for a new agent, and run COMMAND in it, one string for the window's shell: the window closes when COMMAND ends. A COMMAND that starts with a dash is the command and not an option of tmux.

#### Scenario: A command in a project
- **WHEN** `tagents --window ~/projects/app "npm run dev"` runs inside tmux
- **THEN** a window opens in the session that owns `~/projects/app` with its working directory there, running `npm run dev`

#### Scenario: A command that starts with a dash
- **WHEN** `tagents --window ~/projects/app "-zzz"` runs
- **THEN** a window opens whose shell is given `-zzz` as its command, and tmux does not read it as one of its own options

### Requirement: A directory given to `--new` or `--window` is made absolute
`tagents --new` and `tagents --window` SHALL make their DIR absolute against the caller's directory, whatever `CDPATH` holds, and resolve symlinks, so the directory they start in, the one tmux reports and the one the session lookup compares are the same physical path. A DIR that cannot be entered SHALL be refused as `tagents: <dir> is not a directory`, exit 1, with no window opened.

#### Scenario: A relative directory
- **WHEN** `tagents --window . "make watch"` runs from a shell whose directory differs from the tmux server's
- **THEN** the window's working directory is the shell's

#### Scenario: A relative directory for a new agent
- **WHEN** `tagents --new plain-dir personal` runs from the directory that holds `plain-dir`
- **THEN** the agent starts in the absolute path of `plain-dir`, in the session that owns it

#### Scenario: A directory name with `CDPATH` set
- **WHEN** `CDPATH` holds a directory that also contains a directory called `app`, and `tagents --window app "make watch"` runs
- **THEN** the window is opened in the `app` of the current directory, and standard output is exactly one line

#### Scenario: A symlink to a directory
- **WHEN** `tagents --window --detach app-link "make watch"` runs from the directory that holds `app-link`, a symlink to `~/projects/app`
- **THEN** the window opens in the session that owns `~/projects/app`, with that physical directory as its working directory

#### Scenario: A relative symlink for a new agent
- **WHEN** `tagents --new --detach plain-link personal` runs from the directory that holds `plain-link`, a symlink to `plain-dir`
- **THEN** the agent starts in the physical path of `plain-dir`, in the session that owns it

#### Scenario: A directory that cannot be entered
- **WHEN** `tagents --window` runs with a DIR that exists but has no search permission, named by an absolute or by a relative path
- **THEN** it exits 1, prints `tagents: <dir> is not a directory` and opens no window

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
