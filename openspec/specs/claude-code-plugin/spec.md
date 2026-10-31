# claude-code-plugin Specification

## Purpose
The tagents repository is also a Claude Code plugin and its own marketplace, giving a Claude Code session the tagents skill and the knowledge MCP server. This capability covers the plugin's manifest and marketplace entry, the skill, the MCP registration, the fact that the plugin registers no hooks, and how tagents itself is installed.

## Requirements

### Requirement: The repository is a plugin and its own marketplace
The repository SHALL be installable as the Claude Code plugin `tagents`, from a marketplace named `tagents` defined in `.claude-plugin/marketplace.json` that lists exactly one plugin, `tagents`, whose source is the repository root. The plugin manifest `.claude-plugin/plugin.json` names the plugin `tagents` and carries a description, the MIT licence, the repository URL and the MCP server registration. Its `version` and `metadata.digest` belong to the `plugin-contract` capability.

#### Scenario: One plugin in the marketplace
- **WHEN** the marketplace file is read
- **THEN** it holds one plugin entry named `tagents` with the source `./`

### Requirement: Installing the plugin
With Claude Code 2.1.275 or later the plugin SHALL be installable with `/plugin install tagents --marketplace <owner>/tagents`; with an earlier version the marketplace SHALL first be added with `/plugin marketplace add <owner>/tagents` and the plugin then installed with `/plugin install tagents@tagents`.

#### Scenario: A current Claude Code
- **WHEN** the one-line install is run
- **THEN** the skill and the MCP server described below become available to sessions

### Requirement: The plugin gives a session the tagents skill
The plugin SHALL ship one skill, `tagents`, in `skills/tagents/SKILL.md`. Its description SHALL say when to load it: driving tagents from a session or a script, and writing code or a plugin against `@tagents/core`, `@tagents/knowledge`, `@tagents/notify` or `@tagents/telegram`. Its body is a hand-written index that sends the reader to the generated reference for the surface in question.

#### Scenario: When it applies
- **WHEN** a session opens, prompts, lists or aborts headless sessions, finds a past session, searches the knowledge documents, reads cost with `tusage`, or calls a flag of the dashboard or of `tnotes`
- **THEN** the skill's description matches the task

#### Scenario: Which reference
- **WHEN** a session needs to open, prompt, list or abort a headless session, or manage plugins
- **THEN** the skill points it to `tagents-core` and `references/cli.md`

#### Scenario: Other surfaces
- **WHEN** a session needs MCP tools, cost accounting, dashboard or notes flags, or the TypeScript API
- **THEN** the skill points to `references/mcp.md`, `references/scripts.md` or the `*.api.md` of the package respectively

#### Scenario: The contract as data
- **WHEN** a script wants to check a verb or a tool schema
- **THEN** the skill names `contract.json` in the plugin root as the same contract as data

### Requirement: What the skill says holds everywhere
The skill SHALL state four things: a verb the `tagents` script has no flag for is handed to `tagents-core` unchanged; a JSON verb prints one pretty-printed document on stdout, except `session prompt --events`, which prints one compact JSON line per event and then the outcome; exit codes carry the outcome and are checked before output is parsed; `tagents-core`, `tagents-knowledge`, `tagents-notify` and `tagents-mcp` must be on `PATH`.

#### Scenario: Common mistakes
- **WHEN** the skill lists the mistakes to avoid
- **THEN** they are trusting a remembered flag, running into a verb the references list but the installed binary lacks (the binaries are older than the plugin), and editing `references/` or `contract.json`, which are generated through `pnpm plugin:gen`

#### Scenario: The forwarding rule
- **WHEN** a session reads the skill
- **THEN** it learns that `tagents session list` and `tagents-core session list` are the same call, as the `cli-dispatch` capability specifies

### Requirement: The plugin registers the knowledge MCP server
The plugin manifest SHALL register an MCP server `knowledge`, started as the command `sh` with the argument `${CLAUDE_PLUGIN_ROOT}/packages/knowledge/bin/knowledge-mcp`. The tools it offers are those of the `knowledge` capability. A server of the same kind registered by hand with `claude mcp add` SHALL be removed, or the tools appear twice. The manifest registers one more server, `tagents`, which another requirement specifies.

