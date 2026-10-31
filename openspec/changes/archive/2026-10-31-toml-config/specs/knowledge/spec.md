## MODIFIED Requirements

### Requirement: Locating the documents folder
The folder of documents SHALL be chosen, in order of precedence, from the `--dir` flag, the `TAGENTS_KNOWLEDGE_DIR` environment variable, then `knowledge.dir` in the tagents config (`config.toml`, in the tagents config directory, `~/.config/tagents` unless `TAGENTS_CONFIG_DIR` moves it). There SHALL be no default folder, and a blank value is treated as not given.

#### Scenario: Environment beats config, flag beats both
- **WHEN** config names folder A, `TAGENTS_KNOWLEDGE_DIR` names folder B and `--dir` names folder C
- **THEN** the CLI uses C; without `--dir` it uses B; with neither it uses A

#### Scenario: Config alone is enough
- **WHEN** only `config.toml` holds `[knowledge]` with `dir = "./knowledge"`
- **THEN** `tagents-knowledge list` reads the `knowledge` folder next to the config file

#### Scenario: Blank value ignored
- **WHEN** `TAGENTS_KNOWLEDGE_DIR` is set to an empty or whitespace string and config names a folder
- **THEN** the config folder is used

#### Scenario: Nobody said where
- **WHEN** no flag, variable or config key names a folder
- **THEN** the command exits 1 and stderr explains that `TAGENTS_KNOWLEDGE_DIR`, `--dir` or the `knowledge.dir` key of the config must be set, names the config file and shows the lines to add to it, as a `[knowledge]` table for a TOML config and as a `knowledge:` map for a YAML one

#### Scenario: The chosen folder does not exist
- **WHEN** the chosen path does not exist
- **THEN** the command exits 1 and stderr says the knowledge directory does not exist

### Requirement: Path forms in the folder setting
A leading `~` in `--dir`, `TAGENTS_KNOWLEDGE_DIR` or `knowledge.dir` SHALL be expanded to the home directory, and only at the start. A relative `knowledge.dir` SHALL be resolved against the directory that holds the config file. A config file that is missing, unparseable, or without `knowledge.dir` SHALL count as not set, and its other keys (such as `plugins:`) SHALL be ignored.

#### Scenario: Tilde in config
- **WHEN** config holds `dir = "~/knowledge"` under `[knowledge]`
- **THEN** the folder is `knowledge` under the home directory

#### Scenario: Config without a knowledge section
- **WHEN** config holds no `[knowledge]` table (only `[plugins.x]` tables, say), or does not exist
- **THEN** the folder counts as not set
