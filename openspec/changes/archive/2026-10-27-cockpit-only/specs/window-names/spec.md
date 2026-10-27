## RENAMED Requirements

- FROM: `### Requirement: The sidebar does not stop a window being named`
- TO: `### Requirement: The dashboard's own window is never named`

## MODIFIED Requirements

### Requirement: The dashboard's own window is never named
The sweep SHALL NOT rename the dashboard's own window, the one window of the session `tagents`, and SHALL name every window that holds a chat after the chat as it always did.

#### Scenario: The dashboard's window
- **WHEN** the cockpit is up and the sweep runs
- **THEN** the window of the session `tagents` keeps its name

#### Scenario: A chat's window
- **WHEN** a window holds an agent whose title is `Search index rebuild`
- **THEN** the sweep names the window `Search index rebuild`

### Requirement: A label names the agent's window from outside
`tagents --label KEY [NAME]` SHALL store the label for KEY, a session id or a pane id, and SHALL rename the agent's window at once, including a window it shares with other panes, then exit 0. With no KEY it SHALL print a usage error on stderr and exit 2. An empty NAME SHALL remove the label, turn `automatic-rename` back on for the window and drop `@tagents_name`, so the sweep names the window from the titles again.

#### Scenario: A label renames at once
- **WHEN** `tagents --label sid-e named-by-hand` is run for an agent in a window
- **THEN** the window is named `named-by-hand` and `@tagents_name` records it
- **AND** a later sweep keeps that name

#### Scenario: A shared window
- **WHEN** an agent that shares its window with another agent is labelled
- **THEN** the window takes the label

#### Scenario: A name with a hash
- **WHEN** the label is `ticket #Sup-42`
- **THEN** the window is named exactly that and `@tagents_name` equals it

#### Scenario: An empty name
- **WHEN** the label of the agent is cleared with an empty NAME
- **THEN** `automatic-rename` is on for its window and `@tagents_name` is unset
- **AND** the next sweep names it after the newest agent in it
