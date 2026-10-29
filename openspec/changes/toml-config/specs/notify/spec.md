## MODIFIED Requirements

### Requirement: Plugin options and defaults
The options SHALL live in `<configDir>/plugins/notify.toml`, or in `notify.yaml` there when there is no `notify.toml`, with every key optional: `backend = "auto"` (one of `auto`, `macos`, `log`, `none`); `click = "dock"` (one of `dock`, `goto`, `focus`); `icon` unset; `events.question`, `events.permission` and `events.turn_done` each `enabled: true, skip_visible: true`; `events.cache_expiring` as `enabled: true, skip_visible: false, after: 50m, ttl: 60m`; `events.session_end` as `enabled: false, skip_visible: true`.

#### Scenario: a partial file
- **WHEN** the file says only `click = "goto"`
- **THEN** every event setting is still its default

#### Scenario: a partial event
- **WHEN** the file says only `enabled = false` under `[events.question]`
- **THEN** `events.question.skip_visible` is still `true`

#### Scenario: a YAML file
- **WHEN** only `notify.yaml` exists
- **THEN** it is read with the same keys and defaults

### Requirement: Where the options are watched
The service SHALL watch the real path of the `plugins` directory, so a config directory that is a symlink (for example into a dotfiles repository) works. A `plugins` directory that appears after the service started is found. `notify.toml` and `notify.yaml` are both watched, so options that move from one to the other while the service runs are seen. An options file that is itself a symlink is noticed only when the link is replaced, not when its target is edited. With no config directory at all the service runs and logs that options reload is off.

#### Scenario: symlinked config directory
- **WHEN** the config directory is a symlink into another directory and the real `notify.toml` is edited
- **THEN** the change is seen

#### Scenario: the directory appears later
- **WHEN** the `plugins` directory is created after the service started
- **THEN** the file in it is read and watched

#### Scenario: no config directory
- **WHEN** the config directory does not exist
- **THEN** the service runs and logs that options reload is off

#### Scenario: the options move to TOML
- **WHEN** `notify.toml` is written next to a `notify.yaml` while the service runs
- **THEN** the next event uses the values of `notify.toml`
