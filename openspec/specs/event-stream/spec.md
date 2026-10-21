# event-stream Specification

## Purpose
The event stream is an append-only file of the Claude Code events worth reacting to (a question, a permission prompt, a finished turn, a session start or end), written by the agent-state hook while a switch file exists, and followed by programs such as the notify plugin. This capability defines the switch, the line format, what each line carries, and what the core follower and the feed guarantee to their callers.

## Requirements

### Requirement: The switch and the file
The hook SHALL append events to `<state dir>/events.tsv` only while the file `<state dir>/events.on` exists; the state directory is the one named by `TA_STATE_DIR`, or `~/.claude/agent-state`. With the switch absent the hook SHALL write no stream, and its state record and history lines SHALL be written all the same.

#### Scenario: Switch absent
- **WHEN** a `Stop` arrives and `events.on` does not exist
- **THEN** no `events.tsv` is created
- **AND** the session's state record is written

#### Scenario: Switch present
- **WHEN** a `Stop` arrives and `events.on` exists
- **THEN** `events.tsv` gains exactly one line

### Requirement: Which events are written
With the switch on, the hook SHALL write a line for `SessionStart`, `UserPromptSubmit`, `Stop`, `SubagentStop`, `SessionEnd` and every `Notification`, whatever its type (idle pings included). It SHALL write `PreToolUse` and `PostToolUse` only when the tool is `AskUserQuestion` or `ExitPlanMode`; every other tool call writes nothing. The `PostToolUse` of those two tools means the owner answered the form or approved the plan.

#### Scenario: Ordinary tool calls
- **WHEN** a `PreToolUse` and a `PostToolUse` for `Bash` arrive
- **THEN** `events.tsv` is not written

#### Scenario: A question answered
- **WHEN** a `PostToolUse` for `AskUserQuestion` arrives
- **THEN** one line is written with event `PostToolUse`, tool `AskUserQuestion` and empty text

#### Scenario: A plan approved
- **WHEN** a `PostToolUse` for `ExitPlanMode` arrives
- **THEN** one line is written with tool `ExitPlanMode` and empty text

#### Scenario: A subagent finishes
- **WHEN** a `SubagentStop` with `agent_id` `a1` and `agent_type` `Explore` arrives
- **THEN** one line is written with agent `a1` and sub `Explore`
- **AND** the subagent's file under `sub/` is still removed

### Requirement: Line format
Each line SHALL consist of thirteen tab-separated fields ended by a newline, appended in one write: 1 time (epoch seconds), 2 event name, 3 record key (a pane number without `%`, or `s-<session id>`), 4 session id, 5 `agent_id` (empty for the main agent), 6 pane (`%12`, empty for an `s-` key), 7 cwd, 8 transcript path, 9 `CLAUDE_CONFIG_DIR`, 10 tool name (`PreToolUse` and `PostToolUse` only), 11 sub-kind, 12 text, 13 the label.

#### Scenario: A Stop in a pane
- **WHEN** a `Stop` arrives for session `sid-1` in pane `%7` with `TA_LABEL=lbl` and `CLAUDE_CONFIG_DIR=/cfg`
- **THEN** the line has thirteen fields
- **AND** they are the time, `Stop`, `7`, `sid-1`, empty, `%7`, the cwd, the transcript, `/cfg`, empty, empty, empty and `lbl`

#### Scenario: A headless session
- **WHEN** an event arrives for a session with no pane
- **THEN** field 3 is `s-<session id>` and field 6 is empty

### Requirement: Sub-kind and text
Field 11 SHALL hold the notification type (`notification_type` or `notificationType`) for a `Notification`, the source for `SessionStart`, the reason for `SessionEnd`, the agent type for `SubagentStop`. Field 12 SHALL hold the message of a `Notification`; the first question of an `AskUserQuestion`; the first non-empty line of an `ExitPlanMode` plan without its leading `#` marks; the first non-empty line of a `Stop`'s `last_assistant_message`; otherwise nothing.

#### Scenario: A permission prompt
- **WHEN** a `Notification` of type `permission_prompt` with the message `Claude needs your permission to use Bash` arrives
- **THEN** field 11 is `permission_prompt`
- **AND** field 12 is the message

