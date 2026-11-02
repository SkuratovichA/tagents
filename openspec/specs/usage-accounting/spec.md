# usage-accounting Specification

## Purpose
`tusage` turns Claude Code transcripts into an index of requests and prices them into dollars per request, session, subagent, day and account, calibrated against the account's own meter. This capability is the accounting engine and its command line; the `usage-display` capability covers how tagents shows it.

## Requirements

### Requirement: Each request is counted once
`tusage` SHALL count every API request once, identified by its request id, however many transcript lines carry its usage. It SHALL read only complete lines, leaving a partly written last line for the next update, and SHALL carry the last few ids across updates so a response split across two reads is not counted twice.

#### Scenario: Three records and a subagent record
- **WHEN** a transcript holds three assistant records of 100000 input tokens each on opus-5 and its subagent transcript holds one more
- **THEN** `tusage --sessions` reports $2.00 for that session

#### Scenario: A record still being written
- **WHEN** a transcript's last record has no newline yet
- **THEN** the update does not count it
- **AND** once the newline arrives the next update counts it once

### Requirement: Subagent and workflow transcripts belong to the parent session
A transcript under a session's `subagents` directory, workflow runs included, SHALL be attributed to the parent session id it carries. Its spend SHALL be part of the session's total and also be reported separately as the subagent share, a subset of the total and not an addition to it.

#### Scenario: A subagent request
- **WHEN** a session's subagent transcript holds one 100000-token request on opus-5
- **THEN** the session's dollars include it
- **AND** the session's subagent dollars are that request alone

### Requirement: A transcript is indexed by session, not by path
The index SHALL identify a transcript by its session id, plus the path below the session for a subagent file, and not by absolute path. When Claude Code moves a session's files to another project directory, only the bytes added since the last update SHALL be read, and the offsets table SHALL keep one row per file, under the new path. If both copies are on disk at once, only the newest SHALL be indexed.

#### Scenario: A session is re-homed
- **WHEN** a session's files move from one project directory to another and one more request is appended
- **THEN** the session's dollars rise by that request alone
- **AND** `offsets.tsv` holds the new paths and none of the old, with the session key as its fourth field

#### Scenario: Both copies exist
- **WHEN** `tusage --rebuild` runs while both copies of a session are on disk
- **THEN** it says how many duplicate transcript copies it skipped
- **AND** the session is counted once

### Requirement: One updater at a time
Updating the index SHALL take a lock, a directory `.update.lock` in the usage state directory that holds the updater's process id. A background update that loses the lock SHALL return quietly and successfully, because the winner reads the same bytes. `tusage --rebuild` SHALL wait for the lock and, if it never gets it, SHALL say that another update is running and that the index was left alone.

#### Scenario: Two updaters collide
- **WHEN** an update starts while another holds the lock
- **THEN** the second returns without reading or appending anything

### Requirement: A lock is held while its updater runs
A lock SHALL stay held for as long as the process named in it is a running `tusage`, however old the lock is, and SHALL be taken over at once when that process is gone or is now another program. A lock with no process id in it SHALL be treated as left by a killed updater and taken over once it is older than a few minutes.

#### Scenario: A long catch-up keeps its lock
- **WHEN** an update finds the lock older than five minutes and naming a running `tusage`
- **THEN** it returns without reading or appending anything

#### Scenario: The updater is gone
- **WHEN** the lock names a process that is no longer running, or one that is not a `tusage`
- **THEN** the next update takes the lock over and reads at once

### Requirement: An interrupted update leaves nothing behind
An update interrupted by INT, TERM or HUP SHALL remove its lock, its temporary files and its unfinished stamp, SHALL append nothing to the index, and SHALL exit with the signal's status: 130, 143 or 129.

#### Scenario: Ctrl-C in the middle of a catch-up
- **WHEN** a TERM reaches an update while it is reading
- **THEN** it exits 143, its lock, temporary directory and unfinished stamp are gone, and the index holds nothing it read
- **AND** the next update reads what it did not

### Requirement: Updating and rebuilding
`tusage --update` SHALL bring the index up to date and then refresh the meter, and SHALL exit with the index update's status. `tusage --rebuild` SHALL throw the index away and rescan every transcript. Any other invocation SHALL update the index before reporting unless `--no-update` is given. The index SHALL keep 62 days of usage, configurable with `TU_KEEP_DAYS`.

#### Scenario: The totals look wrong
- **WHEN** `tusage --rebuild` runs
- **THEN** the offsets, the facts and the session table are deleted and rebuilt from the transcripts still on disk

