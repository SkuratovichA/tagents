## Context

`tusage` is a bash 3.2 and awk script at the repository root. It keeps an incremental index in `$TU_STATE` (default `~/.claude/agent-state/usage`): `facts.tsv` holds one row per five-minute bucket, session, agent and model with the request count and the token sums (`input`, 5-minute and 1-hour cache write, cache read, `output`, context sizes), `sessions.tsv` holds each session's first and last time, `projects.tsv` maps a slug to a directory, and `accounts.tsv` is the join of session to account built from each account's `history.jsonl` and `TU_ACCOUNT_RULES`. Every figure this change shows is a sum over `facts.tsv` rows, so no report needs the transcripts for usage.

The reports are separate functions: `report_by` (one dimension, cost units, a share bar), `sessions` (14 tab-separated fields), `daily` (five fields, the only one that splits by account and the only one that scales dollars by a stored calibration factor), `burn`, `session_detail`, `summary` and `json`. Dollars come from the `usd()` awk function in `AWK_PRICE`, which prices a row at its own model, and from `money()` for display. Colour escapes are printed unconditionally.

Other programs read the output. `lib/tagents/state.sh:446` runs `tusage --no-update --sessions` on every dashboard refresh, `lib/tagents/usage.sh:71,73` run `--daily --since month [--until]`, `lib/tagents/list.sh:943,995` run `--burn`, `lib/tagents/preview.sh:38` runs `--session "$sid" | tail -n +2` and `lib/tagents/closed.sh:184` runs `--session "$sid" | head -12`. `tests/ui.sh` and `tests/usage.sh` stub `--sessions` with its 14 fields, and `docs/demo/bin/tusage` is the stand-in the demo uses. These outputs are frozen by this change.

The name a person gave a session lives in `labels.tsv` in the state directory (`STATE_DIR=${TA_STATE_DIR:-$HOME/.claude/agent-state}`, `lib/tagents/core.sh:9`), one `key<TAB>name` per line with the session id as the key. `label_of` (`lib/tagents/names.sh:27`) prints the second field of the first line with that key, which the Rust `read_labels` (`crates/tagents-core/src/notify/state.rs`) and the Node `readLabels` (`packages/core/src/agent-state.ts`) do as well. `title_of` (`lib/tagents/state.sh:199`) reads the transcript's `ai-title` record through the cache `title.tsv`. The dashboard's own rule for a row's name is an awk function bound to pane titles (`nameof`, `lib/tagents/list.sh:300`), so there is no shell function to call for it: the reusable pieces are `label_of` and `title_of`. `lib/tagents/names.sh` is executed by three Rust parity tests and is not changed here.

## Goals / Non-Goals

**Goals:**

- One command answers "which account, which project, which session, which day, which model spent this", as a table a person reads in a terminal.
- A session is recognised by the name its owner gave it, and its id stays copyable.
- The dashboard's calls keep their bytes and their speed.
- The script stays bash 3.2 and awk, extends the existing `tusage`, and adds no runtime dependency.

**Non-Goals:**

- ccusage's other agent CLIs, `blocks`, `statusline`, `--timezone` and `--no-cost`.
- Any change to the index, to `lib/tagents/*.sh`, to the Rust core or to the Node packages.
- Calibrated dollars in `--by`, an HTML or chart export, and time zones other than the machine's.
- Changing what the dashboard shows or how often it asks.

## Decisions

### 1. One `--by` grammar of up to three dimensions

**Decision.** `--by` takes a comma list of one to three different dimensions from `account`, `project`, `session`, `day`, `week`, `month`, `hour`, `agent`, `model` and `workflow`. A repeated, unknown or fourth dimension exits 2 and names the valid ones. A report that names `workflow` covers only workflow agents, as `--by workflow` does.

**Reason.** The person's question is a path ("account, then project, then session"), and one list expresses every report the request names, ccusage's `daily`, `weekly`, `monthly`, `session` and `--instances` among them, without a flag per report. Three levels is as deep as a screen stays readable, and the model level that `--breakdown` adds is not counted.

**Rejected.** One flag or verb per report (`--accounts`, `--weekly`): each needs its own table code and its own flags. An unlimited depth: the tree stops being readable at four levels and the aggregate grows with the product of the dimensions. Keeping the silent fall-through of an unknown dimension to `project`: a typo prints a plausible table of the wrong thing.

