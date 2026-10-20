## MODIFIED Requirements

### Requirement: The leading glyph is not part of the name
The terminal title Claude sets starts with a spinner glyph. A leading token SHALL be dropped, together with the spaces after it, only when it is exactly one character and that character is a symbol: an ASCII character that is not a letter or digit, a character in U+2000 to U+2BFF, or a character in U+1F000 to U+1FFFF. Any other first token SHALL be kept. Rows, window names, dialogs and the preview heading SHALL apply this one rule.

#### Scenario: The spinner glyph
- **WHEN** the title is `✳ fix-login-bugs busy`
- **THEN** the window is named `fix-login-bugs busy`

#### Scenario: A Cyrillic title
- **WHEN** the title is `два слова`
- **THEN** the window is named `два слова`, and with `✳ ` in front the name is still `два слова`

#### Scenario: A one-letter non-ASCII first word
- **WHEN** the title is `я иду`
- **THEN** the window is named `я иду`, and with `✳ ` in front the name is still `я иду`

#### Scenario: A braille or emoji glyph
- **WHEN** the title is `⠂ fix-login-bugs` or `🚀 launch`
- **THEN** the window is named `fix-login-bugs` or `launch`

#### Scenario: Other single characters are words
- **WHEN** the title is `中 文`, `é bon` or `a b`
- **THEN** the window name keeps the whole title
