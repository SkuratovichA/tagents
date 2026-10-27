## RENAMED Requirements

- FROM: `### Requirement: Columns drop in a fixed order as the pane narrows`
- TO: `### Requirement: Columns are as wide as what is in them`

## REMOVED Requirements

### Requirement: A session holding only the sidebar has a header alone
**Reason**: The session `tagents` is never a group and a user's window never holds the list, so no session holds only the list.
**Migration**: None: a session with no chat is a group whose windows are dimmed rows (the `window-rows` capability).

## MODIFIED Requirements

### Requirement: The list is laid out for the width of its pane
The width of a list SHALL be taken from `$FZF_COLUMNS` of the running fzf, else `TA_COLS`, else the tmux pane width, else the terminal's, else 100, and never be less than 34. The available width is that minus 5 in the tree and minus 2 in a flat list. A row SHALL NOT be wider than the list it was built for.

#### Scenario: No overflow
- **WHEN** the list is built for 230 columns
- **THEN** no row is wider than 228 characters

#### Scenario: Popup list
- **WHEN** the list runs in popup mode
- **THEN** it is built for 45% of the window, since the preview takes the rest

### Requirement: Columns are as wide as what is in them
Every column SHALL be as wide as the widest thing it has to say on any row, and a column with nothing to say on any row SHALL take no room. Columns are let in one at a time in the order of what they answer: context size, cost, state word, the project of a flat row, location, model, account. The context needs only room for itself; every other column comes in only while the detail keeps ten columns, and a column that does not fit is skipped while a narrower one after it may still come in.

#### Scenario: Wide list
- **WHEN** the list is built for 140 columns and every column has something to say
- **THEN** state word, age, badge, name, context, cost, model, account and location are all shown

#### Scenario: Nothing to say
- **WHEN** usage is off, so no session has a cost or a context size
- **THEN** the list draws no context column and no cost column, and their width goes to the detail

#### Scenario: A column that does not fit
- **WHEN** the pane has room for the context column but not for the cost column with ten columns of detail left
- **THEN** the context column is drawn, the cost column is not, and the detail keeps its width

### Requirement: The name column grows to the names that exist
The name SHALL keep what it needs before any other column is let in: 22 columns from 80 available, 18 from 50, 14 from 38, else 12, and no more than the longest name needs. Once the columns are in, it SHALL grow to the longest name present, up to 64 columns and leaving the detail as many columns as its widest line, up to ten, so that hiding other columns lets a long name be shown in full.

#### Scenario: Names get the freed width
- **WHEN** a 61-column list has every optional column hidden and a session is named with thirty characters
- **THEN** the row shows the name in full

#### Scenario: Wide pane
- **WHEN** a session is named with forty characters and the list is built for 230 columns
- **THEN** the name is spelled out in full

#### Scenario: Short names
- **WHEN** every name in the list is eight characters long
- **THEN** the name column is eight columns wide

### Requirement: ctrl-v opens the preview in a modal window
`ctrl-v` SHALL open the preview in a popup 80% wide and 85% high, headed by the agent's name. The body SHALL be paged with `less -R` and `q` closes it; where `less` is not on `$PATH` the text SHALL be printed and any key closes it. In the dashboard's list there SHALL be no fzf preview window at all. Where tmux has no popups, or the list is itself a popup, `ctrl-v` toggles fzf's own preview instead (see `dashboard-popup`).

#### Scenario: Modal text
- **WHEN** the modal is opened for a session
- **THEN** it shows the preview text and says `q closes`

#### Scenario: No pager
- **WHEN** `less` is not installed
- **THEN** the same text is printed and the hint reads `any key closes`

## ADDED Requirements

### Requirement: The figure columns keep their width
The context and cost columns and the state word SHALL keep their full width whenever they are drawn, so that a figure growing a digit or an agent going idle never shifts the columns after them. A hidden column (`ctrl-w`) SHALL never be let in, its width going to the detail, and the order the columns are drawn in SHALL never change. The account badge SHALL be shown at every width unless it is hidden.

#### Scenario: A figure grows a digit
- **WHEN** a session's context grows from 99k to 100k tokens
- **THEN** the columns after the context column stay where they were

#### Scenario: A hidden column
- **WHEN** the user hides the model column with `ctrl-w`
- **THEN** the model column is not drawn, however wide the pane is, and its width goes to the detail

### Requirement: The state word yields to the name
The state word SHALL be let in only while the longest name can still grow to its full width, up to 64 columns, beside it, because the glyph already says the state in colour. On a narrow list with long names the name wins.

#### Scenario: The name wins over the state word
- **WHEN** the pane has room for a session's thirty-character name in full or for the state word beside a shortened one, but not both
- **THEN** the state word is not drawn and the name is spelled out in full
