## ADDED Requirements

### Requirement: okb reads a config directory of its own
In the second pull request `okb` SHALL read `OKB_CONFIG_DIR`, else `$XDG_CONFIG_HOME/okb`, else `~/.config/okb`, and `dir` in the `config.toml` there. The `knowledge` section of the tagents config SHALL stay as a read-only fallback for the documents folder, and `okb` SHALL NOT write to the tagents config directory.

#### Scenario: Fallback to the tagents config
- **WHEN** only `knowledge.dir` of the tagents `config.toml` names a folder
- **THEN** `okb list` reads that folder (`tests/rust-knowledge-parity.sh`)

#### Scenario: okb's own key wins
- **WHEN** both configs name a folder
- **THEN** the folder of `OKB_DIR`, else of the okb config, is used
