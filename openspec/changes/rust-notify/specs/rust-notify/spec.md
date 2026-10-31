## ADDED Requirements

### Requirement: The service is the verb notify run of tagents-core
`tagents-core notify run` SHALL run the notification service in the foreground until a signal or a deliberate exit, as a verb of the data file with `effect: serve`, so it is not a tool. Any other argument list that starts with `notify` (`notify status`, `notify install`, `notify run extra`) SHALL go to the node CLI, as every word the binary does not serve does.

#### Scenario: The verb
- **WHEN** `tagents-core notify run` runs
- **THEN** it serves until it is stopped, writes its log to stderr and writes nothing to stdout

#### Scenario: Another word
- **WHEN** `tagents-core notify status` or `tagents-core notify run extra` runs
- **THEN** the node CLI answers it

#### Scenario: Not a tool
- **WHEN** the contract and the skill references are generated
- **THEN** they gain the entry of the verb and no tool

### Requirement: The Rust service meets the requirements of the node service
`tagents-core notify run` SHALL meet every requirement of the `notify` and `notify-service` capabilities that concerns the running service: which events raise a notice, how a notice reads, when it is withdrawn, the prompt-cache deadlines, the options, the lock, the stop, the exit codes and the log, except where a requirement below says otherwise; a requirement below wins over the one it departs from, and adds what the port itself promises.

#### Scenario: The same events
- **WHEN** both services run on identical state, options and stub helper and are fed the same events
- **THEN** the helper receives the same calls with the same bytes of input, and the logs are the same lines apart from the time and the pid

#### Scenario: A prompt while a post is in flight
- **WHEN** a post is in flight, the cache deadline of a session passes during it, and then a prompt of that session reaches the events file before the post ends
- **THEN** the prompt is taken in and the deadlines are swept before the due notice runs, so the cache notice of that session is not posted, where the node service posts in this order (a known difference, listed in `docs/architecture/rust-core.md`)

### Requirement: One service per machine, whichever program runs it
The service SHALL take `notify.lock` in the state directory in the node service's format, `<pid> <start time as ps prints it>` or the older bare pid, and judge a holder as the node service does, so a node service and a Rust service on one state directory exclude each other in both directions. A live holder SHALL make it log `another notify service holds <file> (pid <n>); exiting` and exit 0.

#### Scenario: A node service holds the lock
- **WHEN** the lock names a live node service with the start time it recorded
- **THEN** the Rust service logs the line, exits 0 and leaves the lock untouched

#### Scenario: A Rust service holds the lock
- **WHEN** the lock was taken by a Rust service and a node service starts
- **THEN** the node service logs its line, exits 0 and leaves the lock untouched

#### Scenario: A stale lock
- **WHEN** the lock names a dead pid, a live pid whose start time differs, text that cannot be read, or a bare pid older than the last boot
- **THEN** the Rust service takes it over and runs

#### Scenario: A lock taken by another
- **WHEN** the lock names another process at stop time
- **THEN** the stop leaves it in place

### Requirement: A signal ends the service as it ends the node service
The service SHALL register SIGTERM, SIGINT and SIGHUP before it does anything else, so that a signal during start is acted on when start settles and the first signal wins. A stop SHALL log `stopping (<signal name>)` before anything else of the stop (for a signal that comes during start, after `started`, and not at all when the start fails), let a post in flight finish, drop what is queued behind it, remove `events.on`, release the lock last and exit 0.

#### Scenario: A signal during a post
- **WHEN** SIGTERM arrives while the helper is posting a notice
- **THEN** the post finishes, no queued event posts after it, and the service exits 0 with neither the lock nor `events.on` left

#### Scenario: The stopping line comes first
- **WHEN** SIGTERM arrives while the helper is posting a notice
- **THEN** `stopping (SIGTERM)` is logged before the `notice` line of that post

#### Scenario: The name of the signal
- **WHEN** SIGINT or SIGHUP arrives
- **THEN** the line is `stopping (SIGINT)` or `stopping (SIGHUP)`

#### Scenario: A signal during start
- **WHEN** SIGTERM arrives before the service has logged `started` and the start succeeds
- **THEN** the log has `started` and after it `stopping (SIGTERM)`, in that order, and the service exits 0 with neither the lock nor `events.on` left

#### Scenario: A deliberate exit
- **WHEN** the backend is `none`, or the operating system has no backend
- **THEN** the service logs `backend none: nothing to post; exiting` or `no notification backend for <os> yet; exiting`, releases the lock and exits 0

