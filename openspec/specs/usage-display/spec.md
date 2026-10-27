# usage-display Specification

## Purpose
With `usage.watch` set, tagents shows what `tusage` computes: the cost column, the subagent share, the five-hour total, the model column, the month against its limit in the status bar and the footer, and the `$` day table. Without it every one of these is absent.

## Requirements
### Requirement: Usage is off until a profile is watched
Every usage surface SHALL be active only when the config key `usage.watch` names a profile and `tusage` is on the PATH. Without it there SHALL be no cost column and no subagent share, no five-hour burn, no month figure in the status bar, no footer, no `$` table, no cost in previews, and `tusage` SHALL NOT be run at all, neither for display nor by the refresher.

#### Scenario: No watched profile
- **WHEN** the config has a `usage` block with a limit and a margin but no `usage.watch`
- **THEN** the status bar and the list are byte for byte what a config with no `usage` block produces
- **AND** no `/850`-style month figure is printed
- **AND** `tusage` is run by neither the status bar nor the list build
- **AND** the cost column is reported as hidden and the column picker does not offer it

#### Scenario: A watched profile
- **WHEN** `usage.watch` names a profile
- **THEN** the status bar asks `tusage --no-update --burn`
- **AND** the list build asks `tusage --no-update --sessions`
- **AND** the column picker offers the cost column

### Requirement: Display reads the index and never waits on the updater
Status-bar runs, list builds, previews and the `$` table SHALL call `tusage` with `--no-update`, which reads the existing index and never advances it. Advancing the index SHALL be the job of the refresher, which runs `tusage --update`. A report SHALL NOT need the updater to have run first.

#### Scenario: Reading with --no-update
- **WHEN** `tusage --no-update --daily` runs against an index written by hand
- **THEN** it reports from that index without scanning transcripts

### Requirement: The accounts tusage is handed
tagents SHALL give every `tusage` it runs, the refresher's `--update` included, the account list and the directory rules from its own config in the environment: `TU_ACCOUNTS` as `name=config dir` pairs joined by `;` from `claude.profiles` (an empty directory means the default `~/.claude`), and `TU_ACCOUNT_RULES` as `dir=name` pairs joined by `;` from the `claude.rules` entries that have both a directory and a profile.

#### Scenario: Profiles and rules reach tusage
- **WHEN** the config has profiles `personal` (with a config directory) and `work` (without), and a rule placing a repository directory on `work`
- **THEN** `tusage` sees `TU_ACCOUNTS` starting `personal=<its dir>;work=` and `TU_ACCOUNT_RULES` holding `<repository dir>=work`

#### Scenario: The refresher's update uses the same labels
- **WHEN** the refresher runs `tusage --update`
- **THEN** it passes the same `TU_ACCOUNTS` as the readers, so the account map does not flip between labels on every update

### Requirement: The cost figure on a row
A session's row SHALL show Claude Code's own running cost, recorded by the `claude-statusline` capability, when it is above zero, shown bare. Otherwise it SHALL show the transcript estimate prefixed `~`, followed by `?` when part of the session ran on a model with no rate, which marks the figure as a floor. A session with nothing spent SHALL show no marker.

#### Scenario: An open session
- **WHEN** a session has a recorded ledger cost above zero
- **THEN** the row shows that cost with no `~`

#### Scenario: A closed session
- **WHEN** a session has no ledger cost
- **THEN** the row shows the priced transcript estimate prefixed `~`

#### Scenario: Unpriced requests
- **WHEN** an estimated session has requests on an unrated model
- **THEN** the figure is prefixed `~` and ends with `?`

### Requirement: Subagent share and the five-hour total are estimates
When subagents or workflows account for any of a session's spend, its row SHALL show their dollars as a `~`-less dim `⑂` figure next to the live-subagent count, priced from the transcript, because the ledger gives no breakdown. A project header SHALL show the sum of its sessions' dollars over the last five hours as `/5h`, when it is above zero. Hiding the cost column SHALL remove every dollar figure with it: the column, the subagent share and the `/5h` total.

#### Scenario: A workflow-heavy session
- **WHEN** a session's subagents spent $1.25 by the estimate
- **THEN** its row shows `⑂$1.25` before the detail text

#### Scenario: The cost column is hidden
- **WHEN** the cost column is hidden
- **THEN** no row shows the `⑂` dollars and no header shows `/5h`

### Requirement: The model column
The model column SHALL show the model the session is set to now, taken from the status line's model file, and SHALL fall back to the model that served the newest request that spent anything when no model file exists. The id is shown without the `claude-` prefix and without a dated snapshot suffix, as in `opus4.8`.

#### Scenario: A switched session
- **WHEN** a session was switched to another model and has sent nothing since
- **THEN** the column shows the new model, not the one on the newest transcript request

### Requirement: Previews show the breakdown
The preview of a session SHALL include the per-subagent and per-model breakdown from `tusage --session`, for an open pane's preview and, limited to its first lines, for a closed session still within the index. With usage off the preview SHALL omit it.

#### Scenario: A session inside the index
- **WHEN** a preview is drawn for a session the index knows and usage is on
- **THEN** it includes the lines of `tusage --session <id>`

### Requirement: The month in the status bar
With usage on, the status bar SHALL end with the watched account's month: its badge, then the month-to-date dollars and the limit, then the daily allowance as `/d`, for example `w $400/850`. Dollars are whole numbers from 10 up and have cents below 10. The account's badge is its configured badge or the first letter of its name. Only the watched account SHALL be counted. With no usage data for the month the status text SHALL be empty.

