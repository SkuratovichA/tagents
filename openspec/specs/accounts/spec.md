# accounts Specification

## Purpose
Which Claude login each agent runs on. An account is a Claude Code config directory, and a whole login rather than a preference; the config names accounts as profiles, picks one for a new agent by rules, and resumes a recorded conversation on the login it actually ran on.

## Requirements

### Requirement: A profile is a login
A profile SHALL be a named entry under `claude.profiles` in the config. Its `config_dir` names the Claude Code config directory of its login; a profile with no `config_dir` key is the default account, for which `CLAUDE_CONFIG_DIR` is unset. Unset, empty and `~/.claude` written out are three different things: Claude derives its keychain item from the literal path, so a set `CLAUDE_CONFIG_DIR` is a different login from an unset one even at the default location.

#### Scenario: Default account
- **WHEN** a profile `work` has no `config_dir`
- **THEN** an agent started on it has `CLAUDE_CONFIG_DIR` unset

#### Scenario: Two directories, two logins
- **WHEN** profiles point at `~/.claude-personal` and at no directory
- **THEN** they are two independent logins that never evict each other

### Requirement: Profile keys
A profile MAY carry `config_dir`, `command` (the binary or wrapper to run, default `claude`), `args` (replaces `claude.args` for this profile), `env` (a map of extra environment variables) and `badge` (the one or two characters the account column shows for it, default the first character of the profile name, so `personal` and `work` show `p` and `w`). A profile SHALL NOT be named `ask`, the word that opens the dialog.

#### Scenario: Badge default
- **WHEN** profiles `personal` and `work` have no `badge`
- **THEN** their badges are `p` and `w`

#### Scenario: Badge set
- **WHEN** a profile sets `badge: pw`
- **THEN** the account column shows `pw` for it

### Requirement: Tilde is expanded textually
A leading `~` or `~/` in a `config_dir` SHALL be expanded to `$HOME` textually, never through the filesystem, and trailing slashes SHALL be dropped. A symlink is not resolved, because the login is keyed by the literal string.

#### Scenario: Expansion
- **WHEN** `config_dir` is `~/.claude-personal`
- **THEN** the launch sets `CLAUDE_CONFIG_DIR` to `<home>/.claude-personal`

### Requirement: The launch command
A launch on a profile SHALL run the string `env -u CLAUDE_CONFIG_DIR [CLAUDE_CONFIG_DIR='<dir>'] [<VAR>='<value>' …] <command> <args>`, with `--resume <session id>` appended to the arguments for a resume. `env -u CLAUDE_CONFIG_DIR` comes first unconditionally, so an inherited value never leaks in, and the same string works when typed into a shell. `tagents --agent-cmd <profile> new|resume [sid]` prints exactly this string.

#### Scenario: Profile with a config directory
- **WHEN** `tagents --agent-cmd personal new` runs for a profile with `config_dir: ~/.claude-personal`
- **THEN** it prints `env -u CLAUDE_CONFIG_DIR CLAUDE_CONFIG_DIR='<home>/.claude-personal' claude --dangerously-skip-permissions`

#### Scenario: Default account
- **WHEN** the profile has no `config_dir`
- **THEN** the string is `env -u CLAUDE_CONFIG_DIR claude --dangerously-skip-permissions` and assigns no `CLAUDE_CONFIG_DIR`

#### Scenario: Resume
- **WHEN** `tagents --agent-cmd personal resume abc-123` runs
- **THEN** the string ends with `--resume abc-123`

#### Scenario: Apostrophes
- **WHEN** a `config_dir` or an `env` value contains an apostrophe
- **THEN** every value in the string is single-quoted and the apostrophe is escaped inside it

### Requirement: Arguments, command and environment
The arguments of a launch SHALL be the profile's `args`, else `claude.args`, else `--dangerously-skip-permissions`. A scalar is inserted verbatim as the user's own shell words; a list has each item single-quoted, which is how an argument containing a space gets through. The profile's `command` replaces `claude`. Each `env` entry is placed before the command as `NAME='value'`.

