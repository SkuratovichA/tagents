## MODIFIED Requirements

### Requirement: The plugin version follows what the plugin ships
`.claude-plugin/plugin.json` SHALL carry a `version` and a `metadata.digest`, both maintained by the generator. The digest SHALL be a `sha256:` hash over the paths and contents of the payload: the generated files, every file under `skills/` outside `references/`, the files the plugin ships as they are and `plugin.json` starts (`packages/knowledge/bin/knowledge-mcp`), `.claude-plugin/marketplace.json` when present, and `plugin.json` without its `version` and `digest`. The version SHALL move only when the digest moved.

#### Scenario: The first run
- **WHEN** `plugin.json` has no stored digest
- **THEN** the digest is stored, the version stays as it was and the output says the first digest was stored

#### Scenario: Nothing changed
- **WHEN** the stored digest equals the new one
- **THEN** `plugin.json` is not rewritten, even if its formatting differs

#### Scenario: Only the version and digest differ
- **WHEN** nothing but `version` and `metadata.digest` of `plugin.json` changed
- **THEN** the digest does not move

#### Scenario: The knowledge launcher changes
- **WHEN** only `packages/knowledge/bin/knowledge-mcp` changed
- **THEN** the digest moves, the version takes a patch step, and the pre-commit hook regenerates the contract for a commit that stages that file
