## 1. `tagents setup`

- [x] 1.1 Add `hooks/claude-settings.json`: the block the README used to show, with `@HOOKS@` where the hooks directory goes. Proved by `tests/setup.sh` (the template section: valid JSON, the eight events with the three async ones, both script names).
- [x] 1.2 Add `lib/tagents/setup.sh` with the merge: an event is covered when a command names `tmux-agent-state.sh` as a whole path component, a missing event gets the template's group at the end of its list, the person's groups and the file's other keys stay as they were, and a file with nothing to add is not written. Proved by `tests/setup.sh` (the merge and idempotence sections, including a second run that keeps bytes and modification time).
- [x] 1.3 Handle the status line: add it when missing, leave one that names `claude-statusline.sh`, keep any other with a message that names `tagents setup --statusline`, replace it with `--statusline`. Proved by `tests/setup.sh`.
- [x] 1.4 Refuse a file that is not valid JSON or holds more than one JSON value, whose top level or `hooks` is not an object, whose registered event is not an array, that is read-only when something has to be added, or that is a dangling symlink; read an empty file as `{}`; still process the other files and exit 1. Proved by `tests/setup.sh`.
- [x] 1.5 Write through symlinks, back the previous file up as `<real>.tagents-<UTC YYYYmmddTHHMMSSZ>.bak`, replace it through a temp file that keeps the mode, and start over up to three times when the file changed under the read. Proved by `tests/setup.sh`, which also runs under `/bin/bash` 3.2.
- [x] 1.6 Cover `~/.claude`, `$CLAUDE_CONFIG_DIR` and the `config_dir` of each profile, once per directory and per real file; skip a default directory that is missing; take `--config-dir` as the whole set. Proved by `tests/setup.sh`.
- [x] 1.7 Choose the hooks directory for each config directory from `D/hooks`, the `--hooks-dir` list and `~/.claude/hooks`, write `@HOOKS@` as `$HOME/<path>` or an absolute path with the shell's special characters escaped, and refuse a directory with no scripts, naming `install.sh`. Proved by `tests/setup.sh`.
- [x] 1.8 Add `--check`, `--quiet`, the one line per file and the exit codes 0, 1 and 2. Proved by `tests/setup.sh`.
- [x] 1.9 Source the module, answer `setup` in `tagents` ahead of the forwarding, list it in the `--help` header and keep it out of `tagents.cli.json`. Proved by `tests/modules.sh` and `tests/setup.sh` (section 17), and by `pnpm plugin:check` after `pnpm plugin:gen` for `skills/tagents/references/scripts.md` and the manifest digest.

## 2. The installer

- [x] 2.1 Run `tagents setup` from `install.sh` after the hooks and the LaunchAgent, with `--quiet` and each `--hooks-dir` passed on: on a fresh install and when the update changes `hooks/claude-settings.json`, never otherwise and never under `--check`; a failure is a warning and the run ends with exit 1. Proved by `tests/install.sh`: a fresh install, an update that changes the file, an update that does not, `--check`, and a setup that fails.

## 3. Accounts

- [x] 3.1 Make the "never used" note of `tagents --check` look at `.claude.json` only. Proved by `tests/config.sh`: a profile directory holding only a `settings.json` still gets the note.

## 4. Comments and developer docs

- [x] 4.1 Bring the header comments of `hooks/tmux-agent-state.sh` and `hooks/claude-statusline.sh` to `tagents setup`, and add `tests/setup.sh` to the suites table in `docs/development.md`. Proved by `command grep -n 'settings.json' hooks/tmux-agent-state.sh hooks/claude-statusline.sh` finding no instruction to edit it by hand, and `pnpm docs:build`.

## 5. Docs and site

- [x] 5.1 Replace the manual step in the README's Install section with what `tagents setup` does: where it writes, that it only appends, the backup, the refusal of invalid JSON, a status line of your own, and `--check`. Proved by `command grep -rn 'settings.json' README.md docs/guide site/src` finding no instruction to edit it by hand, and by `pnpm test` in `site/` (`src/content.test.ts`).
- [x] 5.2 Rewrite `## Tell Claude Code about it` in `docs/guide/getting-started.md` around `tagents setup`, showing the registration with `<<< @/../hooks/claude-settings.json` and explaining `@HOOKS@`, the append-only rules, the backup, the refusals, `--statusline`, `--check` and `--config-dir`; bring `## Updating`, `docs/guide/accounts.md` and `docs/guide/notes.md` to match. Proved by `pnpm docs:build`, and `pnpm check:links` in `site/` on a build to which the documentation was copied.
- [x] 5.3 Rewrite `INSTALL.hooksIntro` in `site/src/content.ts`, remove `hooksSummary` and `SETTINGS_JSON`, drop the foldable block from `site/src/components/Home.tsx`, and pin the README and the page to saying that the install runs `tagents setup`, which only appends. Proved by `pnpm lint`, `pnpm typecheck`, `pnpm test` (`src/content.test.ts` and `src/components/Home.test.tsx`) and `pnpm build` in `site/`.

## 6. Specs

- [x] 6.1 Write the deltas in this change and edit the `site` requirement of the `landing-site` change in place. Proved by `pnpm spec:check` with no warnings.
- [ ] 6.2 At archive, bring the Purpose line of the `claude-settings` spec, which a delta cannot write, from its placeholder to a sentence that says what `tagents setup` is for.
