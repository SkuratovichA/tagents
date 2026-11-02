## ADDED Requirements

### Requirement: The output of the child is decoded as a stream
The standard output and the standard error of the Claude child SHALL be decoded as streams of bytes, so a character whose bytes arrive in two reads is one character, and each maximal invalid byte sequence reads as one U+FFFD.

#### Scenario: A character split between two reads
- **WHEN** the child writes a result whose text holds `я` with its two bytes in separate writes
- **THEN** the outcome's `text` holds `я` and no U+FFFD

#### Scenario: Invalid bytes
- **WHEN** the child writes the single byte `0xFF` inside a text
- **THEN** the text holds exactly one U+FFFD in its place
