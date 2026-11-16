## RENAMED Requirements

- FROM: `### Requirement: The plugin registers no hooks`
- TO: `### Requirement: The plugin registers one session hook`

## MODIFIED Requirements

### Requirement: The plugin registers one session hook
The plugin SHALL register one Claude Code hook, `SessionStart`, in `hooks/hooks.json`, and no status line, because a plugin cannot set a status line. `tagents setup` registers the agent-state hook and the status line in the user's `settings.json` files, as the `claude-settings` capability specifies.

#### Scenario: Nothing hooked
- **WHEN** the plugin's manifest and files are inspected
- **THEN** `hooks/hooks.json` registers `SessionStart` and no other event; `hooks/claude-settings.json` is what `tagents setup` writes into settings files, not a registration Claude Code reads from the plugin, and the hook scripts under `hooks/` reach `~/.claude/hooks` through `install.sh`
