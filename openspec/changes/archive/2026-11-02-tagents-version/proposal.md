## Why

`tagents --version` is an unknown option, so there is no way to tell which version a machine runs, and `main` moves without a version bump when only shell code changes.

## What Changes

- `tagents --version` and `tagents -V` print `tagents <workspace version> (<short commit>)` and exit 0, from the checkout the script lives in, with no module, config, tmux or node.
- A version or a commit that cannot be read is left out of the line and never fails the flag.
- `README.md` and the manual in the script header describe it.

## Impact

- Specs: `cli-dispatch` gets one ADDED requirement beside "--help prints the manual".
- Code: `tagents` (the symlink walk runs for the flag, the module loop does not, one dispatch arm).
- Tests: `tests/dispatch.sh`.