#### Scenario: Registered by the manifest
- **WHEN** the plugin is installed and a session starts
- **THEN** a `knowledge` MCP server is started with `sh ${CLAUDE_PLUGIN_ROOT}/packages/knowledge/bin/knowledge-mcp`

#### Scenario: Registered twice
- **WHEN** a hand-made registration of the same server exists as well
- **THEN** its tools appear twice

### Requirement: The server entry falls back to a server of its own
The script `packages/knowledge/bin/knowledge-mcp` SHALL join the session to the shared server of the `knowledge` capability: it runs `tagents-knowledge serve`, and when that prints a socket that exists and `nc` is available, it replaces itself with `nc -U` on that socket. Otherwise it SHALL run `tagents-knowledge mcp`, so `tagents-knowledge` must be on `PATH`.

#### Scenario: Shared server available
- **WHEN** `tagents-knowledge serve` prints an existing socket and `nc` is on `PATH`
- **THEN** the process the session started is `nc -U` on that socket

#### Scenario: No shared server
- **WHEN** `serve` fails or is an unknown verb, or there is no `nc`
- **THEN** the session gets `tagents-knowledge mcp` with the same tools

### Requirement: The plugin registers no hooks
The plugin SHALL register no Claude Code hooks and no status line, because a plugin cannot set a status line. `tagents setup` registers the agent-state hook and the status line in the user's `settings.json` files, as the `claude-settings` capability specifies.

#### Scenario: Nothing hooked
- **WHEN** the plugin's manifest and files are inspected
- **THEN** there is no hooks declaration and no `hooks/hooks.json`; `hooks/claude-settings.json` is what `tagents setup` writes into settings files, not a registration Claude Code reads from the plugin, and the hook scripts under `hooks/` reach `~/.claude/hooks` through `install.sh`

### Requirement: Installing tagents
`sh install.sh` from a clone, or `curl -fsSL https://raw.githubusercontent.com/SkuratovichA/tagents/main/install.sh | sh`, SHALL install ONE managed copy in `$TAGENTS_HOME` (default `~/.local/share/tagents`): a clone detached on `origin/main`, made when absent, built with `pnpm install --frozen-lockfile && pnpm build`, not moved while it has local changes. It needs `git`, `node` 22.18 or newer and `pnpm`. The hook and the status line are registered by `tagents setup` (see `claude-settings`).

#### Scenario: Piped from curl
- **WHEN** the one-line `curl … | sh` runs on a machine with no managed copy
- **THEN** the repository is cloned into `~/.local/share/tagents`, built, and the wrappers of the next requirement exist

#### Scenario: A directory that is not a copy
- **WHEN** `$TAGENTS_HOME` exists, holds files and is not a clone
- **THEN** the installer refuses to touch it and exits 1

#### Scenario: Local changes
- **WHEN** the managed copy has local changes and `main` has moved
- **THEN** the copy is not moved and the exit code is 1

#### Scenario: The hook events
- **WHEN** the installer has registered the hook
- **THEN** it is registered for every event `claude-settings` names, with `PreToolUse`, `PostToolUse` and `SubagentStop` as `"async": true` so they never sit in the tool-call path

#### Scenario: The status line
- **WHEN** the installer has configured the status line
- **THEN** its command runs `claude-statusline.sh` from the hooks directory `claude-settings` chooses, which feeds the model column

### Requirement: Prerequisites and the checkout rule
`tagents` SHALL need `tmux`, `fzf`, `jq` and `awk`, and SHALL be written for bash 3.2, the newest bash macOS ships. The `tagents` script is the entry point of a checkout, not a file to copy on its own: the rest lives in `lib/tagents/*.sh` beside the real file, and a lone copy says so and stops, as the `cli-dispatch` capability specifies.

#### Scenario: A lone copy
- **WHEN** `tagents` is copied without `lib/tagents/`
- **THEN** it refuses to run instead of half-working

### Requirement: The parts of the ecosystem
The repository SHALL pair the bash dashboard `tagents` (tmux and fzf) with TypeScript packages: `@tagents/core` (headless sessions and plugins, behind `tagents-core`), `@tagents/knowledge` (the owner's notes as markdown, a CLI and an MCP server), `@tagents/telegram` (a typed Bot API client), `@tagents/notify` (desktop notifications), `@tagents/mcp` (the MCP server of the contract's tools) and `@tagents/contract` (the contract generator). Plugins are further packages the config names.

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

