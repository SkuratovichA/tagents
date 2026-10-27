## MODIFIED Requirements

### Requirement: Each request is counted once
`tusage` SHALL count every API request once, identified by its request id, however many transcript lines carry its usage. It SHALL read only complete lines, leaving a partly written last line for the next update, and SHALL carry the last few ids across updates so a response split across two reads is not counted twice.

#### Scenario: Three records and a subagent record
- **WHEN** a transcript holds three assistant records of 100000 input tokens each on opus-5 and its subagent transcript holds one more
- **THEN** `tusage --sessions` reports $2.00 for that session

#### Scenario: A record still being written
- **WHEN** a transcript's last record has no newline yet
- **THEN** the update does not count it
- **AND** once the newline arrives the next update counts it once

### Requirement: One updater at a time
Updating the index SHALL take a lock, a directory `.update.lock` in the usage state directory that holds the updater's process id. A background update that loses the lock SHALL return quietly and successfully, because the winner reads the same bytes. `tusage --rebuild` SHALL wait for the lock and, if it never gets it, SHALL say that another update is running and that the index was left alone.

#### Scenario: Two updaters collide
- **WHEN** an update starts while another holds the lock
- **THEN** the second returns without reading or appending anything

## ADDED Requirements

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

### Requirement: A long update says how far it got
An update whose standard error is a terminal and that has at least 100 transcripts to read, or `TU_PROGRESS_MIN` when that is set, SHALL show `tusage: reading transcripts <n>/<total>` on one line that it rewrites as it reads, and SHALL clear the line when it ends or is interrupted. On anything but a terminal it SHALL print no progress.

#### Scenario: A catch-up on a terminal
- **WHEN** `tusage --update` runs on a terminal with `TU_PROGRESS_MIN=1` and one transcript to read
- **THEN** its output says `reading transcripts 1/1` and the transcript is counted

#### Scenario: An update to a pipe
- **WHEN** `tusage --update` runs with its output on a pipe and nothing to report
- **THEN** it prints nothing

### Requirement: A total of nothing is a share of 0%
A report SHALL give a share of a total of zero as 0% rather than fail. When the seven days of the summary hold no usage, its breakdown SHALL say `nothing in the last 7 days` and `tusage` SHALL exit 0.

#### Scenario: An empty week
- **WHEN** the newest indexed request is ten days old
- **THEN** `tusage` exits 0 and says `nothing in the last 7 days`

#### Scenario: A window of zero-token requests
- **WHEN** the only request in the window is a zero-token `<synthetic>` placeholder
- **THEN** `tusage --by model` prints it at a share of 0.0% and exits 0
