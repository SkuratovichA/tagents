## MODIFIED Requirements

### Requirement: A group header shows the session and what is going on in it
The header of a group SHALL read `▾ <group name>`, then the group's path with `~` for the home directory when the list is 92 columns wide or more, then one badge per state present, then the five-hour cost total. The path of a session group is the default directory saved for the session, in the normal colour, else the session's working directory as tmux reports it, dim; the group `no window` shows no path. It SHALL be bold when at least one row in the group is not closed, a dimmed window row counting as not closed, and dim when every row is closed.

#### Scenario: Badges
- **WHEN** a group has one blocked, one idle and one working agent
- **THEN** its header ends with `⚠1 ✓1 ●1` in the order blocked, idle, working, new, unknown, closed, each coloured as its state

#### Scenario: Narrow pane drops the path
- **WHEN** the list is built for fewer than 92 columns
- **THEN** the header shows the group name and badges but not the path

#### Scenario: Five-hour total
- **WHEN** a group has spent money in the last five hours, the list is 60 columns wide or more and `cost` is not hidden
- **THEN** its header ends with the total as `$x/5h`

#### Scenario: Session name
- **WHEN** the group is session `release notes`
- **THEN** its header reads `▾ release notes`

#### Scenario: A saved directory
- **WHEN** a default directory is saved for the session and the list is 92 columns wide or more
- **THEN** the header shows that path in the normal colour, and without one it shows the path tmux reports, dim
