## ADDED Requirements

### Requirement: The sidebar does not stop a window being named
The sweep SHALL name a window that holds a chat and the sidebar after the chat, as it would without the sidebar, and SHALL leave out a window whose only pane is the sidebar. Moving the sidebar into or out of a window SHALL NOT rename it.

#### Scenario: A window with the sidebar
- **WHEN** a window holds the sidebar and an agent whose title is `Search index rebuild`
- **THEN** the sweep names the window `Search index rebuild`

#### Scenario: A window with only the sidebar
- **WHEN** a window holds nothing but the sidebar
- **THEN** the sweep leaves its name alone

#### Scenario: The sidebar moves
- **WHEN** the sidebar moves from one window to another
- **THEN** neither window is renamed because of it

### Requirement: A label names the agent's window from outside
`tagents --label KEY [NAME]` SHALL store the label for KEY, a session id or a pane id, and SHALL rename the agent's window at once, including a window it shares with other panes or with the sidebar, then exit 0. With no KEY it SHALL print a usage error on stderr and exit 2. An empty NAME SHALL remove the label, turn `automatic-rename` back on for the window and drop `@tagents_name`, so the sweep names the window from the titles again.

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

#### Scenario: An agent beside the sidebar
- **WHEN** `--label` names an agent whose window holds the sidebar
- **THEN** the window takes the label

## REMOVED Requirements

### Requirement: What the sweep never names
**Reason**: There is no dashboard window and no docked chat any more, and a window with a list in it is where the user's chat is, so excluding it would freeze the name of the window on screen.
**Migration**: "The sidebar does not stop a window being named" in this capability.

### Requirement: Naming an agent from outside
**Reason**: Its rule about a docked agent not renaming the dashboard window has no meaning without docking.
**Migration**: "A label names the agent's window from outside" in this capability, with the docked-agent scenario replaced by one for an agent beside the sidebar.
