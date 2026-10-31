## Decisions to review

**Bash, not TypeScript.** `tagents setup` is a new module, `lib/tagents/setup.sh`, answered by the `tagents` script next to `update`. The profiles, the host overlay and the `CLAUDE_CONFIG_DIR` rules exist only in bash, and `jq` is already a declared dependency. Rejected: a TypeScript verb in `@tagents/core`, which would need the profile list handed over from bash, would join the backlog of what the Rust port has to reproduce, and could leak into the MCP tools.

```sh
# tagents, the bare verbs the script answers itself, ahead of the forwarding
update) shift; exec sh "${TA_LIB%/lib/tagents}/install.sh" "$@" ;;
setup)  shift; …the setup module, which is sourced with the others… ;;
*)      forward_core "$@" ;;
```

**`setup` stays out of `tagents.cli.json`.** That file is the source of the MCP tools, and a tool that rewrites Claude's settings has no business in a list a session can call. The cost is that `skills/tagents/references/cli.md` does not list it; `scripts.md`, which quotes `tagents --help`, does.

**The registration is one file, `hooks/claude-settings.json`.** It is the block the README used to show, with `@HOOKS@` where `$HOME/.claude/hooks` was. `install_hooks` only globs `hooks/*.sh` and Claude Code's plugin loader only reads `hooks/hooks.json`, so the file is inert for both. The guide includes the very same file with VitePress's `<<< @/../hooks/claude-settings.json`, so the page that explains what setup writes cannot drift from what it writes, and the README stops carrying a copy. Rejected: building the JSON inside the shell script, which would be a second copy of the block next to the first.

```json
{ "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "sh \"@HOOKS@/tmux-agent-state.sh\"" }] }] } }
```

**Entries are recognised by script name, not by the exact command.** An event is covered when any command in any of its groups names `tmux-agent-state.sh` as a whole file name: no character that can belong to a longer file name (a letter, a digit, `.`, `_`, `+` or `-`) touches it on either side, so the start or end of the command, `/`, a space, a quote, a redirection and a bracket all bound it. The files people already have use other quoting, other paths and redirections (`sh '/Users/me/.claude/hooks/tmux-agent-state.sh'`, `$HOME/.claude/hooks/tmux-agent-state.sh>/dev/null 2>&1`, `(sh ~/.claude/hooks/claude-statusline.sh)`), which an exact match would miss and then duplicate. Rejected: a substring match, which `my-tmux-agent-state.sh` and `tmux-agent-state.sh.bak` would satisfy.

```
sh "$HOME/.claude/hooks/tmux-agent-state.sh"        covered
sh '/Users/me/.claude/hooks/tmux-agent-state.sh'    covered
$HOME/.claude/hooks/tmux-agent-state.sh>/dev/null   covered: a redirection ends the name
~/bin/my-tmux-agent-state.sh                        not covered: a letter-or-dash precedes the name
tmux-agent-state.sh.bak                             not covered: a dot follows the name
```

**Setup only appends, and writes nothing when nothing is missing.** A missing event gets the template's group at the end of its list; a group the person wrote is never edited, reordered or removed, whether it has a matcher or not; every other key stays where it was. When no event is missing and the status line is in place the file is not opened for writing, so the second run changes neither the bytes nor the modification time and leaves no backup. The file belongs to the person and to Claude Code, which rewrites it too, so the safe amount of change is the smallest one.

```jsonc
// before: the person's own Stop hook and status line
{ "model": "opus",
  "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "~/bin/notify-me.sh" }] }] },
  "statusLine": { "type": "command", "command": "~/bin/my-line.sh" } }

// after tagents setup: the person's group first, the other events appended in the template's order, everything else where it was
{ "model": "opus",
  "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "~/bin/notify-me.sh" }] },
                      { "hooks": [{ "type": "command", "command": "sh \"$HOME/.claude/hooks/tmux-agent-state.sh\"" }] }],
             "SessionStart": [ … ], … },
  "statusLine": { "type": "command", "command": "~/bin/my-line.sh" } }
```