#### Scenario: Wrapper with list and env
- **WHEN** a profile sets `command: /opt/bin/claude-wrap`, a list of args `--model`, `opus`, `--append-system-prompt`, `be brief`, and `env` with `ANTHROPIC_BASE_URL` and `GREETING: it is fine`
- **THEN** the string is `env -u CLAUDE_CONFIG_DIR ANTHROPIC_BASE_URL='https://proxy.example.com' GREETING='it is fine' /opt/bin/claude-wrap '--model' 'opus' '--append-system-prompt' 'be brief'`

#### Scenario: Scalar arguments are verbatim
- **WHEN** a profile's `args` is `--model opus`
- **THEN** the string contains `--model opus` unquoted

### Requirement: No profile means no change
With no profile (no config, or no profiles in it) a launch SHALL be exactly `claude --dangerously-skip-permissions` for a new agent and `claude --dangerously-skip-permissions --resume <sid>` for a resume, with the environment inherited and no `env` prefix.

#### Scenario: No config
- **WHEN** `TA_CONFIG` names a missing file and `tagents --agent-cmd '' new` runs
- **THEN** it prints `claude --dangerously-skip-permissions`

### Requirement: Wrappers keep the account
`TA_NEW_CMD` and `TA_RESUME_CMD` (defaults `claude --dangerously-skip-permissions` and `claude --dangerously-skip-permissions --resume`) SHALL replace the binary and its arguments but never the account prefix, so a wrapper is still started on the right login.

#### Scenario: New wrapper
- **WHEN** `TA_NEW_CMD='foo --bar'` and the profile has no config directory
- **THEN** the string is `env -u CLAUDE_CONFIG_DIR foo --bar`

#### Scenario: Resume wrapper
- **WHEN** `TA_RESUME_CMD='myclaude --resume'` and the profile has a config directory
- **THEN** the string is the prefix followed by `myclaude --resume <sid>`

### Requirement: A raw config directory as a profile
The profile name `dir:<path>` SHALL build a launch on that config directory without any configured profile, using `claude.args` or the default arguments; this is how a closed session comes back on a login that no profile claims any more. `dir:` with nothing after it is the default account stated explicitly.

#### Scenario: Raw directory
- **WHEN** `tagents --agent-cmd 'dir:/tmp/other-login' resume q` runs
- **THEN** the string sets `CLAUDE_CONFIG_DIR='/tmp/other-login'` and ends with `--resume q`

### Requirement: Unknown names are refused, never guessed
`tagents --agent-cmd` with a profile that is not configured SHALL print nothing on stdout, say `tagents: no claude profile "<name>" in <config file>` on stderr and exit 1; `ask` SHALL be refused with `tagents: "ask" is not a profile` and exit 1. A typo must not become a launch on the default login.

#### Scenario: Typo
- **WHEN** `tagents --agent-cmd nosuchprofile new` runs
- **THEN** it exits 1, prints nothing and names the profile on stderr

#### Scenario: Ask
- **WHEN** `tagents --agent-cmd ask new` runs
- **THEN** it exits 1 and prints nothing

### Requirement: Rules pick the account of a new agent
`tagents --profile-for <dir> [session]` SHALL print the profile the rules pick for a new agent, or `ask` when the config wants to be asked, and exit 1 with no output when no profiles are configured (the caller signal to launch as it always did). Rules in `claude.rules` are tried in file order and the first match wins. With both `dir` and `session` present both must match; with neither the rule is a catch-all.

#### Scenario: Both keys
- **WHEN** a rule has `dir` and `session` and only the directory matches
- **THEN** the rule does not match

#### Scenario: Directory rule
- **WHEN** a rule maps `~/git/personal` to `personal`; `dir` matches that directory and everything under it
- **THEN** that directory and a deeper one resolve to `personal`, while the parent `~/git` does not

