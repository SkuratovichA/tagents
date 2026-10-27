## RENAMED Requirements

- FROM: `### Requirement: A popup claims no pane and brings the sidebar to the chat`
- TO: `### Requirement: A popup claims no pane and shows the chat in the dashboard`

## MODIFIED Requirements

### Requirement: Popup mode is selected with TA_MODE=popup
The dashboard SHALL run in popup mode when `TA_MODE=popup` is set in its environment, which a tmux key binding using `display-popup` sets for it. Without it the dashboard runs in dedicated mode and, if it has a pane, claims that pane as the dashboard's list.

#### Scenario: Popup header
- **WHEN** the dashboard starts with `TA_MODE=popup`
- **THEN** its header offers `enter open in dashboard` and `? keys` but no `ctrl-q quit` item

### Requirement: A popup claims no pane and shows the chat in the dashboard
A popup list SHALL NOT claim the pane it runs in, since a popup has none of its own. `enter` on an agent SHALL select its row as the `window-rows` capability describes: with no cockpit up the cockpit is made first with `tagents --ensure-dash`, the viewport shows the agent's window, and the terminal is taken to the session `tagents`, after which the popup closes.

#### Scenario: Open from the popup
- **WHEN** the cockpit is up and the user presses `enter` on an agent in a popup list
- **THEN** the viewport shows the agent's window, the popup's terminal shows the session `tagents` and the popup closes

#### Scenario: No cockpit yet
- **WHEN** no cockpit is up and the user presses `enter` on an agent in a popup list
- **THEN** the session `tagents` exists, its viewport shows the agent's window and the popup closes

### Requirement: A popup's refresher ends with it
A popup list SHALL start a refresher of its own, as the dashboard's list does, handing it fzf's port and process id. Although a popup claims no pane and so releases nothing, it SHALL ring the refresher's channel `tagents-ev` when it exits, so that the refresher sees fzf gone and ends without waiting for its idle timeout.

#### Scenario: The popup closes
- **WHEN** a popup list exits
- **THEN** `@tagents_evgen` goes up by one and the popup's refresher ends

### Requirement: A completed action closes the popup
In popup mode these keys SHALL close the list once their action has been issued: `enter`, double-click, `ctrl-s`, `ctrl-g`, `ctrl-o`, `ctrl-e`, `ctrl-n`, `ctrl-p`, `ctrl-a`, `ctrl-y` and `?`. The keys that change the list or a record instead — `ctrl-r`, `F2`, `ctrl-u`, `ctrl-x`, `ctrl-t`, `ctrl-l`, `ctrl-w`, `$`, `ctrl-v` — SHALL leave the popup open.

#### Scenario: Go to an agent
- **WHEN** the user presses `ctrl-g` in a popup list
- **THEN** the terminal is taken to the agent's own session, window and pane and the popup closes

#### Scenario: Toggle columns
- **WHEN** the user presses `ctrl-w` and hides a column
- **THEN** the popup list is still open, redrawn without that column

#### Scenario: A shell from the popup
- **WHEN** the user presses `ctrl-a` in a popup list
- **THEN** the client is shown the new shell window and the popup closes

### Requirement: Prompts are asked inline
Keys that ask a question — rename, send, kill, new on an account to be asked, pick and the column picker — SHALL run in the popup's own terminal, since a popup cannot open a second popup. The same SHALL hold on a tmux with no `display-popup`, where the dashboard's list asks in place too.

#### Scenario: Rename in a popup
- **WHEN** the user presses `ctrl-r` in a popup list and types `newname`
- **THEN** the session's label becomes `newname`

#### Scenario: Kill in a popup
- **WHEN** the user presses `ctrl-x` in a popup list and answers `y`
- **THEN** the agent is killed as in the dashboard's list

### Requirement: The preview sits beside the list
A popup list SHALL show fzf's own preview of the row beside the list, on its right, 55% wide with a left border and wrapped lines, and `ctrl-v` SHALL toggle it. A list in the dashboard's pane, by contrast, SHALL be started with no preview at all and `ctrl-v` opens the modal described in `dashboard-list`. The same fallback applies to the dashboard's list on a tmux without popups, where the preview starts hidden.

#### Scenario: Popup arguments
- **WHEN** the popup list starts
- **THEN** fzf is given `--preview-window=right,55%,border-left,wrap` and a binding of `ctrl-v` to `toggle-preview`

#### Scenario: Dashboard list arguments
- **WHEN** the dashboard's list starts on a tmux with popups
- **THEN** fzf is given no `--preview` or `--preview-window`

### Requirement: The ? window posts ctrl-v to the popup list
Picking `preview` in the `?` window of a popup list SHALL toggle fzf's preview through the list's listen port and open no second popup. In the dashboard's list the same pick SHALL post nothing and open the modal through the tmux server shortly after the `?` window closes.

#### Scenario: Popup list
- **WHEN** `preview` is picked in the `?` window of a popup list
- **THEN** a `toggle-preview` request is posted to the list

#### Scenario: Dashboard list
- **WHEN** `preview` is picked in the `?` window of the dashboard's list
- **THEN** nothing is posted and the preview modal opens
