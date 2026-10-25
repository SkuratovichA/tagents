## Why

`tagents --timeline` is 80 columns wide on every real terminal. It asks `tput cols` inside a command substitution, so stdout is a pipe and stderr goes to `/dev/null`: when stdin is not a terminal either (a script, `< /dev/null`), tput finds no terminal on any of the three and answers terminfo's 80. The bars are squeezed and the directory column, shown from 100 columns, never appears. `COLUMNS` is not exported by an interactive shell, so nothing overrides it.

`tagents --resurrect-save` writes nothing in a new tmux server's first 300 seconds, even where no restore will ever come. The hold-off protects the empty set that a second server start would restore from, and that set only matters when tmux-resurrect's restore hook runs tagents. `resurrect.auto` defaults to on, so someone without tmux-resurrect, or without the hook line, never had the first five minutes of any server captured, and a by-hand save exited 0 and said nothing.

The `claude-code-plugin` spec has gone stale beside them: it still describes a four-step install with symlinks that `install.sh` replaced by a managed copy and wrapper files, and it lists three of the five packages.

## What Changes

- The timeline asks the controlling terminal for its width, so a pipe or a command substitution does not shrink it to 80. An exported `COLUMNS` still overrides.
- The young-server hold-off applies only while `@resurrect-hook-post-restore-all` runs `tagents --resurrect`. A by-hand `--resurrect-save` that is held off says why on stderr, when stderr is a terminal, and exits 0.
- `claude-code-plugin`: the install requirement states what `install.sh` observably does (the managed copy, the wrappers, the hooks directories, the hook and status line left manual), the dotfiles sentence that nothing supports is dropped, the hook scripts are no longer called "installed by hand", and the list of packages names `notify` and `contract`.

## Impact

- Affected specs: `dashboard-list`, `resurrect`, `claude-code-plugin`.
- Affected code: `lib/tagents/core.sh` (`tty_cols`), `lib/tagents/timeline.sh`, `lib/tagents/dash.sh`, `lib/tagents/resurrect.sh`, `tagents` (the `--resurrect-save` manual), `skills/tagents/references/scripts.md`, `tests/headless.sh`, `tests/resurrect.sh`, `LEARNING.md`.
