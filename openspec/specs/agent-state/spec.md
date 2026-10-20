# agent-state Specification

## Purpose
The agent-state hook runs inside every Claude Code session and publishes what the session is doing as small files in a state directory, so that the dashboard, the status bar and other programs can show every agent on the machine, and rings the dashboard's tmux channel so that it need not poll for them. This capability defines which states exist, when each is set, the records and side files the hook writes, how a session without a pane and a child session are told apart, and how the records are cleaned up.

## Requirements

### Requirement: Events and the states they set
The hook SHALL map each Claude Code event of the main agent to one of the states `new`, `working`, `blocked` and `done`, or to the end of the session: `SessionStart` sets `new`, `UserPromptSubmit`, `PreToolUse` and `PostToolUse` set `working`, `Stop` sets `done`, `Notification` sets `blocked` or `done` (see the next requirement), `SessionEnd` ends the session, `SubagentStop` sets no session state, and any other event name sets `working`.

#### Scenario: A session opens
- **WHEN** a `SessionStart` payload arrives
- **THEN** the state is `new`

#### Scenario: A turn ends
- **WHEN** a `Stop` payload arrives
- **THEN** the state is `done`

#### Scenario: A prompt is submitted
- **WHEN** a `UserPromptSubmit` payload arrives for a session in a pane
- **THEN** the state is `working`

#### Scenario: An unknown event
- **WHEN** an event with an unrecognised name arrives
- **THEN** the state is `working` and the detail is the event name

### Requirement: Detail text of each event
The detail of a record SHALL be: for `UserPromptSubmit` the prompt; for `PreToolUse` the tool name followed by its first argument, taken from the tool input's `command`, `file_path`, `pattern`, `path`, `url`, `description` or `prompt`, in that order; for `PostToolUse` the tool name followed by ` ✓`; for `SessionStart` `session <source>` (`session start` without a source); for `Notification` the message; for `Stop` empty.

#### Scenario: A prompt
- **WHEN** a `UserPromptSubmit` payload with the prompt `hello there` arrives
- **THEN** the detail is `hello there`

#### Scenario: A tool call starts
- **WHEN** a `PreToolUse` payload for the tool `Bash` with the command `ls -la` arrives
- **THEN** the detail is `Bash ls -la`

#### Scenario: A tool call ends
- **WHEN** a `PostToolUse` payload for the tool `Bash` arrives
- **THEN** the detail is `Bash ✓`

#### Scenario: A session opens
- **WHEN** a `SessionStart` payload with the source `startup` arrives
- **THEN** the detail is `session startup`

#### Scenario: A turn ends
- **WHEN** a `Stop` payload arrives
- **THEN** the detail is empty

### Requirement: Notifications that only say it is the owner's move
A `Notification` that asks for a decision SHALL set `blocked` and keep its message as the detail, subject to the line rules below. A `Notification` that only reports that the turn is over and it is the owner's move, recognised by the notification type `idle_prompt` (spelled `notification_type` or `notificationType`) or by a message containing `waiting for your input` in any letter case, SHALL set `done` with an empty detail, exactly as `Stop` does.

#### Scenario: A permission prompt
- **WHEN** a `Notification` payload of type `permission_prompt` with the message `Claude needs your permission to use Bash` arrives
- **THEN** the state is `blocked`
- **AND** the detail is `Claude needs your permission to use Bash`

#### Scenario: An idle ping
- **WHEN** a `Notification` payload of type `idle_prompt` with the message `Claude is waiting for your input` arrives
- **THEN** the state is `done`
- **AND** the detail is empty

### Requirement: Detail text is one short line
The detail written to a record SHALL contain no tab, carriage return or newline (each run of them becomes one space), SHALL have leading and trailing spaces removed, and SHALL be at most 90 characters, a longer text being cut to 89 characters followed by `…`.

#### Scenario: A multi-line prompt
- **WHEN** a prompt contains a newline and a tab
- **THEN** the detail holds them as single spaces on one line

#### Scenario: A long prompt
- **WHEN** a prompt is longer than 90 characters
- **THEN** the detail is its first 89 characters followed by `…`

### Requirement: Where the state is kept
The hook SHALL keep its files in the directory named by `TA_STATE_DIR`, or `~/.claude/agent-state` when that variable is unset, creating the directory and its `sub/` and `prompt/` subdirectories when they are missing. Every file the hook creates SHALL be readable by its owner only (mode 0600).

#### Scenario: The default directory
- **WHEN** the hook runs without `TA_STATE_DIR`
- **THEN** its records are written under `~/.claude/agent-state`

