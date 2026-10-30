# notify-service Specification

## Purpose
The running parts of tagents' desktop notifications: the notify service and its lock, the log, the LaunchAgent and the `tagents notify` verbs (install, uninstall, status, test, run), the macOS helper app with its bundle id, icon, permission and alert style, and the behaviour on a platform without a backend. What raises a notice is in the `notify` capability.

## Requirements

### Requirement: The service runs once per machine
`tagents notify run` SHALL run the engine in the foreground, and only one service per machine runs: it takes the lock file `notify.lock` in the state directory, which holds the pid and the start time of its holder. A second service finds a live holder, logs `another notify service holds <file> (pid N); exiting` and exits 0. The lock is released on stop only if it still names this process.

#### Scenario: another service holds the lock
- **WHEN** the lock names a live process with the start time it recorded
- **THEN** `run` exits 0 at once and leaves the lock untouched

#### Scenario: a lock someone else took over
- **WHEN** the lock names another process at stop time
- **THEN** the stop leaves it in place

### Requirement: Stale locks are taken over
A lock whose process is dead, whose pid has been reused by another process (the recorded start time differs), or that cannot be parsed SHALL be stale and be taken over. A lock with no recorded start time that is older than the last boot is stale as well, even when its pid is alive. A lock in the older format, a bare pid, is still read.

#### Scenario: a dead pid
- **WHEN** the lock names a dead pid
- **THEN** the service takes it over and runs

#### Scenario: a reused pid
- **WHEN** the lock names a live pid whose start time differs from the recorded one
- **THEN** the lock is taken over

#### Scenario: an old-format lock
- **WHEN** the lock holds a bare pid of a live process
- **THEN** that process holds it

### Requirement: Stopping the service
`run` SHALL stop on SIGTERM, SIGINT or SIGHUP (a closed terminal). It SHALL stop taking events at once, let a post in flight finish, drop what was queued behind it, release the lock last and switch the events stream off, as the `event-stream` capability describes; only then does it exit.

#### Scenario: stop on SIGTERM
- **WHEN** the service receives SIGTERM
- **THEN** it exits 0 with neither the lock nor the events stream left on

#### Scenario: stop during a post
- **WHEN** a stop arrives while a notice is being posted
- **THEN** the stop completes after that post settles and no later queued event posts

#### Scenario: a stream that will not close
- **WHEN** closing the stream fails
- **THEN** the failure is logged, the lock is still released and the service still finishes

### Requirement: Exit codes of run
`run` SHALL exit 0 when it deliberately does not run (another service holds the lock, backend `none`, an unsupported OS) and when a signal stops it. It SHALL exit 1 when it fails to start, which launchd retries at most every 5 minutes.

#### Scenario: backend none
- **WHEN** the backend is `none`
- **THEN** the service logs `backend none: nothing to post; exiting`, releases the lock and exits 0

#### Scenario: start fails
- **WHEN** the service throws while starting
- **THEN** `run` exits 1 and the lock is released

### Requirement: Events are handled in order
The service SHALL handle events one at a time in the order they arrive, so that a prompt that withdraws a notice never overtakes the post it withdraws.

#### Scenario: a post then a prompt
- **WHEN** a slow post is under way and a `UserPromptSubmit` for the same key arrives
- **THEN** the withdrawal happens after the post

### Requirement: The stream follower comes back
When the stream follower dies the service SHALL follow again after 1 second, then 2, 4 and so on up to 5 minutes. The wait starts over only when the follower heard an event or lived longer than the wait before it. After a successful re-follow the service arms the idle sessions from the state rows, since the events that landed meanwhile are lost.

#### Scenario: follower dies at once, repeatedly
- **WHEN** the follower dies immediately three times
- **THEN** it is followed again after 1, 2 and 4 seconds

#### Scenario: a follower that works
- **WHEN** the follower heard an event before it died
- **THEN** the next wait is 1 second

### Requirement: A failing backend
A notifier that throws SHALL be logged and the next event SHALL still post. A failure is logged once per distinct message and, when posting works again, once more with "posting works again".

