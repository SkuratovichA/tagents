## MODIFIED Requirements

### Requirement: CLI verbs and flags
The `okb` program SHALL provide the verbs `index [--dir D] [--db F] [--full]`, `search <query…> [--dir] [--db] [--usage-db F] [--verbose] [--tag T] [--type T] [--kind K] [--limit N] [--json]`, `show <id[#heading]> [--dir] [--db] [--usage-db F] [--verbose]`, `list [--dir] [--db] [--type T] [--kind K] [--tag T] [--json]`, `lint [--dir D]`, `toc [--dir D] [--check]`, `usage` (its flags are in the arguments of the usage verb), `mcp`, `serve [--idle S] [--foreground] [--socket P]` and `join`. `tagents-knowledge` is another name for the same program.

#### Scenario: Verbs match the generated contract
- **WHEN** the CLI contract is generated
- **THEN** it lists exactly `index`, `search`, `show`, `list`, `lint`, `toc`, `usage`, `mcp`, `serve`, `join`, in English, with exit codes 0, 1, 2 and 4

## ADDED Requirements

### Requirement: The program is okb
The knowledge base SHALL be served by one program, `okb`, whose verbs are the ones of the requirement "CLI verbs and flags". `okb --spec` SHALL print the machine-readable description of its verbs, flags, exit codes and effects that `spec/cli/okb.json` holds, and `okb --version` the version of the workspace. A word that is not a verb SHALL be a usage error with exit 2 and the usage text on stderr, and no word the usage text on stdout with exit 2.

#### Scenario: The description is the file
- **WHEN** `okb --spec` runs
- **THEN** its output equals `spec/cli/okb.json` and a check of the contract package fails when the two differ (`pnpm -r test`)

#### Scenario: The old name
- **WHEN** `tagents-knowledge search x` runs
- **THEN** it answers as `okb search x` (`tests/install.sh`)

### Requirement: The okb files are found as before
In this change `okb` SHALL choose the documents folder, the index and the usage store by the requirements "Locating the documents folder", "Locating the index" and "Locating the usage store", with the same variables and the same config file of tagents, so that an index and a usage store written by the earlier program are read by `okb` unchanged.

#### Scenario: An index of the earlier program
- **WHEN** `okb search x` runs over the `knowledge.sqlite` and `knowledge-usage.sqlite` that `tagents-knowledge` wrote
- **THEN** it reads them, and records its reads in the same usage store (`tests/rust-knowledge-parity.sh`)

### Requirement: okb has a config directory of its own
In the second pull request `okb` SHALL read its configuration from `OKB_CONFIG_DIR`, else `$XDG_CONFIG_HOME/okb`, else `~/.config/okb`. The documents folder SHALL be `OKB_DIR`, else `dir` in `config.toml` there, else `knowledge.dir` of the tagents config, read only. The index SHALL be `knowledge.sqlite` in that directory.

#### Scenario: The old variable
- **WHEN** only `TAGENTS_KNOWLEDGE_DIR` is set
- **THEN** it names the documents folder, as a fallback for one release

### Requirement: The usage store moves by copy
In the second pull request the usage store SHALL be `knowledge-usage.sqlite` in the okb config directory. When it is missing there and the tagents config directory holds one, `okb` SHALL copy it once and leave the old file, because the store is the only record of reads.

#### Scenario: The usage store moves by copy
- **WHEN** `okb usage` runs for the first time with an `OKB_CONFIG_DIR` that holds no usage store and the tagents directory holds one
- **THEN** the report counts the old events and the old file is still there (`tests/rust-knowledge-parity.sh`)
