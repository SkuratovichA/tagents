## ADDED Requirements

### Requirement: A session holding only the sidebar has a header alone
When a session's only window holds nothing but the sidebar, its group SHALL be a header with no row under it. That header SHALL carry the window id of that window, the state `none`, no session id and the session's working directory, so that `ctrl-n`, `ctrl-p` and `ctrl-a` on it open a window in that session (the `window-rows` capability) and `ctrl-x` on it only shows `tagents: that is the dashboard itself`.

#### Scenario: The header alone
- **WHEN** the client shows session `empty`, whose working directory is `~/app` and whose only window holds nothing but the sidebar
- **THEN** the list has a header `empty` and no row under it, and the header carries the window id of that window, the state `none`, no session id and the directory `~/app`

#### Scenario: ctrl-x on the header alone
- **WHEN** the user presses `ctrl-x` on the header of `empty`
- **THEN** `tagents: that is the dashboard itself` is shown and no window is killed

## MODIFIED Requirements

### Requirement: A group header stands in for the row directly under it
A group header line SHALL carry the key, state, session id and directory of the row printed directly beneath it, so a key that acts on an agent (send, rename, kill, pick) pressed on a header acts on that agent. `enter` and `ctrl-g` on the header of a session group SHALL instead show the session (the `window-rows` capability).

#### Scenario: Header and first row agree
- **WHEN** a group has a closed and a live agent
- **THEN** the header's key equals the key of the first row beneath it, which is the live one

#### Scenario: A group of windows only
- **WHEN** a session holds one window `server` and no chat
- **THEN** the header carries the window id of `server`, the state `none` and no session id
