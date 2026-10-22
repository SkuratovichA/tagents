## A shell script that updates the checkout it lives in must not still be reading itself (20.10.2026)

`install.sh` lives inside the managed copy it moves to a new commit. `sh` reads a script command by command, by offset: when the file changes under it halfway, the next command comes from the middle of whatever is now at that offset. The whole program is therefore one function, called on the last line as `main "$@"; exit $?`; the last line is read in one piece before anything runs, and nothing after `exit` is ever read.

## `ln -s` replaced by `printf > dest` writes through the symlink (20.10.2026)

Turning a symlink into a wrapper file with a plain redirect writes the wrapper INTO the file the link pointed at: the old checkout's `tusage` would have become a three-line stub and the next `git status` in it would have been the first sign. `write_wrapper` removes a symlink first and builds the new file beside the destination, then `mv`s it over; `tests/install.sh` case 2 pins that the old target is untouched.

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
## `perl -pi -e 's|…\|\|…|…|'`: an escaped delimiter is a bare `|`, i.e. an empty alternation (18.09.2026)

With `|` as the substitution delimiter, `\|\|` in the pattern is un-escaped to `||` before the regex
is compiled, which matches the empty string at every position — the replacement was splattered between
every character of lib/tagents/list.sh (807 lines "changed", the file unreadable). Use `s{…}{…}` when
the pattern contains a pipe, and check `git diff --stat` before running anything on the result.

## tmux's default pane title is the FULL host name; every "that is just the hostname" check used `hostname -s` (18.09.2026)

On a Mac `hostname` is `sukas-MacBook-Pro.local` and `hostname -s` is `sukas-MacBook-Pro`; tmux titles
an untitled pane with the former, so the "names nothing" rule in preview_name, ask_kill, the list and the
window names never fired here and the machine name became the agent's name. Found by D4 of
tests/headless.sh, whose parent pane is a fake claude that sets no title. One rule now (`host_title` in
core.sh, both forms), and a test fixture that is compared against the committed entry byte for byte must
title its panes itself rather than depend on what the machine is called.

## A test that cannot fail is not a test: take the code out and watch it go red (19.09.2026)

Two post-review tests passed with the very code they claimed to pin removed: D4's `fromjson?` guard
(jq carries on past a line it cannot parse either way; the `?` only quiets stderr, which `--preview`
never shows) and D6c's live-over-dead rank in the session-id map (livesid had already dropped every
corpse before the map was built, so the rank was dead code). The reviewer's mutation check caught both;
the rank went, and the comments now say what each fixture actually pins. For every "this test pins X",
remove X once and run the suite before calling it a test.

## A suite written on main while a branch was out misses that branch's setup (11.10.2026)
`tests/resurrect.sh` landed on main after child-sessions branched, so it never got the `unset CLAUDE_PID` the branch gave every suite that plays the hook from a stub; rebased, 42 of its checks failed because the hook classified the stubs against the real Claude session running the suite. A clean textual rebase proves nothing about files only one side knew: run every suite afterwards, and run the failing one on main as the control — ten other checks there fail on main too, and were not this branch's. Also: the root `pnpm typecheck` nests a second pnpm that resolves 9.1.4 on this machine and stops on `ERR_PNPM_BAD_PM_VERSION`; `pnpm -r typecheck` and `pnpm -r test` run the same gates.

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

## `tests/panes.sh`'s port-claim checks fail on main too, reading an earlier port (14.10.2026)
"an overwritten port is reclaimed on the next tick" and "a refresher whose posts are refused never claims the port" failed in 2 of 3 runs on unchanged main and 1 of 3 on the branch, each time reading a lower port than the live list's (63474 for 63501, 63560 for 63700, 62719 for 62870): an earlier refresher of the test's own dashboard still holds the claim. Judge them like section 18 — against a control run of main — and do not chase them as a regression of the change under test.

## Claude Code fires Stop before it writes the turn's last assistant record (17.10.2026)
The hook read the answer for the answer-ready notice from the transcript at Stop and got the previous turn's text. A probe showed the record lands after the hook has run; the Stop payload's `last_assistant_message` carries it, and the hook reads that.

## tmux 3.7: `display -p -t %gone` exits 0 (17.10.2026)
A pane that no longer exists prints empty fields and exits 0, so the exit code proves nothing. The notify probe treats empty fields as `NO_SUCH_PANE`.

