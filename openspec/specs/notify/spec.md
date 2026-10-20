# notify Specification

## Purpose
Desktop notifications for tagents, the part that decides what is worth a banner: which agent events raise a notice, what a notice says, when it is withdrawn, the prompt-cache warning, what a click does, and the plugin's options. The service, the macOS helper and the commands are in the `notify-service` capability.

## Requirements

### Requirement: Notices come only from pane agents
The notify service SHALL raise notices only for agents, meaning a Claude session in a tmux pane of its own whose state key is that pane's number. A session whose key starts with `s-` (a child session that an agent started from its Bash tool, or a headless session with no pane) SHALL never raise a notice or arm a cache deadline, and no option turns this on.

#### Scenario: a child session raises nothing
- **WHEN** events with key `s-kid` arrive (a Stop, a permission prompt and a SessionEnd) with every event kind switched on
- **THEN** no notice is posted and no cache deadline is armed

#### Scenario: a headless session is left alone at start
- **WHEN** the service starts and the state rows hold a `done` row with key `s-daemon` that is still inside the cache lifetime
- **THEN** no cache deadline is armed for it

#### Scenario: switches for other sessions are not accepted
- **WHEN** the options file sets `sessions.headless` or `events.subagent_done`
- **THEN** the file is invalid and each key is reported as a problem

### Requirement: Subagents raise no notice of their own
An Agent-tool subagent SHALL post nothing when it finishes: a `SubagentStop`, and a `Stop` that carries an agent id, raise no notice and arm no deadline. A question or a permission prompt raised inside a subagent blocks the agent that started it, so it SHALL be posted as that agent's notice, under that agent's key.

#### Scenario: a subagent finishes
- **WHEN** a `SubagentStop` arrives, or a `Stop` with an agent id, for a pane agent
- **THEN** nothing is posted and nothing is armed

#### Scenario: a subagent asks for permission
- **WHEN** a permission prompt notification with an agent id arrives under pane key `12`
- **THEN** a `permission` notice is posted with id `tagents-12`

### Requirement: Events that raise a notice
The service SHALL turn agent events into notices of five kinds. `question`: a `PreToolUse` of `AskUserQuestion` or `ExitPlanMode`, or a Notification of subtype `elicitation_dialog`. `permission`: a Notification of subtype `permission_prompt`. `turn_done`: a `Stop` of the agent itself. `session_end`: a `SessionEnd`. `cache_expiring`: a deadline falling due, as its own requirement describes.

#### Scenario: a question tool
- **WHEN** a `PreToolUse` of `AskUserQuestion` arrives for a pane agent
- **THEN** a `question` notice is posted

#### Scenario: a plan for approval
- **WHEN** a `PreToolUse` of `ExitPlanMode` arrives
- **THEN** a `question` notice is posted whose subtitle is "Plan ready for review"

#### Scenario: another tool
- **WHEN** a `PreToolUse` of any other tool arrives
- **THEN** nothing is posted

### Requirement: Notifications of other kinds
A Notification with a subtype other than the two above SHALL raise a `permission` notice when it carries text, because Claude Code adds notification types over time and a prompt for the person is the likelier reading. A Notification of subtype `idle_prompt` or `auth_success`, one whose text says it is waiting for your input, and one with neither a known subtype nor text SHALL raise nothing.

#### Scenario: an unknown notification type with words
- **WHEN** a Notification arrives with an unrecognised subtype and non-empty text
- **THEN** a `permission` notice is posted

#### Scenario: the idle ping
- **WHEN** a Notification of subtype `idle_prompt`, or with text "waiting for your input", arrives about a minute after a Stop
- **THEN** nothing is posted, because the Stop already told the person

### Requirement: Event kinds that are on by default
Each kind SHALL be switched on or off with `events.<kind>.enabled`. `question`, `permission`, `turn_done` and `cache_expiring` SHALL be on by default and `session_end` off. A kind that is switched off posts nothing, but the person is still waiting on the session, so a `Stop`, a question or a permission prompt still arms the cache deadline.

