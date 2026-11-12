## MODIFIED Requirements

### Requirement: Equality is kept by generated files and a suite
The tool list and the texts the binary prints (`crates/okb/src/knowledge/tools.json` and `texts.json`) SHALL be frozen files: the generator is gone with the node server they were written from. A differential suite SHALL run the same scenarios against the node server of the oracle tag `v0.6.7` (built by `tests/parity-oracle.sh`) and the `okb` binary on copies of one corpus, with the verbs of the command line as well as the three servers, comparing bytes, with each program reading the index and usage store the other wrote. CI SHALL fail when the suite fails.

#### Scenario: The binary drifts from the oracle
- **WHEN** a tool description or a text of the binary changes and the oracle still answers the old one
- **THEN** the suite fails, unless the scenario names the difference as `OWN_ERR`

#### Scenario: The wrong process
- **WHEN** the process the suite starts as the Rust side is the node CLI
- **THEN** the suite fails at its first check

#### Scenario: The node list moves
- **WHEN** a tool description changes in the node server of the oracle
- **THEN** the oracle is a tag and does not move; the frozen list is changed by hand with the suite beside it

## REMOVED Requirements

### Requirement: The knowledge server is three verbs of tagents-core
**Reason**: The knowledge verbs belong to the `okb` binary, which also serves the seven verbs node used to serve.
**Migration**: "okb serves every verb of the knowledge base" and, in `core-front-door`, "tagents-core knowledge is okb's".

## ADDED Requirements

### Requirement: okb serves every verb of the knowledge base
`okb` SHALL serve `index`, `search`, `show`, `list`, `lint`, `toc`, `usage`, `mcp`, `serve` and `join` from its own crate, and no verb SHALL start a node program. The first seven SHALL print the same bytes on standard output and standard error and exit with the same code as the node program of the oracle tag, for the same arguments, environment and files, errors included. `mcp`, `serve` and `join` SHALL do what `tagents-core knowledge` did with them.

#### Scenario: A read verb
- **WHEN** `okb search`, `show`, `list`, `lint`, `toc` or `usage` runs on a copy of the corpus the suite holds, with a flag, with `--json` and with a bad flag
- **THEN** standard output, standard error and the exit code equal those of the node program of the oracle (`tests/rust-knowledge-parity.sh`)

#### Scenario: A write verb
- **WHEN** `okb index` and `okb index --full` run, and `okb toc` writes `index.md`
- **THEN** the files they write and the lines they print are the oracle's, and the index file is read by both programs (`tests/rust-knowledge-parity.sh`)

#### Scenario: The usage text
- **WHEN** `okb`, `okb help`, `okb --help`, `okb -h` and `okb bogus` run
- **THEN** the text, the stream it goes to and the exit code are the oracle's, byte for byte, so the program name in the text is still `tagents-knowledge` until pull request B renames it (`tests/rust-knowledge-parity.sh`)

#### Scenario: Arguments of mcp and serve
- **WHEN** `okb mcp extra words` runs, and `okb serve` gets `--idle 0`, an unknown option or a positional word
- **THEN** `mcp` ignores the words and runs; `serve` exits 2, and for `--idle` its message names `--idle` (`cargo test -p okb`)

#### Scenario: tagents-core holds no knowledge code
- **WHEN** the workspace is built without the `okb` crate
- **THEN** `tagents-core` builds and passes its tests (`cargo test --workspace --locked`)
