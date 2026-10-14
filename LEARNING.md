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

## A test stub that `exec`s sleep hides the pane from every liveness check (23.09.2026)
A stub `claude` written as `exec sleep 600` turns the pane's current command into `sleep` and leaves no process called `claude` under the pane, so both ways tagents asks "is this chat alive" — the pane command and the process under it — answer no, and every placement test reads the resumed chat as dead. The stub keeps its name instead: `exec -a "$0" /bin/bash -c 'sleep 600; :' "$0" "$@"` — the pane command stays `claude` and the pane stays live for as long as the test needs.

## A `continue` in a lock loop's takeover branch skips the decrement and spins forever (23.09.2026)
`lock_dir` read a failed `stat` as mtime 0, so a lock whose parent directory is unwritable looked infinitely stale, `rm -rf` "succeeded" on nothing, and the `continue` jumped over `tries=$((tries - 1))`; `mkdir` failed again and the loop never left. Every pass through a retry loop costs a try, the takeover pass included, and a stat failure reads as age 0, not as age from the epoch. `tnotes` `take_lock` still has the old shape.

## A second awk over the first awk's output counts the columns the first one kept, not git's (25.09.2026)
`notes-context.sh` filters `git diff --name-status` down to `old<TAB>new` and then a second awk printed `$2 " => " $3` — the columns of the git line, not of the two-column line it was actually reading — so the archive notice came out as `archived: <new> => `. The suite caught it; `sh -x` on a two-commit fixture showed it in one run. When a pipeline re-reads its own output, the field numbers restart from what the previous stage printed.

## A helper defined in three suites and used in a fourth ran nowhere, and every check that called it counted as neither pass nor fail (25.09.2026)
`tests/notes.sh` called `hasnt` since 6b was written, but only `closed.sh`, `launch.sh` and `headless.sh` define it; under `set -uo pipefail` without `-e` the call is `command not found` on stderr and the suite still ends `0 failed`. A "must not contain" check that never runs looks exactly like one that passes. Every helper a suite calls is defined in that suite, and a new check is watched fail once before it is trusted.

## A variadic CLI option swallows the prompt that follows it (15.09.2026)
`claude -p` declares `--disallowedTools <tools...>` and `--mcp-config <configs...>` as variadic: they keep taking argv words until the next option. buildArgs() put `--disallowedTools` last, so on every fresh session (no `--resume`) the prompt became one more "permission deny rule" and the CLI exited 1 with "Input must be provided either through stdin or as a prompt argument" — an earlier ticket agent lost every batch after the port and no test caught it because the argv test only pinned the resumed case. A variadic option goes in front of an option that is always present (`--output-format`), and the test now walks every spec × {resume, fresh} and asserts each variadic flag is followed by one value and then an option.

## API Extractor reads any `.d.ts` under a `node_modules` path as someone else's package (12.10.2026)
The declarations for the API reports were first emitted into `packages/<name>/node_modules/.cache/`, because it is git-ignored and keeps `@tagents/core` resolvable. API Extractor treats every file under a `node_modules` segment as external, so each export came out as a bare re-export and the report held no API at all. The cache lives in `packages/contract/.cache/` instead, one `mkdtemp` directory per call: two test files run as parallel processes, and a shared directory let one delete the other's declarations.

## API Extractor resolves `types` from the working directory when it is only given a tsconfig path (12.10.2026)
With `compiler.tsconfigFilePath`, `types: ["node"]` was looked up from `process.cwd()`: the test passed from `packages/contract` and the generator, started from the repo root, died with `Unable to follow symbol for "AbortSignal"`. `compiler.overrideTsconfig` with an explicit `typeRoots` makes it independent of where it is started, and the test now runs the call from two other working directories in child processes. A tool that runs from a hook, from CI and from a test has three working directories, and the test has to use more than one of them.

## `tusage --help` creates its state directory and needs jq before it prints anything (12.10.2026)
The generator ran the three scripts for their help with the real `HOME`, so a check that promised to write nothing ran `mkdir -p ~/.claude/agent-state/usage` on every commit, and with a hand-made `PATH=/usr/bin:/bin` it would have failed on a machine whose jq lives elsewhere. A script run only for its text gets a throwaway `HOME` and the caller's own `PATH`.

## In zsh an unquoted variable holding a command line is one word (12.10.2026)
A scratch test of the pre-commit hook kept `G="git -c user.name=… commit"` and ran `$G -qam …`; zsh does not split it, so every commit exited 127 and the lines after it reported the previous commit as if it were the new one. A shell function does what the variable was meant to, and its name must not be an alias already defined in the profile (`g` is).

