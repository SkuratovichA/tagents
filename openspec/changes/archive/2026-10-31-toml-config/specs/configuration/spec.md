## MODIFIED Requirements

### Requirement: Where the config file is
The config file SHALL be `$TA_CONFIG` when that is set, else `config.toml` in `$XDG_CONFIG_HOME/tagents` or `~/.config/tagents`. It SHALL be read as TOML, whatever the file is named. A `config.yaml` is not a config file and is never looked at.

#### Scenario: Default location
- **WHEN** neither `TA_CONFIG` nor `XDG_CONFIG_HOME` is set and `~/.config/tagents/config.toml` exists
- **THEN** tagents reads `~/.config/tagents/config.toml`

#### Scenario: Only a YAML file
- **WHEN** the config directory holds `config.yaml` and no `config.toml`
- **THEN** tagents has no config, and the message says `tagents: no config at <dir>/config.toml`

#### Scenario: Both files
- **WHEN** the config directory holds `config.toml` and `config.yaml`
- **THEN** tagents reads `config.toml` and says nothing about `config.yaml`

#### Scenario: Pointed elsewhere
- **WHEN** `TA_CONFIG` names a file
- **THEN** that file is read as TOML, and the default location is not

#### Scenario: The file name does not pick a reader
- **WHEN** a config file is named `config.toml`, `config.work.toml`, `config.yaml` or `config` and is pointed at with `TA_CONFIG`
- **THEN** it is read as TOML in the dashboard and in the TypeScript programs alike, and a file holding YAML is refused line by line as TOML

### Requirement: TypeScript programs find the same directory
Programs built on `@tagents/core` SHALL look for the config in the directory `$TAGENTS_CONFIG_DIR` when that is set and not blank, else `$XDG_CONFIG_HOME/tagents`, else `~/.config/tagents`, and in that directory read `config.toml`. A missing file there means no plugins and is not an error.

#### Scenario: Directory order
- **WHEN** `TAGENTS_CONFIG_DIR` is `/x/tagents`
- **THEN** the file is `/x/tagents/config.toml`
- **AND** with only `XDG_CONFIG_HOME=/x/cfg` the directory is `/x/cfg/tagents`

### Requirement: Printing the config as read
`tagents --config` SHALL print the effective config (the file with the per-machine overlay laid over it) as one `path<TAB>value` line per leaf, in file order, on stdout, and exit 0. Table and mapping keys are joined by dots and array and sequence items are numbered from 0, so a rule's directory is `claude.rules.0.dir`. A key with nothing under it prints with an empty value.

#### Scenario: The shipped example
- **WHEN** `tagents --config` runs on `config.example.toml`
- **THEN** it prints leaves such as `claude.args<TAB>--dangerously-skip-permissions`, `claude.profiles.work<TAB>` (empty) and `claude.rules.0.profile<TAB>personal`

#### Scenario: Exit code with problems
- **WHEN** the file has a profile pointing at a directory that does not exist
- **THEN** `tagents --config` still prints the leaves on stdout and exits 0