### Requirement: The log is the node service's
The service SHALL write to stderr the lines listed below, as `<ISO time with milliseconds> <the parts joined by a space>` and in the node service's words, `started pid <n> backend <name> options <file> (found|not found|invalid)` being the last line of a start. It SHALL write nothing to stdout and add only the lines of "A start that fails is handed to the node service", and an operating system's text in a line SHALL come from `node::io_message` (`crates/tagents-core/src/node.rs`).

#### Scenario: The started line
- **WHEN** the service starts with an options file that is valid, missing or invalid
- **THEN** the line ends `(found)`, `(not found)` or `(invalid)` and comes after everything else of the start

#### Scenario: A notice line
- **WHEN** a `turn_done` notice for key `12` is posted and shown
- **THEN** the line is `notice turn_done 12 <title as JSON> shown`

#### Scenario: A failing post
- **WHEN** the helper fails to post the same way twice and then succeeds
- **THEN** `post failed <kind> <key> <reason>` is logged once and `posting works again` once

#### Scenario: The lines of a start and a stop
- **WHEN** the service starts, finds a lock held, has no backend, or stops
- **THEN** its lines are `started pid <n> backend <name> options <file> (found|not found|invalid)`, `another notify service holds <file> (pid <n>); exiting`, `backend none: nothing to post; exiting`, `no notification backend for <os> yet; exiting`, `stopping (<reason>)` where the reason is a signal's name or `watch failed: <why>`, `could not release the lock <file> <why>` and `drain failed <why>`

#### Scenario: The lines of the options
- **WHEN** the options are read, reloaded or cannot be watched
- **THEN** its lines are `options: <problem>` for each problem, `options reloaded`, `backend changes take effect after a restart (tagents notify install)`, `options reload is off: <dir> does not exist` and `options watch failed <path> <why>`

#### Scenario: The lines of a notice
- **WHEN** the engine posts, drops, withdraws or holds back a notice
- **THEN** its lines are `notice <kind> <key> <title as JSON> shown`, the same with `dropped` and `: <why>` when there is one, `notice <kind> <key> skipped: tmux has no pane <pane>`, `post failed <kind> <key> <why>`, `posting works again`, `withdraw <id>`, `withdraw failed <id> <why>` and `permission prompt held back by the question on screen <key>`; on the `log` backend a withdrawal writes `withdraw <id>` twice, once from the backend and once from the engine, as the node service does

#### Scenario: The lines of a failing part
- **WHEN** the tmux probe, an event or the follower fails
- **THEN** its lines are `screen probe failed <pane> <why>`, `error <why>`, `feed error <message>`, `follow failed <why> trying again in <n>s`, `arming from the state rows failed <why>` and `feed follower died <message> following again in <n>s`

#### Scenario: The lines of the log backend
- **WHEN** the backend is `log` and a notice is posted
- **THEN** the line is `post <id> <kind> <title JSON> <subtitle JSON> <body JSON> click=<command, or terminal> pid=<n or none> <skip-if-frontmost or always>`, 27 lines in all with the ones above

### Requirement: The events file is followed from its end
The service SHALL create `events.tsv` (mode 0600) and `events.on` when it follows, start at its end, read to the end on every wake and keep a partial line. It SHALL drop a line with fewer than 13 fields, a time that is not a number or an unknown event (a trailing carriage return is tolerated, extra fields are ignored), restart at 0 when the file is shorter than its offset, reopen from 0 when the path names another inode, and rotate at 1 MiB, reading the old `events.tsv.1` for 2 seconds.

#### Scenario: A line in two writes
- **WHEN** a line arrives in two writes with a wake between them
- **THEN** it is handled once, after the second

#### Scenario: A line of 14 fields
- **WHEN** a line with a known event and 14 tab-separated fields is appended
- **THEN** it is handled as a line of 13

#### Scenario: A line that ends in a carriage return
- **WHEN** a line with a known event and 13 fields ends in a carriage return
- **THEN** it is handled as the same line without it

#### Scenario: A line of 12 fields
- **WHEN** a line with a known event and 12 fields is appended
- **THEN** it is dropped and the next line is handled

#### Scenario: A truncated file
- **WHEN** the file is truncated and appended to
- **THEN** the new lines are read from the start

#### Scenario: Rotation
- **WHEN** the file passes 1 MiB while the service follows it
- **THEN** the lines of the new file are handled as they are written, and the lines written to the old file before the 2 seconds end are handled once, when they end, so a line of the new file can be handled before the last lines of the old one, as the node service does

#### Scenario: Two thousand lines in a tight loop
- **WHEN** two thousand events are appended with no pause
- **THEN** every one is handled, in order

