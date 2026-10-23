## MODIFIED Requirements

### Requirement: ctrl-x kills an agent after asking
`ctrl-x` SHALL ask `kill this agent?`, naming the agent, its tmux location and what will happen, and SHALL act only on `y`, `yes` or their capitals; anything else, or no answer within 60 seconds, cancels. Confirming SHALL hang up the Claude and close its pane (and its window when it was the only pane there besides the sidebar, the sidebar being moved to the window the client lands on first), ring the refresher's channel and leave the session resumable as a closed row. On a dimmed window row `ctrl-x` SHALL instead ask `kill this window?` and close the window, as the `window-rows` capability describes.

#### Scenario: Confirmed
- **WHEN** the user answers `y` for a live agent
- **THEN** its pane is gone and its row becomes `closed — enter resumes it`

#### Scenario: Anything else
- **WHEN** the user answers `n` or presses enter on an empty line
- **THEN** nothing is killed

#### Scenario: The sidebar survives
- **WHEN** the user confirms on the only chat of a window that holds nothing else but the sidebar
- **THEN** the window is closed and the sidebar is in the window now on screen

### Requirement: Pane verbs refuse pane-less rows
On a headless or child row, `enter`, `ctrl-s`, `ctrl-g`, `ctrl-e` and `ctrl-r` SHALL only show a one-line notice: `tagents: headless session — no pane to open, type into or rename (ctrl-v follows its log)` or, for a child, `tagents: child session — no pane to open, type into or rename (ctrl-v shows its transcript)`. On a dimmed window row `enter` and `ctrl-g` SHALL select the window and `ctrl-x` SHALL ask to kill it, as the `window-rows` capability describes, while `ctrl-s`, `ctrl-u`, `ctrl-e` and `ctrl-r` SHALL only show `tagents: that window runs no chat`.

#### Scenario: Headless enter
- **WHEN** the user presses `enter` on a headless row
- **THEN** the headless notice is shown and no window is created

#### Scenario: Dimmed row
- **WHEN** the user presses `ctrl-e` on a dimmed window row
- **THEN** nothing is typed anywhere and `tagents: that window runs no chat` is shown

#### Scenario: ctrl-x on a dimmed row asks
- **WHEN** the user presses `ctrl-x` on a dimmed window row
- **THEN** `kill this window?` is asked and `tagents: that window runs no chat` is not shown