#### Scenario: An idle ping
- **WHEN** a `Notification` with `notificationType` `idle_prompt` arrives
- **THEN** a line is written with field 11 `idle_prompt`

#### Scenario: A question
- **WHEN** a `PreToolUse` for `AskUserQuestion` with the question `Pick one?` arrives
- **THEN** field 10 is `AskUserQuestion` and field 12 is `Pick one?`

#### Scenario: A plan
- **WHEN** an `ExitPlanMode` plan begins with blank lines and then `# Plan: refactor the parser`
- **THEN** field 12 is `Plan: refactor the parser`

#### Scenario: A finished turn
- **WHEN** a `Stop` carries `last_assistant_message` of `\n  \nFirst   line here\nsecond line`
- **THEN** field 12 is `First line here`

#### Scenario: A Stop without a message
- **WHEN** a `Stop` has no `last_assistant_message`
- **THEN** field 12 is empty and the line is still written

### Requirement: Text is one clean line
Every field of a line SHALL be free of tab, carriage return and newline characters (each replaced by a space), and field 12 SHALL have each run of spaces collapsed to one and be cut to 240 characters, the last of them being `…` when the text was longer. The text of a `Stop` or a plan is taken from at most the first 1000 characters of the first non-empty line.

#### Scenario: Control characters
- **WHEN** a notification message is `one<TAB>two<NEWLINE>three`
- **THEN** one line is written whose field 12 is `one two three`

#### Scenario: A long question
- **WHEN** a question is 300 characters long
- **THEN** field 12 is 240 characters long and ends in `…`

### Requirement: A malformed payload costs nothing
Whatever a payload holds in `tool_input`, `message` or `last_assistant_message` (wrong types, empty arrays, null, a number), the hook SHALL still write the session's state record, and SHALL write the event line with an empty text where the text cannot be extracted.

#### Scenario: Questions of the wrong type
- **WHEN** a `PreToolUse` for `AskUserQuestion` has `questions` set to the string `nope`
- **THEN** the state record is written
- **AND** the event line is written with empty text

#### Scenario: A numeric plan
- **WHEN** a `PreToolUse` for `ExitPlanMode` has `plan` set to `5`
- **THEN** the state record is written and the event's text is empty

### Requirement: Children and background jobs in the stream
The line of a session keyed `s-<session id>` (a headless session, a background job or a child) SHALL carry that key in field 3 and an empty pane in field 6, even when the process inherited a pane through its environment, so that a reader acting on a pane never takes the line for the inherited pane's own. Field 13 of an `s-` line SHALL be the label the session's record keeps, which is blank when it is one inherited from an ancestor; a pane's line carries `TA_LABEL` of the hook's environment.

#### Scenario: A child inherits a pane
- **WHEN** a child sends `SessionStart` and `Stop` with its parent's pane in `TMUX_PANE`
- **THEN** both lines carry `s-<its session id>` in field 3 and nothing in field 6
- **AND** no line carries the parent's pane number as its key

#### Scenario: A child's inherited label is blank
- **WHEN** a child of a session labelled `lbl` sends `Stop` with `TA_LABEL=lbl` inherited
- **THEN** field 13 of its line is empty
- **AND WHEN** a child sends `Stop` with a label of its own, `TA_LABEL=own`, **THEN** field 13 is `own`

#### Scenario: A job re-keyed off its parent's pane
- **WHEN** a background job without `TMUX_PANE` runs below pane `%9` whose record belongs to another session
- **THEN** its line has key `s-<its session id>` and an empty pane
- **AND** the owner's lines still carry key `9` and pane `%9`

### Requirement: The stream is an add-on
With the switch on, the hook SHALL write exactly the same state record, `history.tsv` and side files as with it off, byte for byte, and SHALL start the same programs, except that `SessionStart` runs one extra size check (`wc`) when `events.tsv` exists. An idle machine pays one existence test of `events.on` per hook call.

#### Scenario: Identical files
- **WHEN** the same sequence of events (`SessionStart`, `UserPromptSubmit`, a `Bash` tool call, a `Notification`, `Stop`, `SessionEnd`) runs once with the switch on and once with it off
- **THEN** the state directories are identical apart from `events.tsv` and `events.on`