### Requirement: A long update says how far it got
An update whose standard error is a terminal and that has at least 100 transcripts to read, or `TU_PROGRESS_MIN` when that is set, SHALL show `tusage: reading transcripts <n>/<total>` on one line that it rewrites as it reads, and SHALL clear the line when it ends or is interrupted. On anything but a terminal it SHALL print no progress.

#### Scenario: A catch-up on a terminal
- **WHEN** `tusage --update` runs on a terminal with `TU_PROGRESS_MIN=1` and one transcript to read
- **THEN** its output says `reading transcripts 1/1` and the transcript is counted

#### Scenario: An update to a pipe
- **WHEN** `tusage --update` runs with its output on a pipe and nothing to report
- **THEN** it prints nothing

### Requirement: An update with nothing new returns after one look
`tusage --update` SHALL return successfully after one look, without taking the lock or reading or rewriting the index, when no transcript (`*.jsonl`) and no directory in the projects tree, the projects directory included, is newer than the stamp `.stamp` in the usage state directory, which the last completed update wrote. A directory counts because a transcript moved in with an old modification time changes only its directory.

#### Scenario: Nothing was written
- **WHEN** `tusage --update` runs again with no transcript or directory touched since the last update
- **THEN** it exits 0 with no output, and the index files and the stamp are unchanged in bytes and modification time

#### Scenario: A transcript grew in the same second
- **WHEN** one record is appended after the last update within the same second, on a filesystem whose modification times are finer than a second
- **THEN** the next update counts it

#### Scenario: A transcript moved in
- **WHEN** a transcript with an old modification time is moved into the projects directory
- **THEN** the next update counts it, and a deleted transcript also lets the update run

### Requirement: What the one look does not skip
A `--rebuild`, a first run with no stamp or no offsets, and the meter refresh after the update SHALL NOT be skipped by the one look of `tusage --update`.

#### Scenario: A first run
- **WHEN** `tusage --update` runs with no stamp
- **THEN** it reads the transcripts and writes the index

### Requirement: The stamp is taken before the scan and moved into place after it
An update that runs SHALL create its new stamp before it reads anything and move it over `.stamp` only when it has finished, also when it found nothing to read. A transcript written during the scan is then newer than the stamp and is read by the next update, and an update that dies leaves the old stamp. When no directory is newer than the stamp, only transcripts that grew are read.

#### Scenario: A new transcript
- **WHEN** a transcript is created after an update has finished
- **THEN** the next update counts it once, and an update after that changes no total

### Requirement: Every request is priced at the model that served it
`tusage` SHALL price each request at the model recorded on that request and sum the results, so a session that switched models, or fanned work out to subagents on another tier, is priced correctly, and SHALL NOT price a session's total at the model it is on now. Each model has an input and an output rate per million tokens, whatever the context size.

#### Scenario: Rates pinned by tests
- **WHEN** one million input tokens are priced on `claude-opus-5`
- **THEN** the price is $5.00, and one million output tokens cost $25.00
- **AND** one million five-minute cache-write tokens on `claude-sonnet-5` cost $2.50
- **AND** two hundred thousand input tokens, one hundred thousand one-hour cache-write tokens and one million cache-read tokens on `claude-opus-5` cost $2.50 together

### Requirement: Cache tokens are priced from the input rate
Cache writes SHALL cost 1.25 times the input rate for the five-minute kind and 2 times for the one-hour kind. Cache reads SHALL cost 0.1 times the input rate unless the model states a read rate of its own.

#### Scenario: Cache reads
- **WHEN** one million cache-read tokens are priced
- **THEN** `claude-fable-5-1` costs $0.25, `claude-fable-5` costs $1.00 and `claude-opus-5` costs $0.50

### Requirement: Model ids match by the longest prefix
A model id that is not in the price table exactly SHALL be priced by the table entry that is the longest prefix of it, so dated snapshot ids reach the rate of their base model.

#### Scenario: A dated snapshot
- **WHEN** a request ran on `claude-fable-5-1-20260901`
- **THEN** it is priced at the `claude-fable-5-1` rates, not at `claude-fable-5`

### Requirement: A model without a rate is never guessed at
A request on a model with no price SHALL be excluded from the dollars, not priced as free and not priced at another model's rate, and SHALL be counted as unpriced so every surface can say its figure is a floor. A request that spent no tokens, such as the zero-token synthetic placeholder, SHALL NOT be counted as unpriced.

