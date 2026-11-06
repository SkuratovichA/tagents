## Why

When every transcript an update set out to read was gone by the time it was read, as when Claude Code moves a session to another project directory between the update's listing and its read, the merge of the offsets table swallowed the whole old table and left `offsets.tsv` empty. The next update then took the first-run branch, read every transcript from byte 0 and appended it to the facts again, so every figure the index gives was counted twice.

## What Changes

- The three awk merges in the updater of `tusage` tell their two input files apart by `FILENAME == ARGV[1]`, not by `NR==FNR`, which misreads an empty first file as part of the second.
- An update that reads nothing keeps every row of the offsets table.

## Impact

- Specs: `usage-accounting` gets one ADDED requirement.
- Code: `tusage` (`update`).
- Tests: `tests/tusage.sh`, section 6.
- Docs: `CHANGELOG.md`.
