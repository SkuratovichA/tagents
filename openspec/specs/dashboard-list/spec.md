# dashboard-list Specification

## Purpose
What the tagents dashboard list shows: one row per Claude Code session, grouped by project, with the state glyphs, the columns that fit the pane, the order the rows keep, the columns a user can hide, the preview of a row, and the timeline view.

## Requirements

### Requirement: The list is produced by `tagents --list`
`tagents --list` SHALL print one line per row of the list for fzf to read, each line made of five TAB-separated fields: the pane key, the text of the row with its colours, the row's state, the session id and the directory. `tagents --flat` SHALL print the same list ungrouped whatever mode is saved.

#### Scenario: Row fields
- **WHEN** a session in `~/projects/app` is running in pane `%12` with session id `a1b2c3d4-…`
- **THEN** its line starts with `%12`, the fourth and fifth fields are its session id and its absolute directory, and the third field is its state word (`working`, `done`, `blocked`, `new`, `?` or `dead`)

#### Scenario: Nothing is running
- **WHEN** the dashboard has no row to show
- **THEN** the list it hands to fzf is one dim line reading `no claude sessions running` with the pane key `-` and the state `none`

### Requirement: Rows are grouped into a tree by project
By default rows SHALL be grouped by project: one header line per project followed by that project's rows, drawn with `├` and `└` tees. A project is the repository root of the session's directory. A session started in a subdirectory stays in its project's group and shows the subdirectory, relative to the project, in front of its detail text.

#### Scenario: Tree is the default
- **WHEN** two sessions run in `~/projects/app` and nothing has been toggled to flat
- **THEN** the list has one header line for `app` and two rows under it

#### Scenario: Subdirectory
- **WHEN** a session runs in `~/projects/app/packages/client`
- **THEN** it is listed under the `app` header and its detail text starts with `packages/client`

### Requirement: ctrl-t switches between the tree and a flat list
`ctrl-t` SHALL switch between the tree and a flat list without headers, and the choice SHALL persist across restarts in a marker file in the state directory; switching rings the refresher's channel. `TA_FLAT=1` SHALL force the flat list for one run. A flat row SHALL carry its project's directory name in a column of its own, which hiding the `loc` column does not remove.

#### Scenario: Toggling
- **WHEN** the user presses `ctrl-t` twice
- **THEN** the list is flat after the first press and a tree again after the second

#### Scenario: Flat rows name their project
- **WHEN** the list is flat and at least 98 columns are available
- **THEN** each row names its project as well as the agent, also when `loc` is hidden

### Requirement: A project header shows the project and what is going on in it
The header of a project SHALL read `▾ <project name>`, then the project's path with `~` for the home directory when the list is 92 columns wide or more, then one badge per state present, then the five-hour cost total. It SHALL be bold when at least one row in the project is not closed and dim when every row is closed.

#### Scenario: Badges
- **WHEN** a project has one blocked, one idle and one working agent
- **THEN** its header ends with `⚠1 ✓1 ●1` in the order blocked, idle, working, new, unknown, closed, each coloured as its state

#### Scenario: Narrow pane drops the path
- **WHEN** the list is built for fewer than 92 columns
- **THEN** the header shows the project name and badges but not the path

#### Scenario: Five-hour total
- **WHEN** a project has spent money in the last five hours, the list is 60 columns wide or more and `cost` is not hidden
- **THEN** its header ends with the total as `$x/5h`

### Requirement: A project header stands in for the row directly under it
A group header line SHALL carry the pane key, state, session id and directory of the row printed directly beneath it, so a key pressed on a header acts on that agent. That row is chosen among the rows that are not child sessions, open before closed, then the one typed into most recently; a child is chosen only when the project has nothing else.

#### Scenario: Header and first row agree
- **WHEN** a project has a closed and a live agent
- **THEN** the header's pane key equals the pane key of the first row beneath it, which is the live one

### Requirement: Each state has its own glyph, label and colour
The list SHALL draw states as follows: `⚠` BLOCKED in bold yellow, `✓` IDLE in cyan, `●` working in green, `○` new in grey, `·` with the word `?` in grey for a running Claude with no hook event yet, and `✗` closed in grey. The state word SHALL appear only when the list is wide enough for the label column; the glyph and colour always appear. Which state a session is in, and when, is decided by the `agent-state` capability.

#### Scenario: Idle is not blocked
- **WHEN** a session's last turn ended with nothing pending
- **THEN** it is drawn `✓ IDLE`, not `⚠ BLOCKED`

#### Scenario: Running without a record
- **WHEN** a pane runs Claude but no state record exists for it
- **THEN** the row is drawn with `·`, its age column reads `--`, and the detail text is empty

### Requirement: Closed rows say whether they can be resumed
A row whose Claude process is gone but whose record is younger than `TA_DEAD_TTL` seconds (default 86400) SHALL be listed as closed and dimmed, below the live rows of its project. Its detail text SHALL be `closed — enter resumes it`, or `closed, no session id — cannot resume` when the record has no session id.

#### Scenario: Expired corpse
- **WHEN** a closed record is older than `TA_DEAD_TTL`
- **THEN** it has no row in the list, and the `closed-sessions` capability is how to reach it

#### Scenario: Resumed elsewhere
- **WHEN** a record is closed but another record with the same session id belongs to a running Claude
- **THEN** the closed record has no row

