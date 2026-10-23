## ADDED Requirements

### Requirement: ctrl-x on a dimmed row kills the window after asking
`ctrl-x` on a dimmed window row SHALL ask `kill this window?`, in the popup a chat's kill asks in or inline where there is no popup, and SHALL act only on `y`, `yes` or their capitals; anything else, or no answer within 60 seconds, cancels. Confirming SHALL close the window with every pane in it, ring the refresher's channel and retake the resurrect snapshot.

#### Scenario: Confirmed
- **WHEN** the user answers `y` for the dimmed row of window `server`, which runs a dev server and a shell
- **THEN** the window and both of its panes are gone, and every other window and the sidebar are where they were

#### Scenario: Anything else
- **WHEN** the user answers `n`, presses enter on an empty line or does not answer
- **THEN** the window and its panes are still there

### Requirement: The window question says what will be lost
The question SHALL name the window by its name and its `session:index` and list every pane of the window except the sidebar, one line each, with the command running in it and its directory. When the window is the last of its session and the sidebar is not in it, the question SHALL also say that the session ends with it.

#### Scenario: The question lists the panes
- **WHEN** the window holds `node` running in `~/app` and `zsh` in `~/app/src`
- **THEN** the question names the window and its `session:index` and has one line for each of the two panes with its command and its directory

#### Scenario: The sidebar is not listed
- **WHEN** the sidebar is in the window under the cursor
- **THEN** the question lists the window's other panes and no line for the sidebar

#### Scenario: The last window of its session
- **WHEN** the window is the only window of its session and the sidebar is in another session
- **THEN** the question says that the session ends with it, and confirming ends the session while the client stays attached where it was

### Requirement: A window closed since its row was drawn is not asked about
Whether the window exists SHALL be checked when the question is about to be asked: a window closed since its row was drawn SHALL ask nothing, kill nothing and show `tagents: that window is gone`.

#### Scenario: Closed since the row was drawn
- **WHEN** the window was closed after its row was drawn and the user presses `ctrl-x` on the row
- **THEN** nothing is asked or killed and `tagents: that window is gone` is shown

## MODIFIED Requirements

### Requirement: Windows without a chat are dimmed rows
Every window of a group whose first pane, not counting the sidebar, carries no agent state SHALL get a dimmed row showing the window's name and nothing else: no state, age, context, cost, model or account. The line of such a row for fzf SHALL start with the window id (`@7`), carry the state `none` and an empty session id, and end with the directory of the window's first pane. `enter` on it SHALL select the window like any row, and `ctrl-x` on it SHALL kill the window after asking.

#### Scenario: An editor window
- **WHEN** session `work` has a window `server` running a dev server and no chat
- **THEN** the list has a dim row `server` under `work`, with no state glyph, age, context or cost
- **AND** `enter` on it shows that window with the sidebar in it

#### Scenario: A chat window is not dimmed
- **WHEN** the first pane of a window carries an agent state
- **THEN** its row is an ordinary chat row

### Requirement: The sidebar is never closed
No key or verb of tagents SHALL close the sidebar pane except `ctrl-q`, and closing a chat or a window SHALL NOT take the sidebar with it. When the chat killed with `ctrl-x` is the only pane of its window besides the sidebar, or the window killed with `ctrl-x` on its dimmed row holds the sidebar, the sidebar SHALL be moved to the window the client lands on before the window is closed, or to a new shell window of the same session when the window is the last of its session. When a chat exits by itself in such a window, the sidebar SHALL stay in the window, and a move of the sidebar out of a window in which it was the last pane SHALL close that window.

#### Scenario: Killing the only chat of a window
- **WHEN** the user confirms `ctrl-x` on the chat of the window on screen, which holds only that chat and the sidebar
- **THEN** the window is closed, the client shows another window and the sidebar is in it

#### Scenario: Killing the window the sidebar is in
- **WHEN** the user confirms `ctrl-x` on the dimmed row of the window on screen, which holds a shell beside the sidebar
- **THEN** the window and the shell are gone, the client shows the window it lands on and the sidebar is in it

#### Scenario: Killing the last window of a session with the sidebar in it
- **WHEN** the window killed from its dimmed row is the only window of its session and holds the sidebar
- **THEN** the session stays, with a new shell window that holds the sidebar and is on screen

#### Scenario: The chat exits by itself
- **WHEN** a chat exits in a window that holds only the chat and the sidebar
- **THEN** the sidebar is still there, and a follow to another window moves it out and the emptied window goes

### Requirement: ctrl-x never kills the sidebar
`ctrl-x` on the pane the list itself runs in, or on a window that holds nothing but that pane, SHALL do nothing but show `tagents: that is the dashboard itself`.

#### Scenario: Own pane
- **WHEN** a marker drifted so that the list's own pane is under the cursor and the user presses `ctrl-x`
- **THEN** the pane survives and the line is shown

#### Scenario: The sidebar's own window
- **WHEN** `tagents --act kill` is run on a window that holds only the sidebar
- **THEN** the window and the sidebar survive and the line is shown
