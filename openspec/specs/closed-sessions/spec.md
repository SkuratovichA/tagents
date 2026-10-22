# closed-sessions Specification

## Purpose
Browsing and resuming every Claude Code session that is no longer running, however long ago it stopped, from the dashboard's `ctrl-y` picker and the `tagents --closed-rows` table it is built from.

## Requirements

### Requirement: ctrl-y opens the closed-session picker
`ctrl-y` (the `closed` verb, movable in the `keys:` config block) SHALL open a picker in a popup 90% wide and 85% high, or in the terminal of the caller where a popup cannot open, listing every session that is not running, newest activity first. The picker has the prompt `closed> ` and the header `closed sessions · enter resumes · esc closes`. `esc` closes it and does nothing else.

#### Scenario: Opening
- **WHEN** the user presses `ctrl-y` in the dashboard
- **THEN** a picker titled `closed sessions` opens over the list with a preview on its right half

#### Scenario: Nothing on record
- **WHEN** there is no closed session at all
- **THEN** no picker opens and the message `tagents: no closed sessions on record yet` is shown

### Requirement: A closed session is any that is not running
A session SHALL be offered only when it is not running: one with a live pane, or a pane-less one whose recorded process is alive, SHALL NOT be offered, since resuming it would start a second conversation on the same transcript. A session started by another agent as a child SHALL NOT be offered either.

#### Scenario: Running session
- **WHEN** a session is running in a pane right now
- **THEN** it is not in `tagents --closed-rows`

#### Scenario: Running headless session
- **WHEN** a headless session's process is alive
- **THEN** it is not offered either

#### Scenario: Child session
- **WHEN** the session history marks a session as started by a parent session
- **THEN** it is never offered

### Requirement: Sessions are joined from files that already exist
The set SHALL be built by joining by session id the hook's `history.tsv` in the state directory (and its rotated copy `history.tsv.1`), which gets a line per session start, turn end and session end, and each account's own `history.jsonl`, which has a line per prompt typed. A session SHALL stay browsable as long as either file remembers it. A `history.jsonl` line that is not valid JSON, such as a half-written last one, SHALL be skipped without hiding the rest.

#### Scenario: Either file suffices
- **WHEN** a session appears only in the prompt log of an account
- **THEN** it is listed with source `prompts`, and when only in `history.tsv` with source `history`, and when in both with source `both`

#### Scenario: Half-written line
- **WHEN** the last line of a `history.jsonl` is cut off
- **THEN** every other session in that file is still listed

### Requirement: A closed session is named the way the dashboard names it
The name of a closed session SHALL be, in order: the label the user gave with `ctrl-r` or `tagents --label`; the name announced by `$TA_LABEL` at launch, recorded in the history; the session's first prompt, first line, cut to 60 characters; and the bare session id.

#### Scenario: Label beats prompt
- **WHEN** a session was named `my named one` and its first prompt was something else
- **THEN** its name is `my named one`

#### Scenario: First prompt
- **WHEN** a session has no label and its first prompt was `first prompt of the old one`
- **THEN** that is its name

### Requirement: The account of a closed session is the one it ran on
A closed session's account SHALL be the profile whose account's `history.jsonl` holds its prompts, else the profile that claims the config directory of its surviving state record, else `?`. Its badge SHALL be that profile's badge, and `?` for an unknown account. The file a prompt is in is the answer to which login can resume it.

#### Scenario: Work session
- **WHEN** a session's prompts are in the history of the profile `work`
- **THEN** its account column is `work`

#### Scenario: Personal session
- **WHEN** a session's prompts are in the history of the profile `personal`
- **THEN** its account column is `personal` and its badge `p`

### Requirement: A closed session remembers the directory it last ran in
The directory of a closed session SHALL be the working directory of the newest history line that carries one, so a session resumed somewhere else lives where it ran last; otherwise the project recorded in its prompt log; otherwise empty.

#### Scenario: Directory from history
- **WHEN** the hook recorded a working directory for the session
- **THEN** `--closed-rows` carries it in the directory column

