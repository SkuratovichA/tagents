## RENAMED Requirements

- FROM: `### Requirement: Installing tagents from a checkout`
- TO: `### Requirement: Installing tagents`

## MODIFIED Requirements

### Requirement: The plugin registers no hooks
The plugin SHALL register no Claude Code hooks and no status line. The agent-state hook and the status line stay manual installation steps, because a plugin cannot set a status line.

#### Scenario: Nothing hooked
- **WHEN** the plugin's manifest and files are inspected
- **THEN** there is no hooks declaration and no `hooks/` registration file; the hook scripts under `hooks/` reach `~/.claude/hooks` through `install.sh`, and registering them in `~/.claude/settings.json` is a manual step

### Requirement: Installing tagents
`sh install.sh` from a clone, or `curl -fsSL https://raw.githubusercontent.com/SkuratovichA/tagents/main/install.sh | sh`, SHALL install ONE managed copy in `$TAGENTS_HOME` (default `~/.local/share/tagents`): a clone detached on `origin/main`, made when absent, built with `pnpm install --frozen-lockfile && pnpm build`, not moved while it has local changes. It needs `git`, `node` 22.18 or newer and `pnpm`. Registering the hook and the status line in `~/.claude/settings.json` stays manual.

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
- **WHEN** the hook is registered
- **THEN** it is registered for `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, `SubagentStop` and `SessionEnd`, with `PreToolUse`, `PostToolUse` and `SubagentStop` as `"async": true` so they never sit in the tool-call path

#### Scenario: The status line
- **WHEN** the status line is configured
- **THEN** its command runs `claude-statusline.sh` from `~/.claude/hooks`, which feeds the model column

### Requirement: The parts of the ecosystem
The repository SHALL pair the bash dashboard `tagents` (tmux and fzf) with TypeScript packages: `@tagents/core` (headless sessions and plugins, behind `tagents-core`), `@tagents/knowledge` (the owner's notes as markdown, a CLI and an MCP server), `@tagents/telegram` (a typed Bot API client), `@tagents/notify` (desktop notifications) and `@tagents/contract` (the contract generator). Plugins are further packages the config names. The bash scripts neither import nor need the workspace.

#### Scenario: One name reaches all of it
- **WHEN** a user types `tagents plugin list`, `tagents session list` or `tagents doctor`
- **THEN** it works from the dashboard's name, because the verb is forwarded to `tagents-core`

## ADDED Requirements

### Requirement: The installer writes wrappers, not symlinks
`install.sh` SHALL write a real-file wrapper into `~/.local/bin` for each of `tagents`, `tusage`, `tnotes`, `tagents-core` and `tagents-knowledge`, and one per `hooks/*.sh` into `~/.claude/hooks` or each repeatable `--hooks-dir DIR`; a wrapper runs the same file of the managed copy. It writes only over a symlink or a file with the installer's marker line; any other file is left alone with a warning and exit 1 at the end. A wrapper whose hook the project dropped is removed.

#### Scenario: Two Claude config directories
- **WHEN** `install.sh --hooks-dir ~/.claude/hooks --hooks-dir ~/.claude-work/hooks` runs
- **THEN** both directories hold a wrapper for every hook script

#### Scenario: A file of somebody else's
- **WHEN** `~/.local/bin/tusage` exists and was not written by the installer
- **THEN** it is left as it was, a warning names it, and the exit code is 1

#### Scenario: A hook the project dropped
- **WHEN** an update brings a copy that no longer ships `hooks/old.sh`, and `~/.claude/hooks/old.sh` is a wrapper of the installer
- **THEN** that wrapper is removed
