## MODIFIED Requirements

### Requirement: Where the config file is
The config file SHALL be `$TA_CONFIG` when that is set, else in `$XDG_CONFIG_HOME/tagents` or `~/.config/tagents` the first of `config.toml` and `config.yaml` that is a readable file, else `config.toml` as the path that messages name. A file named by `$TA_CONFIG` is read as TOML when its name ends in `.toml` and as YAML otherwise.

#### Scenario: Default location
- **WHEN** neither `TA_CONFIG` nor `XDG_CONFIG_HOME` is set and `~/.config/tagents/config.toml` exists
- **THEN** tagents reads `~/.config/tagents/config.toml`

#### Scenario: Only a YAML file
- **WHEN** the config directory holds `config.yaml` and no `config.toml`
- **THEN** tagents reads `config.yaml` exactly as it always did

#### Scenario: Both files
- **WHEN** the config directory holds `config.toml` and `config.yaml`
- **THEN** tagents reads `config.toml` and does not read `config.yaml`

#### Scenario: Pointed elsewhere
- **WHEN** `TA_CONFIG` names a file
- **THEN** that file is read, by the reader its extension picks, and the default location is not

#### Scenario: The file name picks the reader
- **WHEN** a config file is named `config.toml`, `config.work.toml` or `.toml`
- **THEN** it is read as TOML
- **AND** a file named `config.TOML`, `Config.Toml`, `config.toml.bak`, `config.yaml`, `config.yml` or `config` is read as YAML, in the dashboard and in the TypeScript programs alike

### Requirement: TypeScript programs find the same directory
Programs built on `@tagents/core` SHALL look for the config in the directory `$TAGENTS_CONFIG_DIR` when that is set and not blank, else `$XDG_CONFIG_HOME/tagents`, else `~/.config/tagents`, and in that directory choose `config.toml`, else `config.yaml`, with the same precedence as the dashboard. A missing file there means no plugins and is not an error.

#### Scenario: Directory order
- **WHEN** `TAGENTS_CONFIG_DIR` is `/x/tagents`
- **THEN** the file is `/x/tagents/config.toml`, or `/x/tagents/config.yaml` when only that exists
- **AND** with only `XDG_CONFIG_HOME=/x/cfg` the directory is `/x/cfg/tagents`

### Requirement: Printing the config as read
`tagents --config` SHALL print the effective config (the file with the per-machine overlay laid over it) as one `path<TAB>value` line per leaf, in file order, on stdout, and exit 0. Table and mapping keys are joined by dots and array and sequence items are numbered from 0, so a rule's directory is `claude.rules.0.dir`. A key with nothing under it prints with an empty value.

#### Scenario: The shipped example
- **WHEN** `tagents --config` runs on `config.example.toml`
- **THEN** it prints leaves such as `claude.args.0<TAB>--dangerously-skip-permissions`, `claude.profiles.work<TAB>` (empty) and `claude.rules.0.profile<TAB>personal`

#### Scenario: Exit code with problems
- **WHEN** the file has a profile pointing at a directory that does not exist
- **THEN** `tagents --config` still prints the leaves on stdout and exits 0

### Requirement: The YAML subset
A config file that is read as YAML (the deprecated fallback) SHALL be read as a deliberate subset of YAML: mappings, sequences (including a bare `-` whose keys follow on the next lines), `#` comments, and plain, single-quoted and double-quoted scalars, at any consistent indentation. In a double-quoted scalar `\"` and `\\` are unescaped; a single-quoted one is literal. A CRLF file reads as its LF twin.

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
In a YAML config, tab indentation, flow style (`{}` or `[]` as a value), block scalars (`|` or `>`), anchors and aliases (`&`, `*`), a line that is not `key: value`, a sequence item where none is expected, and a key where a sequence item is expected SHALL be refused. Each refusal SHALL be written to stderr as `tagents: config: <file>:<line>: <why>` and the rest of the file SHALL still be read.

#### Scenario: Tab-indented line
- **WHEN** line 3 of the file is indented with a tab
- **THEN** stderr says `tabs.yaml:3` and `tab indentation is not supported`
- **AND** the other lines still flatten

#### Scenario: Flow style
- **WHEN** a line says `rules: [a, b]`
- **THEN** it is refused with `flow style is not supported`

