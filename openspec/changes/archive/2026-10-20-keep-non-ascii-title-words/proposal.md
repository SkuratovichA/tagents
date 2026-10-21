## Why

The leading glyph rule says a glyph is one character that is no letter or digit, but the code exempted only ASCII letters and digits. A one-letter first word in another alphabet, such as `я` in `я иду`, was dropped from the name. The rule was also written out three times in awk and the copies could drift.

## What Changes

- A leading token is dropped only when it is one character and a symbol: an ASCII character that is not a letter or digit, a character in U+2000 to U+2BFF, or a character in U+1F000 to U+1FFFF.
- Every other single character, in any alphabet, stays as a word.
- The rule is defined once, as awk source shared by the row, the window-name sweep and the dialogs.

## Impact

- Affected specs: `window-names`.
- Affected code: `lib/tagents/names.sh`, `lib/tagents/list.sh`.