#### Scenario: One jq
- **WHEN** any event other than `SessionStart` runs with the switch on
- **THEN** exactly one `jq` is started, no `wc`, no `cat` and no `date`, and no more than one `tmux` unless the hook decides the session's place again

#### Scenario: The same programs as with the switch off
- **WHEN** an event other than `SessionStart` runs once with the switch on and once with it off
- **THEN** the same set of programs is started both times

#### Scenario: SessionStart size check
- **WHEN** a `SessionStart` runs with both `history.tsv` and `events.tsv` present
- **THEN** exactly one more `wc` is started than with the switch off

### Requirement: Rotation of the stream file
On `SessionStart`, with the switch on, the hook SHALL move `events.tsv` to `events.tsv.1` (replacing any file there) when it is larger than 5 MiB, and the next append SHALL create a new file that only its owner can read (mode 0600). A smaller file SHALL be appended to in place.

#### Scenario: Oversized
- **WHEN** `events.tsv` is 6 MiB and a `SessionStart` arrives
- **THEN** it becomes `events.tsv.1`
- **AND** a fresh `events.tsv` holds the new line with mode 0600

#### Scenario: Under the limit
- **WHEN** `events.tsv` is small
- **THEN** it is not moved and the new line is appended

### Requirement: Parsing a line
The core package SHALL parse a line of `events.tsv` into an event with the fields above and its time in epoch milliseconds (state rows keep seconds). A line SHALL be rejected when it has fewer than thirteen fields, when its time is empty or not a number, or when its event is not one the hook writes. A trailing carriage return and fields beyond the thirteenth SHALL be ignored.

#### Scenario: A good line
- **WHEN** a line with time `1760000200` is parsed
- **THEN** the event's time is `1760000200000`

#### Scenario: A short or unknown line
- **WHEN** a line has twelve fields, an unknown event or a non-numeric time
- **THEN** it yields no event

#### Scenario: A newer hook
- **WHEN** a line has a fourteenth field
- **THEN** the first thirteen are read as usual

#### Scenario: The hook's own lines
- **WHEN** the hook of this tree writes a question, a `Stop` and the answer to the question
- **THEN** the parser reads each of them, with the cwd, transcript, key `7` and pane `%7` of the run

### Requirement: Switching the stream on and off
The core package SHALL turn the stream on by creating `events.on` (and the state directory if needed) and an empty `events.tsv` when there is none, without touching a file that exists, and off by removing `events.on` and nothing else, leaving the log for the next reader. Turning it off twice, or on twice, SHALL be harmless.

#### Scenario: On
- **WHEN** the stream is turned on in a directory with no files
- **THEN** `events.on` and an empty `events.tsv` exist

#### Scenario: An existing log
- **WHEN** it is turned on while `events.tsv` has lines
- **THEN** the lines are kept

#### Scenario: Off
- **WHEN** it is turned off
- **THEN** `events.on` is gone and `events.tsv` remains

### Requirement: Following the stream
A follower SHALL deliver each event appended to `events.tsv` after it started, once, in file order, and no backlog. It SHALL create the state directory and the file when they are missing, and SHALL throw from its start when it cannot create or watch the file. A malformed line SHALL be skipped and the lines after it still delivered. A line written in several appends SHALL be delivered once, whole, also when a multibyte character is split between two appends.

#### Scenario: No backlog
- **WHEN** the file holds two lines and a follower starts, then a third line is appended
- **THEN** only the third is delivered

#### Scenario: A split line
- **WHEN** one line arrives in two appends
- **THEN** it is delivered once, complete

#### Scenario: A malformed line
- **WHEN** a garbage line is followed by a good one
- **THEN** only the good one is delivered

#### Scenario: A missing directory
- **WHEN** a follower starts on a directory that does not exist
- **THEN** the directory and the file are created

### Requirement: The follower survives what happens to the file
The follower SHALL keep delivering after `events.tsv` is truncated (it reads from the start), deleted or replaced (it drains the old file, then follows the path again from the start, creating it when missing), and renamed by the hook's rotation. The one case it cannot detect is a truncation followed by growth past the old offset before it wakes.