### 2. Filters narrow, dimensions group, and `--session` is a filter

**Decision.** `--account` (repeatable, or a comma list), `--project` (a case-insensitive substring of the displayed path, repeatable) and `--session` narrow rows before they are grouped. `--session <x>` with no other report option keeps printing the existing detail. With `--by`, in either order, it runs the same engine on that session's rows. The last-flag-wins use of one `DIM` variable for both purposes ends: the session is held apart from the report.

**Reason.** One `DIM` variable holds both the report and the session, so `--session X --by day` silently prints whichever flag came last. Treating a session as a filter makes "one session by day" the same code path as every other table, and gives `--account work --session billing` a meaning.

**Rejected.** A `--days <session>` verb: a second way to ask for the same table. Putting the account filter inside `--daily` only: the person asked for every report to honour it.

### 3. Dimension keys

**Decision.** `week` starts on Monday and is labelled `wk <date of the Monday>`; `month` is `YYYY-MM`; `day` is `YYYY-MM-DD`; `hour` is `YYYY-MM-DD HH:00`. `account` is the account name, and a session no account claims is `? unplaced` in the table and `?` in `--tsv` and `--daily`. Time dimensions list the oldest first, other dimensions by dollars, and `--sort cost` puts time dimensions in dollar order.

**Reason.** Monday is the week ccusage and most calendars use, and labelling by the date avoids the ISO-week arithmetic a person would have to decode. `? unplaced` keeps the visible hole that "a wrong login is worse than a visible hole" already asks for, and says what to do about it in the closing line.

**Rejected.** ISO week labels (`2026-W44`): they cannot be typed into `--since`. Folding unplaced sessions into a default account: it makes an account's total wrong without saying so.

### 4. Windows and dates

**Decision.** One parser turns `--since` into a start instant and `--until` into an end instant. It keeps `5h`, `3d`, `30m`, `month` and seconds for `--since`, keeps an all-digit `--until` as an epoch, and adds `YYYY-MM-DD` to both: `--since` is local midnight of that day, `--until` is the end of that day. Anything else exits 2 with `tusage: bad --since value <value>`. `sessions`, `daily`, `report_by` and `json` go through it, so `--daily --since 2026-10-01` works and the epoch `--until` the dashboard sends keeps its bytes. The default window stays seven days. It reaches back as far as the index does, which is the retention of `TU_KEEP_DAYS` (62 days), when `--by` names `week` or `month` or when `--session` narrows the report and `--since` is absent. The first line of a table names the window by its first and last day.

**Reason.** `since_secs` evaluates anything it does not recognise as shell arithmetic, so a date would be read as a subtraction. A week table of seven days is one row, and a session's days are not all inside the last week.

**Rejected.** `--last N` of ccusage: `--since 7d`, `--since month` and a date already cover it. An extra `--timezone`: the machine's offset is what `--daily` uses and what the person reads.

### 5. One aggregation pass, one render pass

**Decision.** A single awk pass over `facts.tsv` filters rows (window, account, project, session, workflow), prices each at its model through `usd()`, and adds the row to a node at every depth of its key path (and one more node for the model when `--breakdown` is given). A node holds requests, input, cache write (5-minute plus 1-hour), cache read, output, dollars, the count of unpriced requests, the dollars per model, and its first day, last day and number of distinct days. The same awk sorts each parent's children, cuts them to `--top` with a remainder node, and prints the nodes depth-first. A second awk renders them: it reads the names, picks the columns the width allows, pads and truncates by characters and colours. `--tsv` prints the leaf nodes of the first pass without the second, and the cut to `--top` applies only to the table.

**Reason.** The facts file is the only large input and it is read once whatever the depth, as `report_by` reads it. Keeping rendering apart from aggregation lets `--tsv` and the tests read exact numbers, and lets the names, which cost a process or two, be resolved only for the session rows that survive the cut.

**Rejected.** One awk per level (a second pass per dimension): three reads of the largest file. A render that also aggregates: the width and the names are known only after the aggregate.

### 6. Dollars, shares and the floor