#### Scenario: Directory from the prompt log
- **WHEN** only the prompt log knows the session
- **THEN** the directory column is the prompt log's project

### Requirement: `tagents --closed-rows` is the machine-readable table
`tagents --closed-rows` SHALL print one line per closed session, newest activity first, of eight TAB-separated fields: session id, last activity (epoch seconds), first seen (epoch seconds), account, badge, name, directory, and source. The table SHALL be capped at `TA_CLOSED_MAX` rows (default 300).

#### Scenario: Newest first
- **WHEN** two sessions are closed
- **THEN** the one with the later last activity comes first

#### Scenario: Cap
- **WHEN** `TA_CLOSED_MAX=2` and five sessions are closed
- **THEN** only the two newest are printed

### Requirement: Each picker line is readable at a glance
Each line of the picker SHALL show the age of the last activity in minutes below an hour, then hours below a day, then days (`12m`, `3h`, `5d`), the account badge, the name padded to the longest name (at most 34 characters, cut with `…`), the directory with `~` for the home directory, and the first eight characters of the session id. The line is searchable text.

#### Scenario: Line
- **WHEN** a session named `fix the build` ran in `~/projects/app` two hours ago on the personal account
- **THEN** its line reads like `2h  p  fix the build  ~/projects/app  a1b2c3d4`

### Requirement: The preview is the conversation
For the line under the cursor the picker SHALL show on its right half, via `tagents --closed-preview SESSION [PROFILE] [DIR]`: the session id in bold, the directory with `~`, a blank line, and the last ten prompts of that session from the account's prompt log, oldest of the ten first, each cut to its first line of at most 120 characters. Another session's prompts SHALL NOT appear.

#### Scenario: Prompts
- **WHEN** the preview is asked for a session with two prompts
- **THEN** both appear and the directory with them

#### Scenario: Cost
- **WHEN** usage tracking is on and `tusage` still has the session
- **THEN** the first twelve lines of its cost table follow the prompts

#### Scenario: Account unknown
- **WHEN** the profile argument is empty or `?`
- **THEN** the prompt logs of every account are searched

#### Scenario: Isolation
- **WHEN** another session shares the prompt log
- **THEN** its prompts are not in this preview

### Requirement: enter resumes the chosen session on the account it ran on
`enter` SHALL resume the picked session with `claude --resume <id>` on the account it ran on, in the directory it last ran in, in a new window of the tmux session of the group the dashboard cursor was in (the session of the client when it was on the group `no window`), and select it as `enter` on a live agent would. The command is built by the `accounts` capability and the launch is `chat-launch`'s. Afterwards the dashboard list SHALL reload.

#### Scenario: Work session
- **WHEN** the user picks a session of the profile `work`, which has no config directory
- **THEN** it is started with `--resume <id>` with no `CLAUDE_CONFIG_DIR` set, in its directory

#### Scenario: Personal session
- **WHEN** the user picks a session of the profile `personal`
- **THEN** it comes back on that profile's config directory

#### Scenario: Unknown account
- **WHEN** the session's account is `?`
- **THEN** it is resumed on the default login and not on a profile called `?`

#### Scenario: Owning session
- **WHEN** the dashboard cursor was on a row of the tmux session `proj`
- **THEN** its new window is created in `proj`

### Requirement: A vanished directory is no reason to refuse
When the directory a session last ran in no longer exists, resuming SHALL show `tagents: <dir> is gone — resuming in ~` and start the session in the home directory.

#### Scenario: Gone
- **WHEN** the directory was removed after the session ended
- **THEN** the session still resumes, with the home directory as its working directory

### Requirement: Choosing nothing resumes nothing
When the filter matches no line, or the picker is closed with `esc`, no session SHALL be started and no window opened.

#### Scenario: No match
- **WHEN** the filter is `zzz`
- **THEN** nothing is started

### Requirement: The picker is not the list's closed rows
The closed rows inside the dashboard list SHALL still expire after `TA_DEAD_TTL` (24 hours), while the picker keeps a session for as long as either history file remembers it.

#### Scenario: Older than the list
- **WHEN** a session ended three days ago
- **THEN** it is absent from the list and present in the picker