### Requirement: Nothing polls
The service SHALL learn of a change to the events file and to the options directory from the operating system (inotify on Linux, kqueue on macOS) and SHALL NOT poll or wake on a timer to look for one. Every arming of a watch SHALL be followed by a read to the end, so that a write between the last read and the arming is not lost.

#### Scenario: An idle service
- **WHEN** nothing is written and no deadline is due for ten seconds
- **THEN** the CPU time of the service's process grows by no more than one clock tick

#### Scenario: A write while a watch is armed
- **WHEN** a line is written between the last read and the arming of the watch
- **THEN** the read that follows the arming handles it

### Requirement: The watch does not follow a symlink
An options file that is a symlink SHALL be noticed when the link is replaced, and an edit of its target SHALL NOT by itself cause a reload: it takes effect at the next reload. The options directory SHALL be watched by its real path, so a config directory that is a symlink into a dotfiles repository works.

#### Scenario: A linked options file is edited
- **WHEN** `notify.toml` is a symlink to a file in another directory, that file is edited, and nothing else happens in the options directory
- **THEN** the service does not reload

#### Scenario: The link is replaced
- **WHEN** the link is replaced by another that points to a file with other values
- **THEN** the service reloads and logs `options reloaded`

#### Scenario: A file edited in place
- **WHEN** `notify.toml` is a regular file and is written in place, with no rename
- **THEN** the service reloads, on macOS as on Linux

### Requirement: An event in the options directory reloads only a changed file
An event in the options directory SHALL make the service read the options file and apply it only when what it read, the bytes of the file, its absence or the failure of the read, differs from what is in force. An unchanged file SHALL log nothing and change nothing.

#### Scenario: An unrelated file
- **WHEN** a file other than `notify.toml` is written in the options directory
- **THEN** the service logs no `options` line and keeps its options

#### Scenario: The file written with the same bytes
- **WHEN** `notify.toml` is written again with the bytes it has
- **THEN** the service logs no `options` line and keeps its options

#### Scenario: The file written with other values
- **WHEN** `notify.toml` is written with other valid values
- **THEN** the service logs `options reloaded`

### Requirement: The options file is read as TOML
`<config dir>/plugins/notify.toml` SHALL be read with the `toml` crate and checked against the schema of the `notify` requirements "Plugin options and defaults", "Invalid options" and "Durations": the same keys, lists and defaults. A duration is a whole number of seconds, as a TOML number or a string of ASCII digits, or a string `<n>h<n>m<n>s` of ASCII digits with each part optional, the total a safe integer; dates, booleans, arrays, tables and non-finite floats are not durations.

#### Scenario: A partial file
- **WHEN** the file says only `click = "goto"`
- **THEN** every other setting is its default

#### Scenario: A whole number written as a float
- **WHEN** `after = 1.0e1`
- **THEN** it means 10 seconds

#### Scenario: A duration that is a date
- **WHEN** `after = 1979-05-27`
- **THEN** the file is invalid with the problem at `events.cache_expiring.after`

#### Scenario: Only a YAML file
- **WHEN** only `plugins/notify.yaml` exists
- **THEN** no YAML is read, every setting is its default and the `started` line ends `(not found)`

#### Scenario: A file that cannot be read
- **WHEN** `plugins/notify.toml` is a directory or a file that cannot be read
- **THEN** the one problem is `options: <file>: <the text node prints for the failed read>`, such as `EISDIR: illegal operation on a directory, read`, the defaults hold and the `started` line ends `(invalid)`

#### Scenario: An open that fails while a rename replaces the symlink
- **WHEN** the open of `plugins/notify.toml` fails with EINVAL because a rename is replacing a symlink on the path (macOS)
- **THEN** the open is tried again, three tries in all, and only an EINVAL on the third try is the problem line of "A file that cannot be read"

#### Scenario: A file without read permission
- **WHEN** `plugins/notify.toml` has mode 000 at start
- **THEN** the log has the problem line above and `options watch failed <file> <why>` (the file watch cannot be armed, `EACCES`), before `started` ending `(invalid)`, and the service runs without that file watch, the directory watch still hearing a replacement

### Requirement: A bad options file is worded as the node service words it
For every problem of the schema the service SHALL log `options: <line>` with the line the node service writes, byte for byte, in the order zod 4 reports it: each key's issues in the order of the schema, then the object's unrecognized keys, then the `after`/`ttl` check, which a type problem inside `cache_expiring` skips. It SHALL then run on the defaults, and log each distinct set of problems once.