### Requirement: An update is finished by the installer of the commit it moves to
When an update moves the managed copy to another commit, `install.sh` SHALL hand the rest of the run to the `install.sh` of that commit, with the same arguments and with `TAGENTS_MOVED_FROM` set to the commit it moved from, so that the build, the return to that commit when the build fails, and the commands, hooks and LaunchAgent come from the new installer in the same run. A commit whose `install.sh` does not take `TAGENTS_MOVED_FROM` is finished by the running installer.

#### Scenario: One update installs what the new installer writes
- **WHEN** the copy stands on a commit whose `install.sh` writes the wrappers one way, and `tagents update` moves it to a commit whose `install.sh` writes them another way
- **THEN** after that one update the command and hook wrappers are written the new way, the update exits 0, reports the move once and leaves no lock behind

#### Scenario: The build of the new commit fails
- **WHEN** an update moves the copy and the build of the new commit fails
- **THEN** the copy is back on the commit it was on, and the update exits 1 and says so

#### Scenario: The new commit's installer does not take the hand-over
- **WHEN** an update moves the copy to a commit whose `install.sh` does not take `TAGENTS_MOVED_FROM`
- **THEN** the running installer builds the copy and writes the wrappers itself, and the update exits 0

### Requirement: The installer writes wrappers, not symlinks
`install.sh` SHALL write a real-file wrapper into `~/.local/bin` for each of `tagents`, `tusage`, `tnotes`, `tagents-core`, `tagents-knowledge`, `tagents-notify` and `tagents-mcp`, and one per `hooks/*.sh` into `~/.claude/hooks` or each repeatable `--hooks-dir DIR`; a wrapper runs the same file of the managed copy.

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
The server SHALL list one tool for each verb of each structured CLI spec recorded in the contract, except the verbs whose effect is `serve` and the verbs recorded with `"tool": false`, and SHALL contain no knowledge of any verb. A verb added to a spec is therefore a tool once the contract is regenerated and the plugin updated.

#### Scenario: A verb in the contract
- **WHEN** `contract.json` records a verb that is not `serve`
- **THEN** the server lists a tool for it, whatever the verb is

#### Scenario: A verb that serves
- **WHEN** `contract.json` records a verb with the effect `serve`
- **THEN** the server lists no tool for it

#### Scenario: A verb that is not for a model
- **WHEN** `contract.json` records a verb with `"tool": false`, such as `tagents-core session prompt`
- **THEN** the server lists no tool for it, and the verb stays in the `cli` section of the contract and in the references

### Requirement: A tool is named after its verb
The tool of a verb SHALL be named `<program>_<words of the verb>`: the program name without its `tagents-` prefix, then each word without leading dashes, every run of other characters becoming one underscore. Two verbs that would give the same name SHALL stop the generator.

#### Scenario: Names
- **WHEN** the verbs `session list` of `tagents-core`, `send` of `tagents-notify` and `--window` of the script are listed
- **THEN** the tools are `core_session_list`, `notify_send` and `tagents_window`

### Requirement: A tool says what it starts in its first words
The description of a tool SHALL be the verb's summary as one sentence. A verb that starts a Claude session, a window, a service or a Claude turn SHALL open its summary with `starts`, `opens`, `runs` or `installs`, because the description is what Claude Code shows when it asks the user to allow the call.

#### Scenario: What the permission prompt shows
- **WHEN** a client asks the user to allow `tagents_new` or `tagents_window`
- **THEN** the description it shows begins with what the call starts

### Requirement: A tool's arguments are the verb's own
The input schema of a tool SHALL have one property for each positional of the verb, named after its placeholder in lower case (an array of strings for `<words…>`, a string otherwise), one for each option typed as the option is, and `required` listing the required ones, and no other property. A call SHALL pass each string option as `--name=value`, a boolean option as `--name` when it is true and not at all when it is false, and then the positionals, each as one word of its own.

#### Scenario: A value that starts with a dash
- **WHEN** `notify_send` is called with the `title` `--x`
- **THEN** the verb receives `--title=--x`, so the value stays a value

