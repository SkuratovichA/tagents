# dashboard-popup Specification

## Purpose
How the dashboard behaves when it runs as a tmux popup (`TA_MODE=popup`, typically bound to a tmux prefix key) instead of as the claimed sidebar pane: no seat of its own, a preview beside the list, prompts asked inline, and closing after a completed action.

## Requirements

### Requirement: Popup mode is selected with TA_MODE=popup
The dashboard SHALL run in popup mode when `TA_MODE=popup` is set in its environment, which a tmux key binding using `display-popup` sets for it. Without it the dashboard runs in dedicated mode and, if it has a pane, claims that pane as the sidebar.

#### Scenario: Popup header
- **WHEN** the dashboard starts with `TA_MODE=popup`
- **THEN** its header offers `enter open in sidebar` and `? keys` but no `ctrl-q quit` item

### Requirement: A popup claims no pane and brings the sidebar to the chat
A popup list SHALL NOT claim the pane it runs in, since a popup has none of its own. `enter` on an agent SHALL select its row as the `window-rows` capability describes: the sidebar is moved into the agent's window, started first with `tagents --ensure-dash` when none exists, and the client is taken there, after which the popup closes.

#### Scenario: Open from the popup
- **WHEN** the user presses `enter` on an agent in a popup list
- **THEN** the sidebar is in the agent's window, the client shows it and the popup closes

### Requirement: A popup's refresher ends with it
A popup list SHALL start a refresher of its own, as a sidebar list does, handing it fzf's port and process id. Although a popup claims no pane and so releases nothing, it SHALL ring the refresher's channel `tagents-ev` when it exits, so that the refresher sees fzf gone and ends without waiting for its idle timeout.

#### Scenario: The popup closes
- **WHEN** a popup list exits
- **THEN** `@tagents_evgen` goes up by one and the popup's refresher ends

### Requirement: esc closes the popup
In popup mode `esc` SHALL close the list. When fzf exits for any reason in popup mode, the dashboard SHALL end instead of starting fzf again as it does in dedicated mode.

#### Scenario: Esc
- **WHEN** the user presses `esc`
- **THEN** the popup closes and the dashboard process ends

### Requirement: A completed action closes the popup
In popup mode these keys SHALL close the list once their action has been issued: `enter`, double-click, `ctrl-s`, `ctrl-g`, `ctrl-o`, `ctrl-e`, `ctrl-n`, `ctrl-p`, `ctrl-a`, `ctrl-y` and `?`. The keys that change the list or a record instead — `ctrl-r`, `F2`, `ctrl-u`, `ctrl-x`, `ctrl-t`, `ctrl-l`, `ctrl-w`, `$`, `ctrl-v` — SHALL leave the popup open.

#### Scenario: Go to an agent
- **WHEN** the user presses `ctrl-g` in a popup list
- **THEN** the client is switched to the agent and the popup closes

#### Scenario: Toggle columns
- **WHEN** the user presses `ctrl-w` and hides a column
- **THEN** the popup list is still open, redrawn without that column

#### Scenario: A shell from the popup
- **WHEN** the user presses `ctrl-a` in a popup list
- **THEN** the client is shown the new shell window and the popup closes

### Requirement: Prompts are asked inline
Keys that ask a question — rename, send, kill, new on an account to be asked, pick and the column picker — SHALL run in the popup's own terminal, since a popup cannot open a second popup. The same SHALL hold on a tmux with no `display-popup`, where the sidebar asks in place too.

#### Scenario: Rename in a popup
- **WHEN** the user presses `ctrl-r` in a popup list and types `newname`
- **THEN** the session's label becomes `newname`

#### Scenario: Kill in a popup
- **WHEN** the user presses `ctrl-x` in a popup list and answers `y`
- **THEN** the agent is killed as in the sidebar

### Requirement: The preview sits beside the list
A popup list SHALL show fzf's own preview of the row beside the list, on its right, 55% wide with a left border and wrapped lines, and `ctrl-v` SHALL toggle it. A sidebar list, by contrast, SHALL be started with no preview at all and `ctrl-v` opens the modal described in `dashboard-list`. The same fallback applies to a sidebar on a tmux without popups, where the preview starts hidden.

#### Scenario: Popup arguments
- **WHEN** the popup list starts
- **THEN** fzf is given `--preview-window=right,55%,border-left,wrap` and a binding of `ctrl-v` to `toggle-preview`

#### Scenario: Sidebar arguments
- **WHEN** the sidebar list starts on a tmux with popups
- **THEN** fzf is given no `--preview` or `--preview-window`

### Requirement: The list is built for the width left beside the preview
A popup list's rows SHALL be built for 45% of the popup's width, the rest being the preview. The first frame measures the controlling terminal because there is no pane to ask.

#### Scenario: Narrower rows
- **WHEN** the popup is 200 columns wide
- **THEN** rows are laid out for 90 columns

### Requirement: The ? window posts ctrl-v to the popup list
Picking `preview` in the `?` window of a popup list SHALL toggle fzf's preview through the list's listen port and open no second popup. In a sidebar list the same pick SHALL post nothing and open the modal through the tmux server shortly after the `?` window closes.

#### Scenario: Popup list
- **WHEN** `preview` is picked in the `?` window of a popup list
- **THEN** a `toggle-preview` request is posted to the list

#### Scenario: Sidebar list
- **WHEN** `preview` is picked in the `?` window of a sidebar list
- **THEN** nothing is posted and the preview modal opens
