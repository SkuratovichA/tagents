## 1. The flag

- [x] 1.1 Write failing tests in `tests/dispatch.sh`: both spellings, the exact line, a symlink, a wrapper, each unreadable part, no tmux started, a copy holding only the script. Proof: `tests/dispatch.sh` fails with the flag unknown.
- [x] 1.2 Let the symlink walk run for the flag without loading modules, and add the dispatch arm that reads the version with `core-release.sh version` and the commit with `git rev-parse --short HEAD`. Proof: `tests/dispatch.sh`.
- [x] 1.3 Describe it in the script header, `README.md` and `CHANGELOG.md`, and regenerate `skills/tagents/references/scripts.md`. Proof: `pnpm plugin:gen` then `git diff --exit-code`, `pnpm plugin:check`.
