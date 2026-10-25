## MODIFIED Requirements

### Requirement: Captures are held off while they would mislead
A capture SHALL be skipped, with exit 0, while a restore is placing chats (its lock is younger than 120 seconds; an older lock was left by a restore that died and holds nothing off). It SHALL also be skipped while the server is younger than 300 seconds, the hook has not restored it, `resurrect.auto` is on and `@resurrect-hook-post-restore-all` runs `tagents --resurrect`: a fresh server holds none of its chats, and capturing it would write the empty set a second start would restore from.

#### Scenario: Young server not yet restored
- **WHEN** the server is a few seconds old, `resurrect.auto` is on, `@resurrect-hook-post-restore-all` runs `tagents --resurrect --auto` and the hook has not run
- **THEN** `tagents --resurrect-save` writes no snapshot

#### Scenario: Young server nothing will restore
- **WHEN** the server is a few seconds old, `resurrect.auto` is on, `@resurrect-hook-post-restore-all` is not set or runs something else, and `tagents --resurrect-save` runs by hand
- **THEN** it exits 0 and a snapshot is written

#### Scenario: Restore in progress
- **WHEN** the restore lock exists and is fresh
- **THEN** no capture is written
- **AND** a lock older than 120 seconds does not hold the capture off

## ADDED Requirements

### Requirement: A capture held off by hand says why
A capture held off because the server is young SHALL print one line on standard error, saying that nothing was saved, how many seconds ago the server started and that its resurrect hook has not restored it yet, and exit 0, but only when standard error is a terminal. The same capture runs from the status bar, after a launch and from tmux-resurrect's post-save-layout hook, where a line would land in the status line or a log.

#### Scenario: Held off by hand
- **WHEN** a person runs `tagents --resurrect-save` in a terminal on a young server whose restore hook has not run
- **THEN** one line on standard error says nothing was saved and why, and the exit code is 0

#### Scenario: Held off by the machine
- **WHEN** the same capture is run by the status bar, after a launch or by tmux-resurrect's post-save-layout hook
- **THEN** it prints nothing