#### Scenario: defaults
- **WHEN** the options file does not exist
- **THEN** a finished turn posts `turn_done` and a `SessionEnd` posts nothing

#### Scenario: turning session_end on
- **WHEN** `events.session_end.enabled` is `true` and a `SessionEnd` arrives
- **THEN** the old notice for the key is withdrawn and a `session_end` notice is posted

#### Scenario: a disabled kind still arms the cache
- **WHEN** `events.turn_done.enabled` is `false` and a `Stop` arrives
- **THEN** no `turn_done` notice is posted and the cache deadline is armed

### Requirement: One notice per agent
Each agent SHALL have at most one notice at a time. Every notice is posted under the id `tagents-<key>` (the pane number for a pane agent) with the session id as its thread, and a later notice with the same id replaces the earlier one instead of stacking.

#### Scenario: a second notice replaces the first
- **WHEN** two notices are posted for the same key
- **THEN** both carry the id `tagents-<key>`, so the second replaces the first on screen

### Requirement: The title of a notice
The title SHALL be the agent's name as the dashboard shows it: the name typed for the session, else the name typed for the pane, else the pane title without Claude Code's leading status glyph; for a session with no title its `TA_LABEL`; and the working directory's name when that is still empty or is only the machine's hostname.

#### Scenario: the title follows the dashboard's order
- **WHEN** a name was typed for the session and another for the pane
- **THEN** the title is the session's name

#### Scenario: the pane title loses its glyph
- **WHEN** the pane title is a status glyph such as `✳`, a space and then `build agent`
- **THEN** the title is `build agent`

#### Scenario: a one-letter word is not a glyph
- **WHEN** the pane title is `я иду`
- **THEN** the title is `я иду`

#### Scenario: a title that is the hostname
- **WHEN** the pane title equals the machine's hostname, long or short
- **THEN** the title is the working directory's name

#### Scenario: no title at all
- **WHEN** the pane has no title and no name was typed
- **THEN** the title is `TA_LABEL`, and the working directory's name when that is empty too

### Requirement: The subtitle of a notice
The subtitle SHALL be the kind's phrase, followed by ` · <project>` (the working directory's name) unless the project is empty or equals the title. The phrases are "Asks you something" (`question`), "Plan ready for review" (a plan), "Needs your permission" (`permission`), "Answer ready" (`turn_done`), "Prompt cache expiring" (`cache_expiring`) and "Session ended" (`session_end`).

#### Scenario: the project in the subtitle
- **WHEN** the working directory is `~/projects/app` and the title is `build agent`
- **THEN** the subtitle of a `turn_done` notice is `Answer ready · app`

#### Scenario: the project equals the title
- **WHEN** the title is `app` and the working directory is `~/projects/app`
- **THEN** the subtitle is the phrase alone

### Requirement: The body of a notice
The body SHALL be, for `question`, the event's text or "Asking you something"; for `permission`, the event's text or "Waiting for your permission"; for `session_end`, the end reason or "No reason given"; for `turn_done`, as the next requirement says; for `cache_expiring`, as the cache requirement says.

#### Scenario: a question without text
- **WHEN** a question arrives with no text
- **THEN** the body is "Asking you something"

#### Scenario: a session end
- **WHEN** a `SessionEnd` arrives with the reason `other`
- **THEN** the body is `other`, and with no reason it is "No reason given"

### Requirement: The body of a finished turn
The body of a `turn_done` notice SHALL be the event's own text clipped to 200 characters, else the first non-empty line of the last assistant answer in the transcript clipped to 200 characters, else "Your move" (also when the transcript is missing or unreadable). A clipped body ends with an ellipsis, and a missing transcript never costs the notice.

#### Scenario: a long answer
- **WHEN** a `Stop` carries text longer than 200 characters
- **THEN** the body is that text cut to 200 characters with a trailing ellipsis

