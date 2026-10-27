## REMOVED Requirements

### Requirement: A dashboard layout that cannot be read
**Reason**: The key is gone: the cockpit is the only layout, so there is no value to be misspelt and no layout to fall back to.
**Migration**: None. A file that still carries `dashboard.layout` is read like any key this version does not read ("Keys the file carries").

## MODIFIED Requirements

### Requirement: Keys the file carries
The file SHALL carry these top-level sections, each read by the capability named: `claude` (args, profiles, rules, default; `accounts`), `usage` (watch, monthly_limit_usd, safety_margin_pct, workdays, meter; `usage-accounting`), `notes` (send; `notes-workspace`), `resurrect` (auto, every, notes; `resurrect`), `keys` (`dashboard-keys`) and `plugins` (`plugin-system`). A key this version does not read SHALL be ignored.

#### Scenario: Unknown key
- **WHEN** the file has a section `something_newer` with a nested key that this version does not read
- **THEN** `tagents --check` has nothing to say about it and the leaves still print in `--config`

#### Scenario: A key a version dropped
- **WHEN** the file still sets `dashboard.layout`, a key an earlier version read
- **THEN** `tagents --check` has nothing to say about it and `tagents --config` prints the leaf `dashboard.layout`
