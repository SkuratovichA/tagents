# dashboard-list Specification

## Purpose
What the tagents dashboard list shows: one row per Claude Code session, grouped by the tmux session its window is in, with a dimmed row for every window that holds no chat, the state glyphs, the columns that fit the pane, the order the rows keep, the columns a user can hide, the preview of a row, and the timeline view.

## Requirements

### Requirement: The list is produced by `tagents --list`
`tagents --list` SHALL print one line per row of the list for fzf to read, each line made of five TAB-separated fields: the row key (the pane id of a chat, the window id of a dimmed window row), the text of the row with its colours, the row's state, the session id and the directory. `tagents --flat` SHALL print the same list ungrouped whatever mode is saved.

#### Scenario: Row fields
- **WHEN** a session in `~/projects/app` is running in pane `%12` with session id `a1b2c3d4-…`
- **THEN** its line starts with `%12`, the fourth and fifth fields are its session id and its absolute directory, and the third field is its state word (`working`, `done`, `blocked`, `new`, `?` or `dead`)

#### Scenario: Nothing is running
- **WHEN** the dashboard has no row to show
- **THEN** the list it hands to fzf is one dim line reading `no claude sessions running` with the key `-` and the state `none`

#### Scenario: A dimmed window row
- **WHEN** a window of a group runs no chat
- **THEN** its line starts with the window id, for example `@7`, and its third and fourth fields are `none` and empty

### Requirement: ctrl-t switches between the tree and a flat list
`ctrl-t` SHALL switch between the tree and a flat list without headers, and the choice SHALL persist across restarts in a marker file in the state directory; switching rings the refresher's channel. `TA_FLAT=1` SHALL force the flat list for one run. A flat list SHALL hold chats only, with no dimmed window rows. A flat row SHALL carry the name of its group, the session or `no window`, in a column of its own, which hiding the `loc` column does not remove.

#### Scenario: Toggling
- **WHEN** the user presses `ctrl-t` twice
- **THEN** the list is flat after the first press and a tree again after the second

#### Scenario: Flat rows name their project
- **WHEN** the list is flat and at least 98 columns are available
- **THEN** each row names its group, the session or `no window`, as well as the agent, also when `loc` is hidden

#### Scenario: No dimmed rows when flat
- **WHEN** a group has a window that runs no chat and the list is flat
- **THEN** that window has no line

### Requirement: A group header shows the session and what is going on in it
The header of a group SHALL read `▾ <group name>`, then the group's path with `~` for the home directory when the list is 92 columns wide or more, then one badge per state present, then the five-hour cost total. The path of a session group is the session's working directory as tmux reports it, and the group `no window` shows no path. It SHALL be bold when at least one row in the group is not closed, a dimmed window row counting as not closed, and dim when every row is closed.

#### Scenario: Badges
- **WHEN** a group has one blocked, one idle and one working agent
- **THEN** its header ends with `⚠1 ✓1 ●1` in the order blocked, idle, working, new, unknown, closed, each coloured as its state

#### Scenario: Narrow pane drops the path
- **WHEN** the list is built for fewer than 92 columns
- **THEN** the header shows the group name and badges but not the path

#### Scenario: Five-hour total
- **WHEN** a group has spent money in the last five hours, the list is 60 columns wide or more and `cost` is not hidden
- **THEN** its header ends with the total as `$x/5h`

#### Scenario: Session name
- **WHEN** the group is session `release notes`
- **THEN** its header reads `▾ release notes`

### Requirement: A group header stands in for the row directly under it
A group header line SHALL carry the key, state, session id and directory of the row printed directly beneath it, so a key that acts on an agent (send, rename, kill, pick) pressed on a header acts on that agent. `enter` and `ctrl-g` on the header of a session group SHALL instead show the session (the `window-rows` capability).

#### Scenario: Header and first row agree
- **WHEN** a group has a closed and a live agent
- **THEN** the header's key equals the key of the first row beneath it, which is the live one

#### Scenario: A group of windows only
- **WHEN** a session holds one window `server` and no chat
- **THEN** the header carries the window id of `server`, the state `none` and no session id

### Requirement: The row a group header stands for
The row a header stands in for SHALL be chosen among the rows of the group that are not child sessions: open chats before dimmed window rows before closed rows, and among chats the one typed into most recently. A child is chosen only when the group has nothing else.

#### Scenario: A chat before a window row
- **WHEN** a group holds a dimmed window row and a live chat
- **THEN** the header carries the key of the live chat

