## ADDED Requirements

### Requirement: The viewport's client asks for synchronized updates
The viewport's client SHALL be started with the terminal feature `sync`, whatever tmux reports for a client inside a pane, so that each redraw reaches the outer terminal inside one synchronized update and the cursor stays where it is.

#### Scenario: The client is attached
- **WHEN** the viewport's client is attached
- **THEN** its `client_termfeatures` holds `sync`