#### Scenario: An unrated model
- **WHEN** a day holds a request of 500000 input and 500000 output tokens on `claude-gizmo-9`
- **THEN** its dollars are 0
- **AND** the `--daily` row for that day and account counts one unpriced request

### Requirement: The price table can be overridden
`TU_PRICES` SHALL replace the built-in price table for one run. Rows are separated by `;` or newlines, each row being `model input-rate output-rate`, optionally followed by a cache-read rate, and then optionally by an introductory `until-epoch input-rate output-rate` applied to usage at or before that instant. Models missing from the override are unpriced.

#### Scenario: A different table
- **WHEN** `TU_PRICES='claude-opus-5 10 50'` is set
- **THEN** one million cache-read tokens on `claude-opus-5` cost $1.00

### Requirement: Dollars per day and account
`tusage --daily` SHALL print one row per local day and per account, sorted by day and then account, with no header and five tab-separated fields: the day as `YYYY-MM-DD`, the account name, the dollars to four decimals, the request count and the unpriced-request count. `--since` SHALL set how far back it goes and `--until <epoch>` SHALL close the window at that instant as well.

#### Scenario: Rows for two days
- **WHEN** an index holds work and personal spend on one day and work spend, with one unrated request, two days later
- **THEN** the output is exactly three rows, for example `<day>`, `personal`, `3.0000`, `2`, `0`
- **AND** the later day's work row shows the sum of its priced requests and `1` unpriced

#### Scenario: Units of --since
- **WHEN** `--since` is given as `5h`, `3d`, `30m`, `month` or a number of seconds
- **THEN** the window is that long back from now, and `month` means since midnight on the 1st of this month at today's UTC offset
- **AND** `1m` is one minute, not one month

### Requirement: Sessions are attributed to accounts through a join
`tusage` SHALL attribute each session to an account by the session lists in each account's config directory `history.jsonl`, and SHALL place any session no history lists, such as a headless run, by the directory it was launched in, using the directory rules. If one session appears in two histories the newest line SHALL win. A session nothing places SHALL print as `?` rather than fall into a default account. A rule SHALL match only on a path-component boundary, the longest match winning.

#### Scenario: History and rules
- **WHEN** one session appears in both histories and another is listed in none but launched under a rule's directory
- **THEN** the first goes to the account whose history line is newer, once
- **AND** the second goes to the account the rule names

#### Scenario: A directory that only looks like a prefix
- **WHEN** a rule covers `~/projects/app` and a session was launched in `~/projects/appx/src`
- **THEN** the session is attributed to `?`

### Requirement: The account map follows its spec
The session-to-account map SHALL be rebuilt whenever the account list or the rules it was built from change, whatever the timestamps say, and also when a history file or the session table is newer than the map. It SHALL be written so that a reader sees it whole or not at all.

#### Scenario: Accounts renamed
- **WHEN** the same histories are read with the accounts named `alpha` and `beta`, and then again under the old names
- **THEN** the first run reports only `alpha` and `beta`, and the second reports `work` and `personal` again

### Requirement: Machine-readable sessions
`tusage --sessions` SHALL print one tab-separated row per session in the window with 14 fields: session id, cost units, requests, context size, last-request time, project slug, subagent cost units, live subagents, cost units in the last five hours, current model, dollars, dollars in the last five hours, subagent dollars and unpriced-request count. Dollars SHALL be at list price, not scaled by any calibration. The model SHALL be the one that served the newest request that spent anything.

#### Scenario: A session row
- **WHEN** a session holds a $5.00 and a $25.00 request on opus-5, and a calibration factor is stored for its account
- **THEN** its row has 14 fields and its dollars field is `30.000000`

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

### Requirement: A total of nothing is a share of 0%
A report SHALL give a share of a total of zero as 0% rather than fail. When the seven days of the summary hold no usage, its breakdown SHALL say `nothing in the last 7 days` and `tusage` SHALL exit 0.

#### Scenario: An empty week
- **WHEN** the newest indexed request is ten days old
- **THEN** `tusage` exits 0 and says `nothing in the last 7 days`

#### Scenario: A window of zero-token requests
- **WHEN** the only request in the window is a zero-token `<synthetic>` placeholder
- **THEN** `tusage --by model` prints it at a share of 0.0% and exits 0

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

### Requirement: JSON output
`tusage --json` SHALL print the window as a JSON array of objects with `project`, `session`, `who` (`main` or the agent type), `cost` in cost units and `requests`. With no index it SHALL print `{"error":"no data"}` and exit 1.

