## Why

`tusage` answers "where did my limit go", but a person with several Claude accounts cannot read the answer off the terminal.

- Only `--daily` splits by account, and it prints dollars as bare tab-separated rows for a chart.
- `--by` tables are in cost units with no dollars and no split of the token kinds into input, output, cache write and cache read, so a figure cannot be tied to a bill.
- Sessions print as ids, although the person has named most of them in tagents and Claude Code titles the rest.
- There is no per-day view of one session, no week or month grouping, no way to nest "account, then project, then session" and see which branch holds the money, and `--since` takes only durations.

`ccusage` shows what a readable report looks like: dated rows, a models column, token kinds, a dollar column, a per-model breakdown and a compact table for a narrow terminal. The same reports are missing from `tusage`, which has the data and the price table already.

## What Changes

- `--by` takes up to three dimensions (`account`, `project`, `session`, `day`, `week`, `month`, `hour`, `agent`, `model`, `workflow`) and prints them as an indented tree with subtotals, shares and dollars, sorted by dollars, with input, output, cache write, cache read and total tokens, days and span, and the models of each row.
- `--breakdown` adds a row per model under the deepest rows, `--top` and `--sort cost` shape long tables, `--compact` and the terminal width choose the columns, and colour appears only on a terminal that wants it (`--color` overrides).
- `--account` (repeatable) and `--project` narrow `--by`, the summary, `--sessions`, `--daily`, `--burn` and `--json`. A session no account claims is shown as `? unplaced`.
- `--since` and `--until` accept `YYYY-MM-DD`.
- Without `TU_ACCOUNTS`, accounts are named as the tagents config names them, so a hand-typed `tusage` and the dashboard agree. With no config, or a config that names no accounts, the discovery of `default` and each `~/.claude-*` stays, and `TU_ACCOUNTS` set by hand wins.
- Sessions are shown by the name typed in tagents, else the transcript's title, else the short id, with the short id always printed beside a name. `--session` accepts a name, and an ambiguous name or prefix lists its candidates and exits 3.
- `--session <x> --by day[,model]` prints one session's days.
- `--tsv` prints the breakdown for machines. `--sessions`, `--session <id>`, `--daily`, `--burn` and `--json` keep their bytes.
- The summary gains dollars beside its three windows, a by-account block and named heaviest sessions.
- `docs/guide/cost.md`, the `tusage` header (which is `--help`) and `CHANGELOG.md` describe the reports.

## Impact

- Specs: `usage-accounting` gets four MODIFIED requirements (the breakdown reports, the summary, one session in detail, the five-hour burn) and twenty-one ADDED ones. `usage-display` does not change: the dashboard calls `--sessions`, `--daily`, `--burn` and `--session <id>`, none of which changes its output or gets slower.
- Code: `tusage` (reports, option parsing, the shared awk blocks, a lookup of `lib/tagents/`, whose names and accounts modules it sources and calls). No change to `lib/tagents/*.sh`, `tagents`, the Rust core or the Node packages.
- Generated files: the `tusage` header is printed into `skills/tagents/references/scripts.md` by `pnpm plugin:gen`, so the regenerated diff is committed with it.
- Tests: `tests/tusage.sh` gains the new behaviour on fixtures. `tests/ui.sh`, `tests/usage.sh` and `tests/modules.sh` stay unchanged and green.
- Dependencies: none. The script stays bash 3.2 and awk with `jq`, which it already needs.