## A once-per-process guard set inside `$(…)` guards nothing: the subshell takes the flag with it (01.10.2026)
`cfg_load` set `CFG_LOADED=1` and parsed the file once, as its comment promised, but every caller reached it through `$(cfg_get …)`, so the flag and `$CFG` died with each subshell and one `--counts` parsed the config eleven times and ran `hostname` eleven times. A lazy load has to happen in the parent shell before the first substitution; the dispatch arm now calls `cfg_load` ahead of `list`, `counts` and `dash`. The same shape hides anywhere a function memoises into a global and is called for its output.

## One awk per file is one process per record, and the agent inspecting every process is the bill (01.10.2026)
The model loop read the first line of each of 133 `model/*.tsv` with its own awk, `dir_roots` and the state-record loop did the same per state file, and `cfg_get` ran an awk per lookup: 206 programs per `--list` and 254 per `--counts`, started once or twice a second from the status bar and the refresher, which was ~490 new pids a second on the box and a full core of CrowdStrike Falcon working through its exec queue. One awk over the directory with `FNR == 1` and the key taken off `FILENAME` prints the same records for one process. Measured, not guessed: a `bash -x` trace with `PS4='+|${BASH_SOURCE##*/}:${LINENO}|'` counted the external commands per source line; `$BASHPID` in that prefix aborts every traced line under bash 3.2 and `set -u`, so it stays out.

## macOS awk stops dead at an argument it cannot open, so one awk over a glob needs the glob probed first (01.10.2026)
A state file deleted between `state_files` and the awk that reads them all would have ended that awk at the missing file and dropped every record after it for that repaint, where the old one-awk-per-file loop lost only that row. The BEGIN block now does `(getline junk < ARGV[i]) < 0` on each argument and blanks the ones that fail; gawk would only warn, the awk on this machine is BWK's and does not.

## A guard written for one site of a pattern belongs at every site of it (14.10.2026)
The fork-storm fix turned four per-file loops into one awk per directory and gave only `collect`'s awk the probe for a file that vanished between the glob and the read; `dir_roots`, `sub/` and `model/` have the same glob-then-awk shape and would have dropped every later record, with an awk error on stderr, the first time a file went in that window. A review caught it two weeks later. When a hazard is fixed at one call site, grep for the shape and fix every site in the same change, through one shared piece (`AWK_SKIP_GONE`) so the next site cannot be missed either; `tests/forks.sh` now makes the middle file of each directory unreadable and checks that the record after it still comes out.

## `tests/panes.sh` section 18 is a timing check, and on a loaded box it fails on main too (14.10.2026)
"focusing a seat pokes the list at once" waits 0.6 s for a poke whose `follow_cursor` alone takes ~0.45 s, and the port checks wait on the refresher's 2 s tick. With the endpoint agent inspecting every exec, a logged run put the poke at 0.57 s on average on main and 0.55 s on the fork-storm fix, and each tree failed section 18 in one run and passed it in another. A red section 18 is compared with a control run of main in a scratch worktree (`git worktree add --detach`) before it counts against a change; `tests/notes.sh` nests a panes run and inherits the same failures.

## A test variable named like a module global is overwritten the moment the modules load (14.10.2026)
The refresher test kept its config path in `CFG`, the name `lib/tagents/config.sh` uses for the parsed config text, so a write to `"$CFG"` where the two shared a shell put a file called `usage.watch<TAB>me` into the worktree root. The test's own paths get a prefix of their own (`RFCFG`), and a grep of the test for the module globals (`CFG`, `CFG_LOADED`, `USAGE_ON`, `STATE_DIR`, `LABELS`, `ORIGINS`, `COLS_FILE`, `SELF`, `HOST_S`) comes back empty before it is trusted.

## A fresh process computes once; in a long-lived one that is wrong (14.10.2026)
`cfg_check` guards itself with `CFG_CHECKED`, `cfg_note` adds to `CFG_NPROBLEMS` instead of setting it, `cfg_count_cached` sets the count from its cache without setting the guard, and `usage_env` exports `TU_ACCOUNT_RULES` only when there is something to export. Each was right for a process that runs once and exits, and the refresher that now calls them for a day made them wrong in three ways found by review: a verdict that aged was counted on top of the cached one (`cfg!1` became `cfg!2`), a config fixed or broken under it kept the marker it had (the guard was already set), and a rule removed from the config stayed in the environment of every `tusage --update`. A function written for a fresh process and moved into a loop needs its memos reset (`cfg_reset`) before each pass, or to run in a subshell that starts from a fresh state; `tests/refresh.sh` section 15 changes the config under the running loop and reads what the bar and `tusage` were given.