**A status line of the person's own stays, and setup says how to switch.** A status line is one slot, not a list, so adding next to a foreign one is impossible and replacing it would destroy something the person chose, where adding a hook destroys nothing. The message names what it kept and the command that switches, `tagents setup --statusline`, which replaces it after the usual backup. A `statusLine` whose command names `claude-statusline.sh` in any form is left as it is, and one that is not an object is kept too. This was judged clear from the request and the owner was not asked; see the questions below.

```
~/.claude/settings.json: added the hooks for Stop, SessionEnd; kept the status line it has (it runs: ~/bin/my-line.sh); tagents setup --statusline replaces it; the previous file is kept as ~/.claude/settings.json.tagents-20261029T103207Z.bak
```

**The write follows symlinks, backs up, replaces whole and refuses to overwrite a newer file.** The real file is found by following symlinks, so a `settings.json` that is a link to another config directory's is changed once, and stays a link; the loop in `tagents` that follows `~/.local/bin/tagents` by hand cannot be shared, because it runs before any module is loaded. The previous file is copied to `<real>.tagents-<UTC YYYYmmddTHHMMSSZ>.bak` next to the real file (a suffix on a clash), a missing file has no backup, and the new content goes through a temp file in the same directory with the old file's mode and a rename, so a reader sees the old file or the new one. Claude Code writes `settings.json` too, so just before the rename the file is compared with the bytes setup read; if they differ, setup starts over from the new content, at most three times, and then refuses the file. Rejected: writing in place, where an interrupted write leaves half a file, and a lock, which Claude Code would not take.

```sh
real=…the file after following symlinks…
cp -p "$real" "$real.tagents-$(date -u +%Y%m%dT%H%M%SZ).bak"
jq …merge… "$real" >"$tmp"        # $tmp lives in the real file's directory and has its mode
cmp -s "$real" "$bytes_read" && mv "$tmp" "$real"   # else read again; the fourth try refuses
```

