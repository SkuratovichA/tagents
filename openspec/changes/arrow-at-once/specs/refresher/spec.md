## MODIFIED Requirements

### Requirement: When a reload is posted
The refresher SHALL post `reload-sync(TA_KEEP_ROWS=1 <tagents> --list)` on its first pass, so that the load keeps the dashboard's rows; on a pass where the tmux snapshot, a file the list reads or the number of state files differs from the last reload; on a slow pass; and on the retry after a reload was refused. On any other pass it SHALL post nothing. A reload due within the minimum interval is held back as the next requirement says.

#### Scenario: A quiet minute
- **WHEN** a refresher runs five passes with no change
- **THEN** exactly one reload was posted, on the first

#### Scenario: A refused reload is repeated
- **WHEN** the reload posted on a pass is refused
- **THEN** it is posted again two seconds later with nothing else changed
