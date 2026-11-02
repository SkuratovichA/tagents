# Cost

With cost on, each row shows what its session has spent and which model it is on, and the footer shows the month against your limit. `tusage` is the program behind it: it reads the transcripts Claude Code writes and prices them.

```
├─ ⚠ BLOCKED   2:14  api      142k  $38.3  fable5  %31  ⑂$6.94
```

## Switching it on

`tusage` is only run once `usage.watch` names a profile in your [config](./accounts) (see `config.example.toml`). Without it no cost is shown anywhere: no figure in the status bar, no footer under the list, no `$` window, no cost column or `/5h` burn. Hiding the column is a separate, per-run choice; see [Hiding columns](./dashboard#hiding-columns).

## Where the number comes from

Claude Code keeps its own cost ledger and publishes it to the status line. For any session that is open, the dollar figure **is** that ledger: exact, and inclusive of the requests that never reach the transcript at all (retries, conversation titles, away summaries).

The status line is registered with `refreshInterval: 30` (see [Getting started](./getting-started#_2-register-the-status-line)), which matters more than it looks. Without it an idle session never re-renders, so it would sit on a stale estimate precisely when you are staring at it wondering why the two disagree.

### The `~` estimate

A figure prefixed with **`~` is an estimate**: `tusage` pricing the transcript. It is what closed sessions get, and what the `/5h` burn and the `⑂` subagent share always are, since the ledger publishes no breakdown. Measured against the ledger it lands within a few percent. Never compare a `~` figure to the status line and expect them to match.

### Priced per request

The fallback is priced per request, **at the model that actually served it**, not at the model the session is on now. A session that starts on one tier and finishes on another, or that fans work out to subagents on a cheaper tier, is mispriced badly if you multiply its token total by a single rate.

Subagent spend is included in the session total and also shown separately (`⑂`), because "why is this session expensive when I have barely typed into it" is usually answered by a workflow.

`tagents --preview` and `tusage --session <id>` break a session down per subagent and per model, so a mid-session switch shows up as two priced rows.

## The model column

The model column is the model the session is **set to now**, which is a different question with a different source. The transcript records the model of every assistant *message*, so it can only ever say what answered last: flip a session to another model and say nothing, and the newest message on disk is still the old one. The only channel carrying the configured model is the status line payload, which is why `hooks/claude-statusline.sh` exists. Without it the column falls back to the last model billed, which is correct right up until you switch.

## The month and its meter

The estimate runs steadily beside the account's own meter without tracking it ($807 against $733 one day, $1108 against $830 a fortnight later), and a ratio typed in by hand goes stale within days. So `tusage --meter` asks the account.

- **How**: a GET to `/api/oauth/usage` with the OAuth token Claude Code keeps in the keychain for the default config dir, giving the month-to-date spend and the limit behind it.
- **Where it lands**: in `meter.tsv`, one row per account. It is refreshed at most every `TU_METER_TTL` seconds (900 by default, 300 past 90% of the limit), and it re-prices the per-day factor so `--daily` and the sparkline agree with it.
- **How it is refreshed**: `--update` refreshes it in passing, which is how the dashboard gets it for free.
- **Turning it off**: `TU_NO_METER=1`.
- **The token** is read into a variable, handed to curl as one header and dropped. It is never printed, never logged, never written down.

On screen, while a reading is under two days old, the limit is the meter's own and the month wears a `~`, with `~meter HH:MM` in the footer naming when it was read. `usage.monthly_limit_usd` is what shows when the meter cannot be reached.

A seat with no meter (a plan, not credits) answers without a spend figure and is left alone for a day.

### Setting it by hand

| way | what it does |
|-----|--------------|
| `tusage --calibrate work 732.71` | the manual fallback, for an account whose meter this cannot read |
| `usage.meter: "2026-09-10 15:30 = 684.66"` in the config | overrides the fetched reading entirely |

A typed reading from another month, or one implying a correction outside 0.5 to 1.5, is ignored and the footer says so.

## Reports in a terminal

Run by hand, `tusage` answers where the money went. Every table prices each request at the rate of the model that served it, in dollars at list price, from the same index the dashboard reads.

### The summary

`tusage` with no arguments prints the last five hours, 24 hours and seven days in cost units and in dollars, where the seven days went, the top projects, and the heaviest sessions by name with eight characters of the id. When more than one account spent something in the seven days it adds the week by account. A `*` after a dollar figure says a request ran on a model with no published rate and counts as $0, so the figure is a floor.

```text
 cost = input-token equivalents: in + 1.25*cw5m + 2*cw1h + 0.1*cread + 5*out

last 5 h         1.5M     $7.50       5 requests   peak ctx 612k
last 24 h        4.5M     $13.5      12 requests
last 7 d         7.5M     $24.5      26 requests

by account (7 d)
  work                                           $17.5   71.4%
  personal                                       $6.00   24.5%
  ? unplaced                                     $1.00    4.1%

where it goes (7 d)
  cache WRITE          0 raw ->         0  ······················  0%
  cache READ           0 raw ->         0  ······················  0%
  output            500k raw ->      2.5M  ███████··············· 33%
  88% of requests carry more than 200k of context

top projects (7 d)
  ~/git/work/billing-api                          3.5M  ████████████████
  ~/git/personal/tagents                          3.0M  ██████████████··
  ~/scratch/probe                                 1.0M  █████···········

main sessions vs everything they spawn (7 d)
  main sessions                                   7.5M  ████████████████ 100%

heaviest sessions (7 d)
  refactor-billing  3f9a1c20      3.5M     16 req  ctx   612k  sub       0  ~/git/work/billing-api
                    d8c3b615      3.0M      7 req  ctx   388k  sub       0  ~/git/personal/tagents
                    7b2c5d33      1.0M      3 req  ctx    50k  sub       0  ~/scratch/probe
```

### Where each cost comes from

`--by` takes up to three dimensions, comma separated, and nests each under the one before it: `account`, `project`, `session`, `day`, `week` (from Monday), `month`, `hour`, `agent`, `model` and `workflow`. A row is the total of everything under it, and its share is its dollars over the dollars of the report.

```text
usage  2026-10-26 .. 2026-11-01  by account > project > session

                                     reqs   input  output  cwrite   cread   total         $   share  days  span          models
work                                  812    1.7M    584k    9.2M  110.2M  121.7M      $118   72.5%     5  10-28..11-01  opus-5,sonnet-5 +1
  ~/git/work/billing-api              659    1.4M    483k    7.7M   92.3M  102.0M      $101   62.3%     4  10-29..11-01  opus-5,sonnet-5
    refactor-billing  3f9a1c20        502    1.2M    387k    6.3M   74.3M   82.1M     $86.1   53.1%     3  10-29..11-01  opus-5,sonnet-5
    Add invoice export  c04d7be1       61    130k     44k    690k    8.1M    9.0M     $10.1    6.2%     1  11-01         opus-5
    b72e90d4                           96    150k     52k    780k    9.9M   10.9M     $4.75    2.9%     1  10-30         sonnet-5
  ~/git/work/web-app                  153    290k    101k    1.5M   17.9M   19.8M     $16.7   10.3%     3  10-28..10-31  opus-5,sonnet-5 +1
    Fix the webapp login  91ab44ee    131    250k     89k    1.3M   16.8M   18.5M     $16.3   10.0%     2  10-28..10-30  opus-5,sonnet-5
    e5d1f0a7                           22     40k     12k    150k    1.1M    1.3M     $0.40    0.2%     1  10-31         haiku-4-5
personal                              318    660k    231k    3.5M   42.9M   47.3M     $44.3   27.3%     4  10-27..11-01  opus-5,sonnet-5
  ~/git/personal/tagents              215    470k    162k    2.6M   32.2M   35.4M     $38.8   23.9%     2  10-31..11-01  opus-5
    tagents-core  d8c3b615            215    470k    162k    2.6M   32.2M   35.4M     $38.8   23.9%     2  10-31..11-01  opus-5
  ~/git/personal/site                 103    190k     69k    920k   10.7M   11.9M     $5.51    3.4%     2  10-27..10-28  sonnet-5
    site-redesign  0a6f7e92           103    190k     69k    920k   10.7M   11.9M     $5.51    3.4%     2  10-27..10-28  sonnet-5
? unplaced                             18     30k      9k     90k    700k    829k     $0.26    0.2%     1  11-01         haiku-4-5
  ~/scratch/probe                      18     30k      9k     90k    700k    829k     $0.26    0.2%     1  11-01         haiku-4-5
    Probe title  7b2c5d33              18     30k      9k     90k    700k    829k     $0.26    0.2%     1  11-01         haiku-4-5
total                                1148    2.4M    824k   12.8M  153.8M  169.9M      $162  100.0%     6  10-27..11-01  opus-5,sonnet-5 +1

1 session belongs to no account: TU_ACCOUNT_RULES places a session by the directory it started in.
```

A session is its name in tagents, the one typed for it or else its title, then eight characters of its id. A session with no name is its eight characters. Reading a title out of a transcript writes it to the dashboard's cache (`title.tsv`) through the function the dashboard uses, so the next refresh has it.

The columns are `reqs`, `input`, `output`, `cwrite`, `cread`, `total`, `$` and `share`, then `days` and `span` when no dimension is a time, then `models` when `model` is not a dimension. The width is `COLUMNS`, else the terminal's, else 120. A table that does not fit drops columns in a fixed order (`models`, `span`, `days`, `input`, `cwrite`, `cread`, `output`, `reqs`) until its labels have 24 characters; the label, `total`, `$` and `share` stay. A label that is still too long ends in `…`, and a session keeps its eight characters. `--compact` keeps only those four columns at any width.

```text
usage  2026-10-26 .. 2026-11-01  by project

                         total         $   share
~/git/work/billing-api  102.0M      $101   62.3%
~/git/personal/tagents   35.4M     $38.8   23.9%
~/git/work/web-app       19.8M     $16.7   10.3%
~/git/personal/site      11.9M     $5.51    3.4%
~/scratch/probe           829k     $0.26    0.2%
total                   169.9M      $162  100.0%
```

| flag | what it does |
|------|--------------|
| `--since 5h\|3d\|month\|YYYY-MM-DD` | the start of the window; the default is seven days. A table by week or month, or of one session, reaches back as far as the index does unless this is given |
| `--until <epoch>\|YYYY-MM-DD` | the end of the window; a date is the end of that day |
| `--top N` | rows under each parent; the default is twelve and `0` is all, the rest summed in a `… N more` row |
| `--sort cost` | a table by time lists its rows dearest first instead of oldest first |
| `--compact` | the label, `total`, `$` and `share` only |
| `--tsv` | the deepest rows with no header, no colour and no rounding, for a script |
| `--color auto\|always\|never` | colour only on a terminal and never with `NO_COLOR` set, unless this says otherwise |

A day is cut at today's UTC offset: the rows of a day and the ends of a `--since` or `--until` date use the same offset, so a table by day begins and ends on the days the window names. Where the clocks change, a day from the other season starts an hour away from the local midnight of its time.

```text
usage  2026-10-01 .. 2026-11-01  by week > account

                reqs   input  output  cwrite   cread   total         $   share  models
wk 2026-10-05    240    520k    161k    3.1M   37.0M   40.8M     $44.5   17.0%  opus-5
  work           240    520k    161k    3.1M   37.0M   40.8M     $44.5   17.0%  opus-5
wk 2026-10-12    210    420k    140k    2.2M   26.5M   29.3M     $26.3   10.0%  opus-5,sonnet-5
  personal       130    280k     90k    1.5M   18.0M   19.9M     $22.0    8.4%  opus-5
  work            80    140k     50k    700k    8.5M    9.4M     $4.23    1.6%  sonnet-5
wk 2026-10-19    200    420k    135k    2.2M   25.5M   28.3M     $29.2   11.1%  opus-5,sonnet-5
  personal       200    420k    135k    2.2M   25.5M   28.3M     $29.2   11.1%  opus-5,sonnet-5
wk 2026-10-26   1148    2.4M    824k   12.8M  153.8M  169.9M      $162   61.9%  opus-5,sonnet-5 +1
  work           812    1.7M    584k    9.2M  110.2M  121.7M      $118   44.9%  opus-5,sonnet-5 +1
  personal       318    660k    231k    3.5M   42.9M   47.3M     $44.3   16.9%  opus-5,sonnet-5
  ? unplaced      18     30k      9k     90k    700k    829k     $0.26    0.1%  haiku-4-5
total           1798    3.8M    1.3M   20.3M  242.8M  268.2M      $262  100.0%  opus-5,sonnet-5 +1

1 session belongs to no account: TU_ACCOUNT_RULES places a session by the directory it started in.
```

A request on a model with no published rate ends the dollars of its row in `*`, under a line that says the figure is a floor. A session that no account claims is under `? unplaced`; `TU_ACCOUNT_RULES` places a session by the directory it started in.

`--tsv` is one row per deepest level, tab separated: the keys, then requests, input, output, cache write, cache read, dollars to six decimals, the unpriced requests, the first and last day and the days.

```text
work	812	1730000	584000	9210000	110200000	117.590000	0	2026-10-28	2026-11-01	5
personal	318	660000	231000	3520000	42900000	44.260000	0	2026-10-27	2026-11-01	4
?	18	30000	9000	90000	700000	0.257500	0	2026-11-01	2026-11-01	1
```

### One account, one project

`--account work` narrows a report to the sessions of an account, `--project billing` to the projects whose directory contains the text, ignoring case, as the tables show the directory (`~/git/work/billing-api`). A text that starts with a slash is also matched against the directory written out (`/Users/you/git/work/billing-api`, which is what a shell hands over for the first); any other text is looked for in the directory as the tables show it, so the user name does not match every project. `--account` may be repeated or take a comma list; `--project` may only be repeated, because a directory name can hold a comma. Both work in every report and combine. The name `?` is the sessions no account claims. An unknown account exits 2 and lists the known ones. How the names are found is on the [accounts](./accounts#account-names-in-a-terminal) page.

### One session by day

`--session` takes a name, an id or a prefix of one. On its own it prints the detail the closed-session preview shows. With `--by` it prints that session's table under a heading with its name, id, account, directory and days, and reaches back to the first day the index holds:

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

A name that matches no session exits 1. A name or prefix that matches several lists them and exits 3, and an empty value exits 2.

## Rates

Rates live in `PRICES` at the top of `tusage`, in dollars per million tokens, with cache multipliers (5m write 1.25x, 1h write 2x, read 0.1x) applied on top. They are the published rates, checked against the ledger rather than trusted; the header of `tusage` explains how to re-derive them.

A model with no published rate is **never guessed at**: its usage is excluded and the figure is marked with a trailing `?` to say it is a floor. `tusage --by` and the summary mark it with `*`. Add a rate without editing the file via `TU_PRICES`:

```sh
TU_PRICES='claude-opus-5 5 25;claude-fable-5 10 50' tagents
```

## If the totals look wrong

One updater runs at a time. The index is append-only and each updater starts from the offset it read at entry, so two running at once would append the same requests twice and silently inflate the totals (measured: 13 requests indexed as 21). `tusage` takes a lock (`agent-state/usage/.update.lock`), and a background refresh that loses it just returns.

If the totals ever look wrong, `tusage --rebuild` throws the index away and rescans.

### A transcript is indexed by session, not by path

Claude Code moves a session's files between project directories. One started in a worktree lives under the worktree's slug and reappears under the parent project's when the worktree is deleted. An index keyed by absolute path saw a new file after every move and read it again from byte 0: one live session was indexed under three slugs, and $162 of the $285 charged to it was the copies.

So `offsets.tsv` carries the session-relative key (the sid, plus the path below it for a subagent file) as a fourth field, adopts the stored offset when that key turns up somewhere new, and reads only the tail. Rows written before the key existed still work. If both copies are on disk at once only the newest is indexed, and `--update` and `--rebuild` say how many were skipped.
