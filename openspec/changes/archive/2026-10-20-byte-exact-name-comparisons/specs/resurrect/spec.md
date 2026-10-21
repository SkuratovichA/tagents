## MODIFIED Requirements

### Requirement: Notes editors
After the chats are up, the restore SHALL close the notes editors that tmux-resurrect brought back with nothing linking them to a chat: the windows in `ta-notes` other than the holder window `hold` that are linked to no chat, and in each restored chat's window the pane in the notes directory that no chat links to. It SHALL then ask `tnotes toggle <pane>` once for each restored chat whose editor was on screen.

#### Scenario: Orphans closed and one editor reopened
- **WHEN** two unlinked editors sit in `ta-notes` and one restored chat had its editor on screen
- **THEN** both orphans are closed, the holder and any linked editor stay, and tnotes is asked once for that chat's pane

#### Scenario: Report lines
- **WHEN** tnotes reopens the editor, or fails to
- **THEN** the report says `✓ notes beside <pane>`, or `! notes for <pane> did not reopen — prefix C-t`

#### Scenario: Off
- **WHEN** `resurrect.notes` is `off`
- **THEN** the chats are still restored, the orphans are left and tnotes is not asked
- **AND** any other value of `resurrect.notes`, or none, means `reopen`; a missing `tnotes` is not an error


#### Scenario: A window named for the holder plus a Cyrillic letter
- **WHEN** an unlinked editor in `ta-notes` sits in a window named `holdя`
- **THEN** it is closed with the other orphans, since only the name `hold` itself marks the holder
