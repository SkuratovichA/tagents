## MODIFIED Requirements

### Requirement: What launchd runs
The LaunchAgent SHALL live at `~/Library/LaunchAgents/io.github.skuratovicha.tagents-notify.plist` with that string as its label, whatever icon the helper app was built with, run `tagents-notify run` through the installer's `tagents-notify` command when that command runs this checkout and `node dist/main.js run` otherwise, restart only after a failed exit (`KeepAlive` with `SuccessfulExit` false) and at least 300 seconds apart, and send both output streams to the log file.

#### Scenario: the plist
- **WHEN** install writes the agent
- **THEN** the plist restarts only after a failed exit, at least 5 minutes apart, and passes `plutil -lint`

#### Scenario: hostile characters
- **WHEN** an environment value holds `&`, `<`, `>` or quotes
- **THEN** the plist escapes them

#### Scenario: the installer's command runs this checkout
- **WHEN** `tagents-notify` is found on the `PATH` of the installing shell and the wrapper's text names this checkout's `dist/main.js`
- **THEN** the plist's program is that wrapper and its one argument is `run`

#### Scenario: no command, or another checkout's
- **WHEN** no `tagents-notify` is found, or the one found names another checkout's `dist/main.js`
- **THEN** the plist's program is the node that runs install and its arguments are this checkout's `dist/main.js` and `run`

#### Scenario: the binary disappears
- **WHEN** the plist names the wrapper and the binary is removed by a later update
- **THEN** the next start of the service runs the node program and the plist is not rewritten

### Requirement: Resource use
The service SHALL poll nothing. It holds one file watch on the events stream and one on the options directory, and at most three timed waits: the cache deadline's (only while a deadline is armed, at most 5 minutes), the follower's re-follow (only while the follower is dead) and the rotation grace (2 seconds after the events file rotates). The Rust service also watches the options file when it is a regular file. Each notice costs one tmux invocation and one helper invocation.

#### Scenario: idle
- **WHEN** no session is waiting and the follower is alive
- **THEN** no timed wait is pending

#### Scenario: the Rust service at rest
- **WHEN** the Rust service is idle
- **THEN** it has three threads (the engine, the watch, the signals), and a thread for a tmux, `ps` or helper call only while that call runs; the watch holds, on Linux, the inotify descriptor and the two of its wake pipe, and on macOS the kqueue descriptor, the two of its wake pipe and one open descriptor each for the events file, the options directory and the options file when that is a regular file