#### Scenario: A value with a newline or an equals sign
- **WHEN** `notify_send` is called with a `title` of `a=b` and a newline, and message words that hold a newline
- **THEN** the verb receives the title as the one word `--title=a=b` and a newline, and each message word as one word of its own, so nothing is split or joined on the way

### Requirement: Arguments are checked before anything runs
A call with an argument the schema does not list, a missing required argument, an argument of the wrong type, a positional that starts with a dash or an argument holding a NUL byte SHALL be refused with the exit `usage` (2) of the verb's program, and nothing SHALL run. A NUL byte is refused because the operating system cannot start a program with one in its arguments, and the refusal is an answer, not a failure of the call.

#### Scenario: A message that looks like a flag
- **WHEN** `notify_send` is called with the message words `--title`
- **THEN** the call is refused with an error saying the argument starts with a dash and nothing is run

#### Scenario: A NUL byte
- **WHEN** `notify_send` is called with a message word that holds a NUL byte
- **THEN** the call is refused with exit 2 and an error saying the argument contains a NUL byte, and nothing is run

#### Scenario: A required argument is missing
- **WHEN** `tagents_window` is called with a `dir` and no `command`
- **THEN** the call fails with exit 2 and an error naming `command`, and nothing is run

### Requirement: A call answers with how the verb ended
A call SHALL run the verb's program from `PATH` with the server's own environment and no standard input, and answer with one JSON document holding `exit`, `outcome`, `stdout` and `stderr`. `outcome` is the name of the code in the program's exit table, or `exit <n>` when it has none, or `cancelled` for a call that was stopped; `stdout` is parsed when it is a JSON document and is text otherwise. An exit code other than 0 SHALL make the answer an error.

#### Scenario: A verb that fails
- **WHEN** `core_session_last` is called with a reference that does not exist and the verb exits 1
- **THEN** the answer is an error whose document holds `"exit": 1`, `"outcome": "error"` and the message on stderr

#### Scenario: A verb that prints JSON
- **WHEN** `core_plugin_list` is called with `json` true
- **THEN** the answer's `stdout` is the parsed document, not a string

### Requirement: A call's output is capped in bytes
Each of `stdout` and `stderr` SHALL be kept to its first 262144 bytes (256 KiB), counted in bytes and cut before the character the cap falls in, so the text stays valid UTF-8. A cut stream SHALL end with a line `[output cut at 262144 bytes]`, the document SHALL say `"truncated": true`, and a cut `stdout` is text and is not parsed as JSON.

#### Scenario: Output over the cap
- **WHEN** a verb prints 300 KiB of text on stdout
- **THEN** `stdout` holds the first 262144 bytes, ends with the line `[output cut at 262144 bytes]`, and the document says `"truncated": true`

#### Scenario: The cap falls inside a character
- **WHEN** a verb prints three-byte characters and the 262144th byte is the second byte of one
- **THEN** that character is not in `stdout`, no replacement character stands in for it, and what precedes it is whole

### Requirement: A call is bounded in time
A verb that has not ended after five minutes SHALL be stopped as the requirement that nothing outlives a call says, and answered as exit 4, outcome `timeout`. A program that is not on `PATH` SHALL be answered as exit 1 with its name in `stderr`.

#### Scenario: A program that is not installed
- **WHEN** `notify_send` is called and `tagents-notify` is not on `PATH`
- **THEN** the answer is an error with exit 1 whose `stderr` says `tagents-notify is not on PATH`

#### Scenario: A verb that does not end
- **WHEN** a verb has not ended after five minutes
- **THEN** the answer is an error with exit 4 and outcome `timeout`, and nothing the verb started is left running

### Requirement: A call stops everything it started
The server SHALL start each program as the leader of a process group of its own. When a call is stopped, by the timeout or by the cancellation of its request, the whole group SHALL be sent SIGTERM and, after a grace of two seconds, SIGKILL. A stopped call is answered as an error with outcome `cancelled`, and a request cancelled before its program started SHALL not start it.

#### Scenario: The client cancels a call
- **WHEN** a client cancels a request whose program has started another process
- **THEN** both processes are gone within the grace