#### Scenario: A new file is private
- **WHEN** the hook creates a state record, `history.tsv` or `events.tsv`
- **THEN** the file's mode is 0600

### Requirement: The hook never gets in the way
The hook SHALL exit with status 0 and write nothing when `jq` is not installed, when the payload is empty or cannot be parsed, when the state directory cannot be created, or when the session has neither a pane nor a session id to key a record on. It SHALL print nothing that Claude Code would read.

#### Scenario: Empty input
- **WHEN** the hook runs with an empty standard input
- **THEN** it exits with status 0
- **AND** no record is written

#### Scenario: Nothing to key on
- **WHEN** a payload has no session id and the process has no pane anywhere
- **THEN** the hook exits with status 0 and writes no record

### Requirement: The record files
Each session SHALL have one record, a single tab-separated line in `<state dir>/<key>.tsv`, replaced whole on every event of its main agent and atomically (a temporary file in the same directory, renamed into place), so that a reader sees the old line or the new one and never a partial one. The key is the session's pane number without its `%` (digits only), or `s-<session id>` for a session that does not own a pane.

#### Scenario: A session in a pane
- **WHEN** an event arrives for a session whose pane is `%7`
- **THEN** its record is `<state dir>/7.tsv`

#### Scenario: A session with no pane
- **WHEN** an event arrives for a session `a1b2c3d4` that has no pane anywhere in its ancestry
- **THEN** its record is `<state dir>/s-a1b2c3d4.tsv`

### Requirement: Fields of a record
Every record SHALL start with seven fields: 1 the time of the event in epoch seconds, 2 the state (`new`, `working`, `blocked` or `done`), 3 the Claude session id, 4 the session's working directory, 5 the path of its transcript file, 6 the detail, 7 the value of `CLAUDE_CONFIG_DIR` of the session (empty for the default account). A record of a session that owns a pane SHALL have these seven fields and no more.

#### Scenario: A paned record
- **WHEN** a session in a pane writes its record
- **THEN** the line has exactly seven fields
- **AND** no field holds `TA_LOG`, whatever it is set to

### Requirement: Extra fields of a record without a pane
A record of a session that owns no pane SHALL carry three more fields: 8 the pid of the session's own claude process, 9 the value of `TA_LOG`, 10 the value of `TA_LABEL`. A record of a child session SHALL carry two more: 11 the record key of its parent, 12 the session id of its parent.

#### Scenario: A headless record
- **WHEN** a session without a pane starts with `TA_LABEL=ticket-agent`, `TA_LOG=/tmp/ticket-agent.log` and `CLAUDE_CONFIG_DIR=~/.claude-work`
- **THEN** its record has ten fields
- **AND** field 7 is the config directory, field 8 is the pid of its claude process, field 9 is the log path, and field 10 is `ticket-agent`

#### Scenario: A child record
- **WHEN** a child session writes its record
- **THEN** the record has twelve fields
- **AND** field 11 is its parent's record key and field 12 is its parent's session id

### Requirement: The account field
The hook SHALL write the `CLAUDE_CONFIG_DIR` it runs under as field 7 of every record. An empty field 7 means the default account. A record with only six fields predates the field and says nothing about the account; a reader SHALL tell the two apart by the field count.

#### Scenario: Default account
- **WHEN** `CLAUDE_CONFIG_DIR` is unset
- **THEN** field 7 is present and empty

#### Scenario: A reader meets a six-field record
- **WHEN** a record has six fields
- **THEN** a reader reports no account information for it, which is not the same as the default account

### Requirement: The pane option
For a session that owns a pane the hook SHALL set the tmux pane option `@agent` on that pane (`set -p -t <pane> @agent <state>`) on every event that writes the record, so that the tmux status bar can read the coarse state without opening any file. It SHALL remove the option (`set -up`) when the session ends. For a session without a pane, and for a child session, it SHALL never set or unset any pane option.

#### Scenario: State mirrored onto the pane
- **WHEN** a `UserPromptSubmit` arrives for a session in pane `%9101`
- **THEN** `@agent` on `%9101` becomes `working`

#### Scenario: Headless sessions touch no pane option
- **WHEN** events arrive for a session with no pane, including its `SessionEnd`
- **THEN** no `set -p` or `set -up` command is sent to tmux

#### Scenario: Session end clears the option
- **WHEN** `SessionEnd` arrives for a session in pane `%7` whose record is its own
- **THEN** `@agent` is unset on `%7`

