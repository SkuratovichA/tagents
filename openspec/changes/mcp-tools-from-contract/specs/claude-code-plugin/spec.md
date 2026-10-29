## ADDED Requirements

### Requirement: The plugin registers the tagents MCP server
The plugin manifest SHALL register the MCP server `tagents`, started as the command `tagents-mcp` with the arguments `--contract ${CLAUDE_PLUGIN_ROOT}/contract.json`. The tools it lists SHALL be those `contract.json` records under `mcp.tagents.tools`.

#### Scenario: Registered by the manifest
- **WHEN** the plugin is installed and a session starts
- **THEN** a `tagents` MCP server is started with `tagents-mcp --contract <plugin root>/contract.json`

#### Scenario: The list is the contract's list
- **WHEN** a client asks the running server for its tools
- **THEN** it receives the names, descriptions, input schemas and annotations that `contract.json` records under `mcp.tagents.tools`

#### Scenario: A server that cannot read its contract
- **WHEN** `tagents-mcp` is started without `--contract`, or with a file that is not a contract
- **THEN** it prints the problem on stderr and exits 2 for a missing option and 1 for an unreadable file, and writes nothing to stdout

### Requirement: The server knows no verb
The server SHALL list one tool for each verb of each structured CLI spec recorded in the contract, except the verbs whose effect is `serve`, and SHALL contain no knowledge of any verb. A verb added to a spec is therefore a tool once the contract is regenerated and the plugin updated.

#### Scenario: A verb in the contract
- **WHEN** `contract.json` records a verb that is not `serve`
- **THEN** the server lists a tool for it, whatever the verb is

#### Scenario: A verb that serves
- **WHEN** `contract.json` records a verb with the effect `serve`
- **THEN** the server lists no tool for it

### Requirement: A tool is named after its verb
The tool of a verb SHALL be named `<program>_<words of the verb>`: the program name without its `tagents-` prefix, then each word without leading dashes, every run of other characters becoming one underscore. Two verbs that would give the same name SHALL stop the generator.

#### Scenario: Names
- **WHEN** the verbs `session open` of `tagents-core`, `send` of `tagents-notify` and `--window` of the script are listed
- **THEN** the tools are `core_session_open`, `notify_send` and `tagents_window`

### Requirement: A tool says what it starts in its first words
The description of a tool SHALL be the verb's summary as one sentence. A verb that starts a Claude session, a window, a service or a Claude turn SHALL open its summary with `starts`, `opens`, `runs` or `installs`, because the description is what Claude Code shows when it asks the user to allow the call.

#### Scenario: What the permission prompt shows
- **WHEN** a client asks the user to allow `tagents_new`, `tagents_window` or `core_session_prompt`
- **THEN** the description it shows begins with what the call starts

### Requirement: A tool's arguments are the verb's own
The input schema of a tool SHALL have one property for each positional of the verb, named after its placeholder in lower case (an array of strings for `<words…>`, a string otherwise), one for each option typed as the option is, and `required` listing the required ones, and no other property. A call SHALL pass each option as `--name=value` and then the positionals.

#### Scenario: A value that starts with a dash
- **WHEN** `notify_send` is called with the `title` `--x`
- **THEN** the verb receives `--title=--x`, so the value stays a value

### Requirement: Arguments are checked before anything runs
A call with an argument the schema does not list, a missing required argument, an argument of the wrong type or a positional that starts with a dash SHALL be refused with the exit `usage` (2) of the verb's program, and nothing SHALL run.

#### Scenario: A message that looks like a flag
- **WHEN** `notify_send` is called with the message words `--title`
- **THEN** the call is refused with an error saying the argument starts with a dash and nothing is run

#### Scenario: A required argument is missing
- **WHEN** `tagents_window` is called with a `dir` and no `command`
- **THEN** the call fails with exit 2 and an error naming `command`, and nothing is run

### Requirement: A call answers with how the verb ended
A call SHALL run the verb's program from `PATH` with the server's own environment and no standard input, and answer with one JSON document holding `exit`, `outcome`, `stdout` and `stderr`. `outcome` is the name of the code in the program's exit table, or `exit <n>` when it has none; `stdout` is parsed when it is a JSON document and is text otherwise. An exit code other than 0 SHALL make the answer an error.

#### Scenario: A verb that fails
- **WHEN** `core_session_last` is called with a reference that does not exist and the verb exits 1
- **THEN** the answer is an error whose document holds `"exit": 1`, `"outcome": "error"` and the message on stderr

