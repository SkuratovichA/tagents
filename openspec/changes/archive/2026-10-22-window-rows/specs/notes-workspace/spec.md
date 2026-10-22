## RENAMED Requirements
- FROM: `### Requirement: Toggle hides and restores the editor`
- TO: `### Requirement: Toggle moves the cursor between the chat and its editor`
- FROM: `### Requirement: Sync without an argument only cleans up`
- TO: `### Requirement: Sync only cleans up`

## MODIFIED Requirements

### Requirement: Command surface
`tnotes` SHALL accept the verbs `toggle <pane>`, `sync`, `send <chat> <dir>`, `close <editor>` and `editor <chat> <dir>`. `sync` takes no pane, and a pane given to it, as an older focus hook passed one, is ignored. Run with no argument, or with `-h` or `--help`, it SHALL print its usage text and exit 0. Any other first argument SHALL print `tnotes: unknown command <word>` on stderr and exit 2.

#### Scenario: Unknown verb
- **WHEN** `tnotes frobnicate` is run
- **THEN** stderr says `tnotes: unknown command frobnicate`
- **AND** the exit status is 2

#### Scenario: Missing arguments
- **WHEN** `tnotes send` or `tnotes editor` is run without both a chat and a directory
- **THEN** stderr says `tnotes: send <chat> <dir>` or `tnotes: editor <chat> <dir>` respectively
- **AND** the exit status is 2

#### Scenario: An old hook's argument
- **WHEN** `tnotes sync %5` is run
- **THEN** it behaves as `tnotes sync` and exits 0

### Requirement: Toggle opens an editor beside the chat
`tnotes toggle <pane>` on a chat that has no editor SHALL split the chat's window horizontally, giving the new editor pane 45 percent of the chat pane's width, start the editor program in the notes folder, and leave the cursor where it was. The editor is an ordinary pane of that window: tnotes SHALL NOT move it afterwards, so it leaves the screen with its window when another row is selected and is there again when the row is selected again.

#### Scenario: First toggle
- **WHEN** `tnotes toggle` is run on a chat with no editor
- **THEN** the chat's window holds the editor as a second pane, beside the chat

#### Scenario: Seats are unaffected
- **WHEN** editors are opened and closed
- **THEN** panes that are not chats or editors stay in their windows, and the sidebar and the user's own panes are not moved by `tnotes`

#### Scenario: Another row selected
- **WHEN** the user selects another row of the dashboard and then selects the chat's row again
- **THEN** the editor is the same pane, still beside the chat, with the width it had

### Requirement: Editor and chat name each other
After an editor is created the chat pane SHALL carry the option `@ta_notes` naming the editor pane, and the editor pane SHALL carry `@ta_notes_for` naming the chat.

#### Scenario: Markers after the first toggle
- **WHEN** an editor has just been created
- **THEN** the chat's `@ta_notes` is the editor's pane id and the editor's `@ta_notes_for` is the chat's pane id

### Requirement: Toggle moves the cursor between the chat and its editor
`tnotes toggle <pane>` on a chat whose editor exists SHALL move the cursor into the editor, selecting the editor's window first when it is not the one on screen, and SHALL move the cursor back into the chat when it is already in the editor. It SHALL NOT hide, move or close the editor. This SHALL be the only operation that moves the cursor into an editor.

#### Scenario: Toggle twice
- **WHEN** `tnotes toggle` is run on a chat with an editor beside it and the cursor is in the chat
- **THEN** the cursor is in the editor and the editor has not moved
- **WHEN** it is run again
- **THEN** the cursor is in the chat

### Requirement: Sync only cleans up
`tnotes sync` SHALL NOT move, hide or split any editor of a living chat. It SHALL close editors whose chat pane no longer exists (see the next requirement), bring back editors parked by an older version, and exit 0.

#### Scenario: The backstop changes nothing
- **WHEN** `tnotes sync` is run twice with every editor beside its chat
- **THEN** every editor stays where it was and is alive

### Requirement: Orphaned editors are closed
`tnotes sync` SHALL close every editor whose chat pane is gone.

