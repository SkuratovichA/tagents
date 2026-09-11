## Do not touch the working tree while the bash suite runs in the background (11.09.2026)

The tests read `tagents`, `tnotes`, `tusage` from the checkout as they run. A `git stash` / `stash pop` issued while `tests/*.sh` were running in the background made half the suites exercise one tree and half another — every suite still said "passed", which is exactly why it is dangerous. Rule: while a background test run is in flight, no checkout/stash/apply/reset in that worktree; use a scratch worktree (`git worktree add`) for probes such as `git apply --check --3way`.

## `timeout` is not on macOS (11.09.2026)

`timeout 300 bash tests/x.sh` fails with `command not found` under zsh on a stock Mac (coreutils' `gtimeout` needs brew). The suites bound themselves already; run them bare.

## A group header carries its member's pane key, so `--list | awk '$1 == pane'` finds the header first (11.09.2026)

`list()` prints a group header whose field 1 is the pane id of its most urgent member and whose field 3 is that member's state — so a test that looked up a row by pane key got the header's body instead and never saw the icon, name or detail it was asserting on. Skip it the way `counts()` does, by the header marker: `index($2, "\342\226\276") == 0`.

## `( cmd; echo "exit=$?" )` hides a failure from `set -e` (11.09.2026)

A gate wrapped like that reports its exit code but never stops the script, so a commit landed with typecheck and build red (the i18next 26 bump in packages/core). Gate with a function that exits on failure (`gate() { "$@" > log || { tail log; exit 1; }; }`) and only commit after it.

## i18next 26 dropped `initImmediate` and `showSupportNotice` from InitOptions (11.09.2026)

Both were in packages/core's init and pinned the package to i18next 25 while the orchestrator was on 26. With inline resources `init()` returns already initialised, so neither option was needed; one version across both packages means a linked consumer loads one copy.

## A second package cannot add its own i18next namespace (11.09.2026)

`@tagents/core` ships `declare module 'i18next' { interface CustomTypeOptions { defaultNS: 'core'; resources: { core: CoreResource } } }`, and that augmentation is in the program of anything that imports core. A second augmentation adding a `knowledge` namespace cannot merge (TS2717: the same property declared twice), so inside such a package every `t('ownKey')` is a type error against core's key union. Either lift the namespaces into core's augmentation, or — what @tagents/knowledge does — keep i18next's *shape* (en/ru resources, TAGENTS_LOCALE, fallback) with a dozen lines of local `{{slot}}` interpolation, which types the keys exactly.

## SQLite's `collate nocase` folds ASCII only (11.09.2026)

`... where heading = ? collate nocase` matched `Disks`/`disks` and never `Диски`/`диски`, so half the sections of a Russian document were unaddressable by `show id#heading`. `lower()` has the same limit. Compare in JavaScript (`toLowerCase()`, which is Unicode-aware) after fetching the doc's headings — the row count per document is tiny, so there is nothing to optimise away.

## FTS5 MATCH is AND, and user text must be quoted (11.09.2026)

Two words in a query mean both words in the same chunk, so a case asserting that `['release', 'релиз*']` finds "either" was wrong about the engine, not about the data. And an unquoted `-` in `tmux-agent-state.sh` means NOT while a stray `"` is a syntax error: every user token is wrapped in double quotes before it reaches MATCH, with a trailing `*` kept outside the quotes as the prefix operator.