#### Scenario: No index
- **WHEN** `tusage --json` runs with nothing indexed
- **THEN** it prints `{"error":"no data"}` and exits 1

### Requirement: Command line errors
`tusage --help` SHALL print the header of the tool and exit 0. An unknown option SHALL print `tusage: unknown option <option>` on standard error and exit 2. Without `jq` `tusage` SHALL print that `jq` is required and exit 1.

#### Scenario: An unknown option
- **WHEN** `tusage --nonsense` runs
- **THEN** it exits 2 with `tusage: unknown option --nonsense` on standard error

### Requirement: Calibration to a meter reading
`tusage --calibrate <account> <amount> [--at <YYYY-MM-DD HH:MM or epoch>]` SHALL divide the amount by the account's month-to-date at list price as of that instant (now by default), store the ratio for the account in `factor.tsv`, and print the factor, for example `x0.5000`. From then on `--daily` SHALL report dollars scaled by the factor, while `--sessions` and `--burn` stay at list price. `TU_NO_FACTOR=1` SHALL switch the scaling off for one call.

#### Scenario: Half of list
- **WHEN** an account's month is $32.50 at list and `--calibrate work 16.25` runs
- **THEN** it exits 0 and says `x0.5000`
- **AND** `--daily` totals $16.25 for that account and leaves other accounts alone
- **AND** with `TU_NO_FACTOR=1` the total is $32.50 again

#### Scenario: A reading from earlier
- **WHEN** the reading is given with `--at` one second before the newest row
- **THEN** only the usage up to that instant is divided into it

### Requirement: Calibration refuses what is not a price
`--calibrate` SHALL refuse a ratio too far from 1 to be a price, saying so and exiting 1 and keeping the previous factor. It SHALL exit 2 with a usage message when the account or amount is missing, exit 2 when the amount is not a number or the time cannot be read, and exit 1 when nothing is indexed for the account in the month up to that instant.

#### Scenario: An absurd reading
- **WHEN** `--calibrate work 500` is run against a month of $32.50
- **THEN** it exits 1 and says the factor is `not a price`
- **AND** the stored factor is unchanged

### Requirement: A factor is only valid for the table it came from
Each stored factor SHALL carry a fingerprint of the price table it was derived against, and a factor whose fingerprint does not match the table in use SHALL be ignored, so correcting a rate never leaves an old correction on top of the new prices.

#### Scenario: Another price table
- **WHEN** a factor of 0.5 was stored under the default table and `--daily` runs with `TU_PRICES` set to a different table
- **THEN** the dollars equal the unscaled dollars under the new table
- **AND** under the original table the factor applies again

### Requirement: The account's own meter
`tusage --meter` SHALL print the stored readings, one row per account with the used amount, the limit, the time fetched and the status; `--refresh` SHALL first fetch the readings that are due and `--force` every reading regardless of schedule. A fetch SHALL be one authenticated GET of the account's usage, with the OAuth token Claude Code keeps in the keychain, giving month-to-date spend and limit as minor units scaled by an exponent. With no readings it SHALL exit 1.

#### Scenario: A reading
- **WHEN** the API answers with 83016 used and 100000 as the limit, both with exponent 2, for the default account
- **THEN** `meter.tsv` holds `830.16` and `1000.00` for the account with status `ok`
- **AND** exactly one request was made for one account

### Requirement: Which accounts have a meter
Only the default config directory's account SHALL be read by default, because Claude Code keeps one keychain item and it belongs to the default directory. Another account SHALL be read only when `TU_METER_ITEMS` names its keychain item, as `account=item` pairs joined by `;`. An account with no known item SHALL be marked `nometer` and left alone for a day.

#### Scenario: A login whose credentials are unknown
- **WHEN** an account has no keychain item and none is named in `TU_METER_ITEMS`
- **THEN** its row has status `nometer`
- **AND** `--meter` prints a note that this login reports no spend meter

### Requirement: The token never leaves the process
The OAuth token SHALL be read into a variable, handed to the request as a header and dropped. It SHALL NOT be printed, logged or written to any file, `meter.tsv` included.

#### Scenario: After a fetch
- **WHEN** a meter fetch has completed
- **THEN** the request carried `Authorization: Bearer <token>`
- **AND** no file under the usage state directory contains the token

### Requirement: When the meter is asked again
A stored reading SHALL be refetched only when it is due. The schedule is `TU_METER_TTL` seconds, 900 by default, and 300 once the account is at or past 90 percent of its limit unless a shorter TTL was asked for. An explicit `TU_METER_TTL` SHALL apply to the reading already taken, not only to the next one. A failed fetch SHALL be retried after five minutes, and an account that answers without a spend object after a day.

