## ADDED Requirements

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

#### Scenario: the spec follows the verbs
- **WHEN** a verb gains an option and the CLI spec is not changed
- **THEN** the package's tests fail naming the verb

## MODIFIED Requirements

### Requirement: Verbs and the standalone binary
The plugin SHALL provide the verbs `run`, `install`, `uninstall`, `status`, `test` and `send`, as `tagents notify <verb>` once the plugin is registered and as `tagents-notify <verb>` from the package's own binary, which needs no registration, so a LaunchAgent works on a machine where the host never ran. The binary with no verb, or with an unknown verb, exits 2 and lists the verbs.

#### Scenario: no verb
- **WHEN** `tagents-notify` runs with no arguments
- **THEN** it exits 2 and the six verbs appear in its output

#### Scenario: unknown verb
- **WHEN** `tagents-notify bogus` runs
- **THEN** it exits 2 and the output names `bogus`
