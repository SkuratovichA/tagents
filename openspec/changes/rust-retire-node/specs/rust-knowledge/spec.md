## MODIFIED Requirements

### Requirement: Equality is kept by generated files and a suite
The tool list and the texts the binary prints (`crates/tagents-core/src/knowledge/tools.json` and `texts.json`) SHALL be frozen files: the generator is gone with the node server they were written from. A differential suite SHALL run the same scenarios against the node server of the oracle tag `v0.6.7` (built by `tests/parity-oracle.sh`) and the binary on copies of one corpus, comparing bytes, with each program reading the index and usage store the other wrote. CI SHALL fail when the suite fails.

#### Scenario: The binary drifts from the oracle
- **WHEN** a tool description or a text of the binary changes and the oracle still answers the old one
- **THEN** the suite fails, unless the scenario names the difference as `OWN_ERR`

#### Scenario: The wrong process
- **WHEN** the process the suite starts as the Rust side is the node CLI
- **THEN** the suite fails at its first check

#### Scenario: The node list moves
- **WHEN** a tool description changes in the node server of the oracle
- **THEN** the oracle is a tag and does not move; the frozen list is changed by hand with the suite beside it
