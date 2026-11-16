## RENAMED Requirements

- FROM: `### Requirement: Each state has its own glyph, label and colour`
- TO: `### Requirement: Each state has its own glyph and colour`

## MODIFIED Requirements

### Requirement: Each state has its own glyph and colour
The list SHALL draw states as follows: `⚠` blocked in bold yellow, `✓` idle in cyan, `●` working in green, `○` new in grey, `·` in grey for a running Claude with no hook event yet, and `✗` closed in grey. A row SHALL show its state by the glyph and its colour alone, at every width, with no state word beside the glyph. Which state a session is in, and when, is decided by the `agent-state` capability.

#### Scenario: Idle is not blocked
- **WHEN** a session's last turn ended with nothing pending
- **THEN** it is drawn with the cyan `✓`, not the bold yellow `⚠`, and no word follows the glyph

#### Scenario: Running without a record
- **WHEN** a pane runs Claude but no state record exists for it
- **THEN** the row is drawn with `·`, its age column reads `--`, and the detail text is empty

### Requirement: Sessions with no pane are listed as headless
A session started with `claude -p` by a daemon, a job or `nohup`, with no tmux pane in its ancestry, SHALL be listed in the group `no window`, with `headless` in the location column. It is live while the process id its record names is alive, and shows the ordinary states.

#### Scenario: Headless row location
- **WHEN** a headless session is running
- **THEN** its location column reads `headless` where other rows show a pane

#### Scenario: Ended headless session
- **WHEN** the process of a headless session has exited
- **THEN** its row is dimmed with the `✗` glyph and its detail reads `headless, ended — nothing to resume`

#### Scenario: Its name
- **WHEN** a headless session has no label of its own
- **THEN** its name is `$TA_LABEL` as announced at launch, else the title the session gave itself, else the directory name

### Requirement: Columns are as wide as what is in them
Every column SHALL be as wide as the widest thing it has to say on any row, and a column with nothing to say on any row SHALL take no room. Columns are let in one at a time in the order of what they answer: context size, cost, the project of a flat row, location, model, account. The context needs only room for itself; every other column comes in only while the detail keeps ten columns, and a column that does not fit is skipped while a narrower one after it may still come in.

#### Scenario: Wide list
- **WHEN** the list is built for 140 columns and every column has something to say
- **THEN** age, badge, name, context, cost, model, account and location are all shown

#### Scenario: Nothing to say
- **WHEN** usage is off, so no session has a cost or a context size
- **THEN** the list draws no context column and no cost column, and their width goes to the detail

#### Scenario: A column that does not fit
- **WHEN** the pane has room for the context column but not for the cost column with ten columns of detail left
- **THEN** the context column is drawn, the cost column is not, and the detail keeps its width

### Requirement: The figure columns keep their width
The context and cost columns SHALL keep their full width whenever they are drawn, so that a figure growing a digit never shifts the columns after them. A hidden column (`ctrl-w`) SHALL never be let in, its width going to the detail, and the order the columns are drawn in SHALL never change. The account badge SHALL be shown at every width unless it is hidden.

#### Scenario: A figure grows a digit
- **WHEN** a session's context grows from 99k to 100k tokens
- **THEN** the columns after the context column stay where they were

#### Scenario: A hidden column
- **WHEN** the user hides the model column with `ctrl-w`
- **THEN** the model column is not drawn, however wide the pane is, and its width goes to the detail

## REMOVED Requirements

### Requirement: The state word yields to the name
**Reason**: The list draws no state word, so there is nothing to yield to the name.
**Migration**: None. The glyph and its colour carry the state; the preview, the notifications and the status bar still spell the state out.