#### Scenario: Inside the TTL
- **WHEN** `--meter --refresh` runs again before the reading is due
- **THEN** no request is made

#### Scenario: A zero TTL
- **WHEN** `TU_METER_TTL=0` and `--meter --refresh` runs
- **THEN** the account is fetched again

### Requirement: A failed or empty answer
A failed fetch SHALL write an `error` row that keeps the figures of the reading before it when that reading was good (a second failure in a row has no good reading to keep), and `--meter` SHALL note that the last fetch failed and that the figures shown are from the reading before it. An answer with no spend object, as a plan seat gives, SHALL be recorded as `nometer`, SHALL leave the stored factor alone and SHALL be noted as such.

#### Scenario: A server error
- **WHEN** the API answers 500
- **THEN** the row has status `error` with the earlier used amount and limit
- **AND** the output says `the last fetch failed`
- **AND** exactly one request was made

#### Scenario: A plan seat
- **WHEN** the answer has no spend object
- **THEN** the row has status `nometer` and the factor is unchanged

### Requirement: A reading re-prices the account
Each good meter reading SHALL be applied as a calibration for its account, so `--daily` and the sparkline agree with the meter. When the ratio is not a plausible price the reading SHALL stay as read, the old factor SHALL be kept and a `not a price` note SHALL be printed.

#### Scenario: A usable reading
- **WHEN** a reading of $26.00 arrives against a month of $32.50 at list
- **THEN** the account's factor becomes `0.8000`
- **AND** the meter row holds `26.00`

#### Scenario: An implausible reading
- **WHEN** a reading of $830.16 arrives against $32.50 at list
- **THEN** the row is still `ok` and holds `830.16`
- **AND** the previous factor is kept, and the output says `not a price`

### Requirement: The meter can be turned off
With `TU_NO_METER=1` `tusage --update` and `--meter` SHALL make no request and read no keychain, so a test or an offline run never reaches the network.

#### Scenario: Update with the meter off
- **WHEN** `TU_NO_METER=1 tusage --update` runs
- **THEN** no request is made

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
`--since` SHALL accept a duration (`30m`, `5h`, `3d`, or seconds, counted back from now), `month` or a date `YYYY-MM-DD`, and `--until` an epoch in seconds or a date. A date starts the `--since` window at its midnight and ends the `--until` window at the end of that day, and `month` starts it at the midnight of the 1st of this month, all at today's UTC offset. A value that is none of those SHALL exit 2 with `tusage: bad --since value <value>`, or `--until` for that flag.

#### Scenario: Two days
- **WHEN** `tusage --by day --since 2026-10-28 --until 2026-10-29` runs
- **THEN** the rows are the two days 2026-10-28 and 2026-10-29, both whole

#### Scenario: The offset rows are bucketed by
- **WHEN** a window names days in a zone whose offset changed since an earlier day of the window
- **THEN** the window starts and ends at the midnights the rows are placed in a day by, today's UTC offset, so no row of a named day falls outside it

#### Scenario: The start of the month
- **WHEN** `tusage --by day --since month` runs in a zone whose offset changed since the 1st
- **THEN** the window starts at the midnight of the 1st at today's UTC offset, so a row is in the month when its day, by that offset, is in it

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
`--project <text>` SHALL keep only the rows whose project path contains the text, ignoring case, and may be repeated, a row matching any of them. The path is matched as the tables show it, the home directory as `~`; a text that starts with a slash is matched against the path written out in full too, so a text a shell has expanded matches. A comma is part of the text. It SHALL apply to the reports `--account` applies to, and with both only the rows that match both stay.

#### Scenario: A project and an account
- **WHEN** `tusage --by session --account work --project billing` runs
- **THEN** the sessions are the work account's sessions in projects whose path contains `billing`

#### Scenario: A path a shell expanded
- **WHEN** `tusage --by session --project /Users/me/git/work/billing-api` runs and `~/git/work/billing-api` is the directory of a project
- **THEN** the sessions are those of that project, as with `--project '~/git/work/billing-api'`

#### Scenario: A word that is only in the home directory
- **WHEN** `tusage --by session --project users` runs, the home directory is `/Users/me` and no project's path as the tables show it contains `users`
- **THEN** no session is kept, although every full path holds `users`

