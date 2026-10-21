## Why

Under a UTF-8 locale macOS awk compares strings by the locale's collation, which gives Cyrillic letters no weight of their own: `я` equals `ю`, `я иду` equals `два слова`, and `aя` equals `a`. `sort -u` merges such names as well, and a keyed sort does not keep equal-weight keys together. So two names that differ only in such letters were one name to the program: two projects shared a group, two directories shared a line, a title that began with the host name was taken for the host.

## What Changes

- Every awk this program runs is pinned to bytes (`LC_ALL=C awk`), and a check in `tests/modules.sh` lists any call that is not.
- Every `sort -u` runs under `LC_ALL=C`.
- The list sort carries a group number in a fifteenth field right after the group name, so the rows of each group stay together while the order of names the locale tells apart does not change.
- Cases with one Cyrillic letter per name are added to the forks, resurrect and names suites.

## Impact

- Affected specs: `dashboard-list`, `resurrect`, `window-names`.
- Affected code: every module in `lib/tagents/`, the hooks in `hooks/`, and `tests/`.
