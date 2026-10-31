## MODIFIED Requirements

### Requirement: The dashboard's own flags are answered by the script
Every option that starts with `-` and that the dashboard knows SHALL be answered by the `tagents` script itself and SHALL NEVER be forwarded to `tagents-core`, so a typo in one of them cannot start another process. These flags are matched before any verb is considered, so forwarding can shadow none of them. What each flag does is recorded by the capability that owns it.

#### Scenario: The flags the script answers
- **WHEN** one of `-h`, `--help`, `--list`, `--flat`, `--toggle-group`, `--timeline`, `--label`, `--ask-rename`, `--ask-send`, `--ask-kill`, `--ask-profile`, `--ask-columns`, `--col-rows`, `--toggle-col`, `--hidden-cols`, `--ask-keys`, `--ask-usage`, `--closed-rows`, `--closed-preview`, `--ask-closed`, `--resurrect-save`, `--resurrect-rows`, `--resurrect`, `--keys`, `--header`, `--act` is given
- **THEN** the script handles it itself

#### Scenario: The rest of the flags
- **WHEN** one of `--new`, `--window`, `--profile-for`, `--config`, `--check`, `--agent-cmd`, `--counts`, `--preview`, `--ask-preview`, `--preview-popup`, `--follow`, `--sync-names`, `--refresher`, `--ensure-dash`, `--goto`, `--viewport` is given
- **THEN** the script handles it itself

#### Scenario: Removed flags
- **WHEN** one of `--focus-hooks`, `--slot`, `--unpark`, `--poke`, `--undock-pane`, `--undock-window`, `--collapse`, `--seats`, `--current-seat` or `--ensure-seat` is given
- **THEN** the script does not treat it as a flag of its own

#### Scenario: Answered here
- **WHEN** `tagents --keys`, `--hidden-cols`, `--config`, `--check`, `--header` or `--help` runs while a `tagents-core` is available
- **THEN** the script answers it and `tagents-core` is not started