#### Scenario: the answer is read from the transcript
- **WHEN** a `Stop` carries no text and the transcript's last answer begins with blank lines
- **THEN** the body is the first non-empty line of that answer

#### Scenario: no transcript
- **WHEN** a `Stop` carries no text and the transcript does not exist
- **THEN** the notice is still posted, with the body "Your move"

### Requirement: Phrases follow the locale
The service SHALL write the kind phrases and the fallback bodies in Russian when `TAGENTS_LOCALE` is `ru`, and in English when it is unset or names a locale tagents does not speak.

#### Scenario: Russian
- **WHEN** `TAGENTS_LOCALE` is `ru` and a permission prompt arrives with no text
- **THEN** the body is the Russian fallback phrase

#### Scenario: an unknown locale
- **WHEN** `TAGENTS_LOCALE` is `xx`
- **THEN** the phrases are English

### Requirement: Withdrawing a notice that is no longer true
When the person answers or the session moves on, the service SHALL withdraw the notice it has up for that key, and only when one is up. A `UserPromptSubmit`, a `SessionStart` (a new session in the pane makes the old question moot), a `SessionEnd` and the `PostToolUse` of `AskUserQuestion` or `ExitPlanMode` each withdraw it and cancel the key's cache deadline.

#### Scenario: a prompt withdraws the notice
- **WHEN** a `turn_done` notice is up for key `12` and a `UserPromptSubmit` arrives for it
- **THEN** the notice with id `tagents-12` is withdrawn and the cache deadline is cancelled

#### Scenario: nothing to withdraw
- **WHEN** a `UserPromptSubmit` arrives and the backend never showed a notice for the key
- **THEN** no withdrawal is requested

#### Scenario: the answer to a question
- **WHEN** a `PostToolUse` of `AskUserQuestion` arrives while its question notice is up
- **THEN** the notice is withdrawn, the cache deadline is cancelled, and no notice is posted for the answer

#### Scenario: a new session in the pane
- **WHEN** a `SessionStart` arrives for a pane whose old session left a question up
- **THEN** that notice is withdrawn

### Requirement: Notices for a chat that is on screen
When `skip_visible` is on for a kind and the agent's tmux pane is in some client's current window, the notice SHALL be handed to the backend marked to be dropped if that client's terminal is the frontmost application. With `skip_visible` off, or when tmux cannot say which client shows the pane, or the terminal is not found, the notice is posted unmarked.

#### Scenario: the pane is in front
- **WHEN** a Stop arrives, `events.turn_done.skip_visible` is on, the pane is in a client's window and that terminal is frontmost
- **THEN** the notice is marked to skip if frontmost, and the backend does not show it

#### Scenario: skip_visible off
- **WHEN** `events.turn_done.skip_visible` is `false` and the pane is visible
- **THEN** the notice carries no skip mark, and still names the visible client's terminal for the click

#### Scenario: tmux does not answer
- **WHEN** the screen probe fails or finds nothing
- **THEN** the notice is posted without a terminal and without a skip mark

### Requirement: Withdrawal when the notice is dropped
A notice the backend drops (for example because the chat is on screen) leaves the older notice with the same id on screen, saying something that is no longer so, so the service SHALL withdraw that older notice, but only if the backend showed it.

#### Scenario: a dropped notice takes down the stale one
- **WHEN** a permission notice is up and the next `turn_done` for the same key is dropped as frontmost
- **THEN** the permission notice is withdrawn

#### Scenario: nothing was shown before
- **WHEN** a notice is dropped and no notice with that id was shown
- **THEN** no withdrawal is requested

### Requirement: A permission prompt after a question
A permission prompt that arrives no more than 20 seconds after the `PreToolUse` of a question whose notice is up SHALL post nothing, replace nothing and leave the question's cache deadline as it was, and the service logs that it was held back. Claude Code follows a question with such a generic prompt a few seconds later. A prompt later than that, one after the question was answered, ended or never shown, and one after an MCP elicitation (which has no answer event) post normally.