#### Scenario: Only a child
- **WHEN** the only rows of a group are a child session and nothing else
- **THEN** the header carries the child's key

### Requirement: Each state has its own glyph, label and colour
The list SHALL draw states as follows: `⚠` BLOCKED in bold yellow, `✓` IDLE in cyan, `●` working in green, `○` new in grey, `·` with the word `?` in grey for a running Claude with no hook event yet, and `✗` closed in grey. The state word SHALL appear only when the list is wide enough for the label column; the glyph and colour always appear. Which state a session is in, and when, is decided by the `agent-state` capability.

#### Scenario: Idle is not blocked
- **WHEN** a session's last turn ended with nothing pending
- **THEN** it is drawn `✓ IDLE`, not `⚠ BLOCKED`

#### Scenario: Running without a record
- **WHEN** a pane runs Claude but no state record exists for it
- **THEN** the row is drawn with `·`, its age column reads `--`, and the detail text is empty

### Requirement: Closed rows say whether they can be resumed
A row whose Claude process is gone but whose record is younger than `TA_DEAD_TTL` seconds (default 86400) SHALL be listed as closed and dimmed, below the live rows of its group. Its detail text SHALL be `closed — enter resumes it`, or `closed, no session id — cannot resume` when the record has no session id.

#### Scenario: Expired corpse
- **WHEN** a closed record is older than `TA_DEAD_TTL`
- **THEN** it has no row in the list, and the `closed-sessions` capability is how to reach it

#### Scenario: Resumed elsewhere
- **WHEN** a record is closed but another record with the same session id belongs to a running Claude
- **THEN** the closed record has no row

### Requirement: Sessions with no pane are listed as headless
A session started with `claude -p` by a daemon, a job or `nohup`, with no tmux pane in its ancestry, SHALL be listed in the group `no window`, with `headless` in the location column. It is live while the process id its record names is alive, and shows the ordinary states.

#### Scenario: Headless row location
- **WHEN** a headless session is running
- **THEN** its location column reads `headless` where other rows show a pane

#### Scenario: Ended headless session
- **WHEN** the process of a headless session has exited
- **THEN** its row is dimmed `✗ closed` and its detail reads `headless, ended — nothing to resume`

#### Scenario: Its name
- **WHEN** a headless session has no label of its own
- **THEN** its name is `$TA_LABEL` as announced at launch, else the title the session gave itself, else the directory name

### Requirement: A child session hangs under the agent that started it
A session that an agent started itself with `claude -p` from its own tools SHALL be listed one level deeper than that agent and inside the agent's group, with `child` in the location column. A grandchild SHALL be drawn at the same depth as a child. How child sessions are recorded is the `agent-state` capability's concern.

#### Scenario: Nested row
- **WHEN** an agent has started one child session
- **THEN** the child's row is indented under the agent with a deeper tee, and the agent's detail starts with `⑂1`

#### Scenario: Orphaned child
- **WHEN** the parent's record has gone
- **THEN** the child is drawn as an ordinary top-level row of its own group

#### Scenario: Ended child
- **WHEN** a child's process has ended
- **THEN** its detail reads `child ended — nothing to resume` and its row expires after `TA_SUB_TTL` seconds (default 1800), not after `TA_DEAD_TTL`

### Requirement: Groups keep the place their name gives them
Session groups SHALL be ordered by session name, not by urgency. A group SHALL NOT climb the list when one of its agents blocks or drop back when the agent is answered. The only session group that moves is one in which every row is closed, which sorts to a dim section after every session group with a live row. The group `no window` SHALL always be the last group.

#### Scenario: Sessions by name
- **WHEN** sessions `work` and `personal` hold chats
- **THEN** the header `personal` comes before `work`

#### Scenario: Blocking does not reorder
- **WHEN** an agent in the second group blocks
- **THEN** the order of the groups is unchanged

#### Scenario: Closed-only project sinks
- **WHEN** a session group holds only closed rows
- **THEN** it is listed after every session group that has a live row, even when its name sorts first

#### Scenario: The trailing group is last
- **WHEN** the group `no window` holds a live headless session and a session group holds only closed rows
- **THEN** `no window` is listed after that session group

### Requirement: Inside a group rows follow the user's last message
Rows inside a group SHALL be ordered by when the user last typed into the session, newest first, then the dimmed window rows in window order, then the closed rows, and never by state or by anything that changes during a turn. A child SHALL be placed with its parent, parent first, then its own children. In a flat list the same rule applies to the whole list: open rows before closed, newest conversation first.