#### Scenario: A month figure
- **WHEN** the watched account has spent $400 of an $850 limit
- **THEN** the status bar contains `w $400/850` and a `/d` allowance

#### Scenario: Rounded to dollars
- **WHEN** the month stands at $807.50
- **THEN** it is printed as `$808/850`

### Requirement: The colour of the month figure
The month figure SHALL be dim while the month is well inside the limit, yellow from 70 percent of the limit or when the pace of spending is above the daily allowance, and red from 90 percent of the limit.

#### Scenario: 70 percent
- **WHEN** the month stands at 70 percent of the limit
- **THEN** the figure is yellow

#### Scenario: 90 percent
- **WHEN** the month stands at 90 percent of the limit
- **THEN** the figure is red

#### Scenario: Well inside the limit
- **WHEN** the month is under budget and its pace is below the allowance
- **THEN** the figure is the dim colour

### Requirement: The daily allowance
The allowance SHALL be the budget left divided by the days left. The budget is the limit reduced by `usage.safety_margin_pct`, less the month so far and never below zero. Days are Monday to Friday, from today to month end, unless `usage.workdays` is `false`, `no`, `0` or `off`, when every calendar day counts. The pace is the month so far divided by the days elapsed, counted the same way. A month whose remaining days are all weekend SHALL fall back to calendar days.

#### Scenario: Working days by default
- **WHEN** `usage.workdays` is unset
- **THEN** the footer ends its allowance with `/day left (Nwd)`, N counting the working days left

#### Scenario: Calendar days
- **WHEN** `usage.workdays: false`
- **THEN** the footer ends it with `/day left (Nd)`, N counting the calendar days left

### Requirement: The footer under the list
Under the list the footer SHALL show the watched account, the month's name, the month so far against the limit, today's spend, the allowance and days left, then any calibration note, then a sparkline of the current month's last seven days. It SHALL be dim, yellow or red by the same rule as the status bar figure. With no usage data it SHALL say `<account> · no usage data`.

#### Scenario: The footer
- **WHEN** the watched account has spent $400 against $850
- **THEN** the footer contains `of $850`, today's dollars and the allowance with its days left

#### Scenario: Nothing yet
- **WHEN** the index holds no row for the month
- **THEN** the footer reads `<account> · no usage data` and the status text is empty

### Requirement: Status text and footer come from one calculation
The status text, the footer and the `$` table's closing line SHALL come from one calculation, so they agree to the cent. The refresher's combined form SHALL be the status text, a `\036` byte and the footer text, and each half SHALL be byte for byte what the status form and the footer form print alone. The combined form SHALL read the date once.

#### Scenario: Splitting the combined form
- **WHEN** the combined output is split at the `\036` byte
- **THEN** the first half equals the status text and the second equals the footer text, for a month with data, with a calibration note, with a meter row and with no data

### Requirement: The `$` table
The `$` key, and `tagents --ask-usage`, SHALL show the month a day per row for the watched account only: a header `usage · <month> · <account>`, then a row per day, newest first, with the day, dollars and requests, a `~` after a day that has requests nothing could be priced from, the footer's summary line and a note explaining the `~`. It SHALL open in a popup with `less` where available and print inline with an any-key close where it is not.

#### Scenario: The table
- **WHEN** `tagents --ask-usage` runs with usage on
- **THEN** the output names the month and the account, has a row for today as the newest, ends with a line containing `of $850`
- **AND** shows nothing for an account that is not watched

#### Scenario: Usage off
- **WHEN** `usage.watch` is unset and the user presses `$`
- **THEN** no window opens and `tagents: usage is off — set usage.watch to the profile to track` is shown

### Requirement: The fetched meter sets the limit and wears a tilde
While the fetched meter reading for the watched account has status `ok` and is less than two days old, the limit on screen SHALL be the limit the meter reports, the month SHALL wear a `~` and the footer SHALL carry `~meter HH:MM` naming the time of the reading. A stale reading, one past two days, and an `error` row SHALL be ignored, and then the configured `usage.monthly_limit_usd` SHALL show with no `~`.

#### Scenario: A fresh reading
- **WHEN** the reading says a limit of 1000 and was taken just now
- **THEN** the status bar shows `w ~$400/1000`
- **AND** the footer carries `~meter` and the reading's time, and `of $1000`

#### Scenario: A stale or failed reading
- **WHEN** the reading is three days old, or its status is `error`
- **THEN** the status bar shows the configured limit and no `~`

### Requirement: A typed meter reading overrides the fetched one
`usage.meter: "YYYY-MM-DD HH:MM = amount"` SHALL scale every figure on screen to that amount as of that time in the current month, and SHALL win over any fetched reading; the month wears a `~` and the footer names `~meter` and the time. A reading from another month, unreadable, or whose ratio to the estimate at that instant is outside 0.5 to 1.5 SHALL be ignored with no `~`, the footer SHALL say `meter reading unusable`, and a fetched reading SHALL NOT take its place.

#### Scenario: A usable reading
- **WHEN** the config says 360 at the end of the 1st, and the estimate then stood at 400
- **THEN** the month is scaled by 0.9 and wears a `~`, and the footer names the reading's time

#### Scenario: A reading from another month
- **WHEN** the reading is dated in an earlier month
- **THEN** the month is unscaled with no `~`, and the footer says `meter reading unusable`

#### Scenario: An implausible ratio
- **WHEN** the reading is three times the estimate at its instant
- **THEN** it is ignored and the footer says `meter reading unusable`

#### Scenario: No reading configured
- **WHEN** `usage.meter` is unset and no fetched reading applies
- **THEN** the footer carries no meter note