#### Scenario: A program that ignores SIGTERM
- **WHEN** a call is stopped and its program ignores SIGTERM
- **THEN** the program is still running when the grace begins and is killed with SIGKILL when it ends

#### Scenario: Cancelled before it started
- **WHEN** a request that was already cancelled reaches the server
- **THEN** the program is not started

### Requirement: What a program leaves behind dies with it
When a program has exited, whatever is left in its process group SHALL be killed at once. The call SHALL wait for the program's output pipes for a moment only after the exit, so that a process which left the group and holds them cannot keep the call open.

#### Scenario: A grandchild holds the pipes
- **WHEN** a program exits at once and leaves a process running that holds its stdout
- **THEN** the call is answered with the program's own exit within a moment of that exit, and the process it left is gone

### Requirement: The server's end is the end of its calls
When the server's standard input closes, or the server receives SIGTERM, SIGINT or SIGHUP, it SHALL stop every call in flight as above and exit once they have ended.

#### Scenario: The session closes
- **WHEN** Claude Code closes the server's standard input while a call is running
- **THEN** the program of the call and everything it started are gone, and the server exits

#### Scenario: The server is signalled
- **WHEN** the server receives SIGTERM, SIGINT or SIGHUP while a call is running
- **THEN** the program of the call and everything it started are gone, and the server exits

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

### Requirement: A tool may default an option its verb leaves off
A boolean option that a verb's spec lists in `toolDefaults` SHALL appear in the tool's input schema with that `default`, and a call that leaves the option out SHALL run the verb as if the caller had given that value. A caller who gives the other value SHALL get it. `tagents_new` and `tagents_window` SHALL default `detach` to true, so a window opened by a tool is not selected and takes the screen from nobody.

#### Scenario: The default applies
- **WHEN** `tagents_window` is called with a `dir` and a `command` and no `detach`
- **THEN** the verb receives `--detach`, and the new window is not selected

#### Scenario: The caller chooses
- **WHEN** `tagents_window` is called with `detach` false
- **THEN** the verb receives no `--detach`, and the new window is selected as for a human at the CLI

#### Scenario: The schema says so
- **WHEN** a client lists `tagents_new`
- **THEN** its `detach` property is a boolean whose default is true

### Requirement: A contract from a newer generator still serves
The server SHALL read `contract.json` so that a verb with an effect it does not know is served as a verb with no effect, and a key it does not know is ignored, and neither SHALL take any tool away. A file that is not JSON or has no `cli` section SHALL still stop the server with the reason on stderr.

#### Scenario: An effect nobody has heard of
- **WHEN** the contract records a verb with the effect `quarantine`
- **THEN** the server lists its tool with the annotations of a verb that declares no effect

#### Scenario: A key nobody has heard of
- **WHEN** the contract holds a key on a verb that this server does not read
- **THEN** the tool is listed as it would be without the key

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

### Requirement: The installer writes only over its own files
`install.sh` SHALL write a wrapper only over a symlink or a file with the installer's marker line; any other file is left alone with a warning and exit 1 at the end. A wrapper whose hook the project dropped is removed.

#### Scenario: A symlink in the way
- **WHEN** `~/.local/bin/tusage` is a symlink to a file of an earlier checkout
- **THEN** it is replaced by a wrapper, and the file it pointed at is untouched

### Requirement: The bash scripts do not need the workspace
The bash scripts SHALL neither import nor need the TypeScript workspace.

#### Scenario: A script runs without a build
- **WHEN** `tagents` runs from a copy that holds only the script and `lib/tagents`, with no `packages/` and no `node_modules`
- **THEN** it dispatches the verbs and forwards their flags to the `tagents-core` on the `PATH`, answers its own flags and refuses an unknown one, and with no `tagents-core` on the `PATH` it exits 2 and says so

### Requirement: The tagents-mcp command runs the native server when the binary is installed
When `$TAGENTS_HOME/target/release/tagents-core` is an executable file at install time, the `tagents-mcp` wrapper SHALL run it as `tagents-core mcp` with the wrapper's arguments after the word, and otherwise, or when the binary is gone or not executable at run time, SHALL run the node server. The word SHALL be the only difference from the `tagents-core` wrapper's line, and the pinned node SHALL be handed over as for `tagents-core`.

