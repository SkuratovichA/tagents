# resurrect Specification

## Purpose
After a reboot or any other loss of the tmux server, every Claude chat that had a pane comes back at the same session, window and pane, resumed on the login it ran on with the model it was set to. tagents keeps a snapshot of the live chats keyed by session id, and a restore turns the idle shells that tmux-resurrect leaves behind back into `claude --resume`.

## Requirements

### Requirement: A snapshot holds one row per live chat
A capture SHALL write one `A` row per live chat that has a state record with a session id, whether tagents started the chat or it was typed by hand. A pane that has a record but no Claude process, and the sidebar, SHALL get no row. A row is a tab-separated line of 14 columns, listed in the next requirement.

#### Scenario: Two chats and a pane that only has a record
- **WHEN** two panes run Claude with state records and a third pane runs `sleep` with a record left behind
- **THEN** the snapshot has exactly two `A` rows, each of 14 columns
- **AND** the `sleep` pane has no row

#### Scenario: The default account is recorded as present but empty
- **WHEN** a chat ran on the default login
- **THEN** its config directory column is empty and its account-recorded column is `1`

#### Scenario: Model and effort are carried
- **WHEN** a chat's status line recorded a model and it was started with `--effort high`
- **THEN** its row carries the model in column 13 and a command line containing `--effort high` in column 14

### Requirement: The columns of a row
The 14 columns of an `A` row SHALL be, in order: `A`, the session id, the Claude config directory the chat ran on, `1` when that account was recorded, the tmux session name, the window index, the pane's place in its window, the window name, tagents' own name for it, the working directory, `p` when the place skips the sidebar (older snapshots: empty or `1`), `1` when the notes editor was beside the chat, the model, and the command line it started with, tabs and newlines turned into spaces.

#### Scenario: Column positions
- **WHEN** a chat in session `proj`, window 1, pane 1 named `Alpha` runs in a directory `~/projects/app`
- **THEN** column 5 is `proj`, column 6 is `1`, column 7 is `0`, column 8 is `Alpha`, column 10 is the directory and column 11 is `p`

#### Scenario: An old snapshot
- **WHEN** a snapshot written before this change holds `1` in column 11 of a row
- **THEN** the restore reads column 7 as a tmux pane index and the chat comes back undocked, as every chat does

### Requirement: Window names travel only when tagents named the window
The tagents-name column SHALL be filled only when the window's current name still equals the name tagents gave it; a name that a person typed over it SHALL be left out, so a restore does not hand a typed name back to the naming sweep.

#### Scenario: A typed name
- **WHEN** a window carries a tagents name `Stale` but is now called `Hand`
- **THEN** the row records window name `Hand` and an empty tagents-name column

### Requirement: Rows are ordered and a capture replaces the last one
A capture SHALL be a full replacement, never a merge. The `D` row, when there is one, SHALL come first, and the `A` rows SHALL be sorted by tmux session name, then window index, then pane index, so an unchanged set reads the same whatever order the process list returned its chats in. A capture that says exactly what the newest snapshot already says SHALL NOT be written. A capture that fails SHALL leave the newest good snapshot where it was.

#### Scenario: Same set twice
- **WHEN** `tagents --resurrect-save` runs twice with nothing changed in between
- **THEN** one snapshot file exists

#### Scenario: Changed set
- **WHEN** a chat is moved to another window between two captures
- **THEN** the second capture is written as a new file

### Requirement: Snapshots live in the state directory
Snapshots SHALL be files named `<epoch seconds>.tsv` in the `resurrect` directory of the state directory (`~/.claude/agent-state` unless `TA_STATE_DIR` says otherwise), named after the second they were written. The newest `TA_RESURRECT_KEEP` snapshots (default 50) SHALL be kept, plus the one a restore on the current tmux server would read, however old it is. Older ones SHALL be removed after a successful capture.

