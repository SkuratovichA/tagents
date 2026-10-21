## 1. Implementation

- [x] 1.1 Run every awk in `lib/` and `hooks/` as `LC_ALL=C awk`
- [x] 1.2 Run every `sort -u` as `LC_ALL=C sort -u`
- [x] 1.3 Number the groups of the list in field 15 and sort on it right after the group name

## 2. Tests

- [x] 2.1 Cases in `tests/forks.sh` for two projects, two directories and a home-directory name that differ only in a Cyrillic letter
- [x] 2.2 A case in `tests/resurrect.sh` for an orphan window named `holdя`
- [x] 2.3 A case in `tests/names.sh` for a title that is the host name plus `я`
- [x] 2.4 A check in `tests/modules.sh` that every awk call is pinned