#### Scenario: Truncation
- **WHEN** the file is truncated and a line appended
- **THEN** that line is delivered

#### Scenario: Deletion
- **WHEN** the file is deleted and the path recreated with a line in it
- **THEN** that line is delivered

#### Scenario: The hook rotates
- **WHEN** the file is moved aside and lines are appended to the path at once
- **THEN** those lines are delivered

### Requirement: The follower trims the file itself
Once it has drained the file and the file has reached 1 MiB (or the `rotateBytes` option), the follower SHALL rename `events.tsv` to `events.tsv.1` and follow a fresh `events.tsv`. It SHALL keep the renamed file open for a grace of 2 seconds, so a hook that opened the old path just before the rename still lands its line; a line that arrives in the grace is delivered when it ends, possibly after newer events. No line is lost or delivered twice.

#### Scenario: Fifty lines across a rotation
- **WHEN** fifty lines are appended with a small `rotateBytes`
- **THEN** all fifty are delivered once, in order
- **AND** `events.tsv.1` exists

#### Scenario: A late write
- **WHEN** a hook writes to the old file inside the grace
- **THEN** the line is delivered once the grace ends

### Requirement: Closing a follower
`close()` SHALL stop all delivery at once, release the watcher and any timer so the process can exit, and be harmless when called again. Closing from inside the callback SHALL stop the lines that came with the current batch.

#### Scenario: After close
- **WHEN** a follower is closed and a line is appended
- **THEN** nothing is delivered

#### Scenario: During the grace
- **WHEN** a follower is closed while the grace of a rotation is running
- **THEN** no timer or handle is left holding the process

### Requirement: Errors in the consumer
An exception thrown by the consumer's callback SHALL go to the `onError` option (dropped when there is none), and the follower SHALL keep following.

#### Scenario: A throwing consumer
- **WHEN** the callback throws on one event
- **THEN** `onError` receives the error
- **AND** the next event is still delivered

### Requirement: A follower that cannot hear the file
When the follower cannot reopen the path after a rename, rotation or replacement, cannot watch the new file, or its watcher reports an error, it SHALL close itself and call `onDead` once with the error; with no `onDead` the error SHALL go to `onError`. It SHALL NOT call `onDead` after an explicit `close()` or a second time. An `onDead` that throws SHALL be reported to `onError`.

#### Scenario: A watch error
- **WHEN** the watcher emits an error
- **THEN** `onDead` is called once and nothing is delivered afterwards

#### Scenario: Explicit close first
- **WHEN** the follower was closed and the watcher complains later
- **THEN** `onDead` is not called

#### Scenario: A failed open after rotation
- **WHEN** the fresh file cannot be opened after the follower's own rotation
- **THEN** the follower is dead, reported once through `onDead`

### Requirement: The feed keeps the switch on while anyone listens
A feed over a state directory SHALL turn the switch on when its first follower starts and off when the last one closes, counting followers per directory across all feeds of the process, with differently spelt paths of one directory (a trailing slash, a symlink) counted together. A follower that dies counts as closed, once. `close()` SHALL NOT throw: a switch that cannot be removed goes to `onError` once.

#### Scenario: Two followers
- **WHEN** two followers are open and one is closed twice
- **THEN** the switch stays on
- **AND** it goes off when the other closes, with `events.tsv` kept

#### Scenario: Two spellings
- **WHEN** followers are started through `dir`, `dir/` and a symlink to `dir`
- **THEN** the switch stays on until all three are closed

#### Scenario: The last follower dies
- **WHEN** the only follower dies
- **THEN** the switch is already off when `onDead` runs

#### Scenario: A death with another follower open
- **WHEN** one of two followers dies
- **THEN** the switch is still on when `onDead` runs, and closing the dead follower later does not count it out again

### Requirement: The feed also reads the state rows
A feed SHALL return, through its `states()` call, the current rows of the state directory as the `agent-state` capability reads them. Their `at` is epoch seconds, while an event's `at` is epoch milliseconds.

#### Scenario: Rows and events together
- **WHEN** a feed over a directory with two records is asked for its states and a line with time `1760000200` is then appended
- **THEN** it returns the two rows
- **AND** the follower delivers an event whose time is `1760000200000`