#### Scenario: Component boundary
- **WHEN** the same rule exists
- **THEN** `~/git/personalx` is not under it

#### Scenario: Session by containment
- **WHEN** a rule has `session: work` and the tmux session is `work-2`
- **THEN** the rule matches

#### Scenario: Symlinked checkout
- **WHEN** a directory is a symlink to a directory under a rule's `dir`
- **THEN** it matches that rule, because existing directories are compared by their real path

#### Scenario: No profiles
- **WHEN** the config has no profiles, or there is no config
- **THEN** `--profile-for` prints nothing and exits 1

### Requirement: The default when no rule matches
When no rule matches, `claude.default` SHALL decide: a profile name settles it, and `ask` or an absent or empty value means `ask`. A default that names no profile falls back to `ask` with a warning on stderr. A rule with `profile: ask` makes the dialog open for everything it catches.

#### Scenario: Default settles it
- **WHEN** `claude.default` is `work` and no rule matches `~/git`
- **THEN** `--profile-for ~/git` prints `work`

#### Scenario: No default
- **WHEN** no rule matches and `claude.default` is absent
- **THEN** `--profile-for` prints `ask`

### Requirement: Rules that cannot be applied are skipped aloud
A rule that names a profile nobody configured, or names no profile at all (a `profile:` line indented one column short leaves this), SHALL be skipped with a warning on stderr: `tagents: config: rule <n> names unknown profile "<name>" — skipped` or `tagents: config: rule <n> names no profile — skipped`, and the rest of the rules still apply.

#### Scenario: Unknown profile in a rule
- **WHEN** rule 0 names `nosuch` and rule 1 maps the same directory to `work`
- **THEN** the directory resolves to `work`

### Requirement: Starting an agent from outside the list
`tagents --new [DIR] [PROFILE]` SHALL start an agent in DIR (default the current directory) on PROFILE, else on what the rules pick; `ask` opens the account dialog. A DIR that is not a directory SHALL be refused. A PROFILE that is not configured SHALL be refused before any window is created, with `tagents: no claude profile "<name>" in <config file>` and exit 1.

#### Scenario: Typo
- **WHEN** `tagents --new ~/projects/app personl` runs
- **THEN** it exits 1, creates no window and names the profile

#### Scenario: Shell startup files do not matter
- **WHEN** a rule maps the directory to `personal`
- **THEN** the agent runs on `personal` even though tmux starts it as a child of the server, which never ran the user's shell startup files

#### Scenario: Rule decides
- **WHEN** no profile is given and a rule maps the directory to `personal`
- **THEN** the agent starts on `personal`

### Requirement: Resuming uses the recorded account
A recorded session SHALL be resumed on the config directory it was recorded as running on, and the rules SHALL NOT be consulted, because a conversation resumed on another login is not there. A profile claims a recorded directory when its expanded `config_dir` equals it. When no profile claims it the resume is built on `dir:<recorded directory>`; when there are no profiles at all the resume is the plain, unchanged command.

#### Scenario: Claimed
- **WHEN** a session recorded `~/.claude-personal` and profile `personal` has that `config_dir`
- **THEN** it resumes on `personal`

#### Scenario: Not claimed any more
- **WHEN** no profile has the recorded directory
- **THEN** the session resumes on the raw directory and still lands on the login that holds it

#### Scenario: Plain resume
- **WHEN** the config has no profiles
- **THEN** the resume is `claude --dangerously-skip-permissions --resume <sid>`

#### Scenario: Two default-looking profiles
- **WHEN** two profiles have no `config_dir` and the recorded directory is empty
- **THEN** neither claims it and the resume is on `dir:` with nothing after it, the default account

### Requirement: Who claims the default account
A recorded empty directory (the default account) SHALL be claimed only by the single profile that has no `config_dir`; with two or more such profiles none claims it, since they are two names for the same login and neither is the answer.

#### Scenario: One default profile
- **WHEN** exactly one profile has no `config_dir` and a session recorded the default account
- **THEN** that profile claims it

