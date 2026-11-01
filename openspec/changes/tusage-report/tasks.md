Every shell suite runs as `env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$(mktemp -d)" bash tests/<suite>.sh`. Tests build fixtures by hand under `mktemp` (`facts.tsv`, `sessions.tsv`, `projects.tsv`, `history.jsonl`), set `TU_STATE`, `TU_PROJECTS`, `TU_NO_METER=1`, `TU_ACCOUNTS` and `TU_ACCOUNT_RULES`, run with `--no-update`, and for names also export `TA_STATE_DIR` to a scratch directory. For each behaviour the failing test is written and watched to fail for the expected reason before the code that makes it pass.

## 1. Pin what stays

- [ ] 1.1 Add characterisation tests for the bytes of `tusage --session <id>` (heading, rows, total, model table, floor warning), `tusage --burn` and `tusage --json`, and re-pin the 14 fields and their order of `tusage --sessions` and the five fields of `--daily`; they pass on the unchanged script. Proof: `tests/tusage.sh`.
- [ ] 1.2 Add a test that `--sessions`, `--daily`, `--burn` and `--session <id>` leave `labels.tsv` and `title.tsv` unread and unwritten and read no transcript, with a `labels.tsv`, a transcript title and a stored calibration factor present; it passes on the unchanged script. Proof: `tests/tusage.sh`.

## 2. The command line

- [ ] 2.1 Write failing tests: `--by` with an unknown, repeated or fourth dimension exits 2 and the message lists the dimensions; `--session X --by day` gives the same table in either flag order; `--top`, `--sort`, `--color` and `--account` with a bad value exit 2; `--account nobody` lists the known accounts; an unknown option still exits 2. Proof: `tests/tusage.sh`.
- [ ] 2.2 Parse the new options (`--by` list, `--account`, `--project`, `--breakdown`, `--top`, `--sort`, `--color`, `--compact`, `--tsv`), keep the session apart from the report so the order of the flags does not decide, and validate their values. Proof: `tests/tusage.sh`.

## 3. Dates, weeks and months

- [ ] 3.1 Write failing tests: `--since` and `--until` as `YYYY-MM-DD` in `--by`, `--sessions`, `--daily` and `--json` (local midnight, end of the `--until` day); a date that does not exist and a value that is nothing exit 2 with `tusage: bad --since value <value>`; an all-digit `--until` is still an epoch and `--daily --until <epoch>` keeps its bytes; Sunday falls in the week of the previous Monday; `--by month` splits at the month; a `week` or `month` report with no `--since` reaches back to the start of the index. Proof: `tests/tusage.sh`.
- [ ] 3.2 Add one parser for `--since` and `--until` that every report goes through, and the `week` and `month` keys. Proof: `tests/tusage.sh`.

## 4. The breakdown engine

- [ ] 4.1 Write failing tests on `--tsv` for exact numbers: columns add up (total tokens is the sum of the four kinds, cache write joins 5-minute and 1-hour), a group is the sum of the rows beneath it at three levels, rows are sorted by dollars and time dimensions oldest first, `workflow` covers only workflow agents, an unrated model marks the dollars with `*` and the floor line appears, a zero-token placeholder and a zero total print 0.0% and exit 0, an empty window and a missing index keep their messages and exits. Proof: `tests/tusage.sh`.
- [ ] 4.2 Write the single aggregation pass (filters, pricing through the shared price function, a node per depth, models, days) and `--tsv`. Proof: `tests/tusage.sh`.
- [ ] 4.3 Write failing tests, then add `--breakdown` (model rows under the deepest rows, a no-op when `model` is a dimension), `--top` with the `… N more` row (twelve by default, `0` for all, time dimensions never cut) and `--sort cost`. Proof: `tests/tusage.sh`.
- [ ] 4.4 Write failing tests on the table: the list-price line and the line about a stored calibration factor appear only when they apply, and `--tsv` ignores `--top`. Proof: `tests/tusage.sh`.

## 5. Accounts and projects

- [ ] 5.1 Write failing tests: `--account` on `--by`, the summary, `--sessions` (14 fields), `--daily` (five fields), `--burn` and `--json`, with a comma list and a repeated flag; `?` selects unplaced sessions; `--by account` shows `? unplaced` and the closing line; `--project` with one and several values, and with `--account`. Proof: `tests/tusage.sh`.
- [ ] 5.2 Add the account and project filters in front of the aggregation and the existing reports, joining sessions to accounts only when an account is asked for. Proof: `tests/tusage.sh`.

## 6. Names and account names