## `launchctl bootstrap` of a disabled label says "5: Input/output error" (17.10.2026)
Nothing in the error names the cause. `launchctl print-disabled gui/$(id -u)` lists the label as disabled and `launchctl enable gui/$(id -u)/<label>` fixes it; `install` prints that hint now.

## os.Logger: `.info` is not persisted, and interpolated strings are `<private>` (17.10.2026)
The helper's click lines were missing from `log show` without `--info`, and their argv showed as `<private>`. Lines worth keeping are logged at `.notice` with `privacy: .public`.

## KeepAlive with `SuccessfulExit=false` never restarts an exit 0 (17.10.2026)
`run` exited 0 when its start threw, so launchd left the service dead. It exits 1 now, and `ThrottleInterval` 300 keeps a broken start from looping.

## `ps -o lstart` prints local time in the locale's format (17.10.2026)
The lock compared a holder's start time read with `ps` against a UTC time. `ps` runs with `TZ=UTC` and `LC_ALL=C`.

## `fs.watch` on something that may appear: arm the watch, then look (17.10.2026)
A directory created between the existence check and the watch was never watched. The service arms the watch first and re-reads the state after it.

## BSD `sed -i` takes the next argument as the backup suffix (17.10.2026)
`sed -i 's/a/b/' f` is GNU syntax; on macOS it is `sed -i '' 's/a/b/' f`.

## A notice click runs the script it names, and that script re-points tmux's global hooks at itself (17.10.2026)
The notices pointed at the worktree's `tagents`, so the owner's clicks ran code that was being rewritten, and every click re-installed the dashboard's focus hooks from the worktree. `install` gives the service the `tagents` on the installing shell's PATH; a live service is never pointed at a tree being edited.

## A hook's `run-shell -b` runs against a later state than the one it tested (17.10.2026)
The focus hook's `if-shell -F '#{@tagents_slot}'` passed while the placeholder was the empty seat, but the unpark it scheduled ran after a dock had moved that placeholder home, and handed the dock back. The hook passes `#{window_id}`, and unpark acts only while the placeholder is still in that window, re-checked inside its atomic command list.

## A worker started without TERM or LANG fails suites that pass in a terminal (18.10.2026)
A `claude -p` worker resumed from a launcher had neither: `locale` said C and `$TERM` was unset. With TERM unset, tmux 3.4's server dies ("server exited unexpectedly") on the second `new-session -x 200 -y 50` of a fresh socket, so tests/resurrect.sh lost 10 checks; in the C locale the server stores every non-ASCII byte of a pane title as `_`, so tests/names.sh lost its Cyrillic ones. Main and the branch failed identically, which is what pointed at the environment rather than the merge. The suites now bring their own TERM and a UTF-8 LC_CTYPE when the caller has none; before calling a red suite a regression, compare `env | grep -E '^(TERM|LANG|LC_)'` with a terminal's.

## A merge of two branches that each passed its own suites still owes the other's checks (18.10.2026)
child-sessions added one awk per pane-less record (the title cache lookup) and a second `hostname` call; main had meanwhile landed tests/forks.sh, which pins both counts, and tests/events.sh, whose process checks compared against the merge base. Neither branch was wrong alone. After a merge, run every suite either side added, and read a reference of the form "the merge base's hook" again: once the base moves it compares something else.

## bash without TERM has TERM=dumb, so `${TERM:-default}` keeps "dumb" (18.10.2026)
bash 3.2 started with no TERM in its environment sets an unexported shell variable TERM=dumb, and `export TERM=${TERM:-xterm-256color}` then exports "dumb". A tmux client on it fails with "open terminal failed: terminal does not support clear", so the suites' keeper never attached and every check needing a client (switch-client, display-popup) failed. Three fixes that all kept "dumb" failed the same way; a five-line repro printing `#{client_termname}` and the client's stderr showed it at once. The suites treat "dumb" as missing.

## `sleep 0.05` is 0.12 s at background priority, so a wait counted in sleeps is not a wait in seconds (18.10.2026)
In a detached worker every short sleep overshot by ~70 ms (timer coalescing): the dock lock's 36 tries took 4.4 s on main and on the branch alike, while exec cost 2 ms. Timing each phase of the click (startup 0.07 s, lock 4.4–4.8 s, dock 0.2 s) on both trees showed the "slower merge" was the same loop on a busier box. A wait that a test bounds in seconds is bounded by the clock (`lock_dir ... 3`), not by a count of sleeps.