#### Scenario: Chat killed
- **WHEN** a chat with an editor is killed and `tnotes sync` runs
- **THEN** the editor pane is gone

### Requirement: The editor program
`tnotes editor <chat> <dir>`, the program the editor pane runs, SHALL open `nvim` on `prompt.md` in `<dir>` with every buffer written automatically when focus or the buffer is left, so that the file on disk is current at all times. When `nvim` exits it SHALL run `send` for the chat, then remove the chat's `@ta_notes` option, and exit 0.

#### Scenario: Quit sends and unlinks
- **WHEN** the user writes a draft and quits the editor
- **THEN** the draft is committed, a reference is left in the chat's input (see the `send` requirements)
- **AND** the editor pane is gone, the chat's `@ta_notes` is unset, and the chat's window no longer holds the editor

#### Scenario: No nvim
- **WHEN** the editor program starts and `nvim` is not on the `PATH`
- **THEN** it reports that on stderr, waits five seconds, and sends nothing
- **AND** the chat's `@ta_notes` is still cleared

#### Scenario: Folder gone
- **WHEN** `<dir>` does not exist when the editor program starts
- **THEN** it prints `tnotes: <dir> is gone` on stderr, waits five seconds and exits 1

### Requirement: Other panes are left alone
`tnotes` SHALL NOT move, split, join or kill any pane that is neither a chat it was asked about nor one of its own editors, and SHALL NOT move an editor after creating it. Its editors are ordinary panes of the chat's window, which the dashboard's selecting, following and joining of rows never move.

#### Scenario: Surrounding windows
- **WHEN** editors are opened and closed
- **THEN** every other pane is alive in the window it started in, and a window holding only a non-chat pane still has that one pane

## ADDED Requirements

### Requirement: Editors parked by an older version come back
`tnotes sync` SHALL, when a session named `ta-notes` exists, bring every editor parked in it back beside its chat as a split of the chat's window, given the share of the chat's width recorded in the editor's `@ta_notes_pct` when that is between 10 and 90 and 45 percent otherwise, and leave the cursor where it was. It SHALL do nothing when there is no such session.

#### Scenario: A parked editor
- **WHEN** an editor was parked in `ta-notes` by an older version and `tnotes sync` runs
- **THEN** the editor is a pane of its chat's window and `@ta_notes` still names it

#### Scenario: Nothing parked
- **WHEN** there is no `ta-notes` session
- **THEN** `tnotes sync` changes nothing

### Requirement: The parking session is wound up
`tnotes sync` SHALL close a parked editor whose chat pane is gone, unset `@ta_notes_pct`, `@ta_notes_open` and the global `@ta_notes_any`, and end the `ta-notes` session once no editor is left in it.

#### Scenario: The chat is gone
- **WHEN** the chat of a parked editor no longer exists
- **THEN** the editor is closed and the `ta-notes` session is gone

## REMOVED Requirements

### Requirement: Focus hooks are requested
**Reason**: Nothing needs the focus hooks for notes any more: an editor is an ordinary pane of the chat's window and no hook parks or brings it back.
**Migration**: None. `tnotes` no longer runs `tagents --focus-hooks`.

### Requirement: Hidden editors live in a session of their own
**Reason**: Editors are never parked: switching rows takes the whole window, editor included, off screen.
**Migration**: "Editors parked by an older version come back" returns the editors an older version parked in `ta-notes`.

### Requirement: The split is remembered
**Reason**: An editor is never parked and brought back, so its width is never lost and `@ta_notes_pct` is no longer written.
**Migration**: None. The editor keeps the width the user gave it; "Editors parked by an older version come back" reads a leftover `@ta_notes_pct` once.

### Requirement: Sync follows the user's focus
**Reason**: There is nothing to hide or bring back when the user's focus moves; the window with the editor leaves the screen as a whole.
**Migration**: None. `tnotes sync` takes no pane and only cleans up.

### Requirement: Hiding and showing are idempotent
**Reason**: There is no hiding or showing of editors.
**Migration**: None.