#### Scenario: State changes do not move rows
- **WHEN** an agent goes from working to blocked and back
- **THEN** its position among its siblings is unchanged

#### Scenario: Typing moves a row to the top
- **WHEN** the user sends a prompt to an agent that was second in its group
- **THEN** after the next refresh it is first

#### Scenario: Window rows follow the chats
- **WHEN** a group has a window that runs no chat and two chats
- **THEN** the dimmed row is listed after both chats and before any closed row

### Requirement: The age column is time since the user's last message
The second column of a row SHALL show how long ago the user last typed into the session, as `m:ss` below an hour and `HhMM` from an hour on, so the user can see how much of the one-hour prompt cache is left. It SHALL be read from the per-session file the hook writes on prompt submission in the state directory's `prompt/` folder, and fall back to the time of the record's last event when that file does not exist.

#### Scenario: Working agent
- **WHEN** a session is working and the user's last prompt was thirty minutes ago
- **THEN** the age column reads `30:00`

#### Scenario: Past the hour
- **WHEN** the last prompt was 3660 seconds ago
- **THEN** the column reads `1h01`

#### Scenario: Old record
- **WHEN** a session has no prompt-time file
- **THEN** the column shows the age of its last recorded event rather than the age of the epoch

### Requirement: A row is named by its label, its title or its project
The name on a row SHALL be, in order: the label set with `ctrl-r` or `tagents --label` (keyed by session id first, then by pane); the terminal title Claude keeps, without its leading one-character spinner glyph; for a pane-less session the name announced in `$TA_LABEL`, then the title the session gave itself; and finally the directory's name. A title that is only the machine's host name SHALL count as no title.

#### Scenario: Glyph removed
- **WHEN** the pane title is `✳ Search index rebuild`
- **THEN** the row's name is `Search index rebuild`

#### Scenario: Label wins
- **WHEN** the user has named the session `nightly`
- **THEN** the row's name is `nightly` whatever the title says

#### Scenario: A one-letter word is kept
- **WHEN** the pane title is `я иду`
- **THEN** the row's name is `я иду`

### Requirement: The account badge precedes the name
When at least one Claude profile is configured, every row SHALL carry a dim badge immediately before the name, at every width, showing which account the session's record names. With no profiles configured there SHALL be no badge column and rows SHALL be exactly as without the feature.

#### Scenario: Profiles
- **WHEN** profiles `personal` (with a config directory) and `work` (without) are configured
- **THEN** a session recorded with the personal directory shows `p`, one recorded with an unset directory shows `w`, one with a directory no profile claims shows `?`, and a record written before accounts were recorded shows a blank

#### Scenario: Explicit and long badges
- **WHEN** a profile sets `badge: PP`, or a badge longer than two characters such as `personal!`
- **THEN** the badge is shown as written, or clipped to two characters (`pe`), and the column is as wide as the widest badge for every row

#### Scenario: Default account
- **WHEN** a record names an unset config directory and no single profile lacks a directory
- **THEN** the badge is `·`

#### Scenario: No config
- **WHEN** no configuration file exists
- **THEN** no badge column is drawn at any width

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

### Requirement: The context column warns about long contexts
The context column SHALL show the session's live context size as a token count (`150k`, `1.2M`), blank when unknown, in grey, in yellow from 200000 tokens and in bold red from 600000. The figure is supplied by the `usage-accounting` capability.

#### Scenario: Colours
- **WHEN** a session's context is 150000, 250000 and 700000 tokens
- **THEN** the figures are grey, yellow and bold red respectively

### Requirement: The cost column marks what is an estimate
The cost column SHALL show the session's total in dollars: two decimals below $10, one decimal from $10, none from $100, `k` from $1000, `<$.01` for a nonzero amount below one cent, and a blank for nothing. The figure Claude Code reports through the status line SHALL be shown bare; a figure priced from the transcript SHALL be prefixed with `~`, and suffixed with `?` when part of it ran on an unpriced model.

#### Scenario: Exact and estimated
- **WHEN** the status line has reported a cost for a session, and for another it has not
- **THEN** the first cost has no `~` and the second, priced from the transcript, starts with `~`

#### Scenario: No usage tracking
- **WHEN** usage tracking is off, that is `usage.watch` names no profile or `tusage` is not installed
- **THEN** no cost column and no dollar figure is drawn