### Requirement: The hook rings the dashboard in one tmux call
An event that writes or removes a record SHALL ring the dashboard in one tmux call whose first command adds one to the global option `@tagents_evgen`, whose second is `wait-for -S tagents-ev`, and whose third, for a session with a pane, is the `set -p` or `set -up` of `@agent`. The ring comes first because a failed command skips the ones after it and a pane that has just closed fails the set. A session with no pane makes the call without the third command. With no tmux server it fails quietly.

#### Scenario: A paned event
- **WHEN** a `UserPromptSubmit` arrives for a session in pane `%9101`
- **THEN** tmux receives exactly `set -gF @tagents_evgen #{e|+|:#{@tagents_evgen},1} ; wait-for -S tagents-ev ; set -p -t %9101 @agent working`

#### Scenario: A session-start event with no pane
- **WHEN** a `SessionStart`, or an event that makes the hook decide the session's place again, arrives for a session with no pane
- **THEN** tmux is asked for the pane map and then receives the ring with no pane option

#### Scenario: Any other event with no pane
- **WHEN** any other event arrives for a session with no pane
- **THEN** tmux receives the ring alone, with no pane option

#### Scenario: A pane that has just closed
- **WHEN** an event names a pane that does not exist
- **THEN** `tagents-ev` is rung all the same

#### Scenario: Someone else's record
- **WHEN** `SessionEnd` finds the record in its key naming another conversation
- **THEN** that record, its subagent files, its prompt-time file and the pane option are left alone, and nothing is rung

### Requirement: Which pane a session belongs to
The hook SHALL resolve the pane by walking up the process ancestry of the session to a process that tmux lists as the root of a pane; the walk, not the inherited `TMUX_PANE`, decides when it finds one, unless `CLAUDE_PID` is set and `TMUX_PANE` is a live pane the walk does not reach (the session is then a child). When the walk finds none, `TMUX_PANE` is used. A `TMUX_PANE` that is not `%` followed by digits SHALL name no pane. A session with no pane is keyed `s-<session id>`.

#### Scenario: Ancestry beats the environment
- **WHEN** the process ancestry reaches pane `%5` while `TMUX_PANE` says `%9`, and `CLAUDE_PID` is unset or `%9` is not a live pane
- **THEN** the record is keyed `5`

#### Scenario: Junk in TMUX_PANE
- **WHEN** `TMUX_PANE` holds `not-a-pane` and the ancestry reaches no pane
- **THEN** no file named after that value is created
- **AND** the session is recorded as `s-<session id>`

#### Scenario: A pane with a sibling
- **WHEN** a pane also holds a second, suspended claude, and the session's own ancestry reaches that pane
- **THEN** the session is keyed by the pane and is not taken for a child

### Requirement: How the hook decides cheaply
At `SessionStart` the hook SHALL decide from scratch where the session belongs; on every other event it SHALL read the decision back from the existing record and not walk the process table. A pane-less record is trusted while its field 8 equals `CLAUDE_PID` (or that is absent); a pane record named by `TMUX_PANE` is trusted while its field 3 is empty or the session id. Otherwise the hook SHALL decide again and SHALL NOT overwrite a record that is not the session's.

#### Scenario: Hot path
- **WHEN** a `PreToolUse` event arrives for a child whose record names this claude's pid
- **THEN** the process table is not read
- **AND** the record keeps its parent key, parent session, pid and the new state

#### Scenario: A record written by another process
- **WHEN** the record `s-<session id>.tsv` names a pid other than the running claude
- **THEN** the hook decides the session's place again
- **AND** the record of the pane it was handed through `TMUX_PANE` is left as it was

#### Scenario: A record lost mid-flight
- **WHEN** a child's record has been deleted and a later event arrives
- **THEN** the child is classified as a child again and its record is recreated
- **AND** its parent's pane record is unchanged

### Requirement: SessionStart replaces a stale pane-less record
When `SessionStart` decides that the session owns a pane, the hook SHALL delete any `s-<session id>.tsv` and `prompt/s-<session id>` left for that session, so a stale child or headless record cannot win on the next event.

#### Scenario: A resumed conversation lands in a pane
- **WHEN** a session id that has a stale child record starts in a pane of its own
- **THEN** the child record is gone
- **AND** the session's record is keyed by the pane

### Requirement: A background job must not take over a pane
When a session has no `TMUX_PANE`, its ancestry resolves to a pane, and that pane's record names a different session, the hook SHALL key the new session as `s-<session id>` with an empty pane, leave the pane's record untouched, and set no tmux option.

