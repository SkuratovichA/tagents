## MODIFIED Requirements

### Requirement: Toggle opens an editor beside the chat
`tnotes toggle <pane>` on a chat that has no editor SHALL split the chat's window horizontally, giving the new editor pane 45 percent of the chat pane's width, start the editor program in the notes folder, and leave the cursor where it was. The editor is an ordinary pane of that window: tnotes SHALL NOT move it afterwards, so it leaves the screen with its window when another row is selected and is there again when the row is selected again.

#### Scenario: First toggle
- **WHEN** `tnotes toggle` is run on a chat with no editor
- **THEN** the chat's window holds the editor as a second pane, beside the chat

#### Scenario: Seats are unaffected
- **WHEN** editors are opened and closed
- **THEN** panes that are not chats or editors stay in their windows, and the user's own panes are not moved by `tnotes`

#### Scenario: Another row selected
- **WHEN** the user selects another row of the dashboard and then selects the chat's row again
- **THEN** the editor is the same pane, still beside the chat, with the width it had
