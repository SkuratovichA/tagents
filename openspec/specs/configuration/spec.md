# configuration Specification

## Purpose
The main tagents config file, `config.yaml`: where it lives, the YAML subset it is read with, the per-machine overlay files laid over it, the keys that other capabilities read, and `tagents --config` and `tagents --check`, which say how the file is read and what is wrong with it.
## Requirements
### Requirement: Where the config file is
The config file SHALL be `$TA_CONFIG` when that is set, else `$XDG_CONFIG_HOME/tagents/config.yaml`, else `~/.config/tagents/config.yaml`. The file is optional: without it nothing it controls happens, and every agent is started exactly as it always was (a plain `claude --dangerously-skip-permissions`, environment inherited, no dialog ever).

#### Scenario: Default location
- **WHEN** neither `TA_CONFIG` nor `XDG_CONFIG_HOME` is set
- **THEN** tagents reads `~/.config/tagents/config.yaml`

#### Scenario: Pointed elsewhere
- **WHEN** `TA_CONFIG` names a file
- **THEN** that file is read and the default location is not

### Requirement: TypeScript programs find the same directory
Programs built on `@tagents/core` SHALL look for `config.yaml` in the directory `$TAGENTS_CONFIG_DIR` when that is set and not blank, else `$XDG_CONFIG_HOME/tagents`, else `~/.config/tagents`. A missing file there means no plugins and is not an error.

#### Scenario: Directory order
- **WHEN** `TAGENTS_CONFIG_DIR` is `/x/tagents`
- **THEN** the file is `/x/tagents/config.yaml`
- **AND** with only `XDG_CONFIG_HOME=/x/cfg` the directory is `/x/cfg/tagents`

### Requirement: Printing the config as read
`tagents --config` SHALL print the effective config (the file with the per-machine overlay laid over it) as one `path<TAB>value` line per leaf, in file order, on stdout, and exit 0. Mapping keys are joined by dots and sequence items are numbered from 0, so a rule's directory is `claude.rules.0.dir`. A key with nothing under it prints with an empty value. Warnings about lines the parser refused go to stderr, never into the data.

#### Scenario: The shipped example
- **WHEN** `tagents --config` runs on `config.example.yaml`
- **THEN** it prints leaves such as `claude.args<TAB>--dangerously-skip-permissions`, `claude.profiles.work<TAB>` (empty) and `claude.rules.0.profile<TAB>personal`

#### Scenario: Exit code with problems
- **WHEN** the file has a profile pointing at a directory that does not exist
- **THEN** `tagents --config` still prints the leaves on stdout and exits 0

### Requirement: No usable file
When the config file is missing, unreadable, or a directory, `tagents --config` SHALL print nothing on stdout, say `tagents: no config at <path>` on stderr and exit 1, without leaking a raw I/O error. `tagents --check` SHALL print `tagents: no config at <path> — nothing to check` on stderr and exit 0, because no file is the deliberate way to switch the feature off.

#### Scenario: Missing file
- **WHEN** `TA_CONFIG` names a file that does not exist
- **THEN** `--config` exits 1 and `--check` exits 0

#### Scenario: A directory
- **WHEN** `TA_CONFIG` names a directory
- **THEN** `--config` exits 1 with no output on stdout and no `i/o error` on stderr

### Requirement: The YAML subset
The file SHALL be read as a deliberate subset of YAML: mappings, sequences (including a bare `-` whose keys follow on the next lines), `#` comments, and plain, single-quoted and double-quoted scalars, at any consistent indentation. In a double-quoted scalar `\"` and `\\` are unescaped; a single-quoted one is literal. A CRLF file reads as its LF twin.

#### Scenario: A word-initial rule
- **WHEN** a `#` follows a space outside quotes
- **THEN** it starts a comment, while a `#` inside quotes or in the middle of a word such as `http://x#y` does not
- **AND** a quote opens a scalar only at the start of a word

#### Scenario: Quotes and comments
- **WHEN** a file has `QUOTED: "it is # not a comment"` and `ANTHROPIC_BASE_URL: https://proxy.example.com#frag`
- **THEN** the values are `it is # not a comment` and `https://proxy.example.com#frag`

#### Scenario: Lists and indentation
- **WHEN** `claude.args` is a list of three items indented four spaces
- **THEN** they are `claude.args.0`, `claude.args.1` and `claude.args.2`

#### Scenario: Apostrophe in a plain value
- **WHEN** a line is `odd: don't   # this goes`
- **THEN** the value is `don't` and the comment is gone

#### Scenario: CRLF
- **WHEN** the file uses CRLF line endings
- **THEN** it flattens to the same leaves as the LF file