### Requirement: The per-machine overlay
`config.<host>.toml` beside the config file (the file's name with its extension replaced by `.<host>.toml`; a `config.<host>.yaml` is not an overlay) SHALL be laid over the base file, where `<host>` is the short hostname (`hostname -s`) or `TA_HOST` when that is set.

#### Scenario: Replaced, not merged
- **WHEN** the base defines profiles `personal` and `work`, and `config.mbp.toml` defines profiles `sam` and `client` and one rule
- **THEN** on host `mbp` the effective config has profiles `sam` and `client` only, and the overlay's one rule only
- **AND** `claude.args`, `notes.send` and `usage.*` are inherited from the base

#### Scenario: A YAML overlay is not one
- **WHEN** only `config.mbp.yaml` exists beside a `config.toml`
- **THEN** it is not read and the effective config is the base alone

#### Scenario: Refusals in the overlay
- **WHEN** the overlay has a line the parser refuses
- **THEN** it is reported like a refusal in the base file

#### Scenario: Another machine
- **WHEN** the host is `other` and there is no `config.other.toml`
- **THEN** the effective config is the base alone

#### Scenario: A base profile is unknown here
- **WHEN** the overlay replaced the profiles and `tagents --agent-cmd personal new` names a base-only profile
- **THEN** the command fails with exit 1

### Requirement: Keys the file carries
The file SHALL carry these top-level sections, each read by the capability named: `claude` (args, profiles, rules, default; `accounts`), `usage` (watch, monthly_limit_usd, safety_margin_pct, workdays, meter; `usage-accounting`), `notes` (send; `notes-workspace`), `resurrect` (auto, every, notes; `resurrect`), `keys` (`dashboard-keys`), `plugins` (`plugin-system`) and `knowledge` (dir; `knowledge`). A key this version does not read SHALL be ignored.

#### Scenario: Unknown key
- **WHEN** the file has a section `something_newer` with a nested key that this version does not read
- **THEN** `tagents --check` has nothing to say about it and the leaves still print in `--config`

#### Scenario: A key a version dropped
- **WHEN** the file still sets `dashboard.layout`, a key an earlier version read
- **THEN** `tagents --check` has nothing to say about it and `tagents --config` prints the leaf `dashboard.layout`

### Requirement: A problem names the file it is in
The file in a problem line SHALL be the overlay for a key in a subtree the overlay replaced, and the base file for a key it inherited. A path under the home directory SHALL be written with `~`.

#### Scenario: Two files
- **WHEN** the overlay has a bad profile directory and the base has a bad `notes.send`
- **THEN** one line starts with `config.mbp.toml: claude.profiles.client.config_dir` and another with the base file and `notes.send`
- **AND** on another host only the base's line is listed

### Requirement: The status bar remembers the verdict
The status bar SHALL NOT re-check the config on every redraw. It SHALL remember the count with its time and the config path in `.cfg-check` in the state directory, and reuse it for up to 60 seconds (`TA_CFG_CHECK_EVERY`) unless any `config*.toml` in the config directory is newer than the stamp, or the stamp names a different config. With no config file the count is 0 and the stamp is removed.

#### Scenario: Config edited
- **WHEN** the config file is fixed after a count was remembered
- **THEN** the next redraw checks again and the marker clears

#### Scenario: Config deleted
- **WHEN** the config file is removed
- **THEN** the status bar shows no marker and the stamp is gone

## ADDED Requirements

### Requirement: The config file is optional
The config file SHALL be optional: without it nothing it controls happens, and every agent is started exactly as it always was (a plain `claude --dangerously-skip-permissions`, environment inherited, no dialog ever).

#### Scenario: No config file
- **WHEN** `config.toml` does not exist (a lone `config.yaml` is not looked at)
- **THEN** `tagents --agent-cmd` starts a plain `claude --dangerously-skip-permissions` with the environment inherited, and no dialog opens

### Requirement: The config dump prints text only
Every value in the `tagents --config` output SHALL print as text: a TOML `true`, `850` and `"850"` print as `true`, `850` and `850`. Warnings about lines the parser refused SHALL go to stderr, never into the data.

#### Scenario: Types print as text
- **WHEN** the file says `workdays = true`, `monthly_limit_usd = 850` and `note = "850"`
- **THEN** the lines end in `true`, `850` and `850`

#### Scenario: A warning stays out of the data
- **WHEN** the file has a line the parser refuses
- **THEN** the warning goes to stderr and stdout holds only `path<TAB>value` lines

### Requirement: An overlay replaces whole subtrees
Every subtree of two path segments that the per-machine overlay mentions (`claude.profiles`, `claude.rules`, `notes.send`, …) SHALL replace the base's subtree wholesale, never merged; everything else is inherited.

#### Scenario: A subtree the overlay does not mention
- **WHEN** the overlay defines only `claude.profiles`
- **THEN** `claude.rules` and `claude.default` come from the base unchanged

### Requirement: The TOML subset
A config file that is read as TOML SHALL be read as a deliberate subset of TOML: tables `[a.b]`, arrays of tables `[[a.b]]` (the items are numbered from 0 under the table's path), `key = value` lines with bare, quoted or dotted keys, `#` comments, basic and literal strings, decimal numbers, the booleans `true` and `false`, and one-line arrays and inline tables of those. A CRLF file reads as its LF twin.

#### Scenario: Tables, arrays of tables and lists
- **WHEN** the file has `[claude.profiles.personal]`, two `[[claude.rules]]` tables and `args = ["--model", "opus 4"]` under `[claude]`
- **THEN** `tagents --config` prints `claude.profiles.personal<TAB>`, `claude.rules.0.dir`, `claude.rules.1.dir`, `claude.args.0<TAB>--model` and `claude.args.1<TAB>opus 4`

#### Scenario: Strings
- **WHEN** a basic string holds `\"` and `\\`, and a literal string holds a backslash
- **THEN** the first two are unescaped and the backslash of the literal string is kept

#### Scenario: Numbers and booleans
- **WHEN** a line says `monthly_limit_usd = 1_250`
- **THEN** `tagents --config` prints `1250` for it, and `true` for a `true`

### Requirement: Refused TOML costs only its line
In a TOML config, a table defined twice, a duplicate key, a multi-line string, an escape other than `\"` and `\\`, a date or time, a hexadecimal, octal or binary number, an array or table nested inside an array, and text after a value SHALL be refused. Each refusal SHALL be written to stderr as `tagents: config: <file>:<line>: <why>`, listed by `tagents --check`, and the rest of the file SHALL still be read.

#### Scenario: A construct outside the subset
- **WHEN** line 3 of the file is `meter = """x"""`
- **THEN** stderr says `c.toml:3` and `multi-line strings are not supported`, and `tagents --check` lists the same line
- **AND** the other lines still flatten

#### Scenario: The body of a refused multi-line string
- **WHEN** a line says `a = """` (or `a = '''`), the lines after it say `b = 1`, `[fake]` and `c = 2`, and a line with the closing delimiter follows, then `d = 3`
- **THEN** exactly one refusal is listed, for the line of the opening, `b` and `c` are not read, and `d` is read in the table the opening was in
- **AND** a delimiter closed on the line that opens it (`a = """x"""`) leaves nothing to skip, and a backslash before a closing `"""` means it does not close

#### Scenario: A value that is not a string, a number or a boolean
- **WHEN** a line says `since = 1979-05-27`
- **THEN** it is refused with `not a string, a decimal number or a boolean: 1979-05-27`

#### Scenario: A key twice
- **WHEN** the same key is set twice in one table
- **THEN** the second line is refused and names the line

### Requirement: A JSON Schema describes the config
The repository SHALL carry `schemas/config.schema.json`, a JSON Schema (draft 2020-12) of the TOML config whose `$id` is `https://raw.githubusercontent.com/SkuratovichA/tagents/main/schemas/config.schema.json`, with a `description` and an `examples` entry on every key. `config.example.toml` SHALL start with `#:schema <that URL>` so a TOML-aware editor finds it, and SHALL validate against the schema; its test also runs `taplo lint` on it when `taplo` is on PATH, and says it skipped when not.

#### Scenario: The example validates
- **WHEN** `config.example.toml` is checked against the schema
- **THEN** there are no errors

#### Scenario: A misspelt key
- **WHEN** a config says `monthly_limit = 850` under `[usage]`
- **THEN** the schema reports it as an additional property

### Requirement: The schema names the keys that are read
The schema SHALL name every key the dashboard reads and every key the TypeScript readers declare, and SHALL flag a key neither reads in the tables the dashboard owns (`claude`, `usage`, `notes`, `resurrect`, `keys`). A key a script reads and the schema lacks, and a key the schema has that nothing reads, SHALL fail the schema test.

#### Scenario: A key the dashboard reads is missing from the schema
- **WHEN** a script reads a config key that the schema does not name
- **THEN** the schema test fails

#### Scenario: A key nothing reads
- **WHEN** the schema names a key under `usage` that no script reads
- **THEN** the schema test fails

## REMOVED Requirements

### Requirement: The YAML subset
**Reason**: The config is TOML only; no YAML reader is left in the dashboard or in the TypeScript programs.
**Migration**: Write the config as `config.toml` (see `config.example.toml`); a lone `config.yaml` is not looked at.

### Requirement: Refused syntax costs only its line
**Reason**: Replaced by "Refused TOML costs only its line".
**Migration**: None; the behaviour is the same for the TOML subset.