#### Scenario: six seconds after the question
- **WHEN** a question notice is up and a permission prompt arrives 6 seconds later
- **THEN** only the question's notice exists, nothing is withdrawn, and the deadline stays 50 minutes after the question

#### Scenario: a real prompt
- **WHEN** a permission prompt arrives 21 seconds after the question
- **THEN** a `permission` notice is posted

#### Scenario: after the answer
- **WHEN** the question was answered by a `PostToolUse`, and then a permission prompt arrives
- **THEN** a `permission` notice is posted

#### Scenario: an elicitation
- **WHEN** a permission prompt follows an `elicitation_dialog` notification
- **THEN** it is posted

### Requirement: The prompt-cache deadline
When a session starts waiting on the person (a question, a permission prompt or a `Stop`) the service SHALL arm a deadline `events.cache_expiring.after` (default 50 minutes) after that event. A newer waiting event for the key re-arms it, which makes the older deadline stale. A prompt, an answer or the end of the session cancels it. With `events.cache_expiring.enabled` false no timer is ever armed.

#### Scenario: a turn arms one deadline
- **WHEN** a `Stop` arrives
- **THEN** one deadline is armed for 50 minutes later, and a following `UserPromptSubmit` cancels it

#### Scenario: a question and a prompt arm it
- **WHEN** a question or a permission prompt arrives
- **THEN** a deadline is armed as for a `Stop`

#### Scenario: disabled
- **WHEN** `events.cache_expiring.enabled` is `false`
- **THEN** no deadline timer is ever armed

### Requirement: The prompt-cache warning
When a deadline falls due the service SHALL post a `cache_expiring` notice reporting the idle minutes and the minutes left until `ttl` (default 60 minutes), rounded to whole minutes, as "Idle <n> min — send anything within ~<m> min to keep the prompt cache"; a remainder below one minute reads "within a minute". `skip_visible` defaults to off for this kind, so the warning shows even when the chat is on screen.

#### Scenario: the warning
- **WHEN** a `Stop` arrives and 50 minutes pass with the state row still `done`
- **THEN** a notice is posted with the body "Idle 50 min — send anything within ~10 min to keep the prompt cache"

#### Scenario: a blocked session
- **WHEN** the row is `blocked` when the deadline falls due
- **THEN** the warning is posted

#### Scenario: under a minute left
- **WHEN** a warning goes out with less than a minute of the cache left
- **THEN** the body says "within a minute"

### Requirement: When no cache warning is sent
A due deadline SHALL post nothing when the state row of the session is missing, `new` or `gone`; when the row is `working` with a time later than the event that armed the deadline (the person came back); when the full `ttl` has already passed (the cache is gone); or when tmux answers that the pane does not exist. A tmux that fails to answer is not a pane that is gone, and the warning is posted.

#### Scenario: the person came back
- **WHEN** the row is `working` with a time later than the Stop when the deadline falls due
- **THEN** nothing is posted

#### Scenario: the cache is already gone
- **WHEN** the Mac slept through the whole `ttl` and the deadline is noticed only after it
- **THEN** no notice is posted

#### Scenario: the pane is gone
- **WHEN** tmux answers that the pane does not exist
- **THEN** the warning is not posted and the log says tmux has no such pane, while other notices for the key still post

#### Scenario: tmux silent
- **WHEN** the tmux probe fails or times out
- **THEN** the warning is posted

### Requirement: Deadlines survive sleep
The deadline timer SHALL sleep at most 5 minutes at a time and read the wall clock again on each wake, so that a Mac that slept past a deadline warns within one tick of waking. There is at most one timer however many sessions wait, and none when nothing waits. Every event the follower delivers SHALL also sweep for deadlines already due, so a late warning goes out on the next event of any chat.

#### Scenario: late wake
- **WHEN** the Mac wakes 3 minutes after a deadline's due time
- **THEN** the warning is posted within one 5-minute tick

