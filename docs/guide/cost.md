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

## Rates

Rates live in `PRICES` at the top of `tusage`, in dollars per million tokens, with cache multipliers (5m write 1.25x, 1h write 2x, read 0.1x) applied on top. They are the published rates, checked against the ledger rather than trusted; the header of `tusage` explains how to re-derive them.

A model with no published rate is **never guessed at**: its usage is excluded and the figure is marked with a trailing `?` to say it is a floor. Add a rate without editing the file via `TU_PRICES`:

```sh
TU_PRICES='claude-opus-5 5 25;claude-fable-5 10 50' tagents
```

## If the totals look wrong

One updater runs at a time. The index is append-only and each updater starts from the offset it read at entry, so two running at once would append the same requests twice and silently inflate the totals (measured: 13 requests indexed as 21). `tusage` takes a lock (`agent-state/usage/.update.lock`), and a background refresh that loses it just returns.

If the totals ever look wrong, `tusage --rebuild` throws the index away and rescans.

### A transcript is indexed by session, not by path

Claude Code moves a session's files between project directories. One started in a worktree lives under the worktree's slug and reappears under the parent project's when the worktree is deleted. An index keyed by absolute path saw a new file after every move and read it again from byte 0: one live session was indexed under three slugs, and $162 of the $285 charged to it was the copies.

So `offsets.tsv` carries the session-relative key (the sid, plus the path below it for a subagent file) as a fourth field, adopts the stored offset when that key turns up somewhere new, and reads only the tail. Rows written before the key existed still work. If both copies are on disk at once only the newest is indexed, and `--update` and `--rebuild` say how many were skipped.
