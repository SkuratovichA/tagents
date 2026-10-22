## MODIFIED Requirements

### Requirement: enter resumes the chosen session on the account it ran on
`enter` SHALL resume the picked session with `claude --resume <id>` on the account it ran on, in the directory it last ran in, in a new window of the tmux session of the group the dashboard cursor was in (the session of the client when it was on the group `no window`), and select it as `enter` on a live agent would. The command is built by the `accounts` capability and the launch is `chat-launch`'s. Afterwards the dashboard list SHALL reload.

#### Scenario: Work session
- **WHEN** the user picks a session of the profile `work`, which has no config directory
- **THEN** it is started with `--resume <id>` with no `CLAUDE_CONFIG_DIR` set, in its directory

#### Scenario: Personal session
- **WHEN** the user picks a session of the profile `personal`
- **THEN** it comes back on that profile's config directory

#### Scenario: Unknown account
- **WHEN** the session's account is `?`
- **THEN** it is resumed on the default login and not on a profile called `?`

#### Scenario: Owning session
- **WHEN** the dashboard cursor was on a row of the tmux session `proj`
- **THEN** its new window is created in `proj`