#### Scenario: A job started by an agent in pane 9
- **WHEN** session `sid-bg` runs without `TMUX_PANE` below a process that is the root of pane `%9`, whose record names session `sid-owner`
- **THEN** a record `s-sid-bg.tsv` is written
- **AND** `9.tsv` still names `sid-owner`

### Requirement: Sessions with no pane at all
A session whose ancestry reaches no pane and that has no usable `TMUX_PANE`, for example a headless `claude -p` started by a daemon or a launchd job, SHALL be recorded as `s-<session id>` with the ten-field layout. Field 8 is the pid of its claude process: `CLAUDE_PID` when set, else the claude found in the ancestry, else the hook's parent process. It is the only liveness signal such a record has.

#### Scenario: Started by a daemon
- **WHEN** a `claude -p` started with `TA_LABEL=ticket-agent` and `TA_LOG=/tmp/ticket-agent.log` and no pane sends `SessionStart`
- **THEN** `s-<session id>.tsv` exists with ten fields
- **AND** no file named after a pane number is created
- **AND** the only things asked of tmux are the pane map and the ring

### Requirement: Child sessions
A session started by another agent, typically a `claude -p` run from an agent's Bash tool, SHALL be recorded as a child: key `s-<its own session id>`, the twelve-field layout, field 11 the parent's record key (`83` for a pane, `s-<session id>` for a pane-less parent) and field 12 the parent's session id. A session is a child only when `CLAUDE_PID` is set to a number and it has a session id.

#### Scenario: A grandchild
- **WHEN** a child starts a session of its own
- **THEN** that session's field 11 is the child's record key

#### Scenario: No usable CLAUDE_PID
- **WHEN** `CLAUDE_PID` is unset or not a number
- **THEN** the session is never recorded as a child

### Requirement: Who the parent of a child is
The parent SHALL be found in one of two ways. (1) A claude sits strictly above the session: the parent is the pane-less session whose record has that pid in field 8, else the session in the pane the ancestry reaches. (2) No claude sits above, `TMUX_PANE` names a live pane of a visible tmux server and the session's ancestry does not reach it: the parent is the session in that pane. A session that reaches its own pane with no claude above it is never a child.

#### Scenario: A child of a pane-less parent
- **WHEN** a session starts below a claude whose record `s-sid-p1h.tsv` names that claude's pid in field 8
- **THEN** it is recorded as `s-<its session id>` with twelve fields
- **AND** field 11 is `s-sid-p1h` and field 12 is `sid-p1h`
- **AND** the parent's record is byte for byte unchanged

#### Scenario: A child of an agent in a pane
- **WHEN** a session starts below the claude of pane `%12` and its chain walks through it into that pane
- **THEN** field 11 is `12` and field 12 is the session id found in `12.tsv`

#### Scenario: The inherited pane
- **WHEN** a session has an inherited `TMUX_PANE` of a live pane that its own ancestry does not reach
- **THEN** it is a child of the session in that pane, even if the process that started it has already exited

#### Scenario: A session in its own pane
- **WHEN** a session's ancestry reaches its pane and no claude sits above it
- **THEN** it is keyed by the pane and is not a child, also when a sibling claude sleeps in the same pane

### Requirement: A child never touches its parent
A child session SHALL NOT write, delete or replace the record of the pane it inherited, SHALL NOT set or unset `@agent` on that pane, and SHALL key its subagent files and prompt-time file by its own `s-<session id>` key. Its `SessionEnd` SHALL remove only its own files.

#### Scenario: A child lives through a whole session
- **WHEN** a child sends `SessionStart`, `PreToolUse`, `Stop` and `SessionEnd` with the parent's pane in `TMUX_PANE`
- **THEN** the parent's record and its subagent files are unchanged after each event
- **AND** no `@agent` command is sent for that pane
- **AND** the child's own record is gone after `SessionEnd`

### Requirement: Inherited label and log do not name the child
For a child, `TA_LOG` and `TA_LABEL` from the environment SHALL be written to fields 9 and 10 only when no ancestor was started with the same value. The hook compares them with fields 9 and 10 of the parent's record, then of its parent, and so on for at most eight records, stopping at a missing record or a pane record. For a parent in a pane, the label is also compared with the one on the `start` line of that session in `history.tsv`. A value equal to an ancestor's is written as empty.

#### Scenario: The label is the parent's
- **WHEN** a child starts with `TA_LABEL=nightly-sweep` and its parent was started under the same label
- **THEN** its field 10 is empty
- **AND** its `start` line in `history.tsv` carries an empty label

