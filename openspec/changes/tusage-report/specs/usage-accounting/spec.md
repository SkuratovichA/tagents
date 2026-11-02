## MODIFIED Requirements

### Requirement: Cost units and the breakdown reports
`tusage --by <dimensions>` SHALL print the window's spend grouped by the comma-separated dimensions, then a total. The dimensions are `account`, `project`, `session`, `day`, `week`, `month`, `hour`, `agent`, `model` and `workflow`, and a report that names `workflow` covers only workflow agents. With no index it SHALL print `no data yet — run 'tusage --rebuild'` on standard error and exit 1.

#### Scenario: An empty window
- **WHEN** `tusage --by model --since 1m` finds no usage
- **THEN** it prints `no data in this window` on standard error and exits 1

#### Scenario: One dimension
- **WHEN** `tusage --by project` runs on an index with usage in two projects
- **THEN** it prints one row per project, the costlier first, and a total row

### Requirement: Summary with no arguments
`tusage` with no arguments SHALL print a summary in cost units, with dollars beside the last five hours, 24 hours and seven days: where the seven days went by cache write, cache read and output, the share of requests above 200k of context, the top projects, main sessions against what they spawned, workflow runs, and the heaviest sessions by name and short id. When more than one account has usage in the seven days it SHALL add the seven days by account in dollars.

#### Scenario: A first run with no index
- **WHEN** `tusage` runs with nothing indexed
- **THEN** it prints `no data yet — run 'tusage --rebuild'` on standard error and exits 1

#### Scenario: Two accounts in the week
- **WHEN** both `work` and `personal` have usage in the last seven days
- **THEN** the summary has a block that lists each account with its dollars and share

#### Scenario: A model with no rate
- **WHEN** a request in the last 24 hours ran on a model with no published rate
- **THEN** the dollars of each window that holds it end in `*`, and a note says the figure is a floor

### Requirement: One session in detail
`tusage --session <session>` SHALL find the session as the session lookup says and print the main session and each subagent or workflow agent on its own row with its cost units, dollars, requests and tokens, then a total. When the session used more than one model, or any request was unpriced, it SHALL add a per-model table with its own dollars, mark each unrated model, and warn that the dollar figure is a floor.

#### Scenario: A mid-session model switch
- **WHEN** a session ran part of its requests on one model and part on another
- **THEN** the detail shows two priced model rows

#### Scenario: A session picked by its name
- **WHEN** `tusage --session refactor-billing` runs and one session is named so
- **THEN** it prints the detail of that session, headed by its full id

### Requirement: The five-hour burn
`tusage --burn` SHALL print a tmux status fragment, `5h` followed by the dollars spent in the last five hours across all accounts, or across the accounts `--account` names, coloured yellow and then red as the spend grows. It SHALL print nothing when the window holds no usage.

#### Scenario: Nothing in the last five hours
- **WHEN** no request is newer than five hours
- **THEN** `tusage --burn` prints nothing

#### Scenario: One account
- **WHEN** `tusage --burn --account personal` runs and only `work` spent in the last five hours
- **THEN** it prints nothing

## ADDED Requirements

### Requirement: Cost units
Cost units SHALL be `input + 1.25 × 5m cache write + 2 × 1h cache write + 0.1 × cache read + 5 × output`. They are comparable across models but are not money. The summary, `--sessions` and `--json` report them, and `--by` reports dollars.

#### Scenario: One request of each kind
- **WHEN** a request holds 1M input, 1M 5m cache write, 1M cache read and 1M output tokens
- **THEN** its cost is 7.35M units

### Requirement: Dimensions nest
`--by` SHALL take one to three different dimensions. With more than one, the first groups the rows, each next one splits a group beneath it, indented two spaces, and a group row SHALL be the sum of the rows beneath it. Rows are sorted by dollars, largest first, except the time dimensions. A repeated dimension, a fourth dimension or an unknown one SHALL exit 2 and the message SHALL list the dimensions.

#### Scenario: Account, project, session
- **WHEN** `tusage --by account,project,session` runs
- **THEN** an account row is followed by its projects and each project by its sessions
- **AND** the dollars of an account row equal the sum of its project rows

#### Scenario: An unknown dimension
- **WHEN** `tusage --by colour` runs
- **THEN** it exits 2 with `tusage: unknown dimension colour` and the valid dimensions on standard error

#### Scenario: Four dimensions
- **WHEN** `tusage --by account,project,session,model` runs
- **THEN** it exits 2 and says that three is the most