### Requirement: Sessions with no pane are listed as headless
A session started with `claude -p` by a daemon, a job or `nohup`, with no tmux pane in its ancestry, SHALL be listed in the group of the directory it was launched in, with `headless` in the location column. It is live while the process id its record names is alive, and shows the ordinary states.

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

### Requirement: Projects keep the place their path gives them
Projects SHALL be ordered by path, not by urgency. A project SHALL NOT climb the list when one of its agents blocks or drop back when the agent is answered. The only project that moves is one in which every row is closed, which sorts to a dim section after every project with a live agent.

#### Scenario: Blocking does not reorder
- **WHEN** an agent in the second project blocks
- **THEN** the order of the projects is unchanged

#### Scenario: Closed-only project sinks
- **WHEN** a project holds only closed rows
- **THEN** it is listed after every project that has a live row, even when its path sorts first

### Requirement: Inside a project rows follow the user's last message
Rows inside a project SHALL be ordered by when the user last typed into the session, newest first, with closed rows underneath, and never by state or by anything that changes during a turn. A child SHALL be placed with its parent, parent first, then its own children. In a flat list the same rule applies to the whole list: open rows before closed, newest conversation first.

#### Scenario: State changes do not move rows
- **WHEN** an agent goes from working to blocked and back
- **THEN** its position among its siblings is unchanged

#### Scenario: Typing moves a row to the top
- **WHEN** the user sends a prompt to an agent that was second in its project
- **THEN** after the next refresh it is first

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
The width of a list SHALL be taken from `$FZF_COLUMNS` of the running fzf, else `TA_COLS`, else the tmux pane width, else the terminal's, else 100, and never be less than 34. The available width is that minus 5 in the tree and minus 2 in a flat list. A row SHALL NOT be wider than the list it was built for. A surplus beyond 140 available columns SHALL widen the name and the location.

#### Scenario: No overflow
- **WHEN** the list is built for 230 columns
- **THEN** no row is wider than 228 characters

#### Scenario: Popup list
- **WHEN** the list runs in popup mode
- **THEN** it is built for 45% of the window, since the preview takes the rest

### Requirement: Columns drop in a fixed order as the pane narrows
From 128 available columns every column is shown at full width. Below that, columns SHALL go in this order: model and account first (restored between 80 and 111 available columns while the detail keeps twelve columns), then the location with the project column of a flat list, then the state word, then the cost, then the context size. The name, the age and the glyph survive to the last, the name narrowing with the width. The detail text takes the width left and is cut with `…`.

#### Scenario: Wide list
- **WHEN** the list is built for 140 columns
- **THEN** state word, age, badge, name, context, cost, model, account and location are all shown

#### Scenario: Sidebar width
- **WHEN** the list is built for 45 columns
- **THEN** the row shows the glyph, age, badge, name and context, but no cost, model, account, location or state word

#### Scenario: Model fits at 87 columns
- **WHEN** the list is built for 87 columns and the detail is short
- **THEN** the model column is still present

### Requirement: The name column grows to the names that exist
Once the rows are known, the name column SHALL grow to the longest name present, up to 64 columns and leaving at least ten columns for the detail, so that hiding other columns lets a long name be shown in full.

#### Scenario: Names get the freed width
- **WHEN** a 61-column list has every optional column hidden and a session is named with thirty characters
- **THEN** the row shows the name in full

#### Scenario: Wide pane
- **WHEN** a session is named with forty characters and the list is built for 230 columns
- **THEN** the name is spelled out in full

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

### Requirement: Docked chats are marked in the tree
Where the tree would draw a dash before a row, the list SHALL draw `▶` for the chat docked in the sidebar's current seat and a dim `▹` for every other docked chat, so the user can see which row `enter` would replace. A header and a child row are never marked. Seats themselves belong to the `seats-and-docking` capability.

#### Scenario: Two chats side by side
- **WHEN** two chats are docked and the cursor is in the first one's seat
- **THEN** the first chat's row has `▶` and the second `▹`

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
`ctrl-v` SHALL open the preview in a popup 80% wide and 85% high, headed by the agent's name. The body SHALL be paged with `less -R` and `q` closes it; where `less` is not on `$PATH` the text SHALL be printed and any key closes it. In a sidebar list there SHALL be no fzf preview window at all. Where tmux has no popups, or the list is itself a popup, `ctrl-v` toggles fzf's own preview instead (see `dashboard-popup`).

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
`tagents --timeline` SHALL print a header line and one line per session whose last activity falls within the last `TA_TIMELINE_HOURS` hours (default 24), oldest start first, each with the name, the directory (on terminals of 100 columns or more), the start and end time of day, the duration and a bar over the window. A running session SHALL be drawn in green and end at `now`.

#### Scenario: Running agent
- **WHEN** a session started two hours ago has no end event and is alive
- **THEN** its bar is green and its end reads `now`

#### Scenario: Outside the window
- **WHEN** a session ended before the window began
- **THEN** it has no line

### Requirement: The timeline is honest about what it cannot see
A session already running when history began, with no start event, SHALL show `?` for its start and duration. A child session SHALL be marked `↳` before its name. The name is the label, else the one `$TA_LABEL` announced, else the directory name, else the first eight characters of the session id. When there is no history file the command SHALL print a message on standard error and exit 1.

#### Scenario: No history yet
- **WHEN** neither `history.tsv` nor its rotated copy exists in the state directory
- **THEN** the command exits 1 with a message that history starts filling on the next session start

#### Scenario: Child marker
- **WHEN** a session was started by another agent
- **THEN** its name is shown as `↳ <name>`
