# usage-accounting Specification

## Purpose
`tusage` turns Claude Code transcripts into an index of requests and prices them into dollars per request, session, subagent, day and account, calibrated against the account's own meter. This capability is the accounting engine and its command line; the `usage-display` capability covers how tagents shows it.

## Requirements
### Requirement: Each request is counted once
`tusage` SHALL count every API request once, identified by its request id, however many transcript lines carry its usage. It SHALL read only complete lines, leaving a partly written last line for the next update, and SHALL carry the last few ids across updates so a response split across two reads is not counted twice.

#### Scenario: Three records and a subagent record
- **WHEN** a transcript holds three assistant records of 100000 input tokens each on opus-5 and its subagent transcript holds one more
- **THEN** `tusage --sessions` reports $2.00 for that session

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
Updating the index SHALL take a lock, a directory `.update.lock` in the usage state directory. A background update that loses the lock SHALL return quietly and successfully, because the winner reads the same bytes. `tusage --rebuild` SHALL wait for the lock and, if it never gets it, SHALL say that another update is running and that the index was left alone. A lock older than a few minutes SHALL be treated as left by a killed updater and taken over.

#### Scenario: Two updaters collide
- **WHEN** an update starts while another holds the lock
- **THEN** the second returns without reading or appending anything

### Requirement: Updating and rebuilding
`tusage --update` SHALL bring the index up to date and then refresh the meter, and SHALL exit with the index update's status. `tusage --rebuild` SHALL throw the index away and rescan every transcript. Any other invocation SHALL update the index before reporting unless `--no-update` is given. The index SHALL keep 62 days of usage, configurable with `TU_KEEP_DAYS`.

#### Scenario: The totals look wrong
- **WHEN** `tusage --rebuild` runs
- **THEN** the offsets, the facts and the session table are deleted and rebuilt from the transcripts still on disk

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
- **THEN** the window is that long back from now, and `month` means since local midnight on the 1st
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
`tusage --by day|project|session|agent|model|hour|workflow` SHALL print a table of cost units, the largest group first, with requests, cache writes, cache reads, output, the largest context and a share bar, then a total. Cost units are `input + 1.25 × 5m cache write + 2 × 1h cache write + 0.1 × cache read + 5 × output`; they are comparable across models but are not money. With no index it SHALL print `no data yet — run 'tusage --rebuild'` on standard error and exit 1.

#### Scenario: An empty window
- **WHEN** `tusage --by model --since 1m` finds no usage
- **THEN** it prints `no data in this window` on standard error and exits 1

### Requirement: Summary with no arguments
`tusage` with no arguments SHALL print a summary in cost units: the last five hours with the peak context, the last 24 hours, the last seven days, where the seven days went by cache write, cache read and output, the share of requests above 200k of context, the top projects, main sessions against what they spawned, workflow runs, and the heaviest sessions.

#### Scenario: A first run with no index
- **WHEN** `tusage` runs with nothing indexed
- **THEN** it prints `no data yet — run 'tusage --rebuild'` on standard error and exits 1

### Requirement: One session in detail
`tusage --session <id>` SHALL accept a session id or a unique prefix and print the main session and each subagent or workflow agent on its own row with its cost units, dollars, requests and tokens, then a total. When the session used more than one model, or any request was unpriced, it SHALL add a per-model table with its own dollars, mark each unrated model, and warn that the dollar figure is a floor.

#### Scenario: A mid-session model switch
- **WHEN** a session ran part of its requests on one model and part on another
- **THEN** the detail shows two priced model rows

### Requirement: The five-hour burn
`tusage --burn` SHALL print a tmux status fragment, `5h` followed by the dollars spent in the last five hours across all accounts, coloured yellow and then red as the spend grows. It SHALL print nothing when the window holds no usage.

#### Scenario: Nothing in the last five hours
- **WHEN** no request is newer than five hours
- **THEN** `tusage --burn` prints nothing

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
