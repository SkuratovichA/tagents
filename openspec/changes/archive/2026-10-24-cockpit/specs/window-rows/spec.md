## ADDED Requirements

### Requirement: Moving the sidebar belongs to the follow layout
What this capability says about moving the sidebar — by `tagents --ensure-dash`, by `tagents --follow` and by selecting a row — and about switching a client to the selected window SHALL hold in the `follow` layout, the default. In the `cockpit` layout the `cockpit` capability says what those do instead, and the rest of this capability holds as written.

#### Scenario: The follow layout
- **WHEN** `dashboard.layout` is unset, the client shows `work:1` and the user presses `enter` on the row of a chat in `personal:2`
- **THEN** the sidebar is the leftmost pane of `personal:2` and the client shows `personal:2`

#### Scenario: The cockpit layout
- **WHEN** `dashboard.layout` is `cockpit` and the user presses `enter` on the row of a chat in `personal:2`
- **THEN** no pane changes window, the viewport shows `personal:2` and the user's terminal still shows the session `tagents`

## MODIFIED Requirements

### Requirement: A group is a tmux session
The list SHALL group rows by the tmux session of their window, and a group header SHALL name the session. Every tmux session but the cockpit's dashboard SHALL be a group, whether or not a chat has ever run in it, and every window of a group is listed (see the dimmed rows below), whichever directory its panes are in. A session whose only window holds nothing but the sidebar SHALL be a group with a header and no row under it, as the `dashboard-list` capability describes.

#### Scenario: Two sessions
- **WHEN** session `work` holds two chats and session `personal` holds one
- **THEN** the list has a header `work` over two rows and a header `personal` over one

#### Scenario: Directory no longer groups
- **WHEN** two chats of session `work` run in two unrelated directories
- **THEN** both rows are under the header `work`

#### Scenario: A scratch session
- **WHEN** session `scratch` holds one window `shell`, running a shell, no chat has ever run in it and tagents never created it
- **THEN** the list has a header `scratch` over one dimmed row `shell`

#### Scenario: A session tagents created
- **WHEN** tagents created session `release notes` for a chat and the chat has since exited
- **THEN** the session is still a group and its windows are still listed

#### Scenario: Only the sidebar
- **WHEN** the client is in session `empty`, whose only window holds nothing but the sidebar
- **THEN** the list has a header `empty` and no row under it

#### Scenario: The cockpit's dashboard
- **WHEN** the cockpit is up and the sessions `work`, `personal` and `tagents` exist
- **THEN** the list has the headers `work` and `personal` and none named `tagents`

### Requirement: A restore closes the panes left where the sidebar was
After a restore (`tagents --resurrect`, and `tagents --resurrect --auto` from the tmux-resurrect hook), every pane titled `tagents-sidebar` that is not the live list, and every pane titled `tagents-viewport` that is not the live viewport, SHALL be closed when it is an idle shell; a leftover dashboard is rebuilt or closed as the `cockpit` capability describes. A pane running anything but a shell SHALL never be touched, and a dry run SHALL close nothing.

#### Scenario: Leftover shells
- **WHEN** tmux-resurrect restored three windows, each with an idle shell titled `tagents-sidebar` where the sidebar was, and the restore has started a live list
- **THEN** the three shells are closed and the live list is still there

#### Scenario: A busy pane with that title
- **WHEN** a pane titled `tagents-sidebar` runs `sleep`
- **THEN** it is left running

#### Scenario: A leftover viewport shell
- **WHEN** a restore finds an idle shell titled `tagents-viewport` in the window `work:2`, outside the session `tagents`
- **THEN** that shell is closed and the other panes of `work:2` are untouched