## macOS fs.watch on a file can miss an append made right after an event (18.10.2026)
libuv re-arms a file's kqueue watch only at the loop's next poll, so an append landing in between raises no event at all. A probe appending inside the watch callback saw 1 event for 2 appends in one run of three. The follower drains once more after the re-arm (two setImmediate hops); a longer wait in the test would not have helped, since the event never comes.

## macOS keeps an app's notification icon from its first permission request (18.10.2026)
The helper app first asked for permission before it had an icon, and every notice and its System Settings entry kept a generic icon. Restarting NotificationCenter and usernoted, bumping `CFBundleVersion` and re-registering with lsregister changed nothing, while a copy under a fresh bundle id showed the icon at once. The bundle id now follows the icon, so a new icon is a new registration.

## Two `wait-for -S` sent while nobody waits cancel each other (18.10.2026)
tmux keeps one woken flag per channel, and a signal on a channel nobody waits on does not set it twice: the second one removes the channel together with its flag. A scratch server signalled twice and then waited blocked until a third signal. A waiter that sleeps between two waits, to batch a burst, therefore loses every second ring, and two rings in the gap between any two waits are lost too. Every ring now also bumps a counter in the same tmux call (`@tagents_evgen`, `@tagents_gen`), and a waiter waits through `if-shell -F "#{==:<counter>,<last seen>}"`, so the server only lets it wait when nothing has rung since its last look.

## tmux 3.7b has no after-swap-pane, after-join-pane, after-break-pane, after-move-window or after-respawn-pane (18.10.2026)
`set-hook -g after-swap-pane …` fails with "invalid option", and in a one-call list of `set-hook` commands that failure skips every hook after it. `window-layout-changed` fires for a swap across windows (in both), a join and a break; nothing fires for move-window or respawn-pane, so tagents' own swaps, breaks and unparks ring the channels themselves.

## bash 3.2 `read -t` returns 1 for a timeout and for an end of file alike (18.10.2026)
Later versions return more than 128 on a timeout; macOS's /bin/bash does not, so a loop that read 1 as "the writer is gone" could not tell. The refresher no longer asks: its FIFO is opened read and write, so it never sees an end of file, and the waiter writes its own exit status into it, where anything but 0 is tmux gone. A TERM trap is also deferred while `read -t` blocks, up to the whole timeout, so the refresher has none and the next one sweeps what a killed one left.

## A test that unsets TMUX talks to the live tmux server (18.10.2026)
After `unset TMUX TMUX_PANE`, a bare `tmux`, or any program the test starts that calls one, goes to the default socket, which is the owner's own server whenever the suite runs from a shell inside tmux. One line in tests/refresh.sh ran `tagents --focus-hooks` that way and left the `[42]` channel hooks and focus hooks pointing at the test's temporary tree; once the tree was deleted, every return to the terminal showed `… --poke … returned 127`. A test's `-L` flags and shell functions do not reach the processes it starts. Every suite now sources tests/scratch-guard.sh, which refuses to run unless TMUX_TMPDIR points at a scratch directory: `env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/<suite>.sh`.

## A tick does work nobody wrote down, and an event loop loses it (18.10.2026)
Replacing the 2 s tick with rings kept everything the tick did on purpose and lost two things it did by being there. The seat repair rode the slow tick every 10 s; without a tick, a seat lost just after a slow pass waited for the next ring or the minute-long idle pass, and only the copy of tests/panes.sh nested in tests/notes.sh caught it. The bar's counts were read right after posting a reload, and the reload is asynchronous, so they were the previous reload's; the next tick used to correct them within 2 s, and without one the bar stayed a change behind. The refresher now owes itself a slow pass when the dashboard window has no seat and reads the counts on every pass. Before taking a timer out, list everything that runs on it.

## A requirement over 500 characters fails `openspec validate --strict` (18.10.2026)
While the specs were written, every requirement that stated a rule in one long paragraph failed strict validation: the limit is on the requirement's text, the paragraph under `### Requirement:`. Split such a requirement into two, each with its own scenario, rather than cutting what it says. The same goes for a correction that makes an existing paragraph longer; seven of the review corrections on 20.10 needed a new requirement for that reason.