**Decision.** `--by` prints dollars at list price from `usd()`, formatted by `money()`, and the share of each row is its dollars over the report's dollars at every level. A row that includes a request on a model with no rate ends its dollars in `*`, and the report says the figure is a floor. A report whose dollars total zero prints 0.0% everywhere. The cost-unit definition stays in the spec for the summary, `--sessions` and `--json`. When a calibration factor is stored for an account in the table, a closing line says the figures are at list price and that `tusage --daily` scales them.

**Reason.** The person asked what each thing cost, and cost units hide the price difference between models. Unrated models make dollars a floor, so the mark belongs on the figure and not only in a footnote. `--daily` is the one report that scales by a factor, and a person comparing it with `--by day` should be told why the two can differ.

**Rejected.** A `--calibrated` flag: it widens the scope to the meter, and every other per-session report is already at list price. Shares of cost units: always defined, but they misrepresent a Haiku-heavy against an Opus-heavy session. A share bar and a largest-context column in the table: the tree's indentation carries the structure, the width is scarce, and the summary keeps `bar()` and the peak context.

### 7. Columns, width and compact tables

**Decision.** The columns are the label, `reqs`, `input`, `output`, `cwrite`, `cread`, `total`, `$`, `share`, then `days` and `span` when no dimension is a time dimension, then `models` when `model` is not a dimension. Tokens go through `human()` and dollars through `money()`, both already in `tusage`. The width is `COLUMNS` when numeric, else `stty size` on the terminal when standard output is one, else 120. Columns are dropped in a fixed order (`models`, `span`, `days`, `input`, `cwrite`, `cread`, `output`, `reqs`) until the label has 24 characters; the label, `total`, `$` and `share` are never dropped. `--compact` keeps only those four. A label that is still too long ends in `…`, and a session keeps its eight id characters. The pad-and-measure helpers `uclen` and `upad` that `summary()` defines inline move into one shared awk block next to `AWK_FMT`, with a character-aware `utrunc` beside them, because macOS awk counts bytes and names are written in several scripts.

**Reason.** A fixed drop order makes the table predictable between machines, and the dollars and the share are the point of the report. The shared block is the one place the glyph arithmetic lives, as `AWK_UNTITLE` is for titles.

**Rejected.** Wrapping rows onto two lines on a narrow terminal: it breaks `grep` and `cut`. Measuring display width of wide CJK characters: the helper counts characters, and names in wide scripts are rare enough to leave as an open point.

### 8. Colour

**Decision.** `--by` colours only when standard output is a terminal, `NO_COLOR` is unset or empty and `TERM` is not `dumb`. `--color always|never|auto` overrides, and `always` wins over `NO_COLOR` because it is an explicit request. The summary and `--session <id>` keep their unconditional colour, since `preview.sh` and `closed.sh` pipe the second into a tmux popup that renders it.

**Reason.** The `NO_COLOR` convention and a pipe both mean escape sequences are noise. An explicit flag also lets the tests check colour without a pseudo-terminal.

**Rejected.** Making the summary conditional as well: a different behaviour for a report this change only adds lines to.

### 9. Names come from the code that already decides them

**Decision.** A session's name is the typed name for its id (`label_of`), else the transcript's title (`title_of`), else the first eight characters of the id, with the eight characters printed after a name. `tusage` finds `lib/tagents/` beside its own real file by following symlinks by hand, sources `core.sh`, `names.sh` and `state.sh` inside a subshell that exists only to resolve names, and calls `label_of` and `title_of`. It does not copy the rule. When the modules cannot be found, names are skipped and the short ids show.

The name stage runs only on the session rows that survive the cut, and avoids one process per row: an awk pass over `labels.tsv` keeps the session ids that have any line (the first line then decides inside `label_of`), the `title.tsv` row for a session is passed to `title_of` as its cached title and size, and only a session with neither a label nor a cached title makes `title_of` read its transcript (`$TU_PROJECTS/<slug>/<sid>.jsonl`, the same lookup `origin_dir` makes). `title_of` writes `title.tsv`, which is the dashboard's own cache, so the title it finds is shared. `tusage` writes that file only through `title_of`, never with a writer of its own, and the write is atomic: `title_of` copies the cache without the session's row into `$TITLES.$$` in the same directory, appends the new row and renames it over the cache with `mv -f` (`lib/tagents/state.sh:233-241`). The write is a read, a copy and a rename, so two writers at once can drop each other's row; the cache holds only titles that a transcript read recomputes, so a lost row costs one more read and never a wrong title.

