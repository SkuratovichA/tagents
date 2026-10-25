## ADDED Requirements

### Requirement: The viewport's client has a terminal descriptor of its own
The viewport's client SHALL take its standard input, output and error from one read-write open of the viewport's tty by its path, not from the pane, so that no other process in the pane shares the descriptor the server writes to it through: a tmux client sets its standard input, output and error back to blocking when it exits, and the server is the only reader of the pane it would block writing to.

#### Scenario: A tmux call in the viewport's pane
- **WHEN** the list is killed and the viewport's pane brings it back with a `tmux split-window` whose standard output is the pane
- **THEN** every descriptor the tmux server holds on the value of `@tagents_viewport_tty` is still writable and non-blocking