## macOS awk counts bytes, so a letter test on non-ASCII text works from UTF-8 bytes (20.10.2026)
`length("я")` is 2 and `[[:alpha:]]` rejects it in `/usr/bin/awk`, so "one character that is no letter or digit" cannot be written with a length or a class; it is a set of UTF-8 byte ranges, and in a UTF-8 locale awk also equates non-ASCII strings by collation (`"я иду" == "два слова"` is true), so name comparisons run under `LC_ALL=C`. The rule was written three times in awk and had drifted from its own comment, exempting only ASCII letters and digits; it now lives once in `AWK_UNTITLE` (`lib/tagents/names.sh`) and a test pins that `function untitle` occurs once.

## The ledger hook read TA_STATE where everything else reads TA_STATE_DIR (20.10.2026)
`hooks/ticket-ledger.sh` read `TA_STATE` and cached PRs in `~/.claude/agent-state` when only `TA_STATE_DIR` was set, and its test exported the same wrong variable, so the test agreed with the bug. A test that sets the variable the code reads proves nothing about the name; the suite now runs with a scratch `HOME` and checks that nothing lands under it.

## The notify LaunchAgent named the base bundle id while an app with an icon ran under its own (20.10.2026)
`packages/notify/macos/build.sh` gives a helper app built with an icon the bundle id `<base>.i<first 8 hex of the icon digest>`, and the LaunchAgent went on writing the base id into `AssociatedBundleIdentifiers`, the key System Settings files a job under its app by in Login Items; a doc comment said the `Label` did that filing. What a build produced is read back from the built artifact (`plutil -extract CFBundleIdentifier raw <app>/Contents/Info.plist`), not assumed as a constant or recomputed from the build's rule, and a comment that says which key does a job is checked against launchd.plist(5).

## A copy pinned to the shell by a comparison test drifted with the test green (20.10.2026)
`untitle()` in `packages/notify/src/compose.ts` copies the glyph rule of `AWK_UNTITLE`, and a test runs both on a list of titles; when the rule changed to keep `я иду`, the list had no title that told the old rule from the new one, so the copy kept dropping the word and the test stayed green. When a rule that a copy mirrors changes, add the input that exercises the change to the pin first, watch it fail, and only then fix the copy; a few explicit expected values beside the comparison keep the pin from resting on the two copies agreeing.

## `sort -u` merges names too, and a keyed sort does not keep equal keys together (20.10.2026)
The collation that makes awk call `я` and `ю` equal governs `sort` as well: `printf 'я\nю\n' | sort -u` prints one line, so a name was lost from a list of directories, and `sort -s -k2,2` leaves rows whose keys weigh the same in the order they came in (`я ю я`), so a consumer that groups runs or compares with the previous line splits or merges groups. Fixes that keep the order of ASCII names: `LC_ALL=C sort -u` where the lines are what is counted, and for a keyed sort a number per distinct name (`gnum` in `list.sh`, field 15) sorted on right after the name, because `sort -f` or `LC_ALL=C` would reorder mixed-case names (`Web` before `api`). Every awk in `lib/` and `hooks/` now runs as `LC_ALL=C awk`, and `tests/modules.sh` lists any call that does not; a test for a pin uses one letter per name, since longer names can survive by luck, and is run once without the pin to see it fail.

## tmux `-t "=name"` finds no session for set, show and display; the target needs the colon (22.10.2026)
An exact-name target written `=name` worked for the commands whose target is a session by definition and found nothing for `set`, `show` and `display` aimed at a session, which read it as a window or pane name; `=name:` is the form that names the session for all of them. Found while the session-level options of the window-rows build were failing silently under `2>/dev/null`. Every exact-name target in a command that is not a session command is written `=name:`, and a check of such a call runs it against a scratch server with a session of that name and reads the option back.

## The session record letter `S` was already a record of the state file (22.10.2026)
The window-rows build added a record per session to the stream `collect` emits and named it `S`, which the state-file reader already used for something else, so one consumer read the other's lines as its own. The session record is `G` (P pane, W window, G group). A new record letter is looked up in every awk that switches on the first field of a state or snapshot file before it is chosen, and the consumer of the old letter is shown not to see the new record.

## Functions appended to tnotes with `cat >>` landed after the dispatch case and were never defined (22.10.2026)
`tnotes` is a script that defines its functions and then ends in a `case` that runs the verb, so a function appended to the end of the file sits behind the `case` and does not exist when the verb runs; the call failed with "command not found" only for the verbs that reached it. New functions go above the dispatch (beside the functions they belong with), and `bash -n` cannot see this, so the check is to run the verb on a scratch server and see the function's effect.
