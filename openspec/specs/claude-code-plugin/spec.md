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
The plugin SHALL ship one skill, `tagents`, in `skills/tagents/SKILL.md`. Its description SHALL say when to load it: driving tagents from a session or a script, and writing code or a plugin against `@tagents/core`, `@tagents/knowledge` or `@tagents/telegram`. Its body is a hand-written index that sends the reader to the generated reference for the surface in question.

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
The skill SHALL state four things: a verb the `tagents` script has no flag for is handed to `tagents-core` unchanged; a JSON verb prints one pretty-printed document on stdout, except `session prompt --events`, which prints one compact JSON line per event and then the outcome; exit codes carry the outcome and are checked before output is parsed; `tagents-core` and `tagents-knowledge` must be on `PATH`.

#### Scenario: Common mistakes
- **WHEN** the skill lists the mistakes to avoid
- **THEN** they are trusting a remembered flag, running into a verb the references list but the installed binary lacks (the binaries are older than the plugin), and editing `references/` or `contract.json`, which are generated through `pnpm plugin:gen`

#### Scenario: The forwarding rule
- **WHEN** a session reads the skill
- **THEN** it learns that `tagents session list` and `tagents-core session list` are the same call, as the `cli-dispatch` capability specifies

### Requirement: The plugin registers the knowledge MCP server
The plugin manifest SHALL register one MCP server, `knowledge`, started as the command `sh` with the argument `${CLAUDE_PLUGIN_ROOT}/packages/knowledge/bin/knowledge-mcp`. The tools it offers are those of the `knowledge` capability. A server of the same kind registered by hand with `claude mcp add` SHALL be removed, or the tools appear twice.

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
The plugin SHALL register no Claude Code hooks and no status line. The agent-state hook and the status line stay manual installation steps, because a plugin cannot set a status line.

#### Scenario: Nothing hooked
- **WHEN** the plugin's manifest and files are inspected
- **THEN** there is no hooks declaration and no `hooks/` registration file; the hook scripts under `hooks/` are installed by hand

### Requirement: Installing tagents from a checkout
Installing tagents from a checkout SHALL be four steps: put `tagents` and `tusage` on `PATH` by symlink; symlink `hooks/tmux-agent-state.sh` and `hooks/claude-statusline.sh` into `~/.claude/hooks`; register `tmux-agent-state.sh` in `~/.claude/settings.json` under `hooks`; and set `statusLine` to a command running `claude-statusline.sh`. When the repository is a submodule of a dotfiles repository, that repository's bootstrap script performs the steps.

#### Scenario: The hook events
- **WHEN** the hook is registered
- **THEN** it is registered for `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, `SubagentStop` and `SessionEnd`, with `PreToolUse`, `PostToolUse` and `SubagentStop` as `"async": true` so they never sit in the tool-call path

#### Scenario: The status line
- **WHEN** the status line is configured
- **THEN** its command runs `claude-statusline.sh` from `~/.claude/hooks`, which feeds the model column

### Requirement: Prerequisites and the checkout rule
`tagents` SHALL need `tmux`, `fzf`, `jq` and `awk`, and SHALL be written for bash 3.2, the newest bash macOS ships. The `tagents` script is the entry point of a checkout, not a file to copy on its own: the rest lives in `lib/tagents/*.sh` beside the real file, and a lone copy says so and stops, as the `cli-dispatch` capability specifies.

#### Scenario: A lone copy
- **WHEN** `tagents` is copied without `lib/tagents/`
- **THEN** it refuses to run instead of half-working

### Requirement: The parts of the ecosystem
The repository SHALL pair the bash dashboard `tagents` (tmux and fzf, no dependencies of its own) with TypeScript packages: `@tagents/core` (headless sessions and the plugin host, behind `tagents-core`), `@tagents/knowledge` (the owner's notes as searchable markdown documents, a CLI and an MCP server) and `@tagents/telegram` (a typed Telegram Bot API client). Plugins are further packages the config names. The bash scripts neither import nor need the TypeScript workspace.

#### Scenario: One name reaches all of it
- **WHEN** a user types `tagents plugin list`, `tagents session list` or `tagents doctor`
- **THEN** it works from the dashboard's name, because the verb is forwarded to `tagents-core`