### Requirement: Weeks and months
The dimension `week` SHALL group days into calendar weeks that start on Monday, labelled `wk <YYYY-MM-DD>` with the Monday's date, and `month` SHALL group them into calendar months labelled `YYYY-MM`. Time dimensions list the oldest first, and `--sort cost` lists them by dollars. When `--by` names `week` or `month` and `--since` is absent, the window SHALL reach back as far as the index does, not seven days.

#### Scenario: A Sunday
- **WHEN** usage was spent on Sunday 2026-11-01
- **THEN** `tusage --by week` puts it in the row `wk 2026-10-26`

#### Scenario: Two months
- **WHEN** usage was spent on 2026-10-31 and on 2026-11-01
- **THEN** `tusage --by month` prints the rows `2026-10` and `2026-11`

### Requirement: Every row shows the same figures
Every row of a `--by` table SHALL show requests, input, output, cache write, cache read and total tokens, the dollars at list price and the row's share of the report's dollars. Cache write is the 5-minute and 1-hour writes together and total tokens is the sum of the four token columns. Dollars of a row with an unrated request SHALL end in `*`, and the report SHALL say they are a floor.

#### Scenario: A row adds up
- **WHEN** a row holds 100k input, 50k output, 200k cache write and 1M cache read tokens
- **THEN** its total tokens are 1,350,000, which the table prints as `1.4M`

#### Scenario: An unrated model
- **WHEN** a session ran one request on a model with no published rate
- **THEN** its dollars end in `*` and the report says the figure is a floor

### Requirement: Dollars are at list price
`--by` dollars SHALL be at list price from the price table, never scaled by a calibration factor. When a factor is stored for an account that appears in the table, the report SHALL end with a line that says so and names `tusage --daily` as the report that applies it.

#### Scenario: A stored factor
- **WHEN** a factor of 0.8 is stored for `work` and `tusage --by account` lists it
- **THEN** its dollars are the list-price sum and the last line says `tusage --daily` scales them

### Requirement: Per-model rows
`--breakdown` SHALL add one row per model under every row of the deepest dimension, indented one level further and with the same figures. It SHALL change nothing when `model` is already a dimension, and the model rows do not count towards the limit of three dimensions.

#### Scenario: Models under projects
- **WHEN** `tusage --by project --breakdown` runs and a project used two models
- **THEN** that project row is followed by two model rows whose dollars add up to its own

### Requirement: Top rows and the rest
Under each parent `--by` SHALL show the twelve largest rows of a non-time dimension and one row `… N more` that sums the others, unless `--top <N>` sets another number or `--top 0` shows all. The time dimensions, `model` and the model rows `--breakdown` adds SHALL never be cut. `--sort cost` lists every level by dollars, largest first. A `--top` or `--sort` value that is not a number or `cost` SHALL exit 2.

#### Scenario: Cutting to three
- **WHEN** `tusage --by session --top 3` runs with five sessions in the window
- **THEN** it prints the three largest and a row `… 2 more` with the other two summed

#### Scenario: A day is never left out
- **WHEN** `tusage --by day --top 2` runs with five days in the window
- **THEN** it prints all five days and no `… N more` row, since a day left out is a hole in the window

### Requirement: Dates in the window
`--since` SHALL accept a duration (`30m`, `5h`, `3d`, or seconds, counted back from now), `month` or a date `YYYY-MM-DD`, and `--until` an epoch in seconds or a date. A date starts the `--since` window at its midnight and ends the `--until` window at the end of that day, both at today's UTC offset. A value that is none of those SHALL exit 2 with `tusage: bad --since value <value>`, or `--until` for that flag.

#### Scenario: Two days
- **WHEN** `tusage --by day --since 2026-10-28 --until 2026-10-29` runs
- **THEN** the rows are the two days 2026-10-28 and 2026-10-29, both whole

#### Scenario: The offset rows are bucketed by
- **WHEN** a window names days in a zone whose offset changed since an earlier day of the window
- **THEN** the window starts and ends at the midnights the rows are placed in a day by, today's UTC offset, so no row of a named day falls outside it

#### Scenario: A date that does not exist
- **WHEN** `tusage --by day --since 2026-02-30` runs
- **THEN** it exits 2 with `tusage: bad --since value 2026-02-30`

### Requirement: The account filter
`--account <name>` SHALL narrow `--by`, the summary, `--sessions`, `--daily`, `--burn`, `--json` and the session lookup to the sessions of the named accounts, and may be repeated or take a comma list. The name `?` stands for the sessions no account claims. A filtered report SHALL have the fields and the order it has unfiltered. An unknown name SHALL exit 2 and list the known accounts on standard error.

