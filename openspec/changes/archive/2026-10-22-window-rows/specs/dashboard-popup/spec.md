## RENAMED Requirements
- FROM: `### Requirement: A popup claims no pane and has no seat`
- TO: `### Requirement: A popup claims no pane and brings the sidebar to the chat`

## MODIFIED Requirements

### Requirement: A popup claims no pane and brings the sidebar to the chat
A popup list SHALL NOT claim the pane it runs in, since a popup has none of its own. `enter` on an agent SHALL select its row as the `window-rows` capability describes: the sidebar is moved into the agent's window, started first with `tagents --ensure-dash` when none exists, and the client is taken there, after which the popup closes.

#### Scenario: Open from the popup
- **WHEN** the user presses `enter` on an agent in a popup list
- **THEN** the sidebar is in the agent's window, the client shows it and the popup closes
