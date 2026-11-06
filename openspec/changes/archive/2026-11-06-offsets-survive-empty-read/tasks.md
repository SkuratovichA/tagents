## 1. An update that reads nothing keeps the offsets

- [x] 1.1 Write failing checks in `tests/tusage.sh`, section 6: a dangling `*.jsonl` symlink as the only changed path, the offsets rows after that update, and the dollars after one more record. Proof: the suite run before the fix fails exactly these two checks.
- [x] 1.2 Tell the files of the three awk merges in `update` apart by `FILENAME == ARGV[1]` and say in a comment why the offsets merge needs it. Proof: `tests/tusage.sh` passes with no failure.
- [x] 1.3 Add the `CHANGELOG.md` line. Proof: `pnpm spec:check`.
