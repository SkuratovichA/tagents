# Security policy

## Supported versions

The latest release of `tagents-core` and the `main` branch are supported. A fix lands on `main` first and reaches the next release; older releases do not get backports.

## Reporting a vulnerability

Report it privately through GitHub: [open a private security advisory](https://github.com/SkuratovichA/tagents/security/advisories/new). Do not open a public issue or a pull request for a vulnerability, and do not post details anywhere public before a fix exists.

Say what you found, which version or commit it affects, and the steps that reproduce it. A proof of concept helps; a working exploit against anybody's real machine or account is not needed and not wanted.

This policy makes no promise about how fast a report is answered or when a fix is disclosed.

## What is in scope

- The token that the Telegram plugin (`packages/telegram`) holds: how it is stored, logged, passed to other programs or sent anywhere.
- The headless runner, which starts Claude Code sessions on your behalf: anything that lets input from outside start a session, choose its arguments or its working directory, or read its output.
- `install.sh`, which downloads a prebuilt `tagents-core` and checks its SHA-256 sum before it uses it: a way to make it run an archive that was not checked, or to write outside the install directories.
- The MCP servers (`tagents-core mcp` and `packages/mcp`, `packages/knowledge`): a tool call that does more than its contract says.
- `tagents setup`, which writes to `~/.claude/settings.json`: anything that changes or loses settings it should leave alone.
- The hooks (`hooks/`), which Claude Code runs with what a session sends them and which write tagents' state directory: anything in that input that makes a hook write outside the state directory or run a command.

## What is out of scope

Problems in tmux, fzf, Claude Code, Node or another program tagents runs, which belong to their own projects; and the behaviour of a machine where an attacker already has your user account.
