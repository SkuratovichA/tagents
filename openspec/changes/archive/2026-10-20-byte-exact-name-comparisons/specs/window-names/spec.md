## MODIFIED Requirements

### Requirement: A window is named after its agent
The sweep SHALL rename a window that holds a live agent to that agent's display name: the label given with ctrl-r or `tagents --label` when there is one, otherwise the pane's terminal title (what Claude's `/rename` sets) without its leading glyph. It SHALL NOT use the directory name. An agent with no label whose title is only the machine's host name, short or full, or is empty, has no name to give and SHALL leave its window alone, claiming nothing.

#### Scenario: A new agent
- **WHEN** an agent whose title is `fix-login-bugs` lives alone in a window with tmux's automatic name and a sweep runs
- **THEN** the window is named `fix-login-bugs` and `automatic-rename` is off for it
- **AND** the window option `@tagents_name` records `fix-login-bugs`

#### Scenario: The title is the host name
- **WHEN** an agent's title is the machine's host name and a sweep runs
- **THEN** its window keeps the name it had and `@tagents_name` stays unset

#### Scenario: A window with no agent
- **WHEN** a window holds only shells
- **THEN** a sweep does not rename it


#### Scenario: A title that only begins with the host name
- **WHEN** an agent's title is the host name followed by `я`
- **THEN** the window is named after that title, since a title is the host name only when every byte is the same