#### Scenario: An unknown key
- **WHEN** the file says `icn = "x"`
- **THEN** the line is `options: Unrecognized key: "icn"`

#### Scenario: Unknown keys in the order of a JavaScript object
- **WHEN** the file holds the keys `b`, `2` and `1`, in that order, all unknown
- **THEN** the line is `options: Unrecognized keys: "1", "2", "b"`

#### Scenario: A value outside its list
- **WHEN** `click = "tap"`, or `click = 3`
- **THEN** the line is `options: click: Invalid option: expected one of "dock"|"goto"|"focus"` for both

#### Scenario: A duration that does not parse
- **WHEN** `after = 5e-1`
- **THEN** the line is `options: events.cache_expiring.after: not a duration: 0.5 (use 90, 45s, 50m, 2h or 1h30m)`

#### Scenario: A duration of the wrong type
- **WHEN** `after = true`
- **THEN** the line is `options: events.cache_expiring.after: Invalid input`

#### Scenario: After not below ttl
- **WHEN** `after` and `ttl` are both `60m`
- **THEN** the line is `options: events.cache_expiring.after: after must be below ttl: a notice about a cache that already expired helps nobody`

#### Scenario: Several problems
- **WHEN** the file holds `click = "tap"`, `backend = "x"` and `icn = 1`
- **THEN** the lines come in the order `backend`, `click`, then the unrecognized key

#### Scenario: A date where a table is expected
- **WHEN** `events = 1979-05-27`
- **THEN** the file is valid and every event setting is its default

### Requirement: A file that is not TOML is reported, not reproduced
A file that is not TOML SHALL be reported as the one problem `options: <file>: Invalid TOML document: <reason>`, with the defaults in force, and the reason is the parser's own: it is not required to equal the node service's, which ends in a code excerpt. An integer beyond 2^53 SHALL be refused with the node service's reason.

#### Scenario: A syntax error
- **WHEN** the file holds `click = `
- **THEN** one problem is logged, starting `options: ` and the file's path and `Invalid TOML document: `, and the service runs on the defaults

#### Scenario: An integer that cannot be held
- **WHEN** `after = 9007199254740993`
- **THEN** the file is invalid and the reason says the value cannot be represented losslessly

### Requirement: A start that fails is handed to the node service
When a step of the start before the `started` line fails, the Rust service SHALL, unless a stop was requested, log `handing over to the node service: <why>`, keep the lock held and replace its process with the node service (`node <root>/packages/notify/dist/main.js run`, the same environment), which runs or fails by its own lines. A stop requested during start SHALL end the process without a `stopping` line, and a failure after `started`, such as a failed watch, SHALL NOT be handed over.

#### Scenario: The steps that hand over
- **WHEN** registering the handlers of SIGTERM, SIGINT and SIGHUP, creating the state directory, taking the lock (not a held lock), starting the watch, starting the follower or arming the engine from the state rows fails (the node service has no such step: its handlers cannot fail to register)
- **THEN** the service hands over to the node service

#### Scenario: A watch that cannot be armed
- **WHEN** the watch on the events file fails at start
- **THEN** the node service runs in its place, with the same pid, and the lock is held by it

#### Scenario: The lock is kept across the exec
- **WHEN** the service hands over while a manual `run` starts at the same moment
- **THEN** the lock never names a dead pid, the manual `run` logs `another notify service holds` and exits 0, and the node service runs

#### Scenario: The exec fails
- **WHEN** the node program cannot be executed
- **THEN** the service releases the lock, logs `could not hand over to the node service: <why>` and exits 1

#### Scenario: The node build is missing
- **WHEN** `packages/notify/dist/main.js` is not there
- **THEN** the service logs the same line `could not hand over to the node service: <why>`, with no `tagents-core: cannot find` line, releases the lock and exits 1

#### Scenario: A failure that node shares
- **WHEN** the state directory cannot be created
- **THEN** the node service fails with its own line `the notify service stopped: <why>` and exit 1, the code launchd retries

#### Scenario: The options directory cannot be watched
- **WHEN** the watch on the options directory fails at start, as when `plugins` is a regular file (`ENOTDIR`)
- **THEN** the service logs `options watch failed <dir> <why>`, logs `started` and runs without a reload

#### Scenario: A stop during a failing start
- **WHEN** SIGTERM arrives while a step of the start fails
- **THEN** the process writes no `stopping` line, releases the lock, exits 0 and does not start the node service

