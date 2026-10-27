## MODIFIED Requirements

### Requirement: The `$` table
The `$` key, and `tagents --ask-usage`, SHALL show the month a day per row for the watched account only: a header `usage · <month> · <account>`, then a row per day, newest first, with the day, dollars and requests, a `~` after a day that has requests nothing could be priced from, the footer's summary line and a note explaining the `~`. It SHALL open in a popup with `less` where available and print inline with an any-key close where it is not.

#### Scenario: The table
- **WHEN** `tagents --ask-usage` runs with usage on
- **THEN** the output names the month and the account, has a row for today as the newest, ends with a line containing `of $850`
- **AND** shows nothing for an account that is not watched

#### Scenario: Usage off
- **WHEN** `usage.watch` is unset and the user presses `$`
- **THEN** no window opens and `tagents: usage is off — set usage.watch to the profile to track` is shown