#### Scenario: Pruning
- **WHEN** `TA_RESURRECT_KEEP=2` and four snapshots written after the server started exist and a fifth capture is taken
- **THEN** two snapshots remain

#### Scenario: The snapshot a restore would read survives pruning
- **WHEN** the same pruning happens and there is one older snapshot written before the server started
- **THEN** that older snapshot is kept as well, three in all

### Requirement: Which snapshot a restore reads
A restore SHALL read the newest snapshot written strictly before the current tmux server started (the server's start time), so captures taken after a boot cannot shadow the set that was running before it. A snapshot written in the server's own first second is not before it.

#### Scenario: Pre-start snapshot is picked
- **WHEN** one snapshot predates the server start and a newer one was written after it
- **THEN** the older one is the one a restore reads

#### Scenario: Only post-start snapshots
- **WHEN** no snapshot predates the server start
- **THEN** there is no snapshot to restore from

### Requirement: Captures taken by the machine and by hand
`tagents --resurrect-save` SHALL take one capture, exit 0 when it wrote one or had nothing to change or was held off, and exit non-zero when there is no tmux server or the capture failed. The same capture SHALL run on every tmux-resurrect save through its post-save-layout hook, a few seconds after every chat launched or hung up by tagents (5 seconds), and from the status bar. Arguments passed to it are ignored.

#### Scenario: By hand
- **WHEN** `tagents --resurrect-save` runs on a server with two chats
- **THEN** it exits 0 and a snapshot file exists

#### Scenario: Launch and kill
- **WHEN** an agent is started with `tagents --new` and later killed from the list
- **THEN** the chat is in a snapshot within seconds of its record being written
- **AND** it is out of the snapshot within seconds of the kill

#### Scenario: No server
- **WHEN** there is no tmux server
- **THEN** `tagents --resurrect-save` exits non-zero and writes nothing

### Requirement: The status bar captures at the configured interval
The status bar SHALL start a capture every `resurrect.every` seconds (default 300; `TA_RESURRECT_EVERY` overrides the config), throttled by a time stamp so that several clients redrawing at once start one. A value of `0`, or anything that is not a positive number, SHALL turn the periodic capture off, with no stamp written. A capture that is not yet due SHALL NOT be taken even if the set of chats changed; the next due one takes it.

#### Scenario: Off
- **WHEN** `resurrect.every` is `0` and the status bar is drawn
- **THEN** no snapshot is written

#### Scenario: Due and not due
- **WHEN** `resurrect.every` is 1 and the status bar is drawn after the set changed
- **THEN** a new snapshot is written and the stamp is updated
- **AND** with `resurrect.every` at 3600 a changed set is not captured

### Requirement: Captures are held off while they would mislead
A capture SHALL be skipped, with exit 0, while a restore is placing chats (its lock is younger than 120 seconds; an older lock was left by a restore that died and holds nothing off). It SHALL also be skipped while the current tmux server is younger than 300 seconds, has not been restored by the hook yet, and `resurrect.auto` is on: a freshly started server holds none of its chats, and capturing it would write the empty set that a second server start would restore from.

#### Scenario: Young server not yet restored
- **WHEN** the server is a few seconds old, `resurrect.auto` is on and the hook has not run
- **THEN** `tagents --resurrect-save` writes no snapshot

#### Scenario: Restore in progress
- **WHEN** the restore lock exists and is fresh
- **THEN** no capture is written
- **AND** a lock older than 120 seconds does not hold the capture off

### Requirement: A capture after a restore
After a restore that resumed at least one chat, a capture SHALL be taken 15 seconds later, once the resumed chats have written their records. A restore that resumed nothing, and a dry run, SHALL schedule none.

#### Scenario: Retake
- **WHEN** a restore resumed one chat
- **THEN** a snapshot holding that chat is written shortly afterwards

### Requirement: Reading the raw rows
`tagents --resurrect-rows` SHALL print the rows a restore would read (the pre-start snapshot) on stdout, `tagents --resurrect-rows latest` the newest snapshot of all, and `tagents --resurrect-rows <file>` that file. When there is nothing to print it SHALL print nothing on stdout, a reason on stderr (`tagents: no snapshot from before this tmux server started`, `tagents: no snapshot yet`, or `tagents: no snapshot at <file>`) and exit 1.

#### Scenario: Latest
- **WHEN** `tagents --resurrect-rows latest` runs after a capture
- **THEN** it prints exactly that snapshot

#### Scenario: Nothing before the start
- **WHEN** every snapshot was written after the server started
- **THEN** `tagents --resurrect-rows` prints nothing, says so on stderr and exits 1

### Requirement: The restore command
`tagents --resurrect [--dry-run] [--auto] [--from <file>|latest]` SHALL resume every `A` row of the chosen snapshot that is not already running. Without `--from` it reads the pre-start snapshot; `--from latest` reads the newest snapshot; `--from <file>` reads that file. By hand it runs whenever it is asked to, on a server of any age. An unknown option SHALL exit 2 with `tagents --resurrect: unknown option <x>` on stderr.

#### Scenario: Unknown option
- **WHEN** `tagents --resurrect --bogus` runs
- **THEN** it exits 2 and names the option

#### Scenario: Empty snapshot
- **WHEN** `tagents --resurrect --from <empty file>` runs
- **THEN** it prints `tagents: nothing recorded in <file>` and exits 0

#### Scenario: No snapshot to read
- **WHEN** there is no snapshot from before the server started
- **THEN** it prints `tagents: no snapshot from before this tmux server started — nothing to resurrect` and exits 0
- **AND** with `--from latest` and no snapshot at all it prints `tagents: no snapshot yet` and exits 0

#### Scenario: Server restarted
- **WHEN** a server restarts and `tagents --resurrect` runs
- **THEN** every recorded chat is resumed at its recorded session, window and pane

### Requirement: A chat is resumed on the login it ran on
A restored chat SHALL be started on the account its row recorded, never on the account rules and never through a dialog. The row's config directory is used as it was recorded, even when no profile claims it, and an empty recorded directory means the default login. The `accounts` capability states how the command is built.

#### Scenario: Recorded login
- **WHEN** a row recorded config directory `X` that a profile claims
- **THEN** the chat runs with `CLAUDE_CONFIG_DIR` set to `X`

#### Scenario: Recorded default login
- **WHEN** a row recorded an empty directory with the account-recorded flag `1`
- **THEN** `CLAUDE_CONFIG_DIR` is unset for the chat

### Requirement: A row from before the account was recorded
For a row whose account-recorded flag is not `1`, the transcript SHALL be looked for on the login a hand-typed `claude` would get (the one named by the restoring process's `CLAUDE_CONFIG_DIR`, else `~/.claude`). When the account rules for such a row would ask, the chat SHALL be started on the default login and the report line SHALL carry the note `account not recorded, default login`.

#### Scenario: Old row, no transcript on the default login
- **WHEN** the row has no recorded account and no transcript for its session exists on the default login
- **THEN** the chat is skipped with `transcript gone`

#### Scenario: Old row with a transcript
- **WHEN** the transcript exists on the default login and the rules say ask
- **THEN** the chat is resumed with `CLAUDE_CONFIG_DIR` unset
- **AND** the report notes `account not recorded, default login`

### Requirement: Model and effort are replayed
A restored chat SHALL be started with `--model <recorded model>` when the row has a model, and with `--effort <value>` when the recorded command line carried `--effort <value>` or `--effort=<value>`. Nothing is passed for a column that is empty. An `/effort` chosen inside a session is not recorded and so not replayed; the permission mode comes back by itself with `--resume`.

#### Scenario: Both flags
- **WHEN** a row has model `claude-opus-5-5` and its command line had `--effort high`
- **THEN** the resumed command contains `--resume <sid>`, `--model claude-opus-5-5` and `--effort high`

#### Scenario: Equals spelling
- **WHEN** the recorded command line had `--effort=max`
- **THEN** the resumed command contains `--effort max`

#### Scenario: No model recorded
- **WHEN** the row's model is empty
- **THEN** the resumed command has no `--model`

### Requirement: Where a chat goes back
A chat SHALL be placed at its recorded place in the window `session:window` when that pane is an idle shell with no tagents or tnotes marker on it and is not titled `tagents-sidebar`: the pane is replaced in place by the resumed command, and nothing is typed into the shell. Otherwise (the pane is busy, the sidebar, an editor, gone, or the row has no window and pane) the chat SHALL get a new window in its session, and when the session is gone, a new session of that name.

#### Scenario: Idle shell
- **WHEN** tmux-resurrect left an idle shell at the recorded pane
- **THEN** the chat runs in that pane and no window is added

#### Scenario: Busy pane
- **WHEN** the recorded pane runs `sleep`
- **THEN** the chat gets a new window in the same session and the `sleep` pane keeps running

#### Scenario: A joined chat
- **WHEN** a row has a session and empty window and pane columns
- **THEN** the chat gets a new window in that session

#### Scenario: Bare server
- **WHEN** tmux-resurrect has not run and the server has none of the recorded sessions
- **THEN** the restore creates the missing sessions

#### Scenario: Session gone
- **WHEN** the recorded session does not exist
- **THEN** a new session of that name is created holding the chat

### Requirement: The other panes of a restored window are left alone
The other panes of the window, which tmux-resurrect brings back as idle shells in their working directories, SHALL be left as they are, and a pane running anything but a shell SHALL never be touched.

#### Scenario: A shell beside the chat
- **WHEN** the recorded window also had a shell pane that tmux-resurrect brought back
- **THEN** the shell is untouched, an idle shell in its working directory, and the chat runs in its own pane

### Requirement: Names come back
After placing a chat the restore SHALL stamp the recorded tagents name on its window again so the naming sweep keeps following the agent. A window name that was typed SHALL go back as a plain name, and only when the window had to be made anew.

#### Scenario: Tagents name
- **WHEN** a row has tagents name `Alpha`
- **THEN** the restored window is named `Alpha` and tagents' name is set on it

#### Scenario: Typed name in a surviving window
- **WHEN** the row has only window name `Hand` and the window already has that name
- **THEN** the name stays `Hand` with no tagents name set on it

### Requirement: Chats that need nothing, or cannot be resumed, are skipped
A chat whose session id is already running SHALL be skipped and reported as `already running`. A chat whose transcript no longer exists SHALL be skipped and reported as `transcript gone`: the transcript is looked for in any project of the recorded login. A chat whose pane could not be opened SHALL be skipped. A skipped chat counts as skipped in the totals and nothing is launched for it.

#### Scenario: Restore on the same server
- **WHEN** `tagents --resurrect` runs while both recorded chats are running
- **THEN** both are reported `already running` and nothing is launched

#### Scenario: Transcript gone
- **WHEN** no project of the login holds `<sid>.jsonl`
- **THEN** the chat is reported `transcript gone — skipped` and nothing is launched

### Requirement: A directory that is gone
When a row's working directory no longer exists the chat SHALL be resumed in `$HOME` and the report line SHALL say `<directory> is gone, resumed in ~`.

#### Scenario: Missing directory
- **WHEN** a row's directory is `/nonexistent`
- **THEN** the chat runs with `$HOME` as its working directory and the report says `/nonexistent is gone, resumed in ~`

### Requirement: A resumed pane drops the record its previous chat left
The command run in a resumed pane SHALL first delete the state record stored under that pane's number, so nothing reads the previous chat's session id there before the resumed chat writes its own.

#### Scenario: Stale record
- **WHEN** a restored pane number has a record from before the reboot
- **THEN** that record is gone before `claude` starts and the record that exists afterwards is the resumed chat's

### Requirement: Dry run
`--dry-run` SHALL print what the restore would do, one `✓ would resume <session>:<window>.<pane> <name> [<sid>]` line per chat followed by the command, launch nothing, open no window, take no lock and write no log.

#### Scenario: Dry run
- **WHEN** `tagents --resurrect --dry-run --from latest` runs
- **THEN** it lists the chats that would come back with their commands
- **AND** nothing is launched and no window is opened

### Requirement: One restore at a time
A real restore SHALL take a lock so that a hook and a hand-typed run never resume the same chat twice. When the lock is held by a younger-than-120-seconds holder it SHALL print `tagents: another resurrect is running` and exit 1. A lock older than 120 seconds SHALL be taken over. The lock SHALL be released when the restore ends.

#### Scenario: Held lock
- **WHEN** another restore holds a fresh lock
- **THEN** `tagents --resurrect` prints that another resurrect is running and exits 1

#### Scenario: Released
- **WHEN** a restore finishes
- **THEN** the lock no longer exists

### Requirement: The report
Each recorded chat SHALL get one line: `✓ <session>:<window>.<pane> <name> → <new pane id>` followed by `(<profile>)` when a profile was used, the model, and any note; `– <session>:<window> <name>: already running` or `transcript gone — skipped`; or `! <session>:<window>: could not open a pane — skipped`. The run ends with `tagents: <n> resumed, <k> skipped, <total> recorded (<snapshot path>)` and exits 0.

#### Scenario: Two chats resumed
- **WHEN** both recorded chats are resumed
- **THEN** there are two lines starting with `✓` and the last line is `tagents: 2 resumed, 0 skipped, 2 recorded (…)`

### Requirement: Notes editors
After the chats are up, the restore SHALL close the notes editors that tmux-resurrect brought back with nothing linking them to a chat: in each restored chat's window the pane in the notes directory that no chat links to, and the whole session `ta-notes` when a save of an older version brought it back. It SHALL then ask `tnotes toggle <pane>` once for each restored chat whose editor was beside it.

#### Scenario: Orphans closed and one editor reopened
- **WHEN** a restored chat's window holds an unlinked pane in the notes directory, two unlinked editors sit in a returned `ta-notes` session, and one restored chat had its editor beside it
- **THEN** the unlinked pane and the `ta-notes` session are closed, and tnotes is asked once for that chat's pane

#### Scenario: Report lines
- **WHEN** tnotes reopens the editor, or fails to
- **THEN** the report says `✓ notes beside <pane>`, or `! notes for <pane> did not reopen — prefix C-t`

#### Scenario: Off
- **WHEN** `resurrect.notes` is `off`
- **THEN** the chats are still restored, the orphans are left and tnotes is not asked
- **AND** any other value of `resurrect.notes`, or none, means `reopen`; a missing `tnotes` is not an error

#### Scenario: A window named for the holder plus a Cyrillic letter
- **WHEN** an unlinked editor in a returned `ta-notes` session sits in a window named `holdя`
- **THEN** it is closed with the rest of the session

### Requirement: The hook restore
`tagents --resurrect --auto` is what tmux-resurrect's post-restore-all hook runs. It SHALL print nothing on the terminal and append its report to `resurrect.log` in the state directory, each run headed by a `== <date time> ==` line, keeping the last 2000 lines from earlier runs. It SHALL do nothing at all, silently, when `resurrect.auto` is false. After a restore it SHALL show `tagents: resurrected <n> agents, <k> skipped — <log path>` in the tmux status line.

#### Scenario: Off
- **WHEN** `resurrect.auto` is `false` and `tagents --resurrect --auto` runs
- **THEN** it prints nothing, launches nothing and writes no log

#### Scenario: On
- **WHEN** `resurrect.auto` is on and a young server is restored
- **THEN** nothing is printed and the log holds the `✓` line for each chat

#### Scenario: Log trimming
- **WHEN** the log already holds more than 2000 lines
- **THEN** only its last 2000 lines remain before the new run's lines are added

### Requirement: The hook restores once per server and only a young one
The hook restore SHALL run once per tmux server: the server's start time is written to `.resurrect.done` in the state directory before anything is placed, and a later `--auto` on the same server SHALL log `already restored on this server — skipped` and do nothing. It SHALL restore only on a server younger than 300 seconds (`TA_RESURRECT_YOUNG`); on an older one it SHALL log that this is a manual restore and not a boot, skip, and still stamp the server so it is not asked twice.

#### Scenario: Second hook run
- **WHEN** `--auto` runs a second time on the same server
- **THEN** the last log line says it was already restored and nothing is launched

#### Scenario: No server
- **WHEN** `--auto` runs with no tmux server
- **THEN** the log says `no tmux server to restore into` and the exit code is 0

#### Scenario: Old server
- **WHEN** the server has been up for hours when the hook fires
- **THEN** the log says `not a boot`, nothing is launched and the server is stamped

### Requirement: Configuration keys
The `resurrect:` section of the config SHALL steer this capability, every key optional: `auto` (default true: the hook restores; the words `false`, `no`, `0` and `off` turn it off and anything else counts as on; `tagents --resurrect` by hand works either way), `every` (seconds between status-bar captures, default 300, 0 is never), and `notes` (`reopen` by default, or `off`). `TA_RESURRECT_EVERY` overrides `every`. Values `--check` cannot read are reported by the `configuration` capability.

#### Scenario: Defaults
- **WHEN** the config has no `resurrect:` section
- **THEN** the hook restores, the status bar captures every 300 seconds and notes editors are reopened

#### Scenario: Auto off keeps the manual restore
- **WHEN** `resurrect.auto` is `false`
- **THEN** the hook does nothing but `tagents --resurrect` by hand still restores

### Requirement: Hooking into tmux-resurrect
Two tmux options, set by the user's tmux configuration as the README shows (tagents sets neither itself), SHALL wire both halves: `@resurrect-hook-post-save-layout` set to `tagents --resurrect-save` and `@resurrect-hook-post-restore-all` set to `tagents --resurrect --auto`, after the tmux-resurrect plugin settings. The first captures on every tmux-resurrect save and the second restores once the layout is back after a start.

#### Scenario: Planned reboot
- **WHEN** a person presses `prefix + C-s` before rebooting and starts tmux afterwards
- **THEN** a snapshot was taken at the save, and the hook then resumes the chats and the status line says how many came back

### Requirement: What does not come back
A restore SHALL NOT bring back scrollback, an `/effort` set inside a session, a chat on a login without the state hook (it has no record), headless sessions (`s-*`), the commands of the user's other panes (tmux-resurrect returns them as idle shells), a chat's joined position (it comes back in a window of its own), or a shell under the resumed chat: the pane runs `claude --resume` itself, so `/exit` closes the pane. A chat hung up on purpose through tagents SHALL be out of the next snapshot.

#### Scenario: Headless session
- **WHEN** a headless session was running before the reboot
- **THEN** it has no row and is not resurrected

#### Scenario: A dev server beside the chat
- **WHEN** a window held a chat and a pane running a dev server
- **THEN** the dev server pane comes back as an idle shell and its command is not run

### Requirement: Snapshots from the seat-based version still restore
A snapshot written before windows became rows SHALL restore: its docked column is read and ignored, a chat that was docked comes back at the session, window and pane recorded for its home seat, and its `D` row is handled like any other.

#### Scenario: A docked chat in an old snapshot
- **WHEN** a snapshot holds a row with `1` in the docked column for a chat whose home seat was pane 1 of window 1 of session `proj`
- **THEN** the restore places the chat at `proj:1.1` as it would any other chat

### Requirement: Chats are filed where their panes are
A capture SHALL record each chat at the session name and window index that tmux reports for its pane, and at its place among the panes of that window that are not the sidebar (the pane titled `tagents-sidebar`, or the live list): the number of such panes before it, from 0, with the user's panes counted. The sidebar moves between windows, so an index that counted it would name another pane after a restore.

#### Scenario: A chat beside a shell
- **WHEN** a chat is pane 1 of window 2 of session `proj`, with the sidebar as pane 0 and a shell as pane 2
- **THEN** its row says session `proj`, window 2, place 0, and `p` in column 11

### Requirement: A restore finds a chat's pane by its place
A restore SHALL find the pane at the recorded place among the panes of the window that are not titled `tagents-sidebar`. A row without `p` in column 11 (an older snapshot) holds a tmux pane index, which SHALL be used as it stands, except that a pane titled `tagents-sidebar` is never used.

#### Scenario: The sidebar was elsewhere at the restore
- **WHEN** the snapshot was taken with the sidebar left of the chat, and tmux-resurrect brought the window back as two idle shells without it
- **THEN** the chat runs in the first shell, the second shell is untouched and no window is added

#### Scenario: An old snapshot points at the sidebar's shell
- **WHEN** a row of an older snapshot names a tmux pane index at which an idle shell titled `tagents-sidebar` stands
- **THEN** that pane is not used and the chat gets a new window in its session

### Requirement: A joined chat is filed under its home session
A chat joined into another window with `ctrl-s` SHALL be recorded under the session its `@tagents_joined` names, with the window index and the pane index empty, so that a restore gives it a window of its own there.

#### Scenario: A joined chat
- **WHEN** a chat joined from session `personal` is a pane of a window of session `work`
- **THEN** its row says session `personal` and has empty window and pane columns

### Requirement: The sidebar is filed by its window
When the sidebar is up the snapshot SHALL hold one `D` row of three columns: `D`, the session name and the window index of the window the sidebar is in.

#### Scenario: Sidebar window
- **WHEN** the sidebar is in window 3 of session `work`
- **THEN** the snapshot has the row `D`, `work`, `3`

### Requirement: The notes column says whether the chat has its editor beside it
The notes column SHALL be `1` when the chat's notes editor is a pane of the chat's own window, and empty when the chat has none.

#### Scenario: No editor
- **WHEN** a chat has no notes editor
- **THEN** the notes column of that chat's row is empty

#### Scenario: Editor beside its chat
- **WHEN** the editor is a pane of the chat's window
- **THEN** the notes column is `1`

### Requirement: The sidebar comes back
When the snapshot holds a `D` row, the restore SHALL bring the sidebar back once the chats are placed and report `✓ dashboard`: the list is started as the leftmost full-height pane of the recorded window when that window exists after the restore, and of the window of the first chat restored otherwise. A window that tmux-resurrect left from an older snapshot's dashboard SHALL be an ordinary window and keep what it runs.

#### Scenario: Dashboard row
- **WHEN** the snapshot holds a `D` row whose window is restored
- **THEN** the report says `✓ dashboard` and the list runs as the leftmost pane of that window and claims the sidebar

#### Scenario: The window is gone
- **WHEN** the `D` row names a window that does not exist after the restore
- **THEN** the sidebar is in the window of the first chat restored

### Requirement: The restore closes the sidebar's leftover panes
After the chats and the sidebar are up, the restore SHALL close every idle shell titled `tagents-sidebar` that is not the live list, as the `window-rows` capability says, and SHALL touch no other pane. A dry run SHALL close nothing.

#### Scenario: Shells where the sidebar was
- **WHEN** the snapshot's windows were restored with an idle shell titled `tagents-sidebar` in each
- **THEN** after `tagents --resurrect` those shells are gone and the chats are untouched

#### Scenario: Dry run
- **WHEN** `tagents --resurrect --dry-run` runs
- **THEN** no pane is closed