#### Scenario: A stop during the close of a hand-over
- **WHEN** SIGTERM arrives while the service closes the follower and the watch for a hand-over
- **THEN** the process writes no `stopping` line, releases the lock, exits 0 and does not start the node service

### Requirement: When the watch ends
The service SHALL stop as a signal stop does when its watch ends (a failed wait, or a failed re-arm of a file watch for a reason other than a missing file or a symlink), with the reason `watch failed: <why>` in the line `stopping (<reason>)`, and exit 1. The stop is written when the engine reads the end, after the post in flight and the wakes queued ahead of it.

#### Scenario: The watch fails after start
- **WHEN** the wait of the watch fails while a post is in flight and a wake is queued behind it
- **THEN** the post finishes with its `notice` line, the queued wake is served, then the log has `stopping (watch failed: <why>)`, `drain failed <why>` follows when the drain fails, the lock and `events.on` are released, the service exits 1 and the node service is not started

### Requirement: The helper is called as the node service calls it
A notice SHALL be posted by running `<app>/Contents/MacOS/tagents-notify post` with the notice as JSON on stdin and a withdrawal by `<app>/Contents/MacOS/tagents-notify withdraw <id>`, each with a deadline of 5 seconds after which the helper's process group is killed. Only `ok`, `shown`, `why` and `error` of the one JSON line answered are read, and an answer that is not that line is the node service's `unreadable output from the notification helper` error.

#### Scenario: A helper that answers
- **WHEN** the helper answers `{"ok":true,"shown":true}`
- **THEN** the notice is logged as shown

#### Scenario: A helper that is too slow
- **WHEN** the helper does not answer within 5 seconds
- **THEN** it is killed with its children and `the notification helper timed out after 5 s` is the failure

#### Scenario: A helper that prints garbage
- **WHEN** the helper prints something that is not a JSON line
- **THEN** the failure is `unreadable output from the notification helper: stdout <json>, stderr <json>`

#### Scenario: No helper
- **WHEN** the helper app is not there
- **THEN** the failure is `cannot start the notification helper at <app> (<why>); run \`tagents notify install\``

### Requirement: The program with a deadline and the ending are shared with mcp
The spawn of a program with input, a deadline and a cap on its output, and the ending on SIGTERM, SIGINT and SIGHUP, SHALL be one implementation used by `mcp` and by the service, and what `mcp` does SHALL not change by it: the same constants, the same outcomes, the same answers.

#### Scenario: The MCP suite after the move
- **WHEN** `tests/rust-mcp-parity.sh` and the tests of `mcp` run on the shared modules
- **THEN** they pass as before

### Requirement: The node service is the reference
`tests/rust-notify-parity.sh` SHALL start `packages/notify` and `tagents-core notify run` one after the other on identical scratch state, feed them the same events, options and stub helper, and compare what they post, log and leave behind, with the time and the pid left out, and the workflow `rust.yml` SHALL run it on every change to either service on Linux and on macOS.

#### Scenario: The services differ
- **WHEN** the Rust service posts, logs or leaves behind anything the node service does not
- **THEN** the suite fails and prints both transcripts

#### Scenario: A scenario that stopped provoking
- **WHEN** the node transcript of a scenario lacks the event the scenario exists to provoke
- **THEN** the suite fails instead of passing for nothing

#### Scenario: The suite runs in CI
- **WHEN** a pull request changes `packages/notify/**`, `packages/core/src/agent-*.ts`, `crates/**` or the suite
- **THEN** the `rust` job runs it

### Requirement: Helpers that exist twice are pinned against each other
Each helper the Rust service has beside a node copy (the options schema and durations, the state rows, the event lines, the verdicts, the words of a notice, the phrases, the tmux answer) SHALL be checked by a vector file that node generates from the real functions and that a Rust test reads, and CI SHALL regenerate the file and fail on a difference from the committed one.

#### Scenario: Node changes a word
- **WHEN** a phrase in `phrases.ts` changes and the vector file is not regenerated
- **THEN** CI fails on the regenerated file

#### Scenario: Rust changes a word
- **WHEN** the Rust copy of a phrase changes and the node copy does not
- **THEN** a Rust test fails on the vector

### Requirement: Where the two differ is written down
`docs/architecture/rust-core.md` SHALL list every known difference between the node service and the Rust service, each with its reason, and a difference that is not in the list SHALL be a failure of the suite.

#### Scenario: A listed difference
- **WHEN** the reason of a TOML syntax error differs between the two
- **THEN** the page names it and the suite does not compare it

#### Scenario: An unlisted difference
- **WHEN** the two differ in a way the page does not name
- **THEN** the suite fails
