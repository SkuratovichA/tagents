## ADDED Requirements

### Requirement: An update that reads nothing keeps the offsets
An update SHALL leave every row of the offsets table in place when none of the transcripts it set out to read is still there to read, as when Claude Code moves a session to another project directory between the update's listing and its read. The next update SHALL read only bytes no update has read before.

#### Scenario: The only changed transcript is gone before it is read
- **WHEN** the only path changed since the last update is gone by the time the update reads it
- **THEN** `offsets.tsv` keeps every row it had
- **AND** after one more request is appended to a session, the next update raises that session's dollars by that request alone