**Reason.** The brief for this change names one rule and forbids a second copy. The dashboard rule is awk bound to pane titles and tmux, which a command line has no use for, so the two shell pieces are what a session id needs. The only copy this adds is the symlink walk of about a dozen lines, which `tagents` (`tagents:458-476`) already carries because a script finds its own modules; a test runs `tusage` through a symlink and compares the walk's text with `tagents`.

**Rejected.** Reading `labels.tsv` and the `ai-title` record in `tusage`: a third implementation of the rule beside the shell, Rust and Node ones. Using the dashboard's pane titles and directory-name fallbacks: they need a live tmux server and the session's pane, which a report must not touch. Resolving names for every session in the window: a report of the whole retention would read hundreds of transcripts.

### 10. Finding a session

**Decision.** `--session <x>` takes the full id, else a unique id prefix, else a name matched whole and ignoring case, else as part of a name, over the typed names and the titles in the title cache, narrowed by `--account`. More than one match prints each candidate's id, name, account and days on standard error and exits 3. No match exits 1 with `tusage: no session called <x>`, except an id-shaped value (hexadecimal digits and dashes), which keeps its output, the heading and `(no usage recorded in the retained window)`, and exit 0. The heading of the plain `--session` detail, the id and the directory, stays as it is.

**Reason.** The prefix of an id keeps working for scripts. An ambiguous prefix picks the first match silently, which is the wrong session on a collision, so it joins the ambiguous-name case. The exit codes are 0, 1 (not found), 2 (usage) and 3 (ambiguous) so a script can tell a typo from a collision.

**Rejected.** An interactive picker: a command a script may run must not wait for input. Showing the name in the plain `--session` heading: `closed.sh` prints those first twelve lines under a name it already shows, and the bytes are frozen.

### 11. What machines get

**Decision.** `--tsv` prints the deepest rows of a `--by` report with no header, no colour, no rounding and no cut: one field per dimension, then requests, input, output, cache write, cache read, dollars to six decimals, unpriced requests, first day, last day and days. A session is its full id. `--sessions`, `--session <id>`, `--daily`, `--burn` and `--json` print the bytes they print without the new flags and gain only flags that narrow them. Tests pin the bytes of `--session`, `--burn` and `--json` before any code changes, and keep the existing 14-field pin of `--sessions`.

**Reason.** The spec for `--sessions` says 14 fields and every consumer indexes them, so a new field would be a contract change for the dashboard. A new flag costs nothing to consumers, and `--tsv` also gives the tests exact numbers without parsing a padded table.

**Rejected.** More fields at the end of `--sessions`: the 14-field requirement and the stubs in `tests/ui.sh` and `tests/usage.sh` would change for no consumer. Extending `--json`: its keys are a published shape.

### 12. Speed

**Decision.** The dashboard's calls pay for flag parsing and nothing else: `--sessions`, `--daily`, `--burn` and `--session <id>` resolve no names, join accounts only where they do already or when `--account` asks, and read the same files. `--by` makes one pass over `facts.tsv`, as `report_by` does, plus the name stage for displayed sessions, bounded by twelve rows per parent unless `--top` says otherwise. The task list measures the dashboard calls before and after on a large fixture and records the numbers in the pull request.

**Reason.** `--sessions` runs on every two-second refresh. The cost of this change belongs to the commands a person types.

### 13. The summary

**Decision.** The summary keeps its sections and its cost units. It adds dollars beside the three windows, a block of the seven days by account (printed when more than one account has usage), and shows the heaviest sessions by name and eight characters of id, next to the directory it already prints with the home as a tilde. A window that holds a request on a model with no rate ends its dollars in `*`, under the note `--by` prints; the by-account block counts an account that spent something in the seven days, and a name longer than 28 characters ends in `…`. `--account` narrows it.

**Reason.** The summary is the first thing a person runs, and the question "which account" belongs on it. Its layout stays so that nothing a person has learned moves.

### 14. Where it is written down

