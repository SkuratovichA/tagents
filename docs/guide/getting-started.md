# Getting started

tagents is a dashboard of every Claude Code session running under tmux. This page takes you from nothing to a working list: install it, which also tells Claude Code to report to it, and open it.

## What you need

- `tmux`, `fzf`, `jq` and `awk`. tagents is written for bash 3.2 on purpose, since macOS ships nothing newer.
- `git`, to fetch and update the managed copy.
- Node 22.18 or newer and `pnpm`, to build the TypeScript packages the installer builds.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/SkuratovichA/tagents/main/install.sh | sh
```

`install.sh` clones itself into `~/.local/share/tagents` when it is not there yet. Flags go through `sh -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/SkuratovichA/tagents/main/install.sh | sh -s -- --hooks-dir ~/.claude/hooks
```

Or clone it yourself and run the installer from the clone:

```sh
git clone https://github.com/SkuratovichA/tagents.git ~/.local/share/tagents
sh ~/.local/share/tagents/install.sh --hooks-dir ~/.claude/hooks
```

### What the installer puts where

`install.sh` keeps one managed copy in `~/.local/share/tagents` (set `TAGENTS_HOME` to move it): a clone detached on `origin/main`, built, and never developed in. What your machine runs are small real files that `exec` into it, not symlinks.

| where | what |
|-------|------|
| `~/.local/bin` | `tagents`, `tusage`, `tnotes`, `tagents-core` and `tagents-knowledge`; `tagents-core` runs the prebuilt Rust binary when a release exists for the version you installed, and the node CLI otherwise |
| each `--hooks-dir` | one wrapper per `hooks/*.sh` |
| `settings.json` of each Claude config directory | the state hook and the status line, added by `tagents setup` (see [Tell Claude Code about it](#tell-claude-code-about-it)) |

Give `--hooks-dir` once per Claude config directory you use; without it the installer uses `~/.claude/hooks`. A wrapper is only written over a symlink or over another wrapper. Any other file with that name is left alone, with a warning and exit status 1.

## Tell Claude Code about it

The installer does this part too: a first install ends by running `tagents setup`, which writes the registration into Claude Code's own `settings.json`, so there is nothing to paste. Without the hook there is nothing for the dashboard to show. What it adds is the file [`hooks/claude-settings.json`](https://github.com/SkuratovichA/tagents/blob/main/hooks/claude-settings.json) of the repository:

<<< @/../hooks/claude-settings.json

`@HOOKS@` stands for the folder that holds the hook scripts. When that folder is under your home folder, setup writes it as `$HOME/` and the rest of the path, for example `$HOME/.claude/hooks`, with a literal `$HOME` that the shell expands when the hook runs; otherwise it writes the absolute path.

### 1. Register the state hook

Setup adds the hook for eight events: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, `SubagentStop` and `SessionEnd`. The hook reads the event's name from the JSON Claude Code feeds it, so one command serves them all. `PreToolUse`, `PostToolUse` and `SubagentStop` are `"async": true` so they never sit in the tool-call critical path.

### 2. Register the status line

The status line is what feeds the model column: it is the only place that knows which model a session is set to. It is registered with `refreshInterval: 30`, because without it an idle session never re-renders and its cost figure goes stale exactly when you are looking at it. A status line of your own is not replaced: see [Keeping a status line of your own](#keeping-a-status-line-of-your-own).

### What setup does to your settings

- **It only appends.** An event counts as registered when a command in any of its groups names `tmux-agent-state.sh` as a whole file name, however the command is quoted or redirected and whichever folder it points at (`my-tmux-agent-state.sh` and `tmux-agent-state.sh.bak` do not count), so a registration you made by hand earlier is recognised and not duplicated. An event that is missing gets tagents' group added at the end of its list, and the list is created when there is none. A group you wrote, with a `matcher` or without, is never edited, reordered or removed, and every other key in the file stays, in its order.
- **A second run changes nothing.** When nothing is missing the file is not written at all: same bytes, same modification time, no backup.
- **A write is backed up.** Before it replaces a file, setup copies it to `settings.json.tagents-<UTC timestamp>.bak` beside it, for example `settings.json.tagents-20261029T181500Z.bak` (with a suffix if that name is taken). A file that does not exist yet is created, with no backup because there is nothing to keep.
- **A write is whole.** The new content goes to a temporary file in the same folder, with the old file's permissions, and is renamed over `settings.json`, so no reader sees a half-written file. It is written with two-space indentation, so the first write can re-indent a file you laid out differently.
- **It checks for a change made meanwhile.** Just before the rename setup compares the file with what it read. If they differ, Claude Code wrote it in the meantime: setup starts over from the new content, at most three times, and then refuses.
- **A symlink stays a symlink.** A `settings.json` that links into a dotfiles repository is followed: the real file is written and its backup sits beside it, the link stays a link, and a file that two config directories share is done once.
- **A file it cannot extend is refused.** It is left exactly as it was, the message says why, the other files are still done, and the exit status is 1. That covers a file that is not valid JSON (the message quotes the parser's error) or holds more than one JSON value, a top level that is not an object, a `hooks` that is not an object, a value for one of the eight events that is not an array, a `settings.json` that is a dangling symlink, and one that is read-only when something has to be added to it (a read-only file that already has everything is simply set up). An empty file is read as `{}`. If the installer's run of setup refuses something, the installer still installs everything else, warns, and ends with exit status 1; fix the file and run `tagents setup` yourself.

Setup prints one line per file: what it added and where the backup went, that it was already set up, or why it was refused (`~` stands for your home folder). Errors go to stderr.

### Which files it covers

By default setup covers every config directory it knows: `~/.claude`, the directory in `$CLAUDE_CONFIG_DIR` when that is set, and the `config_dir` of each [account](./accounts). In each it edits `settings.json` and nothing else (not `settings.local.json`). A default directory that does not exist is skipped with a note, which is not an error. If even `~/.claude` is missing because Claude Code has never started on this machine, start it once and run `tagents setup`.

`--config-dir DIR` replaces that default set with the directories you name, once per directory. Use it for a Claude config directory that tagents does not know, for example `tagents setup --config-dir ~/.claude-client`. A directory you name that does not exist is an error for that directory, with exit status 1, and the others are still done.

For a config directory `D`, the entries name the first of these folders that holds both `tmux-agent-state.sh` and `claude-statusline.sh`: `D/hooks`, each `--hooks-dir` given to setup (the installer passes its own list), and `~/.claude/hooks`. If none of them does, `D` is refused with a message to run `install.sh`, adding `--hooks-dir D/hooks` for a copy of its own. A config directory without a `hooks/` of its own therefore points at `~/.claude/hooks`, and that works: the hook reads the session's `CLAUDE_CONFIG_DIR` from its environment, not from where the script lives.

Setup registers only the state hook and the status line. The [notes hooks](./notes#registering-the-hooks) are opt-in, and stay yours to register.

### Keeping a status line of your own

If `statusLine` is already set to a command that is not tagents' script, setup keeps it and prints that it did, what it runs, and the command to switch. `tagents setup --statusline` replaces it with tagents' status line, after the usual backup, so your old one is in the backup file. A `statusLine` that already runs `claude-statusline.sh`, in whatever form, is left as it is. Keep in mind that the model column comes only from tagents' status line.

### Looking first, and the options

`tagents setup --check` prints what would be added to each file and writes nothing. It exits 0 when everything is in place and 1 while something is missing or a file would be refused, so a script can rely on it. A status line of your own that setup would keep counts as a choice, not as something missing.

| option | what it does |
|--------|--------------|
| `--check` | print what would be added to each file and write nothing |
| `--statusline` | replace a status line of your own with tagents' one |
| `--config-dir DIR` | do only the directories you name, once per directory, instead of the default set |
| `--hooks-dir DIR` | add a folder to look in for the hook scripts, once per folder |
| `--quiet` | print only refusals and errors |

The exit status is 0 when everything is set up, already was, or a default directory was skipped; 1 for any refusal or failure, and for `--check` with something missing; 2 for a usage error.

::: warning A config directory tagents does not know
Setup covers `~/.claude`, `$CLAUDE_CONFIG_DIR` and the `config_dir` of each [account](./accounts), and nothing else. Any other Claude config directory runs no state hook and no status line until you run `tagents setup --config-dir DIR` for it, so agents started on it never appear in the dashboard and have no model column. That reads as a tagents bug and is a configuration one.
:::

## Optional: the tmux status bar and resurrect

Two additions to `~/.tmux.conf`. Neither is required to open the dashboard.

A tally of your sessions in the status bar. The refresher keeps the option `@tagents_counts` current while a dashboard is open, and the `#()` in the branch that is not taken never runs, so this costs nothing per redraw:

```sh
set -g status-right '#{?@tagents_counts,#{@tagents_counts},#(~/.local/bin/tagents --counts)}'
```

![The tagents tally in the tmux status bar](../images/statusbar.png)

Two lines that make [resurrect](./resurrect) happen on its own, after the tmux-resurrect plugin settings:

```sh
set -g @resurrect-hook-post-save-layout '~/.local/bin/tagents --resurrect-save'
set -g @resurrect-hook-post-restore-all '~/.local/bin/tagents --resurrect --auto'
```

Run `tmux source-file ~/.tmux.conf` to pick them up.

## First run

```sh
tagents
```

That opens the interactive dashboard. Press `?` to see every key and run the one you pick; [Keys](./keys) explains how to move them.

```
tagents               interactive dashboard
tagents --timeline    who worked when over the last day, as bars
tagents --counts      compact summary, for the tmux status bar
tagents --help        the real manual, with the reason for every non-obvious decision
```

Then start a few Claude Code sessions inside tmux and watch them appear. [The dashboard](./dashboard) explains what each row says.

## Updating

```sh
tagents update
```

Running the installer again is the update, and `tagents update` does exactly that: it fetches `origin/main`, moves the managed copy there, rebuilds, and rewrites the wrappers. A build that fails puts the copy back on the commit it was on. A copy with local changes is not moved, since your work belongs in a clone of its own.

- `tagents update --check` only says whether main has moved.
- `install.sh --launchd` adds a LaunchAgent that runs the update daily at 04:17 (macOS). It remembers the `--hooks-dir` list and the `PATH` of the shell that installed, so node and pnpm are found.
- An update runs `tagents setup` again only when the new version changes what it registers (`hooks/claude-settings.json`). On every other update your `settings.json` files are left alone, so an entry you removed on purpose stays removed.
- You can run `tagents setup` yourself at any time, for example after you add an [account](./accounts). It adds what is missing, and a second run changes nothing.

## The Claude Code plugin

The same repository is also a Claude Code plugin that teaches your sessions how to use tagents. It does not replace the steps above:

```
/plugin install tagents --marketplace SkuratovichA/tagents
```

[The plugin page](./claude-code-plugin) says what it adds.

## Working on tagents itself

Clone it somewhere else (`~/git/.../tagents`) and run the suites from there; the installed copy stays on main. See [Development](../development).
