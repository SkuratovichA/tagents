# lib/tagents — what the dashboard is made of

`tagents` at the root of the checkout is the entry point and nothing else: the
manual it prints for `--help`, `SELF`, the lookup that finds this directory,
`forward_core`, and the `case` that maps a flag to a function. It is
552 lines, 385 of them the manual. Everything the dashboard does is
here, one file per part, sourced in the order of the table before the dispatch
runs.

Nothing in these files runs when it is sourced. They define functions and set
their own constants, so the order is reading order rather than a dependency
graph — with one exception: `core.sh` comes first, because the constants in the
others are built on `STATE_DIR` and `TAB`.

| file | lines | what is in it |
|---|---:|---|
| `core.sh` | 208 | constants, and the plumbing every dialog is built on |
| `config.sh` | 632 | config.yaml, flattened — and what is wrong with it |
| `accounts.sh` | 361 | which Claude login an agent runs on, and whether it is there |
| `usage.sh` | 324 | the monthly limit, on screen |
| `state.sh` | 447 | the raw data every view reads |
| `names.sh` | 404 | what an agent is called, and the window it names |
| `columns.sh` | 135 | which columns are on screen |
| `list.sh` | 1004 | the rows — and the tally the status bar shows |
| `timeline.sh` | 166 | which agent worked when |
| `preview.sh` | 205 | a row, up close |
| `actions.sh` | 240 | what a key actually does |
| `refresh.sh` | 671 | keeping a list current |
| `sidebar.sh` | 147 | which pane is the dashboard right now |
| `cockpit.sh` | 375 | the dashboard as a session of its own, the viewport beside the list |
| `follow.sh` | 97 | the list cursor following the viewport, and the hooks that do it |
| `migrate.sh` | 88 | the one pass that sent the previous version's seats home |
| `rows.sh` | 127 | what a key does to a row: select, go to, join, break out, kill |
| `closed.sh` | 258 | the sessions that stopped running |
| `resurrect.sh` | 362 | every chat back where it was after a reboot |
| `launch.sh` | 226 | starting an agent |
| `keys.sh` | 278 | every key, and where it comes from |
| `dash.sh` | 264 | the dashboard itself |

## How it fits together

**Where the facts come from.** The Claude Code hook
(`hooks/tmux-agent-state.sh`) writes one record per pane into `$STATE_DIR`
(`<pane>.tsv`, `s-<session id>.tsv` for a headless `claude -p` that has no pane
at all, or the same key with two fields more for a CHILD — a `claude -p` an
agent started from its own Bash tool, which names the agent it belongs to), appends start/turn/end lines to `history.tsv`, and keeps the
per-subagent records under `sub/`. `labels.tsv` beside them is the dashboard's
own: the names you type on ctrl-r, keyed by session id so they survive
moving and resuming. `collect()` in `state.sh` is the one pass that joins those
files with the live world — `tmux list-panes`, a `ps` ancestry walk that proves
a Claude is really running in a pane, the transcript's first cwd for the
session's true origin, `tusage` rows for money — and emits one tagged line
stream.

**What reads it.** `list()` in `list.sh` is the only consumer of that stream:
two awk stages that fit the columns to the pane width, format each row, group by tmux session and draw a dimmed row for each window without a chat. `counts()` for the tmux status bar is the same `list()` plus the usage figures.
`timeline.sh`, `preview.sh` and the pickers are separate readers of the same
state directory.

**Who runs what.** More processes are involved than one file suggests, and each
re-enters the program through `$SELF`:

1. the fzf dashboard (`dash` in `dash.sh`), which owns the terminal;
2. a `--refresher` loop beside it (`refresh.sh`), which sleeps on the tmux
   channel `tagents-ev` and, on each wake, reposts a reload into fzf's `--listen`
   port only if something the list draws moved, and at most once per
   `TA_REFRESH_MIN` seconds (2). Its housekeeping — usage, window
   names, notes, the `[42]` and `[43]` hooks — is the slow pass: the first wake
   after `TA_REFRESH_SLOW` seconds (10) since the last, and always at the idle timeout
   `TA_REFRESH_IDLE` (60 s). It exits with its fzf (`TA_LIST_PID` is fzf's pid), or
   after five failed posts;
3. one short-lived child per keypress: fzf's `execute-silent($SELF --act …)`;
4. popups (`tmux display-popup -E "$SELF --ask-…"`), which are independent
   terminals because a blocking child under fzf's alternate screen wedges it;
5. tmux hooks: the hooks `install_event_hooks` puts at array index 42 ring the channel `tagents-ev`, and the follow hooks at index 43 run `--follow`; the status bar prints `@tagents_counts` and fires `--counts` only when that option is not set.

That is why `SELF` appears some fifty times, and why it stays the path the
program was INVOKED by rather than the real file behind the symlink: those
bindings have to name something runnable, and `${SELF%/*}` is also how `tnotes`
and a checkout's `packages/core` are found. The modules are looked up
separately, by following the symlink to the real file.

**The tmux half.** Six files: `cockpit.sh` is the dashboard, the session `tagents` with the list on the left and the viewport on the right, `sidebar.sh` answers "which pane is the list, right now" (markers are only ever a fallback for a live pid), `follow.sh` keeps the list's cursor on the window the viewport shows and owns the follow hooks, `rows.sh` is what a key does to a row (select, go to, join, break out, kill), `migrate.sh` is the one pass that sent the previous version's seats home, and `refresh.sh` is everything that reacts to time or tmux.

**The channels.** Nothing in here polls. `tagents-ev` wakes the refresher; `tmux wait-for -S` rings, and wakes every waiter. Three things ring: the agent-state hook (the count and the signal are the first commands of the `tmux` call that sets `@agent`; an event with no pane rings the default server with one `tmux` program of its own), the tmux hooks at index 42 (`EV_EVENTS` in `refresh.sh`; tmux 3.7 has no `after-swap-pane` and its kin, so `window-layout-changed` stands in for them), and tagents' own writers through `signal_ev` in `core.sh`, which the sidebar's move, a join and a break call themselves. Two things to know before touching it. Two signals with no waiter cancel each other, so nothing may rely on being back in a wait in time; and for that reason every ring is also a count: `tagents-ev` adds one to the global option `@tagents_evgen` (`EV_BUMP`) before it signals. The refresher reads `@tagents_evgen` in the `list-panes` of its snapshot (as a line apart, which the snapshot compared by the passes leaves out) and waits with `tmux if-shell -F` on "the count is still the one I saw", which the server evaluates and waits on as one step, so a ring between two waits has moved the number and the wait does not happen. The refresher has one waiter outstanding at most, a background `tmux if-shell` per wait that writes its exit status into a FIFO the loop reads with a timeout. The agent-state hook is POSIX sh and carries a copy of `EV_BUMP`; `tests/refresh.sh` pins it to core.sh's.

**What the status bar prints.** The refresher keeps the global option
`@tagents_counts` and unsets it when the last refresher ends, so the fragment

    #{?@tagents_counts,#{@tagents_counts},#(~/.local/bin/tagents --counts)}

costs nothing while a dashboard is open (the `#()` in the branch not taken never
runs) and computes the counts itself otherwise.

## Working on it

- bash 3.2: no associative arrays, no `mapfile`, no `${var,,}`. macOS ships
  nothing newer and this has to run there.
- Add a module by creating the file and adding its name to the list in
  `tagents`. `tests/modules.sh` fails if a file is not sourced, if a name has no
  file, if a function is defined twice, or if a module prints or runs anything
  when sourced.
- `tagents --help` is still the manual, and it is printed out of the entry, so a
  new entry point belongs in that header as well as in the dispatch.
- After a change that is meant to move code without changing it, the cheap proof
  is bash's own view: source the definitions before and after and diff
  `declare -f` — identical output means identical function bodies.
