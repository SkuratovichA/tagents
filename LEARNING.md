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

## A splitter must refuse to run on its own output (12.09.2026)

Re-running the tagents splitter on an already-split entry parsed the whole file
as one function and produced nonsense, quietly — the manifest still "applied".
Any tool that rewrites a file in place gets a guard on a marker only its own
output contains, and the source of truth stays git: `git checkout -- tagents &&
rm -rf lib/tagents` before every re-run.

## One anchor, two matches: a second `case "${1:-}" in` (12.09.2026)

Skipping the module load for `--help` was written as a second top-level
`case "${1:-}" in`. That string is an ANCHOR elsewhere: the verification harness
slices the file at it to build a definitions-only copy, and `tests/modules.sh`
extracts the dispatch block with an awk range on it. Both silently matched the
new block instead of the real dispatch — one failed loudly, the other would have
checked nothing at all. The branch is an `if` now, and the anchor stays unique.

## A static scan over several files needs FNR, and a reset per file (12.09.2026)

`tests/ui.sh` looks for an fzf call whose stderr is silenced within the next
eight lines. Pointed at nineteen modules instead of one file it kept `s` across
the boundary, so a match at the end of one file flagged an innocent line at the
start of the next. Multi-file awk: `FNR` for the window, `FNR==1 {s=0}` to reset
it, and `FILENAME":"FNR` in the message so the number names something.

## `declare -f` is the oracle for a refactor that only moves code (12.09.2026)

Sourcing the definitions before and after and diffing `declare -f` (plus
`declare -p` for the globals) proves byte-identical function bodies from bash's
own parser, under the same bash the program runs on. It caught nothing here
because nothing was wrong — which is the point: it is what made "the tests pass"
mean "nothing moved" rather than "nothing tested moved".

## A control run of `git show HEAD:tagents` needs HEAD's lib beside it (12.09.2026)

tests/ui.sh compared the rows of the working tree against the committed entry
written to a temp file. Since the split that entry refuses to run without
`lib/tagents` beside it, printed nothing — and "nothing" compared equal to
nothing until the working tree grew a column. `git archive HEAD lib/tagents |
tar -x -C "$CONTROL"` next to the copied entry, and a guard that the control
actually started.

## `window-size latest` shrinks a detached session to the keeper's 80x24 (12.09.2026)

With one client attached on a `script` pty, every new window on that server —
even in another, detached session created with `-x 220` — came out 80x23, and
fzf truncated the header under test to `..`. `set -w window-size manual` plus
`resize-window -x 220 -y 50` is what sizes a window nobody is attached to.

## A cache keyed on the wrong thing serves the wrong verdict (12.09.2026)

The config check was cached for the status bar in one stamp per state directory
— and nothing in it said WHICH config it described. A count computed for a
broken `TA_CONFIG` was then handed to the next run pointed at a good one, and
`tests/ui.sh`'s existing "says nothing for the good one" case caught it on the
first run. A cache key has to name every input the value depends on: the stamp
now carries the config's path beside the count and the time, any `config*.yaml`
newer than the stamp invalidates it, and an age ceiling
(`TA_CFG_CHECK_EVERY`, 60 s) covers the problems that are fixed WITHOUT touching
the config — creating the login directory a profile names is the obvious one.

## A library's `declare module 'i18next'` never shows under link: and breaks every real consumer (14.09.2026)
Core augmented i18next's global `CustomTypeOptions` (`defaultNS: 'core'`, `resources`) from its own `.d.ts`. Locally the Telegram plugin consumes core through `link:`, which keeps two i18next copies (different typescript peer suffixes in the store), so the augmentation stayed on core's copy and the plugin typechecked. A clean clone resolves both to one file and every plugin `t('tg.key')` became a type error. A library types its own keys locally (`CoreT`) and leaves the global interface to the application; the only oracle for this class of bug is a clean install of the export.

## exactOptionalPropertyTypes refuses an explicit undefined in a tuple-typed rest parameter (14.09.2026)
`t(key, vars)` with `vars: X | undefined` fails against i18next's `(...args: [key, options?])` signature, and TypeScript prints the target with the generic already instantiated — a list of every core key — which reads like a leftover augmentation. It was not one: pass `t(key)` when there are no vars.

## A single red timing test on a loaded box is not evidence against the change (14.09.2026)
turn.test.ts gives a fake claude 400 ms of real time; with eleven claude processes running it lost the race once and passed on both re-runs. Re-run before reverting, and the durable fix is a fake clock in the driver, not a longer budget.

## Dispose before you drain: a flush inside finish() re-armed a timer (14.09.2026)
finish() cleared the timer list and then called reader.end(), which can flush a buffered result line; the result handler scheduled the 60 s grace timer into a list nobody would clear again, holding the event loop for a minute after the turn had resolved. Invisible to every real-timer test, found by the fake-clock one. Close the scope first, then drain; anything scheduled on a closed scope is a no-op.

## An apostrophe in an awk comment ends the awk program (19.09.2026)
`list()` is one single-quoted shell string, so a comment reading "the hook's file" closes the quote and bash reports a syntax error dozens of lines later, at the first parenthesis it then meets. The rule is already written inside that awk (`No apostrophes in here`) — it applies to every comment added to it, not just the one it sits next to. `bash -n lib/tagents/*.sh` catches it in a second.
