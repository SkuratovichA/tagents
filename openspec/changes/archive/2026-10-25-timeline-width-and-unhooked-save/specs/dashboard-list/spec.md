## MODIFIED Requirements

### Requirement: The timeline shows who worked when
`tagents --timeline` SHALL print a header line and one line per session whose last activity falls within the last `TA_TIMELINE_HOURS` hours (default 24), oldest start first: the name, the directory (from 100 columns), the start and end time of day, the duration and a bar over the window. A running session SHALL be green and end at `now`. The width SHALL be the terminal's, asked of the controlling terminal, so redirected streams do not shrink it to 80; an exported `COLUMNS` overrides it.

#### Scenario: Running agent
- **WHEN** a session started two hours ago has no end event and is alive
- **THEN** its bar is green and its end reads `now`

#### Scenario: Outside the window
- **WHEN** a session ended before the window began
- **THEN** it has no line

#### Scenario: The width of the terminal
- **WHEN** `tagents --timeline` runs in a terminal 160 columns wide with `COLUMNS` unset, its input from `/dev/null`, its error output discarded and its output piped to another command, where `tput` alone would answer 80
- **THEN** its widest line is wider than 100 columns and the directory column is shown

#### Scenario: COLUMNS overrides
- **WHEN** `COLUMNS=120` is exported
- **THEN** the timeline is drawn for 120 columns whatever the terminal's width; with no terminal and no `COLUMNS` it assumes 100