**A file setup cannot merge into is refused whole and the others go on.** Invalid JSON (jq's error line is quoted) or more than one JSON value, a top level that is not an object, `hooks` that is not an object, an event of the registration that is not an array, a read-only file and a dangling symlink each leave the file untouched and make the exit code 1 at the end. An empty or whitespace-only file is read as `{}`: it holds no settings, so there is nothing to preserve and nothing to refuse. Rejected: stopping at the first bad file, which would leave the profiles after it unregistered because of a typo in one.

**The config directories are the ones tagents already knows.** `~/.claude`, `$CLAUDE_CONFIG_DIR` when set and not empty (through the same expansion the dashboard uses, which strips a trailing slash) and the `config_dir` of each profile; directories are deduplicated by resolved path and files by their real path. Only `settings.json`, never `settings.local.json`. A default directory that is not there (a profile written for another machine, which the per-machine overlay exists for) is skipped with a note and exit 0, while a directory named with `--config-dir` that is not there is an error for it, because someone who typed a path expects it to be done. `--config-dir` is repeatable and replaces the default set, so one directory can be done on its own.

**The hooks directory is chosen per config directory, and `@HOOKS@` is written portably.** For a config directory D the candidates are `D/hooks`, each `--hooks-dir` (the installer passes its own list) and `$HOME/.claude/hooks`, and the first that holds every script the template names wins; the names are read from the template, not written into the code a second time. The scripts read the session's `CLAUDE_CONFIG_DIR` from the environment and not their own location, so a profile directory with no `hooks/` of its own can name `~/.claude/hooks` and still be told apart as its own account. `@HOOKS@` becomes `$HOME/<path>` with a literal `$HOME` when the directory is under the home directory, as the README's block always had it, and the absolute path otherwise; because the path sits inside the double quotes of an `sh` command, `"`, `\`, `$` and the backtick in it are escaped. When no candidate holds the scripts the directory is refused with a message that says to run `install.sh`, with `--hooks-dir D/hooks` for a copy of its own.

```
hooks directory           @HOOKS@ becomes          command
~/.claude/hooks           $HOME/.claude/hooks      sh "$HOME/.claude/hooks/tmux-agent-state.sh"
~/.claude-work/hooks      $HOME/.claude-work/hooks sh "$HOME/.claude-work/hooks/tmux-agent-state.sh"
/opt/tagents/hooks        /opt/tagents/hooks       sh "/opt/tagents/hooks/tmux-agent-state.sh"
~/ho$ks                   $HOME/ho\$ks             sh "$HOME/ho\$ks/tmux-agent-state.sh"
```

**`--check` is a preview with an exit code.** It prints what each file would get, writes, creates and backs up nothing, and exits 1 while anything is missing or a file would be refused, and 0 when everything is in place. A status line of the person's own that setup would keep counts as in place, because it is a choice and not something missing; otherwise `--check` would fail forever for the people it exists to respect.

**The installer runs setup on a fresh install and when an update changes the registration, not on every run.** The daily launchd update runs `install.sh` too, and a run that re-added what somebody removed on purpose would make removing impossible. The condition is the file itself: `prev` and `target` are the commits the update moves between, and the installer that runs is the one of the commit it moved to (the hand-over the plugin spec already describes), so an update that brings the file, or an event it did not have, runs setup once. A failure prints a warning and the run ends with exit 1 after everything else is installed, the way a skipped wrapper does; `--check` never runs it.

```sh
# install.sh, after install_hooks and the LaunchAgent, from a function of its own so main's arguments stay whole (a sketch: the variable names are the installer's own)
if [ "$fresh" = 1 ] || { [ "$prev" != "$target" ] && ! git -C "$TAGENTS_HOME" diff --quiet "$prev" "$target" -- hooks/claude-settings.json; }; then
  "$TAGENTS_HOME/tagents" setup ${quiet:+--quiet} $hooks_dir_args || warn_and_fail_at_the_end
fi
```

**The "never used" note of `tagents --check` looks at `.claude.json` only.** It counted a `settings.json` as use, and setup creates that file in a profile directory nobody has logged into, which would silence the note exactly where it is needed. The message already says "no .claude.json in it".

```sh
# lib/tagents/accounts.sh, the profile's config_dir checks
-        elif [ ! -e "$d/.claude.json" ] && [ ! -e "$d/settings.json" ]; then
+        elif [ ! -e "$d/.claude.json" ]; then
```

**The notes hooks stay manual.** They are opt-in (`docs/guide/notes.md`), and a command that appended them to everyone's settings would turn them on for people who never asked. Setup registers the state hook and the status line, and the notes guide says so in one sentence.

**The site and the README say what setup does and show no JSON.** The README and the landing page both say that the install ends by running `tagents setup`, which only appends, and a test fails when either stops saying so. The landing page keeps its step text and loses the foldable block with the JSON and the constant that held it. The site stays without i18next, as its own design records (`openspec/changes/landing-site/design.md:13`), so the words live in `site/src/content.ts`.

## Risks

- **An update that changes the registration re-adds an event the person removed.** Setup cannot tell a removed event from one that was never registered, so the one run after such an update puts it back. `tagents setup --check` shows what would come back, and the next update leaves the file alone again.
- **Two tools write one file.** Claude Code rewrites `settings.json` while setup runs. The compare before the rename catches the common case and the three tries bound the rest; what it cannot catch is a write between the compare and the rename, which is a window of one system call.
- **A settings file that `jq` cannot parse.** Setup refuses whatever `jq` rejects and leaves the file alone with jq's message, so if Claude Code reads a file that `jq` does not, that directory stays unregistered until the file is fixed by hand. The failure is loud and costs nothing.

## Open questions for Sasha

1. Is keeping a status line of someone's own the right default? It was judged clear and not asked. The alternative is to replace it and keep the backup, which is simpler to explain and wrong for anyone who chose theirs.
2. A tagents status line registered before this change has no `refreshInterval`. Setup counts any command that names `claude-statusline.sh` as in place and does not touch its other fields; should it add the field when it is missing?
3. `--config-dir` replaces the default set instead of adding to it, so `--config-dir DIR` does exactly DIR. Is that the behaviour you want, or should there be a way to add one directory to the defaults?
4. A group of the person's own with a `matcher` that names `tmux-agent-state.sh` covers its event even though the matcher may keep it from running for every tool. Counting it avoids a duplicate entry; should a matcher-scoped group not count?
5. The daily update does not run setup, so a profile added after the install gets its entries only when you run `tagents setup`. Should `tagents --check` say so when a profile's directory has no entries?