#### Scenario: another chat wakes the sweep
- **WHEN** a deadline fell due while the Mac slept and an event of another chat arrives
- **THEN** the warning goes out before the deadline's own timer would

### Requirement: Deadlines survive a restart
When the service starts, or follows the stream again after the follower died, it SHALL arm every pane agent whose state row is `done`, `blocked`, or `working` on an unanswered `AskUserQuestion` or `ExitPlanMode`, and whose idle time is still inside `ttl`, except an idle period it has already warned about.

#### Scenario: restart remembers idle sessions
- **WHEN** the service starts with a `done` row that is 55 minutes idle
- **THEN** a warning for it goes out once, with the idle and remaining minutes computed from the row

#### Scenario: no second warning
- **WHEN** a warning for an idle period was sent and the follower is re-established
- **THEN** the same idle period is not warned about again

#### Scenario: a new idle period
- **WHEN** a prompt or a new turn arrives after a warning
- **THEN** the key can be warned about again

#### Scenario: an expired row
- **WHEN** the service starts with a row already past `ttl`
- **THEN** nothing is armed for it

### Requirement: What a click does
The `click` option (default `dock`) SHALL choose the action of a notice's click. `dock` runs `tagents --act open <pane> live <session id> <cwd>`, the same as Enter on that chat in the dashboard list. `goto` runs `tagents --goto <pane>`. `focus`, and any notice for a session with no pane, only raises the terminal. A click also brings forward the terminal application behind the tmux client that showed the pane, when it is known.

#### Scenario: dock
- **WHEN** `click` is `dock` and a notice for pane `%12`, session `sess-77`, cwd `/work/app` is clicked
- **THEN** `tagents --act open %12 live sess-77 /work/app` runs

#### Scenario: goto
- **WHEN** `click` is `goto`
- **THEN** the click runs `tagents --goto %12`

#### Scenario: focus
- **WHEN** `click` is `focus`
- **THEN** the click runs no command and only raises the terminal

