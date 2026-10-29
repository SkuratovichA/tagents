## ADDED Requirements

### Requirement: The same bytes from either implementation
`sessions recent`, `sessions search`, `sessions show`, the bare `sessions` and the usage lines of a misspelled subcommand SHALL print the same stdout, the same stderr and exit with the same code whether the node CLI or the Rust binary serves the call, for the same transcripts, the same environment and the same clock. The cases in `packages/core/test/fixtures/sessions/` are the reference, and `tests/rust-parity.sh` runs both implementations on the same seeded home and compares every byte.

#### Scenario: The recorded cases
- **WHEN** the Rust binary runs `sessions recent`, `sessions recent 1`, `sessions search deploy`, `sessions search` for a word nobody wrote and `sessions show` of a recorded id on the seeded home
- **THEN** its stdout is the content of `recent.txt`, `recent-1.txt`, `search-deploy.txt`, `search-miss.txt` and `show.txt` of `packages/core/test/fixtures/sessions/`

#### Scenario: Awkward transcripts
- **WHEN** a transcript holds invalid UTF-8, a lone surrogate escape, a number that overflows a float or a line nested a hundred thousand levels deep
- **THEN** both implementations list the same sessions and print the same bytes

#### Scenario: Awkward files
- **WHEN** a project directory is unreadable, a transcript is a symbolic link, or a modification time is before 1970
- **THEN** both implementations print the same bytes and exit with the same code