#### Scenario: One account of two
- **WHEN** `tusage --sessions --account work` runs and the window holds work and personal sessions
- **THEN** it prints only the work sessions, each with 14 fields

#### Scenario: An unknown account
- **WHEN** `tusage --by day --account nobody` runs
- **THEN** it exits 2 with `tusage: unknown account nobody` and the known names on standard error

### Requirement: Sessions no account claims
In a `--by` table a session no account claims SHALL be the account `? unplaced`, never inside another account. When `account` is a dimension, the report SHALL end with a line that counts the unplaced sessions and says that `TU_ACCOUNT_RULES` places a session by the directory it started in. In `--tsv` and `--daily` such an account is `?`.

#### Scenario: A headless run
- **WHEN** one session is listed in no history and no rule covers its directory
- **THEN** `tusage --by account` has a row `? unplaced` and the closing line counts one session

### Requirement: Account names in a terminal
When `TU_ACCOUNTS` is unset, `tusage` SHALL take the accounts from the tagents config, so a report typed in a terminal names them as the dashboard does. With no config, or a config that names no accounts, it SHALL discover the default account and every `~/.claude-*` directory that keeps a history. `TU_ACCOUNTS` set by hand SHALL win and the config SHALL NOT be read. `TU_ACCOUNT_RULES` set by hand SHALL win over the rules of the config.

#### Scenario: A config names the accounts
- **WHEN** `TA_CONFIG` names a config with profiles `work` and `personal`, `TU_ACCOUNTS` is unset and `tusage --by account` runs
- **THEN** the rows are `work` and `personal`, and no account is named after a `~/.claude-*` directory or as `default`

#### Scenario: No config
- **WHEN** no config file exists and `~/.claude-extra` holds a `history.jsonl`
- **THEN** `tusage --by account` names the accounts `default` and `extra`

#### Scenario: A config with no profiles
- **WHEN** the config has no `claude.profiles` table
- **THEN** the accounts are the discovered ones, exactly as with no config

#### Scenario: TU_ACCOUNTS wins
- **WHEN** `TU_ACCOUNTS` is `a=/path/a` and a config with profiles `work` and `personal` exists
- **THEN** the only account is `a`

### Requirement: The project filter
`--project <text>` SHALL keep only the rows whose project path contains the text, ignoring case, and may be repeated, a row matching any of them. The path is matched as the tables show it (the home directory as `~`) and written out in full, so a text a shell has expanded matches too. A comma is part of the text. It SHALL apply to the reports `--account` applies to, and with both only the rows that match both stay.

#### Scenario: A project and an account
- **WHEN** `tusage --by session --account work --project billing` runs
- **THEN** the sessions are the work account's sessions in projects whose path contains `billing`

#### Scenario: A path a shell expanded
- **WHEN** `tusage --by session --project /Users/me/git/work/billing-api` runs and `~/git/work/billing-api` is the directory of a project
- **THEN** the sessions are those of that project, as with `--project '~/git/work/billing-api'`

### Requirement: Sessions are named
A report that prints a session for a person SHALL name it by the name typed for it in tagents, the first line for its id in `labels.tsv` of the state directory, else by the title of its transcript, else by the first eight characters of its id, and SHALL print those eight characters after a name so the id can be copied. `--sessions`, `--json`, `--daily`, `--tsv` and the heading of `--session <id>` print ids.

#### Scenario: A typed name
- **WHEN** `labels.tsv` holds the name `refactor-billing` for a session and `tusage --by session` lists it
- **THEN** its row reads `refactor-billing  3f9a1c20`

#### Scenario: A title and no name
- **WHEN** a session has no typed name and its transcript holds the title `Add invoice export`
- **THEN** its row reads `Add invoice export  c04d7be1`

#### Scenario: Neither
- **WHEN** a session has no typed name and no title
- **THEN** its row shows only `e5d1f0a7`

### Requirement: The session lookup
`--session <x>` SHALL find a session by its full id, else by a unique id prefix, else by a name, matched whole and ignoring case, else as part of a name. A name is a typed name or a title already in the title cache. More than one match SHALL list each candidate's id, name, account and days on standard error and exit 3. No match SHALL exit 1 with `tusage: no session called <x>`, except an id-shaped value, which keeps its empty detail and exit 0.

