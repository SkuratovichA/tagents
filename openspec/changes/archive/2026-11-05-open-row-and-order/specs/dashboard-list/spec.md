## ADDED Requirements

### Requirement: The row on screen is marked
The row of the window the viewport shows SHALL carry a `▸` in the place of the tree's dash and be drawn bold, in the tree and in a flat list, on a chat row and on a dimmed window row alike. A header and a child without a pane in that window SHALL NOT be marked. The mark SHALL not change the width of any row or the tally, and SHALL follow the viewport when it changes window or session.

#### Scenario: The window on screen
- **WHEN** the viewport shows a window that holds a chat
- **THEN** that chat's row starts with `▸` and is bold, and no other row is marked

#### Scenario: A window with two chats
- **WHEN** the viewport shows a window that holds two chats
- **THEN** both rows are marked

#### Scenario: The viewport moves
- **WHEN** the viewport changes to another window
- **THEN** the mark is on that window's row once the refresher has reloaded the list

### Requirement: Rows can keep their window's place
The toggle `ctrl-o`, the verb `order`, SHALL switch the rows of a group between the default order and window order, and the choice SHALL be kept until it is switched back. In window order the rows that are not closed SHALL follow their tmux window numbers, then pane indexes, a dimmed window at its number among the chats, a child with its parent, and a row with no window at the end of its group. Closed rows and groups SHALL keep their place.

#### Scenario: Window order
- **WHEN** three windows hold chats the user typed into in the order 3, 1, 2 and the user presses `ctrl-o`
- **THEN** the rows are listed in the order of the window numbers 1, 2, 3

#### Scenario: A prompt does not move a row
- **WHEN** window order is on and the user sends a prompt to the chat in the last window
- **THEN** its row keeps its place after the next refresh

#### Scenario: Back to the default
- **WHEN** the user presses `ctrl-o` again
- **THEN** the rows are ordered by the user's last message

## MODIFIED Requirements

### Requirement: Inside a group rows follow the user's last message
Unless window order is on, rows inside a group SHALL be ordered by when the user last typed into the session, newest first, then the dimmed window rows in window order, then the closed rows, and never by state or by anything that changes during a turn. A child SHALL be placed with its parent, parent first, then its own children. In a flat list the same rule applies to the whole list: open rows before closed, newest conversation first.

#### Scenario: State changes do not move rows
- **WHEN** an agent goes from working to blocked and back
- **THEN** its position among its siblings is unchanged

#### Scenario: Typing moves a row to the top
- **WHEN** window order is off and the user sends a prompt to an agent that was second in its group
- **THEN** after the next refresh it is first

#### Scenario: Window rows follow the chats
- **WHEN** a group has a window that runs no chat and two chats
- **THEN** the dimmed row is listed after both chats and before any closed row

### Requirement: The row a group header stands for
The row a header stands in for SHALL be chosen among the rows of the group that are not child sessions: open chats before dimmed window rows before closed rows, and among chats the one typed into most recently. A child is chosen only when the group has nothing else. In window order the header stands for the first printed row: the lowest window among the open chats and the dimmed window rows.

#### Scenario: A chat before a window row
- **WHEN** a group holds a dimmed window row and a live chat
- **THEN** the header carries the key of the live chat

#### Scenario: Only a child
- **WHEN** the only rows of a group are a child session and nothing else
- **THEN** the header carries the child's key

#### Scenario: Window order
- **WHEN** rows are kept in window order and the chat typed into last is in a higher window than another chat of the group
- **THEN** the header carries the key, state, session id and directory of the chat in the lowest window, or of a dimmed window row numbered below every chat, with state none and no session id