#### Scenario: The log is the parent's
- **WHEN** a child inherits the parent's `TA_LOG` while having its own `TA_LABEL`
- **THEN** its field 9 is empty
- **AND** its field 10 is its own label

#### Scenario: A value of its own
- **WHEN** a child has a `TA_LABEL` that no ancestor was started with
- **THEN** its field 10 holds it

#### Scenario: Two generations up
- **WHEN** a grandchild inherits the label of the head of its family and its parent's own label field was already blanked
- **THEN** the grandchild's field 10 is empty too

### Requirement: Subagent files
Events that carry an `agent_id` belong to a subagent. For each the hook SHALL write `<state dir>/sub/<key>.<agent id>` holding the time and the detail, tab-separated, and leave the session's record, pane option, prompt-time file and history untouched. A `SubagentStop` with an `agent_id` SHALL delete that file; without one it changes nothing. A turn that ends (`Stop`, or an idle `Notification`) SHALL delete every subagent file of the session's key.

#### Scenario: A subagent works
- **WHEN** a `PreToolUse` with `agent_id` `a1` arrives for the session in pane `%7`
- **THEN** `sub/7.a1` exists
- **AND** `7.tsv` is not rewritten

#### Scenario: A subagent of a headless session
- **WHEN** the same event arrives for a session keyed `s-sid-h1`
- **THEN** `sub/s-sid-h1.a1` exists
- **AND** the subagent's `SubagentStop` removes it and adds no history line

#### Scenario: The turn ends
- **WHEN** a `Stop` arrives while `sub/7.a1` and `sub/7.a2` exist
- **THEN** both files are deleted

### Requirement: A subagent file that appears or goes rings the dashboard
When the hook creates or removes a subagent file, it SHALL ring `tagents-ev` in a tmux call of its own (the count first, then the signal), because the list draws how many subagents a session has. A rewrite of a file that already exists SHALL ring nothing, so that a busy subagent costs no program per tool call, and removing a file that was not there SHALL ring nothing.

#### Scenario: A subagent starts
- **WHEN** the first event with `agent_id` `a1` arrives for the session in pane `%7`
- **THEN** `sub/7.a1` exists and the channel was rung once

#### Scenario: A busy subagent
- **WHEN** a second event with the same `agent_id` arrives
- **THEN** the file is rewritten and nothing is rung

#### Scenario: A subagent stops
- **WHEN** `SubagentStop` arrives with `agent_id` `a1` while `sub/7.a1` exists
- **THEN** the file is removed and the channel is rung

### Requirement: When the owner last typed
On `UserPromptSubmit` of the main agent the hook SHALL write the current epoch second, and nothing else, to `<state dir>/prompt/<key>`. No other event changes the file. It exists so that the age shown for a session and the order of the list move once per turn rather than on every tool call.

#### Scenario: Two prompts
- **WHEN** a prompt is submitted and a tool call follows
- **THEN** `prompt/<key>` holds the time of the prompt, unchanged by the tool call

#### Scenario: A subagent prompt
- **WHEN** a `UserPromptSubmit` carries an `agent_id`
- **THEN** `prompt/<key>` is not written

### Requirement: The history timeline
For the main agent the hook SHALL append one line to `<state dir>/history.tsv` on `SessionStart` (kind `start`), `Stop` (kind `turn`) and `SessionEnd` (kind `end`), and on no other event. A line has six tab-separated fields: the epoch second, the kind, the session id, the pane (`%12`, empty when none), the `TA_LABEL` of the environment, and the working directory. A child's line has a seventh, the parent's session id, with an empty pane and the label left after the inherited-label rule.

#### Scenario: A headless run
- **WHEN** a headless session sends `SessionStart`, `Stop` and `SessionEnd`
- **THEN** `history.tsv` gains three lines of kinds `start`, `turn` and `end`, each with an empty pane field

#### Scenario: A child's line
- **WHEN** a child's `SessionStart` is logged
- **THEN** the line has seven fields and the seventh is its parent's session id

#### Scenario: Tool calls
- **WHEN** a `PreToolUse` arrives
- **THEN** history is not written

### Requirement: Log rotation at session start
On `SessionStart` the hook SHALL move `history.tsv` to `history.tsv.1` (replacing any file there) when it is larger than 5 MiB, and SHALL do the same for `events.tsv` when the event stream is on. A file at or below that size SHALL be left in place and appended to.

