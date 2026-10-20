## MODIFIED Requirements

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