#### Scenario: A verb that prints JSON
- **WHEN** `core_plugin_list` is called with `json` true
- **THEN** the answer's `stdout` is the parsed document, not a string

### Requirement: A call is bounded
Each of `stdout` and `stderr` SHALL be cut at 256 KiB and the document then says `"truncated": true`. A verb that has not ended after one hour SHALL be stopped with SIGTERM and answered as exit 4, outcome `timeout`. A program that is not on `PATH` SHALL be answered as exit 1 with its name in `stderr`.

#### Scenario: A program that is not installed
- **WHEN** `notify_send` is called and `tagents-notify` is not on `PATH`
- **THEN** the answer is an error with exit 1 whose `stderr` says `tagents-notify is not on PATH`

### Requirement: A verb that needs tmux is refused without it
A verb recorded with `requires: tmux` SHALL be refused by the server, without running it, when the server's environment has no `TMUX`: the answer is an error with exit `refused` (3) and a message saying that the tool opens windows in the tmux server it runs in and none is there. The tmux server a call opens a window in SHALL be the one that environment names, never another one.

#### Scenario: A server outside tmux
- **WHEN** `tagents_new` is called by a Claude Code session that was not started in tmux
- **THEN** the answer is an error with exit 3 saying a tmux server is needed, and no process is started

#### Scenario: A server inside tmux
- **WHEN** `tagents_window` is called by a session running in a tmux pane
- **THEN** the window is opened in that pane's tmux server

### Requirement: Permissions stay with the user
The plugin SHALL register no allow rule and SHALL write nothing to any Claude Code settings file. Claude Code's own prompt for each tool is the guard.

#### Scenario: A listing is not a permission
- **WHEN** the plugin is installed
- **THEN** no settings file under any Claude config directory has changed

### Requirement: A tool carries the annotations of its verb's effect
`read` SHALL give `readOnlyHint` true and `openWorldHint` false. `write` SHALL give `readOnlyHint` false, `destructiveHint` false and `openWorldHint` false; `spawn` the same with `openWorldHint` true; `destructive` `readOnlyHint` false, `destructiveHint` true and `openWorldHint` false. A verb with no effect SHALL give `readOnlyHint` false and nothing else.

#### Scenario: A new session is not read-only
- **WHEN** a client lists `tagents_new`
- **THEN** its annotations say it is not read-only and reaches outside

#### Scenario: A verb nobody classified
- **WHEN** a client lists a tool whose verb declares no effect
- **THEN** its annotations are `readOnlyHint` false and nothing else

### Requirement: The skill says how to use the tools
The hand-written part of `skills/tagents/SKILL.md` SHALL have a section "Using the tools" saying which tool notifies, which opens a Claude session and which opens a plain window, that several `tagents_new` calls open several sessions, that the window tools need a session started inside tmux, and that Claude Code asks before each call. It SHALL NOT repeat the flags of the verbs, which `references/` holds.

#### Scenario: When the skill applies to the new tools
- **WHEN** a session is asked to send a desktop notification, to open another Claude Code session or to run a command in a tmux window
- **THEN** the skill's description matches the task

#### Scenario: Asked to start the day
- **WHEN** the user asks a session to open several projects on their accounts
- **THEN** the skill leads it to one `tagents_new` call per project, each with its directory and profile

## MODIFIED Requirements

### Requirement: The plugin registers the knowledge MCP server
The plugin manifest SHALL register an MCP server `knowledge`, started as the command `sh` with the argument `${CLAUDE_PLUGIN_ROOT}/packages/knowledge/bin/knowledge-mcp`. The tools it offers are those of the `knowledge` capability. A server of the same kind registered by hand with `claude mcp add` SHALL be removed, or the tools appear twice. The manifest registers one more server, `tagents`, which another requirement specifies.

#### Scenario: Registered by the manifest
- **WHEN** the plugin is installed and a session starts
- **THEN** a `knowledge` MCP server is started with `sh ${CLAUDE_PLUGIN_ROOT}/packages/knowledge/bin/knowledge-mcp`

#### Scenario: Registered twice
- **WHEN** a hand-made registration of the same server exists as well
- **THEN** its tools appear twice

### Requirement: What the skill says holds everywhere
The skill SHALL state four things: a verb the `tagents` script has no flag for is handed to `tagents-core` unchanged; a JSON verb prints one pretty-printed document on stdout, except `session prompt --events`, which prints one compact JSON line per event and then the outcome; exit codes carry the outcome and are checked before output is parsed; `tagents-core`, `tagents-knowledge`, `tagents-notify` and `tagents-mcp` must be on `PATH`.