#### Scenario: An oversized history
- **WHEN** `history.tsv` is 6 MiB and a `SessionStart` arrives
- **THEN** it becomes `history.tsv.1`
- **AND** a fresh `history.tsv` holds the one new line

#### Scenario: A small history
- **WHEN** `history.tsv` is a few bytes
- **THEN** it is not rotated and gains a line

### Requirement: SessionEnd of a session
On `SessionEnd` of the main agent the hook SHALL delete the session's record, its subagent files (`sub/<key>.*`) and its prompt-time file, and unset `@agent` on its pane when it has one, but only when field 3 of the record in its key is empty or the session id; a record naming another conversation is left alone with its subagent files and pane option. A `SessionEnd` carrying an `agent_id` removes only that subagent's file.

#### Scenario: A normal end
- **WHEN** `SessionEnd` arrives for the session in pane `%7`
- **THEN** `7.tsv`, `sub/7.*` and `prompt/7` are gone
- **AND** `@agent` is unset on `%7`

#### Scenario: Someone else's record
- **WHEN** the record in the hook's key names a different session
- **THEN** it and its subagent files are kept
- **AND** `@agent` is not unset

### Requirement: A parent takes its finished children with it
On `SessionEnd` the hook SHALL scan the pane-less records for children whose field 12 equals the ending session's id. A child whose pid in field 8 is not a running process (empty, zero, non-numeric, or no longer alive) SHALL have its record, subagent files and prompt-time file deleted. A child that is still running SHALL be kept; it is then shown at the top level.

#### Scenario: A dead and a live child
- **WHEN** a parent with session id `sid-par` ends while one child's recorded pid is dead and another's is alive
- **THEN** the dead child's record and its subagent files are removed
- **AND** the live child's record is kept
- **AND** the parent's own record is gone

### Requirement: Reading records
The core package SHALL read the state directory (`TA_STATE_DIR` when non-blank, otherwise `~/.claude/agent-state`) as a list of rows, newest first by field 1. Only files named `<digits>.tsv` or `s-<id>.tsv` count, and only their first line. A line with fewer than six fields, a non-numeric time or an unknown state (anything but `new`, `working`, `blocked`, `done`, `gone`, `subdone`) is skipped, as is an unreadable file. A missing directory is an empty list.

#### Scenario: Mixed files
- **WHEN** the directory holds `12.tsv`, `s-sess-b.tsv`, `not-a-key.tsv`, `history.tsv` and a `sub/` directory
- **THEN** only the first two are rows, newest first

#### Scenario: Garbage
- **WHEN** a record's content is `nope`
- **THEN** it yields no row and raises no error

#### Scenario: Missing directory
- **WHEN** the state directory does not exist
- **THEN** reading it returns no rows

### Requirement: Reading the optional fields
A reader SHALL report the fields past the sixth only when the line has them. Field 7 is the account, with its presence reported separately from its value. Field 8 is the pid, reported only when it is a positive integer. Fields 9 to 12 are the log, label, parent key and parent session id. A field the line is too short to hold is reported as absent, which is not the same as present and empty (a child's blanked label is empty, a paned record has no label at all).

#### Scenario: A twelve-field record
- **WHEN** a child's record is read
- **THEN** pid, parent key and parent session id are reported
- **AND** an inherited label that the hook blanked is reported as empty

#### Scenario: A seven-field record
- **WHEN** a paned record is read
- **THEN** pid, log, label and parent are reported as absent

### Requirement: Reading the history
A reader of `history.tsv` SHALL return one row per line with at least six fields, a numeric time and a kind of `start`, `turn` or `end`; other lines are skipped. The seventh field is the parent session id and is empty for lines that have six fields. The label of a session is the label of its latest line that has both a session id and a label.

#### Scenario: A child's line
- **WHEN** a line has a seventh field `sess-d`
- **THEN** the row's parent is `sess-d` and its pane is empty

#### Scenario: Latest label wins
- **WHEN** a session has two lines with different labels
- **THEN** its label is the later one

### Requirement: Cost per event
The hook SHALL start exactly one `jq` per event, which reads the payload from standard input and the clock, so that no `cat` and no `date` is started. On any event other than `SessionStart` (and the re-decisions named above) it SHALL make at most one tmux call, the ring above, and SHALL NOT read the process table, so that the cost of a tool call stays small.

#### Scenario: A tool call
- **WHEN** a `PreToolUse` event arrives for a session whose record exists
- **THEN** exactly one `jq` is started, at most one `tmux`, no `ps`, no `cat` and no `date`
