## MODIFIED Requirements

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
