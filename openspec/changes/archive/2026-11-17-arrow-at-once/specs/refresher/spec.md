## MODIFIED Requirements

### Requirement: When a reload is posted
The refresher SHALL post `reload-sync(TA_KEEP_ROWS=1 <tagents> --list)` on its first pass, so that the load keeps the dashboard's rows; on a pass where the tmux snapshot, a file the list reads or the number of state files differs from the last reload; on a slow pass; and on the retry after a reload was refused. On any other pass it SHALL post nothing. A reload due within the minimum interval is held back as the next requirement says.

#### Scenario: A quiet minute
- **WHEN** a refresher runs five passes with no change
- **THEN** exactly one reload was posted, on the first

#### Scenario: A refused reload is repeated
- **WHEN** the reload posted on a pass is refused
- **THEN** it is posted again two seconds later with nothing else changed

### Requirement: The refresher's markers
A refresher SHALL keep five files in the state directory named by its own process id: `.refresher.<pid>` (the time of the last reload), `.cfg` (the last config read), `.start`, and the FIFOs `.evq` and `.nap`, each after `.refresher.<pid>`. At its start it SHALL delete the files named after dead process ids: those five, `.counts.tally.<pid>`, `.counts.out.<pid>` and `.rows.kept.<pid>`; a live process's files stay. It SHALL remove its own when the loop ends.

#### Scenario: A dead refresher left files
- **WHEN** a refresher starts and the directory holds the files of a pid that has exited and those of a live one
- **THEN** the dead pid's files are all gone and the live pid's are kept
- **AND** while it runs it has exactly its own five markers, none named after the port
