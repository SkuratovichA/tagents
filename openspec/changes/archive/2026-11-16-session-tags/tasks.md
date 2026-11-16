## 1. Tags for a session

- [x] 1.1 Add `lib/tagents/tags.sh` with the three verbs, the tag rule and the limit of 10, declare them in `tagents`, `tagents.cli.json` and the dispatch, and regenerate the contract. Proof: `pnpm plugin:check` and the verb checks of `tests/tags.sh`.
- [x] 1.2 Send the tags to the list as the record `K`, append them to a tagged row behind as many spaces as the list is wide (at least 300) with an upper-case copy, add `--no-hscroll` to the dashboard's fzf and `tags.tsv` to both lists of the refresher, and add the `tags:` line to the preview. Proof: the row, search and preview checks of `tests/tags.sh`, and `tests/refresh.sh`.
- [x] 1.3 Drop the tags in the state hook on `SessionEnd` with the reason `clear` only. Proof: the hook checks of `tests/tags.sh`, one case for each other reason and one for a missing session id.
- [x] 1.4 Add the plugin's `SessionStart` hook and its script, and put both in the shipped files of the digest. Proof: the plugin hook checks of `tests/tags.sh` and `pnpm plugin:check`.
- [x] 1.5 Write `tests/tags.sh` and prove it can fail by mutating the limit check, the `clear` condition and the upper-case copy. Proof: each mutation turns named checks red, listed in the report of the change.
- [x] 1.6 Update the tool list in `packages/contract/test/tools.test.ts`, the skill, the guides, `lib/tagents/README.md` and `CHANGELOG.md`. Proof: `pnpm test` and `pnpm spec:check`.