### Requirement: A record from before the account was written down
A state record that has no account field SHALL fall back to the rules, as a new agent would: the resume runs on the profile the rules pick for the session's directory and tmux session, and asks when the rules say `ask`. An empty recorded account in a record that has the field is the default account, not an absent one.

#### Scenario: Old record and ask
- **WHEN** an old record is resumed and the rules say `ask`
- **THEN** the account dialog opens

### Requirement: The account shown for a record
For display, the account of a record SHALL be the name of the profile that claims it; otherwise `default` for the default account, else the config directory's last component without a leading dot (`~/.claude-personal` shows `claude-personal`); and nothing when the record has no account field. The display label SHALL never be used to launch anything.

#### Scenario: Unclaimed directory
- **WHEN** no profile claims `~/.claude-client`
- **THEN** the account reads `claude-client`

#### Scenario: Unrecorded
- **WHEN** a record has no account field
- **THEN** no account is shown, so it is not mistaken for the default account

### Requirement: Config directory problems
`tagents --check` SHALL report each profile whose `config_dir` is empty, does not exist on this machine, is not a directory, is `~/.claude` written out, or has never been used (no `.claude.json` in it). The last is softer: the first agent on it will ask for a login. A launch on such a profile SHALL still be built and run, because logging in once on a fresh directory is how a new login is set up.

#### Scenario: Directory missing
- **WHEN** a profile's `config_dir` does not exist
- **THEN** `--check` says `does not exist on this machine — an agent on it starts logged out` and suggests keeping this machine's profiles in `config.<hostname>.toml`
- **AND** `tagents --agent-cmd` for it still prints the launch string

#### Scenario: Explicit home default
- **WHEN** `config_dir` is `~/.claude`
- **THEN** `--check` says it is a different login from the default account and to drop the key

#### Scenario: Never used
- **WHEN** the directory exists but holds no `.claude.json`
- **THEN** `--check` says the first agent on it will ask you to log in

#### Scenario: Only a settings file
- **WHEN** the directory holds a `settings.json`, which `tagents setup` writes there, but no `.claude.json`
- **THEN** `--check` still says the first agent on it will ask you to log in

### Requirement: Profile and rule problems
`tagents --check` SHALL report a profile named `ask`, a rule that names no profile, a rule or `claude.default` or `usage.watch` that names a profile that is not in `claude.profiles` (`ask` is allowed in a rule and as the default), and rules, a default or a watch with no profiles at all, as one note `claude.profiles: none — …`.

#### Scenario: Names that are not profiles
- **WHEN** a rule names `nosuch`, another rule has no `profile:` line, `claude.default` is `gone` and `usage.watch` is `nobody`
- **THEN** each is reported, for example `claude.default: "gone" is not in claude.profiles — falls back to ask`

#### Scenario: Dead rules
- **WHEN** the config has rules and a default but no profiles
- **THEN** one note says they do nothing without a profile, not one per rule

### Requirement: A login needs its own hooks
Every `config_dir` a profile names SHALL have `settings.json` entries for the state hook and the status line, which `tagents setup` writes, naming the hooks directory the `claude-settings` capability picks for it. An agent started on a config directory without them runs no state hook and no status line, so it never appears in the dashboard and has no model column.

#### Scenario: A login without the hooks
- **WHEN** a profile's directory has no `settings.json`
- **THEN** agents started there do not appear in the dashboard until `tagents setup` has registered the hooks in that directory

#### Scenario: A profile added after the install
- **WHEN** a profile is added to the config after `install.sh` ran
- **THEN** its directory has no entries until `tagents setup` runs

#### Scenario: Hooks shared with the default login
- **WHEN** a profile's directory has no `hooks/` of its own and `tagents setup` registered entries in its `settings.json` that name `~/.claude/hooks`
- **THEN** agents started there appear in the dashboard, each with the profile's account, because the hook records the `CLAUDE_CONFIG_DIR` of the agent's own environment, not the place the script lives
