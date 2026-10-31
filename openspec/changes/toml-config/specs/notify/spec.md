## MODIFIED Requirements

### Requirement: Plugin options and defaults
The options SHALL live in `<configDir>/plugins/notify.toml`, with every key optional: `backend = "auto"` (one of `auto`, `macos`, `log`, `none`); `click = "dock"` (one of `dock`, `goto`, `focus`); `icon` unset.

#### Scenario: a partial file
- **WHEN** the file says only `click = "goto"`
- **THEN** every event setting is still its default

#### Scenario: a partial event
- **WHEN** the file says only `enabled = false` under `[events.question]`
- **THEN** `events.question.skip_visible` is still `true`

#### Scenario: a YAML file
- **WHEN** only `notify.yaml` exists
- **THEN** it is not looked at and the defaults hold

### Requirement: Where the options are watched
The service SHALL watch the real path of the `plugins` directory, so a config directory that is a symlink (for example into a dotfiles repository) works. A `plugins` directory that appears after the service started is found. With no config directory at all the service runs and logs that options reload is off.

#### Scenario: symlinked config directory
- **WHEN** the config directory is a symlink into another directory and the real `notify.toml` is edited
- **THEN** the change is seen

#### Scenario: the directory appears later
- **WHEN** the `plugins` directory is created after the service started
- **THEN** the file in it is read and watched

#### Scenario: no config directory
- **WHEN** the config directory does not exist
- **THEN** the service runs and logs that options reload is off

## ADDED Requirements

### Requirement: Notify event defaults
Each notification event SHALL have these settings when the file leaves them out: `events.question`, `events.permission` and `events.turn_done` each `enabled: true, skip_visible: true`; `events.cache_expiring` as `enabled: true, skip_visible: false, after: 50m, ttl: 60m`; `events.session_end` as `enabled: false, skip_visible: true`.

#### Scenario: no file
- **WHEN** there is no options file
- **THEN** `events.cache_expiring` is `enabled: true, skip_visible: false, after: 50m, ttl: 60m` and `events.session_end` is `enabled: false, skip_visible: true`

### Requirement: Which options files are watched
`notify.toml` SHALL be watched, so a change to it while the service runs is seen. Editing the target of an options file that is a symlink does not reload the options by itself, and replacing the link does.

#### Scenario: the options file is written while the service runs
- **WHEN** `notify.toml` is written, with a `notify.yaml` beside it or without one
- **THEN** the next event uses the values of `notify.toml`

#### Scenario: a symlinked options file
- **WHEN** `notify.toml` is a symlink and its target is edited
- **THEN** the edit does not reload the options, and replacing the link does
