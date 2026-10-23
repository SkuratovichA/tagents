## ADDED Requirements

### Requirement: An update is finished by the installer of the commit it moves to
When an update moves the managed copy to another commit, `install.sh` SHALL hand the rest of the run to the `install.sh` of that commit, with the same arguments and with `TAGENTS_MOVED_FROM` set to the commit it moved from, so that the build, the return to that commit when the build fails, and the commands, hooks and LaunchAgent come from the new installer in the same run. A commit whose `install.sh` does not take `TAGENTS_MOVED_FROM` is finished by the running installer.

#### Scenario: One update installs what the new installer writes
- **WHEN** the copy stands on a commit whose `install.sh` writes the wrappers one way, and `tagents update` moves it to a commit whose `install.sh` writes them another way
- **THEN** after that one update the command and hook wrappers are written the new way, the update exits 0, reports the move once and leaves no lock behind

#### Scenario: The build of the new commit fails
- **WHEN** an update moves the copy and the build of the new commit fails
- **THEN** the copy is back on the commit it was on, and the update exits 1 and says so

#### Scenario: The new commit's installer does not take the hand-over
- **WHEN** an update moves the copy to a commit whose `install.sh` does not take `TAGENTS_MOVED_FROM`
- **THEN** the running installer builds the copy and writes the wrappers itself, and the update exits 0
