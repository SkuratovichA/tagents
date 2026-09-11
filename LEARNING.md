## Do not touch the working tree while the bash suite runs in the background (11.09.2026)

The tests read `tagents`, `tnotes`, `tusage` from the checkout as they run. A `git stash` / `stash pop` issued while `tests/*.sh` were running in the background made half the suites exercise one tree and half another — every suite still said "passed", which is exactly why it is dangerous. Rule: while a background test run is in flight, no checkout/stash/apply/reset in that worktree; use a scratch worktree (`git worktree add`) for probes such as `git apply --check --3way`.

## `timeout` is not on macOS (11.09.2026)

`timeout 300 bash tests/x.sh` fails with `command not found` under zsh on a stock Mac (coreutils' `gtimeout` needs brew). The suites bound themselves already; run them bare.

## A group header carries its member's pane key, so `--list | awk '$1 == pane'` finds the header first (11.09.2026)

`list()` prints a group header whose field 1 is the pane id of its most urgent member and whose field 3 is that member's state — so a test that looked up a row by pane key got the header's body instead and never saw the icon, name or detail it was asserting on. Skip it the way `counts()` does, by the header marker: `index($2, "\342\226\276") == 0`.