#### Scenario: The binary is installed
- **WHEN** the binary is installed and `tagents-mcp a b` runs
- **THEN** the binary receives `mcp a b` (`tests/install.sh` section 14)

#### Scenario: Arguments with a space or empty
- **WHEN** `tagents-mcp "a b" ""` runs over an installed binary
- **THEN** the binary receives the word and each argument whole (`tests/install.sh` section 13)

#### Scenario: The binary vanishes after the install
- **WHEN** the file is removed or loses its executable bit
- **THEN** the same wrapper runs the node server (`tests/install.sh` section 13)

### Requirement: The tagents-mcp wrapper without a binary is the node wrapper
With no executable binary at install time the installer SHALL write the `tagents-mcp` wrapper byte for byte as it wrote it before a native server existed, and `plugin.json` SHALL register the same command, `tagents-mcp --contract ${CLAUDE_PLUGIN_ROOT}/contract.json`, in both cases.

#### Scenario: No binary
- **WHEN** the installer runs on a machine without the binary
- **THEN** `tagents-mcp` is the node wrapper and `tagents-mcp a b` runs `packages/mcp/dist/main.js` (`tests/install.sh` section 13)

### Requirement: A machine with no release keeps the node server
`TAGENTS_NO_NATIVE=1`, a failed or refused fetch and a version without a release SHALL leave the `tagents-mcp` wrapper as the node wrapper, so no machine is without a server.

#### Scenario: No release for the version
- **WHEN** the installer runs on a copy whose version has no release
- **THEN** the old binary is removed and `tagents-mcp` runs the node server (`tests/install.sh` section 14)

#### Scenario: Native disabled
- **WHEN** the installer runs with `TAGENTS_NO_NATIVE=1` over an installed binary
- **THEN** the binary is removed and `tagents-mcp` runs the node server (`tests/install.sh` section 14)

### Requirement: The tagents-core wrapper runs a Rust binary built before the install
When `$TAGENTS_HOME/target/release/tagents-core` is an executable file at the time of the install, the `tagents-core` wrapper SHALL run it, with the node it pinned passed on as `TAGENTS_NODE`, for as long as it is an executable file, and the node CLI otherwise. Both files belong to the managed copy, so the wrapper runs nothing outside it, and the installer never builds that binary.

#### Scenario: A Rust binary built before the install
- **WHEN** `$TAGENTS_HOME/target/release/tagents-core` is executable when the installer runs, and `tagents-core sessions recent` is run
- **THEN** the wrapper runs that binary with the whole argument list, its exit code is the result, and `TAGENTS_NODE` holds the node the installer pinned

#### Scenario: The Rust binary is gone
- **WHEN** the binary the wrapper names has been removed, or replaced by a directory or by a file without the executable bit, after the install
- **THEN** the wrapper runs the node CLI exactly as the wrapper of an install with no Rust binary does

#### Scenario: A Rust binary that cannot run
- **WHEN** a file that is executable but cannot run, because its interpreter is missing, sits at `target/release/tagents-core` when the installer runs
- **THEN** the installed wrapper names it and runs it, and the failure to run it is an error and never a fallback to the node CLI

### Requirement: Without a usable Rust binary the wrapper is the old one
When `$TAGENTS_HOME/target/release/tagents-core` is not an executable file at the time of the install, whether it does not exist, lacks the executable bit or is a directory, the `tagents-core` wrapper SHALL be byte for byte the one written when no Rust binary existed.

#### Scenario: No Rust binary
- **WHEN** the installer runs and `$TAGENTS_HOME/target/release/tagents-core` does not exist
- **THEN** every wrapper it writes is byte for byte what the installer wrote before the Rust binary existed

#### Scenario: A file without the executable bit
- **WHEN** a file without the executable bit sits at `$TAGENTS_HOME/target/release/tagents-core` when the installer runs
- **THEN** the plain wrapper is written, which runs the node CLI and names no Rust binary

#### Scenario: A directory where the Rust binary would be
- **WHEN** a directory sits at `$TAGENTS_HOME/target/release/tagents-core` when the installer runs
- **THEN** the plain wrapper is written, which runs the node CLI and names no Rust binary