### Requirement: Sessions are named
A report that prints a session for a person SHALL name it by the name typed for it in tagents, the first line for its id in `labels.tsv` of the state directory, else by the title of its transcript, else by the first eight characters of its id, and SHALL print those eight characters after a name so the id can be copied. Control characters, tabs included, are removed from a name. `--sessions`, `--json`, `--daily`, `--tsv` and the heading of `--session <id>` print ids.

#### Scenario: A typed name
- **WHEN** `labels.tsv` holds the name `refactor-billing` for a session and `tusage --by session` lists it
- **THEN** its row reads `refactor-billing  3f9a1c20`

#### Scenario: A title and no name
- **WHEN** a session has no typed name and its transcript holds the title `Add invoice export`
- **THEN** its row reads `Add invoice export  c04d7be1`

#### Scenario: Neither
- **WHEN** a session has no typed name and no title
- **THEN** its row shows only `e5d1f0a7`

#### Scenario: A control character in a name
- **WHEN** a name holds an escape sequence, as `typed<ESC>[2Jlabel`, and `tusage --by session` lists the session
- **THEN** the row reads `typed[2Jlabel`, and no control character reaches the terminal

### Requirement: The session lookup
`--session <x>` SHALL find a session by its full id, else a unique id prefix, else a name, matched whole and ignoring case, else as part of a name, whatever characters the text holds. A name is a typed name or a title in the title cache. More than one match SHALL list each candidate's id, name, account and days on standard error and exit 3. No match SHALL exit 1 with `tusage: no session called <x>`, except a whole id (8-4-4-4-12 hexadecimal digits), which keeps its empty detail and exit 0.

#### Scenario: Two sessions called tagents
- **WHEN** `tusage --session tagents` runs and two sessions have names that contain it
- **THEN** it exits 3 and lists both with their ids on standard error

#### Scenario: No such session
- **WHEN** `tusage --session nothing-like-it` runs
- **THEN** it exits 1 with `tusage: no session called nothing-like-it`

#### Scenario: A name made of hexadecimal digits
- **WHEN** a session is named `feed`, no session id starts with `feed`, and `tusage --session feed` runs
- **THEN** it prints that session's detail

#### Scenario: The start of an id that nothing has
- **WHEN** `tusage --session deadbeef` runs and no id starts with it and no name holds it
- **THEN** it exits 1 with `tusage: no session called deadbeef`

#### Scenario: An id that aged out of the index
- **WHEN** `tusage --session <a whole id the index lacks>` runs
- **THEN** it prints the heading and `(no usage recorded in the retained window)`, exits 0 and looks up no name

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
A `--by` table SHALL be as wide as `COLUMNS` when that is a number, else the terminal when standard output is one and the tagents modules are beside `tusage`, else 120. When its columns leave less than 24 characters for the label it SHALL drop `models`, `span`, `days`, `input`, `cache write`, `cache read`, `output` and `requests` in that order. `--compact` SHALL keep only the label, total tokens, dollars and share. A label that does not fit ends in `…`; a session keeps its eight id characters.

#### Scenario: Eighty columns
- **WHEN** `COLUMNS=80 tusage --by account` runs
- **THEN** no line is longer than 80 characters and the dollars and share columns stay

#### Scenario: Compact
- **WHEN** `tusage --by account --compact` runs
- **THEN** each row has only its label, total tokens, dollars and share

#### Scenario: No modules beside tusage
- **WHEN** `tusage --by account` runs in a 70-column terminal with `COLUMNS` unset, from a copy with no tagents modules beside it
- **THEN** the table is laid out for 120 columns

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
`--sessions`, `--daily`, `--burn`, `--json` and `tusage --session <id>` without a report option SHALL print the bytes and keep the field order they print without the new options, SHALL NOT resolve names, and SHALL join sessions to accounts only where they do or `--account` asks. A new figure for machines SHALL be a new flag or a field appended after the last one.

#### Scenario: Fourteen fields
- **WHEN** `tusage --sessions` runs after `labels.tsv` and transcript titles exist
- **THEN** each row has the same 14 fields as without them, and no title cache is written

### Requirement: Reports read the index
A report SHALL be computed from the index and SHALL NOT scan transcripts for usage. To name a session it prints, a report MAY read the first lines of that session's transcript once and remember the title in the title cache that the dashboard reads, and it SHALL read no transcript of a session it does not print.

#### Scenario: A title read once
- **WHEN** `tusage --by session` prints a session whose transcript carries a title and whose title is not cached
- **THEN** the title appears and the title cache holds a row for that session
