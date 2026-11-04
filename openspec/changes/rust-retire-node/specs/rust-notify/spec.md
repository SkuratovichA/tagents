## REMOVED Requirements

### Requirement: A start that fails is handed to the node service
**Reason**: No call of a verb of the binary reaches node.
**Migration**: A start that fails is logged and exits 1, as the requirement "A start that fails is logged and exits 1" says.

## ADDED Requirements

### Requirement: A start that fails is logged and exits 1
When a step of the start before the `started` line fails, the Rust service SHALL, unless a stop was requested, log `could not start: <why>`, release the lock and exit 1, the code launchd retries. A stop requested during the start SHALL end the process without a `stopping` line and with exit 0. A failure after `started`, such as a failed watch, SHALL NOT end the service.

#### Scenario: The steps that fail
- **WHEN** registering the handlers of SIGTERM, SIGINT and SIGHUP, creating the state directory, taking the lock (not a held lock), starting the watch, starting the follower or arming the engine from the state rows fails
- **THEN** the service logs `could not start: <why>`, releases the lock and exits 1, and the node service is not started

#### Scenario: The options directory cannot be watched
- **WHEN** the watch on the options directory fails at start, as when `plugins` is a regular file (`ENOTDIR`)
- **THEN** the service logs `options watch failed <dir> <why>`, logs `started` and runs without a reload

#### Scenario: A stop during a failing start
- **WHEN** SIGTERM arrives while a step of the start fails
- **THEN** the process writes no `stopping` line, releases the lock and exits 0