### Requirement: The environment of a click
A click runs under the notification center and not under the service, so its environment SHALL be the helper's launchd environment overlaid with these variables from the service's environment, each only when set and non-empty: `PATH`, `HOME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `TMUX_TMPDIR`, `TA_STATE_DIR`, `TAGENTS_CONFIG_DIR`, `XDG_CONFIG_HOME` and `TA_CONFIG`. Nothing else is passed on.

#### Scenario: the tmux server is found
- **WHEN** the service runs with `TMUX_TMPDIR` and `LANG` set
- **THEN** the click's environment holds them and no unrelated variable

#### Scenario: unset variables
- **WHEN** `LC_ALL` is unset or empty
- **THEN** the click's environment does not carry it

### Requirement: The tagents script a click runs
The click SHALL run the script named by `TA_NOTIFY_TAGENTS` when it is set and non-empty, else the first `tagents` on the `PATH` of the shell that ran `install` (as found, so a symlink stays the symlink), else the `tagents` script at the root of the checkout. `install` decides this once and hands it to the service, because tagents re-points the global tmux focus hooks at whichever script ran.

#### Scenario: the environment wins
- **WHEN** `TA_NOTIFY_TAGENTS` is set to `~/bin/tagents-dev`
- **THEN** that is the script in the click and in the `click:` line of `status`

#### Scenario: PATH
- **WHEN** it is unset and a `tagents` is on `PATH`
- **THEN** that one, not its resolved target, is used

#### Scenario: a script that cannot run
- **WHEN** `click` is not `focus` and the chosen script is not an executable file
- **THEN** `install` warns that a click raises the terminal and docks nothing, and `status` shows `missing`

### Requirement: Plugin options and defaults
The options SHALL live in `<configDir>/plugins/notify.yaml` with every key optional: `backend: auto` (one of `auto`, `macos`, `log`, `none`); `click: dock` (one of `dock`, `goto`, `focus`); `icon` unset; `events.question`, `events.permission` and `events.turn_done` each `enabled: true, skip_visible: true`; `events.cache_expiring` as `enabled: true, skip_visible: false, after: 50m, ttl: 60m`; `events.session_end` as `enabled: false, skip_visible: true`.

#### Scenario: a partial file
- **WHEN** the file says only `click: goto`
- **THEN** every event setting is still its default

#### Scenario: a partial event
- **WHEN** the file says only `events.question.enabled: false`
- **THEN** `events.question.skip_visible` is still `true`

### Requirement: Invalid options
Unknown keys at any level (the top, `events`, and inside an event) and values outside the enums SHALL be problems that name the key, so that a misspelt key does not silently do nothing.

#### Scenario: a misspelt key
- **WHEN** an event block says `skip_visble: false`
- **THEN** the file is invalid and the problem names that key

#### Scenario: an enum
- **WHEN** `click` is `tap`
- **THEN** the file is invalid

### Requirement: The backend option
`backend: auto` SHALL mean the macOS backend on darwin and an unsupported platform elsewhere. `macos` forces the macOS backend, `log` posts nothing and writes each notice to the log, and `none` posts nothing at all and installs nothing.

#### Scenario: auto on macOS
- **WHEN** `backend` is `auto` on darwin
- **THEN** the backend resolves to `macos`

#### Scenario: none
- **WHEN** `backend` is `none`
- **THEN** nothing posts and the service has nothing to run

### Requirement: Durations
`after` and `ttl` SHALL be written as `<n>s`, `<n>m`, `<n>h` or a combination in that order such as `1h30m`, or as a bare number of seconds. Only whole numbers are accepted. `after` SHALL be below `ttl`. A bad duration is a problem located at its own key.

#### Scenario: combined units
- **WHEN** `after` is `1h30m`
- **THEN** it means 90 minutes

#### Scenario: a bare number
- **WHEN** `after` is `90`
- **THEN** it means 90 seconds

#### Scenario: after not below ttl
- **WHEN** `after` is `60m` and `ttl` is `60m`
- **THEN** the file is invalid with the problem at `after`

#### Scenario: fractions
- **WHEN** `ttl` is `1.5h`
- **THEN** the file is invalid with the problem at `ttl`

### Requirement: Options reload without a restart
The running service SHALL re-read the options file when it changes, with nothing to restart, and the next event SHALL use the new values. A reload to the value already in force is ignored. A change of `backend` takes effect only after a restart, and the log says so (`tagents notify install`).

#### Scenario: turning a kind off
- **WHEN** `turn_done` is switched off in the file while the service runs
- **THEN** the next `Stop` posts no notice

#### Scenario: backend change
- **WHEN** `backend` changes in the file
- **THEN** the log says it takes effect after a restart and the running backend is unchanged

### Requirement: Invalid options at run time
An invalid options file SHALL run the engine on the defaults, and each distinct set of problems is logged once however often the file is read.

#### Scenario: invalid file
- **WHEN** the file is invalid
- **THEN** each problem is logged once and a finished turn still posts under the defaults

#### Scenario: fixing the file
- **WHEN** the file becomes valid again
- **THEN** its values take effect and a later problem is logged anew

### Requirement: Where the options are watched
The service SHALL watch the real path of the `plugins` directory, so a config directory that is a symlink (for example into a dotfiles repository) works. A `plugins` directory that appears after the service started is found. A `notify.yaml` that is itself a symlink is noticed only when the link is replaced, not when its target is edited. With no config directory at all the service runs and logs that options reload is off.

#### Scenario: symlinked config directory
- **WHEN** the config directory is a symlink into another directory and the real `notify.yaml` is edited
- **THEN** the change is seen

#### Scenario: the directory appears later
- **WHEN** the `plugins` directory is created after the service started
- **THEN** the file in it is read and watched

#### Scenario: no config directory
- **WHEN** the config directory does not exist
- **THEN** the service runs and logs that options reload is off
