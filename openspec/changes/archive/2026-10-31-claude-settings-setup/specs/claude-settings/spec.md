## ADDED Requirements

### Requirement: Setup registers the state hook and the status line
`tagents setup` SHALL add to the `settings.json` of each Claude config directory it covers the agent-state hook for `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, `SubagentStop` and `SessionEnd`, with `PreToolUse`, `PostToolUse` and `SubagentStop` as `"async": true` so they never sit in the tool-call path, and the status line that feeds the model column. What it adds is the file `hooks/claude-settings.json` of the checkout.

#### Scenario: A settings file with nothing of tagents
- **WHEN** `tagents setup` runs on a config directory whose `settings.json` has no `hooks` and no `statusLine`
- **THEN** each of the eight events has a group whose command runs `tmux-agent-state.sh`, and `PreToolUse`, `PostToolUse` and `SubagentStop` are `"async": true`
- **AND** `statusLine` is a `command` that runs `claude-statusline.sh`, with `padding` 0 and `refreshInterval` 30

#### Scenario: No settings file
- **WHEN** a config directory exists and has no `settings.json`
- **THEN** setup creates it with those entries and makes no backup, because there is nothing to back up

### Requirement: Setup only appends
`tagents setup` SHALL only add what is missing. An event is covered when a command of any group under it names `tmux-agent-state.sh` as a whole path component, and a covered event gets nothing. A missing event gets the registration's group at the end of its list. Groups and keys the person wrote are never edited, reordered or removed, and the file's other keys keep their order. A file with nothing to add SHALL NOT be written: same bytes, same modification time, no backup.

#### Scenario: The person's own hooks stay
- **WHEN** `Stop` already holds a group that runs `~/bin/notify-me.sh`, and `PreToolUse` a group with a `matcher` that runs `~/bin/guard.sh`
- **THEN** after setup each of those lists holds the person's group first, unchanged, and the group that runs `tmux-agent-state.sh` after it

#### Scenario: Registered by hand before
- **WHEN** every event already runs `sh '/Users/me/.claude/hooks/tmux-agent-state.sh'` and the status line runs `claude-statusline.sh`
- **THEN** setup says the file is already set up and does not write it

#### Scenario: A lookalike does not count
- **WHEN** `Stop` runs only `my-tmux-agent-state.sh` and `SessionEnd` runs only `tmux-agent-state.sh.bak`
- **THEN** both events are missing and get a group each

#### Scenario: A second run
- **WHEN** `tagents setup` runs again right after it changed a file
- **THEN** the file keeps its bytes and its modification time and no new backup appears

### Requirement: A status line of the person's own is kept
A `statusLine` whose `command` names `claude-statusline.sh` SHALL be left as it is, and a missing one SHALL be added. Any other `statusLine`, an object or not, SHALL be kept, and setup SHALL print that it kept it and the command `tagents setup --statusline` that replaces it. With `--statusline` the status line SHALL be replaced by tagents' one, after the backup every changed file gets.

#### Scenario: A status line of your own
- **WHEN** `statusLine.command` is `~/bin/my-line.sh`
- **THEN** that entry is unchanged, the hooks are still added, and the output names `~/bin/my-line.sh` and `tagents setup --statusline`

#### Scenario: Switching
- **WHEN** `tagents setup --statusline` runs on that file
- **THEN** `statusLine` is tagents' one and a backup holds the file as it was

#### Scenario: Its own line in another form
- **WHEN** `statusLine.command` is `bash ~/elsewhere/claude-statusline.sh`
- **THEN** it is left as it is and setup does not say it kept a status line of the person's own

#### Scenario: A status line that is not an object
- **WHEN** `statusLine` is the string `"~/bin/my-line.sh"`
- **THEN** it is kept, and the output says so and names `tagents setup --statusline`

### Requirement: A changed file is backed up and replaced whole
Before `tagents setup` changes a file it SHALL copy the previous one next to it as `<name>.tagents-<UTC YYYYmmddTHHMMSSZ>.bak`, with a suffix when that name is taken; a file that did not exist has no backup. It SHALL write the new content to a temp file in the same directory that keeps the old file's mode, and rename it over the file. The content is indented by two spaces and ends with a newline. After a failure the original is untouched and no temp file is left.

#### Scenario: A backup beside the file
- **WHEN** setup adds an event to `~/.claude/settings.json` at 10:32:07 UTC on 29 October 2026
- **THEN** `~/.claude/settings.json.tagents-20261029T103207Z.bak` holds the file as it was
- **AND** the new file has the mode the old one had

#### Scenario: A failed write
- **WHEN** the new content cannot be written because the directory is not writable
- **THEN** the original file is as it was, no temp file is left and the exit code is 1

### Requirement: Symlinks are followed and a concurrent write is not overwritten
A `settings.json` that is a symlink SHALL be written through to the real file, with the link left a link and the backup next to the real file, and a real file reached by two config directories SHALL be done once. If the file changed between setup's read and its rename, because Claude Code wrote it, setup SHALL start over from the new content, at most three times, and then refuse the file.

#### Scenario: One file under two names
- **WHEN** `~/.claude-shch/settings.json` is a symlink to `~/.claude/settings.json` and both directories are covered
- **THEN** the real file is changed once, the link is still a link, and one backup appears next to the real file

#### Scenario: Claude Code writes meanwhile
- **WHEN** the file changes after setup read it and before it replaced it
- **THEN** setup reads it again and adds to the new content, so the other writer's change is in the result

#### Scenario: A file that keeps changing
- **WHEN** the file changes under setup on each of three tries
- **THEN** setup refuses the file, leaves it as the other writer left it, and exits 1

### Requirement: Setup refuses a file it cannot merge into and leaves it alone
`tagents setup` SHALL refuse a file, leave it untouched, exit 1 and still process the other files, when it is not valid JSON (the message quotes the parser's error) or holds more than one JSON value, its top level is not an object, `hooks` is present and not an object, `hooks.<event>` of an event it registers is present and not an array, or `settings.json` is a dangling symlink, or is read-only when something has to be added. An empty or whitespace-only file is read as `{}`.

#### Scenario: Not JSON
- **WHEN** `settings.json` holds `{ "hooks": `
- **THEN** the file keeps its bytes, no backup is made, the output names the file and the parser's error, and the exit code is 1

#### Scenario: More than one JSON value
- **WHEN** `settings.json` holds `{} {}`
- **THEN** the file keeps its bytes, the output says it holds 2 JSON values, and the exit code is 1

#### Scenario: A read-only file
- **WHEN** `settings.json` has mode 444, lacks tagents' hooks, and the person is not root
- **THEN** the file keeps its bytes, the output says it is read-only, and the exit code is 1

#### Scenario: A read-only file that has everything
- **WHEN** `settings.json` has mode 444 and already holds tagents' hooks and status line
- **THEN** nothing is written, the output says it is already set up, and the exit code is 0

#### Scenario: A shape it cannot add to
- **WHEN** `hooks.Stop` is an object, or `hooks` is a list, or the whole file is a list
- **THEN** that file is refused with a message that names what has the wrong shape

#### Scenario: One bad file among good ones
- **WHEN** `~/.claude/settings.json` is not valid JSON and the `settings.json` of a profile is valid
- **THEN** the profile's file is set up and the exit code is 1

#### Scenario: An empty file
- **WHEN** `settings.json` is empty
- **THEN** it is read as `{}` and set up

#### Scenario: A dangling symlink
- **WHEN** `settings.json` is a symlink to a file that does not exist
- **THEN** it is refused and nothing is created

### Requirement: Setup covers the settings of every config directory tagents knows
`tagents setup` SHALL cover the `settings.json` of `~/.claude`, of `$CLAUDE_CONFIG_DIR` when it is set and not empty, and of the `config_dir` of each profile, each directory once however it is spelt, and no other file, `settings.local.json` included. A default directory that does not exist SHALL be skipped with a note and exit 0. `--config-dir DIR`, repeatable, SHALL replace that set; a named directory that does not exist is an error for it, and the others are still done.

#### Scenario: A profile's directory
- **WHEN** the profile `work` has `config_dir = "~/.claude-work"` and that directory exists
- **THEN** `~/.claude-work/settings.json` gets the entries as well as `~/.claude/settings.json`

#### Scenario: One directory spelt twice
- **WHEN** `$CLAUDE_CONFIG_DIR` is `~/.claude-work/` and a profile's `config_dir` is `~/.claude-work`
- **THEN** that directory is done once

#### Scenario: A default directory that is not there
- **WHEN** a profile's `config_dir` does not exist on this machine
- **THEN** setup notes that it skipped it and the exit code is still 0

#### Scenario: Only the named directories
- **WHEN** `tagents setup --config-dir ~/.claude-work` runs
- **THEN** only `~/.claude-work/settings.json` is looked at

#### Scenario: A named directory that is not there
- **WHEN** `tagents setup --config-dir /no/such/dir` runs
- **THEN** setup reports an error for it and the exit code is 1

### Requirement: The entries name the hooks directory that holds the scripts
For a config directory D the entries SHALL name the first of `D/hooks`, each `--hooks-dir` and `~/.claude/hooks` that holds every script the registration names, as `$HOME/<path>` with a literal `$HOME` when it is under the home directory and otherwise as an absolute path, inside the double quotes of an `sh` command, with `"`, `\`, `$` and the backtick escaped. When none holds them D SHALL be refused, and the message says to run `install.sh`, with `--hooks-dir D/hooks` for a copy of its own.

#### Scenario: The shared hooks directory
- **WHEN** `~/.claude-work/hooks` does not exist and `~/.claude/hooks` holds the scripts
- **THEN** `~/.claude-work/settings.json` runs `sh "$HOME/.claude/hooks/tmux-agent-state.sh"`

#### Scenario: A directory of its own
- **WHEN** `~/.claude-work/hooks` holds the scripts
- **THEN** `~/.claude-work/settings.json` runs `sh "$HOME/.claude-work/hooks/tmux-agent-state.sh"`

#### Scenario: A path the shell would read
- **WHEN** the hooks directory is `~/ho$ks`
- **THEN** the command is `sh "$HOME/ho\$ks/tmux-agent-state.sh"`

#### Scenario: Outside the home directory
- **WHEN** `--hooks-dir /opt/tagents/hooks` is the first candidate that holds the scripts
- **THEN** the command is `sh "/opt/tagents/hooks/tmux-agent-state.sh"`

#### Scenario: No scripts anywhere
- **WHEN** none of the candidates holds `tmux-agent-state.sh` and `claude-statusline.sh`
- **THEN** that directory is refused, nothing is written, the exit code is 1 and the message says to run `install.sh`

### Requirement: `--check` shows what setup would do and writes nothing
`tagents setup --check` SHALL print for each file what would be added or why it would be refused, and SHALL write, create and back up nothing. It SHALL exit 1 while anything is missing or a file would be refused, and 0 when everything is in place. A status line of the person's own that setup would keep is a choice, not something missing.

#### Scenario: Something is missing
- **WHEN** `Stop` is not registered in `~/.claude/settings.json`
- **THEN** `--check` names `Stop` for that file and exits 1, and the file keeps its bytes and its modification time

#### Scenario: Everything is in place
- **WHEN** all eight events and the status line are registered
- **THEN** `--check` says so and exits 0

#### Scenario: A status line of your own
- **WHEN** every event is registered and `statusLine` is the person's own
- **THEN** `--check` exits 0

#### Scenario: A file that would be refused
- **WHEN** a `settings.json` is not valid JSON
- **THEN** `--check` names the file and the reason and exits 1

### Requirement: The installer runs setup when the registration may have changed
`install.sh` SHALL run `tagents setup` after it installed the hooks and the LaunchAgent, with `--quiet` under `--quiet` and each of its `--hooks-dir`: on a first install, and on an update to a commit whose `hooks/claude-settings.json` differs from the one it moved from, and on no other run, so the daily update does not re-add what somebody removed. It SHALL NOT run it under `--check`. A failure SHALL be a warning, and the run ends with exit 1 after everything else is installed.

#### Scenario: A first install
- **WHEN** `install.sh` runs on a machine with no managed copy
- **THEN** it ends by running `tagents setup`, and `~/.claude/settings.json` registers the hook

#### Scenario: An update that changes the registration
- **WHEN** an update moves the copy to a commit whose `hooks/claude-settings.json` differs from the previous one
- **THEN** setup runs once at the end of that update

#### Scenario: An update that does not
- **WHEN** an update moves the copy and `hooks/claude-settings.json` is the same in both commits, or the copy is already up to date
- **THEN** setup does not run, so an entry the person removed stays removed

#### Scenario: A check
- **WHEN** `install.sh --check` runs
- **THEN** setup does not run and no `settings.json` is touched

#### Scenario: Setup fails
- **WHEN** setup exits 1 during an install, because one `settings.json` is not valid JSON
- **THEN** the installer prints a warning, finishes everything else, and exits 1

### Requirement: The command line, the report and the exit codes
`tagents setup [--check] [--statusline] [--config-dir DIR]... [--hooks-dir DIR]... [--quiet]` SHALL be answered by the `tagents` script itself and print one line per file: what was added and where the backup went, that it is already set up, or why it was refused, with `~` for `$HOME`. Errors go to standard error, and `--quiet` prints only refusals and errors. It SHALL exit 0 when every file is set up or was skipped, 1 for a refusal or a failure, 2 for a usage error.

#### Scenario: One line per file
- **WHEN** setup adds `Stop` and the status line to `~/.claude/settings.json`
- **THEN** one line names `~/.claude/settings.json`, what was added and the backup file

#### Scenario: Quiet
- **WHEN** `tagents setup --quiet` runs and every file is set up or already was
- **THEN** nothing is printed and the exit code is 0

#### Scenario: A usage error
- **WHEN** `tagents setup --nosuch` runs, or `--config-dir` has no value
- **THEN** a usage message goes to standard error and the exit code is 2