**Decision.** `docs/guide/cost.md` is the page that describes `tusage`, so the reports go there as sections with the screens of this document; the `tusage` header comment, which is `--help`, lists the new flags in its existing layout; `CHANGELOG.md` gets one line under `[Unreleased]`. Because `skills/tagents/references/scripts.md` embeds `tusage --help`, `pnpm plugin:gen` regenerates it and the diff is committed.

**Reason.** One page per tool keeps `docs/` navigable; the help text is a contract the plugin's generated reference mirrors.

### 15. Account names in a terminal come from the config that names them for the dashboard

**Decision.** When `TU_ACCOUNTS` is unset, `tusage` finds `lib/tagents/` the way decision 9 does, and inside one subshell, with its own standard error discarded, sources `core.sh`, `config.sh`, `accounts.sh` and `usage.sh` and calls `usage_env` (`lib/tagents/usage.sh:30`), which reads the profiles and the rules through `cfg_load`, `prof_pairs` and `cfg_expand_dir` and exports `TU_ACCOUNTS` and `TU_ACCOUNT_RULES`. `tusage` takes those two values from the subshell, once, and exports them for the rest of the run. It does this for the reports that name accounts (`--by`, `--daily`, the meter and the calibration) and for any run that gives `--account`, and for no other: the dashboard's refresh runs `--sessions`, `--burn`, `--json`, `--session <id>` and `--update`, which never read the config. The config file is the one `config.sh` resolves, `$TA_CONFIG` or else `${XDG_CONFIG_HOME:-$HOME/.config}/tagents/config.toml` (`lib/tagents/config.sh:18-19`), so a test points `TA_CONFIG` at a scratch file. `TU_ACCOUNTS` set in the environment skips all of this, because the dashboard sets it for every call it makes and a person who sets it means it. A `TU_ACCOUNT_RULES` already set stays and the config's rules do not replace it. With no config, no readable config, a config with no `claude.profiles`, or no `lib/tagents/` beside the real file, nothing is exported and `account_dirs` discovers the default account and every `~/.claude-*` with a history, as it does when no config exists.

**Reason.** The names a person sees in the dashboard are the profile names of the config, and `account_map` stores the pair beside `accounts.tsv` and rebuilds the join whenever the pair differs (`account_map` in `tusage`), so a terminal run with another pair rebuilds the join the dashboard keeps and the next dashboard refresh rebuilds it back. Calling `usage_env` is the one reader of the profiles and the rules; a second reader in `tusage` would drift from it. The subshell keeps the modules' functions out of `tusage`, so they cannot collide with its own, and the call costs a few tens of milliseconds, measured at task 10.2, which is why the dashboard's refresh path does not pay it. Sourcing the modules changes no file in `lib/tagents/`, which the Non-Goals keep.

**Rejected.** A reader of `config.toml` inside `tusage`: a second parser of a format the dashboard, the Rust core and the Node packages already read through one module each. Asking the user to export `TU_ACCOUNTS` in a profile: the config already says it. Sourcing the modules into the main shell: `tusage` and the modules define functions of the same kind, and a collision would change a report without a message.

## Example screens

The figures come from a fixture of twelve sessions in two accounts plus one run that no account claims, and are priced at the rates in the table, so the columns add up. The fixture's clock is Sunday 2026-11-01 and the window is the default seven days. The layouts are the rules above applied to it.

### The tree: where each account's money went

`tusage --by account,project,session` on a 140-column terminal. Names are the typed ones, except `Add invoice export`, which is a transcript title, and `e5d1f0a7`, which has neither. The last line before the total is the unplaced account.