### Requirement: Refused syntax costs only its line
Tab indentation, flow style (`{}` or `[]` as a value), block scalars (`|` or `>`), anchors and aliases (`&`, `*`), a line that is not `key: value`, a sequence item where none is expected, and a key where a sequence item is expected SHALL be refused. Each refusal SHALL be written to stderr as `tagents: config: <file>:<line>: <why>` and the rest of the file SHALL still be read.

#### Scenario: Tab-indented line
- **WHEN** line 3 of the file is indented with a tab
- **THEN** stderr says `tabs.yaml:3` and `tab indentation is not supported`
- **AND** the other lines still flatten

#### Scenario: Flow style
- **WHEN** a line says `rules: [a, b]`
- **THEN** it is refused with `flow style is not supported`

### Requirement: The per-machine overlay
`config.<host>.yaml` beside the config file (the file's name with `.yaml` replaced by `.<host>.yaml`) SHALL be laid over the base file, where `<host>` is the short hostname (`hostname -s`) or `TA_HOST` when that is set. Every subtree of two path segments that the overlay mentions (`claude.profiles`, `claude.rules`, `notes.send`, …) SHALL replace the base's subtree wholesale, never merged; everything else is inherited.

#### Scenario: Replaced, not merged
- **WHEN** the base defines profiles `personal` and `work`, and `config.mbp.yaml` defines profiles `sam` and `client` and one rule
- **THEN** on host `mbp` the effective config has profiles `sam` and `client` only, and the overlay's one rule only
- **AND** `claude.args`, `notes.send` and `usage.*` are inherited from the base

#### Scenario: Refusals in the overlay
- **WHEN** the overlay has a line the parser refuses
- **THEN** it is reported like a refusal in the base file

#### Scenario: Another machine
- **WHEN** the host is `other` and there is no `config.other.yaml`
- **THEN** the effective config is the base alone

#### Scenario: A base profile is unknown here
- **WHEN** the overlay replaced the profiles and `tagents --agent-cmd personal new` names a base-only profile
- **THEN** the command fails with exit 1

### Requirement: Keys the file carries
The file SHALL carry these top-level sections, each read by the capability named: `claude` (args, profiles, rules, default; `accounts`), `usage` (watch, monthly_limit_usd, safety_margin_pct, workdays, meter; `usage-accounting`), `notes` (send; `notes-workspace`), `resurrect` (auto, every, notes; `resurrect`), `keys` (`dashboard-keys`) and `plugins` (`plugin-system`). A key this version does not read SHALL be ignored.

#### Scenario: Unknown key
- **WHEN** the file has a section `something_newer` with a nested key that this version does not read
- **THEN** `tagents --check` has nothing to say about it and the leaves still print in `--config`

#### Scenario: A key a version dropped
- **WHEN** the file still sets `dashboard.layout`, a key an earlier version read
- **THEN** `tagents --check` has nothing to say about it and `tagents --config` prints the leaf `dashboard.layout`

### Requirement: Checking the config
`tagents --check` SHALL print one line per problem on stdout, each in the shape `<file>: <key>: <what is wrong> — <what to do>`, and exit 1 while any problem exists. A good config SHALL print nothing and exit 0. A line the parser refused SHALL appear as `<file>:<line>: <why>` without a key. Each problem is in one list that `--check`, the dashboard header and the status bar share, so the count they show is the whole truth.

#### Scenario: A good config
- **WHEN** every profile directory exists and has been used
- **THEN** `tagents --check` prints nothing and exits 0

#### Scenario: One problem
- **WHEN** a profile's `config_dir` does not exist
- **THEN** the output is one line naming the file, the key `claude.profiles.personal.config_dir` and `does not exist on this machine — an agent on it starts logged out`
- **AND** the exit code is 1

### Requirement: The accounts are checked first
`--check` SHALL list the problems with profiles and rules before the problems with plain values, because a login that is not there is the one worth reading first. What counts as a problem there is the `accounts` capability's.

#### Scenario: Order
- **WHEN** both a profile directory and `usage.workdays` are wrong
- **THEN** the profile's line comes before the value's line

### Requirement: Values that cannot be what they claim
`--check` SHALL report a `usage.monthly_limit_usd` or `usage.safety_margin_pct` that is not a number (digits with at most one dot), a `usage.safety_margin_pct` over 100, and a `usage.workdays` or `resurrect.auto` that is not one of `true`, `false`, `yes`, `no`, `on`, `off`, `0`, `1` (read as true). It SHALL also report a `notes.send` that is not `reference`, `paste` or `submit` (tnotes uses `reference`).

#### Scenario: Several bad values
- **WHEN** `monthly_limit_usd: 850 dollars`, `safety_margin_pct: 150`, `workdays: False` and `notes.send: mail` are set
- **THEN** each is reported on its own line, for example `usage.workdays: "False" is not true or false — read as true`

#### Scenario: Values of the resurrect section
- **WHEN** `resurrect.every` is `soon`, `resurrect.notes` is `maybe` and `resurrect.auto` is `sometimes`
- **THEN** `--check` names `resurrect.every: "soon" is not a number of seconds`, `resurrect.notes: "maybe" is not one of reopen, off` and `resurrect.auto: "sometimes" is not true or false`

### Requirement: Resurrect values that cannot be read
`--check` SHALL report a `resurrect.every` that is not a whole number of seconds, and a `resurrect.notes` that is not `reopen` or `off` (read as `reopen`).

#### Scenario: Bad values
- **WHEN** `resurrect.every` is `5m` and `resurrect.notes` is `maybe`
- **THEN** each has its own line, `resurrect.every: "5m" is not a number of seconds` and `resurrect.notes: "maybe" is not one of reopen, off — read as reopen`

### Requirement: Key bindings in the same list
The notes that the key table makes about `keys:` (a name fzf does not know, a key already bound) SHALL appear in the same `--check` list, as `<file>: keys.<action>: <note>`.

#### Scenario: Unknown key name
- **WHEN** `keys.new` is `ctrl-1`
- **THEN** `--check` reports `keys.new: 'ctrl-1' is not a key fzf knows`

### Requirement: A problem names the file it is in
The file in a problem line SHALL be the overlay for a key in a subtree the overlay replaced, and the base file for a key it inherited. A path under the home directory SHALL be written with `~`.

#### Scenario: Two files
- **WHEN** the overlay has a bad profile directory and the base has a bad `notes.send`
- **THEN** one line starts with `config.mbp.yaml: claude.profiles.client.config_dir` and another with the base file and `notes.send`
- **AND** on another host only the base's line is listed

### Requirement: What is not a problem
`--check` SHALL NOT report an unknown key, a rule about a directory that is not cloned on this machine, or an absent config file.

#### Scenario: Rule for a missing checkout
- **WHEN** a rule's `dir` does not exist on this machine
- **THEN** `--check` does not mention it

### Requirement: The problem count on screen
While there are problems the dashboard header SHALL carry `config: 1 problem (tagents --check)` or `config: N problems (tagents --check)`, the status bar SHALL show `cfg!N`, and the dashboard SHALL show a one-time tmux message with the same summary when it starts. A good config shows nothing anywhere.

#### Scenario: Header
- **WHEN** the config has two problems
- **THEN** the dashboard header carries `config: 2 problems (tagents --check)`

### Requirement: The status bar remembers the verdict
The status bar SHALL NOT re-check the config on every redraw. It SHALL remember the count with its time and the config path in `.cfg-check` in the state directory, and reuse it for up to 60 seconds (`TA_CFG_CHECK_EVERY`) unless any `config*.yaml` in the config directory is newer than the stamp, or the stamp names a different config. With no config file the count is 0 and the stamp is removed.

#### Scenario: Config edited
- **WHEN** the config file is fixed after a count was remembered
- **THEN** the next redraw checks again and the marker clears

#### Scenario: Config deleted
- **WHEN** the config file is removed
- **THEN** the status bar shows no marker and the stamp is gone

### Requirement: Asking which account
Starting an agent SHALL open a small picker over the profiles when a rule says `profile: ask`, and when no rule matches and `claude.default` is `ask` or unset. The key bound to `pick` (`ctrl-p` by default) SHALL always open it, ignoring the rules entirely. A profile name as the default settles it silently. The picker lists each profile with its config directory, or `default (~/.claude)` when it has none, and `esc` cancels.

#### Scenario: Rules ignored by hand
- **WHEN** a rule maps a personal repository to `personal` and `ctrl-p` is pressed on a row there
- **THEN** the picker opens over all profiles and the chosen one is used

#### Scenario: Silent default
- **WHEN** no rule matches and `claude.default` is `work`
- **THEN** the agent starts on `work` with no dialog

#### Scenario: No profiles
- **WHEN** the config has no profiles and the pick key is pressed
- **THEN** a tmux message says `tagents: no claude profiles in <config>` and nothing starts

### Requirement: Resuming never asks the rules
A resumed conversation SHALL run on the account recorded for it, never on the rules; the `accounts` capability states what is recorded and what happens to a record from before the account was written down.

#### Scenario: Resume on another login's repository
- **WHEN** a closed session ran on `work` in a directory a rule maps to `personal`
- **THEN** resuming it uses `work`
