# lib/tagents — what the dashboard is made of

`tagents` at the root of the checkout is the entry point and nothing else: the
manual it prints for `--help`, `SELF`, the lookup that finds this directory,
`forward_core`, and the `case` that maps a flag to a function. It is
573 lines, 410 of them the manual. Everything the dashboard does is
here, one file per part, sourced in the order of the table before the dispatch
runs.

Nothing in these files runs when it is sourced. They define functions and set
their own constants, so the order is reading order rather than a dependency
graph — with one exception: `core.sh` comes first, because the constants in the
others are built on `STATE_DIR` and `TAB`.

| file | lines | what is in it |
|---|---:|---|
| `core.sh` | 94 | constants, and the plumbing every dialog is built on |
| `config.sh` | 572 | config.yaml, flattened — and what is wrong with it |
| `accounts.sh` | 361 | which Claude login an agent runs on, and whether it is there |
| `usage.sh` | 273 | the monthly limit, on screen |
| `state.sh` | 212 | the raw data every view reads |
| `names.sh` | 369 | what an agent is called, and the window it names |
| `columns.sh` | 123 | which columns are on screen |
| `list.sh` | 672 | the rows — and the tally the status bar shows |
| `timeline.sh` | 162 | which agent worked when |
| `preview.sh` | 176 | a row, up close |
| `actions.sh` | 254 | what a key actually does |
| `refresh.sh` | 225 | keeping a list current |
| `sidebar.sh` | 211 | which pane is the dashboard right now |
| `seats.sh` | 290 | seats: what they are and which one is current |
| `dock.sh` | 381 | docking: the pane swapped into a seat, and sent home again |
| `closed.sh` | 254 | the sessions that stopped running |
| `resurrect.sh` | 273 | every chat back where it was after a reboot |
| `launch.sh` | 293 | starting an agent |
| `keys.sh` | 285 | every key, and where it comes from |
| `dash.sh` | 251 | the dashboard itself |

## How it fits together

**Where the facts come from.** The Claude Code hook
(`hooks/tmux-agent-state.sh`) writes one record per pane into `$STATE_DIR`
(`<pane>.tsv`, or `s-<session id>.tsv` for a headless `claude -p` that has no
pane at all), appends start/turn/end lines to `history.tsv`, and keeps the
per-subagent records under `sub/`. `labels.tsv` beside them is the dashboard's
own: the names you type on ctrl-r, keyed by session id so they survive docking,
moving and resuming. `collect()` in `state.sh` is the one pass that joins those
files with the live world — `tmux list-panes`, a `ps` ancestry walk that proves
a Claude is really running in a pane, the transcript's first cwd for the
session's true origin, `tusage` rows for money — and emits one tagged line
stream.

**What reads it.** `list()` in `list.sh` is the only consumer of that stream:
two awk stages that fit the columns to the pane width, format each row, group by
launch directory and mark the docked seats. `counts()` for the tmux status bar
is the same `list()` with the seat marks off, plus the usage figures.
`timeline.sh`, `preview.sh` and the pickers are separate readers of the same
state directory.

**Who runs what.** More processes are involved than one file suggests, and each
re-enters the program through `$SELF`:

1. the fzf dashboard (`dash` in `dash.sh`), which owns the terminal;
2. a `--refresher` loop beside it (`refresh.sh`), reposting a reload into fzf's
   `--listen` port every 2 s, with housekeeping every fifth tick — usage, window
   names, seat repair, notes — and an exit after five failed posts;
3. one short-lived child per keypress: fzf's `execute-silent($SELF --act …)`;
4. popups (`tmux display-popup -E "$SELF --ask-…"`), which are independent
   terminals because a blocking child under fzf's alternate screen wedges it;
5. tmux hooks: focus events fire `--poke` and `--unpark`, the kill bindings fire
   `--undock-pane` / `--undock-window`, the status bar fires `--counts`;
6. each placeholder pane, running `$SELF --slot` for as long as it holds a seat.

That is why `SELF` appears some fifty times, and why it stays the path the
program was INVOKED by rather than the real file behind the symlink: those
bindings have to name something runnable, and `${SELF%/*}` is also how `tnotes`
and a checkout's `packages/core` are found. The modules are looked up
separately, by following the symlink to the real file.

**The tmux half.** Four ideas that used to interleave over a thousand lines now
have a file each: `sidebar.sh` answers "which pane is the list, right now"
(markers are only ever a fallback for a live pid), `seats.sh` holds that a seat
is a marked pane and never a position, `dock.sh` swaps an agent's pane into a
seat and sends it home again, and `refresh.sh` is everything that reacts to time
or focus.

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