#### Scenario: Two sessions called tagents
- **WHEN** `tusage --session tagents` runs and two sessions have names that contain it
- **THEN** it exits 3 and lists both with their ids on standard error

#### Scenario: No such session
- **WHEN** `tusage --session nothing-like-it` runs
- **THEN** it exits 1 with `tusage: no session called nothing-like-it`

### Requirement: One session by day
`tusage --session <session> --by <dimensions>` SHALL print the table of those dimensions for that session alone, under a heading with its name, full id, account and directory. With no `--since` the window SHALL reach back as far as the index does. `--by day` gives one row per day with the figures of every `--by` table, and `--by day,model` adds the models beneath each day.

#### Scenario: Three days
- **WHEN** a session was active on three days and `tusage --session <id> --by day` runs
- **THEN** the table has three day rows and a total, and the heading names the session

### Requirement: Days, span and models
A `--by` table with no time dimension SHALL add to every row `days`, the number of local days with usage, and `span`, the first and last of them as `MM-DD..MM-DD`, or `MM-DD` for one day. A table with no model rows SHALL add `models`, the two costliest models of the row and `+N` for more. The total row counts the days of the whole window.

#### Scenario: A session on three days
- **WHEN** a session had usage on 10-29, 10-31 and 11-01
- **THEN** its row shows `3` days and the span `10-29..11-01`

### Requirement: The table fits the terminal
A `--by` table SHALL be as wide as `COLUMNS` when that is a number, else the terminal when standard output is one, else 120. When its columns leave less than 24 characters for the label it SHALL drop `models`, `span`, `days`, `input`, `cache write`, `cache read`, `output` and `requests` in that order. `--compact` SHALL keep only the label, total tokens, dollars and share. A label that still does not fit ends in `…`, and a session keeps its eight id characters.

#### Scenario: Eighty columns
- **WHEN** `COLUMNS=80 tusage --by account` runs
- **THEN** no line is longer than 80 characters and the dollars and share columns stay

#### Scenario: Compact
- **WHEN** `tusage --by account --compact` runs
- **THEN** each row has only its label, total tokens, dollars and share

### Requirement: Colour only where it helps
A `--by` table SHALL use colour only when standard output is a terminal, `NO_COLOR` is unset or empty and `TERM` is not `dumb`. `--color always` SHALL force it, even over `NO_COLOR`, and `--color never` SHALL remove it. A `--color` value other than `auto`, `always` or `never` SHALL exit 2. The summary and `--session <id>` keep the colour they have.

#### Scenario: A pipe
- **WHEN** `tusage --by account | cat` runs
- **THEN** the output holds no escape sequence

#### Scenario: Forced
- **WHEN** `NO_COLOR=1 tusage --by account --color always` runs
- **THEN** the output holds escape sequences

### Requirement: A breakdown for machines
`tusage --by <dimensions> --tsv` SHALL print one row per row of the deepest dimension, with no header, no colour, no rounding and no top cut: a field per dimension, then requests, input, output, cache write, cache read, dollars to six decimals, unpriced requests, first day, last day and days. A session is its full id and an unplaced account is `?`. With `--breakdown` the model is a further dimension field.

#### Scenario: Account and project rows
- **WHEN** `tusage --by account,project --tsv` runs
- **THEN** each row has the account, the project and ten figures, 12 tab-separated fields

### Requirement: What the new options leave alone
`--sessions`, `--daily`, `--burn`, `--json` and `tusage --session <id>` without a report option SHALL print the bytes and keep the field order they print without the new options, SHALL NOT resolve names (a `--session` text of hex digits and dashes is looked up as an id and never as a name), and SHALL join sessions to accounts only where they do or `--account` asks. A new figure for machines SHALL be a new flag or a field appended after the last one.

#### Scenario: Fourteen fields
- **WHEN** `tusage --sessions` runs after `labels.tsv` and transcript titles exist
- **THEN** each row has the same 14 fields as without them, and no title cache is written

#### Scenario: An id that aged out of the index
- **WHEN** `tusage --session <a full id the index lacks>` runs
- **THEN** it prints the empty detail, exits 0 as before, and looks up no name

### Requirement: Reports read the index
A report SHALL be computed from the index and SHALL NOT scan transcripts for usage. To name a session it prints, a report MAY read the first lines of that session's transcript once and remember the title in the title cache that the dashboard reads, and it SHALL read no transcript of a session it does not print.

#### Scenario: A title read once
- **WHEN** `tusage --by session` prints a session whose transcript carries a title and whose title is not cached
- **THEN** the title appears and the title cache holds a row for that session
