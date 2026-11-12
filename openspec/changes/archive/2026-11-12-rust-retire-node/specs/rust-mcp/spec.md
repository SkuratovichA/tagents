## MODIFIED Requirements

### Requirement: The node server is the reference
`tests/rust-mcp-parity.sh` SHALL feed one script of requests to the node server of the oracle (`packages/mcp` of tag `v0.6.7`, built by `tests/parity-oracle.sh`) and to `tagents-core mcp` with stub programs on `PATH` and SHALL compare the two answers byte for byte, leaving out only `serverInfo.version`, and the workflow `rust.yml` SHALL run it on every change to `crates/**` or the suite. The working tree has no node server: `packages/mcp` is deleted.

#### Scenario: The servers differ
- **WHEN** one server answers a request differently from the other
- **THEN** the suite fails and prints both lines

#### Scenario: The suite runs in CI
- **WHEN** a pull request changes `crates/**` or the suite
- **THEN** the `rust` job fetches the oracle tag, runs `tests/parity-oracle.sh` and then the suite