```text
usage  2026-10-26 .. 2026-11-01  by account > project > session

                                   reqs   input  output  cwrite   cread   total         $   share  days  span          models
work                                812    1.7M    584k    9.2M  110.2M  121.7M      $118   72.5%     5  10-28..11-01  opus-5,sonnet-5 +1
  ~/git/work/billing-api            659    1.4M    483k    7.7M   92.3M  102.0M      $101   62.3%     4  10-29..11-01  opus-5,sonnet-5
    refactor-billing  3f9a1c20      502    1.2M    387k    6.3M   74.3M   82.1M     $86.1   53.1%     3  10-29..11-01  opus-5,sonnet-5
    Add invoice export  c04d7be1     61    130k     44k    690k    8.1M    9.0M     $10.1    6.2%     1  11-01         opus-5
    fix-flaky-ci  b72e90d4           96    150k     52k    780k    9.9M   10.9M     $4.75    2.9%     1  10-30         sonnet-5
  ~/git/work/web-app                153    290k    101k    1.5M   17.9M   19.8M     $16.7   10.3%     3  10-28..10-31  opus-5,sonnet-5 +1
    review-pr-218  91ab44ee         131    250k     89k    1.3M   16.8M   18.5M     $16.3   10.0%     2  10-28..10-30  opus-5,sonnet-5
    e5d1f0a7                         22     40k     12k    150k    1.1M    1.3M     $0.40    0.2%     1  10-31         haiku-4-5
personal                            318    660k    231k    3.5M   42.9M   47.3M     $44.3   27.3%     4  10-27..11-01  opus-5,sonnet-5
  ~/git/personal/tagents            215    470k    162k    2.6M   32.2M   35.4M     $38.8   23.9%     2  10-31..11-01  opus-5
    tagents-tusage  d8c3b615        215    470k    162k    2.6M   32.2M   35.4M     $38.8   23.9%     2  10-31..11-01  opus-5
  ~/git/personal/site               103    190k     69k    920k   10.7M   11.9M     $5.51    3.4%     2  10-27..10-28  sonnet-5
    site-redesign  0a6f7e92         103    190k     69k    920k   10.7M   11.9M     $5.51    3.4%     2  10-27..10-28  sonnet-5
? unplaced                           18     30k      9k     90k    700k    829k     $0.26    0.2%     1  11-01         haiku-4-5
  ~/scratch/probe                    18     30k      9k     90k    700k    829k     $0.26    0.2%     1  11-01         haiku-4-5
    7b2c5d33                         18     30k      9k     90k    700k    829k     $0.26    0.2%     1  11-01         haiku-4-5
total                              1148    2.4M    824k   12.8M  153.8M  169.9M      $162  100.0%     6  10-27..11-01  opus-5,sonnet-5 +1
```

The account `? unplaced` is one headless run no history lists. The closing line the spec asks for follows the table:

```text
1 session belongs to no account: TU_ACCOUNT_RULES places a session by the directory it started in.
Dollars are at list price. A meter factor is stored for work: tusage --daily scales its dollars by it.
```

### One account, narrowed

`tusage --by account,project --account work` prints only the work rows, with shares of the work total, so a single account reads as a whole.

### The accounts at a glance, on a narrow terminal

`COLUMNS=80 tusage --by account` drops `models`, `span`, `days`, `input` and `cwrite` and keeps the rest.

```text
usage  2026-10-26 .. 2026-11-01  by account

             reqs  output   cread   total         $   share
work          812    584k  110.2M  121.7M      $118   72.5%
personal      318    231k   42.9M   47.3M     $44.3   27.3%
? unplaced     18      9k    700k    829k     $0.26    0.2%
total        1148    824k  153.8M  169.9M      $162  100.0%
```

`COLUMNS=72 tusage --by account,project` leaves 24 characters for the labels by dropping `cread` as well, and `--compact` keeps only the label, total tokens, dollars and share:

```text
                           reqs  output   total         $   share
work                        812    584k  121.7M      $118   72.5%
  ~/git/work/billing-api    659    483k  102.0M      $101   62.3%
  ~/git/work/web-app        153    101k   19.8M     $16.7   10.3%
personal                    318    231k   47.3M     $44.3   27.3%
  ~/git/personal/tagents    215    162k   35.4M     $38.8   23.9%
  ~/git/personal/site       103     69k   11.9M     $5.51    3.4%
? unplaced                   18      9k    829k     $0.26    0.2%
  ~/scratch/probe            18      9k    829k     $0.26    0.2%
total                      1148    824k  169.9M      $162  100.0%
```

```text
                           total         $   share
work                      121.7M      $118   72.5%
  ~/git/work/billing-api  102.0M      $101   62.3%
  ~/git/work/web-app       19.8M     $16.7   10.3%
personal                   47.3M     $44.3   27.3%
  ~/git/personal/tagents   35.4M     $38.8   23.9%
  ~/git/personal/site      11.9M     $5.51    3.4%
? unplaced                  829k     $0.26    0.2%
  ~/scratch/probe           829k     $0.26    0.2%
total                     169.9M      $162  100.0%
```