### Requirement: Subagent work is shown in front of the detail
A live row with subagents or live children SHALL start its detail with `⑂N`, N being their number. When subagents have cost money, the detail SHALL also start with `⑂$x`, their share of the cost, while `cost` is not hidden.

#### Scenario: Subagent share
- **WHEN** a session's subagents cost $1.25
- **THEN** its detail starts with `⑂$1.25`

### Requirement: The model and account columns show what the next request uses
The model column SHALL show the model the session is set to now, as reported by the status line and shortened (`claude-opus-4-8` becomes `opus4.8`, a dated snapshot suffix is dropped), falling back to the model that answered last. The account column, on the widest lists, SHALL show the profile name, `default` for an unset directory no single profile claims, the config directory's name for an unclaimed directory, and a blank for a record that predates the column.

#### Scenario: Short model name
- **WHEN** the session's model is `claude-haiku-4-5-20251001`
- **THEN** the column reads `haiku4.5`

### Requirement: Columns can be hidden with ctrl-w
`ctrl-w` SHALL open a picker with one line per column — `badge`, `ctx`, `cost`, `model`, `acct`, `loc` — each showing `[x]` when shown and `[ ]` when hidden. `enter` SHALL toggle the column under the cursor, flip the checkmark in place and reload the list behind; the picker SHALL stay open with the cursor where it was, and `esc` closes it. Hiding a column gives its width to the detail and reorders nothing.

#### Scenario: Toggle twice
- **WHEN** the user presses `enter` on `cost` in the picker twice
- **THEN** the first press hides it (its row reads `[ ] cost`) and the second shows it again

#### Scenario: Picker stays open
- **WHEN** the user presses `enter` on a column
- **THEN** the picker is still on screen with the checkmark flipped and the cursor on the same row

### Requirement: The hidden columns are remembered and can be scripted
What is hidden SHALL be kept one key per line in `cols` in the state directory so it survives a restart. `TA_HIDE_COLS` (comma separated) SHALL override that file for one run. `tagents --hidden-cols` prints the keys hidden now, `tagents --col-rows` prints the picker's rows as `key<TAB>line`, and `tagents --toggle-col KEY [PORT]` flips one column, rings the refresher's channel and, with a port, reloads the list listening there. A key that is not exactly a column name SHALL be ignored.

#### Scenario: Override
- **WHEN** `TA_HIDE_COLS=model` is set
- **THEN** `tagents --hidden-cols` prints `model` whatever the file holds

#### Scenario: Not a pattern
- **WHEN** `tagents --toggle-col 'co.t'` or `tagents --toggle-col '.*'` is run
- **THEN** nothing is hidden

#### Scenario: Nothing hidden to start with
- **WHEN** no file and no override exist and usage tracking is on
- **THEN** `tagents --hidden-cols` prints nothing

### Requirement: Hiding cost hides every dollar
Hiding `cost` SHALL remove the cost column, the `⑂$` subagent share and the project header's `/5h` total, and SHALL keep the `⑂N` subagent count, which is not money. When usage tracking is off, `cost` SHALL NOT be offered in the picker and `tagents --hidden-cols` SHALL report it as hidden, while the saved file is left as it was so the choice returns when tracking is switched on.

#### Scenario: Count stays
- **WHEN** `cost` is hidden for a session with two live subagents
- **THEN** its detail still starts with `⑂2` and shows no dollar figure

#### Scenario: Other columns stay
- **WHEN** only `cost` is hidden
- **THEN** the context and model columns are still drawn

### Requirement: The preview shows a row up close
`tagents --preview PANE [STATE]` SHALL print, for a pane with a record: the directory the session started in in bold, `cwd now:` when known, `<state> · <detail>`, `session <id>`, `parent: <name>` for a child, `account: <profile> (<config dir>)` when the record names one, the cost table per subagent and model from `tusage` when usage tracking is on, and a separator line. For the pane key `-` it SHALL print nothing.

#### Scenario: Header block
- **WHEN** the preview is asked for a session with an account recorded
- **THEN** it shows the session id and `account: personal (<its config dir>)`

#### Scenario: Child session
- **WHEN** the preview is asked for a child session
- **THEN** it names the parent by name and pane key

### Requirement: The preview body depends on what the row is
After the separator the preview SHALL show: for a live pane the last 60 lines of its screen; for a closed row the words `no Claude running in this pane any more`, the exact command `enter` would run, or a note that `enter` asks which account first, and the last three lines of its transcript; for a pane-less row the last 60 lines of its `$TA_LOG`, else the last turns of its transcript, else a note that there is nothing to show.

