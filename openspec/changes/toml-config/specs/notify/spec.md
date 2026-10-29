## MODIFIED Requirements

### Requirement: Plugin options and defaults
The options SHALL live in `<configDir>/plugins/notify.toml`, or in `notify.yaml` there when there is no `notify.toml`, with every key optional: `backend = "auto"` (one of `auto`, `macos`, `log`, `none`); `click = "dock"` (one of `dock`, `goto`, `focus`); `icon` unset.

#### Scenario: a key left out
- **WHEN** the file says only `click = "goto"`
- **THEN** `backend` is still `auto` and `icon` is still unset

#### Scenario: a YAML file
- **WHEN** only `notify.yaml` exists
- **THEN** it is read with the same keys and defaults

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

#### Scenario: a partial file
- **WHEN** the file says only `click = "goto"`
- **THEN** every event setting is still its default

#### Scenario: a partial event
- **WHEN** the file says only `enabled = false` under `[events.question]`
- **THEN** `events.question.skip_visible` is still `true`

### Requirement: Which options files are watched
`notify.toml` and `notify.yaml` SHALL both be watched, so options that move from one to the other while the service runs are seen. An options file that is itself a symlink is noticed only when the link is replaced, not when its target is edited.

#### Scenario: the options move to TOML
- **WHEN** `notify.toml` is written next to a `notify.yaml` while the service runs
- **THEN** the next event uses the values of `notify.toml`

#### Scenario: a symlinked options file
- **WHEN** `notify.toml` is a symlink and its target is edited
- **THEN** the change is not seen until the link is replaced
