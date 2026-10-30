## MODIFIED Requirements

### Requirement: Config directory problems
`tagents --check` SHALL report each profile whose `config_dir` is empty, does not exist on this machine, is not a directory, is `~/.claude` written out, or has never been used (no `.claude.json` in it). The last is softer: the first agent on it will ask for a login. A launch on such a profile SHALL still be built and run, because logging in once on a fresh directory is how a new login is set up.

#### Scenario: Directory missing
- **WHEN** a profile's `config_dir` does not exist
- **THEN** `--check` says `does not exist on this machine — an agent on it starts logged out` and suggests keeping this machine's profiles in `config.<hostname>.yaml`
- **AND** `tagents --agent-cmd` for it still prints the launch string

#### Scenario: Explicit home default
- **WHEN** `config_dir` is `~/.claude`
- **THEN** `--check` says it is a different login from the default account and to drop the key

#### Scenario: Never used
- **WHEN** the directory exists but holds no `.claude.json`
- **THEN** `--check` says the first agent on it will ask you to log in

#### Scenario: Only a settings file
- **WHEN** the directory holds a `settings.json`, which `tagents setup` writes there, but no `.claude.json`
- **THEN** `--check` still says the first agent on it will ask you to log in

### Requirement: A login needs its own hooks
Every `config_dir` a profile names SHALL have `settings.json` entries for the state hook and the status line, which `tagents setup` writes, naming the directory's own `hooks/` when it has one and `~/.claude/hooks` otherwise. An agent started on a config directory without them runs no state hook and no status line, so it never appears in the dashboard and has no model column.

#### Scenario: A login without the hooks
- **WHEN** a profile's directory has no `settings.json`
- **THEN** agents started there do not appear in the dashboard until `tagents setup` has registered the hooks in that directory

#### Scenario: A profile added after the install
- **WHEN** a profile is added to the config after `install.sh` ran
- **THEN** its directory has no entries until `tagents setup` runs

#### Scenario: Hooks shared with the default login
- **WHEN** a profile's directory has no `hooks/` of its own and `~/.claude/hooks` holds the scripts
- **THEN** `tagents setup` registers entries in that directory's `settings.json` that name `~/.claude/hooks`, and agents started there appear in the dashboard
- **AND** each shows the profile's account, because the hook records the `CLAUDE_CONFIG_DIR` of the agent's own environment, not the place the script lives
