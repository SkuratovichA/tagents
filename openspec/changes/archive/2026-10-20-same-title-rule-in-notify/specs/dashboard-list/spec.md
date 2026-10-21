## MODIFIED Requirements

### Requirement: A row is named by its label, its title or its project
The name on a row SHALL be, in order: the label set with `ctrl-r` or `tagents --label` (keyed by session id first, then by pane); the terminal title Claude keeps, without its leading one-character spinner glyph; for a pane-less session the name announced in `$TA_LABEL`, then the title the session gave itself; and finally the directory's name. A title that is only the machine's host name SHALL count as no title.

#### Scenario: Glyph removed
- **WHEN** the pane title is `✳ Search index rebuild`
- **THEN** the row's name is `Search index rebuild`

#### Scenario: Label wins
- **WHEN** the user has named the session `nightly`
- **THEN** the row's name is `nightly` whatever the title says

#### Scenario: A one-letter word is kept
- **WHEN** the pane title is `я иду`
- **THEN** the row's name is `я иду`
