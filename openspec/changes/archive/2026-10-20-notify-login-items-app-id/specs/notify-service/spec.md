## MODIFIED Requirements

### Requirement: What launchd runs
The LaunchAgent SHALL live at `~/Library/LaunchAgents/io.github.skuratovicha.tagents-notify.plist` with that string as its label, whatever icon the helper app was built with, run `node dist/main.js run` at load, restart only after a failed exit (`KeepAlive` with `SuccessfulExit` false) and at least 300 seconds apart, and send both output streams to the log file.

#### Scenario: the plist
- **WHEN** install writes the agent
- **THEN** the plist restarts only after a failed exit, at least 5 minutes apart, and passes `plutil -lint`

#### Scenario: hostile characters
- **WHEN** an environment value holds `&`, `<`, `>` or quotes
- **THEN** the plist escapes them

## ADDED Requirements

### Requirement: The job is filed under the app in Login Items
The plist's `AssociatedBundleIdentifiers` SHALL name the bundle id the installed helper app has, read from the app at install time, so that Login Items files the job under the app; with no app, or when the id cannot be read, it SHALL name `io.github.skuratovicha.tagents-notify`.

#### Scenario: an app built with an icon
- **WHEN** install runs and the helper app was built with an icon
- **THEN** `AssociatedBundleIdentifiers` names `io.github.skuratovicha.tagents-notify.i<8 hex>` and the label stays `io.github.skuratovicha.tagents-notify`

#### Scenario: no icon, no app, or an unreadable app
- **WHEN** the app has no icon of its own, is missing, or its bundle id cannot be read
- **THEN** `AssociatedBundleIdentifiers` names `io.github.skuratovicha.tagents-notify`
