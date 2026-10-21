## 1. Implementation

- [x] 1.1 Define the glyph rule once as awk source `AWK_UNTITLE` in `lib/tagents/names.sh` and splice it into `untitle_of`, the window-name sweep and the list
- [x] 1.2 Keep a first token unless it is one character in the symbol ranges
- [x] 1.3 Run the programs that compare names under `LC_ALL=C`

## 2. Tests

- [x] 2.1 Window-name and `untitle_of` cases for `я иду`, `✳ я иду`, `⠂ fix-login-bugs`, `🚀 launch`, `中 文`, `é bon`, `* note`, `a b` in `tests/names.sh`
- [x] 2.2 List-row case for `я иду` in `tests/ui.sh`
- [x] 2.3 A pin in `tests/modules.sh` that the rule is written once
