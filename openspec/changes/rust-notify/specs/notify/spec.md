## MODIFIED Requirements

### Requirement: Plugin options and defaults
The options SHALL live in `<configDir>/plugins/notify.toml` with every key optional: `backend = "auto"` (one of `auto`, `macos`, `log`, `none`); `click = "dock"` (one of `dock`, `goto`, `focus`); `icon` unset; `events.question`, `events.permission` and `events.turn_done` each `enabled = true, skip_visible = true`; `events.cache_expiring` as `enabled = true, skip_visible = false, after = "50m", ttl = "60m"`; `events.session_end` as `enabled = false, skip_visible = true`.

#### Scenario: a partial file
- **WHEN** the file says only `click = "goto"`
- **THEN** every event setting is still its default

#### Scenario: a partial event
- **WHEN** the file says only `events.question.enabled = false`
- **THEN** `events.question.skip_visible` is still `true`

### Requirement: Where the options are watched
The service SHALL watch the real path of the `plugins` directory, so a config directory that is a symlink (for example into a dotfiles repository) works. A `plugins` directory that appears after the service started is found. A `notify.toml` that is itself a symlink is noticed only when the link is replaced, not when its target is edited. With no config directory at all the service runs and logs that options reload is off.

#### Scenario: symlinked config directory
- **WHEN** the config directory is a symlink into another directory and the real `notify.toml` is edited
- **THEN** the change is seen

#### Scenario: the directory appears later
- **WHEN** the `plugins` directory is created after the service started
- **THEN** the file in it is read and watched

#### Scenario: no config directory
- **WHEN** the config directory does not exist
- **THEN** the service runs and logs that options reload is off