### One session by day

`tusage --session refactor-billing --by day,model` finds the session by its name. The window defaults to everything the index holds, not to seven days.

```text
refactor-billing  3f9a1c20-6d4e-4b0a-9c75-1e2f8a7b5d90
work  ·  ~/git/work/billing-api  ·  3 days, 10-29..11-01

             reqs   input  output  cwrite   cread   total         $   share
2026-10-29    180    430k    137k    2.3M   24.5M   27.4M     $28.8   33.5%
  opus-5      142    310k     96k    1.9M   21.4M   23.7M     $26.5   30.8%
  sonnet-5     38    120k     41k    410k    3.1M    3.7M     $2.29    2.7%
2026-10-31    210    440k    150k    2.6M   33.0M   36.2M     $38.7   45.0%
  opus-5      210    440k    150k    2.6M   33.0M   36.2M     $38.7   45.0%
2026-11-01    112    290k    100k    1.4M   16.8M   18.6M     $18.6   21.6%
  opus-5       88    200k     70k    1.1M   14.8M   16.2M     $17.0   19.8%
  sonnet-5     24     90k     30k    260k    2.0M    2.4M     $1.53    1.8%
total         502    1.2M    387k    6.3M   74.3M   82.1M     $86.1  100.0%
```

### By week

`tusage --by week,account --since 2026-10-05` groups days into weeks that start on Monday, oldest first.

```text
usage  2026-10-05 .. 2026-11-01  by week > account

                reqs   input  output  cwrite   cread   total         $   share
wk 2026-10-05    240    520k    161k    3.1M   37.0M   40.8M     $44.5   17.0%
  work           240    520k    161k    3.1M   37.0M   40.8M     $44.5   17.0%
wk 2026-10-12    210    420k    140k    2.2M   26.5M   29.3M     $26.3   10.0%
  personal       130    280k     90k    1.5M   18.0M   19.9M     $22.0    8.4%
  work            80    140k     50k    700k    8.5M    9.4M     $4.23    1.6%
wk 2026-10-19    200    420k    135k    2.2M   25.5M   28.3M     $29.2   11.1%
  personal       200    420k    135k    2.2M   25.5M   28.3M     $29.2   11.1%
wk 2026-10-26   1148    2.4M    824k   12.8M  153.8M  169.9M      $162   61.9%
  work           812    1.7M    584k    9.2M  110.2M  121.7M      $118   44.9%
  personal       318    660k    231k    3.5M   42.9M   47.3M     $44.3   16.9%
  ? unplaced      18     30k      9k     90k    700k    829k     $0.26    0.1%
total           1798    3.8M    1.3M   20.3M  242.8M  268.2M      $262  100.0%
```

### Per-model rows

`tusage --by project --breakdown --account work` adds the models beneath each project. The `models` column is dropped because the model is a row.

```text
usage  2026-10-26 .. 2026-11-01  by project > model

                         reqs   input  output  cwrite   cread   total         $   share  days
~/git/work/billing-api    659    1.4M    483k    7.7M   92.3M  102.0M      $101   85.8%     4
  opus-5                  501    1.1M    360k    6.3M   77.3M   85.0M     $92.4   78.5%     3
  sonnet-5                158    360k    123k    1.4M   15.0M   16.9M     $8.57    7.3%     3
~/git/work/web-app        153    290k    101k    1.5M   17.9M   19.8M     $16.7   14.2%     3
  opus-5                   77    160k     58k    900k   11.6M   12.7M     $13.7   11.6%     1
  sonnet-5                 54     90k     31k    420k    5.2M    5.7M     $2.58    2.2%     1
  haiku-4-5                22     40k     12k    150k    1.1M    1.3M     $0.40    0.3%     1
total                     812    1.7M    584k    9.2M  110.2M  121.7M      $118  100.0%     5
```

### Cutting a long table

`tusage --by session --top 3` keeps the three largest sessions and sums the rest.