#### Scenario: Closed row
- **WHEN** the preview is asked for a closed row
- **THEN** it prints the resume command with the recorded account prefix, not a bare `claude --resume`

#### Scenario: Child without a log
- **WHEN** a child has no readable log
- **THEN** the preview says it is a child session with no pane and no log and shows the tail of its transcript

### Requirement: ctrl-v opens the preview in a modal window
`ctrl-v` SHALL open the preview in a popup 80% wide and 85% high, headed by the agent's name. The body SHALL be paged with `less -R` and `q` closes it; where `less` is not on `$PATH` the text SHALL be printed and any key closes it. In the dashboard's list there SHALL be no fzf preview window at all. Where tmux has no popups, or the list is itself a popup, `ctrl-v` toggles fzf's own preview instead (see `dashboard-popup`).

#### Scenario: Modal text
- **WHEN** the modal is opened for a session
- **THEN** it shows the preview text and says `q closes`

#### Scenario: No pager
- **WHEN** `less` is not installed
- **THEN** the same text is printed and the hint reads `any key closes`

### Requirement: The modal is headed by the agent's name
The heading of the modal SHALL be the agent's name — the label, else the pane title without its glyph, else `$TA_LABEL`, else the title the session gave itself, else the directory name — whole, not missing its first word, and the same name the agent's tmux window gets.

#### Scenario: Whole title
- **WHEN** the pane title is `Search index rebuild`
- **THEN** the heading is `Search index rebuild`

#### Scenario: Glyph removed
- **WHEN** the pane title is `✳ Search index rebuild`
- **THEN** the heading is `Search index rebuild`

### Requirement: ctrl-v on a pane-less session follows its log
For a pane-less session with a readable log, the modal SHALL print the record and the last lines and then follow the log with `tail -f` until `ctrl-c`, without a pager.

#### Scenario: Following
- **WHEN** ctrl-v is pressed on a headless row whose `$TA_LOG` is being written
- **THEN** new lines appear in the popup as they are written

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

### Requirement: The timeline is honest about what it cannot see
A session already running when history began, with no start event, SHALL show `?` for its start and duration. A child session SHALL be marked `↳` before its name. The name is the label, else the one `$TA_LABEL` announced, else the directory name, else the first eight characters of the session id. When there is no history file the command SHALL print a message on standard error and exit 1.

#### Scenario: No history yet
- **WHEN** neither `history.tsv` nor its rotated copy exists in the state directory
- **THEN** the command exits 1 with a message that history starts filling on the next session start

#### Scenario: Child marker
- **WHEN** a session was started by another agent
- **THEN** its name is shown as `↳ <name>`

### Requirement: Rows are grouped into a tree by session
By default rows SHALL be grouped by session: one header line per group followed by that group's rows, drawn with `├` and `└` tees. A row whose chat has a window SHALL be in the group of that window's tmux session, and the header SHALL name the session (which sessions are groups is the `window-rows` capability's).

#### Scenario: Tree is the default
- **WHEN** two chats run in session `work` and nothing has been toggled to flat
- **THEN** the list has one header line for `work` and two rows under it

#### Scenario: Two directories, one session
- **WHEN** the two chats of session `work` run in `~/projects/app` and `~/projects/api`
- **THEN** both rows are under the header `work`

#### Scenario: Two sessions that differ only in a Cyrillic letter
- **WHEN** sessions `я` and `ю` hold chats, two of them in the first
- **THEN** the list has a header for each, the two rows of `я` sit together under its header, and the last row of each group is drawn with `└`

### Requirement: Rows with no window form the last group
Every row with no window, a closed session whose pane is gone and a headless session, SHALL be in one trailing group headed `no window`, which is always the last group.

#### Scenario: Rows with no window
- **WHEN** a closed session's pane is gone and a headless session runs, and a session called `app` holds chats
- **THEN** both are under one header `no window`, listed after the header `app`, even when a session called `no window` exists

### Requirement: A subdirectory is shown in front of the detail text
A session started in a subdirectory of its repository SHALL show the subdirectory, relative to the root of that repository, in front of its detail text, whichever group it is in.

#### Scenario: Subdirectory
- **WHEN** a session runs in `~/projects/app/packages/client`
- **THEN** its detail text starts with `packages/client`

#### Scenario: Subdirectory of a Cyrillic repository
- **WHEN** a session runs in `~/projects/я/src`, below its own repository
- **THEN** its detail text starts with `src`