- [ ] 6.1 Write failing tests on fixtures with `TA_STATE_DIR` set to a scratch directory: a typed name shows with its eight id characters; the first line for an id wins and an empty name is no name; a transcript `ai-title` shows when no name exists and a typed name beats it; neither shows the eight characters alone; the title is cached in `title.tsv` and the next run reads the cache; a session cut by `--top` has its transcript left unread; the write of `title.tsv` leaves no temporary file behind; with the modules unfindable the ids show and the report still exits 0. Proof: `tests/tusage.sh`.
- [ ] 6.2 Find `lib/tagents/` beside the real `tusage` by following symlinks by hand, in one function that the account lookup of 6.6 uses too, source the names modules in a subshell and resolve names for the surviving session rows only; `title.tsv` is written by `title_of` and by nothing in `tusage`. Proof: `tests/tusage.sh`.
- [ ] 6.3 Pin the copy of the symlink walk against `tagents`: a test runs `tusage` through a symlink in another directory and names resolve, and a second compares the text of the walk with the one in `tagents`. Proof: `tests/tusage.sh`.
- [ ] 6.4 Write failing tests for the session lookup: full id, unique prefix, name whole and ignoring case, name as a part; an ambiguous prefix and an ambiguous name exit 3 and list id, name, account and days on standard error; no match exits 1; an unknown id-shaped value keeps its empty detail and exit 0; `--account` narrows the candidates. Then implement the lookup. Proof: `tests/tusage.sh`.
- [ ] 6.5 Write failing tests with `HOME` and `TA_CONFIG` pointing at a scratch directory and a scratch TOML file, never `~/.config/tagents`: a config with profiles `work` and `personal` names the accounts in `--by account` and `--account work` is accepted; a rule of the config places a session by its directory; no config file gives `default` and each `~/.claude-*` with a history; a config with no `claude.profiles` does the same; a set `TU_ACCOUNTS` makes a config naming other profiles have no effect; a set `TU_ACCOUNT_RULES` is kept; a malformed config adds nothing to standard error; with no `lib/tagents/` beside the real file the discovery stays; a run through a symlink finds the config. Proof: `tests/tusage.sh`.
- [ ] 6.6 Before any verb runs and only when `TU_ACCOUNTS` is unset, source `core.sh`, `config.sh`, `accounts.sh` and `usage.sh` from the lib found by 6.2 inside one subshell with its standard error discarded, call `usage_env`, and export the two values it sets (keeping a `TU_ACCOUNT_RULES` that was already set); measure the cost of the call and record it for the pull request. Proof: `tests/tusage.sh`, `tests/modules.sh`.

## 7. One session by day

- [ ] 7.1 Write failing tests: `--session <name> --by day` and `--by day,model` on a three-day session print the heading (name, full id, account, directory), one row per day, the models beneath each day and a total equal to the sum; the window reaches back to the start of the index with no `--since`; a session picked by prefix gives the same table. Then implement. Proof: `tests/tusage.sh`.

## 8. Layout and colour

- [ ] 8.1 Write failing tests: `COLUMNS=80` keeps every line within 80 characters and keeps the dollars and share columns; the drop order of the columns at several widths; `--compact`; a label cut with `…` keeps the session's eight id characters; Cyrillic names pad by characters; the closing lines; `days` and `span` appear only without a time dimension and `models` only without model rows. Proof: `tests/tusage.sh`.
- [ ] 8.2 Write failing tests for colour: no escape sequence in a pipe, `--color always` emits it, `--color never` removes it, `NO_COLOR` and `TERM=dumb` remove it under `auto`, and `always` wins over `NO_COLOR`; one check through a pseudo-terminal (`script`, in its BSD or GNU form) that `auto` colours a terminal, reported as skipped when `script` is absent. Proof: `tests/tusage.sh`.
- [ ] 8.3 Write the render pass, move `uclen` and `upad` out of the summary into one shared awk block with a character-aware `utrunc`, and make every awk that uses them read the block. Proof: `tests/tusage.sh`, `tests/modules.sh`.

## 9. The summary

- [ ] 9.1 Write failing tests: dollars beside the 5 h, 24 h and 7 d lines, a by-account block only when more than one account has usage in the week, the heaviest sessions by name and eight id characters with the directory kept, `--account` narrowing it, and the no-index and empty-week behaviour unchanged. Then implement. Proof: `tests/tusage.sh`.

## 10. Compatibility and speed

- [ ] 10.1 Run `tests/ui.sh` and `tests/usage.sh` unchanged and keep them green; check `docs/demo/bin/tusage` against the new flags and change it only if a demo screen needs one. Proof: `tests/ui.sh`, `tests/usage.sh`.
- [ ] 10.2 Measure `--sessions`, `--daily`, `--burn` and `--session <id>` before and after on a fixture of several hundred thousand fact rows, twenty runs each, and compare medians and process counts from a `bash -x` trace; record the numbers for the pull request. Proof: `tests/tusage.sh` for the process count, the numbers by hand.
- [ ] 10.3 Run `shellcheck tusage lib/tagents/usage.sh` and compare the count with `origin/main`: no new finding. Proof: `shellcheck`.

## 11. Documents

- [ ] 11.1 Describe the reports in `docs/guide/cost.md` (accounts, nesting, per-model rows, week and month, dates, names, one session by day, width and colour, `--tsv`) with the screens of the design, and add the `--account` flag to the usage section of `docs/guide/accounts.md`. Proof: `pnpm docs:build`.
- [ ] 11.2 Update the `tusage` header comment, which is the `--help` text, in its existing layout, and run `pnpm plugin:gen` so `skills/tagents/references/scripts.md` carries it; commit the generated diff. Proof: `pnpm plugin:check`, `tests/tusage.sh` (the `--help` exit and the unknown-option exit).
- [ ] 11.3 Add one line under `[Unreleased]` in `CHANGELOG.md`, with no pull request number. Proof: `pnpm docs:build`.
- [ ] 11.4 Add a line to `LEARNING.md` for every mistake made and fixed on the way. Proof: review of `LEARNING.md`.

## 12. Gates

- [ ] 12.1 `tests/tusage.sh`, `tests/usage.sh`, `tests/ui.sh` and `tests/modules.sh`, each on a scratch tmux server, each exit 0. Proof: the four suites.
- [ ] 12.2 `pnpm spec:check`, `pnpm exec openspec validate tusage-report --strict`, `pnpm plugin:check` and `pnpm docs:build`, each exit 0. Proof: those commands.