```text
usage  2026-10-26 .. 2026-11-01  by session

                             reqs   input  output  cwrite   cread   total         $   share  days  span          models
refactor-billing  3f9a1c20    502    1.2M    387k    6.3M   74.3M   82.1M     $86.1   53.1%     3  10-29..11-01  opus-5,sonnet-5
tagents-tusage  d8c3b615      215    470k    162k    2.6M   32.2M   35.4M     $38.8   23.9%     2  10-31..11-01  opus-5
review-pr-218  91ab44ee       131    250k     89k    1.3M   16.8M   18.5M     $16.3   10.0%     2  10-28..10-30  opus-5,sonnet-5
… 5 more                      300    540k    186k    2.6M   30.5M   33.9M     $21.0   13.0%     5  10-27..11-01  sonnet-5,opus-5 +1
total                        1148    2.4M    824k   12.8M  153.8M  169.9M      $162  100.0%     6  10-27..11-01  opus-5,sonnet-5 +1
```

### Finding a session

```text
$ tusage --session tagents
tusage: "tagents" matches 2 sessions, pick one by its id:
  7c3f4e55  tagents-rust    personal  10-13..10-20
  d8c3b615  tagents-tusage  personal  10-31..11-01
$ echo $?
3
$ tusage --session nothing-like-it
tusage: no session called nothing-like-it
$ echo $?
1
```

### For machines

`tusage --by account,project --tsv` has 12 tab-separated fields per row: the account, the project, requests, input, output, cache write, cache read, dollars, unpriced requests, first day, last day and days.

```text
work	~/git/work/billing-api	659	1440000	483000	7740000	92300000	100.937500	0	2026-10-29	2026-11-01	4
work	~/git/work/web-app	153	290000	101000	1470000	17900000	16.652500	0	2026-10-28	2026-10-31	3
personal	~/git/personal/tagents	215	470000	162000	2600000	32200000	38.750000	0	2026-10-31	2026-11-01	2
personal	~/git/personal/site	103	190000	69000	920000	10700000	5.510000	0	2026-10-27	2026-10-28	2
?	~/scratch/probe	18	30000	9000	90000	700000	0.257500	0	2026-11-01	2026-11-01	1
```

### The summary's new lines

The three window lines carry dollars, and a block follows when more than one account has usage. The sections not shown stay as they are, and the context and subagent figures of the session lines are not part of the fixture above.

```text
last 5 h  …
last 24 h …
last 7 d      37.9M   $162    1148 requests

by account (7 d)
  work                                       $118   72.5%
  personal                                  $44.3   27.3%
  ? unplaced                               $0.26    0.2%

…
heaviest sessions (7 d)
  refactor-billing  3f9a1c20  18.4M    502 req  ctx 612k  sub 4.1M  ~/git/work/billing-api
  tagents-tusage  d8c3b615     7.8M    215 req  ctx 388k  sub    0  ~/git/personal/tagents
```

## Risks / Trade-offs

- **A person with a config that names accounts sees the config's names in every terminal run.** An account is named by its profile and not by the suffix of its `~/.claude-*` directory, in `--daily` and in the values `--account` accepts, as well as in the new tables. A scripted call that matched the old name sets `TU_ACCOUNTS` to keep it.
- **The `--session` heading keeps the id and not the name.** It is read by the closed-session preview, which already shows the name above it. The name appears in every new table and in the heading of `--session <x> --by …`.
- **Title lookup writes `title.tsv`, through `title_of` only.** That file is the dashboard's cache and the write is an atomic rename (`lib/tagents/state.sh:233-241`), so a report that reads a transcript's title makes the next dashboard refresh cheaper. Two writers at once can drop a row, which one more transcript read puts back. A session whose title has never been read is matched by name only after a report has printed it once.
- **Day buckets use the machine's present UTC offset**, as `--daily` does. A row from the other side of a daylight-saving change lands in a day boundary that is an hour off. The week and month dimensions inherit this.
- **The shape of `--by` changes for the person who reads it.** It prints dollars and token kinds, not cost units with a share bar and the largest context, `--by day` lists the oldest day first, and an unknown dimension is an error. No program in the repository reads the table.
- **Wide characters.** Padding counts characters, so a name in a script with double-width glyphs misaligns the columns after it.
