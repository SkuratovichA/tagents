## ADDED Requirements

### Requirement: A list started as the sidebar runs in the home directory
A list that tagents starts as the sidebar, for `tagents --ensure-dash` or when a window switch brings the sidebar back, SHALL run with the home directory (`$HOME`) as its working directory, whatever the working directory of the process that started it. A sidebar therefore never keeps a project directory or a worktree in use.

#### Scenario: ensure-dash from inside a worktree
- **WHEN** no list is running and `tagents --ensure-dash` runs from a shell whose working directory is a git worktree
- **THEN** the new list's pane reports `$HOME` as its working directory (`#{pane_current_path}`)

#### Scenario: A sidebar brought back by a window switch
- **WHEN** the window holding the sidebar is killed and the follow hook starts a new list in the window the client lands in
- **THEN** the new list's pane reports `$HOME` as its working directory