#### Scenario: a failing notifier
- **WHEN** the notifier throws for one notice
- **THEN** the failure is logged once and the next event still posts

#### Scenario: the same failure again
- **WHEN** the notifier throws the same message again
- **THEN** it is not logged again

### Requirement: The log lines of the service
The service SHALL write one log line per notice with its kind, key, title and the outcome (`shown`, or `dropped` with the reason), a line per withdrawal naming the id, and lines for held-back prompts, option problems, reloads, failures, `started` (with pid, backend and the options file's state) and `stopping`. Each line is prefixed with an ISO timestamp.

#### Scenario: a notice line
- **WHEN** a `turn_done` notice for key `12` is posted
- **THEN** the log has a line holding `turn_done`, `12`, the title and `shown`

#### Scenario: a withdrawal line
- **WHEN** the notice for key `12` is withdrawn
- **THEN** the log has a `withdraw` line naming `tagents-12`

### Requirement: Where the log goes
Under launchd the service's output and error streams SHALL both go to `~/Library/Logs/tagents/notify.log`. In the foreground they go to the terminal's error stream.

#### Scenario: under launchd
- **WHEN** the service runs from the LaunchAgent
- **THEN** its log lines are appended to `~/Library/Logs/tagents/notify.log`

### Requirement: The log backend
The `log` backend SHALL write each notice as one line `post <id> <kind> <title> <subtitle> <body> click=<command, or terminal> pid=<n or none> <skip-if-frontmost or always>`, with title, subtitle and body as JSON strings, and each withdrawal as `withdraw <id>`. It reports every notice as shown.

#### Scenario: a notice without a pane
- **WHEN** a notice with no pane is posted on the `log` backend
- **THEN** the `post` line holds `click=terminal`

#### Scenario: a multi-line body
- **WHEN** the body has line breaks
- **THEN** the notice is still one line, because the body is a JSON string

### Requirement: Installing the service
`tagents notify install` SHALL, on macOS, in this order: build the helper app if it is stale, ask for notification permission, write and bootstrap the LaunchAgent, wait up to 5 seconds for the service to run and the events stream to be on, then print the status followed by the steps for allowing notifications. Installing again replaces the earlier agent.

#### Scenario: a clean install
- **WHEN** the permission is granted and the service starts within 5 seconds
- **THEN** the status is printed, followed by the steps, and the exit code is 0

#### Scenario: the order
- **WHEN** install runs
- **THEN** the build, the authorization, the agent install, the wait and the status happen in that order

### Requirement: When install fails
`install` SHALL exit 1 and name the cause when the service is not running, the permission is not `authorized`, or the options file is invalid. When another process holds the lock in the service's place it names that pid and the lock file. It exits 1 without doing anything when `dist/main.js` does not exist (`run pnpm build first`) and when the backend is `none`. An invalid options file is reported line by line and the install goes on with the defaults.

#### Scenario: no build
- **WHEN** `dist/main.js` does not exist
- **THEN** install exits 1 with a message that says to run `pnpm build` first

#### Scenario: another process holds the lock
- **WHEN** the agent was started but a different live process holds the lock
- **THEN** install exits 1 and names that pid and the lock file

#### Scenario: the service does not settle
- **WHEN** the service is not running after 5 seconds
- **THEN** install prints what it saw and exits 1

#### Scenario: backend none
- **WHEN** the backend is `none`
- **THEN** install exits 1 and says there is nothing to install

### Requirement: Warnings during install
`install` SHALL warn when tmux is not on `PATH`, since the service then cannot tell whether a pane is on screen, and when `click` is not `focus` and the script a click runs is not an executable file.

#### Scenario: no tmux
- **WHEN** tmux is not on `PATH` at install time
- **THEN** install prints a warning and carries on

### Requirement: What launchd runs
The LaunchAgent SHALL live at `~/Library/LaunchAgents/io.github.skuratovicha.tagents-notify.plist` with that string as its label, whatever icon the helper app was built with, run `node dist/main.js run` at load, restart only after a failed exit (`KeepAlive` with `SuccessfulExit` false) and at least 300 seconds apart, and send both output streams to the log file.

#### Scenario: the plist
- **WHEN** install writes the agent
- **THEN** the plist restarts only after a failed exit, at least 5 minutes apart, and passes `plutil -lint`

#### Scenario: hostile characters
- **WHEN** an environment value holds `&`, `<`, `>` or quotes
- **THEN** the plist escapes them

### Requirement: The environment launchd gives the service
Because launchd inherits nothing from the installing shell, the plist SHALL carry a `PATH` of the directory of the running node, the directory of tmux when found, and the system directories; `HOME`; `LANG` (default `en_US.UTF-8`); `TA_NOTIFY_TAGENTS`; and, when set in the installing shell, `LC_ALL`, `LC_CTYPE`, `TA_STATE_DIR`, `TAGENTS_CONFIG_DIR`, `XDG_CONFIG_HOME`, `TA_CONFIG`, `TMUX_TMPDIR`, `TAGENTS_LOCALE` and `TA_NOTIFY_APP`.

#### Scenario: the state directory is carried
- **WHEN** install runs with `TA_STATE_DIR` set
- **THEN** the service runs with the same state directory

#### Scenario: a default locale
- **WHEN** `LANG` is unset at install time
- **THEN** the plist sets `en_US.UTF-8`

### Requirement: Bootstrap failures
When `launchctl bootstrap` fails with an input/output error (a bootstrap right after a bootout can, while the old process exits), install SHALL make up to three attempts in all, one second apart. A failure after that points at `launchctl enable gui/<uid>/io.github.skuratovicha.tagents-notify` when the label is switched off and at `plutil -lint <plist>` otherwise.

#### Scenario: a transient bootstrap error
- **WHEN** the first bootstrap fails with "Input/output error"
- **THEN** it is retried and install succeeds when a later attempt works

#### Scenario: a disabled label
- **WHEN** all bootstrap attempts fail and the label is listed as disabled
- **THEN** the error says to run `launchctl enable` for the label

#### Scenario: another error
- **WHEN** the bootstrap fails with an error that is not an input/output error
- **THEN** it is not retried

### Requirement: Uninstalling
`tagents notify uninstall` SHALL boot the service out, delete the plist, print `service: removed`, and switch the events stream off with `stream: off`, unless a `tagents notify run` started by hand still holds a live lock, in which case it leaves the stream on and prints `stream: left on, pid <n> holds <lock>`. A lock that names the service just booted out, a dead process, a reused pid or no file does not count as a holder. A service that was not loaded and a plist that is gone are not errors.

#### Scenario: a hand-run service
- **WHEN** a live `tagents notify run` in a terminal holds the lock
- **THEN** the stream stays on and the holder's pid is printed

#### Scenario: the booted service's own lock
- **WHEN** the lock names the service that was just booted out
- **THEN** the stream is switched off

#### Scenario: backend none
- **WHEN** the backend is `none` and an agent is installed
- **THEN** uninstall still reaches and removes it

### Requirement: Purging the helper app
`uninstall --purge` SHALL also delete the helper app and print `app: removed <path>`. Without `--purge` the app is kept. Off macOS, `uninstall` prints `nothing to uninstall on <os>` and exits 0.

#### Scenario: purge
- **WHEN** `uninstall --purge` runs
- **THEN** the service, the plist and the app are removed and the stream is off

#### Scenario: without purge
- **WHEN** `uninstall` runs without `--purge`
- **THEN** the app stays

### Requirement: Status report
`tagents notify status` SHALL print `key: value` lines: `platform`; `backend` as `<configured> (resolved to <name>)`; on macOS `app` (`up to date`, `stale` or `missing`) and `icon` (the path or `none`, with a line of its own for a problem); `permission` (with `alert style: <style>` for the macOS backend); `click` (the script and `ok`, `missing`, or `not used: click is focus`); `service`; `stream` (`on` or `off`); and `options`.

#### Scenario: every key
- **WHEN** status runs on a healthy macOS setup
- **THEN** every key above is printed, once

#### Scenario: the service line
- **WHEN** the service runs
- **THEN** the line reads `loaded, running, pid <n>` with the resident memory in MB

#### Scenario: the other service states
- **WHEN** the agent is not installed, or installed but not loaded, or loaded but not running
- **THEN** the line says `not installed`, `installed, not loaded`, or `loaded, not running (last exit <code>)`

### Requirement: Status options lines and exit code
The `options` line of `status` SHALL show the file and `found`, `not found (defaults)` or `invalid`, with each problem of an invalid file on an indented line of its own. `status` SHALL exit 0 when the service runs, the permission is fine and the options are valid, and 1 otherwise. A permission that cannot be read prints `unknown: <reason>` and counts as not fine.

#### Scenario: everything fine
- **WHEN** the service runs, the permission is `authorized` and the options are valid
- **THEN** the exit code is 0

#### Scenario: denied
- **WHEN** the permission is `denied`
- **THEN** the exit code is 1 and the `permission` line says `denied`

#### Scenario: invalid options
- **WHEN** the options file is invalid
- **THEN** `options:` says `invalid`, each problem follows on an indented line, and the exit code is 1

### Requirement: The test verb
`tagents notify test [--kind <kind>]` SHALL post one sample notice now through the configured backend and wait for the answer. The kind is one of `question`, `permission`, `turn_done`, `cache_expiring` and `session_end`, default `turn_done`. The `enabled` flags of the options are ignored and `skip_visible` is not applied. The sample `cache_expiring` reads 50 minutes idle and 10 left.

#### Scenario: a sample question
- **WHEN** `test --kind question` runs on the `log` backend
- **THEN** it prints `shown` and the log holds a `question` notice

#### Scenario: a disabled kind
- **WHEN** `events.question.enabled` is `false` and `test --kind question` runs
- **THEN** the sample is still posted

### Requirement: The outcome of the test verb
`test` SHALL print `shown` and exit 0, or `dropped: <reason>` and exit 1, or `error: <message>` and exit 1. With backend `none` it prints `error: backend is none, nothing posts`. When `$TMUX_PANE` is set, the notice is that pane's, built from its state row when a hook has recorded it and with an empty session id otherwise, and its click docks that pane. Without a pane the click only raises the terminal.

#### Scenario: in a recorded pane
- **WHEN** `$TMUX_PANE` is `%12` and a state row exists for it
- **THEN** the notice is built from that row and its click docks `%12`

#### Scenario: a plain shell pane
- **WHEN** `$TMUX_PANE` is set and no row exists for it
- **THEN** the click still docks that pane, with an empty session id

#### Scenario: dropped
- **WHEN** the backend answers `shown: false` with a reason
- **THEN** the verb prints `dropped: <reason>` and exits 1

### Requirement: Verbs and the standalone binary
The plugin SHALL provide the verbs `run`, `install`, `uninstall`, `status`, `test` and `send`, as `tagents notify <verb>` once the plugin is registered and as `tagents-notify <verb>` from the package's own binary, which needs no registration, so a LaunchAgent works on a machine where the host never ran. The binary with no verb, or with an unknown verb, exits 2 and lists the verbs.

#### Scenario: no verb
- **WHEN** `tagents-notify` runs with no arguments
- **THEN** it exits 2 and the six verbs appear in its output

#### Scenario: unknown verb
- **WHEN** `tagents-notify bogus` runs
- **THEN** it exits 2 and the output names `bogus`

### Requirement: The macOS helper app and its bundle id
The macOS backend SHALL post through a helper app, `TagentsNotify.app`, kept in `~/Library/Application Support/tagents/` or at `TA_NOTIFY_APP` when that is set. Its bundle id is `io.github.skuratovicha.tagents-notify`, the name System Settings knows its notification settings by. The helper runs once per verb and exits, so no helper process exists while idle.

#### Scenario: the default location
- **WHEN** `TA_NOTIFY_APP` is unset
- **THEN** the app is at `~/Library/Application Support/tagents/TagentsNotify.app`

#### Scenario: an override
- **WHEN** `TA_NOTIFY_APP` names a path
- **THEN** that path is the app

### Requirement: Building the helper app
The helper app SHALL be built from source on install, reported as `up to date`, `stale` or `missing`, and rebuilt only when stale; a changed source or a changed, added or removed icon makes it stale. A build that fails reports the last 20 lines of the build output, with a hint to run `xcode-select --install` when `swiftc` is missing.

#### Scenario: up to date
- **WHEN** the app's recorded digest matches its sources
- **THEN** install does not rebuild it

#### Scenario: no compiler
- **WHEN** the build fails and `swiftc` cannot be found
- **THEN** the error includes the build output and says to run `xcode-select --install`

#### Scenario: an icon added later
- **WHEN** an icon is configured for an app built without one
- **THEN** the app is stale

### Requirement: The configured icon
The `icon` option SHALL name a PNG for the notices' icon, as an absolute path, a `~/` path, or a path relative to the directory of the options file. When it is unset, the icon is `notify-icon.png` beside the helper app when that file exists, and the app has no icon of its own otherwise. `install` prints `icon: <path>` or `icon: none`, as `status` does.

#### Scenario: a relative path
- **WHEN** `icon: icons/tagents.png` is set in the options file
- **THEN** it is read relative to the directory of that file

#### Scenario: the default icon
- **WHEN** `icon` is unset and `notify-icon.png` exists beside the app
- **THEN** that file is the icon

#### Scenario: none
- **WHEN** `icon` is unset and no such file exists
- **THEN** the app has no icon and `icon: none` is printed

### Requirement: The bundle id follows the icon
An icon SHALL give the helper app its own bundle id, `io.github.skuratovicha.tagents-notify.i<first 8 hex of the icon's sha256>`, because macOS keeps an app's icon from its first permission request. Without an icon the bundle id is the base one. After an icon change macOS asks once more for permission, and the old registration stays in System Settings with the old icon.

#### Scenario: the bundle id follows the icon
- **WHEN** an app is built with an icon whose digest starts with `0123abcd`
- **THEN** its bundle id is `io.github.skuratovicha.tagents-notify.i0123abcd`

#### Scenario: no icon
- **WHEN** the app is built without an icon
- **THEN** its bundle id is `io.github.skuratovicha.tagents-notify`

### Requirement: An icon that cannot be used
An `icon` that names no readable file (missing, a directory, unreadable, a dangling link) SHALL be a problem line in `install` and in `status`, and the app is built without it. An icon the build cannot decode makes `install` say which icon failed and build without it.

#### Scenario: a missing file
- **WHEN** `icon` names a file that does not exist
- **THEN** `status` and `install` print a problem that says the app is built without an icon

#### Scenario: an undecodable picture
- **WHEN** the build fails on the icon
- **THEN** install names the icon, builds without it and goes on

### Requirement: Notification permission
The helper SHALL ask macOS for alert and badge permission only, and never for sound. `install` makes macOS ask whether "tagents" may send notifications and waits up to 60 seconds for the answer. `status` reports the permission as `authorized`, `denied`, `notDetermined`, `provisional` or `ephemeral`, and install and status exit 1 when it is not `authorized`.

#### Scenario: not authorized
- **WHEN** the permission is `denied`
- **THEN** `status` exits 1 and says `denied`

#### Scenario: no sound
- **WHEN** a notice is shown
- **THEN** it plays no tone

### Requirement: Posting needs a usable permission
A status of `authorized`, `provisional` or `ephemeral` SHALL let the helper post. Any other status makes a post fail with `not authorized: <status>`, which the service logs as a failing backend.

#### Scenario: a post without permission
- **WHEN** the permission is `denied` and a notice is posted
- **THEN** the post fails with `not authorized: denied` and the engine logs it

### Requirement: Steps for allowing notifications
After `install` the printed steps SHALL be: allow the prompt, or System Settings → Notifications → tagents → Allow notifications; set the Alert Style; know that Focus and Do Not Disturb hide banners while notices still land in Notification Center; check `permission: authorized`. A person not yet authorized sees the Settings step first.

#### Scenario: authorized
- **WHEN** install ends with the permission `authorized`
- **THEN** the prompt step is first

#### Scenario: the prompt was missed
- **WHEN** install ends with the permission not `authorized`
- **THEN** the Settings step comes first and the exit code is 1

### Requirement: Alert style
The helper app SHALL start with the Persistent alert style (`NSUserNotificationAlertStyle` set to `alert`), which keeps a notice on screen until dismissed; the person may change it in System Settings. When the permission is `authorized` and the style is `banner` (Temporary), `status` and `install` SHALL print a hint that notices disappear on their own, with a link that opens the app's settings in System Settings.

#### Scenario: Temporary
- **WHEN** the permission is `authorized` and the alert style is `banner`
- **THEN** a hint says to set Alert Style to Persistent, with the link `x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=<bundle id the helper reported>`

#### Scenario: no bundle id reported
- **WHEN** the helper reported no bundle id
- **THEN** the link uses the base bundle id

#### Scenario: Persistent
- **WHEN** the alert style is `alert`
- **THEN** no hint is printed

### Requirement: Alert style turned off
When the style is `none` and the permission is `authorized`, the hint SHALL say that nothing is shown on screen at all and name the setting. When the permission is not `authorized` no style hint is printed, since the permission line is what to fix.

#### Scenario: Off
- **WHEN** the alert style is `none`
- **THEN** the hint says nothing is shown on screen at all

#### Scenario: not yet authorized
- **WHEN** the permission is `notDetermined`
- **THEN** no style hint is printed

### Requirement: Showing a notice
The helper SHALL show a notice as a banner and in the notification list even when it is itself the foreground app, with the notice's title, subtitle and body, its thread id, and its id as the request id, so that the same id replaces a notice on screen.

#### Scenario: replacement
- **WHEN** a second notice with the same id is posted
- **THEN** it replaces the first

### Requirement: Skipping a notice for a frontmost terminal
When a notice is marked to skip if frontmost and the terminal application above the recorded tmux client pid is the frontmost application, the helper SHALL answer `shown: false` with the reason `frontmost` and show nothing. The terminal is the first ancestor of the client pid that is a regular application.

#### Scenario: frontmost terminal
- **WHEN** a notice marked skip-if-frontmost is posted and its terminal is frontmost
- **THEN** the helper answers `shown: false` with `frontmost`

#### Scenario: another app in front
- **WHEN** the terminal is not the frontmost application
- **THEN** the notice is shown

### Requirement: Handling a click
On a click the helper SHALL bring the terminal application forward and run the notice's command with the notice's environment over its own, with no input, and wait up to 8 seconds before terminating it. A click with no command only raises the terminal.

#### Scenario: a hung child
- **WHEN** the clicked command is still running after 8 seconds
- **THEN** it is terminated

#### Scenario: no command
- **WHEN** the notice's click has an empty command
- **THEN** only the terminal is raised

### Requirement: The click leaves a trace
Each click SHALL leave in the unified log, under the subsystem `io.github.skuratovicha.tagents-notify`, the command it ran, the application it raised, the child's exit status and, when there is any, the first 2 KB of the child's stderr.

#### Scenario: click leaves a trace
- **WHEN** a notice is clicked
- **THEN** `/usr/bin/log show --last 10m --predicate 'subsystem == "io.github.skuratovicha.tagents-notify"'` shows the command, the raised app and the child's exit status

#### Scenario: child stderr
- **WHEN** the clicked command writes to stderr
- **THEN** the first 2 KB of it appear in the log

### Requirement: Withdrawing in the helper
A withdrawal SHALL remove the pending and delivered notices with the given ids and wait up to 3 seconds for the notification center to stop listing them, failing with the ids still listed after that.

#### Scenario: withdraw
- **WHEN** the helper is asked to withdraw `tagents-12`
- **THEN** the notice is gone from the notification center before the helper exits

### Requirement: Helper verbs
The helper binary SHALL provide the verbs `post` (a notice as JSON on stdin), `withdraw <id>...`, `authorize`, `status`, `delivered`, `terminal <pid>` and `icon <in.png> <out.png>`, each printing one JSON line with `ok` and exiting. A failure is `ok: false` with an `error`, which the service turns into an error a person can act on.

#### Scenario: a failure
- **WHEN** a verb fails
- **THEN** it prints `ok: false` with an `error`

#### Scenario: a missing binary
- **WHEN** the helper app is not there
- **THEN** the error names the app and says to run `tagents notify install`

#### Scenario: a timeout
- **WHEN** the helper does not answer within 5 seconds
- **THEN** the error names the number of seconds

#### Scenario: garbage output
- **WHEN** the helper prints something that is not its JSON line
- **THEN** the error shows its stdout and stderr, each cut at 200 characters

### Requirement: Unsupported platforms
Where the platform has no notification backend (any OS but macOS, with backend `auto` or `macos`), the service SHALL refuse to post and say why instead of silently dropping notices. `run` logs `no notification backend for <os> yet; exiting`, follows nothing, releases the lock and exits 0. `install` prints `no notification backend for <os> yet` and exits 2, installing nothing. `test` prints `error: no notification backend for <os> yet` and exits 1.

#### Scenario: install on Linux
- **WHEN** `tagents notify install` runs on Linux
- **THEN** it exits 2 with `no notification backend for linux yet` and installs nothing

#### Scenario: run on Linux
- **WHEN** `tagents notify run` runs on Linux with `backend: auto`
- **THEN** it logs that there is no backend, releases the lock and exits 0

#### Scenario: test on Linux
- **WHEN** `tagents notify test` runs on Linux with `backend: auto`
- **THEN** it prints `error: no notification backend for linux yet` and exits 1

### Requirement: Status and the log backend off macOS
Off macOS `status` SHALL resolve the backend to `unsupported` and print `service: no service manager on <os>`. The `log` backend works on any OS but has a service manager only on macOS.

#### Scenario: status on Linux
- **WHEN** `status` runs on Linux with `backend: auto`
- **THEN** the backend line says `(resolved to unsupported)` and the service line says there is no service manager

#### Scenario: log backend on Linux
- **WHEN** `backend` is `log` on Linux and `test` runs
- **THEN** the notice is written to the log and the verb prints `shown`

### Requirement: Resource use
The service SHALL poll nothing. It holds one file watch on the state directory, one on the options directory, and at most two timers: the cache deadline's (only while a deadline is armed, sleeping at most 5 minutes) and the follower's re-follow timer (only while the follower is dead). Each notice costs one tmux invocation and one helper invocation.

#### Scenario: idle
- **WHEN** no session is waiting and the follower is alive
- **THEN** no timer is pending

### Requirement: The job is filed under the app in Login Items
The plist's `AssociatedBundleIdentifiers` SHALL name the bundle id the installed helper app has, read from the app at install time, so that Login Items files the job under the app; with no app, or when the id cannot be read, it SHALL name `io.github.skuratovicha.tagents-notify`.

#### Scenario: an app built with an icon
- **WHEN** install runs and the helper app was built with an icon
- **THEN** `AssociatedBundleIdentifiers` names `io.github.skuratovicha.tagents-notify.i<8 hex>` and the label stays `io.github.skuratovicha.tagents-notify`

#### Scenario: no icon, no app, or an unreadable app
- **WHEN** the app has no icon of its own, is missing, or its bundle id cannot be read
- **THEN** `AssociatedBundleIdentifiers` names `io.github.skuratovicha.tagents-notify`

### Requirement: The send verb
`tagents notify send <message…> [--title <text>]` SHALL post one notice now through the configured backend and wait for the answer. The message words joined by single spaces are the body, the title defaults to `tagents`, the subtitle is empty, the thread is `tagents`, the kind is `message`, and each send has an id of its own. Without a message it SHALL print a usage error, exit 2 and post nothing.

#### Scenario: a message
- **WHEN** `send The build is green` runs on the `log` backend
- **THEN** it prints `shown` and the log holds one notice titled `tagents` whose body is `The build is green`

#### Scenario: a title
- **WHEN** `send --title Deploy "staging is up, 3 checks passed"` runs
- **THEN** the notice is titled `Deploy` and its body is the one argument whole

#### Scenario: two sends
- **WHEN** `send first` and `send second` run one after the other
- **THEN** two notices with different ids were posted, and neither replaced the other

#### Scenario: no message
- **WHEN** `send` runs with no words
- **THEN** it exits 2, the output says a message is missing and not that the verb is unknown, and nothing is posted

### Requirement: The send verb refuses what a notification cannot show
A title of more than 256 characters or a message of more than 2048 characters (its words joined by single spaces) SHALL be refused with exit 2, a line on standard error naming the limit, and nothing posted. The limits count characters, not bytes. Within them the title and message reach the backend as given, quotes, equals signs and newlines included.

#### Scenario: A title at the limit
- **WHEN** `send` runs with a title of 256 characters
- **THEN** the notice is posted with that title

#### Scenario: A title one over
- **WHEN** `send` runs with a title of 257 characters
- **THEN** it exits 2, the output says the title is over 256 characters, and nothing is posted

#### Scenario: A message at the limit
- **WHEN** `send` runs with words that, joined by single spaces, are 2048 characters
- **THEN** the notice is posted with that body

#### Scenario: A message one over
- **WHEN** `send` runs with words that, joined by single spaces, are 2049 characters
- **THEN** it exits 2, the output says the message is over 2048 characters, and nothing is posted

#### Scenario: Characters, not bytes
- **WHEN** `send` runs with a title of 256 emoji
- **THEN** the notice is posted

#### Scenario: Quotes and a newline
- **WHEN** `send` runs with a title that holds quotes, an equals sign and a newline
- **THEN** the backend receives that title unchanged

### Requirement: The send verb posts what it is told to
The `enabled` flags of the options SHALL be ignored and `skip_visible` SHALL NOT be applied to `send`: someone asked for this notice.

#### Scenario: a disabled kind
- **WHEN** every event kind is switched off in the options and `send hello` runs
- **THEN** the notice is posted

### Requirement: The outcome of the send verb
`send` SHALL answer as `test` does: `shown` and exit 0, `dropped: <reason>` and exit 1, or `error: <message>` and exit 1, and with backend `none` `error: backend is none, nothing posts`. When `$TMUX_PANE` is set the notice's click docks that pane, and without a pane the click only raises the terminal.

#### Scenario: in a tmux pane
- **WHEN** `$TMUX_PANE` is `%12` and `send hello` runs
- **THEN** the notice's click docks `%12`

#### Scenario: outside tmux
- **WHEN** `$TMUX_PANE` is unset
- **THEN** the click only raises the terminal

#### Scenario: dropped
- **WHEN** the backend answers `shown: false` with a reason
- **THEN** the verb prints `dropped: <reason>` and exits 1

#### Scenario: no backend
- **WHEN** the backend is `none`
- **THEN** the verb prints `error: backend is none, nothing posts` and exits 1

### Requirement: The verbs have a structured CLI spec
The package SHALL describe its verbs as a structured CLI spec, which the plugin contract reads, and a test SHALL fail when that spec and the verbs the plugin offers differ in a name, an option, a required option, a positional or an exit code.

#### Scenario: A verb the spec leaves out
- **WHEN** the plugin offers a verb that the CLI spec does not list
- **THEN** the package's tests fail naming the verb

#### Scenario: the spec follows the verbs
- **WHEN** a verb gains an option and the CLI spec is not changed
- **THEN** the package's tests fail naming the verb
