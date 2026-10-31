## MODIFIED Requirements

### Requirement: Which options files are watched
`notify.toml` SHALL be watched, so a change to it while the service runs is seen. Editing the target of an options file that is a symlink does not reload the options by itself: it takes effect at the next event of any name in the options directory, and replacing the link reloads at once.

#### Scenario: the options file is written while the service runs
- **WHEN** `notify.toml` is written, with a `notify.yaml` beside it or without one
- **THEN** the next event uses the values of `notify.toml`

#### Scenario: a symlinked options file
- **WHEN** `notify.toml` is a symlink and its target is edited, and nothing else happens in the options directory
- **THEN** the edit does not reload the options, and replacing the link does

#### Scenario: a symlinked options file edited, then a file of another name written
- **WHEN** `notify.toml` is a symlink, its target is edited, and then a file of another name is written in the options directory
- **THEN** the options reload once and the new values apply
