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
The new agent's window SHALL be created, detached, in the tmux session of the group the dashboard cursor is in. When the cursor is on the group `no window`, or the agent is started without a dashboard (`tagents --new` from a shell), it SHALL be created in the session that owns the project: the session where most of the live panes sitting in that directory are, else the session of the client, else the session tmux treats as current.

#### Scenario: Owning session
- **WHEN** the cursor is on a row of the tmux session `proj`
- **THEN** the new agent's window is in `proj`

#### Scenario: No windows
- **WHEN** the cursor is on the group `no window` and every agent of the project is closed
- **THEN** the window is created in the session of the client

### Requirement: A new agent is opened like any other
After its window is created the new agent SHALL be selected as `enter` on its row would do (the `window-rows` capability): the sidebar is moved into its window, the cursor is in the agent, and the client ends up looking at it. With no sidebar the client SHALL be taken to the new window. `tagents` SHALL show `tagents: new agent in <project> (<session>:<window>) as <profile>` (the last words only when a profile was used) and take a fresh snapshot for the `resurrect` capability.

#### Scenario: Cursor lands in the agent
- **WHEN** the user presses `ctrl-n` in the sidebar
- **THEN** the client's current pane is the new agent and the sidebar is in its window

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