### Requirement: The per-machine overlay
`config.<host>.toml` beside the config file (the file's name with its extension replaced by `.<host>.toml`) SHALL be laid over the base file, where `<host>` is the short hostname (`hostname -s`) or `TA_HOST` when that is set. When there is no `config.<host>.toml`, a `config.<host>.yaml` in the same place is used instead. Each overlay is read by the reader its own extension picks, whichever format the base file is in.

#### Scenario: Replaced, not merged
- **WHEN** the base defines profiles `personal` and `work`, and `config.mbp.toml` defines profiles `sasha` and `nuzhin` and one rule
- **THEN** on host `mbp` the effective config has profiles `sasha` and `nuzhin` only, and the overlay's one rule only
- **AND** `claude.args`, `notes.send` and `usage.*` are inherited from the base

#### Scenario: A YAML overlay
- **WHEN** only `config.mbp.yaml` exists beside a `config.toml`
- **THEN** it is read as YAML and laid over the base in the same way

#### Scenario: Refusals in the overlay
- **WHEN** the overlay has a line the parser refuses
- **THEN** it is reported like a refusal in the base file

#### Scenario: Another machine
- **WHEN** the host is `other` and there is no `config.other.toml` or `config.other.yaml`
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
- **THEN** one line starts with `config.mbp.toml: claude.profiles.nuzhin.config_dir` and another with the base file and `notes.send`
- **AND** on another host only the base's line is listed

### Requirement: The status bar remembers the verdict
The status bar SHALL NOT re-check the config on every redraw. It SHALL remember the count with its time and the config path in `.cfg-check` in the state directory, and reuse it for up to 60 seconds (`TA_CFG_CHECK_EVERY`) unless any `config*.toml` or `config*.yaml` in the config directory is newer than the stamp, or the stamp names a different config. With no config file the count is 0 and the stamp is removed.

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
- **WHEN** neither `config.toml` nor `config.yaml` exists
- **THEN** `tagents --agent-cmd` starts a plain `claude --dangerously-skip-permissions` with the environment inherited, and no dialog opens

### Requirement: The config dump prints text only
Every value in the `tagents --config` output SHALL print as text: a TOML `true`, `850` and `"850"` print as `true`, `850` and `850`. Warnings about lines the parser refused SHALL go to stderr, never into the data. A YAML config and the TOML a conversion made of it SHALL print identical lines.

#### Scenario: Types print as text
- **WHEN** the file says `workdays = true`, `monthly_limit_usd = 850` and `note = "850"`
- **THEN** the lines end in `true`, `850` and `850`

#### Scenario: A warning stays out of the data
- **WHEN** the file has a line the parser refuses
- **THEN** the warning goes to stderr and stdout holds only `path<TAB>value` lines

#### Scenario: A conversion reads the same
- **WHEN** `tagents --config` runs on the YAML example and on the file `tagents config convert` made of it
- **THEN** the two outputs are byte for byte the same

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

### Requirement: A YAML config is deprecated
While the config file in use is YAML, `tagents --check` SHALL list one more problem, `<file>: YAML config is deprecated — run: tagents config convert (it prints the TOML and changes nothing; --write saves it beside this file)`. An overlay in YAML adds the same line for itself, naming `tagents config convert --all`. The problem counts in the dashboard header, the status bar tally and the one-time tmux message like any other, and `tagents --config` prints nothing about it.

#### Scenario: Only YAML
- **WHEN** the config directory holds a good `config.yaml` and no `config.toml`
- **THEN** `tagents --check` prints the deprecation line and exits 1
- **AND** the status bar shows `cfg!1`

#### Scenario: A good TOML config
- **WHEN** the config is a good `config.toml` with no `config.yaml` beside it
- **THEN** `tagents --check` prints nothing and exits 0

#### Scenario: A YAML config named by TA_CONFIG
- **WHEN** `TA_CONFIG` names a file that ends in `.yaml`
- **THEN** the same line is listed

### Requirement: The TypeScript programs say a YAML config is deprecated
A TypeScript program that reads a YAML config SHALL say on stderr, once per process and per file, `tagents: <file> is a YAML config, which is deprecated — run: tagents config convert`. A plugin options file in YAML is read without a word.

#### Scenario: A TypeScript program reads a YAML config
- **WHEN** `tagents plugin list` runs twice in one process against a `config.yaml`
- **THEN** stderr carries the deprecation sentence once

### Requirement: A config.toml beside a config.yaml wins
When `config.toml` and `config.yaml` are both in the config directory, tagents SHALL read the TOML only. `tagents --check` SHALL list `<config.toml>: config.yaml is also there — config.toml is read and config.yaml is ignored; delete config.yaml once config.toml is right`, an overlay pair gets the same line for itself, and the TypeScript programs say it once per process on stderr. The YAML file is not called deprecated, because it is not read.

#### Scenario: Both files, different content
- **WHEN** `config.yaml` sets `usage.workdays: false` and `config.toml` sets `workdays = true`
- **THEN** `tagents --config` prints `usage.workdays<TAB>true` and `tagents --check` names both files

### Requirement: Converting the YAML config to TOML
`tagents config convert [FILE] [--write] [--all]` (run as `tagents-core config convert`, which `tagents config …` hands it) SHALL turn a YAML config into TOML. `FILE` defaults to `$TA_CONFIG` when that is set, else `config.yaml` in the config directory. Without `--write` it SHALL print the TOML on stdout, say on stderr that comments are not carried over, and change nothing. A `.toml` as `FILE` is a usage error (exit 2), a missing file exit 1.

#### Scenario: Print only
- **WHEN** `tagents config convert` runs on a YAML config
- **THEN** stdout is the TOML, stderr says comments are not carried over, the exit code is 0 and no file in the directory changed

#### Scenario: A TOML file as the source
- **WHEN** `tagents config convert config.toml` runs
- **THEN** the exit code is 2

### Requirement: Writing the converted TOML
`tagents config convert --write` SHALL create the `.toml` beside the YAML, print `wrote <target> — <source> is still there, and tagents reads the TOML first and says so while both exist`, refuse with exit 3 to overwrite a file that exists, and never edit or delete the YAML. With `--all` it SHALL also convert the `config.<host>.yaml` overlays beside the file, and a write SHALL be all or nothing.

#### Scenario: Writing beside the YAML
- **WHEN** `tagents config convert --write` runs and there is no `config.toml`
- **THEN** `config.toml` exists beside `config.yaml`, `config.yaml` is byte for byte unchanged, and the exit code is 0

#### Scenario: The permission bits of the source
- **WHEN** `config.yaml` has mode 0640 and `tagents config convert --write` runs under a umask of 022
- **THEN** `config.toml` has the mode of the source as the umask masks it, 0640

#### Scenario: A write that fails halfway
- **WHEN** `--all --write` has written `config.toml` and the next target cannot be written
- **THEN** the exit code is 1, `config.toml` is removed, and a file that was already at the failing target is untouched

#### Scenario: Never overwriting
- **WHEN** `tagents config convert --write` runs and a `config.toml` exists
- **THEN** it exits 3, names the file and writes nothing

#### Scenario: The overlays, all or none
- **WHEN** `tagents config convert --all --write` runs and one overlay holds an alias
- **THEN** it names the line, exits 3 and no `.toml` was created

### Requirement: What the converted TOML says
The converted TOML SHALL start with the `#:schema` line of the schema and a line saying which file it was converted from. A number or a boolean keeps its type only when the YAML wrote it as a plain `850` or `true`; a quoted value is a string. A scalar with no TOML twin SHALL be refused, never turned into a string. A key with no value becomes an empty table, and a key that is not letters, digits, `_` and `-` is quoted.

#### Scenario: Types kept only when plain
- **WHEN** the YAML says `monthly_limit_usd: 850`, `workdays: true` and `meter: "850"`
- **THEN** the TOML has `monthly_limit_usd = 850`, `workdays = true` and `meter = "850"`

#### Scenario: A number with no TOML twin
- **WHEN** line 5 of the YAML says `mode: 0644`, `ratio: .5`, `mask: 0x10`, `flag: True` or `nothing: ~`
- **THEN** the conversion names line 5, says what to write instead (a plain decimal, `true` or `false`, or the value quoted), exits 3 and writes nothing

#### Scenario: A control character in a value
- **WHEN** a YAML string value has a tab, another control character or a lone surrogate in it
- **THEN** the conversion names the line, says that character cannot be written in the TOML tagents reads, exits 3 and writes nothing

#### Scenario: A profile with nothing under it
- **WHEN** the YAML says `work:` under `profiles:`
- **THEN** the TOML has a `[claude.profiles.work]` table with nothing in it

### Requirement: A conversion is checked before it is offered
Before it offers a byte, `tagents config convert` SHALL read the YAML and the result with `tagents --config` and compare the two. When they differ, or when the YAML has a construct with no TOML twin, it SHALL write nothing, name the file (and the line, for the construct) and exit 3. The comparison allows one difference: TOML puts a table's plain keys above its sub-tables, so a plain key written after a sub-table may move up, and the order of the profiles never changes.

#### Scenario: Reading the same
- **WHEN** `config.example.yaml` from the test fixtures is converted
- **THEN** `tagents --config` prints byte for byte the same lines for the YAML and for the TOML, under `/bin/bash` 3.2

#### Scenario: A value that would change type
- **WHEN** the dumps of the YAML and the TOML are the same but a string, number or boolean of the YAML comes back from the TOML as another type or value
- **THEN** the conversion says the TOML would give a different value than the YAML, naming the key, exits 3 and writes nothing

#### Scenario: A tagents that does not answer
- **WHEN** `tagents --config` does not finish within 10 seconds or prints more than 16 MiB
- **THEN** the conversion says so, exits 3 and writes nothing

#### Scenario: An alias
- **WHEN** the YAML has `other: *b`
- **THEN** the conversion names the line, says an alias has no TOML twin, exits 3 and writes nothing

#### Scenario: A reading that differs
- **WHEN** `tagents --config` would print other lines for the TOML than for the YAML
- **THEN** the conversion says `tagents would read the TOML made from it differently from the YAML, so nothing is offered`, exits 3 and writes nothing

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
