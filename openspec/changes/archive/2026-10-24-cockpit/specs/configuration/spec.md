## ADDED Requirements

### Requirement: A dashboard layout that cannot be read
`--check` SHALL report a `dashboard.layout` that is not `follow` or `cockpit` (read as `follow`).

#### Scenario: A misspelt layout
- **WHEN** `dashboard.layout` is `ide`
- **THEN** `--check` has the line `dashboard.layout: "ide" is not one of follow, cockpit — read as follow`
- **AND** `tagents --ensure-dash` puts the sidebar into the client's window and creates no session `tagents`

## MODIFIED Requirements

### Requirement: Keys the file carries
The file SHALL carry these top-level sections, each read by the capability named: `claude` (args, profiles, rules, default; `accounts`), `usage` (watch, monthly_limit_usd, safety_margin_pct, workdays, meter; `usage-accounting`), `notes` (send; `notes-workspace`), `resurrect` (auto, every, notes; `resurrect`), `dashboard` (layout; `cockpit`), `keys` (`dashboard-keys`) and `plugins` (`plugin-system`). A key this version does not read SHALL be ignored.

#### Scenario: Unknown key
- **WHEN** the file has a section `something_newer` with a nested key that this version does not read
- **THEN** `tagents --check` has nothing to say about it and the leaves still print in `--config`

#### Scenario: The dashboard section
- **WHEN** the file sets `dashboard.layout` to `cockpit`
- **THEN** `tagents --check` has nothing to say about it and `tagents --config` prints the leaf `dashboard.layout` with the value `cockpit`