#### Scenario: Common mistakes
- **WHEN** the skill lists the mistakes to avoid
- **THEN** they are trusting a remembered flag, running into a verb the references list but the installed binary lacks (the binaries are older than the plugin), and editing `references/` or `contract.json`, which are generated through `pnpm plugin:gen`

#### Scenario: The forwarding rule
- **WHEN** a session reads the skill
- **THEN** it learns that `tagents session list` and `tagents-core session list` are the same call, as the `cli-dispatch` capability specifies

### Requirement: The parts of the ecosystem
The repository SHALL pair the bash dashboard `tagents` (tmux and fzf) with TypeScript packages: `@tagents/core` (headless sessions and plugins, behind `tagents-core`), `@tagents/knowledge` (the owner's notes as markdown, a CLI and an MCP server), `@tagents/telegram` (a typed Bot API client), `@tagents/notify` (desktop notifications), `@tagents/mcp` (the MCP server that turns the verbs of the contract into tools) and `@tagents/contract` (the contract generator). Plugins are further packages the config names. The bash scripts neither import nor need the workspace.

#### Scenario: One name reaches all of it
- **WHEN** a user types `tagents plugin list`, `tagents session list` or `tagents doctor`
- **THEN** it works from the dashboard's name, because the verb is forwarded to `tagents-core`

### Requirement: The node commands run with the node that installed them
`install.sh` SHALL write into `tagents-core`, `tagents-knowledge`, `tagents-notify` and `tagents-mcp`, the four commands it installs that run a node program, the absolute path of the `node` the installing shell finds on its `PATH`, and SHALL write it again on every install and every `tagents update`. Each of the four SHALL run that node while it is an executable file, and otherwise the `node` on the caller's `PATH`.

#### Scenario: A caller whose PATH holds no node
- **WHEN** tagents was installed from a shell that finds node at `/opt/node/bin/node`, and a process whose `PATH` is `/usr/bin:/bin` runs `tagents-knowledge lint`
- **THEN** the command runs on `/opt/node/bin/node`

#### Scenario: The pinned node is gone
- **WHEN** the node the commands were installed with has been removed, and a process whose `PATH` finds another node runs `tagents-core`
- **THEN** the command runs on the node found on that `PATH`

#### Scenario: Installed from a shell that finds no node
- **WHEN** the installing shell finds no node on its `PATH`, or finds it by a path that is not absolute
- **THEN** all four commands look node up on the caller's `PATH`

#### Scenario: An update from a shell with another node
- **WHEN** `tagents update` runs from a shell whose `PATH` finds node somewhere else
- **THEN** all four commands run on that node from then on

#### Scenario: The notifier and the tool server
- **WHEN** tagents was installed from a shell that finds node at `/opt/node/bin/node`
- **THEN** `tagents-notify` and `tagents-mcp` each pin that node

### Requirement: The installer writes wrappers, not symlinks
`install.sh` SHALL write a real-file wrapper into `~/.local/bin` for each of `tagents`, `tusage`, `tnotes`, `tagents-core`, `tagents-knowledge`, `tagents-notify` and `tagents-mcp`, and one per `hooks/*.sh` into `~/.claude/hooks` or each repeatable `--hooks-dir DIR`; a wrapper runs the same file of the managed copy. It writes only over a symlink or a file with the installer's marker line; any other file is left alone with a warning and exit 1 at the end. A wrapper whose hook the project dropped is removed.

#### Scenario: Two Claude config directories
- **WHEN** `install.sh --hooks-dir ~/.claude/hooks --hooks-dir ~/.claude-work/hooks` runs
- **THEN** both directories hold a wrapper for every hook script

#### Scenario: A file of somebody else's
- **WHEN** `~/.local/bin/tusage` exists and was not written by the installer
- **THEN** it is left as it was, a warning names it, and the exit code is 1

#### Scenario: A hook the project dropped
- **WHEN** an update brings a copy that no longer ships `hooks/old.sh`, and `~/.claude/hooks/old.sh` is a wrapper of the installer
- **THEN** that wrapper is removed

#### Scenario: The commands the tools run
- **WHEN** `install.sh` finishes a build
- **THEN** `tagents-notify` and `tagents-mcp` exist in `~/.local/bin` beside `tagents-core`
