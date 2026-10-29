# Accounts and configuration

If you use more than one Claude login, tagents starts every agent on the right one: the one your directory or tmux session calls for. This page covers the optional config file that does it, `~/.config/tagents/config.yaml`.

It is optional and, at its core, about one thing: **which Claude account an agent is started on**. Without the file (or `$TA_CONFIG`) nothing below happens, and every agent is started exactly as it always was: a plain `claude --dangerously-skip-permissions`, environment inherited, no dialog ever.

## The bug it fixes

`tmux new-window "<command>"` runs that command through `/bin/sh` as a direct child of the **tmux server**. Your interactive shell is never involved, so `.zshrc` never runs, and `.zshrc` is where a per-directory account is usually chosen. The tmux server has no `CLAUDE_CONFIG_DIR` of its own, so every agent started from the dashboard ran on the default account whatever directory it was in, silently and for as long as nobody looked.

### What an account is

An account is a config dir, and it is a whole **login**, not a preference. Claude Code derives its keychain item from the literal path, so `~/.claude-personal` and `~/.claude` are two independent logins. Unset is a third thing again and is not the same as empty.

That is why every launch goes out as `env -u CLAUDE_CONFIG_DIR [CLAUDE_CONFIG_DIR=…] claude …`. The prefix is carried in the command string so that the identical string also works when it is typed into a shell (the resume-in-place path), and so that it steps around any `claude()` shell function that would resolve the account all over again.

## Writing the config

### The file

```yaml
claude:
  # What every agent is started with, unless a profile overrides it.
  # A string (your own shell words, verbatim) or a list (each item quoted).
  args: --dangerously-skip-permissions

  profiles:
    personal:
      config_dir: ~/.claude-personal
      # badge: p    # the row column before the agent name. Defaults to the
      #             # first character of the profile name, so personal and work
      #             # are p and w already; set it when two accounts collide.
    work:
      # config_dir omitted: CLAUDE_CONFIG_DIR is UNSET for this one. Omit it,
      # do not write ~/.claude — set and unset are different keychain items.
      # command: claude                                     # binary or wrapper
      # args: --dangerously-skip-permissions --model opus   # replaces claude.args
      # env:
      #   ANTHROPIC_BASE_URL: https://proxy.example.com

  # First match wins. `dir` matches that directory and everything under it, by
  # path component (~/git/personalx is not under ~/git/personal). `session`
  # matches when the tmux session name CONTAINS the text. Both present means
  # both must match; neither present is a catch-all.
  rules:
    - dir: ~/git/personal
      profile: personal
    - session: work
      profile: work

  # When nothing matches. `ask` (the default) opens a picker; a profile name
  # settles it silently.
  default: ask
```

The file has more sections than the one above. Each one is covered on the page that is about it, and [`config.example.yaml`](https://github.com/SkuratovichA/tagents/blob/main/config.example.yaml) shows them all with comments:

| section | what it holds | page |
|---------|---------------|------|
| `claude` | profiles, rules and the default account | this page |
| `usage` | which profile's spend is tracked, the monthly limit | [Cost](./cost) |
| `notes` | what `:q` does with the draft | [Notes workspace](./notes) |
| `resurrect` | restoring chats after a reboot | [Resurrect](./resurrect) |
| `keys` | moving a verb to another key | [Keys](./keys) |

### The parser

The parser is a deliberate YAML subset: mappings, sequences, `#` comments, and single- and double-quoted scalars. Tabs for indentation, flow style (`{}`, `[]`), block scalars (`|`, `>`) and anchors are refused with a one-line warning naming the line, and the rest of the file is still read.

## Choosing by hand

`profile: ask`, `default: ask`, or **`ctrl-p`** on any row open a small picker over the profiles. `ctrl-p` ignores the rules entirely, which is the answer to "this one agent in a personal repo has to run on the work account".

**Resuming never consults the rules.** The account a closed session comes back on is the one it actually ran on, recorded as the seventh field of its state record by `hooks/tmux-agent-state.sh`; a conversation resumed on another login is simply not there. A record written before that field existed falls back to the rules, and asks if they say `ask`.

## One config, several machines

The file is shared through dotfiles, and the one thing in it that cannot be shared is the account table. On one laptop the default login is the employer's and `~/.claude-personal` is the second; on another the default is the personal account and the second is a client's. A profile pointing at a directory that does not exist on this machine starts a **logged-out** Claude, from a picker that looked perfectly fine.

So `config.<hostname>.yaml` beside `config.yaml` is laid over it.

- Every `a.b` subtree the overlay names (`claude.profiles`, `claude.rules`, `claude.default`, `notes.send`, …) replaces the base one wholesale. The rest is inherited.
- It is wholesale rather than merged because profiles and rules are tables: a union would keep the other laptop's rows in this machine's picker, which is the exact thing being fixed.
- `tagents --config` prints the merged result.
- `TA_HOST` overrides the hostname, which is how the tests have one.

### Which name the overlay answers to

A machine answers to more than one name, so the overlay is looked for under each: `hostname -s` first, then on a Mac the LocalHostName (`scutil --get LocalHostName`).

The first is not an identity on a Mac. With HostName never set it is whatever macOS derived last, and one laptop answered `alex-MBP` for weeks and `alex-MacBook-Pro` after a reboot. Its overlay was not found, the base profiles applied without a word, and every chat on its second login was resumed logged out. Name the overlay after the LocalHostName and it is found whatever `hostname -s` says that day. `TA_HOST` is exactly one name: nothing else is tried.

### Every config dir needs the hooks

Every `config_dir` you name needs its own copy of the [Claude Code settings](./getting-started#tell-claude-code-about-it) (the `hooks/` wrappers and the `settings.json` entries) inside it. A config dir with no `settings.json` runs no state hook and no status line, so agents started on it never appear in the dashboard at all and have no model column.

## Checking it

`tagents --check` lists what is wrong with the config, one `file: key: problem — what to do` line each, and exits 1 while anything is. The dashboard header carries the count, and the status bar shows `cfg!N`.

The first thing it looks for is a profile whose `config_dir` is not on this machine, which is what a shared dotfiles config produces on every machine but the one it was written on.

```sh
tagents --config                    # the file as tagents reads it, path<TAB>value
tagents --profile-for ~/git/work    # which profile the rules pick for a directory
tagents --agent-cmd personal new    # the exact command string a launch would run
tagents --new ~/git/thing personal  # start one from outside the dashboard
tagents --window ~/git/thing 'pnpm dev'  # the same for a plain window running a command
```

`--config` is the thing to look at when a rule will not fire: it prints one leaf per line (`claude.rules.0.dir`), which is also how a rule is referred to in the warnings.
